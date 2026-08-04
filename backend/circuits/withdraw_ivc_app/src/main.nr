//! Withdrawal, as the APP circuit of the folded stack.
//!
//! IDENTICAL STATEMENT, DIFFERENT CALLING CONVENTION. This proves exactly what `withdraw_identity`
//! proves, by calling the same `pp::withdraw::verify_withdrawal`. What differs is where the seven
//! signals go: there they are `pub` and land in the proof's public inputs, so `PrivacyPool.withdraw`
//! can read them; here they are `return_data`, so the next circuit in the IVC stack takes them
//! through `call_data` and the chain of kernels carries them instead.
//!
//! WHY THE TWO CANNOT BE ONE CIRCUIT. The return mode is part of the constraint system, so a single
//! `main` cannot serve both. Sharing the STATEMENT rather than the circuit is what keeps them from
//! drifting - if this file ever proves something `withdraw_identity` does not, the fold would verify
//! a different claim than the contract checks, and nothing on-chain would notice.
//!
//! ON TOOLCHAIN, measured rather than assumed: 5.1.0 CAN build this one (70,077 gates against
//! 6.0.0-nightly's 70,003). `return_data` alone is fine. The version boundary is at the WRAPPER,
//! which carries HN recursion constraints that 5.1.0 rejects outright.
use pp::withdraw::{IDENTITY_TREE_DEPTH, verify_withdrawal, WithdrawSignals, WithdrawWitness};

fn main(
    // The seven signals are ordinary inputs here rather than `pub`: they leave through the return,
    // not through the public-input transcript. Order still matters and still matches
    // `ProofLib.WithdrawProof.pubSignals`, because the kernel folds them positionally into the
    // batch commitment the contract recomputes.
    new_commitment: Field,
    existing_nullifier_hash: Field,
    withdrawn_value: Field,
    state_root: Field,
    state_tree_depth: Field,
    identity_root: Field,
    context: Field,
    value: Field,
    label: Field,
    nullifier: Field,
    secret: Field,
    state_leaf_index: Field,
    state_siblings: [Field; 32],
    out_nullifier: Field,
    out_secret: Field,
    revocation_secret: Field,
    identity_siblings: [Field; IDENTITY_TREE_DEPTH],
) -> return_data WithdrawSignals {
    let signals = WithdrawSignals {
        new_commitment,
        existing_nullifier_hash,
        withdrawn_value,
        state_root,
        state_tree_depth,
        identity_root,
        context,
    };

    verify_withdrawal(
        signals,
        WithdrawWitness {
            value,
            label,
            nullifier,
            secret,
            state_leaf_index,
            state_siblings,
            out_nullifier,
            out_secret,
            revocation_secret,
            identity_siblings,
        },
    );

    signals
}
