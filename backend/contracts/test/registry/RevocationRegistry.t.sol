// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {RevocationRegistry} from '../../contracts/registry/RevocationRegistry.sol';

/*
 * The properties under test are STRUCTURAL, so most of these assert the ABSENCE of power rather
 * than the presence of behaviour. That is the point of sec. 2.5: "we cannot remove you arbitrarily"
 * has to be a property of the code, not a promise.
 */
contract RevocationRegistryTest is Test {
  RevocationRegistry internal registry;

  bytes32 internal constant P_DOC_INVALID = keccak256('predicate.document.not-current');
  bytes32 internal constant P_SANCTIONED = keccak256('predicate.sanctions.ofac-sdn');
  bytes32 internal constant P_UNLISTED = keccak256('predicate.never.registered');

  address internal docAttester = address(0xA1);
  address internal ofacAttester = address(0xA2);
  address internal stranger = address(0xBAD);

  bytes32 internal constant HOLDER_A = bytes32(uint256(0x1111));
  bytes32 internal constant HOLDER_B = bytes32(uint256(0x2222));

  function setUp() public {
    bytes32[] memory preds = new bytes32[](2);
    preds[0] = P_DOC_INVALID;
    preds[1] = P_SANCTIONED;

    address[] memory attesters = new address[](2);
    attesters[0] = docAttester;
    attesters[1] = ofacAttester;

    registry = new RevocationRegistry(preds, attesters, 20);
  }

  // ── the closed predicate set ────────────────────────────────────────────────────────────────

  /// @notice A predicate outside the deploy-time set cannot be cited AT ALL. This is what makes
  /// the rule set closed: there is no setter and no owner, so this can never become possible.
  function test_UnknownPredicateIsUncitable() public {
    vm.prank(docAttester);
    vm.expectRevert(abi.encodeWithSelector(RevocationRegistry.UnknownPredicate.selector, P_UNLISTED));
    registry.revoke(HOLDER_A, P_UNLISTED);
  }

  /// @notice An attester may cite ONLY its own predicate. Otherwise one compromised attester could
  /// revoke under every rule.
  function test_AttesterCannotCiteAnotherPredicate() public {
    vm.prank(docAttester);
    vm.expectRevert(
      abi.encodeWithSelector(RevocationRegistry.NotTheAttester.selector, P_SANCTIONED, docAttester)
    );
    registry.revoke(HOLDER_A, P_SANCTIONED);
  }

  function test_StrangerCannotRevoke() public {
    vm.prank(stranger);
    vm.expectRevert(
      abi.encodeWithSelector(RevocationRegistry.NotTheAttester.selector, P_DOC_INVALID, stranger)
    );
    registry.revoke(HOLDER_A, P_DOC_INVALID);
  }

  // ── append-only ─────────────────────────────────────────────────────────────────────────────

  function test_RevokeWorksAndMovesTheRoot() public {
    bytes32 before = registry.root();

    vm.prank(docAttester);
    bytes32 after_ = registry.revoke(HOLDER_A, P_DOC_INVALID);

    assertTrue(registry.isRevoked(HOLDER_A));
    assertEq(registry.revocationCount(), 1);
    assertTrue(after_ != before, 'root did not change on revocation');
    assertTrue(registry.isKnownRoot(after_));
    assertTrue(registry.isKnownRoot(before), 'the pre-revocation root stopped being known');
  }

  /// @notice Monotonicity. Re-revoking is rejected rather than silently re-adding, so the tree
  /// cannot be perturbed by replaying a revocation.
  function test_CannotRevokeTwice() public {
    vm.prank(docAttester);
    registry.revoke(HOLDER_A, P_DOC_INVALID);

    vm.prank(docAttester);
    vm.expectRevert(abi.encodeWithSelector(RevocationRegistry.AlreadyRevoked.selector, HOLDER_A));
    registry.revoke(HOLDER_A, P_DOC_INVALID);
  }

  /*
   * THE CENTRAL PROPERTY: THERE IS NO WAY BACK.
   *
   * Asserted against the ABI rather than by calling something, because the claim is that the
   * function does not exist - PoseidonSMT, which this deliberately does not reuse, has `remove`.
   * A future edit that adds one would fail here.
   */
  function test_NoRemoveNoUpdateNoOwnerNoUpgrade() public view {
    string[7] memory forbidden = [
      'remove(bytes32)',
      'update(bytes32,bytes32)',
      'owner()',
      'transferOwnership(address)',
      'upgradeTo(address)',
      'upgradeToAndCall(address,bytes)',
      'initialize(bytes32[],address[],uint32)'
    ];
    for (uint256 i = 0; i < forbidden.length; i++) {
      bytes4 sel = bytes4(keccak256(bytes(forbidden[i])));
      (bool ok,) = address(registry).staticcall(abi.encodeWithSelector(sel));
      assertFalse(ok, string.concat('registry answers a forbidden selector: ', forbidden[i]));
    }
  }

  /// @notice Historical roots stay valid, so a proof built a moment before someone else's
  /// revocation does not spuriously fail. Safe only because the tree is append-only: an old root
  /// can never un-revoke anyone, it just predates them.
  function test_HistoricalRootsRemainKnown() public {
    bytes32 r0 = registry.root();

    vm.prank(docAttester);
    bytes32 r1 = registry.revoke(HOLDER_A, P_DOC_INVALID);

    vm.prank(ofacAttester);
    bytes32 r2 = registry.revoke(HOLDER_B, P_SANCTIONED);

    assertTrue(registry.isKnownRoot(r0) && registry.isKnownRoot(r1) && registry.isKnownRoot(r2));
    // ...but a root this registry never had must NOT be accepted.
    assertFalse(registry.isKnownRoot(keccak256('never happened')));
  }

  /// @notice The leaf value records WHICH rule was cited, so an audit does not have to trust the
  /// event log.
  function test_LeafRecordsThePredicate() public {
    vm.prank(ofacAttester);
    registry.revoke(HOLDER_A, P_SANCTIONED);
    assertEq(registry.getProof(HOLDER_A).value, P_SANCTIONED);
  }

  // ── constructor guards ──────────────────────────────────────────────────────────────────────

  function test_RejectsDuplicatePredicate() public {
    bytes32[] memory preds = new bytes32[](2);
    preds[0] = P_DOC_INVALID;
    preds[1] = P_DOC_INVALID;
    address[] memory attesters = new address[](2);
    attesters[0] = docAttester;
    attesters[1] = ofacAttester;

    // Without this guard the second entry would silently win, quietly reassigning the predicate.
    vm.expectRevert(
      abi.encodeWithSelector(RevocationRegistry.DuplicatePredicate.selector, P_DOC_INVALID)
    );
    new RevocationRegistry(preds, attesters, 20);
  }

  function test_RejectsZeroAttester() public {
    bytes32[] memory preds = new bytes32[](1);
    preds[0] = P_DOC_INVALID;
    address[] memory attesters = new address[](1);
    attesters[0] = address(0);

    vm.expectRevert(
      abi.encodeWithSelector(RevocationRegistry.AttesterIsZero.selector, P_DOC_INVALID)
    );
    new RevocationRegistry(preds, attesters, 20);
  }

  function test_RejectsEmptyPredicateSet() public {
    vm.expectRevert(RevocationRegistry.NoPredicates.selector);
    new RevocationRegistry(new bytes32[](0), new address[](0), 20);
  }
}
