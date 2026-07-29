// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ECDSA256, EC256} from "@solarity/solidity-lib/libs/crypto/ECDSA256.sol";

import {ICertificateSigner} from "../../interfaces/signers/ICertificateSigner.sol";

import {SHA1} from "../../utils/SHA1.sol";

contract CECDSA256Signer is ICertificateSigner, Initializable {
    using ECDSA256 for *;
    using SHA1 for *;

    enum Curve {
        secp256r1,
        brainpoolP256r1
    }

    enum HF {
        sha1,
        sha2
    }

    EC256.Curve private _secp256r1CurveParams =
        EC256.Curve({
            a: 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFC,
            b: 0x5AC635D8AA3A93E7B3EBBD55769886BC651D06B0CC53B0F63BCE3C3E27D2604B,
            gx: 0x6B17D1F2E12C4247F8BCE6E563A440F277037D812DEB33A0F4A13945D898C296,
            gy: 0x4FE342E2FE1A7F9B8EE7EB4A7C0F9E162BCE33576B315ECECBB6406837BF51F5,
            p: 0xFFFFFFFF00000001000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFF,
            n: 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
        });

    EC256.Curve internal _brainpoolP256r1CurveParams =
        EC256.Curve({
            a: 0x7d5a0975fc2c3057eef67530417affe7fb8055c126dc5c6ce94a4b44f330b5d9,
            b: 0x26dc5c6ce94a4b44f330b5d9bbd77cbf958416295cf7e1ce6bccdc18ff8c07b6,
            gx: 0x8bd2aeb9cb7e57cb2c4b482ffc81b7afb9de27e1e3bd23c23a4453bd9ace3262,
            gy: 0x547ef835c3dac4fd97f8461a14611dc9c27745132ded8e545c1d54c72f046997,
            p: 0xa9fb57dba1eea9bc3e660a909d838d726e3bf623d52620282013481d1f6e5377,
            n: 0xa9fb57dba1eea9bc3e660a909d838d718c397aa3b561a6f7901e0e82974856a7
        });

    Curve public curve;
    HF public hashFunction;

    function __CECDSA256Signer_init(Curve curve_, HF hashFunction_) external initializer {
        curve = curve_;
        hashFunction = hashFunction_;
    }

    function verifyICAOSignature(
        bytes memory x509SignedAttributes_,
        bytes memory icaoMemberSignature_,
        bytes memory icaoMemberKey_
    ) external view returns (bool) {
        EC256.Curve memory curveParams_;
        function(bytes memory) internal view returns (bytes32) hasher_;

        if (curve == Curve.secp256r1) {
            curveParams_ = _secp256r1CurveParams;
        } else if (curve == Curve.brainpoolP256r1) {
            curveParams_ = _brainpoolP256r1CurveParams;
        }

        if (hashFunction == HF.sha1) {
            hasher_ = _sha1;
        } else if (hashFunction == HF.sha2) {
            hasher_ = _sha2;
        }

        return
            curveParams_.verify(
                hasher_(x509SignedAttributes_),
                _normalizeS(icaoMemberSignature_, curveParams_.n),
                icaoMemberKey_
            );
    }

    /**
     * @dev Rewrite `s` into the lower half of the curve order, because the library refuses anything
     *      else - "signatures only from the lower part of the curve are accepted" (ECDSA256.sol).
     *
     * THAT POLICY IS CORRECT FOR TRANSACTIONS AND WRONG HERE (TODO.md sec. 2.18v). Low-s is an
     * Ethereum/Bitcoin convention preventing a malleated copy of a signature from being a second
     * valid TRANSACTION. Nothing in certificate admission keys on signature bytes -
     * `registerCertificate` does not record them - so malleability buys an attacker nothing, while
     * enforcing low-s rejects any signature a CA happened to emit with high `s`.
     *
     * AND CAs DO NOT NORMALISE. Measured: openssl produced high-s in 11 of 20 signings of the same
     * message. So without this, **roughly half of all genuine ECDSA CSCA certificates would be
     * refused** - the same arbitrary 50% denial as sec. 2.18s, reached by a different route.
     *
     * REWRITING IS SOUND, NOT A BYPASS. If `(r, s)` verifies then so does `(r, n - s)`: they are the
     * two representations of one signature, and ECDSA verification is symmetric in that reflection.
     * Checking the low-s form therefore proves exactly the same statement about the same key and
     * message. A signature that is invalid stays invalid under either representation, which is what
     * the negative tests pin.
     */
    function _normalizeS(
        bytes memory signature_,
        uint256 n_
    ) private pure returns (bytes memory) {
        if (signature_.length != 64) {
            return signature_; // malformed - let the library reject it rather than guess
        }

        uint256 r_;
        uint256 s_;

        assembly {
            r_ := mload(add(signature_, 32))
            s_ := mload(add(signature_, 64))
        }

        // `s_ < n_` is not redundant: a signature made under a DIFFERENT curve can carry an `s`
        // larger than this curve's order, and `n_ - s_` would underflow. Such a signature is
        // invalid here anyway, so it passes through untouched for the library to reject - which is
        // exactly what `test_RejectsUnderTheWrongCurve` caught when this guard was missing.
        if (s_ > n_ / 2 && s_ < n_) {
            s_ = n_ - s_;
        }

        return abi.encodePacked(bytes32(r_), bytes32(s_));
    }

    function _sha1(bytes memory message) internal pure returns (bytes32) {
        return bytes32(message.sha1()) >> 96;
    }

    function _sha2(bytes memory message) internal pure returns (bytes32) {
        return sha256(message);
    }
}
