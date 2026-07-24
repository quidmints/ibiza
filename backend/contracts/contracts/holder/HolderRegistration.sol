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
            passport_.passportHash,
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
            newPassport_.passportHash,
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
     */
    function revokeDocumentViaSigner(
        Passport memory passport_,
        bytes memory signature_
    ) external virtual {
        address signer_ = ECDSA.recover(
            MessageHashUtils.toEthSignedMessageHash(_buildSignedData(passport_)),
            signature_
        );
        require(_isSigner(signer_), "HolderRegistration: caller is not a signer");

        stateKeeper.useSignature(keccak256(signature_));

        _holderStateKeeper().revokeDocument(passport_.publicKey);
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
