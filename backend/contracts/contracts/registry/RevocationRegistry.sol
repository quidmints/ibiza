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

  /// @notice Every root this registry has ever had, so a proof built against a slightly stale root
  ///         still verifies. Append-only, exactly like the ASP tree in Entrypoint: accepting a
  ///         historical root is SAFE here for the same structural reason - the tree only grows, so
  ///         an old root can never re-admit someone who was revoked later. It cannot, and must not,
  ///         be used to un-revoke.
  mapping(bytes32 => bool) public isKnownRoot;

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

  /**
   * @param predicates_ the CLOSED set of revocation reasons. Cannot be changed afterwards.
   * @param attesters_  attesters_[i] is the only address that may cite predicates_[i].
   * @param treeHeight_ SMT depth. Must match the circuit's compiled depth or non-inclusion proofs
   *                    will not verify.
   */
  constructor(bytes32[] memory predicates_, address[] memory attesters_, uint32 treeHeight_) {
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

    isKnownRoot[_tree.getRoot()] = true; // the empty root is legitimately provable against
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
    isKnownRoot[root_] = true;
    revocationCount++;

    emit Revoked(holderRoot_, predicate_, msg.sender, root_);
  }

  function root() external view returns (bytes32) {
    return _tree.getRoot();
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
