// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

// Reverse-coupling interfaces: PP declares ONLY the functions it calls on SPV's deployed contracts,
// matching their real signatures exactly (confirmed by reading /home/rico/projects/SPV/evm/src/
// {Vogue,Basket}.sol directly, 2026-07-02). PP's repo does NOT import SPV's source, does NOT vendor
// SPV as a dependency, and SPV's repo has zero references to PP anywhere. PP is the party that knows
// about SPV's already-deployed, immutable addresses — never the reverse. See
// /home/rico/projects/app/ibiza/PP-SPV-BUFFER-DESIGN.md for the full architecture.

/// @notice The subset of SPV's Vogue.sol PP calls — a plain, permissionless ERC-4626-shaped ETH LP
/// interface (confirmed: no `onlyUs`, no allowlist gate on these two functions).
interface ISpvVogue {
    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares);
    function deposit(uint256 assets, address receiver, uint8 venue) external payable returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

/// @notice The subset of SPV's Basket.sol PP calls — permissionless collateralized mint (confirmed:
/// `external`, no `onlyUs`; the `auth(msg.sender)` branch only changes internal accounting for
/// protocol-internal callers, it does not gate external callers out).
interface ISpvBasket {
    function mint(
        address pledge,
        uint256 amount,
        address token,
        uint256 when
    ) external returns (uint256 normalized);
}
