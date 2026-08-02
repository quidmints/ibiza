// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {PrivacyPoolSimple} from 'contracts/pool/implementations/PrivacyPoolSimple.sol';
import {PrivacyPool} from 'contracts/pool/PrivacyPool.sol';
import {IPrivacyPool} from 'contracts/pool/interfaces/IPrivacyPool.sol';
import {BatchVerifierLib} from 'contracts/pool/lib/BatchVerifierLib.sol';
import {NoirVerifierMock} from 'contracts/mock/verifiers/NoirVerifierMock.sol';
// MockEntrypoint is declared inside the Simple pool suite rather than its own file.
import {MockEntrypoint} from './PrivacyPoolSimple.t.sol';

/*
 * `withdrawBatch` IS FINALLY CALLED BY SOMETHING.
 *
 * WithdrawBatchGuardsTest states plainly that it "does NOT call withdrawBatch" and that the revert
 * paths are UNEXERCISED - it pins BatchCommitmentLib's properties instead. So until this file, the
 * entrypoint had no caller anywhere: not a test, not a contract. Every guard in it was unverified.
 *
 * AND THE FIRST THING CALLING IT FOUND: `AGGREGATION_VERIFIER` was declared and read but NEVER
 * ASSIGNED - no constructor argument, no setter, no deploy script. It was permanently address(0),
 * so `withdrawBatch` could not succeed for any input. A call into an empty address returns empty
 * returndata, which fails to decode as `bool` and reverts bare, saying nothing about the cause.
 * It is now a constructor argument, immutable, with an explicit refusal when unset.
 *
 * WHAT THIS FILE STILL DOES NOT COVER, so its green is not over-read: the HAPPY PATH. Settling a
 * real batch needs a genuine N=16 aggregation proof (~27 GB to produce, TODO.md sec. 2.4a), so
 * every test below stops at or before verification. Double-spend across a batch is likewise
 * untested. **Do not deploy `withdrawBatch` on the strength of this suite either** - but the guards
 * it does reach are now known to fire, which is strictly more than was true before.
 *
 * The verifier double is the same `NoirVerifierMock` the other pool suites use. Every guard tested
 * here fires BEFORE verification except `InvalidBatchProof`, which needs a verifier that says no -
 * so the double is answering "what does the contract do when the proof is rejected", not standing
 * in for the cryptography.
 */
contract WithdrawBatchEntrypointTest is Test {
  uint256 internal constant PUB_LEN = 7;
  uint256 internal constant CONTEXT_SLOT = 6;

  MockEntrypoint internal entrypoint;
  NoirVerifierMock internal aggregationVerifier;
  PrivacyPoolSimple internal pool;
  PrivacyPoolSimple internal poolWithoutAggregation;

  function setUp() public {
    entrypoint = new MockEntrypoint();
    aggregationVerifier = new NoirVerifierMock();
    pool = new PrivacyPoolSimple(
      address(entrypoint),
      address(new NoirVerifierMock()),
      address(new NoirVerifierMock()),
      address(entrypoint),
      address(aggregationVerifier)
    );
    poolWithoutAggregation = new PrivacyPoolSimple(
      address(entrypoint),
      address(new NoirVerifierMock()),
      address(new NoirVerifierMock()),
      address(entrypoint),
      address(0)
    );
  }

  // ── helpers ───────────────────────────────────────────────────────────────────────────────

  /// The context the pool derives for a withdrawal. Mirrors `_contextFor`; if these ever disagree
  /// the ContextMismatch test below starts passing for the wrong reason, so it is derived rather
  /// than hardcoded.
  function _contextFor(IPrivacyPool.Withdrawal memory w_) internal view returns (uint256) {
    return uint256(keccak256(abi.encode(w_, pool.SCOPE()))) % 21888242871839275222246405745257275088548364400416034343698204186575808495617;
  }

  function _withdrawals(uint256 n_) internal view returns (IPrivacyPool.Withdrawal[] memory ws_) {
    ws_ = new IPrivacyPool.Withdrawal[](n_);
    for (uint256 i; i < n_; ++i) {
      ws_[i] = IPrivacyPool.Withdrawal({processooor: address(uint160(0xA0 + i)), data: ''});
    }
  }

  /// Signals whose context slot MATCHES each withdrawal, so the context loop passes and execution
  /// reaches whatever is being tested next.
  function _matchingSignals(IPrivacyPool.Withdrawal[] memory ws_)
    internal
    view
    returns (uint256[PUB_LEN][] memory s_)
  {
    s_ = new uint256[PUB_LEN][](ws_.length);
    for (uint256 i; i < ws_.length; ++i) {
      for (uint256 j; j < PUB_LEN; ++j) s_[i][j] = i * 100 + j + 1;
      s_[i][CONTEXT_SLOT] = _contextFor(ws_[i]);
    }
  }

  // ── the guard that did not exist until the entrypoint was first called ────────────────────

  function test_RefusesWhenNoAggregationVerifierIsConfigured() public {
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(1);
    uint256[PUB_LEN][] memory s = _matchingSignals(ws);
    vm.expectRevert(PrivacyPool.AggregationNotConfigured.selector);
    poolWithoutAggregation.withdrawBatch(ws, s, '');
  }

  // ── the guards, in the order withdrawBatch applies them ───────────────────────────────────

  function test_RejectsMismatchedLengths() public {
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(3);
    uint256[PUB_LEN][] memory s = new uint256[PUB_LEN][](2);
    vm.expectRevert(abi.encodeWithSelector(PrivacyPool.BatchLengthMismatch.selector, 3, 2));
    pool.withdrawBatch(ws, s, '');
  }

  /// The comparison that stops a batcher pairing one user's proven withdrawal with another's
  /// payout address. Every position is checked, not just the first, because a loop that exits early
  /// or starts at 1 would pass a single-element test.
  function test_RejectsAnyWithdrawalWhoseContextDoesNotMatch() public {
    for (uint256 bad; bad < 3; ++bad) {
      IPrivacyPool.Withdrawal[] memory ws = _withdrawals(3);
      uint256[PUB_LEN][] memory s = _matchingSignals(ws);
      s[bad][CONTEXT_SLOT] ^= 1;
      vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
      pool.withdrawBatch(ws, s, '');
    }
  }

  /// Changing ANY field of a withdrawal must break the match, because `_contextFor` hashes the
  /// whole struct. Pins that the binding is to the struct rather than to the processooor alone.
  function test_AlteringTheWithdrawalBreaksTheContext() public {
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(1);
    uint256[PUB_LEN][] memory s = _matchingSignals(ws);
    ws[0].data = hex'01'; // signals still carry the context of the ORIGINAL withdrawal
    vm.expectRevert(IPrivacyPool.ContextMismatch.selector);
    pool.withdrawBatch(ws, s, '');
  }

  function test_RejectsEmptyBatch() public {
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(0);
    uint256[PUB_LEN][] memory s = new uint256[PUB_LEN][](0);
    vm.expectRevert(BatchVerifierLib.EmptyBatch.selector);
    pool.withdrawBatch(ws, s, '');
  }

  /// A batch longer than the circuit's compile-time BATCH_N cannot have been proved by it, and the
  /// commitment fold would absorb any length without complaint - so this is a separate check.
  function test_RejectsOverlongBatch() public {
    uint256 tooMany = pool.MAX_BATCH() + 1;
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(tooMany);
    uint256[PUB_LEN][] memory s = _matchingSignals(ws); // contexts must pass to reach this guard
    vm.expectRevert(
      abi.encodeWithSelector(BatchVerifierLib.BatchTooLarge.selector, tooMany, pool.MAX_BATCH())
    );
    pool.withdrawBatch(ws, s, '');
  }

  function test_RejectsABatchWhoseProofDoesNotVerify() public {
    aggregationVerifier.setShouldVerify(false);
    IPrivacyPool.Withdrawal[] memory ws = _withdrawals(2);
    uint256[PUB_LEN][] memory s = _matchingSignals(ws);
    vm.expectRevert(BatchVerifierLib.InvalidBatchProof.selector);
    pool.withdrawBatch(ws, s, '');
  }

  /// MAX_BATCH must equal the circuit's BATCH_N. Pinned here because the two live in different
  /// languages and nothing else compares them.
  function test_MaxBatchMatchesTheCircuit() public view {
    assertEq(pool.MAX_BATCH(), 16, 'MAX_BATCH diverged from aggregate_withdrawals BATCH_N');
  }
}
