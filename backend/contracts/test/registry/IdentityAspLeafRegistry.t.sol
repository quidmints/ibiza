// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';

import {IdentityAspLeafRegistry} from '../../contracts/registry/IdentityAspLeafRegistry.sol';

contract IdentityAspLeafRegistryTest is Test {
  IdentityAspLeafRegistry internal registry;

  function setUp() public {
    registry = new IdentityAspLeafRegistry();
  }

  function _leaves() internal pure returns (bytes32[] memory leaves) {
    leaves = new bytes32[](2);
    leaves[0] = keccak256('holder-root-1');
    leaves[1] = keccak256('holder-root-2');
  }

  function test_publishLeaves_succeeds() public {
    bytes32 root = keccak256('asp-root');
    bytes32[] memory leaves = _leaves();

    registry.publishLeaves(root, leaves);

    assertTrue(registry.published(root));
  }

  function test_publishLeaves_emitsLeaves() public {
    bytes32 root = keccak256('asp-root');
    bytes32[] memory leaves = _leaves();

    vm.expectEmit(true, false, false, true);
    emit IdentityAspLeafRegistry.LeavesPublished(root, leaves);
    registry.publishLeaves(root, leaves);
  }

  function test_publishLeaves_revertsOnEmptyLeafSet() public {
    vm.expectRevert(IdentityAspLeafRegistry.EmptyLeafSet.selector);
    registry.publishLeaves(keccak256('asp-root'), new bytes32[](0));
  }

  function test_publishLeaves_revertsOnDuplicatePublication() public {
    bytes32 root = keccak256('asp-root');
    registry.publishLeaves(root, _leaves());

    vm.expectRevert(IdentityAspLeafRegistry.AlreadyPublished.selector);
    registry.publishLeaves(root, _leaves());
  }

  function test_publishLeaves_distinctRootsDoNotCollide() public {
    bytes32 rootA = keccak256('asp-root-a');
    bytes32 rootB = keccak256('asp-root-b');

    registry.publishLeaves(rootA, _leaves());
    registry.publishLeaves(rootB, _leaves());

    assertTrue(registry.published(rootA));
    assertTrue(registry.published(rootB));
  }

  function test_publishLeaves_isPermissionless() public {
    // No role/owner check - anyone can call. See the contract's own doc comment for why: it
    // makes no trust claim, consumers always independently re-verify the Poseidon root.
    vm.prank(address(0xDEAD));
    registry.publishLeaves(keccak256('asp-root'), _leaves());
    assertTrue(registry.published(keccak256('asp-root')));
  }
}
