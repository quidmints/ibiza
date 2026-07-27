// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice The minimal surface `PrivacyPool` needs from the append-only identity ASP tree.
/// @dev Kept narrow on purpose: the pool asks one question - "is this a root you actually
///      computed?" - and nothing else. See IdentityAspRegistry.sol for why the pool holds this
///      reference directly rather than reaching the tree through the upgradeable Entrypoint.
interface IIdentityAspRegistry {
  function isKnownAspRoot(uint256 _root) external view returns (bool);
  function latestAspRoot() external view returns (uint256 _root);
  function aspTreeSize() external view returns (uint256);
  function aspTreeDepth() external view returns (uint256);
  function admitIdentity(uint256 _holderRoot) external returns (uint256 _root);
}
