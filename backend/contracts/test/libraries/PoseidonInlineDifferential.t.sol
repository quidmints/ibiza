// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from 'forge-std/Test.sol';

import {PoseidonT2} from 'poseidon-solidity/PoseidonT2.sol';
import {PoseidonT3} from 'poseidon-solidity/PoseidonT3.sol';
import {PoseidonT4} from 'poseidon-solidity/PoseidonT4.sol';
import {PoseidonT5} from 'poseidon-solidity/PoseidonT5.sol';
import {PoseidonT6} from 'poseidon-solidity/PoseidonT6.sol';

import {PoseidonT2Inline} from 'contracts/libraries/inline/PoseidonT2Inline.sol';
import {PoseidonT3Inline} from 'contracts/libraries/inline/PoseidonT3Inline.sol';
import {PoseidonT4Inline} from 'contracts/libraries/inline/PoseidonT4Inline.sol';
import {PoseidonT5Inline} from 'contracts/libraries/inline/PoseidonT5Inline.sol';
import {PoseidonT6Inline} from 'contracts/libraries/inline/PoseidonT6Inline.sol';

/*
 * THE INLINED POSEIDON MUST AGREE WITH THE ORIGINAL, BIT FOR BIT, AT EVERY ARITY.
 *
 * The inline copies exist purely to avoid the DELEGATECALL a `public` library function costs - the
 * arithmetic is meant to be untouched. But "meant to be" is not a guarantee: the copies are produced
 * mechanically, and a single mangled constant would give a Poseidon that is fast, plausible and
 * WRONG. Because the circuits, the wallet and every SMT in this repo assume ONE Poseidon, that would
 * silently fork every commitment in the system rather than fail loudly.
 *
 * So this suite is the precondition for using them anywhere. It pins each arity against the upstream
 * `public` implementation over ordinary values, the boundaries (0, 1, p-1) and pseudo-random vectors.
 * An earlier revision of this work equality-checked only T3 and inferred the rest; that inference is
 * exactly what this file replaces.
 */
contract PoseidonInlineDifferentialTest is Test {
  /// BN254 scalar field order. Inputs are reduced mod p by the library, so p-1 is the real boundary.
  uint256 internal constant P =
    21888242871839275222246405745257275088548364400416034343698204186575808495617;

  function _cases() internal pure returns (uint256[] memory v) {
    v = new uint256[](8);
    v[0] = 0;
    v[1] = 1;
    v[2] = 2;
    v[3] = P - 1;
    v[4] = P - 2;
    v[5] = 0x1234567890abcdef;
    v[6] = 12345678901234567890123456789012345678901234567890;
    v[7] = uint256(keccak256('quid.poseidon.differential')) % P;
  }

  function test_T2_MatchesUpstream() public pure {
    uint256[] memory v = _cases();
    for (uint256 i = 0; i < v.length; ++i) {
      assertEq(PoseidonT2Inline.hash([v[i]]), PoseidonT2.hash([v[i]]), 'T2 diverged');
    }
  }

  function test_T3_MatchesUpstream() public pure {
    uint256[] memory v = _cases();
    for (uint256 i = 0; i < v.length; ++i) {
      uint256 a = v[i];
      uint256 b = v[(i + 3) % v.length];
      assertEq(PoseidonT3Inline.hash([a, b]), PoseidonT3.hash([a, b]), 'T3 diverged');
    }
  }

  function test_T4_MatchesUpstream() public pure {
    uint256[] memory v = _cases();
    for (uint256 i = 0; i < v.length; ++i) {
      uint256 a = v[i];
      uint256 b = v[(i + 3) % v.length];
      uint256 c = v[(i + 5) % v.length];
      assertEq(PoseidonT4Inline.hash([a, b, c]), PoseidonT4.hash([a, b, c]), 'T4 diverged');
    }
  }

  function test_T5_MatchesUpstream() public pure {
    uint256[] memory v = _cases();
    for (uint256 i = 0; i < v.length; ++i) {
      uint256 a = v[i];
      uint256 b = v[(i + 3) % v.length];
      uint256 c = v[(i + 5) % v.length];
      uint256 d = v[(i + 7) % v.length];
      assertEq(PoseidonT5Inline.hash([a, b, c, d]), PoseidonT5.hash([a, b, c, d]), 'T5 diverged');
    }
  }

  function test_T6_MatchesUpstream() public pure {
    uint256[] memory v = _cases();
    for (uint256 i = 0; i < v.length; ++i) {
      uint256 a = v[i];
      uint256 b = v[(i + 3) % v.length];
      uint256 c = v[(i + 5) % v.length];
      uint256 d = v[(i + 7) % v.length];
      uint256 e = v[(i + 1) % v.length];
      assertEq(
        PoseidonT6Inline.hash([a, b, c, d, e]),
        PoseidonT6.hash([a, b, c, d, e]),
        'T6 diverged'
      );
    }
  }

  /// Fuzzed, so agreement is not only pinned at values a human chose.
  function testFuzz_T3_MatchesUpstream(uint256 a, uint256 b) public pure {
    assertEq(PoseidonT3Inline.hash([a, b]), PoseidonT3.hash([a, b]));
  }

  function testFuzz_T6_MatchesUpstream(uint256 a, uint256 b, uint256 c) public pure {
    assertEq(PoseidonT6Inline.hash([a, b, c, 7, 9]), PoseidonT6.hash([a, b, c, 7, 9]));
  }

  /// The saving that justifies all of the above.
  function test_InlineIsSubstantiallyCheaper() public {
    uint256 g = gasleft();
    PoseidonT3.hash([uint256(1), 2]);
    uint256 pub = g - gasleft();

    g = gasleft();
    PoseidonT3Inline.hash([uint256(1), 2]);
    uint256 inl = g - gasleft();

    console.log('T3 public  ', pub);
    console.log('T3 inlined ', inl);
    assertLt(inl * 4, pub, 'inlining is no longer paying for itself - re-measure before relying on it');
  }
}
