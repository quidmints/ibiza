// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';

import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {IdentityAspRegistry} from '../../contracts/registry/IdentityAspRegistry.sol';

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

contract IdentityAspRegistryTest is Test {
  IdentityAspRegistry internal registry;
  MockEvidenceRegistry internal evidence;

  address internal owner = address(0xA011);
  address internal postman = vm.addr(0xB0B); // fixed at construction - there is no grantRole now

  function setUp() public {
    evidence = new MockEvidenceRegistry();
    // NON-UPGRADEABLE and unowned: constructed directly, no proxy, no owner. That is the point -
    // see IdentityAspRegistry.sol's header and TODO.md sec. 2.5a.
    registry = new IdentityAspRegistry(postman, address(evidence));
  }

  function _expectedKey(uint256 _index) internal view returns (bytes32) {
    return
      bytes32(uint256(keccak256(abi.encodePacked('PP_ASP_ROOT', address(registry), _index))) % Constants.SNARK_SCALAR_FIELD);
  }

  function test_constructor_setsEvidenceRegistry() public view {
    assertEq(address(registry.EVIDENCE_REGISTRY()), address(evidence));
  }

  /*
   * APPEND-ONLY ASP TREE (TODO.md sec. 2A Phase 1b, sec. 2.13).
   *
   * These replace the old updateRoot/latestActiveRoot tests wholesale. That surface is GONE, not
   * deprecated: `updateRoot` let the postman publish an arbitrary off-chain-computed root, which
   * was the mechanism by which an existing member could be dropped from the set and have their
   * private exit killed retroactively. Leaving it callable would have made everything below
   * meaningless, since a postman could bypass `admitIdentity` entirely.
   */

  function test_admitIdentity_anchorsRootInRegistry() public {
    vm.prank(postman);
    uint256 root = registry.admitIdentity(12_345);

    // Single-leaf LeanIMT: the root IS the leaf.
    assertEq(root, 12_345);
    assertEq(registry.aspTreeSize(), 1);
    assertEq(evidence.statements(_expectedKey(0)), bytes32(root));
    assertEq(evidence.count(), 1);
  }

  function test_eachRootGetsDistinctStatementKey() public {
    vm.startPrank(postman);
    uint256 r0 = registry.admitIdentity(111);
    uint256 r1 = registry.admitIdentity(222);
    vm.stopPrank();

    assertEq(evidence.statements(_expectedKey(0)), bytes32(r0));
    assertEq(evidence.statements(_expectedKey(1)), bytes32(r1));
    assertEq(evidence.count(), 2);
  }

  /*
   * THE LOAD-BEARING TEST. This is the property the whole redesign exists to produce: once an
   * identity is in, every root that ever contained it stays valid forever, so no later admission -
   * and no operator action of any kind - can invalidate the inclusion proof they already hold.
   *
   * Under the old design the equivalent assertion was false by construction: withdrawals required
   * equality with the single latest active root, so ANY subsequent root superseded the previous one
   * and a root omitting a member killed that member's exit.
   */
  function test_historicalRootsStayValidForever() public {
    vm.startPrank(postman);
    uint256 rootAfterFirst = registry.admitIdentity(111);
    uint256 rootAfterSecond = registry.admitIdentity(222);
    uint256 rootAfterThird = registry.admitIdentity(333);
    vm.stopPrank();

    assertTrue(rootAfterFirst != rootAfterSecond);
    assertTrue(rootAfterSecond != rootAfterThird);

    // Every root the tree ever produced remains acceptable to a withdrawal.
    assertTrue(registry.isKnownAspRoot(rootAfterFirst));
    assertTrue(registry.isKnownAspRoot(rootAfterSecond));
    assertTrue(registry.isKnownAspRoot(rootAfterThird));
    assertEq(registry.latestAspRoot(), rootAfterThird);
  }

  /// @notice No activation delay: a freshly admitted identity can prove inclusion immediately.
  /// Upstream's delay existed to give watchers time to spot an equivocating postman pushing a
  /// fabricated root - impossible now that the contract computes every root itself, so the delay
  /// would only have imposed a wait that bought nothing.
  function test_admittedRootIsUsableImmediately() public {
    vm.prank(postman);
    uint256 root = registry.admitIdentity(777);
    assertTrue(registry.isKnownAspRoot(root));
  }

  function test_isKnownAspRoot_rejectsUnknownAndZero() public {
    vm.prank(postman);
    registry.admitIdentity(111);

    assertFalse(registry.isKnownAspRoot(0));
    assertFalse(registry.isKnownAspRoot(999_999));
  }

  function test_admitIdentity_onlyPostman() public {
    vm.expectRevert();
    vm.prank(owner);
    registry.admitIdentity(111);
  }

  function test_admitIdentity_rejectsDuplicate() public {
    vm.startPrank(postman);
    registry.admitIdentity(111);
    vm.expectRevert(IdentityAspRegistry.AlreadyAdmitted.selector);
    registry.admitIdentity(111);
    vm.stopPrank();
  }

  /// @notice LeanIMT reserves 0 as "empty sibling"; a zero leaf would corrupt inclusion proofs.
  function test_admitIdentity_rejectsZeroLeaf() public {
    vm.prank(postman);
    vm.expectRevert(IdentityAspRegistry.EmptyRoot.selector);
    registry.admitIdentity(0);
  }

  function test_admitIdentity_rejectsOutOfFieldLeaf() public {
    vm.prank(postman);
    vm.expectRevert(IdentityAspRegistry.LeafOutOfField.selector);
    registry.admitIdentity(Constants.SNARK_SCALAR_FIELD);
  }

  function test_latestRoot_revertsWhenEmpty() public {
    vm.expectRevert(IdentityAspRegistry.NoRootsAvailable.selector);
    registry.latestAspRoot();
  }

  function test_treeDepthGrowsWithAdmissions() public {
    vm.startPrank(postman);
    registry.admitIdentity(1);
    assertEq(registry.aspTreeDepth(), 0);
    registry.admitIdentity(2);
    assertEq(registry.aspTreeDepth(), 1);
    registry.admitIdentity(3);
    assertEq(registry.aspTreeDepth(), 2);
    vm.stopPrank();
    assertEq(registry.aspTreeSize(), 3);
  }

  /*
   * SIGNATURE-AUTHORIZED ADMISSION (TODO.md sec. 2.20).
   *
   * Lets admission ride along with the user's first deposit rather than needing its own
   * postman-sent transaction. The authority is unchanged - only an ASP_POSTMAN can authorize - but
   * the postman no longer needs to send transactions or hold ETH.
   */

  uint256 internal postmanPk = 0xB0B;

  function _admitDigest(uint256 holderRoot, uint256 deadline) internal view returns (bytes32) {
    bytes32 structHash =
      keccak256(abi.encode(keccak256('AdmitIdentity(uint256 holderRoot,uint256 deadline)'), holderRoot, deadline));
    bytes32 domainSeparator = keccak256(
      abi.encode(
        keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
        keccak256(bytes('IdentityAspRegistry')),
        keccak256(bytes('1')),
        block.chainid,
        address(registry)
      )
    );
    return keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
  }

  function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, digest);
    return abi.encodePacked(r, s_, v);
  }


  function test_admitWithAuthorization_anyoneMaySubmit() public {

    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(postmanPk, _admitDigest(111, deadline));

    // Submitted by an unrelated address - the whole point is the user pays, not the postman.
    vm.prank(address(0xCAFE));
    uint256 root = registry.admitIdentityWithAuthorization(111, deadline, sig);

    assertEq(root, 111);
    assertTrue(registry.isKnownAspRoot(root));
    assertTrue(registry.aspAdmitted(111));
  }

  function test_admitWithAuthorization_rejectsNonPostmanSigner() public {
    uint256 strangerPk = 0xBAD;
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(strangerPk, _admitDigest(111, deadline));

    vm.expectRevert(IdentityAspRegistry.InvalidAuthorization.selector);
    registry.admitIdentityWithAuthorization(111, deadline, sig);
  }

  function test_admitWithAuthorization_rejectsExpired() public {

    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(postmanPk, _admitDigest(111, deadline));

    vm.warp(deadline + 1);
    vm.expectRevert(IdentityAspRegistry.AuthorizationExpired.selector);
    registry.admitIdentityWithAuthorization(111, deadline, sig);
  }

  /// @notice `aspAdmitted` IS the replay protection - no separate nonce is needed, because the
  /// only action a signature authorizes is an insert that can happen at most once.
  function test_admitWithAuthorization_signatureCannotBeReplayed() public {

    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(postmanPk, _admitDigest(111, deadline));

    registry.admitIdentityWithAuthorization(111, deadline, sig);

    vm.expectRevert(IdentityAspRegistry.AlreadyAdmitted.selector);
    registry.admitIdentityWithAuthorization(111, deadline, sig);
  }

  /// @notice A signature for one identity must not admit a different one.
  function test_admitWithAuthorization_signatureBindsHolderRoot() public {

    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(postmanPk, _admitDigest(111, deadline));

    vm.expectRevert(IdentityAspRegistry.InvalidAuthorization.selector);
    registry.admitIdentityWithAuthorization(222, deadline, sig);
  }

  function test_constructor_rejectsZeroPostman() public {
    vm.expectRevert(IdentityAspRegistry.PostmanIsZero.selector);
    new IdentityAspRegistry(address(0), address(evidence));
  }

  /*
   * THE REASON THIS CONTRACT EXISTS. The tree used to live in Entrypoint, whose
   * _authorizeUpgrade is onlyRole(_OWNER_ROLE) - so "append-only by construction" was really
   * "append-only unless the owner upgrades". Here there is no owner, no role machinery and no
   * proxy, so the postman genuinely cannot be changed and the tree genuinely cannot be rewritten.
   * Asserted against the ABI because the claim is that these functions DO NOT EXIST.
   */
  function test_NoRolesNoOwnerNoUpgradeNoRemove() public view {
    string[6] memory forbidden = [
      'grantRole(bytes32,address)',
      'revokeRole(bytes32,address)',
      'owner()',
      'upgradeToAndCall(address,bytes)',
      'initialize(address,address,address)',
      'remove(uint256)'
    ];
    for (uint256 i = 0; i < forbidden.length; i++) {
      (bool ok,) = address(registry).staticcall(abi.encodeWithSelector(bytes4(keccak256(bytes(forbidden[i])))));
      assertFalse(ok, string.concat('registry answers a forbidden selector: ', forbidden[i]));
    }
    assertEq(registry.POSTMAN(), postman, 'postman is not the immutable one');
  }
}
