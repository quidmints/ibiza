// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {PoseidonUnit1L, PoseidonUnit2L, PoseidonUnit3L} from "../libraries/Poseidon.sol";

import {StateKeeper} from "../state/StateKeeper.sol";

/**
 * @title HolderStateKeeper
 * @notice The holder-rooted credential tree — the "1 key = 1 document" fix. See SCOPE.md §7.8.
 *
 * The upstream {StateKeeper} enforces a strict bijection: `addBond` requires
 * `_identityInfo.activePassport == 0`, so one identity key binds AT MOST one passport.
 * rarime supports identity *rotation* for one passport (`reissueBondIdentity`) but never
 * one holder with many documents, and never renewal-with-continuity.
 *
 * This fork inverts the model into a 2-level tree:
 *
 *     holder root (durable)  =  identityKey = Poseidon(pubkey(sk_identity))
 *          │                     ↑ continuity binds HERE: scoped pseudonyms, nullifiers,
 *          │                       one-person-ness, card-state — NOT the document.
 *          ├── document: passport      (docType, dgCommit, validity, status)
 *          ├── document: national ID
 *          ├── document: EUDI PID
 *          └── document: passport'      ← renewal supersedes the old passport
 *
 * Relation is many-documents-TO-one-holder (a given document still belongs to exactly one
 * holder; a holder may hold many documents). RENEWAL adds a new document and supersedes the
 * old under the SAME holder root, so identity/pseudonyms/card-state survive a passport swap.
 *
 * It REUSES StateKeeper's certificate / registration-set / owner / used-signature machinery
 * by inheritance, ADDS the document model, and DISABLES the old 1:1 `addBond` path so the two
 * binding models can't be mixed. The SMT (`registrationSmt`) is unchanged, and revocation/renewal
 * do NOT need true SMT exclusion (non-membership) proofs — the underlying solarity solidity-lib
 * SparseMerkleTree exposes `getProof`'s exclusion machinery (existence/auxExistence/auxKey/
 * auxValue), but that's for the ORTHOGONAL case of proving a key was never registered. Revocation
 * is different: the document key stays a tree MEMBER forever; only its VALUE changes to a sentinel
 * (Poseidon1(REVOKED) / Poseidon1(SUPERSEDED)). A query circuit reconstructs the CLAIMED-current
 * value — Poseidon3(dgCommit, seq, timestamp) — and does a plain SMT MEMBERSHIP check against the
 * current root; once revoked, that reconstruction can never again equal the real leaf value, so a
 * stale "I'm still current" claim provably fails without any exclusion proof. This membership-
 * with-value property is what actually needs to hold, and it's verified directly (not just
 * asserted) by test_leaf_value_matches_circuit_reconstruction in test/holder/HolderStateKeeper.t.sol.
 *
 * OPEN GAP (tracked in backend/circuits/PP-NOIR-FUSION.md): this property only rejects a stale
 * claim if the CONSUMING circuit actually performs the reconstruct-and-membership-check against
 * THIS tree's value convention. The forked `query_identity` circuit does not yet do so — see the
 * fusion doc's Noir migration TODOs.
 *
 * SCOPE NOTE: the matching ZK side (prove "a CURRENT document under MY holder root satisfies
 * the predicate") is the forked `query_identity` Noir circuit (passport-zk-circuits-noir) and
 * is NOT in this repo — see §7.5/§7.8. This contract defines the on-chain tree the circuit
 * proves against.
 */
contract HolderStateKeeper is StateKeeper {
    bytes32 public constant SUPERSEDED = keccak256("SUPERSEDED");

    // Canonical document types (mirror the SDK DocumentType enum in HolderTree.ts).
    bytes32 public constant DOC_PASSPORT = keccak256("PASSPORT");
    bytes32 public constant DOC_NATIONAL_ID = keccak256("NATIONAL_ID");
    bytes32 public constant DOC_MDL = keccak256("MDL");
    bytes32 public constant DOC_EUDI_PID = keccak256("EUDI_PID");
    // Notarized proof-of-title (property/vehicle/asset ownership) — notary/registrar signature
    // trust root, not a passport biometric chip. Tree/state support only; no query circuit yet
    // (see Eudi.ts TitleClaim for the honest built-vs-unbuilt split).
    bytes32 public constant DOC_NOTARIAL_TITLE = keccak256("NOTARIAL_TITLE");

    enum DocStatus {
        None,
        Current,
        Superseded,
        Revoked
    }

    struct DocumentBond {
        bytes32 holderRoot; // the durable identity (was `identityKey`)
        bytes32 docType;
        uint64 issueTimestamp;
        uint64 notAfter; // validity window end (0 = none)
        uint64 seq; // supersession sequence under this holder
        DocStatus status;
    }

    // --- appended storage (after all StateKeeper storage — safe for the proxy layout) ---
    mapping(bytes32 => DocumentBond) internal _documents; // documentKey => bond
    mapping(bytes32 => bytes32[]) internal _holderDocuments; // holderRoot => documentKeys
    mapping(bytes32 => bool) internal _usedDocumentHash; // anti-replay for the hash variant

    /**
     * @notice Which holder a document hash is bound to. Appended after all prior storage, so the
     *         proxy layout is unaffected.
     *
     * WHY THIS EXISTS. `_usedDocumentHash` records THAT a document hash was consumed but not BY
     * WHOM, which is enough for anti-replay and not enough for escrow (TODO.md sec. 2.13k). The
     * escrow circuit proves an MRZ hashes to `dg1Hash` and that `holder_root` derives from
     * `sk_identity` - it does NOT and CANNOT prove the passport is genuine, because the ICAO
     * signature chain is checked during REGISTRATION, not escrow. Without this lookup a caller
     * could invent a DG1, escrow against it, and land a commitment in the identity tree backed by
     * no real document - which would make the tree's scarcity guarantee, and therefore the entire
     * blacklist, worthless.
     */
    mapping(bytes32 => bytes32) internal _holderOfDocumentHash; // dg1Hash => holderRoot

    /**
     * @notice When a document last STOPPED being current, by revocation or renewal. Appended after
     *         all prior storage, so the proxy layout is unaffected.
     *
     * WHY A CONSUMER NEEDS THIS. Invalidating a document overwrites its leaf VALUE, so every root
     * created afterwards excludes it - but roots created BEFORE still prove it current, and
     * `PoseidonSMT.isRootValid` keeps accepting those for the rest of ROOT_VALIDITY (one hour).
     * A cancelled passport could therefore still register a pool identity for up to an hour
     * (TODO.md sec. 2.18b). A consumer that requires the root it was given to be at least as new as
     * this timestamp closes that, and nothing else on this contract exposes the information: the
     * SMT records WHEN each root appeared but not WHY, and `_documents` is keyed by a document key
     * a caller proving in zero knowledge deliberately never reveals.
     */
    uint64 public lastDocumentInvalidationAt;

    event DocumentAdded(bytes32 indexed holderRoot, bytes32 documentKey, bytes32 docType);
    event DocumentRenewed(
        bytes32 indexed holderRoot,
        bytes32 oldDocumentKey,
        bytes32 newDocumentKey
    );
    event DocumentRevoked(bytes32 indexed holderRoot, bytes32 documentKey);

    /**
     * @notice Disable the upstream 1:1 binding so it cannot be mixed with the holder tree.
     */
    function addBond(bytes32, bytes32, bytes32, uint256) external virtual override onlyRegistration {
        revert("HolderStateKeeper: use addDocument (holder tree)");
    }

    /**
     * @notice Bind a document under a holder root. Many documents may share one holder root;
     *         a document may belong to only one holder.
     * @param documentKey_  unique key of the document (e.g. passport public key hash)
     * @param documentHash_ the document hash variant (anti-replay), may be zero
     * @param holderRoot_   the durable identity (rarime `identityKey` / profileKey)
     * @param docType_      one of the DOC_* constants
     * @param dgCommit_     the document's attribute commitment
     * @param notAfter_     validity window end (epoch seconds), 0 if none
     */
    function addDocument(
        bytes32 documentKey_,
        bytes32 documentHash_,
        bytes32 holderRoot_,
        bytes32 docType_,
        uint256 dgCommit_,
        uint64 notAfter_
    ) external virtual onlyRegistration {
        require(documentKey_ != bytes32(0), "HolderStateKeeper: zero document");
        require(holderRoot_ != bytes32(0), "HolderStateKeeper: zero holder");
        require(_documents[documentKey_].status == DocStatus.None, "HolderStateKeeper: document bound");

        if (documentHash_ != bytes32(0)) {
            require(!_usedDocumentHash[documentHash_], "HolderStateKeeper: document hash used");
            _usedDocumentHash[documentHash_] = true;
            _holderOfDocumentHash[documentHash_] = holderRoot_;
        }

        _bindDocument(documentKey_, holderRoot_, docType_, dgCommit_, notAfter_, 0);

        emit DocumentAdded(holderRoot_, documentKey_, docType_);
    }

    /**
     * @notice Renew a document: supersede `oldDocumentKey_` and add `newDocumentKey_` under the
     *         SAME holder root, preserving identity continuity. The link is the holder root:
     *         registration verifies a ZK proof binding the new document's DG1 to `holderRoot_`,
     *         exactly as the original document was bound, so both provably belong to one holder.
     */
    function renewDocument(
        bytes32 oldDocumentKey_,
        bytes32 newDocumentKey_,
        bytes32 newDocumentHash_,
        bytes32 holderRoot_,
        bytes32 newDocType_,
        uint256 newDgCommit_,
        uint64 newNotAfter_
    ) external virtual onlyRegistration {
        DocumentBond storage old_ = _documents[oldDocumentKey_];

        require(old_.status == DocStatus.Current, "HolderStateKeeper: old not current");
        require(old_.holderRoot == holderRoot_, "HolderStateKeeper: holder mismatch");
        require(_documents[newDocumentKey_].status == DocStatus.None, "HolderStateKeeper: new bound");

        if (newDocumentHash_ != bytes32(0)) {
            require(!_usedDocumentHash[newDocumentHash_], "HolderStateKeeper: document hash used");
            _usedDocumentHash[newDocumentHash_] = true;
            _holderOfDocumentHash[newDocumentHash_] = holderRoot_;
        }

        // Supersede the old leaf (keeps it provably non-current in the tree).
        old_.status = DocStatus.Superseded;
        lastDocumentInvalidationAt = uint64(block.timestamp);
        bytes32 oldIndex_ = bytes32(
            PoseidonUnit2L.poseidon([uint256(oldDocumentKey_), uint256(holderRoot_)])
        );
        registrationSmt.update(
            oldIndex_,
            bytes32(PoseidonUnit1L.poseidon([uint256(SUPERSEDED) % SNARK_SCALAR_FIELD]))
        );

        // Add the renewed document under the same holder root, next sequence.
        _bindDocument(newDocumentKey_, holderRoot_, newDocType_, newDgCommit_, newNotAfter_, old_.seq + 1);

        emit DocumentRenewed(holderRoot_, oldDocumentKey_, newDocumentKey_);
    }

    /**
     * @notice Revoke a current document. The leaf stays a tree member (Poseidon2(documentKey,
     *         holderRoot) is never removed); its VALUE is overwritten to Poseidon1(REVOKED), which
     *         can never equal a query circuit's Poseidon3(dgCommit, seq, timestamp) reconstruction
     *         for "current" — see the class-level NatSpec for why this doesn't need an exclusion
     *         (non-membership) proof.
     */
    function revokeDocument(bytes32 documentKey_) external virtual onlyRegistration {
        DocumentBond storage doc_ = _documents[documentKey_];

        require(doc_.status == DocStatus.Current, "HolderStateKeeper: not current");

        doc_.status = DocStatus.Revoked;
        lastDocumentInvalidationAt = uint64(block.timestamp);

        bytes32 index_ = bytes32(
            PoseidonUnit2L.poseidon([uint256(documentKey_), uint256(doc_.holderRoot)])
        );
        registrationSmt.update(
            index_,
            bytes32(PoseidonUnit1L.poseidon([uint256(REVOKED) % SNARK_SCALAR_FIELD]))
        );

        emit DocumentRevoked(doc_.holderRoot, documentKey_);
    }

    /**
     * @notice Get a document's bond.
     */
    function getDocument(bytes32 documentKey_) external view virtual returns (DocumentBond memory) {
        return _documents[documentKey_];
    }

    /**
     * @notice List all document keys ever bound under a holder root (any status).
     */
    function getHolderDocuments(
        bytes32 holderRoot_
    ) external view virtual returns (bytes32[] memory) {
        return _holderDocuments[holderRoot_];
    }

    /**
     * @notice Count the CURRENT (non-superseded, non-revoked) documents under a holder root.
     */
    function getActiveDocumentCount(
        bytes32 holderRoot_
    ) external view virtual returns (uint256 count_) {
        bytes32[] storage keys_ = _holderDocuments[holderRoot_];
        for (uint256 i = 0; i < keys_.length; ++i) {
            if (_documents[keys_[i]].status == DocStatus.Current) {
                ++count_;
            }
        }
    }

    /**
     * @notice The holder a document hash is bound to, or zero if that hash was never registered.
     * @dev Read by the identity registry to confirm an escrow is backed by a REAL, ICAO-verified
     *      document rather than an invented MRZ. See `_holderOfDocumentHash`.
     */
    function holderOfDocumentHash(bytes32 documentHash_) external view returns (bytes32) {
        return _holderOfDocumentHash[documentHash_];
    }

    function _bindDocument(
        bytes32 documentKey_,
        bytes32 holderRoot_,
        bytes32 docType_,
        uint256 dgCommit_,
        uint64 notAfter_,
        uint64 seq_
    ) internal {
        _documents[documentKey_] = DocumentBond({
            holderRoot: holderRoot_,
            docType: docType_,
            issueTimestamp: uint64(block.timestamp),
            notAfter: notAfter_,
            seq: seq_,
            status: DocStatus.Current
        });

        _holderDocuments[holderRoot_].push(documentKey_);

        bytes32 index_ = bytes32(
            PoseidonUnit2L.poseidon([uint256(documentKey_), uint256(holderRoot_)])
        );
        bytes32 value_ = bytes32(
            PoseidonUnit3L.poseidon([dgCommit_, uint256(seq_), uint256(uint64(block.timestamp))])
        );

        registrationSmt.add(index_, value_);
    }
}
