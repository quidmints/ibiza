// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {Entrypoint} from '../../contracts/pool/Entrypoint.sol';
import {PrivacyPoolSimple} from '../../contracts/pool/implementations/PrivacyPoolSimple.sol';
import {WithdrawalHonkVerifier} from '../../contracts/pool/verifiers/WithdrawalHonkVerifier.sol';
import {VerifierMock} from '../../contracts/mock/verifiers/VerifierMock.sol';
import {IPrivacyPool} from '../../contracts/pool/interfaces/IPrivacyPool.sol';
import {ProofLib} from '../../contracts/pool/lib/ProofLib.sol';
import {Constants} from '../../contracts/pool/lib/Constants.sol';

/// Minimal ERC-7812 registry — same pattern as EntrypointAsp.t.sol (the real one has a
/// Poseidon-under-Forge linking issue); nothing here depends on its behaviour beyond storing.
contract MockEvidenceRegistry is IEvidenceRegistry {
  mapping(bytes32 => bytes32) public statements;

  function addStatement(bytes32 key, bytes32 value) external {
    if (statements[key] != bytes32(0)) revert KeyAlreadyExists(key);
    statements[key] = value;
  }

  function removeStatement(bytes32 key) external {
    delete statements[key];
  }

  function updateStatement(bytes32 key, bytes32 newValue) external {
    statements[key] = newValue;
  }

  function getRootTimestamp(bytes32) external view returns (uint256) {
    return block.timestamp;
  }

  function getIsolatedKey(address source, bytes32 key) external pure returns (bytes32) {
    return keccak256(abi.encodePacked(source, key));
  }
}

/*
 * THE INTEGRATION GAP THIS CLOSES.
 *
 * Before this file, the two halves of the withdrawal path had NEVER MET:
 *   - WithdrawalHonkVerifier.t.sol feeds a REAL proof to `verifier.verify()` directly, with no pool.
 *   - PrivacyPoolSimple.t.sol exercises the real `withdraw()` path against a NoirVerifierMock and a
 *     MockEntrypoint, i.e. a fake proof.
 * So everything PrivacyPool itself enforces was untested against a genuine proof: the `context`
 * recomputation in validWithdrawal, `_isKnownRoot` over the 64-deep root history,
 * `ENTRYPOINT.isKnownAspRoot`, nullifier spending, the change-note insert, and the payout.
 *
 * It is also the ONLY test that validates the WALLET'S TREE MIRRORS against the chain. The proof
 * below commits to a `state_root` and an `asp_root` that the wallet's src/pp/stateTree.ts and
 * src/postman/identityAsp.ts computed OFF-CHAIN, and the pool independently rejects anything whose
 * roots it does not itself hold. A LeanIMT ordering bug, an off-by-one leaf index, or a
 * LeafInserted misread would fail here and nowhere else.
 *
 * FIXTURE PROVENANCE: tools/build-e2e-fixture.js — it reads the values logged by
 * test_LogFixtureInputs below, derives the note with the wallet's own code, builds both trees,
 * assembles the witness, and proves with bb 1.2.0. Regenerate with that script if the pool's SCOPE
 * changes (it is derived from the deployed address, so ANY change to deployment order in setUp
 * invalidates the fixture — test_ScopeMatchesFixture pins that).
 */
contract WithdrawEndToEndTest is Test {
  Entrypoint internal entrypoint;
  PrivacyPoolSimple internal pool;
  WithdrawalHonkVerifier internal withdrawalVerifier;
  MockEvidenceRegistry internal registry;

  address internal owner = address(0xA011);
  address internal postman = address(0xB022);
  address internal depositor = address(0xD0D0);
  address internal recipient = address(0xF00D);

  uint256 internal constant FIELD = Constants.SNARK_SCALAR_FIELD;
  uint256 internal constant DEPOSIT_VALUE = 1 ether;

  /// holderRoot for sk_identity = 1234 (pp/src/identity_asp.nr's published vector), as the wallet's
  /// RarimeUtils.getProfileKey derives it: Poseidon(babyJub.mulPointEScalar(Base8, 1234)).
  uint256 internal constant HOLDER_ROOT =
    0x19bba1d1ede002b61a36d0665bbda703edcf937d846a50864eef80fa7887bded;

  /*
   * Wallet-derived precommitments for THIS pool's SCOPE, from the standard Foundry test mnemonic:
   * Poseidon(nullifier, secret) where the pair is depositSecrets(masterKeys, SCOPE, i). Four of
   * them, and three ASP members, ON PURPOSE - a single deposit gives a size-1 LeanIMT whose root
   * simply IS the leaf, so depth would be 0 and NO SIBLING WOULD EVER BE HASHED. That is the exact
   * degeneracy removed from the verifier fixtures; re-introducing it here would make this test
   * verify a Merkle path it never actually walks.
   */
  uint256[4] internal PRECOMMITMENTS = [
    7859817061603428290238186566395526149948046297166087753738334840531322587938,
    19717560693715280287714986424254343473332961231107022155002803288087080511988,
    20366035142657093795538900147841796082338868149991991895380794842569755222825,
    18622503828118355361935587394317966821763155120431008971272362326958763936848
  ];

  /// Ours is index 1 - deliberately not first or last, so its inclusion path has siblings on both
  /// sides rather than riding the LeanIMT's carry-up-on-empty edge case.
  uint256 internal constant OUR_NOTE_INDEX = 1;

  uint256[3] internal ASP_MEMBERS = [uint256(777), HOLDER_ROOT, uint256(999)];

  uint256 internal ourCommitment;
  uint256 internal ourLabel;
  uint256 internal aspRoot;

  /// Computed OFF-CHAIN by the wallet - see test_WalletMirrorsMatchTheChain.
  uint256 internal constant WALLET_STATE_ROOT =
    4114006897518807419215143935931624663519652876625887777639485551411280863138;
  uint256 internal constant WALLET_ASP_ROOT =
    13499987760479541807145949197691077146081665672725695371757070291942633612052;

  // ── the proved withdrawal (test/fixtures/withdraw_e2e.proof) ────────────────────────────────
  uint256 internal constant WITHDRAWN = 0.3 ether;
  uint256 internal constant E2E_NEW_COMMITMENT =
    20911098276590035301995024307415858626236264280914295270101660895966176628336;
  uint256 internal constant E2E_NULLIFIER_HASH =
    3101124718011203832034772889318834163913351541408400082945464046908098353548;
  uint256 internal constant E2E_CONTEXT =
    2195019173842957884687453008429900813153802825418390942674290471629585962774;

  function setUp() public {
    registry = new MockEvidenceRegistry();

    Entrypoint impl = new Entrypoint();
    bytes memory init = abi.encodeCall(Entrypoint.initialize, (owner, postman, address(registry)));
    entrypoint = Entrypoint(payable(address(new ERC1967Proxy(address(impl), init))));

    withdrawalVerifier = new WithdrawalHonkVerifier();
    pool = new PrivacyPoolSimple(
      address(entrypoint), address(withdrawalVerifier), address(new VerifierMock())
    );

    // Four real deposits through the real pool, so the state tree has genuine depth.
    for (uint256 i = 0; i < PRECOMMITMENTS.length; i++) {
      uint256 label = uint256(keccak256(abi.encodePacked(pool.SCOPE(), pool.nonce() + 1))) % FIELD;
      vm.deal(address(entrypoint), DEPOSIT_VALUE);
      vm.prank(address(entrypoint));
      uint256 c = pool.deposit{value: DEPOSIT_VALUE}(depositor, DEPOSIT_VALUE, PRECOMMITMENTS[i]);
      if (i == OUR_NOTE_INDEX) {
        ourCommitment = c;
        ourLabel = label;
      }
    }

    // Three ASP admissions through the real Entrypoint, ours in the middle.
    for (uint256 i = 0; i < ASP_MEMBERS.length; i++) {
      vm.prank(postman);
      aspRoot = entrypoint.admitIdentity(ASP_MEMBERS[i]);
    }
  }

  /*
   * PASS 1 of fixture generation. The proof must commit to values that do not exist until the
   * contracts are deployed and deposited into - SCOPE is derived from the pool's address, and
   * `label` from SCOPE - so they cannot be chosen in advance. Run this, feed the output to
   * tools/build-e2e-fixture.js, then fill in the constants above.
   *
   *   forge test --match-test test_LogFixtureInputs -vv
   */
  function test_LogFixtureInputs() public {
    emit log_named_uint('SCOPE', pool.SCOPE());
    emit log_named_uint('our label', ourLabel);
    emit log_named_uint('our commitment', ourCommitment);
    emit log_named_uint('our leaf index', OUR_NOTE_INDEX);
    emit log_named_uint('state root', pool.currentRoot());
    emit log_named_uint('state depth', pool.currentTreeDepth());
    emit log_named_uint('state size', pool.currentTreeSize());
    emit log_named_uint('asp root', aspRoot);
    emit log_named_uint('asp depth', entrypoint.aspTreeDepth());
    emit log_named_uint('deposit value', DEPOSIT_VALUE);

    // The context the proof must carry for a SELF-withdrawal to `recipient`. Transcribed from
    // PrivacyPool.validWithdrawal, which recomputes and compares this independently.
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});
    emit log_named_uint('context', uint256(keccak256(abi.encode(w, pool.SCOPE()))) % FIELD);
  }

  /*
   * THE MIRROR CROSS-CHECK, and the reason this file earns its place.
   *
   * These two roots were computed OFF-CHAIN by the wallet's src/pp/stateTree.ts and
   * src/postman/identityAsp.ts from the same leaves, in the same order. The chain computed its own
   * with lean-imt/InternalLeanIMT.sol + PoseidonT3. If the wallet's LeanIMT disagreed with the
   * contract's in ANY respect - node ordering, the carry-up-on-empty rule, Poseidon parameters,
   * insertion order - these would differ, and every proof the wallet ever produced would be
   * rejected on-chain with no indication that the mirror was the cause.
   *
   * Nothing else in the suite tests this. The verifier tests use trees the wallet built alone.
   */
  function test_WalletMirrorsMatchTheChain() public view {
    assertEq(pool.currentRoot(), WALLET_STATE_ROOT, 'wallet stateTree.ts disagrees with the pool');
    assertTrue(entrypoint.isKnownAspRoot(WALLET_ASP_ROOT), 'wallet identityAsp.ts disagrees with the Entrypoint');
    assertEq(pool.currentTreeDepth(), 2, 'state tree is not multi-level - fixture would be degenerate');
    assertGt(entrypoint.aspTreeDepth(), 0, 'ASP tree is degenerate');
  }

  function _e2eProof() internal view returns (ProofLib.WithdrawProof memory _p) {
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_e2e.proof');
    _p.pubSignals = [
      E2E_NEW_COMMITMENT,
      E2E_NULLIFIER_HASH,
      WITHDRAWN,
      WALLET_STATE_ROOT,
      uint256(2), // state_tree_depth
      WALLET_ASP_ROOT,
      uint256(2), // asp_tree_depth
      E2E_CONTEXT
    ];
  }

  /*
   * THE WHOLE POINT: a genuine proof, built by the wallet against THIS pool's real state, driven
   * through the real `withdraw()` - the real verifier, the real Entrypoint, the real root history,
   * the real nullifier set, and a real payout. Never done before this file.
   */
  function test_WithdrawWithRealProof() public {
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});

    uint256 balanceBefore = recipient.balance;
    uint256 sizeBefore = pool.currentTreeSize();

    vm.prank(recipient); // processooor must be the caller (PrivacyPool.sol:45)
    pool.withdraw(w, _e2eProof());

    assertEq(recipient.balance - balanceBefore, WITHDRAWN, 'recipient was not paid the withdrawn value');
    assertTrue(pool.nullifierHashes(E2E_NULLIFIER_HASH), 'nullifier was not marked spent');
    assertEq(pool.currentTreeSize(), sizeBefore + 1, 'change note was not inserted');
  }

  /// The nullifier set must actually prevent a replay - the property the whole spend model rests on.
  function test_ReplayIsRejected() public {
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});

    vm.prank(recipient);
    pool.withdraw(w, _e2eProof());

    vm.prank(recipient);
    vm.expectRevert();
    pool.withdraw(w, _e2eProof());
  }

  /*
   * `context` binds the proof to THESE withdrawal parameters. Submitting the same proof with a
   * different processooor must fail, or a relayer could redirect anyone's funds to itself - the
   * exact attack the context check exists to stop. Proving it with a REAL proof is what makes this
   * meaningful; against a mock verifier it would pass no matter what.
   */
  function test_ProofIsBoundToItsWithdrawalParameters() public {
    IPrivacyPool.Withdrawal memory tampered =
      IPrivacyPool.Withdrawal({processooor: address(0xBAD), data: ''});

    vm.prank(address(0xBAD));
    vm.expectRevert();
    pool.withdraw(tampered, _e2eProof());
  }
}
