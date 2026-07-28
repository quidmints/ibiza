// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {PoseidonUnit2L, PoseidonUnit3L} from '../libraries/Poseidon.sol';
import {INoirVerifier} from '../interfaces/verifiers/INoirVerifier.sol';
import {HolderStateKeeper} from '../holder/HolderStateKeeper.sol';

/**
 * @title IdentityRegistry
 * @notice The SINGLE identity tree (TODO.md sec. 2.13k). Key is the escrow commitment; the VALUE
 *         carries status: `0` = registered and clean, non-zero = the revocation predicate.
 *
 * WHY ONE TREE AND NOT TWO. A withdrawal used to prove ASP inclusion of `holder_root` AND
 * non-inclusion of the same value in a separate revocation tree. Encoding status in the value lets a
 * SINGLE INCLUSION PROOF of `commitment -> 0` do both jobs, which removes 43% of the withdrawal
 * circuit (43,772 -> 24,812 ACIR opcodes, measured). It also removes `sk_identity` from the
 * withdrawal entirely: identity is proven ONCE, at escrow.
 *
 * ONE CONTROLLER for this list and the label list alike - a single party decides both, so splitting
 * the authority across contracts would have been a fiction.
 *
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 * THE TRAPS THIS DESIGN CREATES, AND WHERE EACH IS CLOSED. Merging two trees with OPPOSITE
 * semantics surrenders structural protections the split gave for free, so each is now an explicit
 * guard with a test rather than a property of the shape.
 *
 * 1. ROOT EXPIRY IS MANDATORY HERE, where an inclusion-only tree would need none.
 *    An inclusion tree is safe to prove against forever - an old root has FEWER members, so a
 *    stale root can only ever under-approve. This tree also carries REVOCATIONS, and an old root
 *    has fewer of THOSE, so a revoked identity could prove `commitment -> 0` against a
 *    pre-revocation root FOREVER. `isValidRoot` therefore enforces MAX_ROOT_AGE, with the latest
 *    root always valid so inaction stays harmless.
 *
 * 2. A ZERO PREDICATE WOULD REVOKE SOMEONE INTO CLEANLINESS.
 *    Zero IS the clean sentinel. `revoke` rejects a zero predicate outright.
 *
 * 3. `remove` MUST NEVER BE REACHABLE.
 *    The solarity Bytes32SMT offers `add`, `update` AND `remove`. Removing a registration is
 *    censorship by erasure - the "postman can drop an existing member" failure the append-only
 *    design exists to prevent. Only `add` and `update` are called anywhere in this file.
 *
 * 4. TWO WRITERS ON ONE TREE.
 *    `register` is PERMISSIONLESS (gated by a proof, not a role); `revoke` is controller-only.
 *    Both paths are single-purpose and neither can perform the other's write.
 *
 * 5. AN ESCROW PROOF DOES NOT PROVE THE PASSPORT IS REAL - and this is the subtlest of them.
 *    `escrow_envelope` proves an MRZ hashes to `dg1_hash` and that `holder_root` derives from
 *    `sk_identity`. It CANNOT prove the document is genuine, because the ICAO signature chain is
 *    verified during REGISTRATION. Taken alone, a caller could invent an MRZ, escrow against it and
 *    land a commitment backed by nothing - making the tree's scarcity guarantee, and therefore the
 *    whole blacklist, worthless. `register` closes this by requiring the state keeper to already
 *    bind that `dg1Hash` to that `holderRoot`.
 * ─────────────────────────────────────────────────────────────────────────────────────────────
 *
 * NON-UPGRADEABLE and UNOWNED, for the same reasons RevocationRegistry is: an upgradeable identity
 * gate is a mutable one with extra steps.
 */
contract IdentityRegistry {
  using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

  /// Public-input layout of `escrow_envelope`. Order is pinned by the circuit's `main` signature;
  /// a mismatch here reads the wrong field while the proof still verifies.
  uint256 internal constant PUB_CONTROLLER_X = 0;
  uint256 internal constant PUB_CONTROLLER_Y = 1;
  uint256 internal constant PUB_HOLDER_ROOT = 2;
  uint256 internal constant PUB_COMMITMENT = 3;
  uint256 internal constant PUB_DG1_HASH = 4;
  uint256 internal constant PUB_C1_X = 5;
  uint256 internal constant PUB_C1_Y = 6;
  uint256 internal constant PUB_SEALED_0 = 7;
  uint256 internal constant PUBLIC_INPUT_COUNT = 12;

  INoirVerifier public immutable ESCROW_VERIFIER;
  HolderStateKeeper public immutable STATE_KEEPER;

  /// The only party that may revoke. Also controls the label list - see the header.
  address public immutable CONTROLLER;

  /// The controller's Baby Jubjub sealing key. Pinned so an envelope cannot be sealed to a key the
  /// controller does not hold, which would produce a registration nobody could ever revoke.
  uint256 public immutable CONTROLLER_KEY_X;
  uint256 public immutable CONTROLLER_KEY_Y;

  uint256 public immutable MAX_ROOT_AGE;

  SparseMerkleTree.Bytes32SMT private _tree;

  mapping(bytes32 _root => uint256 _createdAt) public rootCreatedAt;
  mapping(bytes32 _commitment => bool _registered) public registered;
  mapping(bytes32 _commitment => bytes32 _predicate) public statusOf;
  mapping(bytes32 _predicate => bool _allowed) public isPredicate;

  bytes32[] private _predicates;
  uint256 public registeredCount;
  uint256 public revokedCount;

  event IdentityRegistered(bytes32 indexed commitment, bytes32 root, uint256 c1x, uint256 c1y, uint256[5] sealedPayload);
  event IdentityRevoked(bytes32 indexed commitment, bytes32 indexed predicate, bytes32 root);

  error AlreadyRegistered(bytes32 commitment);
  error NotRegistered(bytes32 commitment);
  error AlreadyRevoked(bytes32 commitment);
  error BadProof();
  error WrongPublicInputCount(uint256 got);
  error WrongControllerKey();
  error DocumentNotRegistered(bytes32 dg1Hash);
  error DocumentBoundToAnotherHolder(bytes32 dg1Hash);
  error NotTheController(address caller);
  error ZeroPredicate();
  error UnknownPredicate(bytes32 predicate);
  error NoPredicates();
  error ZeroAddress();

  constructor(
    address escrowVerifier_,
    address stateKeeper_,
    address controller_,
    uint256 controllerKeyX_,
    uint256 controllerKeyY_,
    uint32 treeHeight_,
    uint256 maxRootAge_,
    bytes32[] memory predicates_
  ) {
    if (escrowVerifier_ == address(0) || stateKeeper_ == address(0) || controller_ == address(0)) {
      revert ZeroAddress();
    }
    if (predicates_.length == 0) revert NoPredicates();

    ESCROW_VERIFIER = INoirVerifier(escrowVerifier_);
    STATE_KEEPER = HolderStateKeeper(stateKeeper_);
    CONTROLLER = controller_;
    CONTROLLER_KEY_X = controllerKeyX_;
    CONTROLLER_KEY_Y = controllerKeyY_;
    MAX_ROOT_AGE = maxRootAge_;

    for (uint256 i = 0; i < predicates_.length; i++) {
      // Trap 2: zero is the CLEAN sentinel, so admitting it as a predicate would let a revocation
      // write the clean state. Rejected at deploy rather than only at call time.
      if (predicates_[i] == bytes32(0)) revert ZeroPredicate();
      isPredicate[predicates_[i]] = true;
      _predicates.push(predicates_[i]);
    }

    _tree.initialize(treeHeight_);
    _tree.setHashers(_h2, _h3);

    rootCreatedAt[_tree.getRoot()] = block.timestamp;
  }

  /**
   * @notice Register an identity by posting its sealed escrow envelope. PERMISSIONLESS.
   * @dev Gated by a proof, never by a role - an approval step would hand back the
   *      censorship-by-inaction lever this whole design removes.
   */
  function register(bytes calldata proof_, bytes32[] calldata publicInputs_) external returns (bytes32 root_) {
    if (publicInputs_.length != PUBLIC_INPUT_COUNT) revert WrongPublicInputCount(publicInputs_.length);

    // Trap 5: the envelope must be sealed to THIS controller's key, or it is unreadable by the only
    // party that could ever act on it - a registration nobody can revoke.
    if (
      uint256(publicInputs_[PUB_CONTROLLER_X]) != CONTROLLER_KEY_X
        || uint256(publicInputs_[PUB_CONTROLLER_Y]) != CONTROLLER_KEY_Y
    ) revert WrongControllerKey();

    if (!ESCROW_VERIFIER.verify(proof_, publicInputs_)) revert BadProof();

    bytes32 commitment_ = publicInputs_[PUB_COMMITMENT];
    bytes32 holderRoot_ = publicInputs_[PUB_HOLDER_ROOT];
    bytes32 dg1Hash_ = publicInputs_[PUB_DG1_HASH];

    // Trap 5, the substantive half: the escrow proof shows the MRZ hashes to dg1Hash, NOT that the
    // passport is genuine - the ICAO chain is checked at registration. Require that registration to
    // have happened, for THIS holder.
    bytes32 boundHolder_ = STATE_KEEPER.holderOfDocumentHash(dg1Hash_);
    if (boundHolder_ == bytes32(0)) revert DocumentNotRegistered(dg1Hash_);
    if (boundHolder_ != holderRoot_) revert DocumentBoundToAnotherHolder(dg1Hash_);

    // `_tree.add` would revert with KeyAlreadyExists anyway; this gives the real reason, and stops a
    // re-add from being attempted against a REVOKED commitment.
    if (registered[commitment_]) revert AlreadyRegistered(commitment_);

    registered[commitment_] = true;
    registeredCount++;

    // Value 0: registered and clean. Verified end-to-end - the on-chain root for a zero-valued leaf
    // matches what the Noir gadget computes (test/registry/SmtCompat.t.sol).
    _tree.add(commitment_, bytes32(0));

    root_ = _tree.getRoot();
    rootCreatedAt[root_] = block.timestamp;

    uint256[5] memory sealed_;
    for (uint256 i = 0; i < 5; i++) {
      sealed_[i] = uint256(publicInputs_[PUB_SEALED_0 + i]);
    }
    emit IdentityRegistered(
      commitment_, root_, uint256(publicInputs_[PUB_C1_X]), uint256(publicInputs_[PUB_C1_Y]), sealed_
    );
  }

  /**
   * @notice Revoke a registered identity, citing a predicate. Controller only.
   * @dev Monotone: `statusOf` moves 0 -> predicate once and never back. There is deliberately no
   *      un-revoke; correcting a mistaken revocation is a governance problem, not a setter.
   */
  function revoke(bytes32 commitment_, bytes32 predicate_) external returns (bytes32 root_) {
    if (msg.sender != CONTROLLER) revert NotTheController(msg.sender);
    if (predicate_ == bytes32(0)) revert ZeroPredicate();
    if (!isPredicate[predicate_]) revert UnknownPredicate(predicate_);
    if (!registered[commitment_]) revert NotRegistered(commitment_);
    if (statusOf[commitment_] != bytes32(0)) revert AlreadyRevoked(commitment_);

    statusOf[commitment_] = predicate_;
    revokedCount++;

    // UPDATE, not add - and never `remove` (trap 3). The predicate becomes the leaf value, so the
    // tree records WHY, not merely that, an identity was revoked.
    _tree.update(commitment_, predicate_);

    root_ = _tree.getRoot();
    rootCreatedAt[root_] = block.timestamp;

    emit IdentityRevoked(commitment_, predicate_, root_);
  }

  function root() external view returns (bytes32) {
    return _tree.getRoot();
  }

  /**
   * @notice Is `root_` acceptable to prove `commitment -> 0` against?
   *
   * THE LATEST ROOT IS ALWAYS VALID however old it is, so a controller that never acts again blocks
   * nobody - inaction stays harmless. Superseded roots stay valid for MAX_ROOT_AGE so an in-flight
   * proof is not invalidated by someone else's registration landing first.
   *
   * EXPIRY IS REQUIRED HERE (trap 1). This tree carries revocations, so an unbounded-age root would
   * let a revoked identity prove the clean state against a pre-revocation root forever. Note this
   * tree changes on EVERY registration, not only on revocations, so roots churn far faster than
   * RevocationRegistry's - MAX_ROOT_AGE is time-based, so that is a matter of more stored roots,
   * not of correctness.
   */
  function isValidRoot(bytes32 root_) public view returns (bool) {
    // The EMPTY tree's root is literally zero, and the constructor records it, so without this the
    // zero root reads as valid. Nothing can actually be proven against an empty root - an inclusion
    // path always ends at a non-zero leaf hash - so this is defence in depth rather than a live
    // hole, but State.sol's `_isKnownRoot` already rejects zero and the two should not disagree
    // about what a zero root means.
    if (root_ == bytes32(0)) return false;

    uint256 created_ = rootCreatedAt[root_];
    if (created_ == 0) return false;
    if (root_ == _tree.getRoot()) return true;
    return block.timestamp <= created_ + MAX_ROOT_AGE;
  }

  function getProof(bytes32 commitment_) external view returns (SparseMerkleTree.Proof memory) {
    return _tree.getProof(commitment_);
  }

  function predicates() external view returns (bytes32[] memory) {
    return _predicates;
  }

  function _h2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit2L.poseidon([uint256(a), uint256(b)]));
  }

  function _h3(bytes32 a, bytes32 b, bytes32 c) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit3L.poseidon([uint256(a), uint256(b), uint256(c)]));
  }
}
