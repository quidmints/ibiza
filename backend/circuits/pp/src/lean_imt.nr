// LeanIMT inclusion proof - faithful port of PP's merkleTree.circom (LeanIMTInclusionProof).
// This is the ONE gadget with no drop-in Noir library, so it's a line-for-line translation of the
// Circom, kept algebraic (no `if`) to mirror the original constraints exactly.
//
// LeanIMT rule (the part a generic Merkle gadget gets wrong): when a node's sibling is EMPTY (== 0),
// the node is carried up UNCHANGED; otherwise the node is Poseidon2 of the ordered (left,right) pair.
// Circom: nodes[i+1] = (nodes[i] - h) * siblingIsEmpty + h.
//
// Hashing is circomlib-Poseidon via noir-lang/poseidon - must match the on-chain @zk-kit/lean-imt.sol
// (which hashes with PoseidonT3 / circomlib). DEV-MACHINE TODO: differential-test this against
// lean-imt.sol for random (leaf, index, siblings, depth) before trusting it for real value.
//
// CONFIRMED on dev machine (nargo 1.0.0-beta.1, poseidon tag v0.1.0): import path is
// `poseidon::poseidon::bn254`, NOT `poseidon::bn254` (see commitment.nr for detail).
use poseidon::poseidon::bn254;

pub fn lean_imt_inclusion<let MAX_DEPTH: u32>(
    leaf: Field,
    leaf_index: Field,
    siblings: [Field; MAX_DEPTH],
    actual_depth: u32,
) -> Field {
    // actualDepth is only a bound in the Circom (|siblings| <= actualDepth <= maxDepth).
    assert(actual_depth <= MAX_DEPTH);

    // Path bits of the leaf index (LSB = level 0), as in Circom's Num2Bits(maxDepth).
    let indices: [u1; MAX_DEPTH] = leaf_index.to_le_bits();

    let mut node = leaf;
    for i in 0..MAX_DEPTH {
        let sibling = siblings[i];
        let bit = indices[i] as Field; // 0 => current node is the left child, 1 => the right child

        // Order the pair by the path bit (algebraic switcher, == Circom's DualMux).
        let left = node + bit * (sibling - node); // bit 0 => node,    bit 1 => sibling
        let right = sibling + bit * (node - sibling); // bit 0 => sibling, bit 1 => node

        let hashed = bn254::hash_2([left, right]);

        // Carry-up when the sibling is empty (== 0), else take the hash. == Circom line 74.
        let sibling_is_empty = (sibling == 0) as Field;
        node = (node - hashed) * sibling_is_empty + hashed;
    }

    node
}

// Differential test vector, cross-checked against @zk-kit/lean-imt.sol + poseidon-solidity on
// 2026-07-01 (see PP-NOIR-FUSION.md P0 log). Tree: insert(1), insert(2), insert(3) (3 leaves, depth
// 2). h01 = PoseidonT3.hash([1,2]); root = PoseidonT3.hash([h01,3]); LeanIMT.sol's `root()` was
// asserted equal to this hand-derived root on-chain before taking these numbers.
#[test]
fn test_matches_lean_imt_sol_three_leaves() {
    let leaf: Field = 1;
    let sibling_l0: Field = 2; // L1
    let sibling_l1: Field = 3; // L2 (carried up at level 0, so it's node1 = L2 itself)
    let expected_root: Field = 13816780880028945690020260331303642730075999758909899334839547418969502592169;

    let root = lean_imt_inclusion(leaf, 0, [sibling_l0, sibling_l1], 2);
    assert(root == expected_root);
}
