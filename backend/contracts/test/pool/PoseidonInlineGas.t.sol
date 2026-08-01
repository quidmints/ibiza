// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {PoseidonT3Inline} from 'contracts/libraries/inline/PoseidonT3Inline.sol';
import {PoseidonT5Inline} from 'contracts/libraries/inline/PoseidonT5Inline.sol';
import {PoseidonT6Inline} from 'contracts/libraries/inline/PoseidonT6Inline.sol';
import {PoseidonT3} from 'poseidon-solidity/PoseidonT3.sol';

/// Is the 32.5k/hash cost the DELEGATECALL boundary, or inherent to the implementation?
/// Identical maths, `internal` instead of `public`, so the compiler inlines it.
contract PoseidonInlineGasTest is Test {
  function test_InlineVsPublic() public {
    uint256 g = gasleft();
    PoseidonT3.hash([uint256(1), 2]);
    uint256 pub3 = g - gasleft();

    g = gasleft();
    PoseidonT3Inline.hash([uint256(1), 2]);
    uint256 int3 = g - gasleft();

    g = gasleft();
    PoseidonT5Inline.hash([uint256(1), 2, 3, 4]);
    uint256 int5 = g - gasleft();

    g = gasleft();
    PoseidonT6Inline.hash([uint256(1), 2, 3, 4, 5]);
    uint256 int6 = g - gasleft();

    console.log('T3 public  ', pub3);
    console.log('T3 internal', int3);
    console.log('T5 internal', int5);
    console.log('T6 internal', int6);
    console.log('fold/withdrawal (T6+T5 internal)', int5 + int6);
  }

  /// The inlined copy must produce the SAME hash - a faster function that disagrees is useless,
  /// and would silently fork every commitment in the repo.
  function test_InlineMatchesPublic() public pure {
    assertEq(PoseidonT3Inline.hash([uint256(7), 9]), PoseidonT3.hash([uint256(7), 9]));
  }
}
