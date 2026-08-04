//! The withdrawal statement, extracted so it exists ONCE.
//!
//! WHY THIS FILE EXISTS. `withdraw_identity` proves a withdrawal and exposes seven `pub` signals in
//! the order `ProofLib.WithdrawProof.pubSignals` pins. The IVC/chonk path needs the SAME statement
//! with a different calling convention: the app circuit returns its signals as `return_data` so a
//! kernel can consume them through `call_data`, rather than exposing them as public inputs.
//!
//! Two `main`s, one statement. Copying the body instead would put the money path in two places, and
//! the copies would drift the first time either is touched - which is exactly how a fold that
//! verifies a DIFFERENT statement than the contract checks would arrive, silently.
//!
//! THE EXTRACTION MUST NOT CHANGE THE EXISTING CIRCUIT, and that is checkable rather than arguable:
//! `bb write_vk -t evm` on `withdraw_identity` produced sha256 `366f53d7...` before this file
//! existed. If it still does, the constraint system is untouched and every generated verifier,
//! fixture and committed proof remains valid. If it does not, this extraction is wrong and must be
//! reverted rather than re-pinned.
use crate::commitment::commitment_hasher;
use crate::envelope::secret_commitment;
use crate::lean_imt::lean_imt_inclusion;
use crate::smt::smt_verifier_full;

/// SMT depth of the identity registry. MUST equal IdentityRegistry's constructor `treeHeight_` and
/// the wallet's IDENTITY_TREE_DEPTH. A mismatch fails every proof with no useful diagnostic.
///
/// 32, not 20: this tree holds EVERY registered identity, not just revoked ones, so it is the large
/// tree. Depth 20 caps at ~1M identities and would be cheaper in-circuit (7,889 vs 11,856 opcodes),
/// but raising a tree's depth later invalidates every proof and forces a migration.
pub global IDENTITY_TREE_DEPTH: u32 = 32;

/// `fnc = 0` selects INCLUSION in smt_verifier_full. Named because passing 1 here would prove the
/// OPPOSITE - that the identity is absent from the registry - which is what an UNREGISTERED party
/// can prove and a registered one cannot.
global SMT_INCLUSION: bool = false;

/// The value a clean identity carries. Non-zero means revoked, and the value IS the predicate.
global STATUS_CLEAN: Field = 0;

/// The seven signals, in `ProofLib.WithdrawProof.pubSignals` order. The ORDER is load-bearing in
/// both directions: the contract indexes these positionally, and `BatchCommitmentLib` folds them
/// positionally, so a reordering here produces a commitment the contract cannot reproduce.
pub struct WithdrawSignals {
    pub new_commitment: Field,
    pub existing_nullifier_hash: Field,
    pub withdrawn_value: Field,
    pub state_root: Field,
    pub state_tree_depth: Field,
    pub identity_root: Field,
    pub context: Field,
}

/// The witness a withdrawal is proven against. Grouped into a struct only so both `main`s can pass
/// it through without restating eleven parameters; it is not a semantic boundary.
pub struct WithdrawWitness {
    pub value: Field,
    pub label: Field,
    pub nullifier: Field,
    pub secret: Field,
    pub state_leaf_index: Field,
    pub state_siblings: [Field; 32],
    pub out_nullifier: Field,
    pub out_secret: Field,
    pub revocation_secret: Field,
    pub identity_siblings: [Field; IDENTITY_TREE_DEPTH],
}

/// Prove one withdrawal. Constraint-for-constraint the body `withdraw_identity/src/main.nr` carried
/// before the extraction, in the same order, so the verification key is unchanged.
pub fn verify_withdrawal(signals: WithdrawSignals, w: WithdrawWitness) {
    // Says "no gate reads this, and that is intended" in code rather than in a comment. Without it
    // the compiler warns `unused variable context` on every build, and a warning that is expected
    // forever is a warning nobody reads - so the day a public input goes unused BY ACCIDENT, the
    // diagnostic that would have caught it is already background noise. Costs no constraints.
    let _ = signals.context;

    // 1. Existing note: reconstruct its commitment + nullifier hash, and prove membership in the
    // PP state tree at `state_root`. `state_tree_depth` is contract-selectable, capped at
    // MAX_TREE_DEPTH=32 on-chain, and taken directly as the actual depth - a false depth simply
    // fails to reconstruct `state_root`, so no separate range check is needed beyond
    // lean_imt_inclusion's own `assert(actual_depth <= MAX_DEPTH)`.
    let existing = commitment_hasher(w.value, w.label, w.nullifier, w.secret);
    assert(existing.nullifier_hash == signals.existing_nullifier_hash);
    let computed_state_root = lean_imt_inclusion(
        existing.commitment,
        w.state_leaf_index,
        w.state_siblings,
        signals.state_tree_depth as u32,
    );
    assert(computed_state_root == signals.state_root);

    // 2. Value conservation: existing value == withdrawn + carried into the change note.
    // Range-checked to 128 bits (ample for token amounts) via to_le_bits' own constraint, so the
    // subtraction below can't wrap the ~254-bit field and hide a fabricated balance.
    let _value_bits: [bool; 128] = w.value.to_le_bits();
    let _withdrawn_bits: [bool; 128] = signals.withdrawn_value.to_le_bits();
    let new_value = w.value - signals.withdrawn_value;
    let _new_value_bits: [bool; 128] = new_value.to_le_bits();

    // 3. Change note commitment.
    let out = commitment_hasher(new_value, w.label, w.out_nullifier, w.out_secret);
    assert(out.commitment == signals.new_commitment);

    // 4. REGISTERED AND NOT REVOKED, in one proof. The withdrawer must know the escrowed
    // `revocation_secret` whose commitment sits in the identity registry carrying STATUS_CLEAN.
    //
    // The key is DERIVED from the secret, never a free input. Letting the prover supply the key
    // directly would make this vacuous: they would name any clean identity's commitment - all of
    // which are public in the tree - and withdraw as someone else. Knowledge of the preimage is the
    // whole gate.
    let commitment = secret_commitment(w.revocation_secret);
    let cleared = smt_verifier_full::<IDENTITY_TREE_DEPTH>(
        signals.identity_root,
        commitment,
        STATUS_CLEAN,
        0,
        0,
        false,
        SMT_INCLUSION,
        w.identity_siblings,
    );
    assert(
        cleared == true,
        "identity is unregistered or revoked, or the inclusion witness is invalid",
    );
}
