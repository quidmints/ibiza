// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

/// @notice Minimal abstraction over an EXTERNAL, SPV-independent collateralized credit line (e.g. a
/// real Aave/Morpho/Euler borrow position PP opens with its own posted collateral). This is the
/// backstop primitive: draw instantly against posted collateral, repay whenever the next scheduled
/// venue reclaim lands. Deliberately NOT SPV's `_deleverFlash` (that's an atomic same-transaction
/// Morpho flash loan — confirmed the wrong shape; it cannot persist a debt across transactions).
///
/// STATUS: interface only. Wiring this to a real Aave/Morpho pool is separate, unstarted work — see
/// PP-SPV-BUFFER-DESIGN.md §4. `SpvTreasuryAdapter` is written against this abstraction so that work
/// can land later without touching the buffer/sweep logic that's already built and tested.
interface ICreditLine {
    /// @notice Borrow `amount` instantly against already-posted collateral. Reverts if the line lacks
    /// capacity (e.g. insufficient collateral, LTV cap, or paused).
    function borrow(uint256 amount, address receiver) external returns (uint256 borrowed);

    /// @notice Repay outstanding debt with the attached native ETH value. Any amount up to the
    /// caller's balance; excess is a no-op revert upstream (the adapter never attempts to repay more
    /// than it owes).
    function repay(uint256 amount) external payable returns (uint256 repaid);

    /// @notice Current outstanding debt owed by this contract on the credit line.
    function debtOf(address borrower) external view returns (uint256);
}
