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
//! transcript (`bb -t noir-recursive`); the outer proof uses keccak (`bb -t evm`), because that is
//! what the generated Solidity verifier accepts. So a proof made FOR a batcher is not directly
//! self-submittable. **The wallet must retain the witness until the withdrawal confirms** and
//! re-prove with keccak (~1.3 s) if it ever needs the escape hatch. An optimising refactor that
//! drops that retention silently removes the escape hatch.
mod inner_vk;

use inner_vk::WITHDRAW_IDENTITY_VK;
use keccak256::keccak256;

/// Withdrawals per batch. DECIDED: 16 (sec. 2.4b).
///
/// SIZING IS A PROVER-MEMORY DECISION, NOT AN ON-CHAIN ONE. Honk's verifier is a fixed algorithm,
/// so the generated Solidity is the same size for N=1 and N=16 (sec. 2.4pre measured +/-2 bytes) -
/// N grows the CIRCUIT, not the contract. What N costs is the batcher's RAM: in-circuit UltraHonk
/// verification is ~725k gates each. MEASURED at ~2.36 KB/gate (3.3 GB peak proving N=2), so N=16 is
/// ~27 GB - not the ~56 GB an earlier 3.4 KB/gate estimate gave. N=32 extrapolates to ~55 GB. Past
/// 16 the answer is still a 16-wide TREE (depth 2 reaches 256, depth 3 reaches 4096), where every
/// node stays bounded, rather than one wider flat circuit.
pub global BATCH_N: u32 = 16;

/// UltraHonk **ZK** proof length in fields, MEASURED on bb 5.1.0 (`-t noir-recursive`).
///
/// THIS IS COUPLED TO `HONK_PROOF_TYPE` AND MUST MOVE WITH IT. 458 is Aztec's
/// `RECURSIVE_ZK_PROOF_LENGTH` and pairs with `PROOF_TYPE_HONK_ZK = 6`; the NON-ZK pair is 410 with
/// `PROOF_TYPE_HONK = 0`. Mixing them is what produced `ACIR proof size mismatch. Expected: 410`.
/// (bb 1.2.0 emitted 507 here - a length that belongs to no supported combination on 5.x.)
global PROOF_LEN: u32 = 458;

/// `withdraw_identity`'s public signals, MEASURED: 7, matching `ProofLib.WithdrawProof.pubSignals`
/// (`uint256[7]`) and codegen-verifiers.sh's own target list. TODO.md sec. 2.4pre says 8 - that is
/// wrong, and it matters: the fold below must bind exactly the signals the CONTRACT recomputes
/// over, so an off-by-one here produces a commitment the contract can never reproduce.
global PUB_LEN: u32 = 7;

/// `std::verify_proof_with_type`'s proof_type for UltraHonk.
///
/// **6 = `PROOF_TYPE_HONK_ZK`, AND THIS IS NOT bb's `--honk_recursion` VALUE.** Two unrelated
/// enumerations are trivially conflated and doing so costs hours, because nothing errors: bb's CLI
/// flag used 1 = UltraHonk / 2 = UltraRollupHonk, while the IN-CIRCUIT parameter is Aztec's
/// PROOF_TYPE_* set - `PROOF_TYPE_HONK = 0`, `PROOF_TYPE_ROLLUP_HONK = 4`, `PROOF_TYPE_HONK_ZK = 6`
/// (barretenberg/noir/bb_proof_verification/src/lib.nr).
///
/// WE USE **6** BECAUSE OUR INNER PROOFS ARE ZK, which is bb's default and non-negotiable here: a
/// non-ZK inner proof leaks `nullifier`, `secret`, `label`, `value` and `sk_identity` to whoever
/// holds it. 6 pairs with the 458-field proof above; 0 expects a 410-field NON-ZK proof.
///
/// History, so it is not re-derived: passing 1 compiles, solves the witness AND proves, then fails
/// `bb verify` with `Sumcheck failed!` - naming sumcheck, never the parameter. Passing 0 with a ZK
/// proof was worse: on bb 1.2.0 it produced a circuit that verified GARBAGE batches.
global HONK_PROOF_TYPE: u32 = 6;

/// `State.MAX_TREE_DEPTH`. Mirrored from Solidity; see the range check in `main`.
global MAX_TREE_DEPTH: u32 = 32;

/// Index of `state_tree_depth` within the public signals.
global IDX_STATE_TREE_DEPTH: u32 = 4;

/// The batch commitment: ONE keccak over every withdrawal's signals, big-endian, in order.
///
/// WHY KECCAK AND NOT POSEIDON, WHICH THE REST OF THIS REPO USES. The choice is decided by the
/// CONTRACT side, not this one. A Poseidon fold costs 287,969 gas PER WITHDRAWAL to recompute
/// on-chain (measured: PoseidonT6 + PoseidonT5, ~144k each) against a ~152,846 budget for the whole
/// withdrawal - it would have been 65% of the cost. keccak is a native EVM opcode: ~2k gas for the
/// entire batch. In here it costs ~511k extra gates on an ~11.6M-gate circuit (+4.4%), and that is
/// paid by the BATCHER, whose machine already carries ~27 GB - never by the user, whose
/// `withdraw_identity` proof is untouched.
///
/// This does NOT contradict Poseidon's use elsewhere. Tree and note commitments are hashed
/// REPEATEDLY IN-CIRCUIT (a depth-32 path is ~32 hashes: ~8k Poseidon constraints vs ~4.8M keccak),
/// and they are DURABLE - changing them would strand every existing note. This commitment is hashed
/// ONCE per batch on each side and is TRANSIENT: it lives for one transaction and is never stored.
///
/// SERIALISATION IS THE SILENT FAILURE MODE. Each signal is 32 big-endian bytes, laid out exactly as
/// Solidity's `abi.encodePacked(uint256[])`. A mismatch produces a commitment the contract simply
/// cannot reproduce, with nothing to point at the cause - which is what `BatchCommitmentTest`'s
/// circuit-emitted fixture exists to catch.
///
/// REDUCTION MOD THE FIELD IS AUTOMATIC AND DELIBERATE. keccak yields 256 bits; BN254's field is
/// ~254, so the contract takes `uint256(keccak256(...)) % SNARK_SCALAR_FIELD` (the same treatment
/// `PrivacyPool._contextFor` already gives `context`). Accumulating the digest bytes with `Field`
/// arithmetic below reproduces that exactly, because `Field` operations ARE mod p - no explicit
/// reduction, and no risk of the two sides reducing differently.
pub fn batch_commitment(public_inputs: [[Field; PUB_LEN]; BATCH_N]) -> Field {
    let mut bytes: [u8; BATCH_N * PUB_LEN * 32] = [0; BATCH_N * PUB_LEN * 32];
    for i in 0..BATCH_N {
        for j in 0..PUB_LEN {
            let be: [u8; 32] = public_inputs[i][j].to_be_bytes();
            for k in 0..32 {
                bytes[(i * PUB_LEN + j) * 32 + k] = be[k];
            }
        }
    }
    let digest: [u8; 32] = keccak256(bytes, BATCH_N * PUB_LEN * 32);

    let mut acc: Field = 0;
    for k in 0..32 {
        acc = acc * 256 + digest[k] as Field;
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


