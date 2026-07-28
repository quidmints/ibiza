// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol';

import {IdentityRegistry} from '../../contracts/registry/IdentityRegistry.sol';
import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {EscrowEnvelopeHonkVerifier} from '../../contracts/registry/verifiers/EscrowEnvelopeHonkVerifier.sol';
import {HolderStateKeeperMock} from '../../contracts/mock/holder/HolderStateKeeperMock.sol';
import {PoseidonSMTMock} from '../../contracts/mock/state/PoseidonSMTMock.sol';

/// See HolderRegistration.t.sol - OZ 5.6.1 rejects empty proxy init data; this suite
/// deploys-then-initializes, which is safe single-threaded.
contract UnsafeTestProxy is ERC1967Proxy {
  constructor(address impl) ERC1967Proxy(impl, '') {}

  function _unsafeAllowUninitialized() internal pure override returns (bool) {
    return true;
  }
}

contract TestEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;

  function addStatement(bytes32 key_, bytes32 value_) external {
    statements[keccak256(abi.encodePacked(msg.sender, key_))] = value_;
  }
}

/*
 * TODO.md sec. 2.13k/2.13m - the SINGLE identity tree, and every trap the merge creates.
 *
 * This suite drives the REAL escrow proof through the REAL verifier into the REAL state keeper.
 * Nothing here is mocked except the state keeper's registration gate, which is opened to this test
 * so a document can be planted without going through a passport proof.
 *
 * WHY EACH TRAP IS TESTED RATHER THAN ARGUED. Merging an inclusion tree and an exclusion tree gives
 * up protections the split provided structurally - most importantly the root-expiry asymmetry, which
 * I have already got WRONG once on RevocationRegistry (marking every root valid forever, safe for
 * inclusion, fatal for exclusion). Each guard below is therefore pinned by a test that fails if the
 * guard is removed, not by a comment asserting it holds.
 */
contract IdentityRegistryTest is Test {
  IdentityRegistry internal registry;
  HolderStateKeeperMock internal sk;

  bytes32 internal constant ICAO = 0x2c50ce3aa92bc3dd0351a89970b02630415547ea83c487befbc8b1795ea90c45;
  uint256 internal constant MAX_ROOT_AGE = 1 days;

  /// MUST equal withdraw_identity's IDENTITY_TREE_DEPTH and identityProof.ts's IDENTITY_TREE_DEPTH.
  /// Solarity's maxDepth is a CAP, so the ROOT is the same at any height - but a shallower registry
  /// would reject a deep insert the circuit accepts, and an emitted witness longer than the
  /// circuit's fixed sibling array cannot be padded into one.
  uint32 internal constant IDENTITY_TREE_DEPTH = 32;

  address internal CONTROLLER = address(0xC0FFEE);
  bytes32 internal constant PREDICATE_SANCTIONS = keccak256('OFAC_SDN');
  bytes32 internal constant PREDICATE_DOC_INVALID = keccak256('DOC_INVALID');

  /// From the committed escrow_envelope fixture - see EscrowEnvelopeHonkVerifier.t.sol.
  uint256 internal constant CONTROLLER_KEY_X =
    4_880_901_335_776_166_390_443_888_589_907_570_248_644_423_541_468_541_082_967_598_048_550_539_024_543;
  uint256 internal constant CONTROLLER_KEY_Y =
    6_509_666_988_291_764_283_313_685_078_036_329_297_907_336_602_650_572_952_945_826_675_203_643_401_307;

  function setUp() public {
    PoseidonSMTMock smt = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
    PoseidonSMTMock certs = PoseidonSMTMock(_proxy(address(new PoseidonSMTMock())));
    sk = HolderStateKeeperMock(_proxy(address(new HolderStateKeeperMock())));

    TestEvidenceRegistry ev = new TestEvidenceRegistry();
    smt.__PoseidonSMT_init(address(sk), address(ev), 80);
    certs.__PoseidonSMT_init(address(sk), address(ev), 80);
    sk.__StateKeeper_init(address(0xA11CE), address(smt), address(certs), ICAO);

    // Open the registration gate to this test so a document can be planted directly.
    string[] memory keys = new string[](1);
    keys[0] = 'test';
    address[] memory vals = new address[](1);
    vals[0] = address(this);
    sk.mockAddRegistrations(keys, vals);

    bytes32[] memory preds = new bytes32[](2);
    preds[0] = PREDICATE_SANCTIONS;
    preds[1] = PREDICATE_DOC_INVALID;

    registry = new IdentityRegistry(
      address(new EscrowEnvelopeHonkVerifier()),
      address(sk),
      CONTROLLER,
      CONTROLLER_KEY_X,
      CONTROLLER_KEY_Y,
      IDENTITY_TREE_DEPTH,
      MAX_ROOT_AGE,
      preds
    );
  }

  function _proxy(address impl) internal returns (address) {
    return address(new UnsafeTestProxy(impl));
  }

  function _proof() internal view returns (bytes memory) {
    return _proofAt(0);
  }

  function _proofAt(uint256 _i) internal view returns (bytes memory) {
    return vm.readFileBinary(string.concat('test/fixtures/escrow_envelope', vm.toString(_i), '.proof'));
  }

  function _publicInputs() internal view returns (bytes32[] memory) {
    return _publicInputsAt(0);
  }

  function _publicInputsAt(uint256 _n) internal view returns (bytes32[] memory _inputs) {
    bytes memory _raw =
      vm.readFileBinary(string.concat('test/fixtures/escrow_envelope', vm.toString(_n), '.public'));
    _inputs = new bytes32[](12);
    for (uint256 _i = 0; _i < 12; _i++) {
      bytes32 _w;
      assembly {
        _w := mload(add(_raw, add(32, mul(_i, 32))))
      }
      _inputs[_i] = _w;
    }
  }

  /// Plant the document the fixture's escrow refers to, so `register` finds it bound.
  function _plantDocument() internal {
    _plantDocumentAt(0);
  }

  function _plantDocumentAt(uint256 _n) internal {
    bytes32[] memory p = _publicInputsAt(_n);
    sk.addDocument(
      bytes32(uint256(0xD0C) + _n), p[4] /* dg1Hash */, p[2] /* holderRoot */, sk.DOC_PASSPORT(), 111 + _n, 0
    );
  }

  /*
   * EMITS the identity inclusion witness the withdrawal fixture is built from.
   *
   * WHY THE TEST SUITE GENERATES IT. The wallet never rebuilds this tree - it asks the contract,
   * because a second implementation of a sparse trie is a permanent byte-compatibility liability
   * (see pp/identityProof.ts). The FIXTURE has to come from the same place for the same reason: a
   * witness built off-chain would only ever prove that two of our own implementations agree.
   * Regenerating it inside the suite means it cannot go stale against the contract.
   *
   * THREE REGISTRATIONS, NOT ONE. A single-leaf SMT has an EMPTY inclusion path, so a withdrawal
   * built on it would hash no siblings and prove nothing about the Merkle path - the same
   * degeneracy tools/build-withdrawal-fixture.js already refuses to emit for the state tree. Each
   * one goes through the real `register` with its own genuine escrow proof; there is deliberately
   * no privileged insert to shortcut with.
   */
  function test_EmitIdentityWitnessFixture() public {
    for (uint256 i = 0; i < 3; i++) {
      _plantDocumentAt(i);
      registry.register(_proofAt(i), _publicInputsAt(i));
    }
    assertEq(registry.registeredCount(), 3, 'expected three genuine registrations');

    bytes32 commitment = _publicInputsAt(0)[3];
    SparseMerkleTree.Proof memory p = registry.getProof(commitment);

    assertTrue(p.existence, 'the primary identity is not in the tree');
    assertEq(p.value, bytes32(0), 'the primary identity is not CLEAN');
    assertGt(p.siblings.length, 0, 'DEGENERATE witness - no sibling would ever be hashed');

    string memory json = 'identityWitness';
    vm.serializeBytes32(json, 'root', p.root);
    vm.serializeBytes32(json, 'commitment', commitment);
    string memory out = vm.serializeBytes32(json, 'siblings', p.siblings);
    vm.writeJson(out, 'test/fixtures/identity_witness.json');
  }

  // ── the happy path ──────────────────────────────────────────────────────────────────────

  function test_RegisterWithRealProof() public {
    _plantDocument();
    bytes32 before = registry.root();

    registry.register(_proof(), _publicInputs());

    bytes32[] memory p = _publicInputs();
    assertTrue(registry.registered(p[3]), 'commitment not marked registered');
    assertEq(registry.statusOf(p[3]), bytes32(0), 'a fresh registration must be CLEAN (value 0)');
    assertEq(registry.registeredCount(), 1);
    assertTrue(registry.root() != before, 'root did not change on registration');
    assertTrue(registry.isValidRoot(registry.root()), 'the new root is not valid');
  }

  // ── TRAP 5: an escrow proof does NOT prove the passport is real ──────────────────────────

  function test_RegisterRevertsWhenTheDocumentWasNeverRegistered() public {
    // No _plantDocument(). The proof is perfectly valid - it just attests to an MRZ nobody has ever
    // registered through the ICAO-verified path. Without this guard the tree's scarcity guarantee,
    // and therefore the entire blacklist, is worthless.
    bytes32[] memory p = _publicInputs();
    bytes memory pf = _proof();

    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.DocumentNotRegistered.selector, p[4]));
    registry.register(pf, p);
  }

  function test_RegisterRevertsWhenTheDocumentBelongsToAnotherHolder() public {
    bytes32[] memory p = _publicInputs();
    sk.addDocument(bytes32(uint256(0xD0C)), p[4], bytes32(uint256(0xBEEF)), sk.DOC_PASSPORT(), 111, 0);
    bytes memory pf = _proof();

    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.DocumentBoundToAnotherHolder.selector, p[4]));
    registry.register(pf, p);
  }

  // ── envelope must be readable by the controller ──────────────────────────────────────────

  function test_RegisterRevertsOnAForeignControllerKey() public {
    _plantDocument();
    bytes32[] memory p = _publicInputs();
    p[0] = bytes32(uint256(p[0]) + 1); // sealed to a key the controller does not hold
    bytes memory pf = _proof();

    vm.expectRevert(IdentityRegistry.WrongControllerKey.selector);
    registry.register(pf, p);
  }

  function test_RegisterRevertsOnWrongInputCount() public {
    bytes32[] memory short_ = new bytes32[](11);
    bytes memory pf = _proof();

    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.WrongPublicInputCount.selector, uint256(11)));
    registry.register(pf, short_);
  }

  function test_RegisterRevertsOnDuplicate() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());

    bytes32[] memory p = _publicInputs();
    bytes memory pf = _proof();
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.AlreadyRegistered.selector, p[3]));
    registry.register(pf, p);
  }

  // ── TRAP 4: only the controller revokes ─────────────────────────────────────────────────

  function test_RevokeRevertsForNonController() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[3];

    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotTheController.selector, address(this)));
    registry.revoke(c, PREDICATE_SANCTIONS);
  }

  // ── TRAP 2: zero is the CLEAN sentinel ──────────────────────────────────────────────────

  function test_RevokeRejectsAZeroPredicate() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[3];

    // A zero predicate would write the CLEAN value and "revoke" the identity into good standing.
    vm.prank(CONTROLLER);
    vm.expectRevert(IdentityRegistry.ZeroPredicate.selector);
    registry.revoke(c, bytes32(0));
  }

  function test_ConstructorRejectsAZeroPredicate() public {
    bytes32[] memory preds = new bytes32[](1);
    preds[0] = bytes32(0);

    // vm.expectRevert does NOT reliably match a revert raised inside CREATE, so this asserts the
    // deployment failed via try/catch instead. Using expectRevert here reports "did not revert"
    // even when the guard is working - a false failure that hides a working guard.
    address verifier_ = address(new EscrowEnvelopeHonkVerifier());
    try new IdentityRegistry(
      verifier_, address(sk), CONTROLLER, CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) {
      fail('a zero predicate was accepted at deploy - revocation could write the CLEAN state');
    } catch {}
  }

  function test_RevokeRejectsAnUnknownPredicate() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[3];

    vm.prank(CONTROLLER);
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.UnknownPredicate.selector, keccak256('MADE_UP')));
    registry.revoke(c, keccak256('MADE_UP'));
  }

  function test_RevokeRevertsForAnUnregisteredCommitment() public {
    vm.prank(CONTROLLER);
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.NotRegistered.selector, bytes32(uint256(0xAB))));
    registry.revoke(bytes32(uint256(0xAB)), PREDICATE_SANCTIONS);
  }

  function test_RevokeIsMonotone() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[3];

    vm.prank(CONTROLLER);
    registry.revoke(c, PREDICATE_SANCTIONS);
    assertEq(registry.statusOf(c), PREDICATE_SANCTIONS, 'predicate not recorded as the leaf status');

    vm.prank(CONTROLLER);
    vm.expectRevert(abi.encodeWithSelector(IdentityRegistry.AlreadyRevoked.selector, c));
    registry.revoke(c, PREDICATE_DOC_INVALID);
  }

  // ── TRAP 1: root expiry, the asymmetry I already got wrong once ─────────────────────────

  function test_LatestRootIsAlwaysValidHoweverOld() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 latest = registry.root();

    // Inaction must stay harmless: a controller that never acts again blocks nobody.
    vm.warp(block.timestamp + 365 days);
    assertTrue(registry.isValidRoot(latest), 'the latest root expired - inaction became censorship');
  }

  function test_ASupersededCleanRootExpires() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 cleanRoot = registry.root();
    bytes32 c = _publicInputs()[3];

    vm.prank(CONTROLLER);
    registry.revoke(c, PREDICATE_SANCTIONS);

    // THE WHOLE POINT. The pre-revocation root still proves `commitment -> 0`. It stays valid only
    // long enough not to invalidate in-flight proofs; if it NEVER expired, a revoked identity could
    // withdraw forever by proving against it. That is precisely the bug shipped once on
    // RevocationRegistry by reasoning from the ASP's inclusion semantics.
    assertTrue(registry.isValidRoot(cleanRoot), 'a just-superseded root should still be usable');

    vm.warp(block.timestamp + MAX_ROOT_AGE + 1);
    assertFalse(registry.isValidRoot(cleanRoot), 'the pre-revocation root NEVER EXPIRED - revocation is escapable');
    assertTrue(registry.isValidRoot(registry.root()), 'the post-revocation root should be valid');
  }

  function test_UnknownRootIsRejected() public view {
    assertFalse(registry.isValidRoot(bytes32(uint256(0xDEAD))), 'an invented root was accepted');
    assertFalse(registry.isValidRoot(bytes32(0)), 'the zero root was accepted');
  }

  // ── coverage PORTED from RevocationRegistry.t.sol, which this registry supersedes ───────────
  //
  // Mapped case by case rather than assumed. Most of that suite already has an equivalent above
  // (CannotRevokeTwice -> RevokeIsMonotone, StrangerCannotRevoke -> RevokeRevertsForNonController,
  // StaleRootStopsBeingValid -> ASupersededCleanRootExpires, RootThatNeverExisted ->
  // UnknownRootIsRejected, UnknownPredicateIsUncitable -> RevokeRejectsAnUnknownPredicate). These
  // are the ones that did NOT, and deleting that file without them would have silently narrowed
  // coverage - the exact failure mode this project keeps finding.
  //
  // One case is deliberately NOT ported. `test_AttesterCannotCiteAnotherPredicate` covered
  // per-predicate attesters, which are gone BY DESIGN: one controller writes this list and the
  // label list alike. That is a removed behaviour, not lost coverage.

  /// A duplicate passes silently otherwise - `isPredicate` is idempotent - while pushing the same
  /// value twice into `_predicates`, so the published set misreports itself. Deploy-time only and
  /// immutable, so there is no correcting it afterwards. This guard did NOT exist until the port
  /// found RevocationRegistry had it and IdentityRegistry did not.
  function test_ConstructorRejectsDuplicatePredicates() public {
    bytes32[] memory preds = new bytes32[](2);
    preds[0] = PREDICATE_SANCTIONS;
    preds[1] = PREDICATE_SANCTIONS;

    address verifier_ = address(new EscrowEnvelopeHonkVerifier());
    try new IdentityRegistry(
      verifier_, address(sk), CONTROLLER, CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) {
      fail('a duplicate predicate was accepted - the published set would misreport itself forever');
    } catch {}
  }

  function test_ConstructorRejectsAnEmptyPredicateSet() public {
    bytes32[] memory preds = new bytes32[](0);
    address verifier_ = address(new EscrowEnvelopeHonkVerifier());
    try new IdentityRegistry(
      verifier_, address(sk), CONTROLLER, CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) {
      fail('a registry with NO predicates was accepted - no revocation could ever cite a reason');
    } catch {}
  }

  function test_ConstructorRejectsZeroAddresses() public {
    bytes32[] memory preds = new bytes32[](1);
    preds[0] = PREDICATE_SANCTIONS;
    address verifier_ = address(new EscrowEnvelopeHonkVerifier());

    try new IdentityRegistry(
      address(0), address(sk), CONTROLLER, CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) { fail('a zero verifier was accepted'); } catch {}

    try new IdentityRegistry(
      verifier_, address(0), CONTROLLER, CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) { fail('a zero state keeper was accepted'); } catch {}

    try new IdentityRegistry(
      verifier_, address(sk), address(0), CONTROLLER_KEY_X, CONTROLLER_KEY_Y, IDENTITY_TREE_DEPTH, MAX_ROOT_AGE, preds
    ) { fail('a zero controller was accepted - nobody could ever revoke'); } catch {}
  }

  /// The predicate must land in the TREE as the leaf value, not merely in a mapping. That is what
  /// makes a revocation auditable from committed state rather than from the event log, and what a
  /// future proof-of-correct-listing would prove against.
  function test_TheLeafValueRecordsThePredicate() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[3];

    vm.prank(CONTROLLER);
    registry.revoke(c, PREDICATE_SANCTIONS);

    SparseMerkleTree.Proof memory p = registry.getProof(c);
    assertTrue(p.existence, 'the revoked identity left the tree');
    assertEq(p.value, PREDICATE_SANCTIONS, 'the leaf value is not the cited predicate');
  }

  function test_RevokingMovesTheRoot() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 before = registry.root();

    vm.prank(CONTROLLER);
    registry.revoke(_publicInputs()[3], PREDICATE_SANCTIONS);

    assertTrue(registry.root() != before, 'revoking did not move the root, so it would not take effect');
    assertEq(registry.revokedCount(), 1);
  }

  /// No owner, no upgrade path, no role administration. The value of this registry is that NOBODY
  /// can rewrite it, including us - an upgradeable identity gate is a mutable one with extra steps.
  function test_ThereIsNoGovernanceSurface() public view {
    string[4] memory forbidden =
      ['owner()', 'upgradeToAndCall(address,bytes)', 'grantRole(bytes32,address)', 'transferOwnership(address)'];
    for (uint256 i = 0; i < forbidden.length; i++) {
      (bool ok,) = address(registry).staticcall(abi.encodeWithSelector(bytes4(keccak256(bytes(forbidden[i])))));
      assertFalse(ok, string.concat('the registry answers a governance selector: ', forbidden[i]));
    }
  }

  // ── TRAP 3: removal must not exist ──────────────────────────────────────────────────────

  function test_ThereIsNoRemovalPath() public {
    _plantDocument();
    registry.register(_proof(), _publicInputs());
    bytes32 c = _publicInputs()[3];

    // The solarity SMT provides `remove`, and exposing it would let a controller ERASE a
    // registration - censorship by deletion. Assert no such selector is callable: any of the
    // obvious spellings must hit the fallback and fail.
    string[3] memory sigs = ['remove(bytes32)', 'unregister(bytes32)', 'deregister(bytes32)'];
    for (uint256 i = 0; i < sigs.length; i++) {
      (bool ok,) = address(registry).call(abi.encodeWithSignature(sigs[i], c));
      assertFalse(ok, 'a removal path exists on the registry');
    }
    assertTrue(registry.registered(c), 'the registration is gone');
  }
}
