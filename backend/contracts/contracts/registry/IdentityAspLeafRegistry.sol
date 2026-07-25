// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice On-chain data-availability log for the identity-based ASP tree's leaf set (see
/// backend/circuits/pp/src/identity_asp.nr and frontend/identity-wallet/src/postman/
/// identityAsp.ts). Entrypoint.sol (pre-existing, unmodified by this fusion) still anchors the
/// ASP root itself via `updateRoot(uint256 root, string ipfsCID)` - this contract does not
/// replace or re-verify that root, it only makes the leaf set behind it permanently, publicly
/// available WITHOUT depending on an external pinning service. `postman/identityAsp.ts` calls
/// this alongside `Entrypoint.updateRoot`, in place of relying on `_ipfsCID` for real data
/// availability (that field is left populated with a locator string pointing at this contract,
/// since Entrypoint.sol enforces a 32-64 byte length on it and can't be changed to accept
/// nothing - see publishIdentityAspRoot's own comment).
///
/// UNLIKE RegistrySourceAnchor (the notary registry's anchor), this contract does NOT
/// recompute/verify a root from the leaves on-chain. RegistrySourceAnchor's tree is keccak-hashed
/// (cheap on-chain, and that tree isn't ZK-circuit-consumed); the identity ASP tree is
/// Poseidon-hashed (`pp::lean_imt`, matching what `identity_asp_membership`'s Noir circuit
/// actually verifies against) - recomputing Poseidon over a potentially large leaf set purely for
/// on-chain verification is real, avoidable gas cost this contract chooses not to force, given
/// Entrypoint.updateRoot already trusts the same off-chain root computation unconditionally today
/// (unchanged - this contract doesn't weaken that existing trust model, it only adds genuine data
/// availability on top of it, replacing an external pinning dependency).
///
/// @dev Deliberately NOT upgradeable, unlike RegistrySourceAnchor/TitleLedger (this codebase's
/// usual pattern for record-holding registry contracts). Those are upgradeable because they hold
/// real trust-sensitive state behind role-gated writes, and an owner needs a path to patch bugs.
/// This contract has no access control and makes no trust claim at all - its entire value is
/// being a permissionless, unowned log nobody can rewrite or censor. Adding an upgrade owner here
/// would introduce a trust surface that directly contradicts that design, not preserve
/// consistency with it - so the plain (non-upgradeable) constructor pattern, same as PP's
/// fund-custody PrivacyPool/State, is the correct choice for a different but equally deliberate
/// reason (no owner to trust, vs. no owner to trust with funds).
contract IdentityAspLeafRegistry {
    event LeavesPublished(bytes32 indexed root, bytes32[] leaves);

    mapping(bytes32 => bool) public published;

    error AlreadyPublished();
    error EmptyLeafSet();

    /// @notice Record the leaf set behind a given ASP root (Entrypoint's `_root`, cast to
    /// bytes32). Deliberately NOT role-gated, unlike RegistrySourceAnchor: this contract makes no
    /// trust claim of its own, so there is nothing to gate. A consumer (e.g. a wallet building
    /// its own inclusion proof) always independently recomputes the Poseidon root from `leaves_`
    /// and compares it against Entrypoint's real, already-anchored root before trusting anything
    /// published here - a caller publishing an unrelated or wrong leaf set under a real root
    /// simply produces a publication nobody's reconstruction will match, and wastes their own gas
    /// doing it.
    function publishLeaves(bytes32 root_, bytes32[] calldata leaves_) external {
        if (leaves_.length == 0) revert EmptyLeafSet();
        if (published[root_]) revert AlreadyPublished();
        published[root_] = true;
        emit LeavesPublished(root_, leaves_);
    }
}
