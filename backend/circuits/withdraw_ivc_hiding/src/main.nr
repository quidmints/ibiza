//! The hiding kernel: final circuit of the stack, and the one the accumulator is discharged through.
//!
//! It verifies the last kernel and passes its accumulator out unchanged. `chonk_tail_circuits.json`
//! in Aztec's tree is literally `["hiding"]`, and `Chonk::accumulate_hiding_kernel must be the final
//! circuit in the IVC stack` - so this is not an optional wrapper, it is what the scheme requires to
//! close a fold.
//!
//! Its VK must be derived with `--use_zk_flavor` (MegaZKFlavor), which is the only Chonk circuit
//! proven as MegaZK. Deriving it the ordinary way yields a 5,216-byte key where 3,680 is expected.
use pp::ivc::{BatchAccumulator, MEGA_VK_LENGTH_IN_FIELDS, PROOF_TYPE_HN_FINAL, VkData};

fn main(
    prev: call_data(0) BatchAccumulator,
    prev_kernel_vk: VkData<MEGA_VK_LENGTH_IN_FIELDS>,
) -> pub BatchAccumulator {
    std::verify_proof_with_type(prev_kernel_vk.key, [], [], prev_kernel_vk.hash, PROOF_TYPE_HN_FINAL);

    prev
}
