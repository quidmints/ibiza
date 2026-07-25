// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SpvTreasuryAdapter} from "../../contracts/pool/spv/SpvTreasuryAdapter.sol";
import {ISpvVogue} from "../../contracts/pool/spv/ISpvVenue.sol";
import {ICreditLine} from "../../contracts/pool/spv/ICreditLine.sol";

/// Minimal mock standing in for SPV's real Vogue.sol — implements ONLY the permissionless
/// deposit/withdraw shape confirmed by reading Vogue.sol directly (1 share per 1 wei, no yield
/// simulated; this test suite is about the ADAPTER's decoupling invariants, not Vogue's own math).
contract MockVogue is ISpvVogue {
    mapping(address => uint256) public sharesOf;

    function deposit(uint256 assets, address receiver) external payable returns (uint256 shares) {
        return deposit(assets, receiver, 0);
    }

    function deposit(uint256 assets, address receiver, uint8) public payable returns (uint256 shares) {
        require(msg.value == assets, "MockVogue: value mismatch");
        sharesOf[receiver] += assets;
        return assets;
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(sharesOf[owner] >= assets, "MockVogue: insufficient shares");
        sharesOf[owner] -= assets;
        (bool ok, ) = payable(receiver).call{value: assets}("");
        require(ok, "MockVogue: transfer failed");
        return assets;
    }

    receive() external payable {}
}

/// Minimal mock credit line: unlimited capacity, tracks debt per borrower, 1:1 borrow/repay.
contract MockCreditLine is ICreditLine {
    mapping(address => uint256) public debtOf_;

    function borrow(uint256 amount, address receiver) external returns (uint256 borrowed) {
        debtOf_[msg.sender] += amount;
        (bool ok, ) = payable(receiver).call{value: amount}("");
        require(ok, "MockCreditLine: transfer failed");
        return amount;
    }

    function repay(uint256 amount) external payable returns (uint256 repaid) {
        require(msg.value == amount, "MockCreditLine: value mismatch");
        require(debtOf_[msg.sender] >= amount, "MockCreditLine: overpay");
        debtOf_[msg.sender] -= amount;
        return amount;
    }

    function debtOf(address borrower) external view returns (uint256) {
        return debtOf_[borrower];
    }

    receive() external payable {}
}

contract SpvTreasuryAdapterTest is Test {
    SpvTreasuryAdapter internal adapter;
    MockVogue internal vogue;
    MockCreditLine internal creditLine;

    address internal owner = address(0xA011);
    address internal keeper = address(0xB022);
    address internal ppEntrypoint = address(0xC033); // stand-in for PP's core, funding this adapter

    function setUp() public {
        vogue = new MockVogue();
        creditLine = new MockCreditLine();
        adapter = new SpvTreasuryAdapter(address(vogue), address(creditLine), keeper, owner);

        vm.deal(ppEntrypoint, 100 ether);
        vm.deal(address(creditLine), 100 ether); // funds the mock's borrow() payouts
    }

    function _fund(uint256 amount) internal {
        vm.prank(ppEntrypoint);
        (bool ok, ) = address(adapter).call{value: amount}("");
        require(ok, "fund failed");
    }

    // ── Immutable wiring (the reverse-coupling plan) ────────────────────────────────────────────

    function test_immutableAddressesSetAtConstruction() public view {
        assertEq(address(adapter.VOGUE()), address(vogue));
        assertEq(address(adapter.CREDIT_LINE()), address(creditLine));
    }

    function test_constructor_revertsOnZeroVogue() public {
        vm.expectRevert(SpvTreasuryAdapter.ZeroAddress.selector);
        new SpvTreasuryAdapter(address(0), address(creditLine), keeper, owner);
    }

    function test_constructor_allowsZeroCreditLine() public {
        // Backstop is optional — not yet wired is a valid state.
        SpvTreasuryAdapter a = new SpvTreasuryAdapter(address(vogue), address(0), keeper, owner);
        assertEq(address(a.CREDIT_LINE()), address(0));
    }

    // ── Funding / release ────────────────────────────────────────────────────────────────────────

    function test_fund_and_idleBalance() public {
        _fund(5 ether);
        assertEq(adapter.idleBalance(), 5 ether);
    }

    function test_release_onlyOwner() public {
        _fund(5 ether);
        vm.prank(keeper);
        vm.expectRevert(); // Ownable: caller is not the owner
        adapter.release(payable(ppEntrypoint), 1 ether);

        vm.prank(owner);
        adapter.release(payable(ppEntrypoint), 1 ether);
        assertEq(adapter.idleBalance(), 4 ether);
    }

    // ── Sweep: keeper-gated, rate-limited, size-capped ──────────────────────────────────────────

    function test_sweep_onlyKeeper() public {
        _fund(10 ether);
        vm.prank(owner);
        vm.expectRevert(SpvTreasuryAdapter.NotKeeper.selector);
        adapter.sweepToVenue(1 ether);
    }

    function test_sweep_respectsMaxFractionCap() public {
        _fund(10 ether); // maxSweepBps default 50% -> cap is 5 ether
        vm.prank(keeper);
        vm.expectRevert(SpvTreasuryAdapter.ExceedsMaxSweepFraction.selector);
        adapter.sweepToVenue(6 ether);
    }

    function test_sweep_withinCap_succeeds_andMovesFundsToVenue() public {
        _fund(10 ether);
        vm.prank(keeper);
        adapter.sweepToVenue(4 ether);

        assertEq(adapter.idleBalance(), 6 ether);
        assertEq(vogue.sharesOf(address(adapter)), 4 ether);
        assertEq(adapter.vogueShares(), 4 ether);
    }

    function test_sweep_respectsMinInterval() public {
        _fund(10 ether);
        vm.prank(keeper);
        adapter.sweepToVenue(1 ether);

        vm.prank(keeper);
        vm.expectRevert(); // TooSoon
        adapter.sweepToVenue(1 ether);

        vm.warp(block.timestamp + adapter.minSweepInterval());
        vm.prank(keeper);
        adapter.sweepToVenue(1 ether); // now succeeds
    }

    // ── Reclaim: keeper-gated, rate-limited ─────────────────────────────────────────────────────

    function test_reclaim_onlyKeeper() public {
        _fund(10 ether);
        vm.prank(keeper);
        adapter.sweepToVenue(4 ether);

        vm.prank(owner);
        vm.expectRevert(SpvTreasuryAdapter.NotKeeper.selector);
        adapter.reclaimFromVenue(1 ether);
    }

    function test_reclaim_pullsFundsBackFromVenue() public {
        _fund(10 ether);
        vm.prank(keeper);
        adapter.sweepToVenue(4 ether);
        assertEq(adapter.idleBalance(), 6 ether);

        vm.prank(keeper);
        adapter.reclaimFromVenue(2 ether);

        assertEq(adapter.idleBalance(), 8 ether);
        assertEq(adapter.vogueShares(), 2 ether);
    }

    function test_reclaim_respectsMinInterval() public {
        _fund(10 ether);
        vm.prank(keeper);
        adapter.sweepToVenue(4 ether);

        vm.prank(keeper);
        adapter.reclaimFromVenue(1 ether);

        vm.prank(keeper);
        vm.expectRevert(); // TooSoon
        adapter.reclaimFromVenue(1 ether);
    }

    // ── Backstop: instant draw, tracked debt, repay ─────────────────────────────────────────────

    function test_drawBackstop_revertsWithNoCreditLine() public {
        SpvTreasuryAdapter noCredit = new SpvTreasuryAdapter(address(vogue), address(0), keeper, owner);
        vm.prank(keeper);
        vm.expectRevert(SpvTreasuryAdapter.NoCreditLine.selector);
        noCredit.drawBackstop(1 ether, payable(ppEntrypoint));
    }

    function test_drawBackstop_sendsFundsAndTracksDebt() public {
        uint256 before = ppEntrypoint.balance;

        vm.prank(keeper);
        adapter.drawBackstop(3 ether, payable(ppEntrypoint));

        assertEq(ppEntrypoint.balance, before + 3 ether);
        assertEq(adapter.outstandingDebt(), 3 ether);
        assertEq(creditLine.debtOf(address(adapter)), 3 ether);
    }

    function test_repayBackstop_decrementsDebt() public {
        vm.prank(keeper);
        adapter.drawBackstop(3 ether, payable(ppEntrypoint));

        _fund(5 ether); // adapter needs idle balance to repay from
        vm.prank(keeper);
        adapter.repayBackstop(3 ether);

        assertEq(adapter.outstandingDebt(), 0);
        assertEq(creditLine.debtOf(address(adapter)), 0);
    }

    function test_repayBackstop_revertsAboveOutstandingDebt() public {
        vm.prank(keeper);
        adapter.drawBackstop(2 ether, payable(ppEntrypoint));

        _fund(5 ether);
        vm.prank(keeper);
        vm.expectRevert(SpvTreasuryAdapter.RepayExceedsDebt.selector);
        adapter.repayBackstop(3 ether);
    }

    // ── Pause ────────────────────────────────────────────────────────────────────────────────────

    function test_pause_blocksSweepReclaimAndBackstop() public {
        _fund(10 ether);
        vm.prank(owner);
        adapter.setPaused(true);

        vm.startPrank(keeper);
        vm.expectRevert(SpvTreasuryAdapter.Paused.selector);
        adapter.sweepToVenue(1 ether);

        vm.expectRevert(SpvTreasuryAdapter.Paused.selector);
        adapter.reclaimFromVenue(1 ether);

        vm.expectRevert(SpvTreasuryAdapter.Paused.selector);
        adapter.drawBackstop(1 ether, payable(ppEntrypoint));
        vm.stopPrank();
    }

    // ── Governance ───────────────────────────────────────────────────────────────────────────────

    function test_setKeeper_onlyOwner() public {
        address newKeeper = address(0xD044);
        vm.prank(keeper);
        vm.expectRevert();
        adapter.setKeeper(newKeeper);

        vm.prank(owner);
        adapter.setKeeper(newKeeper);
        assertEq(adapter.keeper(), newKeeper);
    }

    function test_setSweepPolicy_onlyOwner_andBoundsChecked() public {
        vm.prank(owner);
        vm.expectRevert(); // bps > 10_000
        adapter.setSweepPolicy(1 hours, 10_001);

        vm.prank(owner);
        adapter.setSweepPolicy(2 hours, 2_000);
        assertEq(adapter.minSweepInterval(), 2 hours);
        assertEq(adapter.maxSweepBps(), 2_000);
    }
}
