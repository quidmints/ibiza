// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {MessageHashUtils} from '@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {TitleLedger} from '../../contracts/title/TitleLedger.sol';
import {RegistrySourceAnchor} from '../../contracts/registry/RegistrySourceAnchor.sol';
import {NoirVerifierMock} from '../../contracts/mock/verifiers/NoirVerifierMock.sol';
import {TitleHolderHonkVerifier} from '../../contracts/title/TitleHolderHonkVerifier.sol';

/// Same minimal in-test ERC-7812 registry pattern as RegistrySourceAnchor.t.sol / EntrypointAsp.t.sol.
contract MockEvidenceRegistry is IEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;

  function addStatement(bytes32 key, bytes32 value) external {
    if (statements[key] != bytes32(0)) revert KeyAlreadyExists(key);
    statements[key] = value;
  }

  function removeStatement(bytes32 key) external {
    if (statements[key] == bytes32(0)) revert KeyDoesNotExist(key);
    delete statements[key];
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

contract TitleLedgerTest is Test {
  TitleLedger internal ledger;
  RegistrySourceAnchor internal registry;
  NoirVerifierMock internal titleHolderVerifier;

  address internal admin = address(0xA011);
  address internal postman = address(0xB022);

  uint256 internal constant NOTARY_PK = 0xC0FFEE;
  address internal notary;
  uint256 internal constant OTHER_PK = 0xBEEF;
  address internal otherSigner;

  bytes32 internal constant REGISTRY_ID = keccak256('UA_NOTARY_REGISTRY');
  bytes32 internal notaryDataHash;
  bytes32 internal decoyLeaf;
  bytes32[] internal notaryProof; // sibling(s) needed to prove notaryDataHash against the active root

  function setUp() public {
    notary = vm.addr(NOTARY_PK);
    otherSigner = vm.addr(OTHER_PK);

    RegistrySourceAnchor registryImpl = new RegistrySourceAnchor();
    bytes memory registryInit =
      abi.encodeCall(RegistrySourceAnchor.initialize, (address(new MockEvidenceRegistry()), admin));
    registry = RegistrySourceAnchor(address(new ERC1967Proxy(address(registryImpl), registryInit)));
    // Read the role constant BEFORE vm.prank - it's itself an external call and would otherwise
    // consume the single-shot prank before grantRole executes (see RegistrySourceAnchor.t.sol).
    bytes32 postmanRole = registry.REGISTRY_POSTMAN();
    vm.prank(admin);
    registry.grantRole(postmanRole, postman);

    titleHolderVerifier = new NoirVerifierMock();
    TitleLedger ledgerImpl = new TitleLedger();
    bytes memory ledgerInit =
      abi.encodeCall(TitleLedger.initialize, (address(registry), address(titleHolderVerifier), admin));
    ledger = TitleLedger(address(new ERC1967Proxy(address(ledgerImpl), ledgerInit)));

    // A real 2-leaf snapshot: notaryDataHash + one decoy, strictly ascending as
    // RegistrySourceAnchor requires.
    bytes32 a = keccak256('notary-1: reg#123, Jane Doe, Kyiv, active');
    bytes32 b = keccak256('notary-2: reg#456, John Roe, Lviv, active');
    notaryDataHash = a;
    decoyLeaf = b;
    (bytes32 leaf0, bytes32 leaf1) = a < b ? (a, b) : (b, a);
    bytes32[] memory leaves = new bytes32[](2);
    leaves[0] = leaf0;
    leaves[1] = leaf1;

    vm.prank(postman);
    registry.publishSnapshot(REGISTRY_ID, leaves);
    vm.warp(block.timestamp + registry.ROOT_ACTIVATION_DELAY());

    notaryProof = new bytes32[](1);
    notaryProof[0] = (a == leaf0) ? leaf1 : leaf0; // the OTHER leaf is notaryDataHash's sibling

    vm.prank(postman);
    ledger.bindNotaryAddress(notary, notaryDataHash);
  }

  function _mintMessage(
    bytes32 legalDescriptionHash_,
    bytes32 jurisdiction_,
    uint256 priorTitleId_
  ) internal view returns (bytes32) {
    return keccak256(abi.encodePacked('TITLE_LEDGER_MINT', address(ledger), legalDescriptionHash_, jurisdiction_, priorTitleId_));
  }

  function _sign(uint256 pk, bytes32 messageHash_) internal pure returns (bytes memory) {
    bytes32 digest = MessageHashUtils.toEthSignedMessageHash(messageHash_);
    (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
    return abi.encodePacked(r, s, v);
  }

  /// Replace the mock verifier's BYTECODE with the real one, in place.
  /// Keeps the existing registry/notary/signature wiring intact - standing up a second ledger just
  /// to change one immutable would have meant re-plumbing all of it, and the thing under test is
  /// the verifier, not the setup.
  function _useRealVerifier() internal {
    vm.etch(address(titleHolderVerifier), address(new TitleHolderHonkVerifier()).code);
  }

  function _mintValidTitle(bytes32 holderCommitment_) internal returns (uint256 titleId_) {
    bytes32 descHash = keccak256('42 Khreshchatyk St, Kyiv');
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(NOTARY_PK, _mintMessage(descHash, jurisdiction, 0));

    titleId_ = ledger.mintTitle(
      descHash, 'ipfs://legal-doc', jurisdiction, 0, REGISTRY_ID, notary, notaryProof, sig, holderCommitment_
    );
  }

  // ── initialization / upgradeability ─────────────────────────────────────────────────────

  function test_initialize_revertsOnZeroNotaryRegistry() public {
    TitleLedger impl = new TitleLedger();
    bytes memory init = abi.encodeCall(TitleLedger.initialize, (address(0), address(titleHolderVerifier), admin));
    vm.expectRevert(TitleLedger.ZeroAddress.selector);
    new ERC1967Proxy(address(impl), init);
  }

  function test_initialize_revertsOnZeroVerifier() public {
    TitleLedger impl = new TitleLedger();
    bytes memory init = abi.encodeCall(TitleLedger.initialize, (address(registry), address(0), admin));
    vm.expectRevert(TitleLedger.ZeroAddress.selector);
    new ERC1967Proxy(address(impl), init);
  }

  function test_initialize_cannotBeCalledTwice() public {
    vm.expectRevert();
    ledger.initialize(address(registry), address(titleHolderVerifier), admin);
  }

  function test_upgradeToAndCall_revertsForNonOwner() public {
    TitleLedger newImpl = new TitleLedger();
    vm.expectRevert();
    ledger.upgradeToAndCall(address(newImpl), '');
  }

  // ── bindNotaryAddress ───────────────────────────────────────────────────────────────────

  function test_bindNotaryAddress_revertsForNonPostman() public {
    vm.expectRevert(TitleLedger.OnlyRegistryPostman.selector);
    ledger.bindNotaryAddress(notary, notaryDataHash);
  }

  // ── mintTitle ───────────────────────────────────────────────────────────────────────────

  function test_mintTitle_succeeds() public {
    bytes32 holderCommitment = keccak256('holder-commitment-1');
    uint256 titleId = _mintValidTitle(holderCommitment);

    assertEq(titleId, 1);
    assertEq(ledger.holderCommitment(titleId), holderCommitment);
    TitleLedger.TitleEntry memory entry = ledger.getTitle(titleId);
    assertEq(entry.legalDescriptionHash, keccak256('42 Khreshchatyk St, Kyiv'));
    assertEq(entry.jurisdiction, keccak256('UA'));
    assertEq(entry.priorTitleId, 0);
    assertEq(entry.notaryRegistryId, REGISTRY_ID);
    assertEq(entry.notary, notary);
    assertEq(entry.mintedAt, block.timestamp);
    assertFalse(entry.encumbered);
  }

  function test_mintTitle_revertsOnZeroCommitment() public {
    bytes32 descHash = keccak256('desc');
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(NOTARY_PK, _mintMessage(descHash, jurisdiction, 0));

    vm.expectRevert(TitleLedger.ZeroCommitment.selector);
    ledger.mintTitle(descHash, '', jurisdiction, 0, REGISTRY_ID, notary, notaryProof, sig, bytes32(0));
  }

  function test_mintTitle_revertsOnUnboundNotary() public {
    bytes32 descHash = keccak256('desc');
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(OTHER_PK, _mintMessage(descHash, jurisdiction, 0));

    vm.expectRevert(TitleLedger.NotaryNotActive.selector);
    ledger.mintTitle(
      descHash, '', jurisdiction, 0, REGISTRY_ID, otherSigner, notaryProof, sig, keccak256('hc')
    );
  }

  function test_mintTitle_revertsOnWrongMerkleProof() public {
    bytes32 descHash = keccak256('desc');
    bytes32 jurisdiction = keccak256('UA');
    bytes memory sig = _sign(NOTARY_PK, _mintMessage(descHash, jurisdiction, 0));

    bytes32[] memory badProof = new bytes32[](1);
    badProof[0] = keccak256('wrong-sibling');

    vm.expectRevert(TitleLedger.NotaryNotActive.selector);
    ledger.mintTitle(descHash, '', jurisdiction, 0, REGISTRY_ID, notary, badProof, sig, keccak256('hc'));
  }

  function test_mintTitle_revertsOnInvalidSignature() public {
    bytes32 descHash = keccak256('desc');
    bytes32 jurisdiction = keccak256('UA');
    // Signed by otherSigner, claimed as `notary` - recovered signer won't match.
    bytes memory sig = _sign(OTHER_PK, _mintMessage(descHash, jurisdiction, 0));

    vm.expectRevert(TitleLedger.InvalidNotarySignature.selector);
    ledger.mintTitle(descHash, '', jurisdiction, 0, REGISTRY_ID, notary, notaryProof, sig, keccak256('hc'));
  }

  // ── addLegend ───────────────────────────────────────────────────────────────────────────

  function test_addLegend_succeeds() public {
    uint256 titleId = _mintValidTitle(keccak256('hc'));

    bytes32 legendMsg = keccak256(abi.encodePacked('TITLE_LEDGER_LEGEND', address(ledger), titleId, 'subject to mortgage'));
    bytes memory sig = _sign(NOTARY_PK, legendMsg);
    ledger.addLegend(titleId, 'subject to mortgage', notaryProof, sig);

    string[] memory legends = ledger.getRestrictionLegends(titleId);
    assertEq(legends.length, 1);
    assertEq(legends[0], 'subject to mortgage');
  }

  function test_addLegend_revertsOnTitleNotFound() public {
    bytes32 legendMsg = keccak256(abi.encodePacked('TITLE_LEDGER_LEGEND', address(ledger), uint256(999), 'x'));
    bytes memory sig = _sign(NOTARY_PK, legendMsg);

    vm.expectRevert(TitleLedger.TitleDoesNotExist.selector);
    ledger.addLegend(999, 'x', notaryProof, sig);
  }

  function test_addLegend_revertsOnMintSignatureReplay() public {
    // A signature captured for mintTitle must NOT authorize addLegend - domain separation check.
    uint256 titleId = _mintValidTitle(keccak256('hc'));
    bytes32 descHash = keccak256('42 Khreshchatyk St, Kyiv');
    bytes32 jurisdiction = keccak256('UA');
    bytes memory mintSig = _sign(NOTARY_PK, _mintMessage(descHash, jurisdiction, 0));

    vm.expectRevert(TitleLedger.InvalidNotarySignature.selector);
    ledger.addLegend(titleId, 'subject to mortgage', notaryProof, mintSig);
  }

  // ── setEncumbered ───────────────────────────────────────────────────────────────────────

  function test_setEncumbered_succeeds() public {
    uint256 titleId = _mintValidTitle(keccak256('hc'));

    bytes32 msg_ = keccak256(abi.encodePacked('TITLE_LEDGER_ENCUMBER', address(ledger), titleId, true));
    bytes memory sig = _sign(NOTARY_PK, msg_);
    ledger.setEncumbered(titleId, true, notaryProof, sig);

    assertTrue(ledger.getTitle(titleId).encumbered);
  }

  function test_setEncumbered_revertsWithoutNotarySignature() public {
    uint256 titleId = _mintValidTitle(keccak256('hc'));
    bytes32 msg_ = keccak256(abi.encodePacked('TITLE_LEDGER_ENCUMBER', address(ledger), titleId, true));
    bytes memory sig = _sign(OTHER_PK, msg_);

    vm.expectRevert(TitleLedger.InvalidNotarySignature.selector);
    ledger.setEncumbered(titleId, true, notaryProof, sig);
  }

  // ── transferTitle / verifyHolderProof ──────────────────────────────────────────────────

  /*
   * THE REAL VERIFIER, NOT THE MOCK.
   *
   * These two used to assert only that TitleLedger forwards to whatever verifier it holds - the
   * mock returns true, so `hex'ab'` "verified". That tests the plumbing and nothing about whether
   * a genuine holder proof is accepted, which is the claim that matters: a title's holder proof is
   * what links a title to an identity without revealing it.
   *
   * Now a real TitleHolderHonkVerifier and a real proof. The commitment is the circuit's own
   * expected_commitment for title_id = 1 (= Poseidon(holder_root(sk 1234), 1)), and titleId is 1
   * because TitleLedger's counter starts there - the public inputs TitleLedger builds
   * ([holderCommitment, titleId]) must be exactly the ones the circuit bound.
   */
  uint256 internal constant TITLE1_COMMITMENT =
    13133097628895757648741781760678152926284111620646563595865187894813129799232;

  function test_verifyHolderProof_acceptsARealProof() public {
    uint256 titleId = _mintValidTitle(bytes32(TITLE1_COMMITMENT));
    assertEq(titleId, 1, 'fixture is bound to title_id = 1');
    _useRealVerifier();

    assertTrue(
      ledger.verifyHolderProof(titleId, vm.readFileBinary('test/fixtures/title_holder_id1.proof')),
      'a genuine holder proof was rejected'
    );
  }

  /// @notice The same proof against a DIFFERENT title must fail - otherwise one holder proof would
  /// unlock every title, which is the whole property `title_id` is a public input for.
  function test_verifyHolderProof_rejectsAProofBoundToAnotherTitle() public {
    _mintValidTitle(bytes32(TITLE1_COMMITMENT));
    uint256 second = _mintValidTitle(bytes32(TITLE1_COMMITMENT));
    _useRealVerifier();

    // The Honk verifier REVERTS (SumcheckFailed) rather than returning false when the public
    // inputs do not match the proof - both are correct rejections, so accept either.
    try ledger.verifyHolderProof(second, vm.readFileBinary('test/fixtures/title_holder_id1.proof'))
    returns (bool ok) {
      assertFalse(ok, 'a proof for title 1 was accepted for a different title');
    } catch {
      assertTrue(true);
    }
  }

  function test_verifyHolderProof_rejectsGarbageAgainstTheRealVerifier() public {
    uint256 titleId = _mintValidTitle(bytes32(TITLE1_COMMITMENT));
    _useRealVerifier();

    try ledger.verifyHolderProof(titleId, hex'ab') returns (bool ok) {
      assertFalse(ok, 'the real verifier accepted 2 bytes of garbage');
    } catch {
      assertTrue(true); // reverting on a malformed proof is equally correct
    }
  }

  function test_verifyHolderProof_revertsOnTitleNotFound() public {
    vm.expectRevert(TitleLedger.TitleDoesNotExist.selector);
    ledger.verifyHolderProof(999, hex'ab');
  }

  function test_transferTitle_succeeds() public {
    uint256 titleId = _mintValidTitle(keccak256('hc-old'));
    bytes32 newCommitment = keccak256('hc-new');

    ledger.transferTitle(titleId, newCommitment, hex'ab');
    assertEq(ledger.holderCommitment(titleId), newCommitment);
  }

  function test_transferTitle_revertsOnInvalidProof() public {
    uint256 titleId = _mintValidTitle(keccak256('hc-old'));
    titleHolderVerifier.setShouldVerify(false);

    vm.expectRevert(TitleLedger.InvalidHolderProof.selector);
    ledger.transferTitle(titleId, keccak256('hc-new'), hex'ab');
  }

  function test_transferTitle_revertsOnZeroNewCommitment() public {
    uint256 titleId = _mintValidTitle(keccak256('hc-old'));

    vm.expectRevert(TitleLedger.ZeroCommitment.selector);
    ledger.transferTitle(titleId, bytes32(0), hex'ab');
  }
}
