// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {EscrowEnvelopeHonkVerifier} from '../../contracts/registry/verifiers/EscrowEnvelopeHonkVerifier.sol';
import {INoirVerifier} from '../../contracts/interfaces/verifiers/INoirVerifier.sol';

/*
 * TODO.md sec. 2.13d/2.13f - on-chain verification of a REAL escrow_envelope proof.
 *
 * WHY THIS EXISTS given no registry contract consumes this verifier yet. A generated verifier that
 * has never accepted a real proof is a liability, not an asset: when the registry lands and a proof
 * fails, there is no way to tell whether the cause is the new contract or the never-exercised
 * verifier underneath it. WithdrawalHonkVerifier spent a whole phase in exactly that state
 * (sec. 2.12), and this test exists so escrow_envelope never does.
 *
 * BOTH FIXTURES ARE READ FROM DISK, and the named constants are CHECKED AGAINST the public-inputs
 * fixture rather than being the source of truth. Hand-transcribing twelve 77-digit field elements is
 * the obvious place for this test to rot: a typo would make it fail for a reason having nothing to
 * do with the verifier. Reading `escrow_envelope.public` and asserting the constants match it keeps
 * the documentation value of names while making drift impossible.
 *
 * FIXTURE PROVENANCE. Both files are emitted by backend/circuits/codegen-verifiers.sh from the
 * committed backend/circuits/escrow_envelope/Prover.toml. Every value in that witness was produced
 * by @iden3/js-crypto and Node's sha256 - the same primitives the wallet uses - and then accepted by
 * the Noir circuit, so this is a genuine cross-implementation agreement rather than a
 * self-consistent loop. That matters most for `dg1_hash`, which must match registration's own
 * digest-packing convention exactly (skip digest[0], read the remaining 31 bytes big-endian); any
 * other packing yields a different field and would bind the sealed MRZ to a value nothing else
 * agrees with.
 *
 * THE WITNESS IS NOT DEGENERATE:
 *   - `ephemeral` is 55555, not 0. Zero collapses the shared secret to this ladder's (0,0) sentinel
 *     for EVERY controller key, making the mask a public constant and the sealed payload readable
 *     by anyone - see pp/src/envelope.nr::test_zero_ephemeral_would_have_leaked_the_payload.
 *   - `sk_identity` reuses pp/src/identity_asp.nr's published vector.
 *   - The DG1 is a full 95-byte TD3 layout carrying a real MRZ, not zeros.
 *
 * EIP-170: 24,491 bytes with `optimizer_runs = 1` scoped to it in foundry.toml, leaving 85 bytes.
 * WITHOUT that scoping it compiled to 25,503 and was undeployable. Note the cause was the OPTIMIZER
 * SETTING, not the public-input count: this circuit has 12 public inputs and measures 24,491, while
 * TitleHolder has 2 and measures the same 24,491. Verifier size here is essentially flat in input
 * count, so `forge build --sizes` still needs checking after changes, but adding a public input is
 * not the thing to fear.
 */
contract EscrowEnvelopeHonkVerifierTest is Test {
  INoirVerifier internal verifier;

  uint256 internal constant PUBLIC_INPUT_COUNT = 12;

  /// babyJub.mulPointEScalar(babyJub.Base8, 1234) - the controller's published sealing key. Pinned
  /// in pp/src/envelope.nr::test_controller_key_matches_babyjub.
  uint256 internal constant CONTROLLER_X =
    4_880_901_335_776_166_390_443_888_589_907_570_248_644_423_541_468_541_082_967_598_048_550_539_024_543;
  /// Poseidon(pubkey(sk_identity)) for identity_asp.nr's published sk_identity.
  uint256 internal constant HOLDER_ROOT =
    1_865_212_777_183_579_978_282_563_455_860_747_611_651_741_716_602_891_477_985_491_951_937_263_287_453;
  /// Poseidon(revocation_secret) - what the registered-identity leaf stores, and the key the
  /// controller would list this identity under.
  uint256 internal constant COMMITMENT =
    8_358_125_608_916_792_199_567_624_990_380_031_336_399_968_764_944_869_913_697_508_384_993_845_680_707;
  /// The registration-bound MRZ digest the sealed DG1 must reproduce.
  uint256 internal constant DG1_HASH =
    25_221_877_208_166_930_351_050_665_436_133_530_901_095_817_342_996_592_571_437_213_589_958_279_235;

  function setUp() public {
    verifier = INoirVerifier(address(new EscrowEnvelopeHonkVerifier()));
  }

  function _proof() internal view returns (bytes memory) {
    return vm.readFileBinary('test/fixtures/escrow_envelope.proof');
  }

  function _publicInputs() internal view returns (bytes32[] memory _inputs) {
    bytes memory _raw = vm.readFileBinary('test/fixtures/escrow_envelope.public');
    require(_raw.length == PUBLIC_INPUT_COUNT * 32, 'public-inputs fixture has the wrong length');

    _inputs = new bytes32[](PUBLIC_INPUT_COUNT);
    for (uint256 _i = 0; _i < PUBLIC_INPUT_COUNT; _i++) {
      bytes32 _word;
      assembly {
        _word := mload(add(_raw, add(32, mul(_i, 32))))
      }
      _inputs[_i] = _word;
    }
  }

  /// The baseline: a genuine escrow proof verifies on-chain.
  function test_VerifiesRealProof() public view {
    assertTrue(verifier.verify(_proof(), _publicInputs()));
  }

  /// The fixture must be the witness this test claims it is. Without this, the proof and the
  /// public inputs could both be regenerated from a DIFFERENT witness and everything would still
  /// pass while testing something else entirely.
  function test_FixtureIsTheDocumentedWitness() public view {
    bytes32[] memory _inputs = _publicInputs();
    assertEq(uint256(_inputs[0]), CONTROLLER_X, 'slot 0 is not the controller key');
    assertEq(uint256(_inputs[2]), HOLDER_ROOT, 'slot 2 is not the published holder_root vector');
    assertEq(uint256(_inputs[3]), COMMITMENT, 'slot 3 is not Poseidon(revocation_secret)');
    assertEq(uint256(_inputs[4]), DG1_HASH, 'slot 4 is not the registration-bound MRZ digest');
  }

  /// Every public input must be load-bearing. If any slot could be altered while the proof still
  /// verified, the registry could be handed a commitment or a ciphertext the proof does not cover -
  /// which is the entire guarantee escrow provides.
  function test_EveryPublicInputIsBinding() public view {
    bytes memory _p = _proof();

    for (uint256 _i = 0; _i < PUBLIC_INPUT_COUNT; _i++) {
      bytes32[] memory _tampered = _publicInputs();
      _tampered[_i] = bytes32(uint256(_tampered[_i]) + 1);

      // A tampered input makes this verifier REVERT (SumcheckFailed) rather than return false, so
      // both outcomes count as rejection. Asserting only `== false` fails against a verifier that
      // is behaving correctly - which is what the first run of this test did.
      (bool _ok, bytes memory _ret) =
        address(verifier).staticcall(abi.encodeCall(INoirVerifier.verify, (_p, _tampered)));
      bool _accepted = _ok && _ret.length == 32 && abi.decode(_ret, (bool));
      assertFalse(_accepted, 'a public input was not binding');
    }
  }

  /// The sealed MRZ words must actually differ from one another. Identical ciphertext across slots
  /// would mean the per-index mask is not being applied, so payload fields could be permuted
  /// undetectably - the property pp/src/envelope.nr's `mask` index exists to provide, asserted here
  /// against the REAL proof rather than only in-circuit.
  function test_SealedSlotsAreDistinct() public view {
    bytes32[] memory _inputs = _publicInputs();
    for (uint256 _i = 7; _i < PUBLIC_INPUT_COUNT; _i++) {
      for (uint256 _j = _i + 1; _j < PUBLIC_INPUT_COUNT; _j++) {
        assertTrue(_inputs[_i] != _inputs[_j], 'two sealed slots are identical');
      }
    }
  }

  /// A truncated proof must be rejected.
  function test_RejectsMalformedProof() public view {
    bytes memory _p = _proof();
    bytes memory _short = new bytes(_p.length - 32);
    for (uint256 _i = 0; _i < _short.length; _i++) {
      _short[_i] = _p[_i];
    }

    (bool _ok,) =
      address(verifier).staticcall(abi.encodeCall(INoirVerifier.verify, (_short, _publicInputs())));
    assertFalse(_ok, 'a truncated proof was accepted');
  }
}
