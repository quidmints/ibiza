//! AGGREGATE N `withdraw_identity` PROOFS INTO ONE (TODO.md sec. 2.4 / 2.4b).
//!
//! WHAT THIS BUYS. A single withdrawal verification costs ~2.39M gas, which makes the pool
//! unusable for ordinary amounts. Verifying N of them inside one proof amortises that: ~152k
//! gas/withdrawal at N=16, ~95% of the achievable saving. Beyond 16 the benefit decays as 1/N while
//! prover cost grows linearly and calldata becomes the floor.
//!
//! WHY RECURSION RATHER THAN ONE CIRCUIT PROVING N WITHDRAWALS NATIVELY. The native version is
//! cheaper to prove, and requires ONE prover to hold EVERYONE's witness - nullifiers, secrets,
//! `sk_identity`. That is the opposite of what the pool is for. Here each user proves their own
//! withdrawal on-device and the batcher sees only proofs and public inputs, so **anyone can be a
//! batcher**: no registry, no stake, no whitelist.
//!
//! WHAT A MALICIOUS BATCHER CAN AND CANNOT DO. Cannot forge: the aggregate is verified on-chain
//! against a PINNED inner key, so a batch containing anything other than real `withdraw_identity`
//! proofs fails. Can refuse to serve. That is why `PrivacyPool.withdraw` stays untouched - a user
//! censored by every batcher still self-submits at full gas, so refusal costs money, never access.
//!
//! THE ORACLE SPLIT, and the wallet obligation it creates. Inner proofs use the poseidon2
//! transcript (`--honk_recursion 1`); the outer proof uses keccak, because that is what the
//! generated Solidity verifier accepts. So a proof made FOR a batcher is not directly
//! self-submittable. **The wallet must retain the witness until the withdrawal confirms** and
//! re-prove with keccak (~1.3 s) if it ever needs the escape hatch. An optimising refactor that
//! drops that retention silently removes the escape hatch.
mod inner_vk;

use inner_vk::WITHDRAW_IDENTITY_VK;
use poseidon::poseidon::bn254;

/// Withdrawals per batch. DECIDED: 16 (sec. 2.4b).
///
/// SIZING IS A PROVER-MEMORY DECISION, NOT AN ON-CHAIN ONE. Honk's verifier is a fixed algorithm,
/// so the generated Solidity is the same size for N=1 and N=16 (sec. 2.4pre measured +/-2 bytes) -
/// N grows the CIRCUIT, not the contract. What N costs is the batcher's RAM: in-circuit UltraHonk
/// verification is order 1M gates each at ~3.4 KB/gate, so N=16 is ~56 GB. N=64 would be ~225 GB
/// and N=256 ~899 GB, which is not one machine - past 16 the answer is a 16-wide TREE of these
/// circuits (depth 2 reaches 256, depth 3 reaches 4096), where every node stays at ~56 GB.
pub global BATCH_N: u32 = 16;

/// UltraHonk proof length in fields, MEASURED on bb 1.2.0 (`--honk_recursion 1`).
global PROOF_LEN: u32 = 507;

/// `withdraw_identity`'s public signals, MEASURED: 7, matching `ProofLib.WithdrawProof.pubSignals`
/// (`uint256[7]`) and codegen-verifiers.sh's own target list. TODO.md sec. 2.4pre says 8 - that is
/// wrong, and it matters: the fold below must bind exactly the signals the CONTRACT recomputes
/// over, so an off-by-one here produces a commitment the contract can never reproduce.
global PUB_LEN: u32 = 7;

/// `std::verify_proof_with_type`'s proof_type for UltraHonk.
///
/// **0, AND THIS IS NOT bb's `--honk_recursion` VALUE.** Two unrelated enumerations are easy to
/// conflate, and doing so costs hours because nothing errors: bb's CLI flag uses 1 = UltraHonk,
/// 2 = UltraRollupHonk, while the IN-CIRCUIT parameter is Aztec's PROOF_TYPE_* set - 
/// PROOF_TYPE_HONK = 0, PROOF_TYPE_ROLLUP_HONK = 4, PROOF_TYPE_HONK_ZK = 6
/// (barretenberg/noir/bb_proof_verification/src/lib.nr). Passing 1 compiles, solves the witness,
/// and proves - and the proof then fails `bb verify` with `Sumcheck failed!`, with nothing
/// pointing at the parameter. PROOF_TYPE_HONK_ZK = 6 is NOT usable on beta.13: it fails to build.
global HONK_PROOF_TYPE: u32 = 0;

/// `State.MAX_TREE_DEPTH`. Mirrored from Solidity; see the range check in `main`.
global MAX_TREE_DEPTH: u32 = 32;

/// Index of `state_tree_depth` within the public signals.
global IDX_STATE_TREE_DEPTH: u32 = 4;

/// Fold one withdrawal's public signals into the running commitment.
///
/// ORDER-BINDING IS THE POINT. The commitment must pin exactly these N signal-sets IN ORDER, so the
/// contract can walk its calldata and arrive at the same field element. A commutative combiner (a
/// sum, an XOR) would let a batcher permute withdrawals - or swap one user's recipient context onto
/// another's nullifier - while still matching. Chaining the accumulator through each hash is what
/// makes position part of the preimage.
///
/// ARITY IS DICTATED BY THE CONTRACT, not by taste. There are 8 values to absorb (accumulator + 7
/// signals) and `poseidon-solidity` tops out at `PoseidonT6` = 5 inputs, so this is hash_5 then
/// hash_4. Poseidon **v1** (`poseidon::poseidon::bn254`) is used, NOT Poseidon2: v1 is what
/// `poseidon-solidity` implements and what the rest of this repo already matches against it
/// (pp/src/commitment.nr). Using Poseidon2 here would compile, prove, and produce a commitment the
/// contract cannot reproduce.
fn fold_signals(acc: Field, signals: [Field; PUB_LEN]) -> Field {
    let a = bn254::hash_5([acc, signals[0], signals[1], signals[2], signals[3]]);
    bn254::hash_4([a, signals[4], signals[5], signals[6]])
}

/// The batch commitment over all N withdrawals, from a zero accumulator.
///
/// Exposed so the batcher and the contract-side test can compute it the same way the circuit does.
pub fn batch_commitment(public_inputs: [[Field; PUB_LEN]; BATCH_N]) -> Field {
    let mut acc: Field = 0;
    for i in 0..BATCH_N {
        acc = fold_signals(acc, public_inputs[i]);
    }
    acc
}

/// Reject a `state_tree_depth` the pool itself would reject.
///
/// THE TRUNCATION TRAP (sec. 2.4, constraint 5). `PrivacyPool.withdraw` rejects
/// `stateTreeDepth() > MAX_TREE_DEPTH` on the FULL uint256. The inner circuit casts that same
/// `Field` to `u32`, which TRUNCATES, and `lean_imt_inclusion` uses the depth only in a bound
/// assert - it never affects the computed root. So `2^32 + 5` truncates to `5` and satisfies the
/// inner circuit; it is rejected TODAY only because the contract sees the untruncated value.
///
/// A batch verified on-chain must therefore re-impose it here, on the FIELD, before the value is
/// narrowed - otherwise aggregation would quietly remove a check the single-withdrawal path has.
/// `assert_max_bit_size` constrains the full field element, so a value with bits above 2^32 fails
/// rather than wrapping.
fn assert_depth_in_range(depth: Field) {
    depth.assert_max_bit_size::<32>();
    assert(depth as u32 <= MAX_TREE_DEPTH, "state_tree_depth exceeds MAX_TREE_DEPTH");
}

/// Verify N `withdraw_identity` proofs and expose ONE field binding all of their public signals.
///
/// ONE PUBLIC INPUT IS LOAD-BEARING FOR DEPLOYABILITY, not a stylistic choice. sec. 2.4pre measured
/// the generated verifier at 24,493 bytes against EIP-170's 24,576 - **83 bytes of margin**, and
/// only with `optimizer_runs = 1`. The verifier's calldata handling scales with public inputs, so a
/// design exposing N x 7 signals does not fit. Nothing is lost by compressing: the pool still
/// checks each withdrawal's real signals itself, against this commitment.
fn main(
    proofs: [[Field; PROOF_LEN]; BATCH_N],
    public_inputs: [[Field; PUB_LEN]; BATCH_N],
    key_hash: Field,
    batch_commitment_pub: pub Field,
) {
    for i in 0..BATCH_N {
        assert_depth_in_range(public_inputs[i][IDX_STATE_TREE_DEPTH]);

        // EVERY proof is verified - no short-circuit, no early return (sec. 2.4, constraint 2).
        // The key is the pinned constant, never an input (constraint 1).
        std::verify_proof_with_type(
            WITHDRAW_IDENTITY_VK,
            proofs[i],
            public_inputs[i],
            key_hash,
            HONK_PROOF_TYPE,
        );
    }

    assert(batch_commitment(public_inputs) == batch_commitment_pub, "batch commitment mismatch");
}

#[test]
fn fold_is_order_binding() {
    // Swapping two withdrawals must change the commitment - otherwise a batcher could permute the
    // batch relative to the calldata the contract walks.
    let mut a: [[Field; PUB_LEN]; BATCH_N] = [[0; PUB_LEN]; BATCH_N];
    for i in 0..BATCH_N {
        for j in 0..PUB_LEN {
            a[i][j] = (i * 100 + j) as Field;
        }
    }
    let mut b = a;
    let tmp = b[0];
    b[0] = b[1];
    b[1] = tmp;
    assert(batch_commitment(a) != batch_commitment(b));
}

#[test]
fn fold_binds_every_signal_position() {
    // A commitment that ignored a slot would let a batcher alter it freely - the recipient context
    // (index 6) being the obvious target.
    let base: [[Field; PUB_LEN]; BATCH_N] = [[7; PUB_LEN]; BATCH_N];
    let reference = batch_commitment(base);
    for j in 0..PUB_LEN {
        let mut m = base;
        m[BATCH_N - 1][j] = 999;
        assert(batch_commitment(m) != reference);
    }
}

#[test(should_fail_with = "state_tree_depth exceeds MAX_TREE_DEPTH")]
fn depth_above_max_is_rejected() {
    assert_depth_in_range(33);
}

#[test]
fn depth_at_max_is_accepted() {
    assert_depth_in_range(32);
}

#[test(should_fail)]
fn depth_that_truncates_to_a_legal_value_is_rejected() {
    // 2^32 + 5 narrows to 5 under a u32 cast. The inner circuit accepts it; the contract does not;
    // so the aggregator must not.
    assert_depth_in_range(4294967301);
}
