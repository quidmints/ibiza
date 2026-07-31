// Pure registry logic: decode an export, keep the active notaries, build the Merkle root.
//
// NO `//go:build wasip1` TAG, DELIBERATELY. `main.go` is WASM-only because it links the CRE runtime,
// which meant none of the logic below could be tested on a host machine - and this is exactly the
// logic that needs testing. sec. 2.15a's own warning is that scrapers rot: a portal changes its
// schema and the parse silently yields a different set. `cre.ConsensusIdenticalAggregation` makes
// every DON node agree with every other; it CANNOT make them agree CORRECTLY, so a parser that
// quietly drops records reaches consensus on a wrong answer. Consensus covers the FETCH, not the
// MEANING - and the meaning lives here.
//
// Nothing in this file touches the network, the CRE runtime, or a chain: stdlib plus keccak.
package main

import (
	"archive/zip"
	"bytes"
	"encoding/xml"
	"fmt"
	"sort"
	"strings"

	"github.com/ethereum/go-ethereum/crypto"
)

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
func parseRegistryExport(body []byte) ([]NotaryRecordXML, error) {
	xmlBytes := body
	if len(body) >= 2 && body[0] == 0x50 && body[1] == 0x4b { // "PK" zip magic
		zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
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
//
//	Merkle tree: keccak, OpenZeppelin MerkleProof-compatible sorted-pair hashing
//
//	keccak (not Poseidon) is deliberate: this tree isn't consumed by a ZK circuit yet - the
//	notary-credential binding circuit (proving "I am the identity behind this specific registry
//	entry") is explicit future work, deferred alongside the identity-based ASP design (see
//	pp/src/identity_asp.nr's own header and PP-NOIR-FUSION.md). A future ZK-consuming version of
//	this tree would need Poseidon+LeanIMT at that point, mirroring identity_asp.nr - not now.
//	keccak + OpenZeppelin's MerkleProof (already vendored, lib/openzeppelin-contracts) is the
//	simplest correct choice for a list that's on-chain-verifiable but not yet ZK-provable, and
//	matches how most on-chain sanctions/allow-list oracles (the OFAC-list pattern referenced)
//	actually work.
//
// ═══════════════════════════════════════════════════════════════════
// leafHash commits to all four fields UNAMBIGUOUSLY.
//
// WAS keccak(reg || name || region || status) - a bare concatenation with no separator, so reg "12"
// with name "3X" hashed identically to reg "123" with name "X" (sec. 2.18ao). Unreachable with
// Ukrainian data, because registration numbers are numeric and names are not - but that is an
// argument about the DATA, not about the construction, and it stops holding the moment a
// jurisdiction issues alphanumeric registration numbers, which task #12 makes likely.
//
// Hashing each field FIRST makes every part fixed-width (32 bytes), so no boundary is ambiguous and
// no delimiter has to be forbidden from appearing inside a name. `notaryDataHash` in
// TitleLedger.registerNotary is this value; both sides must change together, and both did.
func leafHash(r NotaryRecordXML) [32]byte {
	return crypto.Keccak256Hash(
		crypto.Keccak256([]byte(r.RegistrationNumber)),
		crypto.Keccak256([]byte(r.FullName)),
		crypto.Keccak256([]byte(r.Region)),
		crypto.Keccak256([]byte(normalizeStatus(r.Status))), // normalised, so casing cannot fork the leaf
	)
}

// ---------------------------------------------------------------------------------------------
//  STATUS VOCABULARY - the translation layer.
//
//  A register writes statuses IN ITS OWN LANGUAGE. Ukraine's does not have to say "active", and
//  Iran's certainly will not. Treating the English words as universal is the same mistake as
//  treating one country's SOD layout as universal, and it fails the same way: silently, by dropping
//  people. So the mapping from a register's own vocabulary to protocol meaning is DECLARED PER
//  JURISDICTION and is part of the scraping spec, not an implementation detail.
//
//  WHY NOT TRANSLATE AT RUNTIME. Machine translation inside a DON workflow cannot reach consensus -
//  every node must produce a byte-identical result, and a translation service is neither
//  deterministic nor identical across nodes. The mapping has to be a fixed, reviewable table that
//  ships with the workflow.
// ---------------------------------------------------------------------------------------------

// The registry this deployment scrapes. ONE JURISDICTION PER DEPLOYMENT, deliberately: a single
// root mixing several countries' notaries would let membership in "some register" stand in for
// authority in a SPECIFIC one, which is not a property any relying party could check (task #12).
const defaultRegistryKey = "UA_NOTARY_REGISTRY"

func registryIDFor(registryKey string) [32]byte {
	return crypto.Keccak256Hash([]byte(registryKey))
}

type statusMeaning int

const (
	meaningActive statusMeaning = iota + 1
	meaningInactive
)

// statusVocabularies maps registryKey -> (the register's own status string -> what it MEANS).
// Keys are compared after `normalizeStatus`, so entries are lowercase and untrimmed variants are
// handled for free. `strings.ToLower` is Unicode-aware, so Cyrillic and Arabic-script entries fold
// correctly.
//
// UNPOPULATED ENTRIES ARE NOT A BUG, THEY ARE THE POINT. An unrecognised status refuses the whole
// snapshot (see activeLeaves), so a jurisdiction whose vocabulary has not been declared cannot
// publish a partially-correct one. Adding a country means adding a table entry here, taken from a
// REAL export - never guessed.
var statusVocabularies = map[string]map[string]statusMeaning{
	// The three values the export was assumed to emit - this workflow's XML type documents them.
	//
	// THE UKRAINIAN-LANGUAGE ENTRIES ARE DELIBERATELY ABSENT. I do not know what the Ministry of
	// Justice register actually writes, and inventing plausible Cyrillic here would be exactly the
	// fabrication sec. 2.18k refuses: a wrong mapping either admits nobody (loud, recoverable) or
	// maps a status to the wrong meaning (silent, and it decides who may act). Until a real export
	// is read, an unknown status correctly refuses to publish.
	"UA_NOTARY_REGISTRY": {
		"active":     meaningActive,
		"suspended":  meaningInactive,
		"terminated": meaningInactive,
	},
}

// normalizeStatus trims and lowercases, so a portal migration that starts emitting "Active" does not
// change what a record MEANS. Unicode-aware, so it folds non-Latin scripts too.
func normalizeStatus(s string) string {
	return strings.ToLower(strings.TrimSpace(s))
}

// activeLeaves keeps only ACTIVE notaries and hashes each to a leaf.
//
// THE DANGEROUS DIRECTION IS UNDER-COUNTING. A snapshot with EXTRA notaries would be caught by
// anyone comparing against the register; a snapshot MISSING real ones silently removes people's
// ability to act, which is censorship by parse error rather than by decision. `onSchedule` refuses
// to publish when this returns nothing, so total failure is loud - but a PARTIAL match is not, and
// exact-string "active" is what makes that possible (see the status tests).
// activeLeaves keeps only ACTIVE notaries, hashes each to a leaf, and DEDUPLICATES.
//
// AN UNKNOWN STATUS IS AN ERROR, NOT A SKIP - the fix for the worst defect in sec. 2.18ao. The old
// code compared exactly against "active", so a migrated portal emitting "Active" dropped those
// notaries with NO error at all. Total failure was loud (onSchedule refuses an empty root) but a
// PARTIAL change was silent, and mixed casing is exactly how a partial change arrives.
//
// UNDER-COUNTING IS THE DANGEROUS DIRECTION. Extra notaries would be caught by anyone comparing the
// snapshot against the public register; MISSING ones silently strip real people of the ability to
// act, and nothing downstream can distinguish "not a notary" from "the parser dropped you".
//
// CASE-FOLDING ALONE WOULD HAVE BEEN A GUESS. If the register's real vocabulary turns out to be
// Ukrainian, folding ASCII case admits nobody extra and hides that the mapping was never verified.
// So anything outside the known set REFUSES THE WHOLE SNAPSHOT rather than quietly excluding one
// person - which is the difference between a scraper that rots loudly and one that rots silently.
//
// DEDUPLICATION is here because RegistrySourceAnchor requires STRICTLY ascending leaves: sorting
// duplicates yields equal neighbours, not strict ascent, so one duplicated row upstream used to make
// the entire snapshot unpublishable. Safe, but a liveness failure - every notary in the country
// stops being refreshed over a registrar's data-entry slip.
func activeLeaves(records []NotaryRecordXML, registryKey string) ([][32]byte, error) {
	vocabulary, ok := statusVocabularies[registryKey]
	if !ok {
		return nil, fmt.Errorf(
			"no status vocabulary declared for registry %q - a register's statuses are in its own "+
				"language and must be translated in statusVocabularies before it can publish",
			registryKey)
	}

	leaves := make([][32]byte, 0, len(records))
	seen := make(map[[32]byte]struct{}, len(records))

	for _, r := range records {
		switch vocabulary[normalizeStatus(r.Status)] {
		case meaningActive:
			leaf := leafHash(r)
			if _, dup := seen[leaf]; dup {
				continue
			}
			seen[leaf] = struct{}{}
			leaves = append(leaves, leaf)
		case meaningInactive:
			continue
		default:
			return nil, fmt.Errorf(
				"unknown status %q for registration %q in registry %q - refusing to publish a "+
					"snapshot that would silently omit this notary; declare it in statusVocabularies",
				r.Status, r.RegistrationNumber, registryKey)
		}
	}
	return leaves, nil
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
