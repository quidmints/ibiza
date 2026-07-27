// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice The minimal surface `PrivacyPool` needs from the append-only revocation list.
/// @dev `isValidRoot`, NOT an "isKnown"-style predicate. This tree proves NON-inclusion, so an
///      older root has FEWER revocations and honouring one indefinitely would let a revoked
///      identity prove absence forever. The registry bounds that while keeping the LATEST root
///      valid regardless of age, so attester inaction cannot block a withdrawal.
interface IRevocationRegistry {
  function isValidRoot(bytes32 _root) external view returns (bool);
  function root() external view returns (bytes32);
  function isRevoked(bytes32 _holderRoot) external view returns (bool);
}
