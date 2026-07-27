// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {ISpvVogue} from "./ISpvVenue.sol";
import {ICreditLine} from "./ICreditLine.sol";

/**
 * @title SpvTreasuryAdapter
 * @notice Routes PP's otherwise-idle ETH into SPV's Vogue LP for yield, WITHOUT breaking PP's
 *         anonymity guarantees and WITHOUT modifying PP's core contracts (`PrivacyPool`/`Entrypoint`
 *         stay completely untouched — this is a separate satellite contract PP's governance funds
 *         periodically). See ../../../../PP-SPV-BUFFER-DESIGN.md for the full
 *         design rationale; this NatSpec covers the invariants only.
 *
 * WHY THIS EXISTS (the privacy constraint, restated precisely): Vogue's own deposit/withdraw events
 * are public and cleartext (no privacy properties of their own). If ETH moved into/out of Vogue
 * synchronously and 1:1 with individual PP user deposits/withdrawals, Vogue's event stream would
 * become a side-channel that reconstructs the deposit<->withdrawal link PP's ZK design exists to
 * hide. This contract exists ONLY to enforce decoupling: every sweep/reclaim is (a) keeper-gated,
 * NOT permissionless (timing itself is the sensitive parameter here — unlike e.g. SPV's own
 * de-lever functions, where anyone-can-call is fine because timing doesn't leak anything), (b)
 * rate-limited (a minimum interval must elapse between calls), and (c) size-capped (a single call
 * can move at most a configured fraction of the current idle balance) — so no single call can be
 * forced into a 1:1 correlation with any specific user action.
 *
 * COUPLING: holds SPV's Vogue address as an IMMUTABLE constructor argument (the "reverse coupling"
 * plan) — SPV's repo has zero references to this contract or to PP anywhere. Deploy SPV first (its
 * addresses are final and non-upgradeable), then deploy this adapter with that address baked in.
 *
 * BACKSTOP: buffer-exhaustion tail risk is covered by `ICreditLine` — a genuinely EXTERNAL,
 * SPV-independent collateralized credit line (e.g. a real Aave/Morpho borrow position), NOT SPV's
 * `_deleverFlash` (confirmed atomic same-transaction Morpho flash loan — cannot persist a debt
 * across transactions, the wrong shape for "draw now, repay later"). Optional: address(0) disables
 * it until that integration is built (see ICreditLine.sol STATUS note).
 */
contract SpvTreasuryAdapter is Ownable, ReentrancyGuard {
    /// @notice SPV's deployed Vogue ETH-LP contract. Immutable — pinned once, at THIS contract's
    /// construction, never SPV's. SPV never needs to know this contract exists.
    ISpvVogue public immutable VOGUE;

    /// @notice Optional external backstop credit line (SPV-independent). address(0) if not yet wired.
    ICreditLine public immutable CREDIT_LINE;

    /// @notice The single automation address permitted to trigger sweep/reclaim/backstop actions.
    /// Deliberately NOT permissionless — see class NatSpec. Owner-rotatable (this is an internal ops
    /// role, not a cross-protocol trust boundary, so it doesn't need pin-once/immutable treatment).
    address public keeper;

    /// @notice Minimum seconds that must elapse between sweeps (resp. reclaims). Enforces decoupling
    /// from any single user action's timing.
    uint256 public minSweepInterval = 1 hours;
    uint256 public minReclaimInterval = 1 hours;

    /// @notice Maximum fraction (basis points, 10_000 = 100%) of the CURRENT idle balance a single
    /// sweep may move. Prevents "sweep everything in one shot right after a big deposit" from
    /// becoming its own correlatable event.
    uint256 public maxSweepBps = 5_000; // 50%

    uint256 public lastSweepAt;
    uint256 public lastReclaimAt;

    /// @notice Outstanding debt drawn from the backstop credit line, to be repaid from future reclaims.
    uint256 public outstandingDebt;

    /// @notice Vogue LP shares this contract currently holds (informational; Vogue is the source of
    /// truth via its own share balance, this just avoids an extra external call in view paths).
    uint256 public vogueShares;

    bool public paused;

    event Funded(address indexed from, uint256 amount);
    event Released(address indexed to, uint256 amount);
    event SweptToVenue(uint256 amount, uint256 sharesOut);
    event ReclaimedFromVenue(uint256 sharesIn, uint256 assetsOut);
    event BackstopDrawn(uint256 amount, address indexed recipient);
    event BackstopRepaid(uint256 amount);
    event KeeperUpdated(address indexed keeper);
    event PausedSet(bool paused);

    error NotKeeper();
    error Paused();
    error TooSoon(uint256 readyAt);
    error ExceedsMaxSweepFraction();
    error ZeroAddress();
    error ZeroAmount();
    error NoCreditLine();
    error InsufficientBalance();
    error RepayExceedsDebt();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    constructor(address vogue_, address creditLine_, address keeper_, address owner_) Ownable(owner_) {
        if (vogue_ == address(0)) revert ZeroAddress();
        if (keeper_ == address(0)) revert ZeroAddress();
        VOGUE = ISpvVogue(vogue_);
        CREDIT_LINE = ICreditLine(creditLine_); // address(0) allowed: backstop not yet wired
        keeper = keeper_;
    }

    // ── Funding (PP's governance moves excess idle ETH in; core PP contracts are never modified to
    //    know about this contract — it's a plain, permissionless-to-fund satellite) ──────────────

    receive() external payable {
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Send idle ETH back out (e.g. to PP's Entrypoint, to top up its own hot buffer).
    /// Owner-gated: this is PP's own internal treasury movement, not a user-facing withdrawal path.
    function release(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (amount > _idleBalance()) revert InsufficientBalance();
        emit Released(to, amount);
        (bool ok, ) = to.call{value: amount}("");
        require(ok, "SpvTreasuryAdapter: release transfer failed");
    }

    // ── Sweep / reclaim (keeper-gated, rate-limited, size-capped — the decoupling enforcement) ──

    /// @notice Sweep up to `maxSweepBps` of the current idle balance into Vogue. Keeper chooses the
    /// exact amount (within the cap) and when to call (subject to the minimum interval) — that
    /// discretion is the jitter; this contract only enforces the safety rails.
    function sweepToVenue(uint256 amount) external onlyKeeper whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // lastSweepAt == 0 means "never swept" — the very first call is always allowed regardless
        // of minSweepInterval; the rate limit only applies BETWEEN calls.
        if (lastSweepAt != 0 && block.timestamp < lastSweepAt + minSweepInterval) {
            revert TooSoon(lastSweepAt + minSweepInterval);
        }

        uint256 idle_ = _idleBalance();
        if (amount > (idle_ * maxSweepBps) / 10_000) revert ExceedsMaxSweepFraction();

        lastSweepAt = block.timestamp;

        uint256 sharesOut_ = VOGUE.deposit{value: amount}(amount, address(this));
        vogueShares += sharesOut_;

        emit SweptToVenue(amount, sharesOut_);
    }

    /// @notice Reclaim `assets` worth of ETH from Vogue back into this contract's idle balance.
    function reclaimFromVenue(uint256 assets) external onlyKeeper whenNotPaused nonReentrant {
        if (assets == 0) revert ZeroAmount();
        // lastReclaimAt == 0 means "never reclaimed" — see sweepToVenue for the same convention.
        if (lastReclaimAt != 0 && block.timestamp < lastReclaimAt + minReclaimInterval) {
            revert TooSoon(lastReclaimAt + minReclaimInterval);
        }

        lastReclaimAt = block.timestamp;

        uint256 sharesIn_ = VOGUE.withdraw(assets, address(this), address(this));
        vogueShares -= sharesIn_;

        emit ReclaimedFromVenue(sharesIn_, assets);
    }

    // ── Backstop (tail-risk-only: buffer exhaustion between scheduled reclaims) ──────────────────

    /// @notice Draw `amount` instantly from the external credit line to cover an urgent shortfall,
    /// bypassing Vogue entirely (Vogue never has to respond in real time to any single event — see
    /// class NatSpec). Recorded as debt, repaid later from a normal scheduled reclaim.
    function drawBackstop(uint256 amount, address payable recipient) external onlyKeeper whenNotPaused nonReentrant {
        if (address(CREDIT_LINE) == address(0)) revert NoCreditLine();
        if (amount == 0) revert ZeroAmount();
        if (recipient == address(0)) revert ZeroAddress();

        uint256 borrowed_ = CREDIT_LINE.borrow(amount, address(this));
        outstandingDebt += borrowed_;

        emit BackstopDrawn(borrowed_, recipient);
        (bool ok, ) = recipient.call{value: borrowed_}("");
        require(ok, "SpvTreasuryAdapter: backstop transfer failed");
    }

    /// @notice Repay outstanding backstop debt from this contract's own idle balance (typically
    /// called right after a scheduled reclaim lands). Never repays more than is owed.
    function repayBackstop(uint256 amount) external onlyKeeper whenNotPaused nonReentrant {
        if (address(CREDIT_LINE) == address(0)) revert NoCreditLine();
        if (amount == 0) revert ZeroAmount();
        if (amount > outstandingDebt) revert RepayExceedsDebt();
        if (amount > _idleBalance()) revert InsufficientBalance();

        outstandingDebt -= amount;
        CREDIT_LINE.repay{value: amount}(amount);

        emit BackstopRepaid(amount);
    }

    // ── Governance ────────────────────────────────────────────────────────────────────────────

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperUpdated(keeper_);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function setSweepPolicy(uint256 minSweepInterval_, uint256 maxSweepBps_) external onlyOwner {
        require(maxSweepBps_ <= 10_000, "SpvTreasuryAdapter: bps");
        minSweepInterval = minSweepInterval_;
        maxSweepBps = maxSweepBps_;
    }

    function setMinReclaimInterval(uint256 minReclaimInterval_) external onlyOwner {
        minReclaimInterval = minReclaimInterval_;
    }

    // ── Views ─────────────────────────────────────────────────────────────────────────────────

    function idleBalance() external view returns (uint256) {
        return _idleBalance();
    }

    function _idleBalance() internal view returns (uint256) {
        return address(this).balance;
    }
}
