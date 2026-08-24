// sanctions_lists/report.go — the on-chain report encoding, deliberately UNTAGGED.
//
// `main.go` is `//go:build wasip1`, because it needs the CRE runtime. This file needs
// none of it: it is pure ABI shape. Splitting it out is what lets a test running on the
// DEVELOPER'S machine see `snapshotABI` at all.
//
// ⚠️ THAT SPLIT IS THE WHOLE POINT, AND IT WAS PAID FOR. While this lived in `main.go`,
// the arity here and the `abi.decode` in `RegistrySourceAnchor.onReport` could drift
// apart with nothing to catch it: the host-arch `go test` excluded `main.go` by build
// tag, so it compiled, passed, and proved NOTHING about this encoding. A field was added
// to the contract's decode and this Pack kept sending the old shape - every report would
// have reverted on-chain, at a cost measured in a live workflow run.
//
// `report_test.go` now pins the shape against the Solidity signature. Keep both in step.

package main

import "github.com/ethereum/go-ethereum/accounts/abi"

var (
	bytes32Type, _      = abi.NewType("bytes32", "", nil)
	bytes32ArrayType, _ = abi.NewType("bytes32[]", "", nil)
)

var snapshotABI = abi.Arguments{
	{Type: bytes32Type},      // registryId
	{Type: bytes32Type},      // smtRoot
	{Type: bytes32ArrayType}, // leaves
}

// ═══════════════════════════════════════════════════════════════════
//
//	THE POSEIDON SMT ROOT IS NOT COMPUTED YET, AND ZERO IS FAIL-OPEN
//
// ═══════════════════════════════════════════════════════════════════
//
// The second report field is the root of the POSEIDON sparse Merkle tree that
// `withdraw_identity` proves NON-MEMBERSHIP against. It is a DIFFERENT TREE from
// `merkleRoot(leaves)` below, and the two must never be swapped:
//
//	merkleRoot(leaves)  keccak, dense, binary. Cheap on-chain, and what the
//	                    anchor's own inclusion checks use.
//	smtRoot             Poseidon, sparse, keyed. The ONLY one a circuit can
//	                    verify - in-circuit the cost relation inverts and
//	                    keccak becomes the expensive hash.
//
// Publishing zero here is the empty tree, and for an EXCLUSION predicate an empty
// tree admits EVERYONE. That is fail-open: until a real root is published, the
// blacklist term in `withdraw_identity` is satisfied by every prover, including a
// sanctioned one. It matches the 32 batch witnesses, which carry the empty-tree
// zero witness and are valid for ANY key by construction.
//
// ⚠️ THIS IS A BOOTSTRAP STATE, NOT A DESIGN. It is safe only while no withdrawal
// is gated on the predicate. Before the pool relies on it, EITHER publish a real
// root here, OR make the pool reject a zero `blacklistRoot` so an unpublished list
// BLOCKS withdrawals instead of waving them through. Do not leave both open.
//
// ✅ THE BUILDER NOW EXISTS AND IS PROVEN: `smt.go`, with `smt_conformance_test.go`
// checking its root against one a real solarity SparseMerkleTree produced, and the
// Go Poseidon checked against a value the Noir circuit accepted.
//
// 🔴 WHAT IS STILL MISSING IS THE INPUT, NOT THE TREE. The predicate keys on
// `document_identifier(issuing_state, document_number)`, and `ListedSubject` carries
// only a reference, a kind and name parts - no source parser extracts document
// numbers. Publishing a root over the NAME leaves would be worse than this zero: it
// would look published while every exclusion proof still succeeded, because the
// circuit queries keys that tree does not contain.
var smtRootUnpublished = [32]byte{}
