// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

// Reverse-coupling interfaces: PP declares ONLY the functions it calls on SPV's deployed contracts,
// matching their real signatures exactly (re-confirmed against SPV HEAD 2026-07-26 — all four
// signatures below still match). PP's repo does NOT import SPV's source and SPV's repo has zero
// references to PP anywhere. PP is the party that knows about SPV's already-deployed, immutable
// addresses — never the reverse. See ../../../../PP-SPV-BUFFER-DESIGN.md for the full architecture.
//
// SPV is now also present as a pinned git submodule at backend/contracts/lib/SPV (tracking its
// `main`), for reference only — nothing here imports it, and this file must stay a standalone
// declaration so the reverse-coupling property holds. SPV commits daily: RE-VERIFY these signatures
// immediately before wiring real addresses, per §2.10.

/// @notice The subset of SPV's Vogue.sol PP calls — a plain, permissionless ERC-4626-shaped ETH LP
/// interface (confirmed: no `onlyUs`, no allowlist gate on these two functions).
interface ISpvVogue {
    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares);
    function deposit(uint256 assets, address receiver, uint8 venue) external payable returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

/// @notice The subset of SPV's Basket.sol PP calls — collateralized mint.
///
/// ACCESS CONTROL is permissionless (confirmed: `external`, no `onlyUs`; the `auth(msg.sender)`
/// branch only changes internal accounting for protocol-internal callers, it does not gate external
/// callers out).
///
/// TOKEN ACCEPTANCE IS NOT. An earlier version of this comment said "permissionless collateralized
/// mint" without qualification, which wrongly implied any token is accepted. `Basket.mint` enforces
/// a hard, deploy-time-fixed whitelist of the basket stables (checked via `Aux.toIndex` /
/// `aux.tokens`) — an arbitrary ERC20 reverts. Confirm the intended token is in that set before
/// wiring this up; see §2.10.
interface ISpvBasket {
    function mint(
        address pledge,
        uint256 amount,
        address token,
        uint256 when
    ) external returns (uint256 normalized);
}
