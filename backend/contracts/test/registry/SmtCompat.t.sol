// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {PoseidonUnit2L, PoseidonUnit3L} from '../../contracts/libraries/Poseidon.sol';

// Drives solarity's SMT directly with the same hashers RevocationRegistry uses.
contract SolaritySmtHarness {
  using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

  SparseMerkleTree.Bytes32SMT internal _tree;

  constructor(uint32 depth_) {
    _tree.initialize(depth_);
    _tree.setHashers(_h2, _h3);
  }

  function add(bytes32 k, bytes32 v) external {
    _tree.add(k, v);
  }

  function root() external view returns (bytes32) {
    return _tree.getRoot();
  }

  function _h2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit2L.poseidon([uint256(a), uint256(b)]));
  }

  function _h3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit3L.poseidon([uint256(a), uint256(b), uint256(c)]));
  }
}

/*
 * THE COMPATIBILITY QUESTION THAT GATES THE revocation_root WIRING.
 *
 * The Noir exclusion gadget (noir_dl_lib/src/smt.nr) is differential-tested against CIRCOMLIBJS.
 * The on-chain registry uses @solarity's SparseMerkleTree. Both hash leaves as Poseidon(key,value,1)
 * and nodes as Poseidon(L,R) - confirmed by reading the source.
 *
 * IDENTICAL HASHING DOES NOT IMPLY AN IDENTICAL TREE. Bit order, sparse-subtree collapsing and
 * single-leaf short-circuiting are free choices that change the ROOT for the same key set. If
 * solarity places nodes differently the circuit could never verify against the registry root, and
 * the gadget would have to be re-derived against solarity. Reading the hash functions is NOT enough
 * to answer this - only building the same key set in both is.
 */
contract SmtCompatTest is Test {
  /// Root circomlibjs produces for {1:11, 2:22, 7:77, 9:99}.
  bytes32 internal constant CIRCOMLIBJS_ROOT =
    bytes32(uint256(518494836555806875742446376098343000486175381741467406929375446995815951571));

  function test_SolarityMatchesCircomlibjsRoot() public {
    SolaritySmtHarness t = new SolaritySmtHarness(20);
    t.add(bytes32(uint256(1)), bytes32(uint256(11)));
    t.add(bytes32(uint256(2)), bytes32(uint256(22)));
    t.add(bytes32(uint256(7)), bytes32(uint256(77)));
    t.add(bytes32(uint256(9)), bytes32(uint256(99)));

    emit log_named_uint('solarity  ', uint256(t.root()));
    emit log_named_uint('circomlibjs', uint256(CIRCOMLIBJS_ROOT));

    assertEq(
      t.root(),
      CIRCOMLIBJS_ROOT,
      'solarity and circomlib build DIFFERENT trees - the Noir gadget cannot verify against the registry'
    );
  }
}
