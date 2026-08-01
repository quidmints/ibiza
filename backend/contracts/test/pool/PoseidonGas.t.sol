// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test, console} from 'forge-std/Test.sol';
import {PoseidonT3} from 'poseidon-solidity/PoseidonT3.sol';
import {PoseidonT5} from 'poseidon-solidity/PoseidonT5.sol';
import {PoseidonT6} from 'poseidon-solidity/PoseidonT6.sol';

/// Isolates the per-hash cost of each Poseidon arity. poseidon-solidity advertises ~1.3k for T3;
/// if T6 measures ~100x that, the build is hitting an unoptimised path rather than an inherent cost.
contract PoseidonGasTest is Test {
  function test_PerHashGas() public view {
    uint256 g = gasleft();
    PoseidonT3.hash([uint256(1), 2]);
    console.log('T3 (2 in)', g - gasleft());

    g = gasleft();
    PoseidonT5.hash([uint256(1), 2, 3, 4]);
    console.log('T5 (4 in)', g - gasleft());

    g = gasleft();
    PoseidonT6.hash([uint256(1), 2, 3, 4, 5]);
    console.log('T6 (5 in)', g - gasleft());
  }
}
