//go:build wasip1

// ofac_sdn/main.go — OFAC Specially Designated Nationals (SDN) list CRE workflow.
//
// The sanctions half of TODO.md sec. 2.5's closed predicate set. Cron-triggered, it fetches the
// U.S. Treasury's published SDN export, parses it into a leaf set, builds a keccak Merkle tree and
// anchors the root on-chain via RegistrySourceAnchor.publishSnapshot — the same ERC-7812 evidence
// registry every other root in this fusion anchors into. Structurally a sibling of
// notary_registry/main.go; read that first, this deliberately mirrors it rather than inventing a
// second shape.
//
// WHY CRE AND NOT A RELAYER SCRIPT. Every DON node fetches the SAME export independently and must
// produce a BYTE-IDENTICAL result (http.SendRequest + cre.ConsensusIdenticalAggregation) before a
// report is generated. That is the property that makes this an ANCHORED EXTERNAL AUTHORITY rather
// than an operator's opinion, which is the whole justification for admitting "listed on OFAC SDN"
// into a closed predicate set that is otherwise deliberately tiny. A single relayer could
// substitute a tampered snapshot and nobody could tell; this cannot.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
// WHAT THIS WORKFLOW DOES NOT DO, AND MUST NOT BE ASSUMED TO DO.
//
// It anchors "here is the SDN list at time T". It does NOT revoke anybody, and it CANNOT: the
// missing step is the link from "person P is on the list" to "holderRoot H belongs to person P".
// That mapping does not exist on-chain by construction — the entire point of the identity ASP is
// that a holderRoot reveals nothing about who its owner is.
//
// So an OFAC hit cannot be turned into a revocation by this workflow alone. Whoever performed the
// original identity check is the only party holding that correspondence, and any design that
// resolves it has to answer a privacy question this file cannot: WHO is allowed to learn that
// holderRoot H is person P, and what stops them asserting it falsely? Deliberately left open here
// rather than papered over with a plausible-looking mechanism — see TODO.md sec. 2.5.
//
// The honest shape of the remaining work is an ATTESTER CONTRACT holding the
// RevocationRegistry's sanctions predicate, which accepts a proof that some identity is in the
// anchored set and revokes on that basis. Deploy it as a CONTRACT, never an EOA: the registry's
// attester is immutable, so a contract's internal key rotation is the only way to recover from a
// key compromise (TODO.md sec. 2.5a).
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// OPERATOR TODO before deploying:
//  1. Config.SDNEndpointURL must be the exact published export URL. Treasury publishes several
//     formats (SDN.XML, SDN.CSV, and the consolidated variants); the XML schema below is written
//     against the documented sdnList/sdnEntry shape but has NOT been checked against a real
//     download. Confirm before trusting parse results — the same caveat notary_registry carries.
//  2. RegistrySourceAnchor's REGISTRY_POSTMAN role must be granted to the address this workflow's
//     WriteReport resolves to (see RegistrySourceAnchor.onReport's Forwarder-trust note).
//  3. Decide the linkage question above BEFORE wiring any attester. Anchoring the list is safe and
//     useful on its own; revoking on it is not, until that is answered.
//
// NOT BUILT OR SIMULATED against a live DON — no deployed environment exists yet. It compiles:
//   GOOS=wasip1 GOARCH=wasm go build ./...
// Simulate: cre workflow simulate ofac_sdn --trigger-index 0
package main

import (
	"encoding/xml"
	"fmt"
	"log/slog"
	"sort"
	"strings"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"
	"github.com/ethereum/go-ethereum/crypto"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

type Config struct {
	ChainSelectorName     string `json:"chainSelectorName"`
	RegistryAnchorAddress string `json:"registryAnchorAddress"`

	// See OPERATOR TODO #1 — left for the deployer, not guessed.
	SDNEndpointURL string `json:"sdnEndpointUrl"`

	// Standard 5-field cron. Defaults to daily: Treasury republishes the list on its own
	// schedule, so polling more often than it changes buys nothing and only widens the window in
	// which nodes could observe different bytes mid-publish.
	Schedule string `json:"schedule"`
}

func (c *Config) applyDefaults() {
	if c.Schedule == "" {
		c.Schedule = "0 0 * * *" // daily
	}
}

// keccak256("OFAC_SDN") — the registryId RegistrySourceAnchor keys these snapshots under. A
// constant rather than config, because it identifies the LIST, not a deployment.
var registryID = crypto.Keccak256Hash([]byte("OFAC_SDN"))

// ═══════════════════════════════════════════════════════════════════
//  SDN schema (per Treasury's documented sdnList shape - see OPERATOR TODO #1)
// ═══════════════════════════════════════════════════════════════════

// SDNEntry is one designated party. `uid` is Treasury's own stable identifier and is what makes a
// leaf reproducible across nodes and across refreshes; names alone are not stable enough to key on
// (transliteration and alias ordering both vary).
type SDNEntry struct {
	UID       string `xml:"uid"`
	FirstName string `xml:"firstName"`
	LastName  string `xml:"lastName"`
	SDNType   string `xml:"sdnType"`
}

type SDNList struct {
	XMLName xml.Name   `xml:"sdnList"`
	Entries []SDNEntry `xml:"sdnEntry"`
}

// ═══════════════════════════════════════════════════════════════════
//  Fetch + parse (node mode - every DON node runs this independently)
// ═══════════════════════════════════════════════════════════════════

func fetchAndParse(sr *http.SendRequester, url string) ([]SDNEntry, error) {
	resp, err := sr.SendRequest(&http.Request{Url: url, Method: "GET"}).Await()
	if err != nil {
		return nil, fmt.Errorf("SDN fetch: %w", err)
	}

	var list SDNList
	if err := xml.Unmarshal(resp.Body, &list); err != nil {
		return nil, fmt.Errorf("SDN parse: %w", err)
	}
	if len(list.Entries) == 0 {
		// An empty list is far more likely to be a fetch/schema failure than a genuinely empty
		// SDN list, and publishing an empty root would silently clear the anchored set.
		return nil, fmt.Errorf("SDN parse produced 0 entries - refusing to publish an empty snapshot")
	}

	// DETERMINISM IS THE WHOLE POINT: ConsensusIdenticalAggregation compares node outputs
	// byte-for-byte, so any source-order variation between nodes would prevent consensus rather
	// than produce a wrong answer. Sorting by Treasury's stable uid removes that class entirely.
	sort.Slice(list.Entries, func(i, j int) bool { return list.Entries[i].UID < list.Entries[j].UID })

	return list.Entries, nil
}

// leafHash keys a leaf on the STABLE uid, with the name folded in so a leaf commits to the
// identity it claims to describe rather than just to a row number.
func leafHash(e SDNEntry) [32]byte {
	name := strings.ToUpper(strings.TrimSpace(e.LastName + "<<" + e.FirstName))
	return crypto.Keccak256Hash([]byte(e.UID + "|" + name + "|" + e.SDNType))
}

// merkleRoot over sorted-pair keccak, matching notary_registry so both lists verify identically.
func merkleRoot(leaves [][32]byte) [32]byte {
	if len(leaves) == 0 {
		return [32]byte{}
	}
	level := make([][32]byte, len(leaves))
	copy(level, leaves)

	for len(level) > 1 {
		next := make([][32]byte, 0, (len(level)+1)/2)
		for i := 0; i < len(level); i += 2 {
			if i+1 == len(level) {
				// Odd node carries up unchanged - the same rule the LeanIMT trees in this fusion
				// use, so the shape is familiar rather than a second convention.
				next = append(next, level[i])
				continue
			}
			next = append(next, hashSortedPair(level[i], level[i+1]))
		}
		level = next
	}
	return level[0]
}

// hashSortedPair orders the pair before hashing so a proof does not need to carry direction bits.
func hashSortedPair(a, b [32]byte) [32]byte {
	if string(a[:]) > string(b[:]) {
		a, b = b, a
	}
	return crypto.Keccak256Hash(append(a[:], b[:]...))
}

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

func onSchedule(config *Config, runtime cre.Runtime, _ *cron.Payload) (string, error) {
	logger := runtime.Logger()

	chainSel, err := evm.ChainSelectorFromName(config.ChainSelectorName)
	if err != nil {
		return "", fmt.Errorf("unknown chain %s: %w", config.ChainSelectorName, err)
	}

	if config.SDNEndpointURL == "" {
		return "", fmt.Errorf("sdnEndpointUrl is empty - see OPERATOR TODO #1")
	}

	httpClient := &http.Client{}

	entriesPromise := http.SendRequest(config, runtime, httpClient,
		func(cfg *Config, lg *slog.Logger, sr *http.SendRequester) (*[]SDNEntry, error) {
			out, err := fetchAndParse(sr, cfg.SDNEndpointURL)
			if err != nil {
				return nil, err
			}
			return &out, nil
		},
		cre.ConsensusIdenticalAggregation[*[]SDNEntry](),
	)

	entriesPtr, err := entriesPromise.Await()
	if err != nil || entriesPtr == nil {
		logger.Error(fmt.Sprintf("[ofac_sdn] fetch/consensus failed: %v", err))
		return "", fmt.Errorf("fetch/consensus failed: %w", err)
	}

	leaves := make([][32]byte, 0, len(*entriesPtr))
	for _, e := range *entriesPtr {
		leaves = append(leaves, leafHash(e))
	}
	root := merkleRoot(leaves)

	logger.Info(fmt.Sprintf("[ofac_sdn] %d entries, root %s", len(leaves), common.BytesToHash(root[:]).Hex()))

	payload, err := snapshotABI.Pack(registryID, leaves)
	if err != nil {
		return "", fmt.Errorf("abi pack: %w", err)
	}

	reportResp, err := runtime.GenerateReport(&cre.ReportRequest{
		EncodedPayload: payload,
		EncoderName:    "evm",
		SigningAlgo:    "ecdsa",
		HashingAlgo:    "keccak256",
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[ofac_sdn] GenerateReport failed: %v", err))
		return "", fmt.Errorf("GenerateReport: %w", err)
	}

	evmClient := &evm.Client{ChainSelector: chainSel}
	writeResp, err := evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(config.RegistryAnchorAddress).Bytes(),
		Report:    reportResp,
		GasConfig: &evm.GasConfig{GasLimit: 300000},
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[ofac_sdn] WriteReport failed: %v", err))
		return "", fmt.Errorf("WriteReport: %w", err)
	}

	return fmt.Sprintf("ofac_sdn anchored %d entries, tx %x", len(leaves), writeResp.TxHash), nil
}

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	config.applyDefaults()

	scheduleTrigger := cron.Trigger(&cron.Config{Schedule: config.Schedule})
	return cre.Workflow[*Config]{cre.Handler(scheduleTrigger, onSchedule)}, nil
}

func main() {
	wasm.NewRunner(cre.ParseJSON[Config]).Run(InitWorkflow)
}
