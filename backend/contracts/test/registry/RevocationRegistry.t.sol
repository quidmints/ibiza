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

  uint256 internal constant MAX_AGE = 1 hours;

  function setUp() public {
    bytes32[] memory preds = new bytes32[](2);
    preds[0] = P_DOC_INVALID;
    preds[1] = P_SANCTIONED;

    address[] memory attesters = new address[](2);
    attesters[0] = docAttester;
    attesters[1] = ofacAttester;

    registry = new RevocationRegistry(preds, attesters, 20, MAX_AGE);
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
    assertTrue(registry.isValidRoot(after_));
    assertTrue(registry.isValidRoot(before), 'the superseded root lost its grace window immediately');
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

  /*
   * REGRESSION TEST FOR A FATAL DESIGN BUG.
   *
   * The first version of this registry marked EVERY root known forever, by analogy with the
   * append-only ASP tree in Entrypoint. The analogy is inverted: the ASP tree proves INCLUSION, so
   * an older root merely has fewer members; THIS tree proves NON-INCLUSION, so an older root has
   * fewer REVOCATIONS. Under the old behaviour a revoked identity could prove absence against the
   * EMPTY INITIAL ROOT forever, and revocation would have been a complete no-op.
   */
  function test_StaleRootStopsBeingValid_SoRevocationCannotBeEvaded() public {
    bytes32 emptyRoot = registry.root();
    assertTrue(registry.isValidRoot(emptyRoot), 'the initial root should start valid');

    vm.prank(docAttester);
    registry.revoke(HOLDER_A, P_DOC_INVALID);

    // Immediately after, the superseded root is still accepted - that grace is deliberate, so an
    // in-flight proof is not killed by someone else's revocation landing first.
    assertTrue(registry.isValidRoot(emptyRoot), 'grace window should still accept the old root');

    vm.warp(block.timestamp + MAX_AGE + 1);

    assertFalse(
      registry.isValidRoot(emptyRoot),
      'a pre-revocation root is STILL accepted - revocation is evadable'
    );
  }

  /*
   * NO CENSORSHIP THROUGH INACTION.
   *
   * If no attester ever acts again, withdrawals must keep working forever. A naive age check
   * without the always-valid-latest clause would be fail-CLOSED: the newest root would age out and
   * every withdrawal would halt, handing an operator a censorship lever by simply doing nothing.
   */
  function test_LatestRootNeverExpires_NoCensorshipByInaction() public {
    vm.prank(docAttester);
    registry.revoke(HOLDER_A, P_DOC_INVALID);
    bytes32 current = registry.root();

    vm.warp(block.timestamp + 3650 days); // a decade of total attester silence

    assertTrue(
      registry.isValidRoot(current),
      'the current root expired - inaction blocks withdrawals, i.e. censorship'
    );
  }

  function test_RootThatNeverExistedIsRejected() public view {
    assertFalse(registry.isValidRoot(keccak256('never happened')));
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
    new RevocationRegistry(preds, attesters, 20, MAX_AGE);
  }

  function test_RejectsZeroAttester() public {
    bytes32[] memory preds = new bytes32[](1);
    preds[0] = P_DOC_INVALID;
    address[] memory attesters = new address[](1);
    attesters[0] = address(0);

    vm.expectRevert(
      abi.encodeWithSelector(RevocationRegistry.AttesterIsZero.selector, P_DOC_INVALID)
    );
    new RevocationRegistry(preds, attesters, 20, MAX_AGE);
  }

  function test_RejectsEmptyPredicateSet() public {
    vm.expectRevert(RevocationRegistry.NoPredicates.selector);
    new RevocationRegistry(new bytes32[](0), new address[](0), 20, MAX_AGE);
  }
}
