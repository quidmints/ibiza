//! First kernel of the folded stack: starts the chain.
//!
//! It verifies the app proof that immediately preceded it and absorbs that withdrawal's signals into
//! a fresh accumulator. There is no previous kernel, which is the only thing separating this from
//! `withdraw_ivc_kernel_inner`.
//!
//! THE PROOF IS NOT AN ARGUMENT. `verify_proof_with_type` is called with empty proof and public-input
//! arrays because under IVC the proof travels on the Goblin op queue rather than through the ABI.
//! What this circuit names is WHICH key the previous proof must satisfy.
use pp::ivc::{absorb, BatchAccumulator, MEGA_VK_LENGTH_IN_FIELDS, PROOF_TYPE_OINK, VkData};
use pp::withdraw::WithdrawSignals;

fn main(
    app_signals: call_data(1) WithdrawSignals,
    app_vk: VkData<MEGA_VK_LENGTH_IN_FIELDS>,
) -> return_data BatchAccumulator {
    std::verify_proof_with_type(app_vk.key, [], [], app_vk.hash, PROOF_TYPE_OINK);

    absorb(BatchAccumulator { commitment: 0, count: 0 }, app_signals)
}
