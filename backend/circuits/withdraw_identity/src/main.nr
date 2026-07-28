// Identity-based withdraw circuit.
//
// ONE IDENTITY TREE, AND NO sk_identity (TODO.md sec. 2.13k). This circuit previously proved TWO
// separate things about identity: inclusion of `holder_root` in an ASP tree, and non-inclusion of
// that same value in a separate revocation tree. Both collapse into a SINGLE INCLUSION PROOF once
// status lives in the leaf VALUE: `commitment -> 0` means registered and clean, and a non-zero
// value is the revocation predicate. There is no state a revoked identity can prove.
//
// MEASURED: 43,772 -> 24,812 ACIR opcodes, -43%. Two sources - the ASP scalar multiplication
// disappears entirely (~11.8k, since `holder_root` is no longer derived here), and a LeanIMT
// inclusion plus an SMT exclusion (~18.5k combined) become one SMT inclusion (~11.9k).
//
// WHY DROPPING sk_identity IS SOUND. Identity is proven ONCE, at escrow: `escrow_envelope` proves
// `holder_root` derives from `sk_identity`, binds the authenticated MRZ, and IdentityRegistry
// additionally requires that MRZ to be a document already registered through the ICAO-verified
// path. A commitment can therefore only enter the tree backed by a real, uniquely-bound passport.
// By withdrawal time, knowing the escrowed secret IS the proof of clearance - and knowing it
// authorises nothing else, since spending a note still requires that note's own secrets.
//
// PUBLIC I/O pinned to ProofLib.WithdrawProof.pubSignals - SEVEN elements now, down from nine:
//   [0] new_commitment          [4] state_tree_depth
//   [1] existing_nullifier_hash [5] identity_root   <- replaces asp_root AND revocation_root
//   [2] withdrawn_value         [6] context
//   [3] state_root
// `asp_tree_depth` is gone with the LeanIMT identity tree; the SMT depth is FIXED, so there is no
// prover-supplied depth to reason about at all.
//
// `context` is a plain pass-through public signal - PrivacyPool.sol independently recomputes and
// checks it (keccak256(abi.encode(withdrawal, scope)) % SNARK_SCALAR_FIELD) against this same
// value, so the circuit only needs it bound as a public input, which `pub` already guarantees.
use pp::commitment::commitment_hasher;
use pp::envelope::secret_commitment;
use pp::lean_imt::lean_imt_inclusion;
use pp::smt::smt_verifier_full;

/// SMT depth of the identity registry. MUST equal IdentityRegistry's constructor `treeHeight_` and
/// the wallet's IDENTITY_TREE_DEPTH. A mismatch fails every proof with no useful diagnostic.
///
/// 32, not 20: this tree holds EVERY registered identity, not just revoked ones, so it is the large
/// tree. Depth 20 caps at ~1M identities and would be cheaper in-circuit (7,889 vs 11,856 opcodes),
/// but raising a tree's depth later invalidates every proof and forces a migration.
global IDENTITY_TREE_DEPTH: u32 = 32;

/// `fnc = 0` selects INCLUSION in smt_verifier_full. Named because passing 1 here would prove the
/// OPPOSITE - that the identity is absent from the registry - which is what an UNREGISTERED party
/// can prove and a registered one cannot.
global SMT_INCLUSION: u1 = 0;

/// The value a clean identity carries. Non-zero means revoked, and the value IS the predicate.
///
/// This constant is the entire security of the merged design, so the two ways it could be hollow
/// are tested directly in pp/src/smt.nr rather than assumed:
///   - an ABSENT key cannot be proven present with value 0 (else every unregistered party passes)
///   - a leaf holding a NON-ZERO value cannot claim 0 (else revocation is escapable)
global STATUS_CLEAN: Field = 0;

fn main(
    new_commitment: pub Field,
    existing_nullifier_hash: pub Field,
    withdrawn_value: pub Field,
    state_root: pub Field,
    state_tree_depth: pub Field,
    // Root of the identity registry. PrivacyPool checks it against IdentityRegistry.isValidRoot,
    // which enforces MAX_ROOT_AGE - REQUIRED here, because this tree carries revocations and an
    // unbounded-age root would let a revoked identity prove the clean state forever.
    identity_root: pub Field,
    context: pub Field,
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
    // The escrowed revocation secret. Replaces sk_identity: its commitment is the registry key.
    revocation_secret: Field,
    // Inclusion witness for the identity registry, straight from its own getProof().
    identity_siblings: [Field; IDENTITY_TREE_DEPTH],
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

    // 4. REGISTERED AND NOT REVOKED, in one proof. The withdrawer must know the escrowed
    // `revocation_secret` whose commitment sits in the identity registry carrying STATUS_CLEAN.
    //
    // The key is DERIVED from the secret, never a free input. Letting the prover supply the key
    // directly would make this vacuous: they would name any clean identity's commitment - all of
    // which are public in the tree - and withdraw as someone else. Knowledge of the preimage is the
    // whole gate.
    let commitment = secret_commitment(revocation_secret);
    let cleared = smt_verifier_full::<IDENTITY_TREE_DEPTH>(
        identity_root,
        commitment,
        STATUS_CLEAN,
        0,
        0,
        0,
        SMT_INCLUSION,
        identity_siblings,
    );
    assert(cleared == 1, "identity is unregistered or revoked, or the inclusion witness is invalid");
}
