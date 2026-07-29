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

// =================================================================================================
// THE FIRST TESTS THIS CIRCUIT HAS EVER HAD (TODO.md sec. 2.18ah).
//
// It had ZERO. `pp` covers the pieces - `commitment_hasher`, `lean_imt_inclusion`,
// `smt_verifier_full`, `secret_commitment` all have their own vectors - but nothing exercised the
// COMPOSITION, and the composition is where the money is. A wiring error here (arguments swapped
// between two Field parameters, a check reading the wrong variable) is invisible to every unit test
// in `pp` and would still produce a circuit that proves and verifies.
//
// NO EXTERNAL DATA IS NEEDED, which is why the absence of tests was a choice rather than a
// constraint. A single-leaf LeanIMT has root == leaf by its carry-up rule, and a single-leaf SMT
// root is just `Poseidon(key, value, 1)` - so a complete, valid witness is constructible in-circuit
// with no fixture, no phone and no document.
// =================================================================================================
mod wiring_tests {
    use super::{IDENTITY_TREE_DEPTH, main, STATUS_CLEAN};
    use pp::commitment::commitment_hasher;
    use pp::envelope::secret_commitment;
    use poseidon::poseidon::PoseidonHasher;
    use std::hash::Hasher;

    global VALUE: Field = 100;
    global LABEL: Field = 20;
    global NULLIFIER: Field = 30;
    global SECRET: Field = 40;
    global OUT_NULLIFIER: Field = 31;
    global OUT_SECRET: Field = 41;
    global REVOCATION_SECRET: Field = 987654321;
    global WITHDRAWN: Field = 30;
    global CONTEXT: Field = 42424242;

    /// The identity registry's root for a tree holding exactly `commitment -> STATUS_CLEAN`.
    /// Mirrors `smt_hash1`, which pp keeps private: Poseidon(key, value, 1).
    fn single_leaf_identity_root(commitment: Field) -> Field {
        let mut hasher = PoseidonHasher::default();
        hasher.write(commitment);
        hasher.write(STATUS_CLEAN);
        hasher.write(1);
        hasher.finish()
    }

    /// Drive `main` with a fully consistent witness, allowing individual fields to be perturbed.
    fn run(
        value: Field,
        withdrawn: Field,
        revocation_secret: Field,
        nullifier_hash_override: Field,
        use_override: bool,
    ) {
        let existing = commitment_hasher(value, LABEL, NULLIFIER, SECRET);
        let out = commitment_hasher(value - withdrawn, LABEL, OUT_NULLIFIER, OUT_SECRET);
        let identity_root = single_leaf_identity_root(secret_commitment(REVOCATION_SECRET));

        let nullifier_hash = if use_override {
            nullifier_hash_override
        } else {
            existing.nullifier_hash
        };

        main(
            out.commitment,
            nullifier_hash,
            withdrawn,
            existing.commitment, // single-leaf LeanIMT: root == leaf
            0,                   // depth 0
            identity_root,
            CONTEXT,
            value,
            LABEL,
            NULLIFIER,
            SECRET,
            0,
            [0; 32],
            OUT_NULLIFIER,
            OUT_SECRET,
            revocation_secret,
            [0; IDENTITY_TREE_DEPTH],
        );
    }

    /// The baseline. If this ever fails, every negative test below is meaningless.
    #[test]
    fn test_a_consistent_withdrawal_proves() {
        run(VALUE, WITHDRAWN, REVOCATION_SECRET, 0, false);
    }

    /// THE IDENTITY GATE. Knowing the escrowed secret is the whole of it - the registry key is
    /// DERIVED from the secret, never supplied, so a prover who does not know it cannot name a
    /// clean identity and withdraw as them. Every commitment in that tree is public.
    #[test(should_fail)]
    fn test_a_wrong_revocation_secret_cannot_withdraw() {
        run(VALUE, WITHDRAWN, REVOCATION_SECRET + 1, 0, false);
    }

    /// VALUE CONSERVATION. Withdrawing more than the note holds must not prove: the subtraction is
    /// range-checked to 128 bits precisely so it cannot wrap the field and mint a balance.
    #[test(should_fail)]
    fn test_cannot_withdraw_more_than_the_note_holds() {
        run(VALUE, VALUE + 1, REVOCATION_SECRET, 0, false);
    }

    /// The nullifier hash is what makes a note single-spend. If a false one proved, the same note
    /// could be spent repeatedly under different nullifier hashes.
    #[test(should_fail)]
    fn test_a_false_nullifier_hash_cannot_prove() {
        run(VALUE, WITHDRAWN, REVOCATION_SECRET, 12345, true);
    }

    /// Withdrawing the whole note is legitimate - the change note is simply worth zero. Asserting
    /// it because a range check written slightly wrong would reject exactly this case, and a user
    /// who could never empty a note would be quietly stuck.
    #[test]
    fn test_withdrawing_the_entire_note_is_allowed() {
        run(VALUE, VALUE, REVOCATION_SECRET, 0, false);
    }
}
