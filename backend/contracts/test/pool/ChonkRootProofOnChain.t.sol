// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {ChonkRootHonkVerifier} from '../../contracts/pool/verifiers/ChonkRootHonkVerifier.sol';

/*
 * THE FOLD REACHES THE CHAIN AFTER ALL (2026-08-04).
 *
 * TODO sec. 2.18ea recorded this path as BLOCKED, and it was wrong. Verifying a chonk proof emits
 * IPA openings over Grumpkin, the EVM has no Grumpkin precompiles, and every attempt to build an
 * EVM-targeted verifier over one failed. The missing piece was not a precompile - it was a PROOF
 * TYPE. `PROOF_TYPE_ROOT_ROLLUP_HONK = 5` does not accumulate the child's IPA claim, it DISCHARGES
 * it, verifying the inner product argument natively in-circuit. What comes out has nothing nested,
 * so it is an ordinary UltraHonk proof and a Solidity verifier generates from it normally.
 *
 * THE CHAIN THIS FIXTURE CAME FROM:
 *   16 withdrawals  ->  chonk fold           (572 MB)   ->  1,223-field chonk proof
 *                   ->  withdraw_ivc_wrapper (1.9 GB)   ->  480-field rollup proof, IPA ACCUMULATED
 *                   ->  this root circuit    (8.87 GB)  ->  358-field proof, IPA DISCHARGED
 *
 * EXACTLY TWO CHILDREN, NOT ONE. bb refuses a single-child root outright: *"Root rollup must
 * accumulate two IPA proofs"*. So one on-chain proof settles TWO folds - 32 withdrawals here - and a
 * partial batch has to pad the second child rather than omit it.
 *
 * WHAT THIS FIXTURE IS AND IS NOT. Both children are the SAME fold, so the four public inputs are two
 * identical (commitment, count) pairs. That makes this a test of the MECHANISM - that a chonk fold
 * can be discharged to an EVM-verifiable proof - and NOT a demonstration that two distinct batches
 * compose. Settling this on-chain would be settling the same sixteen withdrawals twice; the pool's
 * nullifiers would refuse it, but the PROOF would verify, so nothing here should be read as evidence
 * that the root binds two different batches. That needs a second, distinct fold.
 *
 * WHY IT IS STILL NOT OBVIOUSLY THE RIGHT PATH. `RecursionTreeProofOnChain.t.sol` settles sixteen
 * withdrawals from a tree at a 2.11 GB peak and 2,776,678 gas, with no chonk anywhere. This path
 * peaks at 8.87 GB for the discharge. What it buys instead is that batch size stops being
 * compile-time: the fold takes any N with one set of circuits, and the root always takes exactly two
 * children whatever they contain.
 */
contract ChonkRootProofOnChainTest is Test {
  ChonkRootHonkVerifier internal verifier;
  string internal fixture;

  function setUp() public {
    fixture = vm.readFile('test/fixtures/chonk_root.json');
    verifier = new ChonkRootHonkVerifier();
  }

  function _proof() internal view returns (bytes memory) {
    return vm.parseJsonBytes(fixture, '.proof');
  }

  function _publicInputs() internal view returns (bytes32[] memory) {
    return vm.parseJsonBytes32Array(fixture, '.publicInputs');
  }

  /// THE CLAIM: a folded batch, discharged through a root-rollup circuit, verifies on-chain.
  function test_aDischargedChonkFoldVerifiesOnChain() public view {
    assertTrue(
      verifier.verify(_proof(), _publicInputs()),
      'the discharged chonk fold was rejected by its own generated verifier'
    );
  }

  /// The shape: two children, each contributing (commitment, count). The counts are what tie the
  /// public inputs to how many withdrawals the folds actually absorbed.
  function test_theRootCarriesBothFoldsCommitmentAndCount() public view {
    bytes32[] memory pubs = _publicInputs();
    assertEq(pubs.length, 4, 'a root rollup carries exactly two children');
    assertEq(uint256(pubs[1]), 16, 'first fold did not report sixteen withdrawals');
    assertEq(uint256(pubs[3]), 16, 'second fold did not report sixteen withdrawals');
  }

  /// Against the tree, which settles the same sixteen withdrawals with no chonk at all.
  function test_MeasureChonkRootVerificationGas() public view {
    bytes memory p = _proof();
    bytes32[] memory pubs = _publicInputs();

    uint256 g0 = gasleft();
    bool ok = verifier.verify(p, pubs);
    uint256 used = g0 - gasleft();

    assertTrue(ok);
    console.log('chonk root verify() gas (two folds of 16):', used);
    console.log('  per withdrawal across 32:', used / 32);
    console.log('  recursion tree, 16:       2776678 (173542 each)');
    console.log('  flat aggregation, 16:     2980094 (186255 each)');
  }

  /*
   * NON-VACUITY. Without these a verifier ignoring its arguments would pass everything above.
   */
  function test_aTamperedProofIsRejected() public {
    bytes memory p = _proof();
    p[3000] = bytes1(uint8(p[3000]) ^ 0x01);
    vm.expectRevert();
    verifier.verify(p, _publicInputs());
  }

  /// Changing a fold's commitment claims a DIFFERENT sixteen withdrawals.
  function test_aDifferentFoldCommitmentIsRejected() public {
    bytes32[] memory pubs = _publicInputs();
    pubs[0] = bytes32(uint256(pubs[0]) ^ 1);
    vm.expectRevert();
    verifier.verify(_proof(), pubs);
  }

  /// And so does lying about how many withdrawals a fold covered - `count` is the only thing tying
  /// the commitment to a batch SIZE, and the settlement half must check it against the calldata.
  function test_aDifferentCountIsRejected() public {
    bytes32[] memory pubs = _publicInputs();
    pubs[1] = bytes32(uint256(15));
    vm.expectRevert();
    verifier.verify(_proof(), pubs);
  }
}
