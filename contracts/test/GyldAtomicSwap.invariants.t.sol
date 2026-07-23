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
// The audit-prep checklist (lib/gyld-contracts/docs/atomic-settlement.md) flags
// the absence of a stateful invariant suite over executeSwap as outstanding.
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

        MockSanctionsList mockSanctions = new MockSanctionsList();
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
            expiry: uint64(block.timestamp + 15 minutes),
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
            expiry: uint64(block.timestamp + 15 minutes),
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
// ─────────────────────────────────────────────────────────────────────────────
contract SwapHandler is CommonBase, StdCheats, StdUtils {
    GyldAtomicSwap public swap;
    GyldBondToken public token;
    MockUSDCPermit public usdc;

    address public taker;
    uint256 public signerPk;

    /// Monotonic quoteId counter — every handler swap uses a fresh id so the
    /// single-use BitInvalidator never trips during the fuzz sequence (that
    /// guard is covered by the replay fuzz test above).
    uint256 public nextQuoteId = 1_000;

    /// Total bond tokens moved OUT of the swap across all BUYs (for accounting
    /// cross-checks); never asserted directly, only via the invariant contract.
    uint256 public tokensOutCumulative;

    constructor(
        GyldAtomicSwap swap_,
        GyldBondToken token_,
        MockUSDCPermit usdc_,
        address taker_,
        uint256 signerPk_
    ) {
        swap = swap_;
        token = token_;
        usdc = usdc_;
        taker = taker_;
        signerPk = signerPk_;
    }

    /// BUY: taker draws USDC into the swap for bond tokens, at a fixed on-NAV price.
    function buy(uint256 drawSeed) external {
        uint256 maxAmountIn = 100e6; // small cap so many swaps fit in taker USDC balance
        uint256 requested = bound(drawSeed, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: nextQuoteId++,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: maxAmountIn,
            tokenOut: address(token),
            price: 1e28,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, swap.hashSwapMessage(m));
        bytes memory sig = abi.encodePacked(r, s, v);

        uint256 swapTokenBefore = token.balanceOf(address(swap));
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requested);
        tokensOutCumulative += swapTokenBefore - token.balanceOf(address(swap));
    }

    /// REDEEM: taker draws bond tokens into the swap for USDC, at a fixed on-NAV price.
    function redeem(uint256 drawSeed) external {
        uint256 maxAmountIn = 1e18; // small cap so many swaps fit in taker token balance
        uint256 requested = bound(drawSeed, maxAmountIn / 100, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: nextQuoteId++,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: maxAmountIn,
            tokenOut: address(usdc),
            price: 100e6,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, swap.hashSwapMessage(m));
        bytes memory sig = abi.encodePacked(r, s, v);

        // REDEEM pulls tokens in — taker approved the swap in setUp.
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requested);
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }
}

contract GyldAtomicSwapInvariantsTest is StdInvariant, Test {
    GyldAtomicSwap swap;
    GyldBondToken token;
    MockUSDCPermit usdc;
    SwapHandler handler;

    address admin = address(0xA0);
    address pauser = address(0xA1);

    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK = 0xA11CE;
    address taker;

    /// Captured in setUp — the bond totalSupply after deployment + inventory mint.
    /// The swap only ever transfers pre-minted tokens, so this must never move.
    uint256 immutableBondSupply;

    function setUp() public {
        vm.warp(1_750_000_000);
        taker = vm.addr(TAKER_PK);

        MockSanctionsList mockSanctions = new MockSanctionsList();
        usdc = new MockUSDCPermit();
        MockNavForwarder navFeed = new MockNavForwarder(100e8);

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

        vm.startPrank(admin);
        swap.registerSeries(address(token), address(navFeed));
        swap.setWithdrawalWallet(address(0xA3));
        swap.setAllowed(taker, true);
        vm.stopPrank();
        // admin grants MINTER_ROLE to this test contract; it then mints as itself.
        // Read MINTER_ROLE() before vm.prank — the getter is an external call that
        // would otherwise consume the single-call prank.
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
        // Large inventory + taker balances so a depth-50 fuzz sequence never
        // runs out of inventory mid-sequence (which would revert under
        // fail_on_revert and abort the run).
        token.mint(address(swap), 1_000_000e18);
        token.mint(taker, 100_000e18);
        usdc.mint(taker, 100_000_000e6);
        usdc.mint(address(swap), 100_000_000e6);

        immutableBondSupply = token.totalSupply();

        handler = new SwapHandler(swap, token, usdc, taker, SIGNER_PK);
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
}
