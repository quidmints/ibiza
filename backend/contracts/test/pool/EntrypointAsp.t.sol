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
    uint256 root = entrypoint.admitIdentity(12_345);

    // Single-leaf LeanIMT: the root IS the leaf.
    assertEq(root, 12_345);
    assertEq(entrypoint.aspTreeSize(), 1);
    assertEq(registry.statements(_expectedKey(0)), bytes32(root));
    assertEq(registry.count(), 1);
  }

  function test_eachRootGetsDistinctStatementKey() public {
    vm.startPrank(postman);
    uint256 r0 = entrypoint.admitIdentity(111);
    uint256 r1 = entrypoint.admitIdentity(222);
    vm.stopPrank();

    assertEq(registry.statements(_expectedKey(0)), bytes32(r0));
    assertEq(registry.statements(_expectedKey(1)), bytes32(r1));
    assertEq(registry.count(), 2);
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
    uint256 rootAfterFirst = entrypoint.admitIdentity(111);
    uint256 rootAfterSecond = entrypoint.admitIdentity(222);
    uint256 rootAfterThird = entrypoint.admitIdentity(333);
    vm.stopPrank();

    assertTrue(rootAfterFirst != rootAfterSecond);
    assertTrue(rootAfterSecond != rootAfterThird);

    // Every root the tree ever produced remains acceptable to a withdrawal.
    assertTrue(entrypoint.isKnownAspRoot(rootAfterFirst));
    assertTrue(entrypoint.isKnownAspRoot(rootAfterSecond));
    assertTrue(entrypoint.isKnownAspRoot(rootAfterThird));
    assertEq(entrypoint.latestRoot(), rootAfterThird);
  }

  /// @notice No activation delay: a freshly admitted identity can prove inclusion immediately.
  /// Upstream's delay existed to give watchers time to spot an equivocating postman pushing a
  /// fabricated root - impossible now that the contract computes every root itself, so the delay
  /// would only have imposed a wait that bought nothing.
  function test_admittedRootIsUsableImmediately() public {
    vm.prank(postman);
    uint256 root = entrypoint.admitIdentity(777);
    assertTrue(entrypoint.isKnownAspRoot(root));
  }

  function test_isKnownAspRoot_rejectsUnknownAndZero() public {
    vm.prank(postman);
    entrypoint.admitIdentity(111);

    assertFalse(entrypoint.isKnownAspRoot(0));
    assertFalse(entrypoint.isKnownAspRoot(999_999));
  }

  function test_admitIdentity_onlyPostman() public {
    vm.expectRevert();
    vm.prank(owner);
    entrypoint.admitIdentity(111);
  }

  function test_admitIdentity_rejectsDuplicate() public {
    vm.startPrank(postman);
    entrypoint.admitIdentity(111);
    vm.expectRevert(IEntrypoint.AlreadyAdmitted.selector);
    entrypoint.admitIdentity(111);
    vm.stopPrank();
  }

  /// @notice LeanIMT reserves 0 as "empty sibling"; a zero leaf would corrupt inclusion proofs.
  function test_admitIdentity_rejectsZeroLeaf() public {
    vm.prank(postman);
    vm.expectRevert(IEntrypoint.EmptyRoot.selector);
    entrypoint.admitIdentity(0);
  }

  function test_admitIdentity_rejectsOutOfFieldLeaf() public {
    vm.prank(postman);
    vm.expectRevert(IEntrypoint.LeafOutOfField.selector);
    entrypoint.admitIdentity(Constants.SNARK_SCALAR_FIELD);
  }

  function test_latestRoot_revertsWhenEmpty() public {
    vm.expectRevert(IEntrypoint.NoRootsAvailable.selector);
    entrypoint.latestRoot();
  }

  function test_treeDepthGrowsWithAdmissions() public {
    vm.startPrank(postman);
    entrypoint.admitIdentity(1);
    assertEq(entrypoint.aspTreeDepth(), 0);
    entrypoint.admitIdentity(2);
    assertEq(entrypoint.aspTreeDepth(), 1);
    entrypoint.admitIdentity(3);
    assertEq(entrypoint.aspTreeDepth(), 2);
    vm.stopPrank();
    assertEq(entrypoint.aspTreeSize(), 3);
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
        keccak256(bytes('QuidPrivacyPoolEntrypoint')),
        keccak256(bytes('1')),
        block.chainid,
        address(entrypoint)
      )
    );
    return keccak256(abi.encodePacked('\x19\x01', domainSeparator, structHash));
  }

  function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
    (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, digest);
    return abi.encodePacked(r, s_, v);
  }

  function _grantPostman(address who) internal {
    vm.prank(owner);
    entrypoint.grantRole(keccak256('ASP_POSTMAN'), who);
  }

  function test_admitWithAuthorization_anyoneMaySubmit() public {
    address signer = vm.addr(postmanPk);
    _grantPostman(signer);

    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(postmanPk, _admitDigest(111, deadline));

    // Submitted by an unrelated address - the whole point is the user pays, not the postman.
    vm.prank(address(0xCAFE));
    uint256 root = entrypoint.admitIdentityWithAuthorization(111, deadline, sig);

    assertEq(root, 111);
    assertTrue(entrypoint.isKnownAspRoot(root));
    assertTrue(entrypoint.aspAdmitted(111));
  }

  function test_admitWithAuthorization_rejectsNonPostmanSigner() public {
    uint256 strangerPk = 0xBAD;
    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(strangerPk, _admitDigest(111, deadline));

    vm.expectRevert(IEntrypoint.InvalidAuthorization.selector);
    entrypoint.admitIdentityWithAuthorization(111, deadline, sig);
  }

  function test_admitWithAuthorization_rejectsExpired() public {
    address signer = vm.addr(postmanPk);
    _grantPostman(signer);

    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(postmanPk, _admitDigest(111, deadline));

    vm.warp(deadline + 1);
    vm.expectRevert(IEntrypoint.AuthorizationExpired.selector);
    entrypoint.admitIdentityWithAuthorization(111, deadline, sig);
  }

  /// @notice `aspAdmitted` IS the replay protection - no separate nonce is needed, because the
  /// only action a signature authorizes is an insert that can happen at most once.
  function test_admitWithAuthorization_signatureCannotBeReplayed() public {
    address signer = vm.addr(postmanPk);
    _grantPostman(signer);

    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(postmanPk, _admitDigest(111, deadline));

    entrypoint.admitIdentityWithAuthorization(111, deadline, sig);

    vm.expectRevert(IEntrypoint.AlreadyAdmitted.selector);
    entrypoint.admitIdentityWithAuthorization(111, deadline, sig);
  }

  /// @notice A signature for one identity must not admit a different one.
  function test_admitWithAuthorization_signatureBindsHolderRoot() public {
    address signer = vm.addr(postmanPk);
    _grantPostman(signer);

    uint256 deadline = block.timestamp + 1 hours;
    bytes memory sig = _sign(postmanPk, _admitDigest(111, deadline));

    vm.expectRevert(IEntrypoint.InvalidAuthorization.selector);
    entrypoint.admitIdentityWithAuthorization(222, deadline, sig);
  }

  function test_initialize_revertsOnZeroRegistry() public {
    Entrypoint impl = new Entrypoint();
    bytes memory init = abi.encodeCall(Entrypoint.initialize, (owner, postman, address(0)));
    vm.expectRevert(IEntrypoint.ZeroAddress.selector);
    new ERC1967Proxy(address(impl), init);
  }
}
