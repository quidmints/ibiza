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
    0x293d6fe456f214495aad57522b06eae244a7e962d91ee5303b631e9a1508e425;
  uint256 internal constant EXISTING_NULLIFIER_HASH =
    0x10a702921ecbe33f9b33b1a2edd252556d5a1abc623a87fcf1daee3953d158f5;
  uint256 internal constant WITHDRAWN_VALUE = 4;
  uint256 internal constant STATE_ROOT =
    0x099b2caf32e59a2e0cf64fe6376beb17c2aaf359c6b8178b671c32bd6c79756f;
  uint256 internal constant STATE_TREE_DEPTH = 3;
  uint256 internal constant ASP_ROOT =
    0x035d7de0fa38af5be238bc9a7bd85f8fbe06d2b0e70c785d42bac3d79e846ab4;
  uint256 internal constant ASP_TREE_DEPTH = 2;
  uint256 internal constant CONTEXT = 42_424_242;

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
      ASP_ROOT,
      ASP_TREE_DEPTH,
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
      ASP_ROOT,
      ASP_TREE_DEPTH,
      CONTEXT
    ];
    assertEq(_p.newCommitmentHash(), NEW_COMMITMENT);
    assertEq(_p.existingNullifierHash(), EXISTING_NULLIFIER_HASH);
    assertEq(_p.withdrawnValue(), WITHDRAWN_VALUE);
    assertEq(_p.stateRoot(), STATE_ROOT);
    assertEq(_p.stateTreeDepth(), STATE_TREE_DEPTH);
    assertEq(_p.ASPRoot(), ASP_ROOT);
    assertEq(_p.ASPTreeDepth(), ASP_TREE_DEPTH);
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
    _p.pubSignals[7] = CONTEXT + 1;
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
    _p.pubSignals[5] = ASP_ROOT ^ 1;
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
    0x2bb08368e1faa84baa5d5f99c6a4835bc75d03dbdbfdc9314e95ffc00092552f;
  uint256 internal constant W_EXISTING_NULLIFIER_HASH =
    0x0c1f6053164b5cde7f8508564ba00f9e27b25158be14d2e6c82aeade4425a678;
  uint256 internal constant W_WITHDRAWN_VALUE = 0.3 ether;
  uint256 internal constant W_STATE_ROOT =
    0x1a5bd0daddfd676a0f834c646038b32226d66a2ecc9487f6d68272e1a781b0ff;
  uint256 internal constant W_STATE_TREE_DEPTH = 3;
  uint256 internal constant W_ASP_ROOT =
    0x035d7de0fa38af5be238bc9a7bd85f8fbe06d2b0e70c785d42bac3d79e846ab4;
  uint256 internal constant W_ASP_TREE_DEPTH = 2;
  uint256 internal constant W_CONTEXT = 42_424_242;

  function _walletProof() internal view returns (ProofLib.WithdrawProof memory _p) {
    _p.proof = vm.readFileBinary('test/fixtures/withdraw_identity_wallet.proof');
    _p.pubSignals = [
      W_NEW_COMMITMENT,
      W_EXISTING_NULLIFIER_HASH,
      W_WITHDRAWN_VALUE,
      W_STATE_ROOT,
      W_STATE_TREE_DEPTH,
      W_ASP_ROOT,
      W_ASP_TREE_DEPTH,
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
  function test_FixturesAreNotDegenerate() public pure {
    assertGt(STATE_TREE_DEPTH, 0, 'baseline state tree is degenerate - no siblings hashed');
    assertGt(ASP_TREE_DEPTH, 0, 'baseline ASP tree is degenerate - no siblings hashed');
    assertGt(W_STATE_TREE_DEPTH, 0, 'wallet state tree is degenerate - no siblings hashed');
    assertGt(W_ASP_TREE_DEPTH, 0, 'wallet ASP tree is degenerate - no siblings hashed');
  }

  /// @notice The wallet path must be no weaker than the baseline against public-input tampering.
  function test_RejectsTamperedWalletStateRoot() public {
    ProofLib.WithdrawProof memory _p = _walletProof();
    _p.pubSignals[3] = W_STATE_ROOT ^ 1;
    _assertRejects(_p);
  }

  function test_RejectsTamperedWalletContext() public {
    ProofLib.WithdrawProof memory _p = _walletProof();
    _p.pubSignals[7] = W_CONTEXT + 1;
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
