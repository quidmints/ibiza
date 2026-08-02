//go:build wasip1

// sanctions_lists/main.go — the CRE workflow that anchors a published sanctions list.
//
// The sanctions half of TODO.md sec. 2.5's closed predicate set. Cron-triggered, it fetches ONE
// declared list's published export, decodes it into a leaf set, builds a keccak Merkle tree and
// anchors the root on-chain via RegistrySourceAnchor.publishSnapshot — the same ERC-7812 evidence
// registry every other root in this fusion anchors into. Structurally a sibling of
// notary_registry/main.go; read that first, this deliberately mirrors it rather than inventing a
// second shape.
//
// ONE LIST PER DEPLOYMENT. `Config.RegistryKey` names which — `OFAC_SDN` (US), `UK_OFSI_CONSOLIDATED`
// (UK), `UN_SC_CONSOLIDATED` (UN). Everything jurisdiction-specific is declared in `sources.go`;
// this file is the same for all of them. Two lists in one root would let membership in "some
// sanctions list" stand in for designation under a SPECIFIC legal regime, which no relying party
// could check — the same reasoning `notary_registry` uses for one jurisdiction per deployment.
//
// WHY CRE AND NOT A RELAYER SCRIPT. Every DON node fetches the SAME export independently and must
// produce a BYTE-IDENTICAL result (http.SendRequest + cre.ConsensusIdenticalAggregation) before a
// report is generated. That is the property that makes this an ANCHORED EXTERNAL AUTHORITY rather
// than an operator's opinion, which is the whole justification for admitting "listed by an
// authority" into a closed predicate set that is otherwise deliberately tiny. A single relayer could
// substitute a tampered snapshot and nobody could tell; this cannot. What consensus does NOT cover
// is whether the DECODER is right — see sources.go, and its tests.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────
// WHAT THIS WORKFLOW DOES NOT DO, AND MUST NOT BE ASSUMED TO DO.
//
// It anchors "here is list L at time T". It does NOT revoke anybody, and it CANNOT: the missing
// step is the link from "person P is on the list" to "holderRoot H belongs to person P". That
// mapping does not exist on-chain by construction — the entire point of the identity ASP is that a
// holderRoot reveals nothing about who its owner is.
//
// So a sanctions hit cannot be turned into a revocation by this workflow alone. Whoever performed
// the original identity check is the only party holding that correspondence, and any design that
// resolves it has to answer a privacy question this file cannot: WHO is allowed to learn that
// holderRoot H is person P, and what stops them asserting it falsely? Deliberately left open here
// rather than papered over with a plausible-looking mechanism — see TODO.md sec. 2.5.
//
// The honest shape of the remaining work is an ATTESTER CONTRACT holding the RevocationRegistry's
// sanctions predicate, which accepts a proof that some identity is in the anchored set and revokes
// on that basis. Deploy it as a CONTRACT, never an EOA: the registry's attester is immutable, so a
// contract's internal key rotation is the only way to recover from a key compromise (sec. 2.5a).
//
// AND WHAT IT CANNOT PROVE EVEN THEN: all three declared lists are `membershipMeansListed`, so
// DELISTING is an absence claim and a keccak Merkle root cannot prove absence (sec. 2.18bp). An
// attester built on this can revoke on a hit; nothing here can reinstate on a removal. That is a
// property of what the authorities publish, not of our design, and it must not be papered over.
// ─────────────────────────────────────────────────────────────────────────────────────────────
//
// OPERATOR TODO before deploying:
//  1. Config.RegistryKey must name a declared source, and Config.ExportURL must be that source's
//     published export. `SourceSpec.PublishedAt` records the URL each declaration was read from —
//     compare the two rather than assuming, since a publisher's URL scheme is not part of any
//     guarantee.
//  2. RegistrySourceAnchor's REGISTRY_POSTMAN role must be granted to the address this workflow's
//     WriteReport resolves to (see RegistrySourceAnchor.onReport's Forwarder-trust note), and a
//     workflow version must be PINNED AND ACTIVE or `_publishSnapshot` reverts NoActiveWorkflow.
//  3. Decide the linkage question above BEFORE wiring any attester. Anchoring a list is safe and
//     useful on its own; revoking on it is not, until that is answered.
//
// NOT BUILT OR SIMULATED against a live DON — no deployed environment exists yet. It compiles:
//
//	GOOS=wasip1 GOARCH=wasm go build ./...
//
// and the logic it calls is host-testable: `go test ./...`.
// Simulate: cre workflow simulate sanctions_lists --trigger-index 0
package main

import (
	"fmt"
	"log/slog"

	"github.com/ethereum/go-ethereum/accounts/abi"
	"github.com/ethereum/go-ethereum/common"

	"github.com/smartcontractkit/cre-sdk-go/capabilities/blockchain/evm"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/networking/http"
	"github.com/smartcontractkit/cre-sdk-go/capabilities/scheduler/cron"
	"github.com/smartcontractkit/cre-sdk-go/cre"
	"github.com/smartcontractkit/cre-sdk-go/cre/wasm"
)

type Config struct {
	ChainSelectorName     string `json:"chainSelectorName"`
	RegistryAnchorAddress string `json:"registryAnchorAddress"`

	// Which declared list this deployment anchors. See `sources` in sources.go.
	RegistryKey string `json:"registryKey"`

	// The published export URL for that list — see OPERATOR TODO #1.
	ExportURL string `json:"exportUrl"`

	// Standard 5-field cron. Defaults to daily: the authorities republish on their own schedules, so
	// polling more often than they change buys nothing and only widens the window in which nodes
	// could observe different bytes mid-publish.
	Schedule string `json:"schedule"`
}

func (c *Config) applyDefaults() {
	if c.Schedule == "" {
		c.Schedule = "0 0 * * *" // daily
	}
}

// ═══════════════════════════════════════════════════════════════════
//  Fetch (node mode - every DON node runs this independently)
// ═══════════════════════════════════════════════════════════════════

// fetchAndDecode is the only part of the pipeline that touches the network; everything it hands on
// lives in sources.go and is tested on the host.
//
// NOTHING RE-SORTS THE DECODED ROWS. Consensus requires every node to produce identical output from
// identical bytes, and document order already is that — a re-sort would add a comparison that must
// itself be total (the version this replaced sorted by uid with `sort.Slice`, which is not stable,
// so equal keys ordered arbitrarily). The ordering that actually matters is over LEAVES, and
// `snapshotLeaves` owns it because the CONTRACT requires it.
func fetchAndDecode(sr *http.SendRequester, registryKey, url string) ([]ListedSubject, error) {
	resp, err := sr.SendRequest(&http.Request{Url: url, Method: "GET"}).Await()
	if err != nil {
		return nil, fmt.Errorf("%s fetch: %w", registryKey, err)
	}
	return decodeSubjects(registryKey, resp.Body)
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

	// Resolve the source BEFORE fetching: an undeclared registry key must fail without spending a
	// DON-wide HTTP round trip, and the error names the omission rather than a parse failure
	// downstream of it.
	spec, err := sourceFor(config.RegistryKey)
	if err != nil {
		return "", err
	}
	if config.ExportURL == "" {
		return "", fmt.Errorf("exportUrl is empty for %s - see OPERATOR TODO #1 (published at %s)",
			spec.Key, spec.PublishedAt)
	}

	httpClient := &http.Client{}

	subjectsPromise := http.SendRequest(config, runtime, httpClient,
		func(cfg *Config, lg *slog.Logger, sr *http.SendRequester) (*[]ListedSubject, error) {
			out, err := fetchAndDecode(sr, cfg.RegistryKey, cfg.ExportURL)
			if err != nil {
				return nil, err
			}
			return &out, nil
		},
		cre.ConsensusIdenticalAggregation[*[]ListedSubject](),
	)

	subjectsPtr, err := subjectsPromise.Await()
	if err != nil || subjectsPtr == nil {
		logger.Error(fmt.Sprintf("[%s] fetch/consensus failed: %v", spec.Key, err))
		return "", fmt.Errorf("fetch/consensus failed: %w", err)
	}

	leaves := snapshotLeaves(spec.Key, *subjectsPtr)
	root, err := merkleRoot(leaves)
	if err != nil {
		return "", fmt.Errorf("%s root: %w", spec.Key, err)
	}

	registryID := registryIDFor(spec.Key)
	logger.Info(fmt.Sprintf("[%s] %d rows, %d leaves, root %s",
		spec.Key, len(*subjectsPtr), len(leaves), common.BytesToHash(root[:]).Hex()))

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
		logger.Error(fmt.Sprintf("[%s] GenerateReport failed: %v", spec.Key, err))
		return "", fmt.Errorf("GenerateReport: %w", err)
	}

	evmClient := &evm.Client{ChainSelector: chainSel}
	writeResp, err := evmClient.WriteReport(runtime, &evm.WriteCreReportRequest{
		Receiver:  common.HexToAddress(config.RegistryAnchorAddress).Bytes(),
		Report:    reportResp,
		GasConfig: &evm.GasConfig{GasLimit: 300000},
	}).Await()
	if err != nil {
		logger.Error(fmt.Sprintf("[%s] WriteReport failed: %v", spec.Key, err))
		return "", fmt.Errorf("WriteReport: %w", err)
	}

	return fmt.Sprintf("%s anchored %d leaves, tx %x", spec.Key, len(leaves), writeResp.TxHash), nil
}

func InitWorkflow(config *Config, logger *slog.Logger, secretsProvider cre.SecretsProvider) (cre.Workflow[*Config], error) {
	config.applyDefaults()

	scheduleTrigger := cron.Trigger(&cron.Config{Schedule: config.Schedule})
	return cre.Workflow[*Config]{cre.Handler(scheduleTrigger, onSchedule)}, nil
}

func main() {
	wasm.NewRunner(cre.ParseJSON[Config]).Run(InitWorkflow)
}
