//go:build wasip1

// notary_registry/main.go — Ukraine notary registry CRE workflow.
//
// Periodically (cron-triggered) fetches Ukraine's Ministry of Justice notary registry bulk
// XML/zip export (ern.minjust.gov.ua / data.gov.ua open-data catalog), parses it into a leaf
// set, builds a keccak Merkle tree over it, and anchors the root on-chain via
// RegistrySourceAnchor.publishSnapshot
// (backend/contracts/contracts/registry/RegistrySourceAnchor.sol) - the SAME ERC-7812 evidence
// registry every other root in this fusion (rarime identity state, PP's ASP) anchors into.
//
// THE POINT of routing this through CRE rather than a single relayer script: multiple
// independent Chainlink DON nodes fetch the SAME bulk export and must produce a byte-identical
// result (http.SendRequest + cre.ConsensusIdenticalAggregation, the exact pattern used for
// vendor price fetches in old/keeper/my-workflow/main.go) before a report is generated - no
// single operator can substitute a tampered registry snapshot. This is "the concept... a
// public, authoritative government source, same pattern as the OFAC list": a periodically-
// refreshed, cross-verified snapshot, explicitly NOT a live query endpoint (the open-data
// format IS a bulk export - this workflow treats it as one, not as something to poll
// per-request).
//
// OPERATOR TODO before deploying:
//  1. Config.RegistryEndpointURL must be filled in with the exact bulk-export URL from the
//     data.gov.ua catalog entry / ern.minjust.gov.ua for this dataset - deliberately left
//     empty here rather than guessed, since the exact deep link needs confirming against the
//     live catalog (see PP-NOIR-FUSION.md's CRE integration note, 2026-07-24).
//  2. NotaryRecordXML's field tags are a reasonable PLACEHOLDER schema (registration number /
//     full name / region / status), not a verified one - confirm against a real downloaded
//     sample before trusting parse results.
//  3. RegistrySourceAnchor's REGISTRY_POSTMAN role must be granted to whatever address this
//     workflow's WriteReport call resolves to (see RegistrySourceAnchor.onReport's own doc
//     comment for the Forwarder-trust caveat).
//
// Nothing here has been built/simulated/deployed yet - same standing constraint as the rest of
// this session's circuit work (not running the toolchain without approval); this is written to
// the same real-code, not-yet-compiled-and-verified standard as backend/circuits/withdraw_identity.
//
// Build:    GOOS=wasip1 GOARCH=wasm go build -o notary_registry.wasm .
// Simulate: cre workflow simulate notary_registry --trigger-index 0
package main

import (
	"archive/zip"
	"bytes"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"log/slog"
	"sort"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

// ═══════════════════════════════════════════════════════════════════
//  Configuration
// ═══════════════════════════════════════════════════════════════════

type Config struct {
	ChainSelectorName     string `json:"chainSelectorName"`
	RegistryAnchorAddress string `json:"registryAnchorAddress"`

	// See OPERATOR TODO #1 above - deliberately left for the deployer to fill in, not guessed.
	RegistryEndpointURL string `json:"registryEndpointUrl"`

	// Cron schedule (standard 5-field cron expression). Defaults to daily - matches the "not
	// necessarily real-time" framing this mechanism is built around; a bulk export doesn't
	// change intra-day, so polling more often than the source republishes it buys nothing.
	Schedule string `json:"schedule"`
}

func (c *Config) applyDefaults() {
	if c.Schedule == "" {
		c.Schedule = "0 0 * * *" // daily
	}
}

// keccak256("UA_NOTARY_REGISTRY") - the registryId RegistrySourceAnchor keys this list's
// snapshots under. A constant, not per-config, because it identifies the LIST, not a deployment.
var registryID = crypto.Keccak256Hash([]byte("UA_NOTARY_REGISTRY"))

// ═══════════════════════════════════════════════════════════════════
//  Registry schema (placeholder pending a real sample export - see OPERATOR TODO #2)
// ═══════════════════════════════════════════════════════════════════

// NotaryRecordXML is one entry as parsed from the bulk export. Field tags are a reasonable guess
// at the real schema's shape, NOT verified against a real downloaded file.
type NotaryRecordXML struct {
	RegistrationNumber string `xml:"reg_number"`
	FullName           string `xml:"full_name"`
	Region             string `xml:"region"`
	Status             string `xml:"status"` // expected values: "active" / "suspended" / "terminated"
}

type NotaryRegistryXML struct {
	XMLName xml.Name          `xml:"registry"`
	Records []NotaryRecordXML `xml:"record"`
}

// ═══════════════════════════════════════════════════════════════════
//  Fetch + parse (runs inside CRE node mode - see onSchedule below)
// ═══════════════════════════════════════════════════════════════════

// fetchAndParse downloads the bulk export via the SendRequester passed into node mode (each DON
// node calls this independently; cre.ConsensusIdenticalAggregation then requires every node's
// result to match byte-for-byte before the workflow proceeds). Handles both a raw .xml response
// and a .zip wrapping one, since open-data catalogs commonly serve bulk exports zipped.
func fetchAndParse(sr *http.SendRequester, url string) ([]NotaryRecordXML, error) {
	resp, err := sr.SendRequest(&http.Request{Url: url, Method: "GET"}).Await()
	if err != nil {
		return nil, fmt.Errorf("fetch registry export: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("fetch registry export: status %d", resp.StatusCode)
	}

	xmlBytes := resp.Body
	if len(resp.Body) >= 2 && resp.Body[0] == 0x50 && resp.Body[1] == 0x4b { // "PK" zip magic
		zr, err := zip.NewReader(bytes.NewReader(resp.Body), int64(len(resp.Body)))
		if err != nil {
			return nil, fmt.Errorf("open registry export zip: %w", err)
		}
		var found bool
		for _, f := range zr.File {
			if f.FileInfo().IsDir() {
				continue
			}
			rc, err := f.Open()
			if err != nil {
				return nil, fmt.Errorf("open %s in registry zip: %w", f.Name, err)
			}
			buf := new(bytes.Buffer)
			_, readErr := buf.ReadFrom(rc)
			rc.Close()
			if readErr != nil {
				return nil, fmt.Errorf("read %s in registry zip: %w", f.Name, readErr)
			}
			xmlBytes = buf.Bytes()
			found = true
			break // the export is expected to contain exactly one XML file
		}
		if !found {
			return nil, fmt.Errorf("registry export zip contained no files")
		}
	}

	var registry NotaryRegistryXML
	if err := xml.Unmarshal(xmlBytes, &registry); err != nil {
		return nil, fmt.Errorf("parse registry XML: %w", err)
	}
	if len(registry.Records) == 0 {
		return nil, fmt.Errorf("registry export parsed to zero records - schema mismatch or empty export")
	}
	return registry.Records, nil
}

// ═══════════════════════════════════════════════════════════════════
//  Merkle tree: keccak, OpenZeppelin MerkleProof-compatible sorted-pair hashing
//
//  keccak (not Poseidon) is deliberate: this tree isn't consumed by a ZK circuit yet - the
//  notary-credential binding circuit (proving "I am the identity behind this specific registry
//  entry") is explicit future work, deferred alongside the identity-based ASP design (see
//  pp/src/identity_asp.nr's own header and PP-NOIR-FUSION.md). A future ZK-consuming version of
//  this tree would need Poseidon+LeanIMT at that point, mirroring identity_asp.nr - not now.
//  keccak + OpenZeppelin's MerkleProof (already vendored, lib/openzeppelin-contracts) is the
//  simplest correct choice for a list that's on-chain-verifiable but not yet ZK-provable, and
//  matches how most on-chain sanctions/allow-list oracles (the OFAC-list pattern referenced)
//  actually work.
// ═══════════════════════════════════════════════════════════════════

func leafHash(r NotaryRecordXML) [32]byte {
	return crypto.Keccak256Hash([]byte(r.RegistrationNumber), []byte(r.FullName), []byte(r.Region), []byte(r.Status))
}

// merkleRoot builds an OpenZeppelin-MerkleProof-compatible root: leaves sorted, each internal
// node hashes its two children in sorted order (so proofs don't need left/right direction bits) -
// the same convention @openzeppelin/merkle-tree (JS) and MerkleProof.sol use.
func merkleRoot(leaves [][32]byte) [32]byte {
	if len(leaves) == 0 {
		return [32]byte{}
	}
	sort.Slice(leaves, func(i, j int) bool { return bytes.Compare(leaves[i][:], leaves[j][:]) < 0 })

	level := leaves
	for len(level) > 1 {
		next := make([][32]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 < len(level) {
				next = append(next, hashSortedPair(level[i], level[i+1]))
			} else {
				next = append(next, level[i]) // odd one out, carried up unchanged
			}
		}
		level = next
	}
	return level[0]
}

func hashSortedPair(a, b [32]byte) [32]byte {
	if bytes.Compare(a[:], b[:]) > 0 {
		a, b = b, a
	}
	return crypto.Keccak256Hash(a[:], b[:])
}

// ═══════════════════════════════════════════════════════════════════
//  ABI: RegistrySourceAnchor.onReport's decoded payload shape
//  (bytes32 registryId, bytes32[] leaves) - the CONTRACT computes and verifies the root from
//  these leaves on-chain (RegistrySourceAnchor._computeRoot); this workflow does not submit a
//  separately-claimed root at all, so there is no way for an on-chain root to end up
//  disconnected from a real, fully-available leaf set. `leaves` doubles as the on-chain data-
//  availability layer (emitted via SnapshotLeaves) - no IPFS or other external pinning
//  dependency; leaves are just the transaction's own calldata/event data, permanently replayable
//  by any full node.
// ═══════════════════════════════════════════════════════════════════

var (
	bytes32Type, _      = abi.NewType("bytes32", "", nil)
	bytes32ArrayType, _ = abi.NewType("bytes32[]", "", nil)
)

var snapshotABI = abi.Arguments{
	{Type: bytes32Type},      // registryId
	{Type: bytes32ArrayType}, // leaves
}

// ═══════════════════════════════════════════════════════════════════
//  Handler
// ═══════════════════════════════════════════════════════════════════

// The cron trigger's own payload (2nd param) is unused - onSchedule's job is entirely
// self-contained (fetch, aggregate, publish), it doesn't need anything the trigger carries.
func onSchedule(config *Config, runtime cre.Runtime, _ *cron.Payload) (string, error) {
	logger := runtime.Logger()

	chainSel, err := evm.ChainSelectorFromName(config.ChainSelectorName)
	if err != nil {
		return "", fmt.Errorf("unknown chain %s: %w", config.ChainSelectorName, err)
	}
	evmClient := &evm.Client{ChainSelector: chainSel}

	httpClient := &http.Client{}
	recordsPromise := http.SendRequest(config, runtime, httpClient,
		func(cfg *Config, lg *slog.Logger, sr *http.SendRequester) (*[]NotaryRecordXML, error) {
			records, err := fetchAndParse(sr, cfg.RegistryEndpointURL)
			if err != nil {
				return nil, err
			}
			return &records, nil
		},
		cre.ConsensusIdenticalAggregation[*[]NotaryRecordXML](),
	)

	recordsPtr, err := recordsPromise.Await()
	if err != nil || recordsPtr == nil {
		logger.Error(fmt.Sprintf("[notary_registry] fetch/consensus failed: %v", err))
		return "", fmt.Errorf("fetch/consensus failed: %w", err)
	}
	records := *recordsPtr

	// Only ACTIVE notaries are admitted as leaves - a suspended/terminated entry proves nothing
	// useful. This tree has no update/removal semantics of its own (unlike PP's LeanIMT or
	// rarime's SMT); each publish is a fresh full rebuild from the current export instead, so
	// dropped/reinstated entries are simply reflected in the next scheduled snapshot.
	leaves := make([][32]byte, 0, len(records))
	for _, r := range records {
		if r.Status != "active" {
			continue
		}
		leaves = append(leaves, leafHash(r))
	}
	if len(leaves) == 0 {
		err := fmt.Errorf("zero active notaries parsed from a %d-record export - refusing to publish an empty root", len(records))
		logger.Error(fmt.Sprintf("[notary_registry] %v", err))
		return "", err
	}
	// merkleRoot sorts `leaves` in place (Go slices share their backing array, so this reorders
	// the caller's slice too) - by the time we log/submit below, `leaves` is already the exact
	// strictly-ascending order RegistrySourceAnchor._computeRoot requires.
	root := merkleRoot(leaves)
	logger.Info(fmt.Sprintf("[notary_registry] %d active / %d total notaries, root=0x%x", len(leaves), len(records), root))

	// leaves ARE the on-chain data-availability layer (see the ABI comment above) - no IPFS CID,
	// no external pinning service. The contract recomputes and verifies this exact root from
	// `leaves` itself; `root` here is only used for the log line above, not submitted separately.
	payload, err := snapshotABI.Pack(registryID, leaves)
	if err != nil {
		return "", fmt.Errorf("abi pack failed: %w", err)
	}
	reportResp, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: payload,
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[notary_registry] GenerateReport failed: %v", err))
		return "", fmt.Errorf("GenerateReport: %w", err)
	}
	writeResp, err := evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(config.RegistryAnchorAddress).Bytes(),
		Report:    reportResp,
		GasConfig: &evm.GasConfig{GasLimit: 300000},
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[notary_registry] WriteReport failed: %v", err))
		return "", fmt.Errorf("WriteReport: %w", err)
	}

	txHash := hex.EncodeToString(writeResp.TxHash)
	logger.Info(fmt.Sprintf("[notary_registry] anchored root 0x%x, tx %s", root, txHash))
	return txHash, nil
}

// ═══════════════════════════════════════════════════════════════════
//  Workflow initialization: cron trigger only - this mechanism is explicitly NOT a live query
//  endpoint (see the header comment), so it has no HTTP/log trigger, unlike my-workflow's
//  dual-trigger design.
// ═══════════════════════════════════════════════════════════════════

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	config.applyDefaults()

	scheduleTrigger := cron.Trigger(&cron.Config{Schedule: config.Schedule})

	return cre.Workflow[*Config]{
		cre.Handler(scheduleTrigger, onSchedule),
	}, nil
}

func main() {
	wasm.NewRunner(cre.ParseJSON[Config]).Run(InitWorkflow)
}
