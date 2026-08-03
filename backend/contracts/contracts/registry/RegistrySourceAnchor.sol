// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@oz-upgradeable/access/AccessControlUpgradeable.sol";
import {UUPSUpgradeable} from "@oz-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IEvidenceRegistry} from "@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol";

/// @notice Anchors periodically-refreshed roots of external authoritative-source lists (e.g.
/// Ukraine's notary registry bulk XML/zip export from ern.minjust.gov.ua / data.gov.ua) into the
/// SAME ERC-7812 evidence registry rarime's identity state roots and PP's ASP root already anchor
/// into - one anchoring mechanism for every "public, authoritative government source" this fusion
/// consumes (the notary registry is the first; more are expected, hence keyed by `registryId`
/// rather than hardwired to one list). Mirrors Entrypoint.sol's updateRoot/latestActiveRoot
/// pattern deliberately (proven design in this codebase): an activation delay against
/// front-run/equivocation, and a write-once-per-index anchor into the evidence registry.
///
/// @dev Trust model: the LEAF SET is produced OFF-CHAIN by a Chainlink CRE workflow using
/// DON-consensus HTTP fetches - multiple independent CRE nodes fetch the SAME bulk export
/// independently and must agree bit-for-bit (cre.ConsensusIdenticalAggregation) before a report
/// is generated and written here (see backend/cre/notary_registry/main.go). But unlike an
/// earlier version of this contract, the ROOT is never trusted as a bare off-chain claim: the
/// full leaf set is submitted as calldata and the root is COMPUTED ON-CHAIN from it
/// (`_computeRoot`), so there is no way to publish a root that doesn't correspond to a real,
/// fully-available leaf set. Data availability is the transaction's own calldata/event log -
/// permanently replayable by any full node - not an external pinning service (an earlier design
/// used an IPFS CID for this; dropped as an unnecessary and less reliable dependency for data
/// that's cheap enough to just put on-chain). This is deliberately the SAME shape as an
/// OFAC-list oracle: a periodically-refreshed, cross-verified, fully self-contained snapshot of a
/// bulk export, not a live query endpoint.
///
/// @dev UUPS-upgradeable behind a proxy, matching this codebase's convention for registry/
/// orchestration contracts that hold evolving records rather than custody funds directly
/// (Entrypoint, StateKeeper, RegistrationSimple all follow the same pattern; only PP's
/// fund-custody contracts - PrivacyPool/State - are deliberately immutable, a trust-minimization
/// choice for the vault logic specifically, not something a registry anchor needs).
contract RegistrySourceAnchor is AccessControlUpgradeable, UUPSUpgradeable {
    /**
     * PUBLICATION ONLY. This role may anchor a snapshot and do nothing else (sec. 2.18cn).
     *
     * IT USED TO DO THREE JOBS. `TitleLedger.registerNotary` and `revokeNotary` checked THIS role
     * too, on the sound-sounding reasoning that one auditable trust boundary beats two. The effect
     * was that a snapshot-submission role also decided **who is a notary** - and `revokeNotary`'s
     * own comment calls that "THE ENTIRE FAULT MECHANISM". Granting publication to a machine (a CRE
     * Forwarder, the intended holder) would therefore have handed that machine the power to revoke
     * every notary; and any operator key kept for notary administration could publish fabricated
     * registers. The reuse was not a smaller trust boundary, it was a LARGER one wearing one name.
     */
    bytes32 public constant REGISTRY_POSTMAN = keccak256("REGISTRY_POSTMAN");

    /**
     * NOTARY ADMINISTRATION ONLY - enrolment and revocation in `TitleLedger`.
     *
     * Declared HERE rather than in `TitleLedger` because that contract already reads its authority
     * from this registry (`NOTARY_REGISTRY.hasRole(...)`), so the role list stays in one place and
     * one admin governs both. Separate from `REGISTRY_POSTMAN` because the two powers must be able
     * to have DIFFERENT HOLDERS: one is a relay, the other is a human decision that ends with
     * somebody losing their ability to act.
     */
    bytes32 public constant NOTARY_REGISTRAR = keccak256("NOTARY_REGISTRAR");

    bytes32 public constant OWNER_ROLE = keccak256("OWNER_ROLE");

    /**
     * The pinned CRE workflow, append-only (sec. 2.18bs).
     *
     * WHY THIS EXISTS. `ConsensusIdenticalAggregation` proves the DON nodes AGREE; it cannot prove
     * they are RIGHT (sec. 2.18ao). Verifying the register's TLS session INSIDE the workflow fixes
     * that - agreement becomes agreement on *"the register's own server served these bytes"* - but
     * only if the workflow that ran is the one that does the verifying. **Consensus protects against
     * a rogue NODE, never against a rogue WORKFLOW** (sec. 2.15a).
     *
     * NO NEW AUTHORITY, DELIBERATELY. Pinning is gated by the EXISTING `OWNER_ROLE`, not a bespoke
     * publisher role - the same reasoning `TitleLedger` used when it reused `REGISTRY_POSTMAN`
     * rather than minting an admin key: one trust boundary is auditable, two are a surface. What
     * makes this SAFE where that was not is that the power differs in kind - an owner here can only
     * name a hash-identified, publicly auditable artifact on an append-only list after a delay,
     * never publish data directly.
     *
     * APPEND-ONLY is the load-bearing property: a swap is permanently visible rather than a silent
     * substitution, so "which code produced this snapshot" is answerable for every past root.
     */
    struct WorkflowVersion {
        bytes32 workflowId; // deterministic wasm artifact hash
        uint64 pinnedAt;
        uint64 activeFrom;
    }

    WorkflowVersion[] public workflowVersions;

    event WorkflowPinned(bytes32 indexed workflowId, uint256 index, uint64 activeFrom);

    error ZeroWorkflowId();
    error WorkflowAlreadyPinned(bytes32 workflowId);
    error NoActiveWorkflow();
    error UnpinnedWorkflow(bytes32 reported, bytes32 active);
    error MalformedReportMetadata(uint256 length);

    /**
     * Where the workflow ID sits in the metadata header CRE prepends to every report.
     *
     * NOT A GUESSED OFFSET. This is `chainlink-common pkg/capabilities/consensus/ocr3/types.Metadata`
     * as documented in the SDK this repo actually depends on
     * (cre-sdk-go v1.15.0, `cre/report_fields.go`): version 1 || executionId 32 || timestamp 4 ||
     * donId 4 || donConfigVersion 4 || **workflowId 32** || workflowName 10 || workflowOwner 20 ||
     * reportId 2 = 109. Decoding this wrong would reject VALID reports, so the length is CHECKED
     * rather than assumed and its failure is named rather than silent.
     */
    uint256 public constant REPORT_METADATA_LENGTH = 109;
    uint256 public constant REPORT_WORKFLOW_ID_OFFSET = 45;

    /// Same window Entrypoint.sol uses for ASP roots - gives verifiers/watchers a chance to catch
    /// a bad snapshot before anything can be proven against it.
    uint256 public constant ROOT_ACTIVATION_DELAY = 1 hours;

    /**
     * How long a newly pinned workflow waits before snapshots may cite it (sec. 2.18bs).
     *
     * THE ONE THING A TIMELOCK IS ACTUALLY FOR HERE. Once each DON node verifies the register's TLS
     * session inside the workflow, fabricated DATA becomes impossible rather than merely detectable -
     * so the snapshot path needs no contest window.
     *
     * AND A SWAP IS NOT WHAT THIS DEFENDS AGAINST - an earlier version of this comment claimed "a
     * workflow SWAP cannot be prevented cryptographically, only seen", which was true only because
     * `onReport` DISCARDED the metadata naming the workflow. It no longer does: a report is now
     * checked against the active pin, so a swapped workflow is REJECTED rather than watched. What is
     * left for a delay is the only thing it was ever suited to - the AUTHORISED RE-PIN. Changing
     * which code the anchor believes is a governance act, and this is the interval in which that act
     * is visible and contestable before anything relies on it. Without it the update mechanism is a
     * same-block censorship lever.
     */
    uint256 public constant WORKFLOW_ACTIVATION_DELAY = 24 hours;

    // Same BN254/SNARK scalar field every other statement key in this fusion is reduced into
    // (Entrypoint._aspStatementKey, EvidenceRegistry.BABY_JUB_JUB_PRIME_FIELD) - duplicated
    // locally rather than imported cross-module, matching this codebase's existing convention.
    uint256 internal constant SNARK_SCALAR_FIELD =
        21888242871839275222246405745257275088548364400416034343698204186575808495617;

    struct RegistrySnapshot {
        bytes32 root;
        uint256 timestamp;
    }

    // Regular state, NOT immutable - one implementation contract can serve many proxy instances
    // (or be reused across deployments), so deployment-specific config belongs in initializer-set
    // state. Kept ALL-CAPS despite not being immutable, matching Entrypoint.EVIDENCE_REGISTRY's
    // own naming convention for this exact situation (a semi-constant config address, set once at
    // initialize() and never changed again in practice, even though the language doesn't enforce
    // that the way `immutable` would).
    IEvidenceRegistry public EVIDENCE_REGISTRY;

    mapping(bytes32 => RegistrySnapshot[]) public snapshots;

    /// Full leaf set for every published snapshot - the on-chain data-availability layer
    /// `_computeRoot`'s output is checked against. Anyone can rebuild and independently re-verify
    /// a Merkle proof against `snapshots[registryId][index].root` using this array directly, with
    /// no external fetch of any kind.
    event SnapshotLeaves(bytes32 indexed registryId, uint256 indexed index, bytes32[] leaves);
    event SnapshotAnchored(bytes32 indexed registryId, bytes32 root, uint256 index, bytes32 statementKey);

    error EmptyLeafSet();
    error LeavesNotStrictlySorted();
    error NoSnapshotsAvailable();
    error NoActiveSnapshot();
    error ZeroAddress();

    /// @notice Disables initializers on the implementation contract. Using the UUPS
    /// upgradeability pattern - matches Entrypoint.sol's own constructor exactly.
    constructor() {
        _disableInitializers();
    }

    function initialize(address evidenceRegistry_, address admin_) external initializer {
        if (evidenceRegistry_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        __AccessControl_init();
        // UUPSUpgradeable has no storage/init step in OZ 5.6.1 (it's a thin, stateless wrapper).

        EVIDENCE_REGISTRY = IEvidenceRegistry(evidenceRegistry_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(OWNER_ROLE, admin_);
    }

    function _authorizeUpgrade(address) internal override onlyRole(OWNER_ROLE) {}

    /// @notice Publish a fresh snapshot for `registryId_` (e.g. keccak256("UA_NOTARY_REGISTRY")).
    /// `leaves_` MUST be strictly ascending (matches backend/cre/notary_registry/main.go's own
    /// `sort.Slice` before computing its root) - cheaper to verify on-chain (O(n) comparisons)
    /// than to sort on-chain, and rejects duplicate leaves as a side effect. The root is computed
    /// here, not trusted from the caller - see the contract-level trust-model note. Never
    /// overwrites a prior snapshot - each publish appends, so history (and what was active at any
    /// past timestamp) is preserved, same as Entrypoint's association sets.
    /**
     * @notice Pin the CRE workflow whose output this anchor accepts.
     * @dev Append-only and timelocked; reuses OWNER_ROLE rather than adding a publisher authority.
     */
    function pinWorkflow(bytes32 workflowId_) external onlyRole(OWNER_ROLE) returns (uint256 index_) {
        if (workflowId_ == bytes32(0)) revert ZeroWorkflowId();

        // Re-pinning the SAME id would reset its timelock, which is how a contested version gets
        // quietly re-armed. The list is append-only in both senses: nothing is removed, and nothing
        // already named can be renamed.
        for (uint256 i = 0; i < workflowVersions.length; ++i) {
            if (workflowVersions[i].workflowId == workflowId_) revert WorkflowAlreadyPinned(workflowId_);
        }

        index_ = workflowVersions.length;
        uint64 activeFrom_ = uint64(block.timestamp + WORKFLOW_ACTIVATION_DELAY);
        workflowVersions.push(
            WorkflowVersion({workflowId: workflowId_, pinnedAt: uint64(block.timestamp), activeFrom: activeFrom_})
        );
        emit WorkflowPinned(workflowId_, index_, activeFrom_);
    }

    /**
     * @notice The workflow currently entitled to produce snapshots, or zero before the first one
     *         becomes active.
     * @dev FAILS OPEN TO THE LAST GOOD VERSION: a newly pinned version does not displace its
     *      predecessor until its delay elapses, so a swap cannot silence the registry in the
     *      meantime - inaction and a contested update both leave the previous version working.
     */
    function activeWorkflowId() public view returns (bytes32) {
        for (uint256 i = workflowVersions.length; i > 0; --i) {
            WorkflowVersion storage v_ = workflowVersions[i - 1];
            if (v_.activeFrom <= block.timestamp) return v_.workflowId;
        }
        return bytes32(0);
    }

    function workflowVersionCount() external view returns (uint256) {
        return workflowVersions.length;
    }

    /// @notice CRE report-callback entrypoint: decodes a (bytes32 registryId, bytes32[] leaves)
    /// payload and publishes it - but ONLY if the report says it came from the pinned workflow.
    ///
    /// @dev THE PIN IS ENFORCED HERE, AND UNTIL IT WAS, IT WAS NOT ENFORCED ANYWHERE. `metadata`
    /// carries the workflow ID, and this function used to discard it with the note "intentionally
    /// unused; `onlyRole(REGISTRY_POSTMAN)` already gates who may call this". That reasoning gates
    /// the CALLER and says nothing about the CODE: the Forwarder relays whatever the DON ran, so
    /// every report from every workflow arrived from the same authorised address, and
    /// `_publishSnapshot`'s check that SOME workflow is active is a LIVENESS test, not an IDENTITY
    /// one. A swapped workflow would have published successfully. Comparing the reported ID to the
    /// active pin is what makes `pinWorkflow` load-bearing rather than - in this contract's own
    /// words - decoration.
    ///
    /// AND IT IS NOW THE ONLY ENTRYPOINT. `publishSnapshot` was deleted (sec. 2.18ct): it did the
    /// same job MINUS this check, so it was simultaneously a duplicate mechanism and the one path no
    /// pin constrained. Removing it deletes a moving part and closes the bypass in one act - which is
    /// why it was the right answer rather than gating it harder.
    ///
    /// @dev Checks `onlyRole` on ITS OWN `msg.sender`, never via an external self-call - that would
    /// make the contract's own address the effective caller and silently require the CONTRACT to
    /// hold REGISTRY_POSTMAN instead of whoever invoked `onReport`.
    ///
    /// The metadata LAYOUT is now confirmed (see REPORT_METADATA_LENGTH) against the CRE SDK this
    /// repo depends on, rather than assumed. What is still unconfirmed is the Forwarder's calling
    /// convention itself - grant REGISTRY_POSTMAN to the Forwarder's on-chain address once that is
    /// verified, or to an operator key as a manual bootstrap in the meantime.
    function onReport(
        bytes calldata metadata,
        bytes calldata report
    ) external onlyRole(REGISTRY_POSTMAN) returns (uint256 index_, bytes32 root_) {
        // Length-checked before slicing: a short header would otherwise read whatever follows it,
        // and an identity check that compares the WRONG 32 bytes fails in exactly the direction
        // that looks like a healthy rejection.
        if (metadata.length < REPORT_METADATA_LENGTH) revert MalformedReportMetadata(metadata.length);

        bytes32 reported_ = bytes32(metadata[REPORT_WORKFLOW_ID_OFFSET:REPORT_WORKFLOW_ID_OFFSET + 32]);
        bytes32 active_ = activeWorkflowId();
        if (active_ == bytes32(0)) revert NoActiveWorkflow();
        if (reported_ != active_) revert UnpinnedWorkflow(reported_, active_);

        (bytes32 registryId_, bytes32[] memory leavesMem_) = abi.decode(report, (bytes32, bytes32[]));
        return _publishSnapshot(registryId_, leavesMem_);
    }

    /// @dev Kept separate from `onReport` so the authorization and the publication read as distinct
    /// steps. Takes `memory` because `onReport`'s array is already decoded.
    function _publishSnapshot(
        bytes32 registryId_,
        bytes32[] memory leaves_
    ) internal returns (uint256 index_, bytes32 root_) {
        // A PIN NOTHING CHECKS IS DECORATION. The whole point of naming the workflow is that
        // snapshots are attributable to auditable code, so publishing must be impossible until a
        // version is active. Without this line `pinWorkflow` would be a public statement of intent
        // with no bearing on what the anchor accepts - the shape sec. 2.18bg calls theatre.
        if (activeWorkflowId() == bytes32(0)) revert NoActiveWorkflow();

        root_ = _computeRoot(leaves_);

        snapshots[registryId_].push(RegistrySnapshot(root_, block.timestamp));
        index_ = snapshots[registryId_].length - 1;

        bytes32 statementKey_ = _statementKey(registryId_, index_);
        EVIDENCE_REGISTRY.addStatement(statementKey_, root_);

        emit SnapshotLeaves(registryId_, index_, leaves_);
        emit SnapshotAnchored(registryId_, root_, index_, statementKey_);
    }

    /// @notice Newest snapshot root for `registryId_`, regardless of activation delay
    /// (informational / dashboards only - verifiers must use `latestActiveRoot`).
    function latestRoot(bytes32 registryId_) external view returns (bytes32) {
        uint256 length_ = snapshots[registryId_].length;
        if (length_ == 0) revert NoSnapshotsAvailable();
        return snapshots[registryId_][length_ - 1].root;
    }

    /// @notice The newest snapshot whose activation delay has elapsed - what a verifier should
    /// check membership against. Mirrors Entrypoint.latestActiveRoot exactly.
    function latestActiveRoot(bytes32 registryId_) external view returns (bytes32) {
        RegistrySnapshot[] storage list_ = snapshots[registryId_];
        uint256 length_ = list_.length;
        if (length_ == 0) revert NoSnapshotsAvailable();
        for (uint256 i_ = length_; i_ > 0; --i_) {
            RegistrySnapshot storage snap_ = list_[i_ - 1];
            if (snap_.timestamp + ROOT_ACTIVATION_DELAY <= block.timestamp) return snap_.root;
        }
        revert NoActiveSnapshot();
    }

    function snapshotCount(bytes32 registryId_) external view returns (uint256) {
        return snapshots[registryId_].length;
    }

    /// @dev Keccak Merkle root over `leaves_`, OpenZeppelin-MerkleProof-compatible (each internal
    /// node hashes its children in sorted order, so proofs carry no left/right direction bits) -
    /// the exact algorithm backend/cre/notary_registry/main.go's `merkleRoot()` implements and
    /// TitleLedger.sol's `MerkleProof.verify` calls assume.
    function _computeRoot(bytes32[] memory leaves_) internal pure returns (bytes32) {
        uint256 n_ = leaves_.length;
        if (n_ == 0) revert EmptyLeafSet();

        bytes32[] memory level_ = new bytes32[](n_);
        for (uint256 i_ = 0; i_ < n_; ++i_) {
            if (i_ > 0 && leaves_[i_] <= leaves_[i_ - 1]) revert LeavesNotStrictlySorted();
            level_[i_] = leaves_[i_];
        }

        while (level_.length > 1) {
            uint256 len_ = level_.length;
            bytes32[] memory next_ = new bytes32[]((len_ + 1) / 2);
            for (uint256 i_ = 0; i_ < len_; i_ += 2) {
                next_[i_ / 2] = i_ + 1 < len_ ? _hashSortedPair(level_[i_], level_[i_ + 1]) : level_[i_];
            }
            level_ = next_;
        }
        return level_[0];
    }

    function _hashSortedPair(bytes32 a_, bytes32 b_) internal pure returns (bytes32) {
        return a_ < b_ ? keccak256(abi.encodePacked(a_, b_)) : keccak256(abi.encodePacked(b_, a_));
    }

    function _statementKey(bytes32 registryId_, uint256 index_) internal view returns (bytes32) {
        return
            bytes32(
                uint256(
                    keccak256(abi.encodePacked("REGISTRY_SOURCE_ROOT", registryId_, address(this), index_))
                ) % SNARK_SCALAR_FIELD
            );
    }
}
