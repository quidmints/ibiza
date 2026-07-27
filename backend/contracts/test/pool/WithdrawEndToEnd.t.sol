// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {ERC1967Proxy} from '@oz/proxy/ERC1967/ERC1967Proxy.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {Entrypoint} from '../../contracts/pool/Entrypoint.sol';
import {IdentityAspRegistry} from '../../contracts/registry/IdentityAspRegistry.sol';
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
  IdentityAspRegistry internal aspRegistry;
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
    14894516687091200428867646999555195857366192177471111112487282030615629365635,
    13199981910239328870624154981781513659107854765074935359406948407461300864920,
    12882994012526257397249270087775781613032447103540512961946622769062666449753,
    10318167675095160449581079747579328628800989145060822024614324067031914075854
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
    16821439025066267276348068301416927716355643931045125335219004834544672089857;
  uint256 internal constant WALLET_ASP_ROOT =
    13499987760479541807145949197691077146081665672725695371757070291942633612052;

  // ── the proved withdrawal (test/fixtures/withdraw_e2e.proof) ────────────────────────────────
  uint256 internal constant WITHDRAWN = 0.3 ether;
  uint256 internal constant E2E_NEW_COMMITMENT =
    1237296196900923841159970544797035268653241631024055794471141723617698506354;
  uint256 internal constant E2E_NULLIFIER_HASH =
    19270481334125549904345247761028963384752785010606808297865858680963613098534;
  uint256 internal constant E2E_CONTEXT =
    19740679237850356548516882207291664877369069337852394327550049754510873474913;

  function setUp() public {
    registry = new MockEvidenceRegistry();

    Entrypoint impl = new Entrypoint();
    bytes memory init = abi.encodeCall(Entrypoint.initialize, (owner, postman, address(registry)));
    entrypoint = Entrypoint(payable(address(new ERC1967Proxy(address(impl), init))));

    // The ASP tree lives in its own NON-UPGRADEABLE registry now (sec. 2.5a), and the pool holds a
    // direct reference to it - the upgradeable Entrypoint is no longer in the ASP trust path.
    aspRegistry = new IdentityAspRegistry(postman, address(registry));

    withdrawalVerifier = new WithdrawalHonkVerifier();
    pool = new PrivacyPoolSimple(
      address(entrypoint), address(withdrawalVerifier), address(new VerifierMock()), address(aspRegistry)
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
      aspRoot = aspRegistry.admitIdentity(ASP_MEMBERS[i]);
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
    emit log_named_uint('asp depth', aspRegistry.aspTreeDepth());
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
    assertTrue(aspRegistry.isKnownAspRoot(WALLET_ASP_ROOT), 'wallet identityAsp.ts disagrees with the ASP registry');
    assertEq(pool.currentTreeDepth(), 2, 'state tree is not multi-level - fixture would be degenerate');
    assertGt(aspRegistry.aspTreeDepth(), 0, 'ASP tree is degenerate');
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

  /*
   * ═══ THE NEGATIVE INVARIANT (TODO.md sec. 2.5) ═══
   *
   * "A revocation is valid only if it cites a provable predicate from a closed set, AND THAT IS THE
   * ONLY WAY TO BLOCK A WITHDRAWAL." The second clause is a claim about the WHOLE withdrawal path,
   * not a feature, so it is asserted here by enumerating every way withdraw() can revert and
   * showing each is either the caller's own doing or the rule-bound membership check.
   *
   * PrivacyPool.withdraw reverts on exactly these, and nothing else:
   *   InvalidProcessooor   caller is not the address the proof commits to      -> caller's own
   *   ContextMismatch      proof does not match these withdrawal parameters    -> caller's own
   *   InvalidTreeDepth     declared depth exceeds MAX_TREE_DEPTH               -> caller's own
   *   UnknownStateRoot     state root outside the 64-root history              -> caller's own
   *                        (staleness only; rebuild the witness and retry)
   *   InvalidProof         the proof does not verify                           -> caller's own
   *   NullifierAlreadySpent  note already spent                                -> caller's own
   *   IncorrectASPRoot     ASP root not one the registry computed              -> RULE-BOUND
   *
   * Only the last is a third party's decision, and it is now bounded by a NON-UPGRADEABLE,
   * append-only registry with no owner (sec. 2.5a). Nothing else in the path consults any role,
   * owner, pause flag or upgrade.
   */
  function test_NoGovernanceLeverCanBlockAWithdrawal() public {
    // The ONLY governance action reachable on a live pool is windDown, via the Entrypoint.
    vm.prank(address(entrypoint));
    pool.windDown();
    assertTrue(pool.dead(), 'windDown did not take effect - the test proves nothing');

    // A dead pool must still pay out. Wind-down stops DEPOSITS; it must never trap funds already
    // inside, or "wind the pool down" would be a censorship lever over every existing depositor.
    IPrivacyPool.Withdrawal memory w = IPrivacyPool.Withdrawal({processooor: recipient, data: ''});
    uint256 before = recipient.balance;

    vm.prank(recipient);
    pool.withdraw(w, _e2eProof());

    assertEq(recipient.balance - before, WITHDRAWN, 'a wound-down pool blocked a valid withdrawal');
  }

  /// @notice The ASP membership check is the ONLY third-party-controlled revert in the path, and it
  /// is served by a contract with no owner and no upgrade path. If a future change routes it back
  /// through anything upgradeable, this pins the address the pool actually trusts.
  function test_TheOnlyThirdPartyGateIsTheNonUpgradeableRegistry() public view {
    assertEq(address(pool.ASP_REGISTRY()), address(aspRegistry), 'pool trusts an unexpected contract');

    string[4] memory forbidden =
      ['owner()', 'upgradeToAndCall(address,bytes)', 'grantRole(bytes32,address)', 'remove(uint256)'];
    for (uint256 i = 0; i < forbidden.length; i++) {
      (bool ok,) =
        address(aspRegistry).staticcall(abi.encodeWithSelector(bytes4(keccak256(bytes(forbidden[i])))));
      assertFalse(ok, string.concat('the ASP gate answers a governance selector: ', forbidden[i]));
    }
  }
}
