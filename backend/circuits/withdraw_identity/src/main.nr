// Identity-based withdraw circuit - the rescoped P2 port (PP-NOIR-FUSION.md P2 + the 2026-07-24
// "build the identity-based upgrade... using ERC identity standard" directive).
//
// NOT YET nargo-compiled/tested (standing constraint this session: don't run nargo without
// approval - see PP-NOIR-FUSION.md's P1 log for the pattern this repo follows once that approval
// is given: compile, `nargo test`, differential-check against the on-chain reference before
// trusting it for real value). Written against the SAME gadgets that already passed differential
// tests (pp::commitment, pp::lean_imt) plus the new pp::identity_asp (cross-checked in Node against
// the wallet's real derivation, see identity_asp.nr's own test) - not invented from scratch.
//
// PUBLIC I/O pinned to PrivacyPool.sol's ProofLib.WithdrawProof.pubSignals (8 elements, unchanged
// order/count from upstream - the contract does not need to change):
//   [0] new_commitment          [4] state_tree_depth
//   [1] existing_nullifier_hash [5] asp_root       <- now an IDENTITY tree root, not a label tree
//   [2] withdrawn_value         [6] asp_tree_depth
//   [3] state_root              [7] context
//
// `context` is a plain pass-through public signal - PrivacyPool.sol independently recomputes and
// checks it (keccak256(abi.encode(withdrawal, scope)) % SNARK_SCALAR_FIELD, see ProofLib.context()
// and PrivacyPool.validWithdrawal) against this same value, so the circuit doesn't need to
// constrain it against anything else internally; it only needs to be bound as a public input,
// which `pub` on a Noir main() parameter already guarantees regardless of whether the body
// references it.
use pp::commitment::commitment_hasher;
use pp::identity_asp::identity_asp_membership;
use pp::lean_imt::lean_imt_inclusion;
use pp::smt::smt_verifier_full;

/// SMT depth of the revocation registry. MUST equal RevocationRegistry's constructor `treeHeight_`
/// and the wallet's REVOCATION_TREE_DEPTH. A mismatch fails every proof with no useful diagnostic.
global REVOCATION_TREE_DEPTH: u32 = 20;

/// `fnc = 1` selects EXCLUSION in smt_verifier_full. Named because passing 0 here would silently
/// prove the opposite of what this circuit needs - that the identity IS revoked.
global SMT_EXCLUSION: u1 = 1;

fn main(
    new_commitment: pub Field,
    existing_nullifier_hash: pub Field,
    withdrawn_value: pub Field,
    state_root: pub Field,
    state_tree_depth: pub Field,
    asp_root: pub Field,
    asp_tree_depth: pub Field,
    context: pub Field,
    // Root of the revocation registry this proof asserts non-membership of. PrivacyPool checks it
    // against RevocationRegistry.isValidRoot, so a stale or invented root is rejected on-chain.
    revocation_root: pub Field,
    // The existing note being spent.
    value: Field,
    label: Field,
    nullifier: Field,
    secret: Field,
    state_leaf_index: Field,
    state_siblings: [Field; 32],
    // The change note (remainder after withdrawal) - a fresh commitment, spendable later the same
    // way. `label` carries over unchanged (it still identifies the deposit lineage for the state
    // tree / any future ragequit on this same original deposit); only the nullifier/secret pair is
    // re-derived per withdrawal index, per the wallet's withdrawalSecrets() convention.
    out_nullifier: Field,
    out_secret: Field,
    // Identity-based ASP membership (the actual upgrade) - see pp/src/identity_asp.nr.
    sk_identity: Field,
    asp_leaf_index: Field,
    asp_siblings: [Field; 32],
    // Non-inclusion witness for the revocation registry, straight from its own getProof(). The
    // registry is a @solarity SparseMerkleTree; `revocation_is_old0` is the INVERSE of solarity's
    // `auxExistence` (see the wallet's src/pp/revocation.ts, where the conversion is done).
    revocation_old_key: Field,
    revocation_old_value: Field,
    revocation_is_old0: u1,
    revocation_siblings: [Field; REVOCATION_TREE_DEPTH],
) {
    // 1. Existing note: reconstruct its commitment + nullifier hash, and prove membership in the
    // PP state tree at `state_root`. `state_tree_depth` is a public signal (contract-selectable,
    // capped at MAX_TREE_DEPTH=32 on-chain, see State.sol) taken directly as the actual depth - a
    // false depth simply fails to reconstruct `state_root`, so no separate range check is needed
    // beyond lean_imt_inclusion's own `assert(actual_depth <= MAX_DEPTH)`.
    let existing = commitment_hasher(value, label, nullifier, secret);
    assert(existing.nullifier_hash == existing_nullifier_hash);
    let computed_state_root = lean_imt_inclusion(
        existing.commitment,
        state_leaf_index,
        state_siblings,
        state_tree_depth as u32,
    );
    assert(computed_state_root == state_root);

    // 2. Value conservation: existing value == withdrawn + carried into the change note.
    // Range-checked to 128 bits (ample for token amounts) via to_le_bits' own constraint, so the
    // subtraction below can't wrap the ~254-bit field and hide a fabricated balance.
    let _value_bits: [u1; 128] = value.to_le_bits();
    let _withdrawn_bits: [u1; 128] = withdrawn_value.to_le_bits();
    let new_value = value - withdrawn_value;
    let _new_value_bits: [u1; 128] = new_value.to_le_bits();

    // 3. Change note commitment.
    let out = commitment_hasher(new_value, label, out_nullifier, out_secret);
    assert(out.commitment == new_commitment);

    // 4. Identity-based ASP membership: the withdrawer must know an sk_identity whose holder_root
    // (Poseidon(pubkey(sk_identity)), the SAME value rarime's HolderStateKeeper anchors) is
    // included in the identity ASP tree at `asp_root`. This is the actual upgrade over upstream's
    // per-label membership check - see pp/src/identity_asp.nr for the full rationale.
    let membership = identity_asp_membership(
        sk_identity,
        asp_root,
        asp_leaf_index,
        asp_siblings,
        asp_tree_depth as u32,
    );

    // 5. NOT REVOKED. The withdrawer must show their holder_root is ABSENT from the revocation
    // registry at `revocation_root`. This is the second half of TODO.md sec. 2.5: admission alone
    // is no longer sufficient, and revocation is the only thing that can withdraw it.
    //
    // The key is `membership.holder_root` - the SAME value just proven to be an ASP member - not a
    // free input. Letting the prover choose the key would make this vacuous: they would simply
    // prove non-revocation of an identity that was never revoked and withdraw as someone else.
    //
    // smt_verifier_full's own `assert_keys_ok` additionally makes it impossible to claim exclusion
    // while pointing at the very key being queried, so a revoked identity cannot pass by supplying
    // itself as the occupying leaf.
    let not_revoked = smt_verifier_full::<REVOCATION_TREE_DEPTH>(
        revocation_root,
        membership.holder_root,
        0,
        revocation_old_key,
        revocation_old_value,
        revocation_is_old0,
        SMT_EXCLUSION,
        revocation_siblings,
    );
    assert(not_revoked == 1, "identity is revoked, or the non-inclusion witness is invalid");
}
