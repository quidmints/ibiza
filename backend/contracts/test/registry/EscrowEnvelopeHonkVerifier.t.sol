// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.28;

import {Test} from 'forge-std/Test.sol';
import {EscrowEnvelopeHonkVerifier} from '../../contracts/registry/verifiers/EscrowEnvelopeHonkVerifier.sol';
import {INoirVerifier} from '../../contracts/interfaces/verifiers/INoirVerifier.sol';

/*
 * TODO.md sec. 2.13d - on-chain verification of a REAL escrow_envelope proof.
 *
 * WHY THIS EXISTS AT ALL, given no registry contract consumes this verifier yet. A generated
 * verifier that has never accepted a real proof is a liability, not an asset: when the registry
 * lands and a proof fails, there is no way to tell whether the cause is the new contract or the
 * never-exercised verifier underneath it. WithdrawalHonkVerifier spent a whole phase in exactly
 * that state (sec. 2.12), and this test exists so escrow_envelope never does.
 *
 * FIXTURE PROVENANCE. `test/fixtures/escrow_envelope.proof` is emitted by
 * backend/circuits/codegen-verifiers.sh from the committed
 * backend/circuits/escrow_envelope/Prover.toml. Every public input below was produced by
 * @iden3/js-crypto - the SAME babyJub and Poseidon the wallet uses - and then accepted by the Noir
 * circuit, so this fixture is a genuine cross-implementation agreement between the JS that will
 * build envelopes in the wallet and the circuit that constrains them, not a self-consistent loop.
 *
 * THE WITNESS IS NOT DEGENERATE:
 *   - `ephemeral` is 55555, not 0. Zero is the case where the shared secret collapses to this
 *     ladder's (0,0) sentinel for EVERY controller key, making the mask a public constant and the
 *     sealed secret readable by anyone - see pp/src/envelope.nr and its
 *     test_zero_ephemeral_would_have_leaked_the_payload.
 *   - `sk_identity` reuses pp/src/identity_asp.nr's published vector, so `holder_root` here is the
 *     same identity commitment the ASP membership tests use.
 *   - The controller key is babyJub.Base8 * 1234, whose coordinates are pinned in
 *     pp/src/envelope.nr::test_controller_key_matches_babyjub.
 *
 * EIP-170: this verifier is 24,490 bytes with `optimizer_runs = 1` scoped to it in foundry.toml,
 * leaving 86 bytes of headroom. WITHOUT that scoping it compiles to 25,503 bytes and is
 * undeployable. It has 8 public inputs - more than any other circuit here - and each one costs
 * runtime code, so anything that adds a public input needs `forge build --sizes` checked again.
 */
contract EscrowEnvelopeHonkVerifierTest is Test {
  INoirVerifier internal verifier;

  /// babyJub.mulPointEScalar(babyJub.Base8, 1234) - the controller's published sealing key.
  uint256 internal constant CONTROLLER_X =
    4_880_901_335_776_166_390_443_888_589_907_570_248_644_423_541_468_541_082_967_598_048_550_539_024_543;
  uint256 internal constant CONTROLLER_Y =
    6_509_666_988_291_764_283_313_685_078_036_329_297_907_336_602_650_572_952_945_826_675_203_643_401_307;
  /// Poseidon(pubkey(sk_identity)) for identity_asp.nr's published sk_identity.
  uint256 internal constant HOLDER_ROOT =
    1_865_212_777_183_579_978_282_563_455_860_747_611_651_741_716_602_891_477_985_491_951_937_263_287_453;
  /// Poseidon(revocation_secret) - what the registered-identity leaf stores, and the key the
  /// controller would list this identity under.
  uint256 internal constant COMMITMENT =
    8_358_125_608_916_792_199_567_624_990_380_031_336_399_968_764_944_869_913_697_508_384_993_845_680_707;
  uint256 internal constant C1_X =
    17_256_304_381_782_086_244_104_795_765_452_609_196_414_860_732_904_408_511_437_489_658_761_108_445_241;
  uint256 internal constant C1_Y =
    1_895_287_904_113_580_891_932_863_718_220_612_746_733_011_354_009_233_103_840_636_298_777_381_758_670;
  uint256 internal constant SEALED_SECRET =
    9_601_630_596_704_293_070_318_244_764_398_083_567_056_379_859_480_077_534_762_099_206_028_018_790_121;
  uint256 internal constant SEALED_DOCUMENT =
    6_693_972_765_792_004_013_245_759_092_561_206_201_716_999_645_836_635_423_539_028_926_499_612_393_634;

  function setUp() public {
    verifier = INoirVerifier(address(new EscrowEnvelopeHonkVerifier()));
  }

  function _publicInputs() internal pure returns (bytes32[] memory _inputs) {
    _inputs = new bytes32[](8);
    _inputs[0] = bytes32(CONTROLLER_X);
    _inputs[1] = bytes32(CONTROLLER_Y);
    _inputs[2] = bytes32(HOLDER_ROOT);
    _inputs[3] = bytes32(COMMITMENT);
    _inputs[4] = bytes32(C1_X);
    _inputs[5] = bytes32(C1_Y);
    _inputs[6] = bytes32(SEALED_SECRET);
    _inputs[7] = bytes32(SEALED_DOCUMENT);
  }

  /// The baseline: a genuine escrow proof verifies on-chain.
  function test_VerifiesRealProof() public view {
    bytes memory _proof = vm.readFileBinary('test/fixtures/escrow_envelope.proof');
    assertTrue(verifier.verify(_proof, _publicInputs()));
  }

  /// Every public input must be load-bearing. If any slot could be altered while the proof still
  /// verified, the registry could be handed a commitment or a ciphertext that the proof does not
  /// actually cover - which is the whole guarantee escrow depends on.
  function test_EveryPublicInputIsBinding() public view {
    bytes memory _proof = vm.readFileBinary('test/fixtures/escrow_envelope.proof');

    for (uint256 _i = 0; _i < 8; _i++) {
      bytes32[] memory _tampered = _publicInputs();
      _tampered[_i] = bytes32(uint256(_tampered[_i]) + 1);

      // A tampered input makes this verifier REVERT (SumcheckFailed) rather than return false, so
      // both outcomes have to be treated as rejection. Asserting only `== false` fails against a
      // verifier that is behaving correctly - which is what the first run of this test did.
      (bool _ok, bytes memory _ret) =
        address(verifier).staticcall(abi.encodeCall(INoirVerifier.verify, (_proof, _tampered)));
      bool _accepted = _ok && _ret.length == 32 && abi.decode(_ret, (bool));
      assertFalse(_accepted, 'a public input was not binding');
    }
  }

  /// A truncated proof must be rejected rather than reverting in a way a caller might swallow.
  function test_RejectsMalformedProof() public {
    bytes memory _proof = vm.readFileBinary('test/fixtures/escrow_envelope.proof');
    bytes memory _short = new bytes(_proof.length - 32);
    for (uint256 _i = 0; _i < _short.length; _i++) {
      _short[_i] = _proof[_i];
    }

    // The generated verifier reverts on a malformed proof rather than returning false, so this
    // asserts the call fails - NOT that it returns false, which would silently pass if the
    // verifier were replaced by one that swallows the error.
    (bool _ok,) =
      address(verifier).staticcall(abi.encodeCall(INoirVerifier.verify, (_short, _publicInputs())));
    assertFalse(_ok, 'a truncated proof was accepted');
  }

  /// The commitment slot specifically: this is the value that binds an escrow to the secret a
  /// withdrawal will later re-derive. Pinned separately because a mix-up between it and the sealed
  /// ciphertext would leave escrow superficially working while binding nothing.
  function test_CommitmentSlotIsNotTheSealedSecret() public pure {
    assertTrue(COMMITMENT != SEALED_SECRET, 'commitment and sealed secret must be distinct values');
  }
}
