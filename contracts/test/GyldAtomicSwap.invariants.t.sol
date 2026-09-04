// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDCPermit} from "./MockUSDCPermit.sol";
import {MockNavForwarder} from "./MockNavForwarder.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Fuzz + invariant coverage for GyldAtomicSwap.
//
// The audit-prep checklist (docs/ARCHITECTURE.md) flags the absence of a
// stateful invariant suite over executeSwap as outstanding.
// These tests prove the two load-bearing conservation properties that make the
// self-custodial swap safe:
//
//   1. NEVER-MINTS  — executeSwap only ever moves pre-minted inventory via
//      ERC-20 transfer. It has no MINTER/BURNER role, so the bond token's
//      totalSupply is invariant across any swap (BUY or REDEEM).
//   2. FAIR PRICE    — amountOut is always (requestedAmountIn * price) / 1e18,
//      rounded down exactly like the contract, with no value created.
//
// Plus fuzz coverage of the single-use quoteId (BitInvalidator) replay guard.
// ─────────────────────────────────────────────────────────────────────────────

contract SwapFuzzTest is Test {
    GyldAtomicSwap swap;
    GyldBondToken token;
    MockUSDCPermit usdc;
    MockNavForwarder navFeed;

    address admin = address(0xA0);
    address pauser = address(0xA1);
    address treasurer = address(0xA2);
    address withdrawalWallet = address(0xA3);

    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK = 0xA11CE;
    address taker;

    // NAV $100.00/token (8dp): 1e18 token ⇔ 100e6 USDC — the standard on-NAV price.
    int256 constant NAV = 100e8;
    uint16 constant MAX_BPS = 200; // ±2% band
    uint32 constant MAX_NAV_AGE = 1 days;

    function setUp() public {
        vm.warp(1_750_000_000);
        taker = vm.addr(TAKER_PK);

        MockSanctionsList mockSanctions = new MockSanctionsList(address(this));
        usdc = new MockUSDCPermit();
        navFeed = new MockNavForwarder(NAV);

        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeCall(
                        GyldBondToken.initialize,
                        ("Gyld Bond", "GYLD", "US912797KR72", 1_780_000_000, admin, pauser, address(mockSanctions))
                    )
                )
            )
        );

        GyldAtomicSwap swapImpl = new GyldAtomicSwap();
        swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(swapImpl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, vm.addr(SIGNER_PK), treasurer, address(usdc), MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );

        vm.prank(admin);
        swap.registerSeries(address(token), address(navFeed));
        vm.prank(admin);
        swap.setWithdrawalWallet(withdrawalWallet);
        // setAllowed is gated on ALLOWLIST_ADMIN_ROLE (GYL-1050). Read the role bytes
        // before vm.prank — the getter is an external call that consumes the prank.
        bytes32 allowlistRole = swap.ALLOWLIST_ADMIN_ROLE();
        vm.prank(admin);
        swap.grantRole(allowlistRole, admin);
        vm.prank(admin);
        swap.setAllowed(taker, true);

        // Self-custodial inventory + taker balances (matches GyldAtomicSwap.t.sol setUp).
        // NOTE: `token.MINTER_ROLE()` is an external getter — read it BEFORE vm.prank,
        // else the getter call consumes the prank and grantRole runs as address(this).
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
        token.mint(address(swap), 1_000e18);
        token.mint(taker, 100e18);
        usdc.mint(taker, 1_000_000e6);
        usdc.mint(address(swap), 100_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _buyQuote(uint256 quoteId, uint256 maxAmountIn) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: maxAmountIn,
            tokenOut: address(token),
            price: 1e28, // 10e18 tokens per 1_000e6 USDC at NAV
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });
    }

    function _redeemQuote(uint256 quoteId, uint256 maxAmountIn)
        internal
        view
        returns (GyldAtomicSwap.SwapMessage memory)
    {
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: maxAmountIn,
            tokenOut: address(usdc),
            price: 100e6, // 1_000e6 USDC per 10e18 tokens at NAV
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });
    }

    function _sign(GyldAtomicSwap.SwapMessage memory m) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, swap.hashSwapMessage(m));
        return abi.encodePacked(r, s, v);
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    /// Approve the swap for both assets so executeSwap's pull succeeds without permit.
    function _approveTaker() internal {
        // Taker approves the swap for the full balance of both legs up-front.
        vm.startPrank(taker);
        usdc.approve(address(swap), type(uint256).max);
        token.approve(address(swap), type(uint256).max);
        vm.stopPrank();
    }

    // ── NEVER-MINTS: bond totalSupply is invariant across any valid swap ──────

    /// A BUY only moves pre-minted inventory — it must never change token.totalSupply.
    function testFuzz_executeSwap_buy_tokenTotalSupply_unchanged(uint256 requestedAmountIn) public {
        _approveTaker();
        uint256 maxAmountIn = 1_000e6; // up to 1_000 USDC
        // Contract dust floor: requestedAmountIn must be ≥ 1% of maxAmountIn.
        requestedAmountIn = bound(requestedAmountIn, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1, maxAmountIn);
        uint256 supplyBefore = token.totalSupply();

        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        assertEq(token.totalSupply(), supplyBefore, "BUY must never change bond totalSupply (no mint/burn)");
    }

    /// A REDEEM only moves inventory back to the swap — totalSupply must never change.
    function testFuzz_executeSwap_redeem_tokenTotalSupply_unchanged(uint256 requestedAmountIn) public {
        _approveTaker();
        uint256 maxAmountIn = 10e18; // up to 10 tokens
        requestedAmountIn = bound(requestedAmountIn, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(1, maxAmountIn);
        uint256 supplyBefore = token.totalSupply();

        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        assertEq(token.totalSupply(), supplyBefore, "REDEEM must never change bond totalSupply (no mint/burn)");
    }

    // ── FAIR PRICE: amountOut matches the contract's rounding exactly ─────────

    /// For any valid partial draw, the token out equals (requested * price) / 1e18,
    /// rounded down — proving no value is created or destroyed vs the signed price.
    function testFuzz_executeSwap_buy_amountOut_matchesPriceRoundedDown(uint256 requestedAmountIn) public {
        _approveTaker();
        uint256 maxAmountIn = 1_000e6;
        requestedAmountIn = bound(requestedAmountIn, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(2, maxAmountIn);
        uint256 takerTokensBefore = token.balanceOf(taker);
        uint256 expectedOut = (requestedAmountIn * m.price) / 1e18;

        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        assertEq(
            token.balanceOf(taker) - takerTokensBefore,
            expectedOut,
            "amountOut must equal (requestedAmountIn * price) / 1e18 rounded down"
        );
    }

    /// Conservation of both pools across a BUY: USDC gained by swap == USDC lost by
    /// taker, and tokens lost by swap == tokens gained by taker (no leakage).
    function testFuzz_executeSwap_buy_conservesBothPools(uint256 requestedAmountIn) public {
        _approveTaker();
        uint256 maxAmountIn = 1_000e6;
        requestedAmountIn = bound(requestedAmountIn, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(3, maxAmountIn);
        uint256 expectedOut = (requestedAmountIn * m.price) / 1e18;

        uint256 swapTokenBefore = token.balanceOf(address(swap));
        uint256 swapUsdcBefore = usdc.balanceOf(address(swap));
        uint256 takerTokenBefore = token.balanceOf(taker);
        uint256 takerUsdcBefore = usdc.balanceOf(taker);

        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        // Token moves swap → taker exactly by expectedOut.
        assertEq(swapTokenBefore - token.balanceOf(address(swap)), expectedOut, "swap token debit mismatch");
        assertEq(token.balanceOf(taker) - takerTokenBefore, expectedOut, "taker token credit mismatch");
        // USDC moves taker → swap exactly by requestedAmountIn.
        assertEq(takerUsdcBefore - usdc.balanceOf(taker), requestedAmountIn, "taker USDC debit mismatch");
        assertEq(usdc.balanceOf(address(swap)) - swapUsdcBefore, requestedAmountIn, "swap USDC credit mismatch");
    }

    // ── SINGLE-USE: a quoteId can never be consumed twice ────────────────────

    /// Replaying the exact same (quoteId, message) must always revert, regardless
    /// of the draw amount — the BitInvalidator is the replay-protection backstop.
    function testFuzz_quoteId_replay_alwaysReverts(uint256 requestedAmountIn) public {
        _approveTaker();
        uint256 maxAmountIn = 1_000e6;
        requestedAmountIn = bound(requestedAmountIn, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(42, maxAmountIn);
        // Sign once before each prank — inline _sign(m) would consume the prank
        // (hashSwapMessage is an external call evaluated as an argument).
        bytes memory sig = _sign(m);

        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteAlreadyUsed.selector, 42));
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Stateful invariants: a handler performs random valid BUY/REDEEM swaps, and
// the invariant assertions check global conservation after every sequence.
//
// FIND-021 scale note: the handler is sized against the fixture's per-NAV-round
// notional cap (ROUND_CAP below), not against the taker's wallet. A handful of
// fills exhausts a round's budget, so the cap is exercised as a BOUND THAT
// BITES — the earlier handler moved ~$5,000 per run against a $1,000,000 cap
// and could only ever prove the guard's passing direction.
// ─────────────────────────────────────────────────────────────────────────────
contract SwapHandler is CommonBase, StdCheats, StdUtils {
    GyldAtomicSwap public swap;
    GyldBondToken public token;
    MockUSDCPermit public usdc;
    MockNavForwarder public navFeed;

    address public taker;
    uint256 public signerPk;

    /// Monotonic quoteId counter — every handler swap uses a fresh id so the
    /// single-use BitInvalidator never trips during the fuzz sequence (that
    /// guard is covered by the replay fuzz test above).
    uint256 public nextQuoteId = 1_000;

    /// Total bond tokens moved OUT of the swap across all BUYs (for accounting
    /// cross-checks); never asserted directly, only via the invariant contract.
    uint256 public tokensOutCumulative;

    /// Largest USDC notional a single handler fill may draw. Sized to a fraction of
    /// the fixture's round cap so that a few fills exhaust one round's budget.
    uint256 public constant MAX_FILL_NOTIONAL = 100_000e6;
    /// Floor below which a fill is skipped rather than attempted: the remaining budget
    /// is dust, and MIN_DRAW_BPS/rounding make a well-formed quote for it fiddly.
    /// Skipping is mandatory, not cosmetic — `fail_on_revert = true` means a refused
    /// fill would abort the entire run.
    uint256 public constant MIN_FILL_NOTIONAL = 1e6;

    // ── Ghost mirror of GyldAtomicSwap's NavRoundDraw ─────────────────────────
    // Recomputed here from the OBSERVED USDC leg of every settled fill, using the
    // spec's rule ("reset only on a strictly newer round"). The invariant asserts the
    // contract's counter equals this, which catches an uncharged fill, the wrong leg
    // being charged, and a reset that fires on the wrong condition — none of which a
    // `drawn <= cap` bound alone would notice.
    uint64 public ghostRound;
    uint256 public ghostDrawn;
    /// Highest round key the contract's counter has ever held.
    uint64 public maxRoundObserved;

    // ── Call counters (asserted by the exhaustion test below) ─────────────────
    uint256 public fills;
    uint256 public skippedForBudget;
    uint256 public capRefusals;
    uint256 public roundAdvances;
    uint256 public roundRegressions;

    constructor(
        GyldAtomicSwap swap_,
        GyldBondToken token_,
        MockUSDCPermit usdc_,
        MockNavForwarder navFeed_,
        address taker_,
        uint256 signerPk_
    ) {
        swap = swap_;
        token = token_;
        usdc = usdc_;
        navFeed = navFeed_;
        taker = taker_;
        signerPk = signerPk_;
    }

    /// BUY: taker draws USDC into the swap for bond tokens, at a fixed on-NAV price.
    /// The draw is clamped to what the CURRENT NAV round still admits — under
    /// `fail_on_revert = true` a cap-refused fill would abort the run, so the refusal
    /// path is exercised deliberately in `buyBeyondRoundBudget` instead.
    function buy(uint256 drawSeed) external {
        uint256 remaining = _remainingRoundBudget();
        if (remaining < MIN_FILL_NOTIONAL) {
            skippedForBudget++;
            return;
        }
        uint256 maxAmountIn = remaining < MAX_FILL_NOTIONAL ? remaining : MAX_FILL_NOTIONAL;
        uint256 requested = bound(drawSeed, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: nextQuoteId++,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: maxAmountIn,
            tokenOut: address(token),
            price: 1e28,
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, swap.hashSwapMessage(m));
        bytes memory sig = abi.encodePacked(r, s, v);

        uint64 feedRound = _feedRound();
        uint256 swapTokenBefore = token.balanceOf(address(swap));
        uint256 swapUsdcBefore = usdc.balanceOf(address(swap));
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requested);
        tokensOutCumulative += swapTokenBefore - token.balanceOf(address(swap));
        // A BUY's USDC leg is what the swap took IN.
        _recordFill(feedRound, usdc.balanceOf(address(swap)) - swapUsdcBefore);
    }

    /// REDEEM: taker draws bond tokens into the swap for USDC, at a fixed on-NAV price.
    /// Both legs share one budget, so the token draw is converted to its USDC value and
    /// clamped the same way `buy` is: 1e18 bond wei ⇔ 100e6 USDC ⇒ 1 USDC unit ⇔ 1e10 wei.
    function redeem(uint256 drawSeed) external {
        uint256 remaining = _remainingRoundBudget();
        if (remaining < MIN_FILL_NOTIONAL) {
            skippedForBudget++;
            return;
        }
        uint256 affordable = remaining * 1e10; // USDC budget expressed in bond wei
        uint256 ceiling = MAX_FILL_NOTIONAL * 1e10;
        uint256 maxAmountIn = affordable < ceiling ? affordable : ceiling;
        uint256 requested = bound(drawSeed, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: nextQuoteId++,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: maxAmountIn,
            tokenOut: address(usdc),
            price: 100e6,
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, swap.hashSwapMessage(m));
        bytes memory sig = abi.encodePacked(r, s, v);

        uint64 feedRound = _feedRound();
        uint256 swapUsdcBefore = usdc.balanceOf(address(swap));
        // REDEEM pulls tokens in — taker approved the swap in setUp.
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requested);
        // A REDEEM's USDC leg is what the swap paid OUT.
        _recordFill(feedRound, swapUsdcBefore - usdc.balanceOf(address(swap)));
    }

    /// Publish a STRICTLY NEWER NAV round. Crossing a round boundary is the only thing
    /// that re-opens the budget, so this is what lets a fuzz sequence exercise the RESET
    /// path rather than just running into the cap and stopping. `updatedAt` is set to
    /// `block.timestamp` after the warp: never future-dated (StaleNav) and never stale.
    function advanceNavRound(uint256 stepSeed) external {
        vm.warp(block.timestamp + bound(stepSeed, 1, 1 hours));
        navFeed.setUpdatedAt(block.timestamp);
        roundAdvances++;
        _observeRound();
    }

    /// Re-date the feed BACKWARDS (still comfortably inside maxNavAge). A round key that
    /// moves backwards must NOT re-open an already-spent budget: `_drawNavRoundNotional`
    /// resets only on a STRICTLY newer round, so the counter stays pinned to the highest
    /// round it has seen. `invariant_navRound_never_moves_backwards` is what enforces it.
    function regressNavRound(uint256 backSeed) external {
        navFeed.setUpdatedAt(block.timestamp - bound(backSeed, 1, 30 minutes));
        roundRegressions++;
        _observeRound();
    }

    /// The REFUSAL path, on purpose: ask for strictly more than the round still admits.
    /// try/catch is mandatory here — `fail_on_revert = true` would abort the run on the
    /// (expected) revert — and note the failure this hunts is the call SUCCEEDING.
    function buyBeyondRoundBudget(uint256 overSeed) external {
        uint256 requested = _remainingRoundBudget() + bound(overSeed, 1, MAX_FILL_NOTIONAL);

        // maxAmountIn == requested, so the MIN_DRAW_BPS floor is met by construction.
        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: nextQuoteId++,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: requested,
            tokenOut: address(token),
            price: 1e28,
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, swap.hashSwapMessage(m));
        bytes memory sig = abi.encodePacked(r, s, v);

        (uint64 roundBefore, uint256 drawnBefore) = swap.navRoundNotionalDrawn(address(token));
        vm.prank(taker);
        try swap.executeSwap(m, sig, _noPermit(), requested) {
            revert("FIND-021: a fill above the round budget settled");
        } catch (bytes memory err) {
            require(
                // Selector extraction: revert data shorter than 4 bytes zero-pads and
                // then fails this require, which is the outcome we want anyway.
                // forge-lint: disable-next-line(unsafe-typecast)
                bytes4(err) == GyldAtomicSwap.NavRoundNotionalExceeded.selector,
                "over-budget fill refused for the wrong reason"
            );
            capRefusals++;
        }
        (uint64 roundAfter, uint256 drawnAfter) = swap.navRoundNotionalDrawn(address(token));
        require(roundAfter == roundBefore && drawnAfter == drawnBefore, "a refused fill moved the counter");
        _observeRound();
    }

    // ── Handler internals ─────────────────────────────────────────────────────

    /// What the series' current NAV round still admits, mirroring
    /// `_drawNavRoundNotional`: a strictly newer feed round means the next fill starts
    /// from a clean budget, otherwise the spend so far is charged against the cap.
    function _remainingRoundBudget() internal view returns (uint256) {
        uint256 cap = swap.maxNavRoundNotionalFor(address(token));
        (uint64 round, uint256 drawn) = swap.navRoundNotionalDrawn(address(token));
        if (_feedRound() > round) return cap; // this fill opens a fresh round
        return drawn >= cap ? 0 : cap - drawn;
    }

    function _feedRound() internal view returns (uint64) {
        (,,, uint256 updatedAt,) = navFeed.latestRoundData();
        // Mirrors the contract's own round key: a block timestamp, never near 2**64.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(updatedAt);
    }

    function _recordFill(uint64 feedRound, uint256 usdcLeg) internal {
        if (feedRound > ghostRound) {
            ghostRound = feedRound;
            ghostDrawn = usdcLeg;
        } else {
            ghostDrawn += usdcLeg;
        }
        fills++;
        _observeRound();
    }

    function _observeRound() internal {
        (uint64 round,) = swap.navRoundNotionalDrawn(address(token));
        if (round > maxRoundObserved) maxRoundObserved = round;
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }
}

contract GyldAtomicSwapInvariantsTest is StdInvariant, Test {
    GyldAtomicSwap swap;
    GyldBondToken token;
    MockUSDCPermit usdc;
    MockNavForwarder navFeed;
    SwapHandler handler;

    address admin = address(0xA0);
    address pauser = address(0xA1);

    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK = 0xA11CE;
    address taker;

    /// Per-NAV-round notional budget for the series under test (FIND-021). Deliberately
    /// far below DEFAULT_MAX_NAV_ROUND_NOTIONAL ($1M) so a depth-50 sequence exhausts it
    /// several times over: the handler's largest fill is 100_000e6, so ~3 fills close a
    /// round and the guard is fuzzed as a live constraint rather than slack.
    uint256 constant ROUND_CAP = 250_000e6;

    /// Captured in setUp — the bond totalSupply after deployment + inventory mint.
    /// The swap only ever transfers pre-minted tokens, so this must never move.
    uint256 immutableBondSupply;

    function setUp() public {
        vm.warp(1_750_000_000);
        taker = vm.addr(TAKER_PK);

        MockSanctionsList mockSanctions = new MockSanctionsList(address(this));
        usdc = new MockUSDCPermit();
        navFeed = new MockNavForwarder(100e8);

        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeCall(
                        GyldBondToken.initialize,
                        ("Gyld Bond", "GYLD", "US912797KR72", 1_780_000_000, admin, pauser, address(mockSanctions))
                    )
                )
            )
        );

        GyldAtomicSwap swapImpl = new GyldAtomicSwap();
        swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(swapImpl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, vm.addr(SIGNER_PK), address(0xA2), address(usdc), 200, 1 days)
                    )
                )
            )
        );

        bytes32 allowlistRole = swap.ALLOWLIST_ADMIN_ROLE();
        vm.startPrank(admin);
        swap.registerSeries(address(token), address(navFeed));
        swap.setWithdrawalWallet(address(0xA3));
        swap.grantRole(allowlistRole, admin); // setAllowed gate (GYL-1050)
        swap.setAllowed(taker, true);
        // FIND-021: bind the series to a budget the fuzz sequence can actually exhaust.
        swap.setMaxNavRoundNotionalFor(address(token), ROUND_CAP);
        vm.stopPrank();
        // admin grants MINTER_ROLE to this test contract; it then mints as itself.
        // Read MINTER_ROLE() before vm.prank — the getter is an external call that
        // would otherwise consume the single-call prank.
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
        // Inventory and balances are sized so that the ROUND CAP — not a balance — is
        // always the binding constraint. Worst case a depth-50 run opens a fresh NAV
        // round on every step and spends the full ROUND_CAP on each: 50 * $250k = $12.5M
        // of USDC and 125_000e18 of bond tokens in one direction. Everything below is at
        // least an order of magnitude clear of that, so no sequence can run out of
        // inventory mid-run (which would revert under fail_on_revert and abort the run).
        token.mint(address(swap), 10_000_000e18);
        token.mint(taker, 10_000_000e18);
        usdc.mint(taker, 1_000_000_000e6);
        usdc.mint(address(swap), 1_000_000_000e6);

        immutableBondSupply = token.totalSupply();

        handler = new SwapHandler(swap, token, usdc, navFeed, taker, SIGNER_PK);
        // Taker approves the swap for both legs once — handler swaps need no permit.
        vm.prank(taker);
        usdc.approve(address(swap), type(uint256).max);
        vm.prank(taker);
        token.approve(address(swap), type(uint256).max);

        targetContract(address(handler));
    }

    // ── NEVER-MINTS (stateful): totalSupply is constant across any swap sequence.

    /// The swap has no MINTER/BURNER role on the bond token; executeSwap only
    /// transfers pre-minted inventory. Therefore token.totalSupply() is an
    /// invariant regardless of how many BUY/REDEEM swaps the handler runs.
    function invariant_bond_totalSupply_never_changes() external view {
        assertEq(token.totalSupply(), immutableBondSupply, "swap must never mint or burn bond tokens");
    }

    /// Tokens are neither created nor destroyed — the sum of all balances equals
    /// totalSupply exactly (no rounding, no phantom issuance) after any sequence.
    function invariant_no_phantom_token_balances() external view {
        assertEq(
            token.totalSupply(),
            token.balanceOf(taker) + token.balanceOf(address(swap)),
            "sum(balances) != totalSupply - value was created or destroyed"
        );
    }

    /// USDC conservation, which must keep holding while the cap is biting: the swap and
    /// the taker are the only holders, nothing is withdrawn, so no fill — settled or
    /// refused — may create or destroy cash.
    function invariant_usdc_conserved_across_swaps() external view {
        assertEq(
            usdc.totalSupply(),
            usdc.balanceOf(taker) + usdc.balanceOf(address(swap)),
            "USDC was created or destroyed by a swap sequence"
        );
    }

    // ── FIND-021: the per-NAV-round notional cap ─────────────────────────────

    /// CORE SAFETY PROPERTY. No sequence of fills — any mix of BUY and REDEEM, any
    /// interleaving with NAV pushes, forwards or backwards — may settle more USDC
    /// notional against a single NAV round than that series' EFFECTIVE cap.
    function invariant_navRoundNotional_never_exceeds_cap() external view {
        (, uint256 drawn) = swap.navRoundNotionalDrawn(address(token));
        assertLe(
            drawn,
            swap.maxNavRoundNotionalFor(address(token)),
            "notional settled against one NAV round exceeded the series cap"
        );
    }

    /// The counter's round key is monotone. It is what scopes the budget, so a key that
    /// moves backwards re-opens an already-spent round: a feed that reports A, then B,
    /// then A again would settle 2x the cap against A. `maxRoundObserved` is the highest
    /// key the counter has ever held, and the handler regresses the feed on purpose.
    function invariant_navRound_never_moves_backwards() external view {
        (uint64 round,) = swap.navRoundNotionalDrawn(address(token));
        assertGe(round, handler.maxRoundObserved(), "the NAV round key moved backwards");
        assertLe(uint256(round), block.timestamp, "the NAV round key is future-dated");
    }

    /// Full mirror of the counter, recomputed from the observed USDC leg of every
    /// settled fill. Stronger than the `<= cap` bound above, which an implementation
    /// that simply never charged anything would also satisfy: this pins WHICH amount is
    /// charged (the USDC leg of both directions) and WHEN the reset fires.
    function invariant_navRoundCounter_matches_observed_fills() external view {
        (uint64 round, uint256 drawn) = swap.navRoundNotionalDrawn(address(token));
        assertEq(uint256(round), uint256(handler.ghostRound()), "counter is keyed on the wrong NAV round");
        assertEq(drawn, handler.ghostDrawn(), "drawn != the USDC notional actually settled this round");
    }

    // ── Teeth check: the fixture must genuinely reach the cap ────────────────

    /// Guards the invariant suite against going vacuous. Everything above is only
    /// meaningful if a run actually exhausts a round budget, so this drives the handler
    /// deterministically through the exhaust → refuse → reset cycle. Seeds are passed
    /// inside `bound`'s range, so each one is used verbatim as the draw.
    function test_handler_exhaustsRoundBudget_thenRefuses_thenResets() public {
        uint256 cap = swap.maxNavRoundNotionalFor(address(token));
        assertEq(cap, ROUND_CAP, "fixture must bind the series to the small round cap");

        // Spend the round budget down to zero in whole 100k fills.
        for (uint256 i; i < 10; i++) {
            (, uint256 spent) = swap.navRoundNotionalDrawn(address(token));
            uint256 remaining = cap - spent;
            uint256 fill = remaining < handler.MAX_FILL_NOTIONAL() ? remaining : handler.MAX_FILL_NOTIONAL();
            if (fill == 0) break;
            handler.buy(fill);
        }
        (uint64 roundA, uint256 drawn) = swap.navRoundNotionalDrawn(address(token));
        assertEq(drawn, cap, "handler fills must be able to exhaust a round budget exactly");

        // With the budget gone the handler stops filling rather than reverting — that is
        // what keeps `fail_on_revert = true` runs alive once the cap starts biting.
        uint256 skippedBefore = handler.skippedForBudget();
        handler.buy(50_000e6);
        assertEq(handler.skippedForBudget(), skippedBefore + 1, "an exhausted round must skip, not revert");
        (, uint256 unchangedDrawn) = swap.navRoundNotionalDrawn(address(token));
        assertEq(unchangedDrawn, cap, "a skipped fill must not move the counter");

        // ... and an explicit over-budget attempt is refused by the cap itself.
        handler.buyBeyondRoundBudget(1e6);
        assertEq(handler.capRefusals(), 1, "the over-budget fill must be refused by NavRoundNotionalExceeded");

        // A backwards NAV push must NOT hand the round its budget back.
        handler.regressNavRound(15 minutes);
        skippedBefore = handler.skippedForBudget();
        handler.buy(50_000e6);
        assertEq(handler.skippedForBudget(), skippedBefore + 1, "a rewound feed must not re-open the budget");
        (uint64 stillRoundA, uint256 stillDrawn) = swap.navRoundNotionalDrawn(address(token));
        assertEq(stillRoundA, roundA, "the counter must stay pinned to the highest round seen");
        assertEq(stillDrawn, cap, "a rewound feed must not zero the spent notional");

        // A strictly newer round does, and the counter restarts from that fill alone.
        handler.advanceNavRound(30 minutes);
        handler.buy(handler.MAX_FILL_NOTIONAL());
        (uint64 roundB, uint256 afterReset) = swap.navRoundNotionalDrawn(address(token));
        (,,, uint256 feedUpdatedAt,) = navFeed.latestRoundData();
        assertEq(uint256(roundB), feedUpdatedAt, "the counter must re-key onto the new feed round");
        assertGt(roundB, roundA, "the new round key must be strictly newer");
        assertEq(afterReset, handler.MAX_FILL_NOTIONAL(), "a new round restarts the budget from this fill alone");

        // The ghost mirror the invariants assert against tracked all of it.
        assertEq(handler.ghostDrawn(), afterReset, "ghost mirror drifted from the contract counter");
        assertEq(handler.ghostRound(), roundB, "ghost round drifted from the contract counter");
    }

    /// The REDEEM leg draws on the same budget: the handler must be able to exhaust a
    /// round through redemptions alone, which is what makes the fuzzed mix meaningful.
    function test_handler_redeemAlsoExhaustsRoundBudget() public {
        uint256 cap = swap.maxNavRoundNotionalFor(address(token));
        for (uint256 i; i < 10; i++) {
            (, uint256 spent) = swap.navRoundNotionalDrawn(address(token));
            uint256 remaining = cap - spent;
            uint256 fillNotional = remaining < handler.MAX_FILL_NOTIONAL() ? remaining : handler.MAX_FILL_NOTIONAL();
            if (fillNotional == 0) break;
            handler.redeem(fillNotional * 1e10); // seed == the exact bond-wei draw
        }
        (, uint256 drawn) = swap.navRoundNotionalDrawn(address(token));
        assertEq(drawn, cap, "redemptions must charge the same round budget as buys");
        assertEq(handler.ghostDrawn(), drawn, "redeem must charge the USDC leg, not the bond leg");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// FIND-021 at production scale. The spec suite (GyldAtomicSwap.spec.t.sol) pins
// the cap's semantics with $1,000-sized fixtures; this contract pins the same
// behaviour against the SHIPPED default — $1,000,000 per NAV round, drained by
// ten $100,000 fills — where an off-by-one or an overshoot is measured in real
// money and a uint192 counter is carrying six-figure values.
// ─────────────────────────────────────────────────────────────────────────────
contract GyldAtomicSwapNavRoundScaleTest is Test {
    GyldAtomicSwap swap;
    GyldBondToken token;
    MockUSDCPermit usdc;
    MockNavForwarder navFeed;

    address admin = address(0xA0);
    address pauser = address(0xA1);

    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK = 0xA11CE;
    address taker;

    /// The shipped fallback: $1M of USDC notional per NAV round, per series.
    uint256 constant CAP = 1_000_000e6;
    /// Ten of these drain it exactly.
    uint256 constant FILL = 100_000e6;

    uint256 nextQuoteId = 1;

    function setUp() public {
        vm.warp(1_750_000_000);
        taker = vm.addr(TAKER_PK);

        MockSanctionsList mockSanctions = new MockSanctionsList(address(this));
        usdc = new MockUSDCPermit();
        navFeed = new MockNavForwarder(100e8);

        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeCall(
                        GyldBondToken.initialize,
                        ("Gyld Bond", "GYLD", "US912797KR72", 1_780_000_000, admin, pauser, address(mockSanctions))
                    )
                )
            )
        );

        GyldAtomicSwap swapImpl = new GyldAtomicSwap();
        swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(swapImpl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, vm.addr(SIGNER_PK), address(0xA2), address(usdc), 200, 1 days)
                    )
                )
            )
        );

        bytes32 allowlistRole = swap.ALLOWLIST_ADMIN_ROLE();
        vm.startPrank(admin);
        swap.registerSeries(address(token), address(navFeed));
        swap.setWithdrawalWallet(address(0xA3));
        swap.grantRole(allowlistRole, admin);
        swap.setAllowed(taker, true);
        vm.stopPrank();
        // No setMaxNavRoundNotionalFor call anywhere in this fixture, deliberately: these
        // tests must exercise the UNCONFIGURED series' effective cap, i.e. the fallback.

        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
        // Sized so the CAP, never a balance, is the binding constraint: the busiest test
        // below settles ~$2M in one direction, which is 100_000e18 of bond tokens.
        token.mint(address(swap), 10_000_000e18);
        token.mint(taker, 1_000_000e18);
        usdc.mint(taker, 100_000_000e6);
        usdc.mint(address(swap), 100_000_000e6);

        vm.startPrank(taker);
        usdc.approve(address(swap), type(uint256).max);
        token.approve(address(swap), type(uint256).max);
        vm.stopPrank();
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _buyMessage(uint256 usdcIn) internal returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId: nextQuoteId++,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: usdcIn, // full-draw quote: requested == maxAmountIn
            tokenOut: address(token),
            price: 1e28, // on NAV: $100/token
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });
    }

    function _redeemMessage(uint256 tokensIn) internal returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId: nextQuoteId++,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: tokensIn,
            tokenOut: address(usdc),
            price: 100e6,
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });
    }

    function _sign(GyldAtomicSwap.SwapMessage memory m) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, swap.hashSwapMessage(m));
        return abi.encodePacked(r, s, v);
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    /// Settle a full-size BUY of `usdcIn`. The signature is computed BEFORE the prank:
    /// hashSwapMessage is an external call and would otherwise consume it (NotTaker).
    function _buy(uint256 usdcIn) internal {
        GyldAtomicSwap.SwapMessage memory m = _buyMessage(usdcIn);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), usdcIn);
    }

    /// Publish a strictly newer NAV round one hour on (>= the feed's real 1 h minimum
    /// update interval). Quotes must be built AFTER this, or they are already expired.
    function _pushNewNavRound() internal returns (uint64 newRound) {
        vm.warp(block.timestamp + 1 hours);
        navFeed.setUpdatedAt(block.timestamp);
        return uint64(block.timestamp);
    }

    function _drawn() internal view returns (uint256 drawn) {
        (, drawn) = swap.navRoundNotionalDrawn(address(token));
    }

    // ── A. The cap bites at scale ─────────────────────────────────────────────

    /// Ten $100k fills drain the shipped $1M budget to the last unit, and the eleventh
    /// is refused with remaining == 0 — the cap bounds AGGREGATE notional even though
    /// every one of those fills passes every per-fill guard.
    function test_scale_tenHundredThousandFills_drainTheDefaultCap() public {
        assertEq(swap.maxNavRoundNotionalFor(address(token)), CAP, "unconfigured series must use the $1M default");

        for (uint256 i; i < 10; i++) {
            _buy(FILL);
            assertEq(_drawn(), FILL * (i + 1), "each fill must charge its full USDC leg");
        }
        assertEq(_drawn(), CAP, "ten $100k fills must land exactly on the $1M budget");

        // The eleventh is individually legal — in band, unexpired, fresh quoteId, ample
        // inventory — and refused purely because the round has nothing left.
        GyldAtomicSwap.SwapMessage memory over = _buyMessage(FILL);
        bytes memory sig = _sign(over);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.NavRoundNotionalExceeded.selector, address(token), FILL, 0, CAP)
        );
        vm.prank(taker);
        swap.executeSwap(over, sig, _noPermit(), FILL);

        // Refused BEFORE any transfer: the taker keeps the cash, the swap keeps the bonds.
        assertEq(_drawn(), CAP, "a refused fill must not charge the budget");
    }

    /// No overshoot and no off-by-one at the boundary: a fill sized to exactly the
    /// remaining budget settles, and lands `drawn` on the cap to the unit — while one
    /// single USDC unit more is refused, with `remaining` reported exactly.
    function test_scale_fillSizedExactlyAtRemaining_landsOnTheCap() public {
        for (uint256 i; i < 9; i++) {
            _buy(FILL);
        }
        uint256 remaining = CAP - _drawn();
        assertEq(remaining, FILL, "precondition: $100k of the $1M budget is left");

        // One unit over the line is refused, and the error carries the exact numbers the
        // quote service needs to re-issue against.
        GyldAtomicSwap.SwapMessage memory over = _buyMessage(remaining + 1);
        bytes memory overSig = _sign(over);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.NavRoundNotionalExceeded.selector, address(token), remaining + 1, remaining, CAP
            )
        );
        vm.prank(taker);
        swap.executeSwap(over, overSig, _noPermit(), remaining + 1);

        // Exactly at the line settles.
        uint256 takerTokensBefore = token.balanceOf(taker);
        _buy(remaining);
        assertEq(_drawn(), CAP, "an exact-remaining fill must land on the cap, never past it");
        assertEq(
            token.balanceOf(taker) - takerTokensBefore, remaining * 1e10, "the exact-remaining fill must have settled"
        );

        // And the budget is now closed to everything, down to a single USDC unit.
        GyldAtomicSwap.SwapMessage memory dust = _buyMessage(1);
        bytes memory dustSig = _sign(dust);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.NavRoundNotionalExceeded.selector, address(token), 1, 0, CAP)
        );
        vm.prank(taker);
        swap.executeSwap(dust, dustSig, _noPermit(), 1);
    }

    // ── B. A strictly newer round genuinely resets the budget ────────────────

    /// After the budget is exhausted, a NAV push re-opens it: a large fill settles again,
    /// `drawn` restarts from that fill ALONE (it is not carried over), and the counter is
    /// re-keyed onto the feed's new `updatedAt`.
    function test_scale_newNavRoundResetsBudgetAndRekeysCounter() public {
        for (uint256 i; i < 10; i++) {
            _buy(FILL);
        }
        (uint64 oldRound, uint256 spent) = swap.navRoundNotionalDrawn(address(token));
        assertEq(spent, CAP, "precondition: the round budget is exhausted");

        uint64 newRound = _pushNewNavRound();
        assertGt(newRound, oldRound, "the new round key must be STRICTLY newer");

        // A fill far larger than anything the old round had left settles immediately.
        uint256 bigFill = 750_000e6;
        _buy(bigFill);

        (uint64 storedRound, uint256 drawn) = swap.navRoundNotionalDrawn(address(token));
        (,,, uint256 feedUpdatedAt,) = navFeed.latestRoundData();
        assertEq(drawn, bigFill, "a new round must restart from this fill alone, not from $1M + fill");
        assertEq(uint256(storedRound), feedUpdatedAt, "the counter must be keyed on the feed's new updatedAt");
        assertEq(uint256(storedRound), uint256(newRound), "the round key must equal the pushed updatedAt exactly");

        // The rest of the fresh budget is spendable, and stops on the cap again.
        _buy(CAP - bigFill);
        assertEq(_drawn(), CAP, "the reset budget is the full cap, no more and no less");

        GyldAtomicSwap.SwapMessage memory over = _buyMessage(FILL);
        bytes memory sig = _sign(over);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.NavRoundNotionalExceeded.selector, address(token), FILL, 0, CAP)
        );
        vm.prank(taker);
        swap.executeSwap(over, sig, _noPermit(), FILL);
    }

    /// Consecutive rounds do not accumulate: each NAV push starts the series' budget over
    /// at the cap, no matter how many full rounds preceded it.
    function test_scale_everyNavRoundGetsAFullBudget() public {
        for (uint256 round; round < 3; round++) {
            for (uint256 i; i < 10; i++) {
                _buy(FILL);
            }
            assertEq(_drawn(), CAP, "each round must absorb exactly the cap");
            uint64 pushed = _pushNewNavRound();
            (uint64 storedRound,) = swap.navRoundNotionalDrawn(address(token));
            assertLt(storedRound, pushed, "the counter is still keyed on the round just closed");
        }
        // Three full rounds settled $3M in aggregate; the counter never held more than $1M.
        assertEq(usdc.balanceOf(address(swap)) - 100_000_000e6, 3 * CAP, "three rounds must have settled $3M");
    }

    // ── C. Redemptions draw on the same budget at scale ──────────────────────

    /// The cap is denominated in USDC, so a $1M round is $1M of settlement in EITHER
    /// direction: five $100k buys plus five $100k redemptions exhaust the same budget.
    function test_scale_buysAndRedemptionsShareOneMillionBudget() public {
        uint256 redeemTokens = FILL * 1e10; // $100k of bonds at $100/token = 1_000e18

        for (uint256 i; i < 5; i++) {
            _buy(FILL);
        }
        for (uint256 i; i < 5; i++) {
            GyldAtomicSwap.SwapMessage memory sell = _redeemMessage(redeemTokens);
            bytes memory sellSig = _sign(sell);
            vm.prank(taker);
            swap.executeSwap(sell, sellSig, _noPermit(), redeemTokens);
        }
        assertEq(_drawn(), CAP, "both directions must charge one shared budget");

        GyldAtomicSwap.SwapMessage memory over = _redeemMessage(redeemTokens);
        bytes memory sig = _sign(over);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.NavRoundNotionalExceeded.selector, address(token), FILL, 0, CAP)
        );
        vm.prank(taker);
        swap.executeSwap(over, sig, _noPermit(), redeemTokens);
    }

    /// A configured series is bounded by ITS cap at scale, not by the $1M fallback —
    /// the deploy-time policy value ($10M) must actually be reachable and enforced.
    function test_scale_configuredSeriesCapReplacesTheDefault() public {
        vm.prank(admin);
        swap.setMaxNavRoundNotionalFor(address(token), 10_000_000e6);
        assertEq(swap.maxNavRoundNotionalFor(address(token)), 10_000_000e6, "the $10M policy cap must take effect");

        // $2M against one round — impossible under the fallback, fine under the override.
        for (uint256 i; i < 20; i++) {
            _buy(FILL);
        }
        assertEq(_drawn(), 2_000_000e6, "the override must admit notional the default would refuse");

        // Tightening the cap below what is already spent saturates `remaining` at zero
        // rather than underflowing, and closes the round immediately.
        vm.prank(admin);
        swap.setMaxNavRoundNotionalFor(address(token), 1_500_000e6);
        GyldAtomicSwap.SwapMessage memory over = _buyMessage(FILL);
        bytes memory sig = _sign(over);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.NavRoundNotionalExceeded.selector, address(token), FILL, 0, 1_500_000e6
            )
        );
        vm.prank(taker);
        swap.executeSwap(over, sig, _noPermit(), FILL);
    }
}
