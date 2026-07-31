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
    bytes32 public constant REGISTRY_POSTMAN = keccak256("REGISTRY_POSTMAN");
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

    /// Same window Entrypoint.sol uses for ASP roots - gives verifiers/watchers a chance to catch
    /// a bad snapshot before anything can be proven against it.
    uint256 public constant ROOT_ACTIVATION_DELAY = 1 hours;

    /**
     * How long a newly pinned workflow waits before snapshots may cite it (sec. 2.18bs).
     *
     * THE ONE THING A TIMELOCK IS ACTUALLY FOR HERE. Once each DON node verifies the register's TLS
     * session inside the workflow, fabricated DATA becomes impossible rather than merely detectable -
     * so the snapshot path needs no contest window. **A workflow SWAP cannot be prevented
     * cryptographically, only seen**, so this is where a delay earns its keep: it is the interval in
     * which a malicious version is visible and contestable BEFORE anything relies on it. Without it
     * the update mechanism is a same-block censorship lever.
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

    function publishSnapshot(
        bytes32 registryId_,
        bytes32[] calldata leaves_
    ) external onlyRole(REGISTRY_POSTMAN) returns (uint256 index_, bytes32 root_) {
        return _publishSnapshot(registryId_, leaves_);
    }

    /// @notice CRE report-callback entrypoint: decodes a (bytes32 registryId, bytes32[] leaves)
    /// payload and publishes it, same as calling `publishSnapshot` directly. `metadata` (CRE's
    /// report metadata - workflow ID, execution ID) is intentionally unused; nothing here needs
    /// it, since `onlyRole(REGISTRY_POSTMAN)` already gates who may call this.
    ///
    /// @dev Checks `onlyRole` directly on ITS OWN `msg.sender` (does not route through
    /// `publishSnapshot` via `this.` - an external self-call would make the contract's own
    /// address the effective caller for role-checking purposes, silently requiring the CONTRACT
    /// ITSELF to hold REGISTRY_POSTMAN instead of whoever actually invoked `onReport`). Both
    /// entrypoints share `_publishSnapshot`, which does no authorization of its own by design -
    /// that's each public entrypoint's own job.
    ///
    /// NOT yet wired to Chainlink's actual KeystoneForwarder/IReceiver trust model - the exact
    /// selector/interface a CRE Forwarder invokes on a receiver should be confirmed against
    /// current Chainlink CRE docs before relying on Forwarder-triggered calls in production. Today
    /// this is safe regardless of how it's invoked, because `onlyRole(REGISTRY_POSTMAN)` is the
    /// actual trust boundary: grant that role to the Forwarder's on-chain address once confirmed,
    /// or to an operator key as a manual bootstrap in the meantime - both paths are equally valid
    /// callers of this same function.
    function onReport(
        bytes calldata /* metadata */,
        bytes calldata report
    ) external onlyRole(REGISTRY_POSTMAN) returns (uint256 index_, bytes32 root_) {
        (bytes32 registryId_, bytes32[] memory leavesMem_) = abi.decode(report, (bytes32, bytes32[]));
        return _publishSnapshot(registryId_, leavesMem_);
    }

    /// @dev Shared logic for both entrypoints above - deliberately NOT role-gated itself; each
    /// caller checks `onlyRole(REGISTRY_POSTMAN)` against its own real `msg.sender` before
    /// reaching here. Takes `memory` (not `calldata`) so `onReport`'s already-decoded array can be
    /// passed straight through - `publishSnapshot`'s calldata argument is auto-copied to memory at
    /// the call site, which is the normal, correct way to bridge the two without a second
    /// `_computeRoot` implementation or an unnecessary external self-call.
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
