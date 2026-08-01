// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {PoseidonT5} from "poseidon-solidity/PoseidonT5.sol";
import {PoseidonT6} from "poseidon-solidity/PoseidonT6.sol";

/**
 * @notice Recomputes the aggregation batch commitment from calldata, so the contract can check that
 *         a batched proof covers EXACTLY the withdrawals it was handed (TODO.md sec. 2.4).
 *
 * @dev THIS MUST STAY BYTE-IDENTICAL TO `aggregate_withdrawals::batch_commitment`. The aggregation
 *      verifier exposes ONE public input - this commitment - because the verifier has 84 bytes of
 *      EIP-170 margin and N x 7 signals would not fit. So this function is the ONLY thing tying that
 *      single field back to the individual withdrawals; if it diverges from the circuit, every batch
 *      fails to verify (the benign case) or, worse, a commitment computed a different way could be
 *      matched by a different set of withdrawals.
 *
 *      The divergence is SILENT in both directions and neither side can detect it alone, which is
 *      why `BatchCommitmentTest` pins a fixture emitted by the CIRCUIT and recomputed here. That is
 *      the same cross-language guard `NotaryRegistryProofTest` applies to the Go/Solidity Merkle
 *      trees, and for the same reason: a shared misunderstanding makes a generator and its own
 *      checker agree and both be wrong.
 *
 *      POSEIDON v1, NOT POSEIDON2. `poseidon-solidity` implements v1, and the circuit uses
 *      `poseidon::poseidon::bn254::hash_N` to match it - as `pp/src/commitment.nr` already does.
 *      Poseidon2 in the circuit would compile, prove, and produce a commitment no contract could
 *      ever reproduce.
 *
 *      THE ARITY SPLIT IS FORCED BY SOLIDITY, not chosen. There are 8 values to absorb per
 *      withdrawal (the accumulator plus 7 signals) and `poseidon-solidity` tops out at PoseidonT6 =
 *      5 inputs, hence hash_5 then hash_4.
 */
library BatchCommitmentLib {
    /// @notice Public signals per withdrawal - `ProofLib.WithdrawProof.pubSignals` is `uint256[7]`.
    uint256 internal constant PUB_LEN = 7;

    /**
     * @notice Fold one withdrawal's signals into the running accumulator.
     * @dev Mirrors `fold_signals`. ORDER-BINDING: chaining the accumulator through each hash makes
     *      POSITION part of the preimage, so a batcher cannot permute withdrawals relative to the
     *      calldata walked here. A commutative combiner would let them swap one user's recipient
     *      context onto another's nullifier and still match.
     */
    function foldSignals(uint256 acc, uint256[PUB_LEN] memory signals)
        internal
        pure
        returns (uint256)
    {
        uint256 a = PoseidonT6.hash([acc, signals[0], signals[1], signals[2], signals[3]]);
        return PoseidonT5.hash([a, signals[4], signals[5], signals[6]]);
    }

    /**
     * @notice The batch commitment over `signals`, from a zero accumulator.
     * @dev Mirrors `batch_commitment`. The caller supplies the per-withdrawal signals it is about to
     *      settle; the result must equal the aggregation proof's single public input.
     */
    function batchCommitment(uint256[PUB_LEN][] memory signals) internal pure returns (uint256 acc) {
        for (uint256 i = 0; i < signals.length; ++i) {
            acc = foldSignals(acc, signals[i]);
        }
    }
}
