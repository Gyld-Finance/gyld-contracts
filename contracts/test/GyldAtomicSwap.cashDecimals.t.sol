// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockStablecoin} from "./MockStablecoin.sol";
import {MockNavForwarder} from "./MockNavForwarder.sol";

/// GLD-713: the cash leg may carry 6..18 decimals (an 18dp stablecoin on BSC testnet).
/// Every economic test here runs the SAME dollar quote against a 6dp and an 18dp swap and
/// asserts identical outcomes — the band and the FIND-021 cap must not be able to tell
/// the two chains apart.
contract GyldAtomicSwapCashDecimalsTest is Test {
    GyldBondToken token;
    MockNavForwarder navFeed;
    MockSanctionsList mockSanctions;

    GyldAtomicSwap swap6;
    MockStablecoin cash6;
    GyldAtomicSwap swap18;
    MockStablecoin cash18;

    address admin = address(0xA0);
    address pauser = address(0xA1);
    address treasurer = address(0xA2);

    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK = 0xA11CE;
    address signer;
    address taker;

    int256 constant NAV = 100e8; // $100.00 per token, 8dp
    uint16 constant MAX_BPS = 200; // 2% band
    uint32 constant MAX_NAV_AGE = 1 days;

    // erc7201:gyld.GyldAtomicSwap base; cashDecimals is the appended field at B+12.
    bytes32 constant STORAGE_BASE = 0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300;
    bytes32 constant CASH_DECIMALS_SLOT = bytes32(uint256(STORAGE_BASE) + 12);

    function setUp() public {
        vm.warp(1_750_000_000);
        signer = vm.addr(SIGNER_PK);
        taker = vm.addr(TAKER_PK);

        mockSanctions = new MockSanctionsList(address(this));
        navFeed = new MockNavForwarder(NAV);

        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeCall(
                        GyldBondToken.initialize,
                        (
                            "Gyld US Treasury Bond 2026-06",
                            "GYLD-UST-2606",
                            "US912797KR72",
                            1_780_000_000,
                            admin,
                            pauser,
                            address(mockSanctions)
                        )
                    )
                )
            )
        );
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
        token.mint(taker, 1_000e18);

        cash6 = new MockStablecoin(6);
        cash18 = new MockStablecoin(18);
        swap6 = _wire(cash6);
        swap18 = _wire(cash18);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _deploy(address cashToken) internal returns (GyldAtomicSwap) {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        return GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, cashToken, MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );
    }

    /// A registered, funded swap over `cash` with the taker allowlisted and approved.
    function _wire(MockStablecoin cash) internal returns (GyldAtomicSwap s) {
        s = _deploy(address(cash));
        vm.prank(admin);
        s.registerSeries(address(token), address(navFeed));
        bytes32 allowlistRole = s.ALLOWLIST_ADMIN_ROLE();
        vm.prank(admin);
        s.grantRole(allowlistRole, admin);
        vm.prank(admin);
        s.setAllowed(taker, true);

        uint256 dollar = 10 ** uint256(cash.decimals());
        token.mint(address(s), 1_000e18);
        cash.mint(address(s), 1_000_000 * dollar);
        cash.mint(taker, 1_000_000 * dollar);
        vm.startPrank(taker);
        cash.approve(address(s), type(uint256).max);
        token.approve(address(s), type(uint256).max);
        vm.stopPrank();
    }

    function _dollar(GyldAtomicSwap s) internal view returns (uint256) {
        return 10 ** uint256(s.cashDecimals());
    }

    /// BUY `dollars` of bond at NAV skewed by `skewBps` (positive = more tokens out).
    /// price = tokens-out per 1e18 cash units; at NAV that is 1e34 / 10**d.
    function _buyQuote(GyldAtomicSwap s, uint256 quoteId, uint256 maxAmountIn, int256 skewBps)
        internal
        view
        returns (GyldAtomicSwap.SwapMessage memory)
    {
        uint256 atNav = 1e34 / _dollar(s);
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(s.usdc()),
            maxAmountIn: maxAmountIn,
            tokenOut: address(token),
            price: (atNav * uint256(int256(10_000) + skewBps)) / 10_000,
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: s.quoteEpoch()
        });
    }

    /// REDEEM `maxAmountIn` bond at NAV skewed by `skewBps` (positive = more cash out).
    /// price = cash-out per 1e18 bond; at NAV that is 100 * 10**d.
    function _redeemQuote(GyldAtomicSwap s, uint256 quoteId, uint256 maxAmountIn, int256 skewBps)
        internal
        view
        returns (GyldAtomicSwap.SwapMessage memory)
    {
        uint256 atNav = 100 * _dollar(s);
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: maxAmountIn,
            tokenOut: address(s.usdc()),
            price: (atNav * uint256(int256(10_000) + skewBps)) / 10_000,
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: s.quoteEpoch()
        });
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    /// Execute as the taker without bubbling the revert, so 6dp/18dp outcomes compare.
    function _try(GyldAtomicSwap s, GyldAtomicSwap.SwapMessage memory m, uint256 amountIn)
        internal
        returns (bool ok, bytes memory ret)
    {
        // Sign BEFORE the prank — hashSwapMessage is itself a call and would eat it.
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(SIGNER_PK, s.hashSwapMessage(m));
        bytes memory sig = abi.encodePacked(r, sg, v);
        vm.prank(taker);
        (ok, ret) = address(s).call(abi.encodeCall(GyldAtomicSwap.executeSwap, (m, sig, _noPermit(), amountIn)));
    }

    function _exec(GyldAtomicSwap s, GyldAtomicSwap.SwapMessage memory m, uint256 amountIn) internal {
        (bool ok, bytes memory ret) = _try(s, m, amountIn);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    // ── initialize: the 6..18 probe ───────────────────────────────────────────

    function test_initialize_6dpCash_ok() public {
        GyldAtomicSwap s = _deploy(address(new MockStablecoin(6)));
        assertEq(s.cashDecimals(), 6);
        assertEq(uint256(vm.load(address(s), CASH_DECIMALS_SLOT)), 6, "initialize must store the probe");
    }

    function test_initialize_18dpCash_ok() public {
        GyldAtomicSwap s = _deploy(address(new MockStablecoin(18)));
        assertEq(s.cashDecimals(), 18);
        assertEq(uint256(vm.load(address(s), CASH_DECIMALS_SLOT)), 18, "cashDecimals lives at B+12");
    }

    function testFuzz_initialize_inRangeCash_ok(uint8 d) public {
        d = uint8(bound(d, 6, 18));
        assertEq(_deploy(address(new MockStablecoin(d))).cashDecimals(), d);
    }

    function test_initialize_5dpCash_reverts() public {
        MockStablecoin c = new MockStablecoin(5);
        GyldAtomicSwap impl = new GyldAtomicSwap();
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidTokenDecimals.selector, address(c), uint8(5)));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(c), MAX_BPS, MAX_NAV_AGE)
            )
        );
    }

    function test_initialize_19dpCash_reverts() public {
        MockStablecoin c = new MockStablecoin(19);
        GyldAtomicSwap impl = new GyldAtomicSwap();
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidTokenDecimals.selector, address(c), uint8(19)));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(c), MAX_BPS, MAX_NAV_AGE)
            )
        );
    }

    // ── Upgrade fallback ──────────────────────────────────────────────────────

    /// A proxy upgraded from a pre-GLD-713 implementation never wrote B+12. It was
    /// necessarily initialized against 6dp cash, so the unset slot must read as 6 — and
    /// the band must still price exactly as before (a zero read would mean 10**26).
    function test_upgrade_unsetCashDecimalsSlot_fallsBackTo6() public {
        vm.store(address(swap6), CASH_DECIMALS_SLOT, bytes32(0));
        assertEq(uint256(vm.load(address(swap6), CASH_DECIMALS_SLOT)), 0, "precondition: slot unset");
        assertEq(swap6.cashDecimals(), 6, "unset must resolve to 6");

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(swap6, 1, 1_000e6, 0);
        _exec(swap6, m, m.maxAmountIn);
        assertEq(token.balanceOf(taker), 1_010e18, "10 tokens for $1,000 at NAV, as pre-upgrade");
        (, uint256 drawn) = swap6.navRoundNotionalDrawn(address(token));
        assertEq(drawn, 1_000e6, "cap charged in 6dp, unscaled");
    }

    // ── 18dp happy paths ──────────────────────────────────────────────────────

    function test_buy_18dpCash_happyPath() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(swap18, 1, 1_000e18, 0);
        assertEq(m.price, 1e16, "10e18 tokens per 1_000e18 cash");
        uint256 cashBefore = cash18.balanceOf(taker);
        _exec(swap18, m, m.maxAmountIn);
        assertEq(token.balanceOf(taker), 1_010e18, "10 tokens out");
        assertEq(cashBefore - cash18.balanceOf(taker), 1_000e18, "$1,000 in, 18dp");
        (, uint256 drawn) = swap18.navRoundNotionalDrawn(address(token));
        assertEq(drawn, 1_000e6, "FIND-021 counter is 6dp micro-USD on every chain");
    }

    function test_redeem_18dpCash_happyPath() public {
        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(swap18, 1, 10e18, 0);
        assertEq(m.price, 100e18, "$100 per token, 18dp");
        uint256 cashBefore = cash18.balanceOf(taker);
        _exec(swap18, m, m.maxAmountIn);
        assertEq(token.balanceOf(taker), 990e18, "10 tokens in");
        assertEq(cash18.balanceOf(taker) - cashBefore, 1_000e18, "$1,000 out, 18dp");
        (, uint256 drawn) = swap18.navRoundNotionalDrawn(address(token));
        assertEq(drawn, 1_000e6, "redeem charges the cash leg, normalised to 6dp");
    }

    // ── Band parity ───────────────────────────────────────────────────────────

    /// The same economic quote (NAV skewed by `skewBps`) passes or fails identically at
    /// 6dp and 18dp, and a failure is the same QuotePriceOutOfBand scaled by 1e12.
    function testFuzz_bandParity_buy(int256 skewBps) public {
        skewBps = bound(skewBps, -1_000, 1_000);
        GyldAtomicSwap.SwapMessage memory m6 = _buyQuote(swap6, 1, 1_000e6, skewBps);
        GyldAtomicSwap.SwapMessage memory m18 = _buyQuote(swap18, 1, 1_000e18, skewBps);
        (bool ok6, bytes memory ret6) = _try(swap6, m6, m6.maxAmountIn);
        (bool ok18, bytes memory ret18) = _try(swap18, m18, m18.maxAmountIn);
        assertEq(ok6, ok18, "band verdict must not depend on cash decimals");
        if (!ok6) _assertSameBandRevert(ret6, ret18);
        // Buy-side band in skew terms: 1/1.02 <= 1 + skew <= 1/0.98, i.e. [-196, +204] bps.
        assertEq(ok6, skewBps >= -196 && skewBps <= 204, "the band itself, not just parity");
    }

    function testFuzz_bandParity_redeem(int256 skewBps) public {
        skewBps = bound(skewBps, -1_000, 1_000);
        GyldAtomicSwap.SwapMessage memory m6 = _redeemQuote(swap6, 1, 10e18, skewBps);
        GyldAtomicSwap.SwapMessage memory m18 = _redeemQuote(swap18, 1, 10e18, skewBps);
        (bool ok6, bytes memory ret6) = _try(swap6, m6, m6.maxAmountIn);
        (bool ok18, bytes memory ret18) = _try(swap18, m18, m18.maxAmountIn);
        assertEq(ok6, ok18, "band verdict must not depend on cash decimals");
        if (!ok6) _assertSameBandRevert(ret6, ret18);
    }

    /// Pinned boundary: 2% band, skew exactly at and just past the edge, both scales.
    function test_bandParity_edges() public {
        int256[4] memory skews = [int256(200), int256(201), int256(-200), int256(-201)];
        bool[4] memory expectOk = [true, false, true, false];
        for (uint256 i = 0; i < 4; i++) {
            (bool ok6,) = _try(swap6, _redeemQuote(swap6, 10 + i, 10e18, skews[i]), 10e18);
            (bool ok18,) = _try(swap18, _redeemQuote(swap18, 10 + i, 10e18, skews[i]), 10e18);
            assertEq(ok6, expectOk[i], "6dp edge");
            assertEq(ok18, expectOk[i], "18dp edge");
        }
    }

    function _assertSameBandRevert(bytes memory ret6, bytes memory ret18) internal pure {
        assertEq(bytes4(ret6), GyldAtomicSwap.QuotePriceOutOfBand.selector, "6dp: band revert");
        assertEq(bytes4(ret18), GyldAtomicSwap.QuotePriceOutOfBand.selector, "18dp: band revert");
        (uint256 q6, uint256 n6) = abi.decode(_stripSelector(ret6), (uint256, uint256));
        (uint256 q18, uint256 n18) = abi.decode(_stripSelector(ret18), (uint256, uint256));
        assertEq(q18, q6 * 1e12, "quoted cash scales by exactly 1e12");
        assertEq(n18, n6 * 1e12, "NAV value scales by exactly 1e12");
    }

    function _stripSelector(bytes memory ret) internal pure returns (bytes memory out) {
        out = new bytes(ret.length - 4);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = ret[i + 4];
        }
    }

    // ── FIND-021 round notional cap in 6dp on every chain ─────────────────────

    /// The cap is set in 6dp units on both swaps and binds at the same dollar amount.
    function test_navRoundCap_18dpEqualsCapAt6dp() public {
        vm.startPrank(admin);
        swap6.setMaxNavRoundNotionalFor(address(token), 1_000e6);
        swap18.setMaxNavRoundNotionalFor(address(token), 1_000e6);
        vm.stopPrank();

        GyldAtomicSwap.SwapMessage memory a6 = _buyQuote(swap6, 1, 1_000e6, 0);
        GyldAtomicSwap.SwapMessage memory a18 = _buyQuote(swap18, 1, 1_000e18, 0);
        _exec(swap6, a6, a6.maxAmountIn);
        _exec(swap18, a18, a18.maxAmountIn);

        // One more dollar: identical NavRoundNotionalExceeded, args in 6dp on both.
        bytes memory expected = abi.encodeWithSelector(
            GyldAtomicSwap.NavRoundNotionalExceeded.selector, address(token), 1e6, 0, 1_000e6
        );
        (bool ok6, bytes memory ret6) = _try(swap6, _buyQuote(swap6, 2, 1e6, 0), 1e6);
        (bool ok18, bytes memory ret18) = _try(swap18, _buyQuote(swap18, 2, 1e18, 0), 1e18);
        assertFalse(ok6);
        assertFalse(ok18);
        assertEq(ret6, expected, "6dp");
        assertEq(ret18, expected, "18dp reports 6dp units, not 1e18");
    }

    /// Any whole-micro dollar amount: same verdict and same counter at 6dp and 18dp.
    function testFuzz_navRoundCap_parity(uint256 micro) public {
        micro = bound(micro, 1e6, 2_000e6);
        vm.startPrank(admin);
        swap6.setMaxNavRoundNotionalFor(address(token), 1_000e6);
        swap18.setMaxNavRoundNotionalFor(address(token), 1_000e6);
        vm.stopPrank();

        (bool ok6, bytes memory ret6) = _try(swap6, _buyQuote(swap6, 1, micro, 0), micro);
        (bool ok18, bytes memory ret18) = _try(swap18, _buyQuote(swap18, 1, micro * 1e12, 0), micro * 1e12);
        assertEq(ok6, micro <= 1_000e6, "6dp verdict");
        assertEq(ok18, ok6, "18dp verdict must match 6dp");
        assertEq(ret18, ret6, "identical revert data");
        (, uint256 d6) = swap6.navRoundNotionalDrawn(address(token));
        (, uint256 d18) = swap18.navRoundNotionalDrawn(address(token));
        assertEq(d18, d6, "identical 6dp counter");
    }

    /// A sub-micro 18dp fill (< 1e12 wei, i.e. under $0.000001) is charged a full micro
    /// — rounding UP — so it can neither settle uncharged nor slip past a spent budget.
    function testFuzz_navRoundCap_subMicro18dp_roundsUp(uint256 k) public {
        // amountIn = 100k wei keeps tokens-out (k wei) exactly at NAV, so the band passes
        // and the cap is what decides. 100k < 1e12 ⇒ strictly sub-micro.
        k = bound(k, 1, 9_999_999_999); // floor((1e12 - 1) / 100)
        uint256 amountIn = 100 * k;

        _exec(swap18, _buyQuote(swap18, 1, amountIn, 0), amountIn);
        (, uint256 drawn) = swap18.navRoundNotionalDrawn(address(token));
        assertEq(drawn, 1, "a sub-micro fill charges one micro, never zero");

        // Exhaust the budget exactly, then the same sub-micro fill must be refused.
        vm.prank(admin);
        swap18.setMaxNavRoundNotionalFor(address(token), 1); // bumps the epoch
        (bool ok, bytes memory ret) = _try(swap18, _buyQuote(swap18, 2, amountIn, 0), amountIn);
        assertFalse(ok, "a spent budget must refuse sub-micro fills");
        assertEq(
            ret,
            abi.encodeWithSelector(GyldAtomicSwap.NavRoundNotionalExceeded.selector, address(token), 1, 0, 1),
            "requested reported as ceil(amount / 1e12)"
        );
    }
}
