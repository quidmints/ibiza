// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {WithdrawalHonkVerifier} from '../../contracts/pool/verifiers/WithdrawalHonkVerifier.sol';
import {INoirVerifier} from '../../contracts/interfaces/verifiers/INoirVerifier.sol';
import {ProofLib} from '../../contracts/pool/lib/ProofLib.sol';

/*
 * TODO.md §2A Phase 0 - the baseline this project had been missing.
 *
 * Before this, `withdraw_identity`'s verifier was generated and compiled but had NEVER verified a
 * real proof (§2.12 said so explicitly). That made it impossible to attribute a future failure:
 * change the circuit, watch a proof fail, and you cannot tell whether the cause is your change or
 * the never-exercised path underneath it. This test establishes the known-good baseline that
 * §2A Phase 4 will regress against once the circuit gains `revocation_root`.
 *
 * It deliberately routes the public inputs through `ProofLib.publicInputsBytes32` - the SAME
 * conversion `PrivacyPool.withdraw` uses at line 122 - rather than hand-building a bytes32[]. A
 * hand-built array would test the verifier but not the production plumbing that feeds it, and an
 * ordering bug in ProofLib is exactly the kind of thing that survives a verifier-only test.
 *
 * FIXTURE PROVENANCE. Regenerate BOTH fixtures with `tools/build-withdrawal-fixture.js` - see that
 * file's header for the exact tsc / nargo / bb commands. It is deterministic (sk_identity pinned to
 * 1234, fixed mnemonic) and it writes the committed `Prover.baseline.toml` / `Prover.wallet.toml`,
 * so both fixtures are reproducible from the repo.
 *
 * The witness is a genuine satisfying assignment, not a weakened one:
 *   - Note values (10, 20, 30, 40) reuse pp/src/commitment.nr's differential-tested vector, whose
 *     commitment/nullifier_hash were cross-checked against poseidon-solidity. That independence
 *     from the wallet's own derivation is why this fixture is kept alongside the wallet one.
 *   - sk_identity = 1234 reuses pp/src/identity_asp.nr's published vector.
 *   - Withdraws 4 of 10, carrying 6 into a change note under the same label.
 *
 * REGENERATED 2026-07-27 TO REMOVE A DEGENERATE CASE. This fixture previously used size-1 trees:
 * pp::lean_imt carries a node up unchanged when its sibling is 0, so with a single leaf and
 * all-zero siblings the root simply IS the leaf, both depths were 0, and NO SIBLING WAS EVER
 * HASHED. That verified, but never exercised the Merkle path a withdrawal depends on. Both fixtures
 * now use state depth 3 / ASP depth 2 over trees with unrelated filler leaves; the generator
 * refuses to emit a depth-0 witness, and test_FixturesAreNotDegenerate below pins it here too.
 *
 * ON bb 1.2.0 THERE IS NOTHING TO STRIP. `bb prove` writes `target/proof` and `target/public_inputs`
 * as separate files and `target/proof` IS the fixture format. Earlier revisions of this comment
 * described stripping a 4-byte field count and 8 leading public-input fields - that was a 0.82.2-era
 * instruction from when the two were concatenated into one file.
 */
contract WithdrawalHonkVerifierTest is Test {
  using ProofLib for ProofLib.WithdrawProof;

  INoirVerifier internal verifier;

  uint256 internal constant NEW_COMMITMENT =
    18653376712734179938763709399463410120694066225799564842943406163517501924389;
  uint256 internal constant EXISTING_NULLIFIER_HASH =
    7532086780038402662674345296860422071861903663404908958571451852914592667893;
  uint256 internal constant WITHDRAWN_VALUE = 4;
  uint256 internal constant STATE_ROOT =
    4344985332480040079471765000069393836362873940320599351794913073184699413871;
  uint256 internal constant STATE_TREE_DEPTH = 3;
  /// CHANGED WITH THE COMMITMENT DERIVATION (TODO.md sec. 2.18a). The identity tree is keyed on
  /// `Poseidon(revocation_secret)`, and the secret is now DERIVED from `sk_identity` rather than
  /// chosen - so every leaf key moved, and with them the root. The other five signals are unchanged,
  /// which is the check that this was a key-derivation change and not something broader.
  uint256 internal constant IDENTITY_ROOT =
    2910739936757023150025232640645754432456838469272402593742390097823972605304;
  uint256 internal constant CONTEXT = 42424242;
  /// Empty revocation registry: root 0, and an all-zero witness proves absence for every key

  function setUp() public {
    verifier = INoirVerifier(address(new WithdrawalHonkVerifier()));
  }

  function _withdrawProof() internal view returns (ProofLib.WithdrawProof memory _p) {
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_identity.proof');
    _p.pubSignals = [
      NEW_COMMITMENT,
      EXISTING_NULLIFIER_HASH,
      WITHDRAWN_VALUE,
      STATE_ROOT,
      STATE_TREE_DEPTH,
      IDENTITY_ROOT,
      CONTEXT
    ];
  }

  /// @notice The baseline: a genuine proof verifies on-chain through the production plumbing.
  function test_VerifiesRealProof() public view {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    assertTrue(verifier.verify(_p.proof, _p.publicInputsBytes32()));
  }

  /// @notice ProofLib's accessors must agree with the fixture's slot ordering. If an accessor were
  /// mis-indexed, `PrivacyPool.withdraw` would read the wrong field while the proof still verified
  /// - a bug a verifier-only test cannot see.
  function test_ProofLibAccessorsMatchSlotOrder() public pure {
    ProofLib.WithdrawProof memory _p;
    _p.pubSignals = [
      NEW_COMMITMENT,
      EXISTING_NULLIFIER_HASH,
      WITHDRAWN_VALUE,
      STATE_ROOT,
      STATE_TREE_DEPTH,
      IDENTITY_ROOT,
      CONTEXT
    ];
    assertEq(_p.newCommitmentHash(), NEW_COMMITMENT);
    assertEq(_p.existingNullifierHash(), EXISTING_NULLIFIER_HASH);
    assertEq(_p.withdrawnValue(), WITHDRAWN_VALUE);
    assertEq(_p.stateRoot(), STATE_ROOT);
    assertEq(_p.stateTreeDepth(), STATE_TREE_DEPTH);
    assertEq(_p.identityRoot(), IDENTITY_ROOT);
    assertEq(_p.context(), CONTEXT);
  }

  /*
   * THE SECURITY-CRITICAL CASE. `context` is declared `pub` in the circuit but its body never
   * reads it - nargo emits "unused variable context" for exactly this. withdraw_identity's header
   * argues that `pub` binds it as a public input regardless, and PrivacyPool.validWithdrawal
   * depends on that being true: it recomputes context from (withdrawal, SCOPE) and compares, which
   * is what stops a valid proof being replayed against different withdrawal parameters. If the
   * value were NOT bound into the transcript, that check would be trivially bypassable by
   * submitting any context alongside an otherwise-valid proof.
   *
   * §2.12 inferred this from the verification key's publicInputsSize == 8. This proves it.
   */
  function test_RejectsTamperedContext() public {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    _p.pubSignals[6] = CONTEXT + 1;
    _assertRejects(_p);
  }

  function test_RejectsTamperedWithdrawnValue() public {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    _p.pubSignals[2] = WITHDRAWN_VALUE + 1;
    _assertRejects(_p);
  }

  /// @notice An attacker substituting a different ASP root - the exact move §2.13's lever analysis
  /// turns on - must not produce a passing proof.
  function test_RejectsTamperedAspRoot() public {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    _p.pubSignals[5] = IDENTITY_ROOT ^ 1;
    _assertRejects(_p);
  }

  function test_RejectsTamperedNullifierHash() public {
    ProofLib.WithdrawProof memory _p = _withdrawProof();
    _p.pubSignals[1] = EXISTING_NULLIFIER_HASH ^ 1;
    _assertRejects(_p);
  }

  /*
   * ─────────────────────────────────────────────────────────────────────────────────────────────
   * WALLET-PRODUCED WITNESS (TODO.md sec. 2.1, landed 2026-07-27).
   *
   * Everything above proves the VERIFIER works. This proves the WALLET works: the witness below
   * was assembled by frontend/identity-wallet/src/pp/withdrawWitness.ts from a note discovered
   * through the wallet's own derivation, an inclusion path from src/pp/stateTree.ts, and an ASP
   * path from src/postman/identityAsp.ts - not hand-built. It is the first end-to-end evidence
   * that the client can produce a withdrawal the chain accepts.
   *
   * WHAT IT ADDS OVER THE BASELINE is provenance, not tree shape - both fixtures now use state
   * depth 3 / ASP depth 2 (see the file header; the baseline's former size-1 degeneracy was
   * removed in the same change). The baseline's spent note is an independent hand vector, so it
   * still catches a wallet that is self-consistently wrong; this one proves the wallet's real
   * derivation path produces something the chain accepts. Neither subsumes the other.
   *
   * Regenerate with tools/build-withdrawal-fixture.js - it emits both fixtures' Prover.*.toml.
   */
  uint256 internal constant W_NEW_COMMITMENT =
    19761324528885713390391631165680038172128702826549789957405969105810862789935;
  uint256 internal constant W_EXISTING_NULLIFIER_HASH =
    5483191249680064704425129569822560397968224872405526965537704682354244953720;
  uint256 internal constant W_WITHDRAWN_VALUE = 300000000000000000;
  uint256 internal constant W_STATE_ROOT =
    11922358609946525750179191892257841520060631680150773185653959528175536025855;
  uint256 internal constant W_STATE_TREE_DEPTH = 3;
  uint256 internal constant W_IDENTITY_ROOT =
    2910739936757023150025232640645754432456838469272402593742390097823972605304;
  uint256 internal constant W_CONTEXT = 42424242;

  function _walletProof() internal view returns (ProofLib.WithdrawProof memory _p) {
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_identity_wallet.proof');
    _p.pubSignals = [
      W_NEW_COMMITMENT,
      W_EXISTING_NULLIFIER_HASH,
      W_WITHDRAWN_VALUE,
      W_STATE_ROOT,
      W_STATE_TREE_DEPTH,
      W_IDENTITY_ROOT,
      W_CONTEXT
    ];
  }

  /// @notice The end-to-end case: a proof over a WALLET-ASSEMBLED witness verifies on-chain.
  function test_VerifiesWalletAssembledWitness() public view {
    ProofLib.WithdrawProof memory _p = _walletProof();
    assertTrue(verifier.verify(_p.proof, _p.publicInputsBytes32()));
  }

  /// @notice Guards BOTH fixtures against silently regressing to the degenerate size-1 shape this
  /// suite used to have. A depth-0 witness still verifies - the proof is valid - so nothing else
  /// here would fail; the suite would simply stop covering multi-level sibling hashing. That is
  /// the failure mode worth pinning: a green test that has quietly stopped testing anything.
  /// tools/build-withdrawal-fixture.js refuses to emit depth 0; this is the second line.
  ///
  /// COVERAGE MOVED, NOT DROPPED. The ASP tree's depth used to be a PUBLIC signal, so its
  /// degeneracy could be asserted right here. The identity witness is now an SMT inclusion path
  /// carried entirely in PRIVATE inputs (sec. 2.13k), so nothing about it is visible from
  /// `pubSignals` and this test physically cannot see it. That check now lives at the two places
  /// that CAN see it: WithdrawEndToEnd asserts the live registry returns a non-empty sibling path
  /// for the fixture's commitment, and IdentityRegistry.t.sol's emitter asserts the same before
  /// writing the witness at all. Recorded explicitly because a silently narrower degeneracy check
  /// is exactly the "green test that stopped testing anything" this function exists to prevent.
  function test_FixturesAreNotDegenerate() public pure {
    assertGt(STATE_TREE_DEPTH, 0, 'baseline state tree is degenerate - no siblings hashed');
    assertGt(W_STATE_TREE_DEPTH, 0, 'wallet state tree is degenerate - no siblings hashed');
  }

  /// @notice The wallet path must be no weaker than the baseline against public-input tampering.
  function test_RejectsTamperedWalletStateRoot() public {
    ProofLib.WithdrawProof memory _p = _walletProof();
    _p.pubSignals[3] = W_STATE_ROOT ^ 1;
    _assertRejects(_p);
  }

  function test_RejectsTamperedWalletContext() public {
    ProofLib.WithdrawProof memory _p = _walletProof();
    _p.pubSignals[6] = W_CONTEXT + 1;
    _assertRejects(_p);
  }

  /// @notice Cross-fixture guard: the baseline proof must NOT verify against the wallet witness's
  /// public inputs. Both are valid proofs of the same circuit, so nothing but the transcript
  /// binding stops one being presented with the other's signals.
  function test_BaselineProofDoesNotVerifyWalletSignals() public {
    ProofLib.WithdrawProof memory _p = _walletProof();
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_identity.proof');
    _assertRejects(_p);
  }

  /// @dev A rejection is either `false` or a revert (SumcheckFailed etc.) - both are correct.
  function _assertRejects(ProofLib.WithdrawProof memory _p) internal view {
    bytes32[] memory _inputs = _p.publicInputsBytes32();
    try verifier.verify(_p.proof, _inputs) returns (bool _ok) {
      assertFalse(_ok);
    } catch {
      assertTrue(true);
    }
  }
}
