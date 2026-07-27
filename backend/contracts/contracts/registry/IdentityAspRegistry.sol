// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {InternalLeanIMT, LeanIMTData} from 'lean-imt/InternalLeanIMT.sol';
import {EIP712} from '@oz/utils/cryptography/EIP712.sol';
import {ECDSA} from '@oz/utils/cryptography/ECDSA.sol';
import {IEvidenceRegistry} from '@rarimo/evidence-registry/interfaces/IEvidenceRegistry.sol';

import {Constants} from '../pool/lib/Constants.sol';

/**
 * @title IdentityAspRegistry
 * @notice The append-only identity ASP tree. A withdrawal proves INCLUSION here.
 *
 * WHY THIS IS NOT PART OF `Entrypoint` ANY MORE (TODO.md sec. 2.5a).
 *
 * The tree used to live in `Entrypoint`, and sec. 2.13 claimed the append-only construction meant
 * "the postman can no longer drop an existing member". That was true of the POSTMAN and false of
 * the system: `Entrypoint._authorizeUpgrade` is `onlyRole(_OWNER_ROLE)`, so the owner could upgrade
 * the implementation and rewrite the tree wholesale. The guarantee was really "append-only unless
 * the owner upgrades", which is not a guarantee.
 *
 * A PASS-THROUGH WOULD NOT HAVE FIXED IT. Leaving `isKnownAspRoot` on `Entrypoint` to delegate here
 * would preserve the whole vulnerability: `PrivacyPool` would still be asking an upgradeable
 * contract whether a root is genuine, and an upgraded `Entrypoint` could simply lie. So
 * `PrivacyPool` holds a reference to THIS contract directly, and `Entrypoint` is out of the ASP
 * trust path entirely. It remains upgradeable for asset config and routing, where that is
 * legitimate.
 *
 * PROPERTIES, all structural:
 *   - APPEND-ONLY: `_insert` is the only mutation. No remove, no update, no root override.
 *   - NON-UPGRADEABLE: not a proxy, no `_authorizeUpgrade`.
 *   - NO OWNER: no roles, no admin. The postman is fixed at construction and cannot be changed.
 *
 * WHY ACCEPTING EVERY HISTORICAL ROOT IS CORRECT HERE - AND WRONG IN `RevocationRegistry`.
 * This tree proves INCLUSION, and it only grows, so an older root has FEWER members: accepting one
 * can only fail to admit somebody who was added later. It can never wrongly admit. `isKnownAspRoot`
 * therefore has no expiry, and that is what removes the operator's retroactive lever - a member
 * admitted once can always prove membership, even against a root published years ago.
 *
 * `RevocationRegistry` proves NON-INCLUSION, where the same rule is fatal: an older root has fewer
 * REVOCATIONS, so unbounded history would let a revoked identity prove absence forever. Same data
 * structure, opposite direction of use. Do not copy this contract's root policy over to that one.
 *
 * POSTMAN IMMUTABILITY HAS A COST: a compromised postman key cannot be rotated, and the postman
 * could spam admissions (it cannot remove anyone, so the damage is bounded to admitting parties who
 * should not have been admitted). DEPLOY THE POSTMAN AS A CONTRACT (multisig/threshold), NEVER AN
 * EOA - this only checks `msg.sender` and a signature, so an attester contract can rotate its own
 * keys internally while this registry stays immutable.
 */
contract IdentityAspRegistry is EIP712 {
  using InternalLeanIMT for LeanIMTData;

  /// @notice The only address that may admit identities. Immutable - there is no setter.
  address public immutable POSTMAN;

  /// @notice ERC-7812 evidence registry the roots are anchored in. Tamper-evident and
  ///         independently timestamped; the anchoring was never the weak part of the old design.
  IEvidenceRegistry public immutable EVIDENCE_REGISTRY;

  LeanIMTData internal _aspTree;

  /// @notice root => timestamp it was created. Never cleared - see the header for why unbounded
  ///         history is correct for an INCLUSION tree.
  mapping(uint256 _root => uint256 _createdAt) public aspRootCreatedAt;

  mapping(uint256 _holderRoot => bool _admitted) public aspAdmitted;

  bytes32 private constant _ADMIT_TYPEHASH =
    keccak256('AdmitIdentity(uint256 holderRoot,uint256 deadline)');

  event IdentityAdmitted(uint256 _holderRoot, uint256 _root, uint256 _index);

  error EmptyRoot();
  error LeafOutOfField();
  error AlreadyAdmitted();
  error NotPostman();
  error AuthorizationExpired();
  error InvalidAuthorization();
  error NoRootsAvailable();
  error PostmanIsZero();

  constructor(address _postman, address _evidenceRegistry) EIP712('IdentityAspRegistry', '1') {
    if (_postman == address(0)) revert PostmanIsZero();
    POSTMAN = _postman;
    EVIDENCE_REGISTRY = IEvidenceRegistry(_evidenceRegistry);
  }

  /// @notice Admit a cleared identity. Insert-only.
  function admitIdentity(uint256 _holderRoot) external returns (uint256 _root) {
    if (msg.sender != POSTMAN) revert NotPostman();
    _root = _admitIdentity(_holderRoot);
  }

  /**
   * @notice Admit using an off-chain postman signature, so anyone can pay the gas.
   * @dev Does NOT widen the postman's power: `_admitIdentity` can only ever INSERT, and
   *      `aspAdmitted` makes a replayed signature revert rather than perturb the tree.
   */
  function admitIdentityWithAuthorization(
    uint256 _holderRoot,
    uint256 _deadline,
    bytes calldata _signature
  ) external returns (uint256 _root) {
    if (block.timestamp > _deadline) revert AuthorizationExpired();

    bytes32 _digest =
      _hashTypedDataV4(keccak256(abi.encode(_ADMIT_TYPEHASH, _holderRoot, _deadline)));
    if (ECDSA.recover(_digest, _signature) != POSTMAN) revert InvalidAuthorization();

    _root = _admitIdentity(_holderRoot);
  }

  /// @dev The ONLY writer of the tree.
  function _admitIdentity(uint256 _holderRoot) internal returns (uint256 _root) {
    // LeanIMT reserves 0 as "empty sibling"; a zero leaf would corrupt inclusion proofs.
    if (_holderRoot == 0) revert EmptyRoot();
    if (_holderRoot >= Constants.SNARK_SCALAR_FIELD) revert LeafOutOfField();
    if (aspAdmitted[_holderRoot]) revert AlreadyAdmitted();

    aspAdmitted[_holderRoot] = true;
    _root = _aspTree._insert(_holderRoot);

    uint256 _index = _aspTree.size - 1;
    aspRootCreatedAt[_root] = block.timestamp;

    EVIDENCE_REGISTRY.addStatement(_aspStatementKey(_index), bytes32(_root));

    emit IdentityAdmitted(_holderRoot, _root, _index);
  }

  function isKnownAspRoot(uint256 _root) external view returns (bool) {
    return aspRootCreatedAt[_root] != 0;
  }

  function latestAspRoot() external view returns (uint256 _root) {
    if (_aspTree.size == 0) revert NoRootsAvailable();
    _root = _aspTree._root();
  }

  function aspTreeSize() external view returns (uint256) {
    return _aspTree.size;
  }

  function aspTreeDepth() external view returns (uint256) {
    return _aspTree.depth;
  }

  function _aspStatementKey(uint256 _index) internal view returns (bytes32) {
    return bytes32(
      uint256(keccak256(abi.encodePacked('PP_ASP_ROOT', address(this), _index)))
        % Constants.SNARK_SCALAR_FIELD
    );
  }
}
