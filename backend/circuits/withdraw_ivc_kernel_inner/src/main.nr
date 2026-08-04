//! Every kernel after the first: extends the chain by one withdrawal.
//!
//! Verifies two things - the previous KERNEL (so the chain cannot be re-rooted) and the APP proof
//! that ran just before this step - then absorbs that app's signals into the running accumulator.
//!
//! VERIFYING THE PREVIOUS KERNEL IS WHAT MAKES THE CHAIN MEAN ANYTHING. Without it a batcher could
//! hand any accumulator value to this circuit and continue from it, which would let them drop
//! withdrawals from the middle of a batch while the final commitment still verified.
use pp::ivc::{absorb, BatchAccumulator, MEGA_VK_LENGTH_IN_FIELDS, PROOF_TYPE_HN, VkData};
use pp::withdraw::WithdrawSignals;

fn main(
    prev: call_data(0) BatchAccumulator,
    prev_kernel_vk: VkData<MEGA_VK_LENGTH_IN_FIELDS>,
    app_signals: call_data(1) WithdrawSignals,
    app_vk: VkData<MEGA_VK_LENGTH_IN_FIELDS>,
) -> return_data BatchAccumulator {
    // BOTH are PROOF_TYPE_HN, and mixing types here is a compile error rather than a subtle bug:
    // "both honk and HN recursion constraints present". OINK appears only in the INIT kernel, where
    // the app it verifies is the first circuit in the stack.
    std::verify_proof_with_type(prev_kernel_vk.key, [], [], prev_kernel_vk.hash, PROOF_TYPE_HN);
    std::verify_proof_with_type(app_vk.key, [], [], app_vk.hash, PROOF_TYPE_HN);

    absorb(prev, app_signals)
}
