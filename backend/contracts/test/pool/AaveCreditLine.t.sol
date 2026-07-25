// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@oz/interfaces/IERC20.sol";

import {AaveCreditLine} from "../../contracts/pool/spv/AaveCreditLine.sol";
import {IAavePool} from "../../contracts/pool/spv/interfaces/IAavePool.sol";
import {IWETH} from "../../contracts/pool/spv/interfaces/IWETH.sol";

/// Minimal WETH9 mock: real deposit/withdraw/transfer semantics (this is exactly what's being
/// exercised - the wrap/unwrap boundary - so it needs to actually hold and move ETH, not stub).
contract MockWETH is IWETH {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "MockWETH: insufficient balance");
        balanceOf[msg.sender] -= amount;
        totalSupply -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MockWETH: ETH transfer failed");
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockWETH: insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "MockWETH: insufficient balance");
        require(allowance[from][msg.sender] >= amount, "MockWETH: insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    receive() external payable {}
}

/// Minimal Aave V3 Pool mock: real WETH custody + a simple collateral/debt ledger (enough to
/// exercise AaveCreditLine's wrap/supply/borrow/repay/withdraw flow end-to-end, including the
/// health-factor-style guard on withdraw/borrow), not a no-op stub.
contract MockAavePool is IAavePool {
    IWETH public immutable WETH;

    mapping(address => uint256) public collateralOf;
    mapping(address => uint256) public debtOf_;

    error InsufficientCollateral();
    error InsufficientLiquidity();

    constructor(address weth_) {
        WETH = IWETH(weth_);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(asset == address(WETH), "MockAavePool: only WETH");
        IERC20(address(WETH)).transferFrom(msg.sender, address(this), amount);
        collateralOf[onBehalfOf] += amount;
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        require(asset == address(WETH), "MockAavePool: only WETH");
        if (amount > collateralOf[msg.sender] - debtOf_[msg.sender]) revert InsufficientCollateral();
        collateralOf[msg.sender] -= amount;
        WETH.transfer(to, amount);
        return amount;
    }

    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16, address onBehalfOf) external {
        require(asset == address(WETH), "MockAavePool: only WETH");
        require(interestRateMode == 2, "MockAavePool: variable rate only");
        if (amount > collateralOf[onBehalfOf] - debtOf_[onBehalfOf]) revert InsufficientCollateral();
        if (WETH.balanceOf(address(this)) < amount) revert InsufficientLiquidity();
        debtOf_[onBehalfOf] += amount;
        WETH.transfer(msg.sender, amount);
    }

    function repay(address asset, uint256 amount, uint256 interestRateMode, address onBehalfOf)
        external
        returns (uint256)
    {
        require(asset == address(WETH), "MockAavePool: only WETH");
        require(interestRateMode == 2, "MockAavePool: variable rate only");
        uint256 actual = amount > debtOf_[onBehalfOf] ? debtOf_[onBehalfOf] : amount;
        IERC20(address(WETH)).transferFrom(msg.sender, address(this), actual);
        debtOf_[onBehalfOf] -= actual;
        return actual;
    }
}

contract AaveCreditLineTest is Test {
    MockWETH internal weth;
    MockAavePool internal pool;
    AaveCreditLine internal creditLine;

    address internal owner = address(0xA11CE);
    address internal caller = address(0xCA11E5); // stands in for SpvTreasuryAdapter
    address internal stranger = address(0xBAD);

    function setUp() public {
        weth = new MockWETH();
        pool = new MockAavePool(address(weth));
        creditLine = new AaveCreditLine(address(pool), address(weth), caller, owner);

        vm.deal(owner, 100 ether);
        vm.deal(address(pool), 100 ether); // liquidity for the pool to lend out
        vm.prank(address(pool));
        weth.deposit{value: 100 ether}();
    }

    function test_constructor_revertsOnZeroAddress() public {
        vm.expectRevert(AaveCreditLine.ZeroAddress.selector);
        new AaveCreditLine(address(0), address(weth), caller, owner);
        vm.expectRevert(AaveCreditLine.ZeroAddress.selector);
        new AaveCreditLine(address(pool), address(0), caller, owner);
        vm.expectRevert(AaveCreditLine.ZeroAddress.selector);
        new AaveCreditLine(address(pool), address(weth), address(0), owner);
        // Ownable's own constructor-time zero-owner check fires before AaveCreditLine's body runs.
        vm.expectRevert(abi.encodeWithSignature("OwnableInvalidOwner(address)", address(0)));
        new AaveCreditLine(address(pool), address(weth), caller, address(0));
    }

    function test_supplyCollateral_succeeds() public {
        vm.prank(owner);
        creditLine.supplyCollateral{value: 10 ether}();

        assertEq(pool.collateralOf(address(creditLine)), 10 ether);
        assertEq(address(creditLine).balance, 0); // fully wrapped+supplied, nothing idle
    }

    function test_supplyCollateral_revertsOnZeroValue() public {
        vm.prank(owner);
        vm.expectRevert(AaveCreditLine.ZeroAmount.selector);
        creditLine.supplyCollateral{value: 0}();
    }

    function test_supplyCollateral_revertsOnNonOwner() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        creditLine.supplyCollateral{value: 1 ether}();
    }

    function _supply(uint256 amount) internal {
        vm.prank(owner);
        creditLine.supplyCollateral{value: amount}();
    }

    function test_borrow_succeeds() public {
        _supply(10 ether);

        uint256 balBefore = address(this).balance;
        vm.prank(caller);
        uint256 borrowed = creditLine.borrow(3 ether, address(this));

        assertEq(borrowed, 3 ether);
        assertEq(address(this).balance, balBefore + 3 ether);
        assertEq(creditLine.debt(), 3 ether);
        assertEq(creditLine.debtOf(address(creditLine)), 3 ether);
        assertEq(creditLine.debtOf(caller), 3 ether);
    }

    function test_borrow_revertsOnNonCaller() public {
        _supply(10 ether);
        vm.expectRevert(AaveCreditLine.OnlyCaller.selector);
        creditLine.borrow(1 ether, address(this));
    }

    function test_borrow_revertsOnZeroAmount() public {
        _supply(10 ether);
        vm.prank(caller);
        vm.expectRevert(AaveCreditLine.ZeroAmount.selector);
        creditLine.borrow(0, address(this));
    }

    function test_borrow_revertsOnZeroReceiver() public {
        _supply(10 ether);
        vm.prank(caller);
        vm.expectRevert(AaveCreditLine.ZeroAddress.selector);
        creditLine.borrow(1 ether, address(0));
    }

    function test_borrow_revertsOnInsufficientCollateral() public {
        _supply(1 ether);
        vm.prank(caller);
        vm.expectRevert(MockAavePool.InsufficientCollateral.selector);
        creditLine.borrow(5 ether, address(this));
    }

    function test_repay_succeeds() public {
        _supply(10 ether);
        vm.prank(caller);
        creditLine.borrow(3 ether, address(this));

        vm.deal(caller, 3 ether);
        vm.prank(caller);
        uint256 repaid = creditLine.repay{value: 3 ether}(3 ether);

        assertEq(repaid, 3 ether);
        assertEq(creditLine.debt(), 0);
        assertEq(pool.debtOf_(address(creditLine)), 0);
    }

    function test_repay_partial_succeeds() public {
        _supply(10 ether);
        vm.prank(caller);
        creditLine.borrow(3 ether, address(this));

        vm.deal(caller, 1 ether);
        vm.prank(caller);
        creditLine.repay{value: 1 ether}(1 ether);

        assertEq(creditLine.debt(), 2 ether);
    }

    function test_repay_revertsOnNonCaller() public {
        _supply(10 ether);
        vm.prank(caller);
        creditLine.borrow(3 ether, address(this));

        vm.deal(stranger, 3 ether);
        vm.prank(stranger);
        vm.expectRevert(AaveCreditLine.OnlyCaller.selector);
        creditLine.repay{value: 3 ether}(3 ether);
    }

    function test_repay_revertsOnValueMismatch() public {
        _supply(10 ether);
        vm.prank(caller);
        creditLine.borrow(3 ether, address(this));

        vm.deal(caller, 3 ether);
        vm.prank(caller);
        vm.expectRevert(AaveCreditLine.ValueMismatch.selector);
        creditLine.repay{value: 2 ether}(3 ether);
    }

    function test_repay_revertsOnExceedingDebt() public {
        _supply(10 ether);
        vm.prank(caller);
        creditLine.borrow(1 ether, address(this));

        vm.deal(caller, 5 ether);
        vm.prank(caller);
        vm.expectRevert(AaveCreditLine.RepayExceedsDebt.selector);
        creditLine.repay{value: 5 ether}(5 ether);
    }

    function test_withdrawCollateral_succeeds() public {
        _supply(10 ether);

        vm.prank(owner);
        creditLine.withdrawCollateral(4 ether, owner);

        assertEq(pool.collateralOf(address(creditLine)), 6 ether);
        assertEq(owner.balance, 90 ether + 4 ether);
    }

    function test_withdrawCollateral_revertsWhenEncumberedByDebt() public {
        _supply(10 ether);
        vm.prank(caller);
        creditLine.borrow(8 ether, address(this));

        // Only 2 ether of the 10 posted is unencumbered (10 collateral - 8 debt).
        vm.prank(owner);
        vm.expectRevert(MockAavePool.InsufficientCollateral.selector);
        creditLine.withdrawCollateral(3 ether, owner);
    }

    function test_withdrawCollateral_revertsOnNonOwner() public {
        _supply(10 ether);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        creditLine.withdrawCollateral(1 ether, stranger);
    }

    function test_debtOf_returnsZeroForUnrelatedAddress() public {
        _supply(10 ether);
        vm.prank(caller);
        creditLine.borrow(3 ether, address(this));

        assertEq(creditLine.debtOf(stranger), 0);
    }

    receive() external payable {}
}
