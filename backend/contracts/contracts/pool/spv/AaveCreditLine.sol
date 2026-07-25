// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Ownable} from "@oz/access/Ownable.sol";
import {ReentrancyGuardTransient} from "@oz/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@oz/interfaces/IERC20.sol";
import {SafeERC20} from "@oz/token/ERC20/utils/SafeERC20.sol";

import {ICreditLine} from "./ICreditLine.sol";
import {IAavePool} from "./interfaces/IAavePool.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/// @notice Real ICreditLine implementation: PP posts ETH collateral once (wrapped to WETH,
/// supplied to a real Aave V3 pool), then a single designated caller (SpvTreasuryAdapter) can
/// draw/repay native-ETH debt against it instantly, across transactions - the actual backstop
/// primitive ICreditLine.sol's header describes, not a mock.
///
/// Deliberately generic over WHICH Aave V3 pool / WETH address: neither is hardcoded, both are
/// constructor params. SPV has not deployed to mainnet yet (confirmed 2026-07-25 - its own
/// deploy/PRODUCTION-LAUNCH.md pre-mainnet gates are still unchecked), so the target chain isn't
/// known yet either - hardcoding a specific chain's Aave Pool/WETH address here would be a guess,
/// not a fact. Deploy this with whichever chain's real addresses apply once that's decided.
///
/// Debt is tracked locally (principal drawn via THIS contract, not Aave's own accruing variable
/// debt token balance) - accurate for "how much has SpvTreasuryAdapter borrowed through this
/// credit line," which is what debtOf() is for (see SpvTreasuryAdapter's own outstandingDebt
/// tracking, which this mirrors). If interest-inclusive debt is ever needed, that requires
/// reading the reserve's variableDebtTokenAddress via IPool.getReserveData - a materially larger
/// interface surface, not added speculatively.
contract AaveCreditLine is ICreditLine, Ownable, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    IAavePool public immutable POOL;
    IWETH public immutable WETH;
    address public immutable CALLER; // the one contract allowed to borrow/repay (SpvTreasuryAdapter)

    uint256 internal constant VARIABLE_RATE_MODE = 2; // Aave V3's only remaining rate mode

    uint256 public debt;

    error OnlyCaller();
    error ZeroAddress();
    error ZeroAmount();
    error ValueMismatch();
    error RepayExceedsDebt();

    modifier onlyCaller() {
        if (msg.sender != CALLER) revert OnlyCaller();
        _;
    }

    constructor(address pool_, address weth_, address caller_, address owner_) Ownable(owner_) {
        if (pool_ == address(0) || weth_ == address(0) || caller_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        POOL = IAavePool(pool_);
        WETH = IWETH(weth_);
        CALLER = caller_;
    }

    /// @notice Post ETH collateral, wrapped to WETH and supplied to the Aave pool on this
    /// contract's own behalf. Owner-only: collateral sizing is a deliberate treasury decision,
    /// not something the automated borrow/repay path should ever trigger.
    function supplyCollateral() external payable onlyOwner nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        WETH.deposit{value: msg.value}();
        IERC20(address(WETH)).forceApprove(address(POOL), msg.value);
        POOL.supply(address(WETH), msg.value, address(this), 0);
    }

    /// @notice Withdraw previously-supplied collateral (unencumbered by outstanding debt) back
    /// out as native ETH. Reverts upstream (in the Aave pool) if it would breach the health
    /// factor against any remaining debt.
    function withdrawCollateral(uint256 amount, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        uint256 withdrawn_ = POOL.withdraw(address(WETH), amount, address(this));
        WETH.withdraw(withdrawn_);
        (bool ok_,) = to.call{value: withdrawn_}("");
        require(ok_, "AaveCreditLine: ETH transfer failed");
    }

    /// @inheritdoc ICreditLine
    function borrow(uint256 amount, address receiver) external onlyCaller nonReentrant returns (uint256 borrowed) {
        if (amount == 0) revert ZeroAmount();
        if (receiver == address(0)) revert ZeroAddress();

        POOL.borrow(address(WETH), amount, VARIABLE_RATE_MODE, 0, address(this));
        WETH.withdraw(amount);
        debt += amount;

        (bool ok_,) = receiver.call{value: amount}("");
        require(ok_, "AaveCreditLine: ETH transfer failed");

        return amount;
    }

    /// @inheritdoc ICreditLine
    function repay(uint256 amount) external payable onlyCaller nonReentrant returns (uint256 repaid) {
        if (amount == 0) revert ZeroAmount();
        if (msg.value != amount) revert ValueMismatch();
        if (amount > debt) revert RepayExceedsDebt();

        WETH.deposit{value: amount}();
        IERC20(address(WETH)).forceApprove(address(POOL), amount);
        uint256 actuallyRepaid_ = POOL.repay(address(WETH), amount, VARIABLE_RATE_MODE, address(this));
        debt -= actuallyRepaid_;

        return actuallyRepaid_;
    }

    /// @inheritdoc ICreditLine
    function debtOf(address borrower) external view returns (uint256) {
        return borrower == address(this) || borrower == CALLER ? debt : 0;
    }

    receive() external payable {}
}
