//! Shared types for the folded (chonk/IVC) withdrawal stack.
//!
//! WHY A CHAINED COMMITMENT RATHER THAN THE FLAT ONE. `aggregate_withdrawals` builds one keccak over
//! all `BATCH_N * 7` signals at once, which forces the batch size to be a COMPILE-TIME constant: the
//! fold is length-binding, so a proof over sixteen cannot be presented against four, and a batcher
//! must pad with dummy withdrawals they prove and pay for (TODO sec. 2.18ds).
//!
//! Folding removes that, but only if the commitment can be built incrementally. So the fold here is
//! a CHAIN: `H_0 = 0`, `H_i = keccak(H_{i-1} || signals_i)`. Each kernel absorbs exactly one
//! withdrawal, the running value is carried in the kernel's public inputs, and the batch size is
//! whatever was folded rather than whatever the circuit was compiled for. Settle four at 3am and
//! sixteen at noon, from one circuit and one deployed verifier.
//!
//! THE CONTRACT SIDE COSTS ALMOST NOTHING FOR THIS. One keccak over ~3.5 KB becomes sixteen over 256
//! bytes each; both are a few thousand gas, and keccak is a native opcode. What it buys is that
//! `BatchCommitmentLib` stops needing to know N.
//!
//! COUNT IS NOT OPTIONAL. Without it a batcher presents sixteen signal sets against a proof that
//! folded four: the chain over the first four would match, and the contract would settle sixteen
//! withdrawals having verified four. The count is threaded here and MUST be checked on-chain against
//! `signals.length`.
use crate::withdraw::WithdrawSignals;
use keccak256::keccak256;

/// Length of a MegaApp / MegaKernel verification key in fields. Mirrored from Aztec's
/// `protocol_types::constants` (both are 151); a mismatch fails with a size error, not silently.
pub global MEGA_VK_LENGTH_IN_FIELDS: u32 = 151;

/// Aztec's PROOF_TYPE_* set, transcribed from
/// `noir-protocol-circuits/crates/types/src/constants.nr:1249-1257`. Do NOT infer these.
///
/// They are a different enumeration from bb's `--honk_recursion` flag AND from the value
/// `aggregate_withdrawals` calls `HONK_PROOF_TYPE` (6 = PROOF_TYPE_HONK_ZK, which belongs to the
/// non-IVC recursion path). Guessing 6 for HN here produced
/// `input.proof.size() == expected_proof_size` - an error naming the proof, never the constant.
pub global PROOF_TYPE_OINK: u32 = 1;
pub global PROOF_TYPE_HN: u32 = 2;
pub global PROOF_TYPE_HN_FINAL: u32 = 7;
pub global PROOF_TYPE_CHONK: u32 = 8;

/// A verification key as `std::verify_proof_with_type` wants it.
pub struct VkData<let N: u32> {
    pub key: [Field; N],
    pub hash: Field,
}

/// What each kernel hands to the next, and what the wrapper finally exposes.
pub struct BatchAccumulator {
    /// `H_i` of the chain described above.
    pub commitment: Field,
    /// How many withdrawals have been folded. Checked on-chain against `signals.length`.
    pub count: Field,
}

/// Absorb one withdrawal into the running chain: `H = keccak(H_prev || signals)`.
///
/// SERIALISATION IS THE SILENT FAILURE MODE, exactly as in the flat version. Each field is 32
/// big-endian bytes laid out as Solidity's `abi.encodePacked` would, and the digest is reduced into
/// the field by accumulating bytes - which reproduces `uint256(keccak256(...)) % SNARK_SCALAR_FIELD`
/// because `Field` arithmetic IS mod p. A mismatch produces a commitment the contract cannot
/// reproduce, with nothing to point at.
pub fn absorb(prev: BatchAccumulator, signals: WithdrawSignals) -> BatchAccumulator {
    let ordered = [
        signals.new_commitment,
        signals.existing_nullifier_hash,
        signals.withdrawn_value,
        signals.state_root,
        signals.state_tree_depth,
        signals.identity_root,
        signals.context,
    ];

    let mut bytes: [u8; 256] = [0; 256];
    let head: [u8; 32] = prev.commitment.to_be_bytes();
    for k in 0..32 {
        bytes[k] = head[k];
    }
    for j in 0..7 {
        let be: [u8; 32] = ordered[j].to_be_bytes();
        for k in 0..32 {
            bytes[32 + j * 32 + k] = be[k];
        }
    }

    let digest: [u8; 32] = keccak256(bytes, 256);
    let mut acc: Field = 0;
    for k in 0..32 {
        acc = acc * 256 + digest[k] as Field;
    }

    BatchAccumulator { commitment: acc, count: prev.count + 1 }
}
