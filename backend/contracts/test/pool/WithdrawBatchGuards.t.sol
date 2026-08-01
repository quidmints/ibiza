// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {BatchCommitmentLib} from 'contracts/pool/lib/BatchCommitmentLib.sol';

/*
 * THE PROPERTIES `withdrawBatch`'s GUARDS REST ON.
 *
 * BE PRECISE ABOUT WHAT THIS FILE IS. It does NOT call `withdrawBatch`. It pins the properties of
 * `BatchCommitmentLib` that the guards ASSUME - that the commitment is order-binding, length-binding,
 * and sensitive to every context and root - because if any of those is false, guards written on top
 * of them are decorative no matter how they are tested.
 *
 * WHAT IS STILL UNTESTED, so this suite's green is not over-read:
 *   1. `withdrawBatch` itself - no test calls it. The revert paths (BatchLengthMismatch,
 *      ContextMismatch, EmptyBatch, BatchTooLarge) are UNEXERCISED.
 *   2. The HAPPY PATH. Settling a real batch needs a genuine N=16 aggregation proof, ~27 GB to
 *      produce, so it cannot be made on an ordinary dev machine (TODO.md sec. 2.4a).
 *   3. Double-spend ACROSS a batch - two withdrawals sharing a nullifier. `_spend` should reject the
 *      second, but nothing here proves it.
 * **Do not deploy `withdrawBatch` on the strength of this suite.**
 *
 * WHY NO MOCK VERIFIER. One returning `true` would let (1) and (3) be tested today, at the cost of
 * asserting that the only thing that really matters - does the proof bind? - is irrelevant. The
 * circuit's soundness is established separately and properly by the `rmin` harness (real proof
 * ACCEPTED, valid proof of a DIFFERENT statement REFUSED, garbage REFUSED). Standing rule: never mock.
 */
contract WithdrawBatchGuardsTest is Test {
  uint256 internal constant PUB_LEN = 7;
  uint256 internal constant MAX_BATCH = 16;

  function _signals(uint256 n) internal pure returns (uint256[PUB_LEN][] memory s) {
    s = new uint256[PUB_LEN][](n);
    for (uint256 i = 0; i < n; ++i) {
      for (uint256 j = 0; j < PUB_LEN; ++j) {
        s[i][j] = i * 100 + j + 1;
      }
    }
  }

  // ── the two guards inside BatchVerifierLib, which run before the verifier is ever called ──────

  /// An empty batch folds to the ZERO accumulator. Without this guard a batch settling nothing would
  /// present a commitment that a proof could, in principle, be made for.
  function test_EmptyBatchIsRejected() public {
    uint256[PUB_LEN][] memory none = new uint256[PUB_LEN][](0);
    assertEq(BatchCommitmentLib.batchCommitment(none), 0, 'empty batch must fold to zero');
    // The guard exists because that zero is otherwise a perfectly ordinary commitment value.
  }

  /// The circuit's BATCH_N is a COMPILE-TIME constant, so a longer batch cannot have been proved by
  /// it. The commitment alone cannot catch this - the fold happily absorbs any length.
  function test_TheCommitmentAloneCannotCatchAnOverlongBatch() public pure {
    uint256[PUB_LEN][] memory big = _signals(MAX_BATCH + 1);
    // It folds without complaint. That is precisely why `BatchTooLarge` is a separate check.
    assertTrue(BatchCommitmentLib.batchCommitment(big) != 0);
  }

  // ── the properties the guards rest on ─────────────────────────────────────────────────────────

  /// ORDER. A permuted batch must produce a different commitment, or a batcher could pair one user's
  /// recipient context with another's nullifier while still satisfying the proof.
  function test_PermutingTheBatchChangesTheCommitment() public pure {
    uint256[PUB_LEN][] memory a = _signals(MAX_BATCH);
    uint256[PUB_LEN][] memory b = _signals(MAX_BATCH);
    (b[0], b[1]) = (b[1], b[0]);
    assertTrue(
      BatchCommitmentLib.batchCommitment(a) != BatchCommitmentLib.batchCommitment(b),
      'the fold is commutative - the batch can be permuted'
    );
  }

  /// CONTEXT IS SIGNAL 6, and altering it must change the commitment - that is what makes the
  /// per-withdrawal context comparison in `withdrawBatch` load-bearing rather than decorative.
  function test_ChangingAContextChangesTheCommitment() public pure {
    uint256[PUB_LEN][] memory a = _signals(MAX_BATCH);
    uint256 baseline = BatchCommitmentLib.batchCommitment(a);
    for (uint256 i = 0; i < MAX_BATCH; ++i) {
      uint256[PUB_LEN][] memory m = _signals(MAX_BATCH);
      m[i][6] ^= 1; // signal 6 is `context`
      assertTrue(
        BatchCommitmentLib.batchCommitment(m) != baseline,
        'a withdrawal context does not affect the commitment'
      );
    }
  }

  /// LENGTH. Truncating the batch must not collide - the cheapest attack is to drop a withdrawal.
  function test_TruncatingTheBatchChangesTheCommitment() public pure {
    uint256[PUB_LEN][] memory full = _signals(MAX_BATCH);
    uint256[PUB_LEN][] memory short = _signals(MAX_BATCH - 1);
    assertTrue(
      BatchCommitmentLib.batchCommitment(full) != BatchCommitmentLib.batchCommitment(short),
      'a truncated batch produced the same commitment'
    );
  }

  /// THE ROOT MEMO MUST NOT WEAKEN ANYTHING. `withdrawBatch` checks each DISTINCT state/identity root
  /// once instead of per withdrawal. That is only equivalent if differing roots are still each
  /// checked - so a batch carrying two different roots must not let the second ride on the first.
  /// This pins the ASSUMPTION the memo rests on: the roots are part of the committed signals, so a
  /// batch with a different root set is a different batch.
  function test_RootsAreCommittedSoTheMemoCannotHideOne() public pure {
    uint256[PUB_LEN][] memory a = _signals(MAX_BATCH);
    uint256[PUB_LEN][] memory b = _signals(MAX_BATCH);
    b[3][3] ^= 1; // signal 3 is `state_root`, on the 4th withdrawal
    assertTrue(
      BatchCommitmentLib.batchCommitment(a) != BatchCommitmentLib.batchCommitment(b),
      'a state root change is invisible to the commitment'
    );
    uint256[PUB_LEN][] memory c = _signals(MAX_BATCH);
    c[3][5] ^= 1; // signal 5 is `identity_root`
    assertTrue(
      BatchCommitmentLib.batchCommitment(a) != BatchCommitmentLib.batchCommitment(c),
      'an identity root change is invisible to the commitment'
    );
  }
}
