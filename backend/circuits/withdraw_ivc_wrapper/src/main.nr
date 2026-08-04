//! Verifies the FOLDED proof and exposes the batch commitment for the chain.
//!
//! THIS IS THE CIRCUIT THE EVM VERIFIER IS GENERATED FROM. Everything before it lives inside the
//! fold: the app, the kernels and the hiding kernel are accumulated, and their cost is paid in cheap
//! incremental steps (measured: a flat 359 MiB across sixteen accumulations). This circuit is the one
//! that gets proven conventionally and verified on-chain, so its size is the size that matters.
//!
//! WHY IT DOES NOT GROW WITH BATCH SIZE, which is the whole point. `aggregate_withdrawals` verifies
//! each withdrawal proof in-circuit and pays ~798k gates for every one, so N is compile-time and 16
//! and 256 are different circuits with different verifiers. This verifies ONE accumulated proof.
//! Folding four or four hundred produces the same circuit, the same verifier, the same deployed
//! address - and makes partial batches provable, which the flat design cannot do at all.
//!
//! ONLY bb 6.0.0-nightly BUILDS THIS. 5.1.0 rejects HN recursion constraints outright with "not
//! supported with UltraBuilder", on this circuit and on Aztec's own published equivalents. The app
//! and kernels build under either; this one is the version boundary.
use pp::ivc::{BatchAccumulator, PROOF_TYPE_CHONK};

/// Transcribed from `noir-protocol-circuits/crates/types/src/constants.nr`:
/// 48 + 28 + 41 + 556 + 70 + 478. Do not infer it - a wrong length fails inside the verifier with a
/// size assertion that names neither the constant nor the circuit.
global CHONK_PROOF_LENGTH: u32 = 1221;
/// `CHONK_VK_LENGTH_IN_FIELDS = MEGA_ZK_VK_LENGTH_IN_FIELDS`, the MegaZK key the hiding kernel is
/// proven under - which is why the hiding kernel's vk must be derived with `--use_zk_flavor`.
global CHONK_VK_LENGTH_IN_FIELDS: u32 = 119;

fn main(
    proof: [Field; CHONK_PROOF_LENGTH],
    vk: [Field; CHONK_VK_LENGTH_IN_FIELDS],
    vk_hash: Field,
    // The accumulator the hiding kernel exposed. Re-declared `pub` here so it lands in THIS proof's
    // public inputs, where `BatchVerifierLib` reads it.
    accumulator: pub BatchAccumulator,
) {
    let inputs = [accumulator.commitment, accumulator.count];
    std::verify_proof_with_type(vk, proof, inputs, vk_hash, PROOF_TYPE_CHONK);
}
