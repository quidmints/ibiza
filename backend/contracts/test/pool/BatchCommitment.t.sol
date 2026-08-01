// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {BatchCommitmentLib} from 'contracts/pool/lib/BatchCommitmentLib.sol';

/*
 * THE CIRCUIT AND THE CONTRACT MUST AGREE ABOUT THE BATCH COMMITMENT (TODO.md sec. 2.4).
 *
 * The aggregation verifier exposes ONE public input - the commitment - so this fold is the only
 * thing tying that field back to the individual withdrawals a batch settles. If the two
 * implementations diverge, nothing says so: the circuit proves happily, the contract recomputes
 * happily, and they simply produce different field elements.
 *
 * Solidity testing Solidity cannot catch that, exactly as Go testing Go could not catch the notary
 * Merkle mismatch (see NotaryRegistryProofTest) - a shared misunderstanding makes a generator and
 * its own checker agree and both be wrong. So the expected value below is produced by the REAL
 * CIRCUIT and recomputed here by the REAL library the contract will use.
 *
 * FIXTURE PROVENANCE. Emitted by `aggregate_withdrawals::batch_commitment` at N=16 with
 * `pi[i][j] = i * 100 + j + 1`. Regenerate by adding a `println(batch_commitment(pi))` test to
 * backend/circuits/aggregate_withdrawals/src/main.nr and running `nargo test --show-output`.
 */
contract BatchCommitmentTest is Test {
  uint256 internal constant N = 16;
  uint256 internal constant PUB_LEN = 7;

  /// Emitted by the circuit. If this test fails, the circuit and contract have diverged - do NOT
  /// "fix" it by pasting in whatever Solidity now produces without first establishing which side moved.
  uint256 internal constant EXPECTED =
    0x10b1c1fb68f9667a893d791c0b18afe571ac415a0377e9bff7a1d2c9224d9349;

  function _signals() internal pure returns (uint256[PUB_LEN][] memory s) {
    s = new uint256[PUB_LEN][](N);
    for (uint256 i = 0; i < N; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        s[i][j] = i * 100 + j + 1;
      }
    }
  }

  /// THE BASELINE: Solidity reproduces the value the Noir circuit computed.
  function test_MatchesTheCircuit() public pure {
    assertEq(
      BatchCommitmentLib.batchCommitment(_signals()),
      EXPECTED,
      'the circuit and the contract disagree about the batch commitment'
    );
  }

  /// ...and it is not vacuous: changing any single signal must change the result. Without this, a
  /// fold that ignored its inputs entirely would pass the test above.
  function test_EverySignalIsBound() public pure {
    uint256 baseline = BatchCommitmentLib.batchCommitment(_signals());
    for (uint256 i = 0; i < N; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        uint256[PUB_LEN][] memory m = _signals();
        m[i][j] ^= 1;
        assertTrue(
          BatchCommitmentLib.batchCommitment(m) != baseline,
          'a signal position does not affect the commitment'
        );
      }
    }
  }

  /// ORDER-BINDING. Swapping two withdrawals must change the commitment, or a batcher could permute
  /// the batch relative to the calldata the contract walks - moving one user's recipient context
  /// onto another's nullifier while still matching.
  function test_OrderIsBound() public pure {
    uint256[PUB_LEN][] memory a = _signals();
    uint256[PUB_LEN][] memory b = _signals();
    (b[0], b[1]) = (b[1], b[0]);
    assertTrue(
      BatchCommitmentLib.batchCommitment(a) != BatchCommitmentLib.batchCommitment(b),
      'the fold is commutative - withdrawals can be permuted'
    );
  }

  /// A batch of a different LENGTH must not collide with this one. Truncating the calldata is the
  /// cheapest thing an attacker can try.
  function test_LengthIsBound() public pure {
    uint256[PUB_LEN][] memory full = _signals();
    uint256[PUB_LEN][] memory short = new uint256[PUB_LEN][](N - 1);
    for (uint256 i = 0; i < N - 1; ++i) short[i] = full[i];
    assertTrue(
      BatchCommitmentLib.batchCommitment(short) != BatchCommitmentLib.batchCommitment(full),
      'a shorter batch produced the same commitment'
    );
  }

  /// GAS: what the on-chain recompute actually costs per withdrawal.
  function test_GasOfTheFold() public view {
    uint256[PUB_LEN][] memory s = _signals();
    uint256 g0 = gasleft();
    BatchCommitmentLib.batchCommitment(s);
    uint256 used = g0 - gasleft();
    console.log("fold gas total", used);
    console.log("per withdrawal ", used / N);
  }

  /// The empty batch is the zero accumulator, and must not equal any non-empty one.
  function test_EmptyBatchIsDistinct() public pure {
    uint256[PUB_LEN][] memory none = new uint256[PUB_LEN][](0);
    assertEq(BatchCommitmentLib.batchCommitment(none), 0);
    assertTrue(BatchCommitmentLib.batchCommitment(_signals()) != 0);
  }
}
