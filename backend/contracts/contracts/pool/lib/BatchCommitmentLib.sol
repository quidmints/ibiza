// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/**
 * @notice Recomputes the aggregation batch commitment from calldata, so the contract can check that
 *         a batched proof covers EXACTLY the withdrawals it was handed (TODO.md sec. 2.4).
 *
 * @dev THIS MUST STAY BYTE-IDENTICAL TO `aggregate_withdrawals::batch_commitment`. The aggregation
 *      verifier exposes ONE public input - this commitment - because the verifier has little EIP-170
 *      margin and N x 7 signals would not fit. So this function is the ONLY thing tying that single
 *      field back to the individual withdrawals; if it diverges from the circuit, every batch fails
 *      to verify.
 *
 *      IT HAD DIVERGED, AND THE GUARD THAT EXISTS TO CATCH THAT COULD NOT FIRE (2026-08-04). This
 *      library folded with chained Poseidon v1 while the circuit had moved to a single keccak256
 *      over the concatenated signals - `aggregate_withdrawals` does not depend on poseidon at all,
 *      and the `fold_signals` this file claimed to mirror no longer exists. Nothing failed, because
 *      `BatchCommitmentTest` compared Solidity against a FROZEN CONSTANT rather than against the
 *      circuit: a pinned number tests that Solidity has not changed, which is not the question. The
 *      test now derives its expectation from the circuit's construction, so moving either side
 *      breaks it.
 *
 *      WHICH SIDE MOVED, established before changing anything: the circuit. It carries no poseidon
 *      dependency, and its own comment describes the contract taking
 *      `uint256(keccak256(...)) % SNARK_SCALAR_FIELD` - the design intended keccak on both sides and
 *      only this file was left behind. Keccak is also far cheaper here: one hash for the whole batch
 *      against two Poseidon permutations per withdrawal.
 *
 *      THE REDUCTION IS PART OF THE COMMITMENT, not a detail. keccak256 gives 256 bits and the field
 *      is ~254, so the circuit folds the digest bytes with Field arithmetic - which IS mod p - and
 *      the contract must reduce explicitly to land on the same element. Omitting `% FIELD_MODULUS`
 *      would agree for most inputs and disagree for the roughly one in 2^-2 that exceed p.
 */
library BatchCommitmentLib {
    /// @notice Public signals per withdrawal - `ProofLib.WithdrawProof.pubSignals` is `uint256[7]`.
    uint256 internal constant PUB_LEN = 7;

    /// @notice BN254's scalar field order, the modulus every public input lives in.
    uint256 internal constant FIELD_MODULUS =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /**
     * @notice The batch commitment over `signals`.
     * @dev Mirrors `batch_commitment`: keccak256 over every signal as a 32-byte big-endian word, in
     *      withdrawal order then signal order, reduced into the field.
     *
     *      ORDER- AND LENGTH-BINDING, both structurally. Concatenation makes POSITION part of the
     *      preimage, so a batcher cannot permute withdrawals relative to the calldata walked here -
     *      which is what stops them moving one user's recipient context onto another's nullifier.
     *      Length is bound because a shorter batch hashes a shorter preimage.
     *
     *      `abi.encodePacked` on a `uint256[]` emits exactly 32 bytes per element with no length
     *      prefix and no padding, which is the circuit's layout. Flattening first and encoding once
     *      is deliberate: encoding per withdrawal and concatenating would copy the accumulated bytes
     *      on every iteration.
     */
    function batchCommitment(uint256[PUB_LEN][] memory signals) internal pure returns (uint256) {
        uint256[] memory flat = new uint256[](signals.length * PUB_LEN);
        uint256 k;
        for (uint256 i = 0; i < signals.length; ++i) {
            for (uint256 j = 0; j < PUB_LEN; ++j) {
                flat[k++] = signals[i][j];
            }
        }
        return uint256(keccak256(abi.encodePacked(flat))) % FIELD_MODULUS;
    }
}
