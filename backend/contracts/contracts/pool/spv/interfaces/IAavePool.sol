// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice Minimal slice of Aave V3's real `IPool` interface (the de facto standard shape shared
/// by Aave itself and most of its forks) - only the four functions AaveCreditLine actually calls.
/// Vendoring the full Aave core-v3 npm package would pull in a large, mostly-unused surface for
/// four function signatures; this mirrors the same "vendor only what's used" call this codebase
/// already made for `SetHelper.sol` (see its own header comment).
interface IAavePool {
    /// @notice Supplies `amount` of `asset` as collateral on behalf of `onBehalfOf`.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Withdraws up to `amount` of previously-supplied `asset` to `to`. Reverts if it would
    /// leave the account's health factor below the liquidation threshold.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Borrows `amount` of `asset` against posted collateral, sent to `onBehalfOf`'s debt
    /// balance (variable-rate mode = 2, the only mode Aave V3 keeps).
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;

    /// @notice Repays `amount` of `asset` debt owed by `onBehalfOf`. Returns the actual amount repaid.
    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256);
}
