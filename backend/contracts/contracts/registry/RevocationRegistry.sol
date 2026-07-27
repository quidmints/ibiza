// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {SparseMerkleTree} from '@solarity/solidity-lib/libs/data-structures/SparseMerkleTree.sol';
import {PoseidonUnit2L, PoseidonUnit3L} from '../libraries/Poseidon.sol';

/**
 * @title RevocationRegistry
 * @notice Append-only registry of revoked identities. A withdrawal proves NON-INCLUSION here.
 *
 * WHY THIS IS NOT A PoseidonSMT. `contracts/state/PoseidonSMT.sol` already maintains a Poseidon
 * SMT, and reusing it was the obvious move - but it is `UUPSUpgradeable` and it exposes `remove`.
 * Either one defeats the entire point: the value of this registry is that NOBODY CAN REWRITE IT,
 * including us. An upgradeable revocation list is just a mutable one with extra steps, and a
 * removable entry means an operator can un-revoke silently. So this builds directly on the
 * SparseMerkleTree library instead and offers neither.
 *
 * THE THREE PROPERTIES, all structural rather than policy:
 *   1. APPEND-ONLY   - there is no `remove` and no `update`. Revoking is monotone.
 *   2. UNOWNED       - no owner, no roles, no admin. Nothing here is permissioned at deploy time
 *                      except the attesters fixed in the constructor.
 *   3. NON-UPGRADEABLE - not a proxy, no `_authorizeUpgrade`. The bytecode at this address is the
 *                      bytecode forever.
 *
 * THE PREDICATE SET IS IMMUTABLE AT DEPLOY (TODO.md sec. 2.5, decided). A revocation must cite a
 * predicate from a closed set fixed in the constructor - there is no setter and no owner to call
 * one. An owner-mutable predicate set would move discretion up a level rather than remove it,
 * which is the failure this design exists to avoid.
 *
 * WHAT THIS CONTRACT DOES NOT DECIDE: whether a cited predicate is TRUE. That is the attester's
 * job (an anchored external authority, e.g. the OFAC CRE workflow, or HolderStateKeeper's
 * DocStatus). This contract only enforces that some attester authorised for THAT predicate signed
 * off, and that the predicate is one of the ones this deployment was born with.
 */
contract RevocationRegistry {
  using SparseMerkleTree for SparseMerkleTree.Bytes32SMT;

  /// @notice The closed set of reasons an identity may be revoked, fixed at deploy.
  /// @dev Values are opaque to this contract; they are meaningful to the circuits and to the
  ///      attesters. Kept as bytes32 so a predicate can be a namespaced string hash.
  bytes32[] private _predicates;

  /// @dev predicate => attester allowed to cite it. One attester per predicate, set once.
  mapping(bytes32 => address) private _attesterOf;

  SparseMerkleTree.Bytes32SMT private _tree;

  /**
   * @notice When each root became current. A root is ACCEPTABLE only while it is the latest root
   *         or younger than MAX_ROOT_AGE - see `isValidRoot`.
   *
   * AN EARLIER VERSION OF THIS ACCEPTED EVERY HISTORICAL ROOT FOREVER, reasoning by analogy with
   * the append-only ASP tree in Entrypoint. THE ANALOGY IS INVERTED AND THE BUG WAS FATAL:
   *
   *   - The ASP tree proves INCLUSION. Append-only means an older root has FEWER members, so
   *     accepting one can only fail to admit somebody - never wrongly admit. Safe.
   *   - This tree proves NON-INCLUSION. Append-only means an older root has FEWER REVOCATIONS, so
   *     accepting one lets a revoked identity prove absence against a root that predates its own
   *     revocation. With unbounded history, anyone could prove non-revocation against the EMPTY
   *     INITIAL ROOT forever and revocation would be a complete no-op.
   *
   * Same data structure, opposite direction of use. Do not re-derive the old behaviour from the
   * Entrypoint precedent.
   */
  mapping(bytes32 => uint256) public rootCreatedAt;

  /**
   * @notice How long a superseded root stays acceptable.
   *
   * This is the whole fail-open/fail-closed tradeoff (TODO.md sec. 2.5), and it is bounded on both
   * sides deliberately:
   *   - Too short, and an in-flight proof is invalidated by an unrelated revocation landing first,
   *     which hands an attester a censorship lever: revoke anyone, and everyone's pending proofs
   *     die.
   *   - Too long, and a revoked identity keeps withdrawing for that long.
   * Immutable, like everything else here - there is no owner to tune it later.
   */
  uint256 public immutable MAX_ROOT_AGE;

  mapping(bytes32 => bool) public isRevoked;

  uint256 public revocationCount;

  event Revoked(bytes32 indexed holderRoot, bytes32 indexed predicate, address indexed attester, bytes32 root);

  error UnknownPredicate(bytes32 predicate);
  error NotTheAttester(bytes32 predicate, address caller);
  error AlreadyRevoked(bytes32 holderRoot);
  error EmptyHolderRoot();
  error DuplicatePredicate(bytes32 predicate);
  error NoPredicates();
  error AttesterIsZero(bytes32 predicate);
  error ZeroMaxRootAge();

  /**
   * @param predicates_ the CLOSED set of revocation reasons. Cannot be changed afterwards.
   * @param attesters_  attesters_[i] is the only address that may cite predicates_[i].
   * @param treeHeight_ SMT depth. Must match the circuit's compiled depth or non-inclusion proofs
   *                    will not verify.
   */
  constructor(
    bytes32[] memory predicates_,
    address[] memory attesters_,
    uint32 treeHeight_,
    uint256 maxRootAge_
  ) {
    if (maxRootAge_ == 0) revert ZeroMaxRootAge();
    MAX_ROOT_AGE = maxRootAge_;

    if (predicates_.length == 0) revert NoPredicates();
    require(predicates_.length == attesters_.length, 'RevocationRegistry: length mismatch');

    for (uint256 i = 0; i < predicates_.length; i++) {
      if (attesters_[i] == address(0)) revert AttesterIsZero(predicates_[i]);
      // A duplicate would silently make the LAST attester the effective one; reject instead.
      if (_attesterOf[predicates_[i]] != address(0)) revert DuplicatePredicate(predicates_[i]);
      _attesterOf[predicates_[i]] = attesters_[i];
      _predicates.push(predicates_[i]);
    }

    _tree.initialize(treeHeight_);
    _tree.setHashers(_hash2, _hash3);

    rootCreatedAt[_tree.getRoot()] = block.timestamp; // the empty root starts out current
  }

  /**
   * @notice Revoke `holderRoot_`, citing `predicate_`.
   * @dev Callable ONLY by the attester bound to that predicate at deploy. Monotone: a holderRoot
   *      can be revoked once and never un-revoked.
   */
  function revoke(bytes32 holderRoot_, bytes32 predicate_) external returns (bytes32 root_) {
    if (holderRoot_ == bytes32(0)) revert EmptyHolderRoot();

    address attester_ = _attesterOf[predicate_];
    if (attester_ == address(0)) revert UnknownPredicate(predicate_);
    if (msg.sender != attester_) revert NotTheAttester(predicate_, msg.sender);
    if (isRevoked[holderRoot_]) revert AlreadyRevoked(holderRoot_);

    isRevoked[holderRoot_] = true;
    // The leaf VALUE is the predicate, so the tree records not just that an identity was revoked
    // but under which rule - auditable after the fact without trusting the event log.
    _tree.add(holderRoot_, predicate_);

    root_ = _tree.getRoot();
    rootCreatedAt[root_] = block.timestamp;
    revocationCount++;

    emit Revoked(holderRoot_, predicate_, msg.sender, root_);
  }

  function root() external view returns (bytes32) {
    return _tree.getRoot();
  }

  /**
   * @notice Is `root_` acceptable to prove non-inclusion against?
   *
   * THE LATEST ROOT IS ALWAYS VALID, however old it is. That is what makes inaction harmless: if
   * no attester ever revokes again, the current root simply stays current and no withdrawal is
   * ever blocked. A pure age check WITHOUT this clause would be fail-CLOSED - the newest root
   * would age out and every withdrawal would halt, which is censorship through inaction and
   * exactly the property sec. 2.5 forbids.
   *
   * Superseded roots stay valid for MAX_ROOT_AGE so an in-flight proof is not invalidated by
   * someone else's revocation landing first.
   */
  function isValidRoot(bytes32 root_) public view returns (bool) {
    uint256 created_ = rootCreatedAt[root_];
    if (created_ == 0) return false; // never was a root here
    if (root_ == _tree.getRoot()) return true; // current: always valid, no expiry
    return block.timestamp <= created_ + MAX_ROOT_AGE;
  }

  function getProof(bytes32 holderRoot_) external view returns (SparseMerkleTree.Proof memory) {
    return _tree.getProof(holderRoot_);
  }

  function predicates() external view returns (bytes32[] memory) {
    return _predicates;
  }

  function attesterOf(bytes32 predicate_) external view returns (address) {
    return _attesterOf[predicate_];
  }

  function _hash2(bytes32 a_, bytes32 b_) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit2L.poseidon([uint256(a_), uint256(b_)]));
  }

  function _hash3(bytes32 a_, bytes32 b_, bytes32 c_) internal pure returns (bytes32) {
    return bytes32(PoseidonUnit3L.poseidon([uint256(a_), uint256(b_), uint256(c_)]));
  }
}
