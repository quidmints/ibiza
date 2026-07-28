// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {RegistrationSimple} from "../registration/RegistrationSimple.sol";
import {HolderStateKeeper} from "./HolderStateKeeper.sol";

/**
 * @title HolderRegistration
 * @notice Registration entry for the holder-rooted tree (SCOPE.md §7.8). Forks
 *         {RegistrationSimple}: reuses its signer set, signed-data format, and Noir proof
 *         verification, but writes to {HolderStateKeeper}'s document model instead of the
 *         upstream 1:1 `addBond`.
 *
 * THE LINK PROOF (renewal continuity) is implicit and cryptographic: both the original and
 * the renewed document carry a Noir proof binding their DG1 to the SAME `holderRoot_`
 * (the identity key lives inside the DG1 commitment — see RegistrationSimple._buildSignedData).
 * So a renewal can only attach a document the holder can actually prove control of, and the
 * holder root is preserved across the swap → scoped pseudonyms / nullifiers / card-state
 * carry over with no re-onboarding.
 *
 * CIRCUIT NOTE: presentation-side (prove "a CURRENT document under MY holder root satisfies a
 * predicate, and is non-revoked/non-superseded") is the forked `query_identity` Noir circuit,
 * not in this repo (§7.5/§7.8).
 */
contract HolderRegistration is RegistrationSimple {
    event DocumentRegistered(bytes32 indexed holderRoot, bytes32 documentKey, bytes32 docType);
    event DocumentRenewedVia(bytes32 indexed holderRoot, bytes32 oldDocumentKey, bytes32 newDocumentKey);

    /**
     * @notice Register a NEW document under `holderRoot_` (= identity key). Unlike the
     *         upstream path, this does NOT require the holder to be unused — many documents
     *         may share one holder root.
     */
    function registerDocumentViaNoir(
        uint256 holderRoot_,
        Passport memory passport_,
        bytes32 docType_,
        uint64 notAfter_,
        bytes memory signature_,
        bytes memory zkPoints_
    ) external virtual {
        require(holderRoot_ > 0, "HolderRegistration: holder can not be zero");

        _authenticateDocument(holderRoot_, passport_, signature_, zkPoints_);

        _holderStateKeeper().addDocument(
            passport_.publicKey,
            _replayKey(passport_),
            bytes32(holderRoot_),
            docType_,
            passport_.dgCommit,
            notAfter_
        );

        emit DocumentRegistered(bytes32(holderRoot_), passport_.publicKey, docType_);
    }

    /**
     * @notice Renew: supersede `oldDocumentKey_` and bind `newPassport_` under the SAME
     *         `holderRoot_`. The new document's Noir proof binding to `holderRoot_` IS the
     *         link proof that both documents belong to one holder.
     */
    function renewDocumentViaNoir(
        bytes32 oldDocumentKey_,
        uint256 holderRoot_,
        Passport memory newPassport_,
        bytes32 newDocType_,
        uint64 newNotAfter_,
        bytes memory signature_,
        bytes memory zkPoints_
    ) external virtual {
        require(holderRoot_ > 0, "HolderRegistration: holder can not be zero");

        _authenticateDocument(holderRoot_, newPassport_, signature_, zkPoints_);

        _holderStateKeeper().renewDocument(
            oldDocumentKey_,
            newPassport_.publicKey,
            _replayKey(newPassport_),
            bytes32(holderRoot_),
            newDocType_,
            newPassport_.dgCommit,
            newNotAfter_
        );

        emit DocumentRenewedVia(bytes32(holderRoot_), oldDocumentKey_, newPassport_.publicKey);
    }

    /**
     * @notice Revoke a document the holder controls. Gated by a valid backend signer signature
     *         over the document (same trust assumption as registration).
     *
     * @dev Signs a REVOKE-specific message (`_buildRevokeSignedData`), deliberately NOT
     *      `_buildSignedData` (registration's message format). Reusing registration's exact
     *      message here would mean asking the backend signer to sign the SAME digest twice for
     *      the same document (once to register, once to revoke) — with a deterministic signer
     *      (RFC 6979, the common case), that produces byte-identical signature bytes, which
     *      `stateKeeper.useSignature`'s anti-replay check would then reject as already-used
     *      (consumed at registration time), making revocation of any normally-registered
     *      document permanently impossible. Domain-separating the message avoids depending on
     *      signer randomness for correctness.
     */
    function revokeDocumentViaSigner(
        Passport memory passport_,
        bytes memory signature_
    ) external virtual {
        address signer_ = ECDSA.recover(
            MessageHashUtils.toEthSignedMessageHash(_buildRevokeSignedData(passport_)),
            signature_
        );
        require(_isSigner(signer_), "HolderRegistration: caller is not a signer");

        stateKeeper.useSignature(keccak256(signature_));

        _holderStateKeeper().revokeDocument(passport_.publicKey);
    }

    /**
     * @dev Revocation's signed-data format — same fields as `_buildSignedData`, distinguished by
     *      a different prefix, so a registration signature and a revocation signature for the
     *      SAME document are never the same message (see `revokeDocumentViaSigner`'s doc comment).
     */
    function _buildRevokeSignedData(Passport memory passport_) internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    "HolderRegistration revoke prefix",
                    address(this),
                    passport_.passportHash,
                    passport_.dgCommit,
                    passport_.publicKey,
                    passport_.verifier
                )
            );
    }

    /**
     * @dev Shared auth: verify the backend signer signature AND the Noir proof binding the
     *      document's DG1 to `holderRoot_`. Consumes the signature (anti-replay).
     */
    function _authenticateDocument(
        uint256 holderRoot_,
        Passport memory passport_,
        bytes memory signature_,
        bytes memory zkPoints_
    ) internal {
        address signer_ = ECDSA.recover(
            MessageHashUtils.toEthSignedMessageHash(_buildSignedData(passport_)),
            signature_
        );
        require(_isSigner(signer_), "HolderRegistration: caller is not a signer");

        stateKeeper.useSignature(keccak256(signature_));

        _verifyNoirZKProof(
            passport_.verifier,
            passport_.dg1Hash,
            bytes32(passport_.dgCommit),
            bytes32(holderRoot_),
            zkPoints_
        );
    }

    /**
     * @dev The anti-replay key for a document binding: `dg1Hash`, NOT `passportHash`.
     *
     * WHY THIS MATTERS, AND WHAT WAS WRONG. `HolderStateKeeper` already refuses to bind the same
     * document twice (`_usedDocumentHash`), but it was being fed `passport_.passportHash` — a
     * caller-supplied struct field that the Noir proof DOES NOT CONSTRAIN. `_verifyNoirZKProof`
     * binds exactly three public signals: `dgCommit`, `dg1Hash` and `holderRoot`. `passportHash`
     * and `publicKey` are attested only by the backend signer's signature.
     *
     * So the uniqueness guard keyed on values the proof never checks, while a proof-bound value
     * sat unused. Anyone able to obtain a signature could present a FRESH `publicKey` and
     * `passportHash` for the SAME physical passport and bind it to a SECOND `holderRoot` — the
     * proof still verifies, because nothing links those fields to the document. That defeats any
     * identity-level blacklist by construction: get listed, re-register, withdraw as someone new.
     *
     * `dg1Hash` is computed IN-CIRCUIT as `passport_hash(dg1)` over the MRZ (see
     * noir_dl_lib/src/lite.nr::register_identity_light), so it is deterministic for a given
     * passport and unforgeable. Two different documents cannot collide on it — the MRZ carries the
     * document number — so renewal is unaffected: a renewed passport has a new MRZ, hence a new
     * key, and legitimately binds under the same holder root.
     *
     * ZERO IS REJECTED HERE rather than in `addDocument`, which treats a zero hash as "no
     * anti-replay wanted" and skips the check. That permissiveness is fine for the state keeper as
     * a general primitive, but on THIS path the guard is load-bearing, and silently skipping it is
     * exactly the shape of hole this function exists to close.
     */
    function _replayKey(Passport memory passport_) internal pure returns (bytes32) {
        require(passport_.dg1Hash != bytes32(0), "HolderRegistration: zero dg1 hash");
        return passport_.dg1Hash;
    }

    function _holderStateKeeper() internal view returns (HolderStateKeeper) {
        return HolderStateKeeper(address(stateKeeper));
    }

    function _isSigner(address account_) internal view returns (bool) {
        // `getSigners()` is external in RegistrationSimple and `_signers` is private, so reuse
        // it via an external view staticcall.
        address[] memory signers_ = this.getSigners();
        for (uint256 i = 0; i < signers_.length; ++i) {
            if (signers_[i] == account_) {
                return true;
            }
        }
        return false;
    }
}
