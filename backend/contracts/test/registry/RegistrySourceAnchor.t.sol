// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {RegistrySourceAnchor} from '../../contracts/registry/RegistrySourceAnchor.sol';

/// Minimal in-test ERC-7812 registry - same pattern as EntrypointAsp.t.sol's MockEvidenceRegistry
/// (keccak-isolated, sidesteps the real registry's Poseidon-under-Forge linking issue).
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

contract RegistrySourceAnchorTest is Test {
  RegistrySourceAnchor internal anchor;
  MockEvidenceRegistry internal registry;

  address internal admin = address(0xA011);
  address internal postman = address(0xB022);
  address internal stranger = address(0xC033);

  bytes32 internal constant NOTARY_REGISTRY = keccak256('UA_NOTARY_REGISTRY');
  bytes32 internal constant OTHER_REGISTRY = keccak256('SOME_OTHER_LIST');

  uint256 internal constant SNARK_SCALAR_FIELD =
    21888242871839275222246405745257275088548364400416034343698204186575808495617;

  function setUp() public {
    registry = new MockEvidenceRegistry();

    RegistrySourceAnchor impl = new RegistrySourceAnchor();
    bytes memory init = abi.encodeCall(RegistrySourceAnchor.initialize, (address(registry), admin));
    ERC1967Proxy proxy = new ERC1967Proxy(address(impl), init);
    anchor = RegistrySourceAnchor(address(proxy));

    // anchor.REGISTRY_POSTMAN() must be read BEFORE vm.prank: it's itself an external call, and
    // vm.prank only overrides msg.sender for the single next call - reading it inline as an
    // argument would consume the prank before grantRole executes, leaving grantRole to run as
    // this test contract (no DEFAULT_ADMIN_ROLE) instead of admin.
    bytes32 postmanRole = anchor.REGISTRY_POSTMAN();
    vm.prank(admin);
    anchor.grantRole(postmanRole, postman);
  }

  function _expectedKey(bytes32 registryId_, uint256 index_) internal view returns (bytes32) {
    return
      bytes32(
        uint256(keccak256(abi.encodePacked('REGISTRY_SOURCE_ROOT', registryId_, address(anchor), index_))) %
          SNARK_SCALAR_FIELD
      );
  }

  /// Two-leaf sorted set + the OpenZeppelin-MerkleProof-compatible root for it (sorted-pair
  /// keccak, matching RegistrySourceAnchor._computeRoot and MerkleProof.verify's convention).
  function _twoLeafSet(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory leaves, bytes32 root) {
    (bytes32 lo, bytes32 hi) = a < b ? (a, b) : (b, a);
    leaves = new bytes32[](2);
    leaves[0] = lo;
    leaves[1] = hi;
    root = lo < hi ? keccak256(abi.encodePacked(lo, hi)) : keccak256(abi.encodePacked(hi, lo));
  }

  function _oneLeafSet(bytes32 a) internal pure returns (bytes32[] memory leaves) {
    leaves = new bytes32[](1);
    leaves[0] = a;
  }

  // ── initialization / upgradeability ─────────────────────────────────────────────────────

  function test_initialize_revertsOnZeroEvidenceRegistry() public {
    RegistrySourceAnchor impl = new RegistrySourceAnchor();
    bytes memory init = abi.encodeCall(RegistrySourceAnchor.initialize, (address(0), admin));
    vm.expectRevert(RegistrySourceAnchor.ZeroAddress.selector);
    new ERC1967Proxy(address(impl), init);
  }

  function test_initialize_revertsOnZeroAdmin() public {
    RegistrySourceAnchor impl = new RegistrySourceAnchor();
    bytes memory init = abi.encodeCall(RegistrySourceAnchor.initialize, (address(registry), address(0)));
    vm.expectRevert(RegistrySourceAnchor.ZeroAddress.selector);
    new ERC1967Proxy(address(impl), init);
  }

  function test_initialize_cannotBeCalledTwice() public {
    vm.expectRevert();
    anchor.initialize(address(registry), admin);
  }

  function test_upgradeToAndCall_revertsForNonOwner() public {
    RegistrySourceAnchor newImpl = new RegistrySourceAnchor();
    vm.prank(stranger);
    vm.expectRevert();
    anchor.upgradeToAndCall(address(newImpl), '');
  }

  // ── access control ──────────────────────────────────────────────────────────────────────

  function test_publishSnapshot_revertsForNonPostman() public {
    vm.prank(stranger);
    vm.expectRevert();
    anchor.publishSnapshot(NOTARY_REGISTRY, _oneLeafSet(keccak256('leaf')));
  }

  function test_onReport_revertsForNonPostman() public {
    bytes memory report = abi.encode(NOTARY_REGISTRY, _oneLeafSet(keccak256('leaf')));
    vm.prank(stranger);
    vm.expectRevert();
    anchor.onReport('', report);
  }

  // ── publishSnapshot ─────────────────────────────────────────────────────────────────────

  function test_publishSnapshot_singleLeaf_rootIsTheLeafItself() public {
    bytes32 leaf = keccak256('only-notary');
    vm.prank(postman);
    (uint256 index, bytes32 root) = anchor.publishSnapshot(NOTARY_REGISTRY, _oneLeafSet(leaf));

    assertEq(index, 0);
    assertEq(root, leaf); // a 1-leaf tree's root IS the leaf - matches MerkleProof.verify(empty proof)
    assertEq(registry.statements(_expectedKey(NOTARY_REGISTRY, 0)), root);
    assertEq(registry.count(), 1);
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), root);
  }

  function test_publishSnapshot_twoLeaves_computesSortedPairRoot() public {
    (bytes32[] memory leaves, bytes32 expectedRoot) = _twoLeafSet(keccak256('a'), keccak256('b'));

    vm.prank(postman);
    (, bytes32 root) = anchor.publishSnapshot(NOTARY_REGISTRY, leaves);

    assertEq(root, expectedRoot);
    assertEq(registry.statements(_expectedKey(NOTARY_REGISTRY, 0)), expectedRoot);
  }

  function test_publishSnapshot_revertsOnEmptyLeafSet() public {
    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.EmptyLeafSet.selector);
    anchor.publishSnapshot(NOTARY_REGISTRY, new bytes32[](0));
  }

  function test_publishSnapshot_revertsOnUnsortedLeaves() public {
    bytes32 a = keccak256('a');
    bytes32 b = keccak256('b');
    (bytes32 lo, bytes32 hi) = a < b ? (a, b) : (b, a);
    bytes32[] memory badOrder = new bytes32[](2);
    badOrder[0] = hi; // descending - must revert
    badOrder[1] = lo;

    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.LeavesNotStrictlySorted.selector);
    anchor.publishSnapshot(NOTARY_REGISTRY, badOrder);
  }

  function test_publishSnapshot_revertsOnDuplicateLeaves() public {
    bytes32 leaf = keccak256('dup');
    bytes32[] memory duplicated = new bytes32[](2);
    duplicated[0] = leaf;
    duplicated[1] = leaf; // strictly ascending required - equal adjacent values must revert

    vm.prank(postman);
    vm.expectRevert(RegistrySourceAnchor.LeavesNotStrictlySorted.selector);
    anchor.publishSnapshot(NOTARY_REGISTRY, duplicated);
  }

  function test_publishSnapshot_emitsFullLeafSet() public {
    (bytes32[] memory leaves, ) = _twoLeafSet(keccak256('a'), keccak256('b'));

    vm.expectEmit(true, true, false, true);
    emit RegistrySourceAnchor.SnapshotLeaves(NOTARY_REGISTRY, 0, leaves);
    vm.prank(postman);
    anchor.publishSnapshot(NOTARY_REGISTRY, leaves);
  }

  function test_publishSnapshot_neverOverwritesPriorSnapshot() public {
    vm.startPrank(postman);
    (, bytes32 root0) = anchor.publishSnapshot(NOTARY_REGISTRY, _oneLeafSet(keccak256('a')));
    (, bytes32 root1) = anchor.publishSnapshot(NOTARY_REGISTRY, _oneLeafSet(keccak256('b')));
    vm.stopPrank();

    assertEq(anchor.snapshotCount(NOTARY_REGISTRY), 2);
    assertEq(registry.statements(_expectedKey(NOTARY_REGISTRY, 0)), root0);
    assertEq(registry.statements(_expectedKey(NOTARY_REGISTRY, 1)), root1);
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), root1);
  }

  function test_publishSnapshot_distinctRegistriesDoNotCollide() public {
    vm.startPrank(postman);
    (, bytes32 rootA) = anchor.publishSnapshot(NOTARY_REGISTRY, _oneLeafSet(keccak256('a')));
    (, bytes32 rootB) = anchor.publishSnapshot(OTHER_REGISTRY, _oneLeafSet(keccak256('b')));
    vm.stopPrank();

    assertEq(anchor.snapshotCount(NOTARY_REGISTRY), 1);
    assertEq(anchor.snapshotCount(OTHER_REGISTRY), 1);
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), rootA);
    assertEq(anchor.latestRoot(OTHER_REGISTRY), rootB);
  }

  // ── onReport ────────────────────────────────────────────────────────────────────────────

  function test_onReport_decodesAndPublishes() public {
    bytes32 leaf = keccak256('c');
    bytes memory report = abi.encode(NOTARY_REGISTRY, _oneLeafSet(leaf));

    vm.prank(postman);
    (uint256 index, bytes32 root) = anchor.onReport('some-metadata', report);

    assertEq(index, 0);
    assertEq(root, leaf);
    assertEq(anchor.latestRoot(NOTARY_REGISTRY), leaf);
  }

  // ── latestRoot / latestActiveRoot / snapshotCount ──────────────────────────────────────

  function test_latestRoot_revertsWhenNoSnapshots() public {
    vm.expectRevert(RegistrySourceAnchor.NoSnapshotsAvailable.selector);
    anchor.latestRoot(NOTARY_REGISTRY);
  }

  function test_latestActiveRoot_respectsActivationDelay() public {
    bytes32 leaf = keccak256('a');
    vm.prank(postman);
    anchor.publishSnapshot(NOTARY_REGISTRY, _oneLeafSet(leaf));

    vm.expectRevert(RegistrySourceAnchor.NoActiveSnapshot.selector);
    anchor.latestActiveRoot(NOTARY_REGISTRY);

    vm.warp(block.timestamp + anchor.ROOT_ACTIVATION_DELAY());
    assertEq(anchor.latestActiveRoot(NOTARY_REGISTRY), leaf);
  }

  function test_latestActiveRoot_keepsPreviousRootDuringWindow() public {
    bytes32 leafA = keccak256('a');
    bytes32 leafB = keccak256('b');
    vm.prank(postman);
    anchor.publishSnapshot(NOTARY_REGISTRY, _oneLeafSet(leafA));
    vm.warp(block.timestamp + anchor.ROOT_ACTIVATION_DELAY());

    vm.prank(postman);
    anchor.publishSnapshot(NOTARY_REGISTRY, _oneLeafSet(leafB));
    assertEq(anchor.latestActiveRoot(NOTARY_REGISTRY), leafA); // leafB's snapshot still pending

    vm.warp(block.timestamp + anchor.ROOT_ACTIVATION_DELAY());
    assertEq(anchor.latestActiveRoot(NOTARY_REGISTRY), leafB);
  }
}
