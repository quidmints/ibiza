// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {Entrypoint} from '../../contracts/pool/Entrypoint.sol';
import {IEntrypoint} from '../../contracts/pool/interfaces/IEntrypoint.sol';
import {Constants} from '../../contracts/pool/lib/Constants.sol';

/// Minimal in-test ERC-7812 registry (keccak-isolated) — records statements so we can assert the
/// Entrypoint anchors each ASP root. Mirrors the holder-test pattern that sidesteps the real
/// registry's Poseidon-under-Forge linking issue; behaviour we assert on (dedup, store) is identical.
contract MockEvidenceRegistry is IEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;
  uint256 public count;

  function addStatement(bytes32 key, bytes32 value) external {
    if (statements[key] != bytes32(0)) revert KeyAlreadyExists(key);
    statements[key] = value;
    count++;
  }

  function removeStatement(bytes32 key) external {
    if (statements[key] == bytes32(0)) revert KeyDoesNotExist(key);
    delete statements[key];
    count--;
  }

  function updateStatement(bytes32 key, bytes32 newValue) external {
    if (statements[key] == bytes32(0)) revert KeyDoesNotExist(key);
    statements[key] = newValue;
  }

  function getRootTimestamp(bytes32) external view returns (uint256) {
    return block.timestamp;
  }

  function getIsolatedKey(address source, bytes32 key) external pure returns (bytes32) {
    return keccak256(abi.encodePacked(source, key));
  }
}

contract EntrypointAspTest is Test {
  Entrypoint internal entrypoint;
  MockEvidenceRegistry internal registry;

  address internal owner = address(0xA011);
  address internal postman = address(0xB022);

  // A valid IPFS CID per updateRoot() is 32..64 bytes (this is 45).
  string internal constant CID = 'QmA1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8S9T0UVW';

  function setUp() public {
    registry = new MockEvidenceRegistry();
    Entrypoint impl = new Entrypoint();
    bytes memory init = abi.encodeCall(Entrypoint.initialize, (owner, postman, address(registry)));
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
    entrypoint = Entrypoint(payable(address(proxy)));
  }

  function _expectedKey(uint256 _index) internal view returns (bytes32) {
    return
      bytes32(uint256(keccak256(abi.encodePacked('PP_ASP_ROOT', address(entrypoint), _index))) % Constants.SNARK_SCALAR_FIELD);
  }

  function test_initialize_setsEvidenceRegistry() public view {
    assertEq(address(entrypoint.EVIDENCE_REGISTRY()), address(registry));
  }

  function test_updateRoot_anchorsRootInRegistry() public {
    uint256 root = 12_345;
    vm.prank(postman);
    uint256 index = entrypoint.updateRoot(root, CID);

    assertEq(index, 0);
    assertEq(registry.statements(_expectedKey(0)), bytes32(root));
    assertEq(registry.count(), 1);
  }

  function test_eachRootGetsDistinctStatementKey() public {
    vm.startPrank(postman);
    entrypoint.updateRoot(111, CID);
    entrypoint.updateRoot(222, CID);
    vm.stopPrank();

    assertEq(registry.statements(_expectedKey(0)), bytes32(uint256(111)));
    assertEq(registry.statements(_expectedKey(1)), bytes32(uint256(222)));
    assertEq(registry.count(), 2);
  }

  function test_latestActiveRoot_respectsActivationDelay() public {
    uint256 root = 777;
    vm.prank(postman);
    entrypoint.updateRoot(root, CID);

    // Pending during the challenge window.
    vm.expectRevert(IEntrypoint.NoActiveRoot.selector);
    entrypoint.latestActiveRoot();

    // Active once it ages past ROOT_ACTIVATION_DELAY.
    vm.warp(block.timestamp + entrypoint.ROOT_ACTIVATION_DELAY());
    assertEq(entrypoint.latestActiveRoot(), root);
  }

  function test_latestActiveRoot_keepsPreviousRootDuringWindow() public {
    vm.prank(postman);
    entrypoint.updateRoot(111, CID);
    vm.warp(block.timestamp + entrypoint.ROOT_ACTIVATION_DELAY());

    // root 111 is active; pushing 222 must NOT instantly switch the gate (222 still pending).
    vm.prank(postman);
    entrypoint.updateRoot(222, CID);
    assertEq(entrypoint.latestActiveRoot(), 111);

    // After the window clears, 222 becomes the active root.
    vm.warp(block.timestamp + entrypoint.ROOT_ACTIVATION_DELAY());
    assertEq(entrypoint.latestActiveRoot(), 222);
  }

  function test_latestActiveRoot_revertsWhenNoRoots() public {
    vm.expectRevert(IEntrypoint.NoRootsAvailable.selector);
    entrypoint.latestActiveRoot();
  }

  function test_initialize_revertsOnZeroRegistry() public {
    Entrypoint impl = new Entrypoint();
    bytes memory init = abi.encodeCall(Entrypoint.initialize, (owner, postman, address(0)));
    vm.expectRevert(IEntrypoint.ZeroAddress.selector);
    new ERC1967Proxy(address(impl), init);
  }
}
