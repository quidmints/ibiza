// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {RegistrationSimple} from "../registration/RegistrationSimple.sol";
import {HolderStateKeeper} from "./HolderStateKeeper.sol";
import {INoirVerifier} from "../interfaces/verifiers/INoirVerifier.sol";
import {PoseidonSMT} from "../state/PoseidonSMT.sol";

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
    /// NOT `indexed` on `holderRoot` - see HolderStateKeeper's DocumentAdded (sec. 2.18bc).
    event DocumentRegistered(bytes32 holderRoot, bytes32 documentKey, bytes32 docType);
    event DocumentRenewedVia(bytes32 holderRoot, bytes32 oldDocumentKey, bytes32 newDocumentKey);

    /*
     * ── THE PERMISSIONLESS PATH (sec. 2.18g/2.18l/2.18n) ────────────────────────────────
     *
     * Every OTHER entry point on this contract requires a backend signer's signature, so enrolment
     * can be withheld from one person by whoever holds that key. `registerDocumentViaIcao` takes no
     * signature: it consumes a `register_identity` proof, which verifies the whole ICAO chain
     * in-circuit, and the only thing the caller must satisfy is arithmetic.
     */

    /// Public-input layout of `register_identity`, pinned by its `main` signature. A mismatch here
    /// reads the wrong field while the proof still verifies.
    uint256 internal constant _ICAO_SIGNALS_COUNT = 6;
    uint256 internal constant _ICAO_PUB_DG15_PK_HASH = 0;
    uint256 internal constant _ICAO_PUB_PASSPORT_HASH = 1;
    uint256 internal constant _ICAO_PUB_DG_COMMIT = 2;
    uint256 internal constant _ICAO_PUB_HOLDER_ROOT = 3;
    uint256 internal constant _ICAO_PUB_ICAO_ROOT = 4;
    uint256 internal constant _ICAO_PUB_DG1_HASH = 5;

    /**
     * @notice The ONE verifier accepted on the permissionless path. PINNED, never caller-supplied.
     *
     * THIS IS THE TRAP THAT REMOVING THE SIGNATURE CREATES, and it is easy to miss because the
     * signer path looks like it takes a caller-supplied verifier safely. It does:
     * `registerDocumentViaNoir` reads `passport_.verifier` from the caller, but the backend
     * signature covers the whole `Passport` struct including that field, so the signer is
     * attesting the verifier as much as the data.
     *
     * Delete the signature and that becomes a hole wide enough to drive anything through: a caller
     * would pass their own contract whose `verify` returns true unconditionally, and register any
     * identity they liked. So on this path the verifier is set once, by the owner, and the caller
     * has no say.
     */
    address public icaoRegistrationVerifier;

    event IcaoRegistrationVerifierSet(address verifier);

    function setIcaoRegistrationVerifier(address verifier_) external {
        _onlyOwner();
        require(verifier_ != address(0), "HolderRegistration: zero verifier");
        icaoRegistrationVerifier = verifier_;

        emit IcaoRegistrationVerifierSet(verifier_);
    }

    /**
     * @notice Register a document with NO signature, against the ICAO chain proven in-circuit.
     * @param publicInputs_ `register_identity`'s six public outputs, in circuit order.
     * @param zkPoints_ the Honk proof.
     *
     * WHAT THE CALLER DOES NOT GET TO CHOOSE, and why each one matters:
     *
     * - **the verifier** - see `icaoRegistrationVerifier`.
     * - **`documentKey`** - taken from the proof's `passportHash`, not from an argument. The signer
     *   path uses `passport_.publicKey`, a caller-supplied field; here it is proof-bound, which is
     *   strictly better and costs nothing.
     * - **the anti-replay key** - `dg1Hash`, the same value `_replayKey` uses on the signer path.
     *   sec. 2.18i added that output to the circuit precisely so the two paths cannot key on
     *   different values and let one passport bind twice under two holder roots.
     * - **`docType`** - fixed to `DOC_PASSPORT`. `register_identity` IS the passport circuit; a
     *   caller-supplied type would let someone label a passport a national ID for free.
     * - **`notAfter`** - fixed to 0. Nothing in the proof attests an expiry, so accepting one would
     *   be recording a claim the caller made about themselves as though it were established.
     *
     * ────────────────────────────────────────────────────────────────────────────────────────
     * THE VERIFIER MUST BE THE TD1 ONE (sec. 2.18j / 2.18z / 2.18ac).
     *
     * `register_identity` is TD3 - a passport booklet, DG1 of 93 bytes - while `escrow_envelope`
     * computes `dgCommit` over **95**, the TD1 / ID-card layout the live signer path and the
     * wallet's upstream circuits use. Pointing this function at the 93-byte circuit produces
     * `registrationSmt` leaves escrow can NEVER reproduce, so the documents it registers could
     * never obtain a pool identity - correct-looking and inert.
     *
     * `register_identity_td1` exists for that reason and is what `icaoRegistrationVerifier` must be
     * set to. Its `dg1Hash` AND its `dgCommit` are proven to agree with `register_identity_light` at
     * 95 bytes, which is exactly the agreement escrow depends on.
     * ────────────────────────────────────────────────────────────────────────────────────────
     *
     * THE ROOT IS CHECKED BEFORE THE PROOF IS VERIFIED, deliberately (sec. 2.18k). Two reasons.
     * A Honk verification costs hundreds of thousands of gas and a root lookup is one call, so the
     * cheap check goes first. And more importantly it is what makes the guard TESTABLE AT ALL
     * before a real document exists: the negative test hands this function arbitrary bytes with a
     * wrong root and asserts it reverts on the root, never reaching the verifier.
     */
    function registerDocumentViaIcao(
        bytes32[] calldata publicInputs_,
        bytes calldata zkPoints_
    ) external virtual {
        require(
            publicInputs_.length == _ICAO_SIGNALS_COUNT,
            "HolderRegistration: wrong public input count"
        );

        /*
         * THE ENTIRE SECURITY OF THIS PATH IS THIS CHECK (sec. 2.18k).
         *
         * `register_identity` proves the document's signer key is in a tree with the root the
         * PROVER supplied. That is vacuous on its own - rarime's own witness generator builds a
         * ONE-LEAF tree holding the very key being registered, and the circuit accepts it by
         * construction. Anyone can generate a keypair, sign a fabricated SOD over a fabricated
         * MRZ, and produce a completely valid proof.
         *
         * What makes it mean something is that the root must be one `certificatesSmt` actually
         * holds - a tree whose every leaf arrived through `Registration2.registerCertificate`,
         * which proves a CSCA is in the ICAO master list and verifies that CSCA's signature over
         * the DSC. Without this line the proof shows only that the prover can sign their own
         * documents.
         *
         * NOTE THE TREE: `certificatesSmt`, NOT `icaoMasterTreeMerkleRoot`. The circuit parameter
         * is named `icao_root` and the master root is a DIFFERENT structure - a keccak tree of CSCA
         * keys, consumed only when admitting a DSC. Comparing against it would reject every genuine
         * proof while looking principled (sec. 2.18l).
         */
        require(
            PoseidonSMT(address(stateKeeper.certificatesSmt())).isRootValid(
                publicInputs_[_ICAO_PUB_ICAO_ROOT]
            ),
            "HolderRegistration: unknown certificates root"
        );

        address verifier_ = icaoRegistrationVerifier;
        require(verifier_ != address(0), "HolderRegistration: icao verifier not set");
        require(
            INoirVerifier(verifier_).verify(zkPoints_, publicInputs_),
            "HolderRegistration: invalid icao zk proof"
        );

        bytes32 holderRoot_ = publicInputs_[_ICAO_PUB_HOLDER_ROOT];
        require(holderRoot_ != bytes32(0), "HolderRegistration: holder can not be zero");

        bytes32 dg1Hash_ = publicInputs_[_ICAO_PUB_DG1_HASH];
        require(dg1Hash_ != bytes32(0), "HolderRegistration: zero dg1 hash");

        bytes32 documentKey_ = publicInputs_[_ICAO_PUB_PASSPORT_HASH];

        _holderStateKeeper().addDocument(
            documentKey_,
            dg1Hash_,
            holderRoot_,
            _holderStateKeeper().DOC_PASSPORT(),
            uint256(publicInputs_[_ICAO_PUB_DG_COMMIT]),
            0
        );

        emit DocumentRegistered(holderRoot_, documentKey_, _holderStateKeeper().DOC_PASSPORT());
    }

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
    /**
     * @param holderRoot_ the identity this document is bound to.
     *
     * REQUIRED SINCE sec. 2.18bi, and deliberately NOT part of the signed data. The state keeper
     * stores only `Poseidon(holderRoot)` - so that a seized passport cannot be resolved to its
     * owner - and therefore cannot hand the value back. Passing it unsigned is safe because the
     * keeper checks it against that commitment: a wrong holder reverts, so this parameter cannot
     * be used to revoke somebody else's document. What authorises the revocation remains the
     * signature over the PASSPORT, unchanged.
     */
    function revokeDocumentViaSigner(
        Passport memory passport_,
        bytes32 holderRoot_,
        bytes memory signature_
    ) external virtual {
        address signer_ = ECDSA.recover(
            MessageHashUtils.toEthSignedMessageHash(_buildRevokeSignedData(passport_)),
            signature_
        );
        require(_isSigner(signer_), "HolderRegistration: caller is not a signer");

        stateKeeper.useSignature(keccak256(signature_));

        _holderStateKeeper().revokeDocument(passport_.publicKey, holderRoot_);
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
