// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from 'forge-std/Test.sol';
import {CECDSA256Signer} from '../../contracts/certificate/signers/CECDSA256Signer.sol';
import {PNOAADispatcher} from '../../contracts/passport/dispatchers/PNOAADispatcher.sol';

/*
 * CECDSA256Signer verifies ICAO MEMBER SIGNATURES - the signatures of the country-signing
 * authorities that anchor passport trust. It had no tests. If it accepted a bad signature, forged
 * certificates would register as genuine; if it rejected good ones, no passport from that curve
 * would ever verify. Neither shows up anywhere else.
 *
 * The vector is a real secp256r1/SHA-256 ECDSA signature generated independently in Python (Jacobian
 * -free affine arithmetic over the NIST P-256 parameters, verified by the standard u1*G + u2*Q
 * check before being pasted here), NOT re-derived from this contract.
 */
contract CECDSA256SignerTest is Test {
  CECDSA256Signer internal signer;

  bytes internal constant MSG = hex'4943414f20746573742061747472696275746573'; // "ICAO test attributes"
  bytes internal constant PUBKEY =
    hex'14b8a2c95626f164e38703bd976b200e0650503e4b701ecbf29f96abf786d31f'
    hex'9b978f67b1ea482736e63b98c445745a521135bf468d6d0c168ef66a4163f46f';
  bytes internal constant SIG =
    hex'8dd0cb91f783328c76cbdbdc3106e4435e34cd7635a747f135f4457e8ecf1a6c'
    hex'25259c428c8632e13537f2def9f71ba30a72a6f02d0d23d7bc97aa0bec03d362';

  function setUp() public {
    signer = new CECDSA256Signer();
    signer.__CECDSA256Signer_init(CECDSA256Signer.Curve.secp256r1, CECDSA256Signer.HF.sha2);
  }

  function test_acceptsAValidSecp256r1Signature() public view {
    assertTrue(signer.verifyICAOSignature(MSG, SIG, PUBKEY), 'a valid ICAO signature was rejected');
  }

  /// @notice A tampered signature must fail. Without this the signer would be a rubber stamp and
  /// any forged certificate would anchor a fake passport.
  function test_rejectsATamperedSignature() public view {
    bytes memory bad = SIG;
    bad[0] = bytes1(uint8(bad[0]) ^ 0x01);
    assertFalse(signer.verifyICAOSignature(MSG, bad, PUBKEY), 'a tampered signature was accepted');
  }

  /// @notice A signature valid for OTHER attributes must not verify against these - otherwise one
  /// genuine ICAO signature would authenticate any content.
  function test_rejectsAValidSignatureOverDifferentAttributes() public view {
    assertFalse(
      signer.verifyICAOSignature(hex'deadbeef', SIG, PUBKEY),
      'a signature was accepted over the wrong attributes'
    );
  }

  function test_rejectsAWrongPublicKey() public view {
    bytes memory bad = PUBKEY;
    bad[0] = bytes1(uint8(bad[0]) ^ 0x01);
    assertFalse(signer.verifyICAOSignature(MSG, SIG, bad), 'a wrong public key was accepted');
  }

  /// @notice Selecting the WRONG CURVE must reject a signature that is valid on the right one.
  /// The two share a signature format, so a misconfigured deployment fails silently otherwise.
  function test_wrongCurveRejectsAnOtherwiseValidSignature() public {
    CECDSA256Signer brainpool = new CECDSA256Signer();
    brainpool.__CECDSA256Signer_init(
      CECDSA256Signer.Curve.brainpoolP256r1, CECDSA256Signer.HF.sha2
    );
    assertFalse(
      brainpool.verifyICAOSignature(MSG, SIG, PUBKEY),
      'a secp256r1 signature verified against brainpoolP256r1'
    );
  }

  /// @notice Likewise the wrong hash function - same curve, different digest, must not verify.
  function test_wrongHashFunctionRejects() public {
    CECDSA256Signer sha1Signer = new CECDSA256Signer();
    sha1Signer.__CECDSA256Signer_init(CECDSA256Signer.Curve.secp256r1, CECDSA256Signer.HF.sha1);
    assertFalse(
      sha1Signer.verifyICAOSignature(MSG, SIG, PUBKEY),
      'a SHA-256 signature verified under SHA-1'
    );
  }
}

/*
 * PNOAADispatcher is the "no active authentication" path: passports without AA present NO
 * signature. Its whole security contribution is one length check, and inverting it would accept any
 * bytes as authentication for every non-AA passport.
 */
contract PNOAADispatcherTest is Test {
  PNOAADispatcher internal dispatcher;

  function setUp() public {
    dispatcher = new PNOAADispatcher();
    dispatcher.__PNOAADispatcher_init();
  }

  function test_acceptsOnlyAnEmptySignature() public view {
    assertTrue(dispatcher.authenticate('', '', ''), 'an empty signature was rejected');
  }

  function test_rejectsAnyNonEmptySignature() public view {
    assertFalse(dispatcher.authenticate('', hex'00', ''), 'a 1-byte signature was accepted');
    assertFalse(dispatcher.authenticate('', hex'deadbeef', ''), 'a garbage signature was accepted');
  }

  /// @notice Non-AA passports omit the challenge entirely.
  function test_challengeIsEmpty() public view {
    assertEq(dispatcher.getPassportChallenge(12_345).length, 0);
  }

  function test_passportKeyIsTheHashReinterpreted() public view {
    bytes32 h = keccak256('passport');
    assertEq(dispatcher.getPassportKey(abi.encodePacked(h)), uint256(h));
  }
}
