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
func leafHash(r NotaryRecordXML) [32]byte {
	return crypto.Keccak256Hash([]byte(r.RegistrationNumber), []byte(r.FullName), []byte(r.Region), []byte(r.Status))
}

// activeLeaves keeps only ACTIVE notaries and hashes each to a leaf.
//
// THE DANGEROUS DIRECTION IS UNDER-COUNTING. A snapshot with EXTRA notaries would be caught by
// anyone comparing against the register; a snapshot MISSING real ones silently removes people's
// ability to act, which is censorship by parse error rather than by decision. `onSchedule` refuses
// to publish when this returns nothing, so total failure is loud - but a PARTIAL match is not, and
// exact-string "active" is what makes that possible (see the status tests).
func activeLeaves(records []NotaryRecordXML) [][32]byte {
	leaves := make([][32]byte, 0, len(records))
	for _, r := range records {
		if r.Status != "active" {
			continue
		}
		leaves = append(leaves, leafHash(r))
	}
	return leaves
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
