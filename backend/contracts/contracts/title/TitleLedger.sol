// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {AccessControlUpgradeable} from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {INoirVerifier} from "../interfaces/verifiers/INoirVerifier.sol";
import {RegistrySourceAnchor} from "../registry/RegistrySourceAnchor.sol";

/// @notice Public, inspectable title/property ledger - informed by (NOT copying) MetaLeX's
/// CyberCorps design (see backend/circuits/pp/src/title_holder.nr's header and the 2026-07-24
/// design discussion). Takes CyberCorps' structural properties that don't touch identity - rich,
/// self-describing, non-fungible per-entry records; "the ledger IS the record, not a pointer to
/// one"; possession alone never implies a change of registered holder - and deliberately REJECTS
/// the one CyberCorps property that's at odds with this system's goal: identifiable, inspectable
/// ownership (CyberCorps exists specifically to satisfy DGCL SS219-220's stockholder-list
/// inspection rights, which requires a knowable holder). Here, the holder is NEVER a public
/// identity - only a title-specific Poseidon commitment, provable in zero-knowledge.
///
/// WHY NOT the raw holder_root (Poseidon(pubkey(sk_identity))) used elsewhere in this fusion
/// (HolderStateKeeper, the PP identity ASP)? Because holder_root is one fixed, durable value per
/// identity - storing it directly as a title's public "holder" field would let anyone compare
/// that field across every title entry and correlate every title the same person holds. Instead
/// each title stores `Poseidon2(holder_root, titleId)` - see pp/src/title_holder.nr - so
/// commitments for the same identity on different titles are unrelated field elements.
///
/// LOAN-COLLATERAL FLOW this is built for: a borrower calls `verifyHolderProof` (or a lender
/// contract does, off the borrower's proof) to confirm "the presenter controls this title,"
/// without ever learning who they are. The loan itself should be disbursed via a Privacy Pool
/// deposit using a precommitment the borrower generated locally (frontend/identity-wallet/src/
/// pp/notes.ts, already built) - not a direct transfer to an address that could be linked to the
/// borrower by timing/IP/counterparty analysis. That disbursement-side wiring lives in whatever
/// lending contract integrates this ledger; it is not part of this contract.
///
/// OPEN GAP, not silently assumed solved: binding a real-world notary's identity to an on-chain
/// signing address. `bindNotaryAddress` is gated by NOTARY_REGISTRY's own REGISTRY_POSTMAN role
/// (the SAME trust boundary the notary registry itself already rests on, not a separate,
/// independently-scrutinized admin key) - but the underlying claim "this address really is that
/// notary" still isn't cryptographically proven. A real binding needs an out-of-band process
/// (e.g. reusing rarime's own passport-verification flow, cross-checked against the government
/// registry by name/ID) that isn't built yet. Everything downstream of that binding (the
/// Merkle-proof check against RegistrySourceAnchor's CRE-fed root) is real and
/// unmodified from how the notary registry mechanism already works.
///
/// @dev UUPS-upgradeable behind a proxy - matches RegistrySourceAnchor.sol and this codebase's
/// convention for record-holding registry contracts (see RegistrySourceAnchor.sol's own doc
/// comment for the non-upgradeable-vault-vs-upgradeable-registry distinction this follows).
contract TitleLedger is AccessControlUpgradeable, UUPSUpgradeable {
    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    struct TitleEntry {
        // Public, self-describing legal metadata - NEVER identity.
        bytes32 legalDescriptionHash; // hash of the off-chain legal description document
        string legalDescriptionURI; // where to find it (IPFS/similar)
        bytes32 jurisdiction; // e.g. keccak256("UA") - which registry/law this title is under
        uint256 priorTitleId; // 0 if this is a root entry; otherwise a chain-of-title link
        bytes32 notaryRegistryId; // which RegistrySourceAnchor registryId attested this entry
        address notary; // the specific notary (must be active at mint/endorse time)
        uint256 mintedAt;
        bool encumbered;
    }

    // Regular state, not immutable - see RegistrySourceAnchor.EVIDENCE_REGISTRY's comment for why
    // (one implementation can serve many proxies; deployment-specific config is initializer-set).
    RegistrySourceAnchor public NOTARY_REGISTRY;
    INoirVerifier public TITLE_HOLDER_VERIFIER; // verifies pp::title_holder proofs

    // 0 is reserved for "no prior title" in priorTitleId. NOT given an inline default here: for a
    // UUPS-upgradeable contract, an inline state-variable initializer only runs in the
    // IMPLEMENTATION contract's own (never-used) constructor-time storage, not the proxy's - the
    // proxy's slot would silently stay at the EVM default of 0 forever. Set explicitly in
    // initialize() instead (caught by a real assertEq(titleId, 1) test failure, not by inspection).
    uint256 public nextTitleId;
    mapping(uint256 => TitleEntry) public titles;
    mapping(uint256 => string[]) public restrictionLegends; // titleId => legends, separately mutable
    mapping(uint256 => bytes32) public holderCommitment; // titleId => Poseidon2(holder_root, titleId)

    // See the OPEN GAP note above - placeholder trust bootstrap, not a solved binding. Gated by
    // NOTARY_REGISTRY's OWN REGISTRY_POSTMAN role (checked live via hasRole, not copied into a
    // separate admin key here) - deliberately the SAME trust boundary the notary registry itself
    // already rests on, not an additional, independently-scrutinized authority. This doesn't
    // solve "how do we know the binding claim is true" (that needs the out-of-band identity
    // process described above), but it does mean there is exactly ONE trust assumption in this
    // whole mechanism (whoever the registry's postman is), not two.
    mapping(address => bytes32) public notaryDataHash; // notary address => keccak(regNumber,fullName,region,status)

    event TitleMinted(uint256 indexed titleId, bytes32 jurisdiction, address indexed notary, bytes32 holderCommitment);
    event TitleTransferred(uint256 indexed titleId, bytes32 oldHolderCommitment, bytes32 newHolderCommitment);
    event LegendAdded(uint256 indexed titleId, string legend, address indexed notary);
    event EncumbranceSet(uint256 indexed titleId, bool encumbered, address indexed notary);
    event NotaryAddressBound(address indexed notary, bytes32 notaryDataHash);

    error TitleDoesNotExist();
    error NotaryNotActive();
    error InvalidNotarySignature();
    error InvalidHolderProof();
    error ZeroCommitment();
    error OnlyRegistryPostman();
    error ZeroAddress();

    /// @notice Disables initializers on the implementation contract. Using the UUPS
    /// upgradeability pattern - matches Entrypoint.sol's own constructor exactly.
    constructor() {
        _disableInitializers();
    }

    function initialize(address notaryRegistry_, address titleHolderVerifier_, address owner_) external initializer {
        if (notaryRegistry_ == address(0) || titleHolderVerifier_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        __AccessControl_init();
        // UUPSUpgradeable has no storage/init step in OZ 5.6.1 (it's a thin, stateless wrapper).

        NOTARY_REGISTRY = RegistrySourceAnchor(notaryRegistry_);
        TITLE_HOLDER_VERIFIER = INoirVerifier(titleHolderVerifier_);
        nextTitleId = 1;
        _grantRole(DEFAULT_ADMIN_ROLE, owner_);
        _grantRole(OWNER_ROLE, owner_);
    }

    function _authorizeUpgrade(address) internal override onlyRole(OWNER_ROLE) {}

    /// @dev Placeholder trust bootstrap - see the contract-level OPEN GAP note and the
    /// `notaryDataHash` field comment for why this is gated by NOTARY_REGISTRY's role instead of
    /// a bespoke admin key.
    function bindNotaryAddress(address notary_, bytes32 notaryDataHash_) external {
        if (!NOTARY_REGISTRY.hasRole(NOTARY_REGISTRY.REGISTRY_POSTMAN(), msg.sender)) revert OnlyRegistryPostman();
        notaryDataHash[notary_] = notaryDataHash_;
        emit NotaryAddressBound(notary_, notaryDataHash_);
    }

    /// @notice Mint a new title entry. `notarySignature_` must be from `notary_` over the entry's
    /// legal metadata; `notary_` must currently be bound (see bindNotaryAddress) to a leaf that is
    /// a member of the CURRENTLY ACTIVE snapshot for `notaryRegistryId_` (proven by
    /// `notaryMerkleProof_` against RegistrySourceAnchor.latestActiveRoot - the same
    /// keccak/MerkleProof-compatible tree backend/cre/notary_registry builds).
    function mintTitle(
        bytes32 legalDescriptionHash_,
        string calldata legalDescriptionURI_,
        bytes32 jurisdiction_,
        uint256 priorTitleId_,
        bytes32 notaryRegistryId_,
        address notary_,
        bytes32[] calldata notaryMerkleProof_,
        bytes calldata notarySignature_,
        bytes32 initialHolderCommitment_
    ) external returns (uint256 titleId_) {
        if (initialHolderCommitment_ == bytes32(0)) revert ZeroCommitment();
        _requireActiveNotary(notaryRegistryId_, notary_, notaryMerkleProof_);
        bytes32 mintMessage_ = keccak256(
            abi.encodePacked("TITLE_LEDGER_MINT", address(this), legalDescriptionHash_, jurisdiction_, priorTitleId_)
        );
        _requireSignedByNotary(notary_, notarySignature_, mintMessage_);

        titleId_ = nextTitleId++;
        titles[titleId_] = TitleEntry({
            legalDescriptionHash: legalDescriptionHash_,
            legalDescriptionURI: legalDescriptionURI_,
            jurisdiction: jurisdiction_,
            priorTitleId: priorTitleId_,
            notaryRegistryId: notaryRegistryId_,
            notary: notary_,
            mintedAt: block.timestamp,
            encumbered: false
        });
        holderCommitment[titleId_] = initialHolderCommitment_;

        emit TitleMinted(titleId_, jurisdiction_, notary_, initialHolderCommitment_);
    }

    /// @notice Add a restriction legend to an existing title (e.g. "subject to mortgage", "life
    /// estate") - mutable and per-entry, unlike a fungible balance which can't distinguish
    /// restricted from unrestricted units. Requires the SAME currently-active-notary check as
    /// minting; does not require the holder's proof (a lien can be recorded against a title the
    /// notary is attesting to independent of who currently holds it, mirroring how a real
    /// county recorder files an encumbrance).
    function addLegend(
        uint256 titleId_,
        string calldata legend_,
        bytes32[] calldata notaryMerkleProof_,
        bytes calldata notarySignature_
    ) external {
        TitleEntry storage entry = titles[titleId_];
        if (entry.mintedAt == 0) revert TitleDoesNotExist();
        _requireActiveNotary(entry.notaryRegistryId, entry.notary, notaryMerkleProof_);
        // Domain-separated from mintTitle's message (a different prefix, different fields) - a
        // deterministic notary signer must never be asked to sign the "same" digest for two
        // different operations, or a signature captured for one could be replayed as the other.
        // See HolderRegistration.revokeDocumentViaSigner's doc comment for the same lesson,
        // found the hard way earlier in this fusion's own registration flow.
        bytes32 legendMessage_ = keccak256(abi.encodePacked("TITLE_LEDGER_LEGEND", address(this), titleId_, legend_));
        _requireSignedByNotary(entry.notary, notarySignature_, legendMessage_);

        restrictionLegends[titleId_].push(legend_);
        emit LegendAdded(titleId_, legend_, entry.notary);
    }

    /// @notice Mark/clear a title as encumbered (e.g. a lending protocol placing/releasing a
    /// lien). Gated exactly like addLegend - a bare boolean with no authorization check would let
    /// anyone lock (or fraudulently clear) an encumbrance on someone else's title.
    function setEncumbered(
        uint256 titleId_,
        bool encumbered_,
        bytes32[] calldata notaryMerkleProof_,
        bytes calldata notarySignature_
    ) external {
        TitleEntry storage entry = titles[titleId_];
        if (entry.mintedAt == 0) revert TitleDoesNotExist();
        _requireActiveNotary(entry.notaryRegistryId, entry.notary, notaryMerkleProof_);
        bytes32 encumberMessage_ =
            keccak256(abi.encodePacked("TITLE_LEDGER_ENCUMBER", address(this), titleId_, encumbered_));
        _requireSignedByNotary(entry.notary, notarySignature_, encumberMessage_);

        entry.encumbered = encumbered_;
        emit EncumbranceSet(titleId_, encumbered_, entry.notary);
    }

    /// @notice Transfer registered holdership. Requires a ZK proof (pp::title_holder) that the
    /// caller knows an sk_identity whose title-specific commitment matches the CURRENTLY recorded
    /// one - possession of the title's metadata/knowledge of its ID alone never suffices, mirroring
    /// CyberCorps' "no change in record ownership shall be deemed to occur solely by virtue of any
    /// transfer... among addresses" principle, implemented here via a proof instead of an
    /// admin-authorized metadata edit.
    function transferTitle(uint256 titleId_, bytes32 newHolderCommitment_, bytes calldata proof_) external {
        if (titles[titleId_].mintedAt == 0) revert TitleDoesNotExist();
        if (newHolderCommitment_ == bytes32(0)) revert ZeroCommitment();
        if (!_verifyHolderProof(titleId_, proof_)) revert InvalidHolderProof();

        bytes32 old = holderCommitment[titleId_];
        holderCommitment[titleId_] = newHolderCommitment_;
        emit TitleTransferred(titleId_, old, newHolderCommitment_);
    }

    /// @notice Read-only collateral-eligibility check: does `proof_` demonstrate control of
    /// `titleId_`'s CURRENT holder commitment, without transferring anything? This is the hook a
    /// lending protocol calls (or has the borrower call and relays) before disbursing a loan -
    /// disbursement itself should go through a Privacy Pool deposit using a borrower-supplied
    /// precommitment, kept entirely outside this contract, so the loan is never linkable to
    /// whoever produced this proof.
    function verifyHolderProof(uint256 titleId_, bytes calldata proof_) external view returns (bool) {
        if (titles[titleId_].mintedAt == 0) revert TitleDoesNotExist();
        return _verifyHolderProof(titleId_, proof_);
    }

    function getRestrictionLegends(uint256 titleId_) external view returns (string[] memory) {
        return restrictionLegends[titleId_];
    }

    /// @notice Explicit getter for the full entry - not relying on the auto-generated `titles(id)`
    /// tuple getter's exact field ordering/inclusion rules for a struct containing a `string`
    /// member, which is easy to get subtly wrong at a call site without a compiler to check it.
    function getTitle(uint256 titleId_) external view returns (TitleEntry memory) {
        if (titles[titleId_].mintedAt == 0) revert TitleDoesNotExist();
        return titles[titleId_];
    }

    function _verifyHolderProof(uint256 titleId_, bytes calldata proof_) internal view returns (bool) {
        bytes32[] memory publicInputs = new bytes32[](2);
        publicInputs[0] = holderCommitment[titleId_];
        publicInputs[1] = bytes32(titleId_);
        return TITLE_HOLDER_VERIFIER.verify(proof_, publicInputs);
    }

    function _requireActiveNotary(bytes32 registryId_, address notary_, bytes32[] calldata proof_) internal view {
        bytes32 dataHash = notaryDataHash[notary_];
        if (dataHash == bytes32(0)) revert NotaryNotActive();
        if (!MerkleProof.verify(proof_, NOTARY_REGISTRY.latestActiveRoot(registryId_), dataHash)) {
            revert NotaryNotActive();
        }
    }

    /// @dev Generic signature check over a CALLER-CONSTRUCTED, already-domain-separated message
    /// hash - each call site builds its own message with its own prefix (see mintTitle/addLegend),
    /// this function never fabricates one, so two different operations can never end up asking a
    /// notary to sign the same digest.
    function _requireSignedByNotary(address notary_, bytes calldata signature_, bytes32 messageHash_) internal pure {
        address signer_ = ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(messageHash_), signature_);
        if (signer_ != notary_) revert InvalidNotarySignature();
    }
}
