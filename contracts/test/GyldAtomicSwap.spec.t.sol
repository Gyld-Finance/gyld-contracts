// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockUSDCPermit} from "./MockUSDCPermit.sol";
import {MockNavForwarder} from "./MockNavForwarder.sol";
import {MockReentrantToken, ISwapReentryTarget} from "./MockReentrantToken.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Spec-conformance suite for docs/atomic-swap-spec.md.
//
// Every test here pins a numbered invariant (I-n), a normative test vector, or a
// §10 finding remediation (F-n) from that document, and covers ONLY properties
// that GyldAtomicSwap.t.sol and GyldAtomicSwap.invariants.t.sol do not already
// assert. Neither of those files is modified by this suite. Each test names the
// invariant or finding it discharges.
//
// Deliberate non-goals (already covered elsewhere, do not duplicate):
//   I-2  replay             → [t] test_executeSwap_replayedQuoteId_reverts
//   I-10 never-mints        → [i] invariant_bond_totalSupply_never_changes
//   I-11 price fidelity     → [i] testFuzz_..._amountOut_matchesPriceRoundedDown
//   I-16 withdrawal target  → [t] test_withdraw_* family
//   I-18 pause asymmetry    → [t] test_pause_asymmetric_onlyAdminUnpauses
// ─────────────────────────────────────────────────────────────────────────────

contract GyldAtomicSwapSpecTest is Test {
    GyldAtomicSwap swap;
    GyldBondToken token;
    MockUSDCPermit usdc;
    MockNavForwarder navFeed;
    MockSanctionsList mockSanctions;

    address admin = address(0xA0);
    address pauser = address(0xA1);
    address treasurer = address(0xA2);
    address wallet = address(0xA3);
    address allowlistAdmin = address(0xA4);
    address outsider = address(0xFF);

    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK = 0xA11CE;
    address signer;
    address taker;

    int256 constant NAV = 100e8; // $100.00/token, 8dp
    uint16 constant MAX_BPS = 200; // ±2%
    uint32 constant MAX_NAV_AGE = 1 days;

    /// Distinguishable probe value for the ERC-7201 packing test. Must stay
    /// 0 < LAYOUT_NAV_AGE <= GyldAtomicSwap.MAX_NAV_AGE_CEILING (72 h = 259_200 s).
    uint32 constant LAYOUT_NAV_AGE = 0x0003F123; // 258_339 s ≈ 71.76 h

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // ── docs/atomic-swap-spec.md §5 normative constants ──────────────────────
    bytes32 constant SPEC_TYPEHASH = 0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b;
    bytes32 constant SPEC_STORAGE_LOCATION = 0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300;
    bytes32 constant SPEC_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // §5.6 / §5.7 vector fixtures.
    address constant V_TAKER = 0x1111111111111111111111111111111111111111;
    address constant V_USDC = 0x2222222222222222222222222222222222222222;
    address constant V_BOND = 0x3333333333333333333333333333333333333333;
    address constant V_VERIFYING = 0x4444444444444444444444444444444444444444;
    uint256 constant V_CHAINID = 11155111; // Sepolia

    bytes32 constant SPEC_DOMAIN_SEPARATOR = 0x304880d5d505807dde95e80b427a4bc881bd5fd4b959e6c9db7e64a78de9477c;
    bytes32 constant SPEC_V1_STRUCT_HASH = 0xd2e737d0941c835fc896c70c66fca52d93a48de326c54d02d3f88a290d14837b;
    bytes32 constant SPEC_V1_DIGEST = 0x852a19245c94dad26a71f09b771d40d99907121f525677d7358f41bf18254422;
    bytes32 constant SPEC_V2_STRUCT_HASH = 0xd80d5543af9c13a18803944f04f58bb289d9c69744fd314cf9ff7f05999abfd2;
    bytes32 constant SPEC_V2_DIGEST = 0x525dd14923d57b1c74b3f8cc8d13b26beaef3aa907e4c285eccc23c00f72e799;

    function setUp() public {
        vm.warp(1_750_000_000);
        signer = vm.addr(SIGNER_PK);
        taker = vm.addr(TAKER_PK);

        mockSanctions = new MockSanctionsList(address(this));
        usdc = new MockUSDCPermit();
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

        swap = _deploySwap(address(usdc));

        vm.prank(admin);
        swap.registerSeries(address(token), address(navFeed));

        // MINTER_ROLE on this test contract so inventory can be topped up mid-test.
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
        token.mint(address(swap), 1_000e18);
        token.mint(taker, 100e18);
        usdc.mint(taker, 1_000_000e6);
        usdc.mint(address(swap), 100_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Deploy + wire a fresh swap proxy over `cashToken`: series registered by the
    /// caller afterwards; withdrawalWallet set; `taker` allowlisted.
    function _deploySwap(address cashToken) internal returns (GyldAtomicSwap s) {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        s = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, signer, treasurer, cashToken, MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );
        // Cache role bytes before pranking — a getter call would consume the prank.
        bytes32 allowlistRole = s.ALLOWLIST_ADMIN_ROLE();
        vm.startPrank(admin);
        s.setWithdrawalWallet(wallet);
        s.grantRole(allowlistRole, allowlistAdmin);
        vm.stopPrank();
        vm.prank(allowlistAdmin);
        s.setAllowed(taker, true);
    }

    /// BUY at exactly NAV: 10 bond tokens per 1_000 USDC.
    function _buyQuote(uint256 quoteId, uint256 maxAmountIn)
        internal
        view
        returns (GyldAtomicSwap.SwapMessage memory)
    {
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: maxAmountIn,
            tokenOut: address(token),
            price: 1e28,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
    }

    /// REDEEM at exactly NAV: 1_000 USDC per 10 bond tokens.
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
            price: 100e6,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
    }

    function _sign(GyldAtomicSwap.SwapMessage memory m) internal view returns (bytes memory) {
        return _signFor(swap, m, SIGNER_PK);
    }

    function _signFor(GyldAtomicSwap s, GyldAtomicSwap.SwapMessage memory m, uint256 pk)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(pk, s.hashSwapMessage(m));
        return abi.encodePacked(r, sigS, v);
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    function _approveTaker() internal {
        vm.startPrank(taker);
        usdc.approve(address(swap), type(uint256).max);
        token.approve(address(swap), type(uint256).max);
        vm.stopPrank();
    }

    function _minDraw(uint256 maxAmountIn) internal view returns (uint256) {
        return (maxAmountIn * swap.MIN_DRAW_BPS()) / swap.BPS_DENOMINATOR();
    }

    /// The spec's §5.3 struct-hash formula, instantiated from the CONTRACT's typehash.
    function _specStructHash(
        uint256 quoteId,
        address taker_,
        address tokenIn,
        uint256 maxAmountIn,
        address tokenOut,
        uint256 price,
        uint64 expiry,
        uint64 epoch
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                swap.SWAP_MESSAGE_TYPEHASH(), quoteId, taker_, tokenIn, maxAmountIn, tokenOut, price, expiry, epoch
            )
        );
    }

    /// The spec's §5.1 domain separator formula.
    function _specDomainSeparator(uint256 chainId, address verifyingContract) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SPEC_DOMAIN_TYPEHASH,
                keccak256(bytes("GyldAtomicSwap")),
                keccak256(bytes("2")),
                chainId,
                verifyingContract
            )
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-1 — Inventory solvency
    // ═════════════════════════════════════════════════════════════════════════

    /// Positive direction (the existing suite only covers the reverting direction):
    /// for ANY legal draw the pushed-out amount is covered by pre-existing inventory,
    /// and the swap's balance decreases by exactly that amount.
    function testFuzz_executeSwap_neverPaysOutMoreThanInventory(uint256 requestedAmountIn) public {
        _approveTaker();
        uint256 maxAmountIn = 1_000e6;
        requestedAmountIn = bound(requestedAmountIn, _minDraw(maxAmountIn), maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1, maxAmountIn);
        uint256 expectedOut = (requestedAmountIn * m.price) / 1e18;
        uint256 inventoryBefore = token.balanceOf(address(swap));
        assertLe(expectedOut, inventoryBefore, "fixture must be solvent");

        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        assertEq(
            token.balanceOf(address(swap)),
            inventoryBefore - expectedOut,
            "swap paid out more (or less) than the derived amountOut"
        );
    }

    /// Any draw whose derived amountOut exceeds on-hand inventory MUST revert
    /// InsufficientInventory — the swap can never go short.
    function testFuzz_executeSwap_overInventoryDraw_alwaysReverts(uint256 requestedAmountIn) public {
        _approveTaker();
        // Leave exactly 5 bond tokens of inventory: a draw > 500 USDC needs > 5 tokens.
        vm.prank(treasurer);
        swap.withdraw(address(token), 1_000e18 - 5e18);
        assertEq(token.balanceOf(address(swap)), 5e18);

        uint256 maxAmountIn = 1_000e6;
        requestedAmountIn = bound(requestedAmountIn, 500e6 + 1, maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(2, maxAmountIn);
        uint256 expectedOut = (requestedAmountIn * m.price) / 1e18;
        bytes memory sig = _sign(m);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.InsufficientInventory.selector, address(token), expectedOut, 5e18)
        );
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-2a — Bitmap non-aliasing
    // ═════════════════════════════════════════════════════════════════════════

    /// The BitInvalidator indexes word `quoteId >> 8` bit `quoteId & 0xff`. Consuming
    /// an id MUST NOT mark its neighbours, and in particular MUST NOT alias across the
    /// 256-id word boundary (255 → word 0 bit 255, 256 → word 1 bit 0).
    function test_bitmap_wordBoundary_noAliasing() public {
        _approveTaker();
        uint256[3] memory ids = [uint256(255), uint256(256), uint256(257)];

        for (uint256 i = 0; i < ids.length; i++) {
            GyldAtomicSwap.SwapMessage memory m = _buyQuote(ids[i], 100e6);
            bytes memory sig = _sign(m);
            vm.prank(taker);
            swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
            assertTrue(swap.isQuoteUsed(ids[i]), "id not consumed");
        }

        // Neighbours on both sides of both word boundaries stay untouched.
        assertFalse(swap.isQuoteUsed(0), "id 0 aliased");
        assertFalse(swap.isQuoteUsed(1), "id 1 aliased");
        assertFalse(swap.isQuoteUsed(254), "id 254 aliased");
        assertFalse(swap.isQuoteUsed(258), "id 258 aliased");
        assertFalse(swap.isQuoteUsed(511), "id 511 aliased");
        assertFalse(swap.isQuoteUsed(512), "id 512 aliased");
        assertFalse(swap.isQuoteUsed(type(uint256).max), "max id aliased");
    }

    /// For any id other than the consumed one, isQuoteUsed MUST stay false.
    function testFuzz_isQuoteUsed_neverAliases(uint256 otherId) public {
        _approveTaker();
        uint256 consumed = 4_242;
        vm.assume(otherId != consumed);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(consumed, 100e6);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);

        assertTrue(swap.isQuoteUsed(consumed));
        assertFalse(swap.isQuoteUsed(otherId), "consuming one quoteId aliased another");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-3 — Draw range
    // ═════════════════════════════════════════════════════════════════════════

    /// The dust floor is INCLUSIVE: requestedAmountIn == minAllowed must succeed.
    /// (The existing suite only pins minAllowed - 1 reverting.)
    function test_executeSwap_exactlyMinDrawFloor_succeeds() public {
        _approveTaker();
        uint256 maxAmountIn = 1_000e6;
        uint256 floorDraw = _minDraw(maxAmountIn); // 10.000000 USDC
        assertEq(floorDraw, 10e6, "spec 5.6: minAllowed = maxAmountIn * 100 / 10_000");

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(3, maxAmountIn);
        bytes memory sig = _sign(m);

        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), floorDraw);

        assertTrue(swap.isQuoteUsed(3), "inclusive lower edge of the draw range must execute");
        assertEq(token.balanceOf(taker), 100e18 + 1e17, "floor draw must yield 0.1 bond token");
    }

    /// Any draw outside [minAllowed, maxAmountIn] MUST revert RequestedAmountOutOfRange.
    function testFuzz_executeSwap_outOfRangeDraw_alwaysReverts(uint256 requestedAmountIn) public {
        _approveTaker();
        uint256 maxAmountIn = 1_000e6;
        uint256 minAllowed = _minDraw(maxAmountIn);
        // Split the fuzz domain: below the floor, or above the cap.
        if (requestedAmountIn % 2 == 0) {
            requestedAmountIn = bound(requestedAmountIn, 0, minAllowed - 1);
        } else {
            requestedAmountIn = bound(requestedAmountIn, maxAmountIn + 1, type(uint128).max);
        }

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(4, maxAmountIn);
        bytes memory sig = _sign(m);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.RequestedAmountOutOfRange.selector, requestedAmountIn, minAllowed, maxAmountIn
            )
        );
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);
        assertFalse(swap.isQuoteUsed(4), "an out-of-range draw must not consume the quoteId");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-4 — quoteEpoch monotonicity
    // ═════════════════════════════════════════════════════════════════════════

    /// quoteEpoch is strictly monotonic and moves only by +1 per bump.
    function test_bumpQuoteEpoch_strictlyMonotonic() public {
        uint64 previous = swap.quoteEpoch();
        assertEq(previous, 0);
        for (uint64 i = 1; i <= 5; i++) {
            vm.prank(admin);
            swap.bumpQuoteEpoch();
            uint64 current = swap.quoteEpoch();
            assertEq(current, previous + 1, "bumpQuoteEpoch must increment by exactly 1");
            assertGt(current, previous, "quoteEpoch must be strictly increasing");
            previous = current;
        }
    }

    /// The epoch gate is equality, not a floor: a quote for a FUTURE epoch is rejected
    /// just as hard as a stale one. (The existing suite covers only the stale side.)
    function test_executeSwap_futureEpochQuote_reverts() public {
        _approveTaker();
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(5, 1_000e6);
        m.epoch = 7; // current epoch is 0
        bytes memory sig = _sign(m);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteEpochStale.selector, uint64(7), uint64(0)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-5 — Epoch bump does not free quoteIds
    // ═════════════════════════════════════════════════════════════════════════

    /// bumpQuoteEpoch writes only quoteEpoch; usedQuoteWords is NOT epoch-scoped, so a
    /// consumed id stays consumed across every future epoch. Pins finding F-3: the
    /// quote service MUST never reuse a quoteId, even after a mass invalidation.
    function test_consumedQuoteId_survivesEpochBump() public {
        _approveTaker();
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(6, 1_000e6);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(6));

        vm.prank(admin);
        swap.bumpQuoteEpoch();
        assertTrue(swap.isQuoteUsed(6), "epoch bump must not clear the usage bitmap");

        // A freshly signed quote reusing the id at the NEW epoch passes the epoch gate
        // (step 7) and then dies on the bitmap (step 9).
        GyldAtomicSwap.SwapMessage memory reused = _buyQuote(6, 1_000e6);
        reused.epoch = 1;
        bytes memory reusedSig = _sign(reused);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteAlreadyUsed.selector, uint256(6)));
        swap.executeSwap(reused, reusedSig, _noPermit(), reused.maxAmountIn);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-9 — Atomic consumption
    // ═════════════════════════════════════════════════════════════════════════

    /// _consumeQuote is an ordinary state write inside the transaction, so a swap that
    /// reverts LATER (here: at the inventory check, two steps downstream) must leave the
    /// quoteId unconsumed and re-executable once the blocking condition clears.
    function test_failedSwap_doesNotConsumeQuoteId() public {
        _approveTaker();
        // Drain all bond inventory so the outgoing leg cannot be covered.
        vm.prank(treasurer);
        swap.withdraw(address(token), 1_000e18);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(7, 1_000e6);
        bytes memory sig = _sign(m);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.InsufficientInventory.selector, address(token), uint256(10e18), uint256(0)
            )
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);

        assertFalse(swap.isQuoteUsed(7), "a reverted swap must not burn the quoteId");

        // Restock, then the very same quote + signature executes.
        token.mint(address(swap), 1_000e18);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(7), "quote must remain executable after an earlier revert");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-10 — Conservation on the REDEEM leg (BUY leg already covered)
    // ═════════════════════════════════════════════════════════════════════════

    function testFuzz_executeSwap_redeem_conservesBothPools(uint256 requestedAmountIn) public {
        _approveTaker();
        uint256 maxAmountIn = 10e18;
        requestedAmountIn = bound(requestedAmountIn, _minDraw(maxAmountIn), maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(8, maxAmountIn);
        uint256 expectedOut = (requestedAmountIn * m.price) / 1e18;

        uint256 swapTokenBefore = token.balanceOf(address(swap));
        uint256 swapUsdcBefore = usdc.balanceOf(address(swap));
        uint256 takerTokenBefore = token.balanceOf(taker);
        uint256 takerUsdcBefore = usdc.balanceOf(taker);
        uint256 usdcSupplyBefore = usdc.totalSupply();

        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        // Bond moves taker → swap by exactly requestedAmountIn.
        assertEq(token.balanceOf(address(swap)) - swapTokenBefore, requestedAmountIn, "swap bond credit mismatch");
        assertEq(takerTokenBefore - token.balanceOf(taker), requestedAmountIn, "taker bond debit mismatch");
        // USDC moves swap → taker by exactly the derived amountOut.
        assertEq(swapUsdcBefore - usdc.balanceOf(address(swap)), expectedOut, "swap USDC debit mismatch");
        assertEq(usdc.balanceOf(taker) - takerUsdcBefore, expectedOut, "taker USDC credit mismatch");
        // No cash created or destroyed.
        assertEq(usdc.totalSupply(), usdcSupplyBefore, "REDEEM must never change USDC totalSupply");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-12 — Signature authority: revocation takes effect immediately
    // ═════════════════════════════════════════════════════════════════════════

    /// hasRole is evaluated at EXECUTION time, not signing time: revoking
    /// QUOTE_SIGNER_ROLE invalidates every in-flight quote from that key.
    function test_executeSwap_revokedSigner_reverts() public {
        _approveTaker();
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(9, 1_000e6);
        bytes memory sig = _sign(m); // signed while the key is authorised

        bytes32 signerRole = swap.QUOTE_SIGNER_ROLE();
        vm.prank(admin);
        swap.revokeRole(signerRole, signer);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteSigner.selector, signer));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-13 — Cross-chain / cross-proxy replay resistance
    // ═════════════════════════════════════════════════════════════════════════

    /// The same SwapMessage bytes hash differently on a different chainId, so a signature
    /// cannot be replayed across chains even at an identical proxy address.
    function test_hashSwapMessage_bindsChainId() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(10, 1_000e6);
        bytes32 here = swap.hashSwapMessage(m);

        vm.chainId(block.chainid + 1);
        bytes32 there = swap.hashSwapMessage(m);

        assertTrue(here != there, "digest must bind chainId (cross-chain replay)");
        assertEq(there, _hand(m, block.chainid, address(swap)), "digest must follow the spec 5.1 domain formula");
    }

    /// Two proxies over the same implementation produce different digests for identical
    /// message bytes — verifyingContract is the proxy, not the implementation.
    function test_hashSwapMessage_bindsVerifyingContract() public {
        GyldAtomicSwap other = _deploySwap(address(usdc));
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(11, 1_000e6);

        assertTrue(
            swap.hashSwapMessage(m) != other.hashSwapMessage(m),
            "digest must bind verifyingContract (cross-deployment replay)"
        );
        assertEq(other.hashSwapMessage(m), _hand(m, block.chainid, address(other)));
    }

    function _hand(GyldAtomicSwap.SwapMessage memory m, uint256 chainId, address verifying)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash =
            _specStructHash(m.quoteId, m.taker, m.tokenIn, m.maxAmountIn, m.tokenOut, m.price, m.expiry, m.epoch);
        return keccak256(abi.encodePacked("\x19\x01", _specDomainSeparator(chainId, verifying), structHash));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // §5.6 / §5.7 — Normative test vectors
    // ═════════════════════════════════════════════════════════════════════════

    /// Vector 1 (BUY) and vector 2 (REDEEM): the struct hashes published in
    /// docs/atomic-swap-spec.md must be exactly reproducible from the CONTRACT's own
    /// SWAP_MESSAGE_TYPEHASH. Struct hashes are chain- and address-independent, so a
    /// third-party signer can check these directly.
    function test_specVectors_structHashes_matchPublishedLiterals() public view {
        assertEq(swap.SWAP_MESSAGE_TYPEHASH(), SPEC_TYPEHASH, "spec 5.2 typehash drifted");

        assertEq(
            _specStructHash(1, V_TAKER, V_USDC, 1_000_000_000, V_BOND, 1e28, 1_750_000_900, 0),
            SPEC_V1_STRUCT_HASH,
            "spec 5.6 vector 1 structHash drifted"
        );
        assertEq(
            _specStructHash(257, V_TAKER, V_BOND, 10e18, V_USDC, 100e6, 1_750_000_900, 3),
            SPEC_V2_STRUCT_HASH,
            "spec 5.7 vector 2 structHash drifted"
        );
    }

    /// The published digests must follow from the published struct hashes under the
    /// spec's domain (chainId 11155111, verifyingContract 0x4444…4444).
    function test_specVectors_digests_matchPublishedLiterals() public view {
        bytes32 ds = _specDomainSeparator(V_CHAINID, V_VERIFYING);
        assertEq(ds, SPEC_DOMAIN_SEPARATOR, "spec 5.6 domainSeparator drifted");

        assertEq(
            keccak256(abi.encodePacked("\x19\x01", ds, SPEC_V1_STRUCT_HASH)),
            SPEC_V1_DIGEST,
            "spec 5.6 vector 1 digest drifted"
        );
        assertEq(
            keccak256(abi.encodePacked("\x19\x01", ds, SPEC_V2_STRUCT_HASH)),
            SPEC_V2_DIGEST,
            "spec 5.7 vector 2 digest drifted"
        );
    }

    /// Ties the two tests above to the live contract: hashSwapMessage must equal the
    /// spec formula (§5.1 domain + §5.3 struct hash) for BOTH vectors' field shapes,
    /// instantiated with this deployment's chainId and proxy address.
    function test_hashSwapMessage_matchesSpecFormula_forBothVectorShapes() public view {
        GyldAtomicSwap.SwapMessage memory v1 = GyldAtomicSwap.SwapMessage({
            quoteId: 1,
            taker: V_TAKER,
            tokenIn: V_USDC,
            maxAmountIn: 1_000_000_000,
            tokenOut: V_BOND,
            price: 1e28,
            expiry: 1_750_000_900,
            epoch: 0
        });
        GyldAtomicSwap.SwapMessage memory v2 = GyldAtomicSwap.SwapMessage({
            quoteId: 257,
            taker: V_TAKER,
            tokenIn: V_BOND,
            maxAmountIn: 10e18,
            tokenOut: V_USDC,
            price: 100e6,
            expiry: 1_750_000_900,
            epoch: 3
        });

        assertEq(swap.hashSwapMessage(v1), _hand(v1, block.chainid, address(swap)), "vector 1 shape");
        assertEq(swap.hashSwapMessage(v2), _hand(v2, block.chainid, address(swap)), "vector 2 shape");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-14 — Exactly one bond leg
    // ═════════════════════════════════════════════════════════════════════════

    /// tokenIn == tokenOut can never classify as a swap: both `buy` and `redeem` are
    /// false, so `buy == redeem` and NotOneBondLeg fires. This is what makes the
    /// post-pull-in inventory measurement sound (spec §4.2).
    function test_executeSwap_sameTokenBothLegs_reverts() public {
        _approveTaker();
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(12, 1_000e6);
        m.tokenOut = address(usdc); // USDC → USDC
        bytes memory sig = _sign(m);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotOneBondLeg.selector, address(usdc), address(usdc)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);

        // Bond → bond is equally rejected.
        GyldAtomicSwap.SwapMessage memory m2 = _redeemQuote(13, 10e18);
        m2.tokenOut = address(token);
        bytes memory sig2 = _sign(m2);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotOneBondLeg.selector, address(token), address(token)));
        swap.executeSwap(m2, sig2, _noPermit(), m2.maxAmountIn);
    }

    /// Two registered series against each other (neither leg is USDC) is rejected — no
    /// bond-for-bond swap can bypass the NAV band or the single-bond-leg screening
    /// assumption the compliance design relies on.
    function test_executeSwap_neitherLegUsdc_reverts() public {
        _approveTaker();
        // A second registered series (18-decimal mock, never armed — a plain ERC-20
        // here; registerSeries now probes decimals() == 18 on-chain, F-1).
        MockReentrantToken seriesB = new MockReentrantToken();
        vm.prank(admin);
        swap.registerSeries(address(seriesB), address(navFeed));
        assertTrue(swap.registeredSeries(address(seriesB)));

        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(14, 10e18);
        m.tokenOut = address(seriesB); // bond → bond, both registered
        bytes memory sig = _sign(m);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.NotOneBondLeg.selector, address(token), address(seriesB))
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-15 — NAV fail-closed
    // ═════════════════════════════════════════════════════════════════════════

    /// A strictly negative NAV is a hard feed fault. (The existing suite pins nav == 0.)
    function test_executeSwap_negativeNav_reverts() public {
        _approveTaker();
        navFeed.setAnswer(-1);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(15, 1_000e6);
        bytes memory sig = _sign(m);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNav.selector, address(token), int256(-1)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// The staleness bound is INCLUSIVE: updatedAt == block.timestamp - maxNavAgeSecs
    /// still executes; one second older reverts. (Existing suite pins only the revert.)
    function test_executeSwap_navExactlyAtMaxAge_succeeds() public {
        _approveTaker();
        uint256 edge = block.timestamp - uint256(MAX_NAV_AGE);
        navFeed.setUpdatedAt(edge);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(16, 1_000e6);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(16), "NAV exactly at maxNavAgeSecs must be accepted");

        navFeed.setUpdatedAt(edge - 1);
        GyldAtomicSwap.SwapMessage memory m2 = _buyQuote(17, 1_000e6);
        bytes memory sig2 = _sign(m2);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.StaleNav.selector, address(token), edge - 1));
        swap.executeSwap(m2, sig2, _noPermit(), m2.maxAmountIn);
    }

    /// F-6 extends I-15: a future-dated updatedAt would satisfy
    /// `block.timestamp > updatedAt + maxNavAgeSecs` forever, so the guard rejects it
    /// explicitly. updatedAt == block.timestamp remains the inclusive fresh edge (the
    /// mock's default, exercised by every happy-path test).
    function test_executeSwap_futureDatedNav_reverts() public {
        _approveTaker();
        uint256 future = block.timestamp + 100;
        navFeed.setUpdatedAt(future);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(23, 1_000e6);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.StaleNav.selector, address(token), future));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertFalse(swap.isQuoteUsed(23), "a future-dated NAV must not let the quote execute");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-15 (GYL-1135) — the staleness guard is structurally bounded
    // ═════════════════════════════════════════════════════════════════════════
    //
    // Context. KaleidoscopeNAVFeed deliberately does NOT revert on a stale answer
    // (Chainlink read semantics — see KaleidoscopeNAVFeed.t.sol
    // test_noStalenessRevertPathExists). That makes this contract's StaleNav check the
    // ONLY thing preventing a swap from being priced against a NAV nobody has
    // refreshed. Before GYL-1135, setMaxNavAgeSecs validated non-zero only, and uint32
    // reaches ~136 years — so a single DEFAULT_ADMIN_ROLE transaction could raise the
    // bound past any real elapsed time and turn the guard into a no-op while every
    // getter still reported it as "set". MAX_NAV_AGE_CEILING closes that.

    /// No admin call, for any input above the ceiling, can widen the staleness bound.
    function testFuzz_setMaxNavAgeSecs_revertsAboveCeiling(uint32 newSecs) public {
        uint32 ceiling = swap.MAX_NAV_AGE_CEILING();
        newSecs = uint32(bound(uint256(newSecs), uint256(ceiling) + 1, type(uint32).max));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNavAge.selector, newSecs));
        swap.setMaxNavAgeSecs(newSecs);

        assertEq(swap.maxNavAgeSecs(), MAX_NAV_AGE, "a rejected setter must leave the bound untouched");
    }

    /// The ceiling itself is accepted — the bound is inclusive, so a deliberate
    /// 3-day-holiday tolerance remains configurable.
    function test_setMaxNavAgeSecs_ceilingExactlyIsAccepted() public {
        uint32 ceiling = swap.MAX_NAV_AGE_CEILING();
        assertEq(ceiling, 72 hours, "ceiling must match Euler's structural upper bound");

        vm.prank(admin);
        swap.setMaxNavAgeSecs(ceiling);
        assertEq(swap.maxNavAgeSecs(), ceiling);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNavAge.selector, ceiling + 1));
        swap.setMaxNavAgeSecs(ceiling + 1);
    }

    /// The same bound applies at construction — otherwise a fresh deployment could be
    /// born with the guard already disabled and never trip the setter check.
    function test_initialize_revertsAboveCeiling() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        uint32 ceiling = impl.MAX_NAV_AGE_CEILING();
        uint32 tooLarge = ceiling + 1;

        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNavAge.selector, tooLarge));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(usdc), MAX_BPS, tooLarge)
            )
        );

        // uint32 max — the "just make it never expire" value — is rejected too.
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNavAge.selector, type(uint32).max));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize,
                (admin, pauser, signer, treasurer, address(usdc), MAX_BPS, type(uint32).max)
            )
        );

        // Zero is still rejected (pre-existing rule), and the ceiling still deploys.
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNavAge.selector, uint32(0)));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(usdc), MAX_BPS, uint32(0))
            )
        );

        GyldAtomicSwap ok = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, signer, treasurer, address(usdc), MAX_BPS, ceiling)
                    )
                )
            )
        );
        assertEq(ok.maxNavAgeSecs(), ceiling);
    }

    /// REGRESSION TEST FOR THE INCIDENT CLASS (GYL-1135).
    ///
    /// On Base mainnet the NAV feed stopped being pushed on 2026-05-19. Euler froze on
    /// its own staleness check; Morpho, which has none, kept quoting the last pushed
    /// $100.00 answer indefinitely. This contract is on the Euler side of that line
    /// only because maxNavAgeSecs is small — and that was, until now, one admin
    /// transaction away from being untrue. This test asserts the guard survives a
    /// full-authority attempt to remove it: hold DEFAULT_ADMIN_ROLE, push the bound to
    /// uint32 max, and confirm an ancient NAV still fails closed afterwards.
    function test_staleNavGuardCannotBeDisabledByAdmin() public {
        _approveTaker();

        // Full authority: a fresh admin account holding DEFAULT_ADMIN_ROLE, i.e. the
        // strongest caller that exists on this contract.
        address rogueAdmin = address(0xBADADD);
        bytes32 adminRole = swap.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        swap.grantRole(adminRole, rogueAdmin);
        assertTrue(swap.hasRole(adminRole, rogueAdmin));

        // Attempt 1: the direct "never expire" value.
        vm.prank(rogueAdmin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNavAge.selector, type(uint32).max));
        swap.setMaxNavAgeSecs(type(uint32).max);

        // Attempt 2: a plausible-looking but still guard-defeating 10 years.
        uint32 tenYears = 3650 days;
        vm.prank(rogueAdmin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNavAge.selector, tenYears));
        swap.setMaxNavAgeSecs(tenYears);

        // The bound is unchanged, and is still meaningfully small.
        // Cache the ceiling before pranking — a getter call would consume the prank.
        uint32 ceiling = swap.MAX_NAV_AGE_CEILING();
        assertEq(swap.maxNavAgeSecs(), MAX_NAV_AGE);
        assertLe(swap.maxNavAgeSecs(), ceiling);

        // The widest the admin CAN go is 72 h — apply it, to prove the guard still
        // bites even at maximum permitted laxity.
        vm.prank(rogueAdmin);
        swap.setMaxNavAgeSecs(ceiling);

        // Now replay the mainnet scenario: a feed that stopped 72 days ago. The feed
        // itself happily returns the pinned answer (it never reverts) — this contract
        // must refuse to trade on it.
        uint256 abandonedAt = block.timestamp - 72 days;
        navFeed.setUpdatedAt(abandonedAt);
        (, int256 nav,, uint256 updatedAt,) = navFeed.latestRoundData();
        assertEq(nav, NAV, "the feed still serves a price - that is the whole problem");
        assertEq(updatedAt, abandonedAt);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(91, 1_000e6);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.StaleNav.selector, address(token), abandonedAt));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertFalse(swap.isQuoteUsed(91), "no swap may settle against an abandoned NAV");

        // And once the keeper resumes, trading resumes — the guard is a pause, not a brick.
        navFeed.setUpdatedAt(block.timestamp);
        GyldAtomicSwap.SwapMessage memory m2 = _buyQuote(92, 1_000e6);
        bytes memory sig2 = _sign(m2);
        vm.prank(taker);
        swap.executeSwap(m2, sig2, _noPermit(), m2.maxAmountIn);
        assertTrue(swap.isQuoteUsed(92), "a refreshed NAV must restore tradability");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-17 — Reentrancy exclusion covers withdraw too
    // ═════════════════════════════════════════════════════════════════════════

    /// withdraw shares the nonReentrant guard with executeSwap: a malicious inventory
    /// token cannot use the withdrawal transfer hook to enter executeSwap.
    function test_withdraw_cannotReenterExecuteSwap() public {
        MockReentrantToken evil = new MockReentrantToken();
        evil.mint(address(swap), 100e18); // mint BEFORE arming (the hook fires on mint too)

        ISwapReentryTarget.SwapMessage memory rm = ISwapReentryTarget.SwapMessage({
            quoteId: 999,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: 1_000e6,
            tokenOut: address(evil),
            price: 1e28,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
        // The re-entrant call dies on the guard (the FIRST modifier), so the message and
        // signature never get validated — an empty signature is sufficient.
        evil.armExecuteSwap(address(swap), rm, "", 1_000e6);

        vm.prank(treasurer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        swap.withdraw(address(evil), 10e18);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-8 — Admin-role non-renounceability holds for every holder
    // ═════════════════════════════════════════════════════════════════════════

    function test_renounceRole_defaultAdmin_revertsForEveryHolder() public {
        bytes32 adminRole = swap.DEFAULT_ADMIN_ROLE();
        address secondAdmin = address(0xADAD);
        vm.prank(admin);
        swap.grantRole(adminRole, secondAdmin);
        assertTrue(swap.hasRole(adminRole, secondAdmin));

        vm.prank(secondAdmin);
        vm.expectRevert(GyldAtomicSwap.CannotRenounceAdminRole.selector);
        swap.renounceRole(adminRole, secondAdmin);

        vm.prank(admin);
        vm.expectRevert(GyldAtomicSwap.CannotRenounceAdminRole.selector);
        swap.renounceRole(adminRole, admin);

        // revokeRole remains the explicit, two-party removal path.
        vm.prank(admin);
        swap.revokeRole(adminRole, secondAdmin);
        assertFalse(swap.hasRole(adminRole, secondAdmin));
    }

    /// F-7 extends I-8 to the incident-response pair: PAUSER and TREASURER renounce
    /// MUST revert (a sole holder self-renouncing would remove pause() and
    /// withdraw()-while-paused until the timelock re-grants). QUOTE_SIGNER and
    /// ALLOWLIST_ADMIN stay renounceable — signer rotation and ops-key retirement.
    function test_renounceRole_incidentResponseRoles_revert() public {
        bytes32 pauserRole = swap.PAUSER_ROLE();
        vm.prank(pauser);
        vm.expectRevert(GyldAtomicSwap.CannotRenouncePauserRole.selector);
        swap.renounceRole(pauserRole, pauser);

        bytes32 treasurerRole = swap.TREASURER_ROLE();
        vm.prank(treasurer);
        vm.expectRevert(GyldAtomicSwap.CannotRenounceTreasurerRole.selector);
        swap.renounceRole(treasurerRole, treasurer);

        // The other two roles remain renounceable.
        bytes32 signerRole = swap.QUOTE_SIGNER_ROLE();
        vm.prank(signer);
        swap.renounceRole(signerRole, signer);
        assertFalse(swap.hasRole(signerRole, signer));

        bytes32 allowlistRole = swap.ALLOWLIST_ADMIN_ROLE();
        vm.prank(allowlistAdmin);
        swap.renounceRole(allowlistRole, allowlistAdmin);
        assertFalse(swap.hasRole(allowlistRole, allowlistAdmin));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-19 — ERC-7201 storage location and packing
    // ═════════════════════════════════════════════════════════════════════════

    /// Pins spec §3.1: the base slot equals the ERC-7201 derivation, quoteEpoch /
    /// maxQuoteDeviationBps / maxNavAgeSecs pack into B+0 at offsets 0 / 8 / 10,
    /// withdrawalWallet and usdc occupy B+1 and B+2, and the F-4 addition maxQuoteTtl
    /// sits at the append-only tail (B+8). An upgrade that reorders or resizes any of
    /// these silently corrupts live state.
    function test_storageLayout_erc7201SlotAndPacking() public {
        bytes32 derived =
            keccak256(abi.encode(uint256(keccak256("gyld.GyldAtomicSwap")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(derived, SPEC_STORAGE_LOCATION, "ERC-7201 derivation drifted from the spec literal");

        // Move all three packed fields off their defaults with distinguishable values.
        vm.startPrank(admin);
        swap.bumpQuoteEpoch();
        swap.bumpQuoteEpoch();
        swap.bumpQuoteEpoch(); // quoteEpoch = 3
        swap.setMaxQuoteDeviationBps(0x0123); // 291 bps
        // GYL-1135: maxNavAgeSecs is now bounded by MAX_NAV_AGE_CEILING (72 h), so this
        // probe value can no longer be an arbitrary uint32. 0x0003F123 (258_339 s ≈
        // 71.76 h) is the widest distinguishable value that still passes the setter.
        // Consequence for this test: byte 13 of the field is necessarily 0x00, so the
        // assertion below no longer distinguishes uint32 from uint24 by content alone —
        // the `slot0 >> 112 == 0` assertion plus the ceiling itself carry that instead.
        swap.setMaxNavAgeSecs(LAYOUT_NAV_AGE);
        vm.stopPrank();

        uint256 slot0 = uint256(vm.load(address(swap), derived));
        assertEq(uint64(slot0), uint64(3), "quoteEpoch must occupy B+0 offset 0 (8 bytes)");
        assertEq(uint16(slot0 >> 64), uint16(0x0123), "maxQuoteDeviationBps must occupy B+0 offset 8 (2 bytes)");
        assertEq(uint32(slot0 >> 80), LAYOUT_NAV_AGE, "maxNavAgeSecs must occupy B+0 offset 10 (4 bytes)");
        assertEq(slot0 >> 112, 0, "bytes 14..31 of B+0 must remain free");

        // withdrawalWallet does NOT pack into B+0 (14 bytes used + 20 needed > 32).
        assertEq(
            address(uint160(uint256(vm.load(address(swap), bytes32(uint256(derived) + 1))))),
            wallet,
            "withdrawalWallet must occupy B+1"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(swap), bytes32(uint256(derived) + 2))))),
            address(usdc),
            "usdc must occupy B+2"
        );

        // maxQuoteTtl (F-4) is appended AFTER the existing fields at B+8 — ERC-7201
        // append-only: nothing above moved.
        assertEq(
            uint64(uint256(vm.load(address(swap), bytes32(uint256(derived) + 8)))),
            swap.DEFAULT_MAX_QUOTE_TTL(),
            "maxQuoteTtl must occupy B+8 offset 0 (8 bytes), seeded by initialize"
        );

        // Getters agree with the raw slots.
        assertEq(swap.quoteEpoch(), 3);
        assertEq(swap.maxQuoteDeviationBps(), 0x0123);
        assertEq(swap.maxNavAgeSecs(), LAYOUT_NAV_AGE);
        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL());
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-20 — Upgrade authority
    // ═════════════════════════════════════════════════════════════════════════

    function test_upgradeToAndCall_onlyAdmin() public {
        address newImpl = address(new GyldAtomicSwap());

        vm.prank(outsider);
        vm.expectRevert();
        swap.upgradeToAndCall(newImpl, "");

        vm.prank(treasurer);
        vm.expectRevert();
        swap.upgradeToAndCall(newImpl, "");

        // The admin can upgrade, and namespaced state survives.
        vm.prank(admin);
        swap.upgradeToAndCall(newImpl, "");
        assertEq(swap.usdc(), address(usdc), "ERC-7201 state must survive the upgrade");
        assertEq(swap.withdrawalWallet(), wallet);
        assertTrue(swap.isAllowed(taker));
    }

    /// The implementation behind the proxy must not be initializable directly.
    function test_implementation_initializersDisabled() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        impl.initialize(admin, pauser, signer, treasurer, address(usdc), MAX_BPS, MAX_NAV_AGE);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-21 — Series deregistration / re-registration
    // ═════════════════════════════════════════════════════════════════════════

    function test_deregisterSeries_thenReregister_restoresTradability() public {
        _approveTaker();

        vm.prank(treasurer);
        swap.withdraw(address(token), 1_000e18);
        vm.prank(admin);
        swap.deregisterSeries(address(token));

        assertFalse(swap.registeredSeries(address(token)), "registeredSeries must be cleared");
        assertEq(swap.navForwarderOf(address(token)), address(0), "navForwarderOf must be cleared");

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(18, 1_000e6);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotOneBondLeg.selector, address(usdc), address(token)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);

        // Re-register + restock: tradability returns, and the quoteId was never burned.
        vm.prank(admin);
        swap.registerSeries(address(token), address(navFeed));
        token.mint(address(swap), 1_000e18);

        assertFalse(swap.isQuoteUsed(18), "the failed pre-registration attempt must not burn the id");
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(18));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-22 — Permit is never load-bearing for authorization
    // ═════════════════════════════════════════════════════════════════════════

    /// tokenIn with NO permit() at all (plain MockUSDC — real USDC uses a non-standard
    /// version "2"): the try/catch swallows the failure and a plain approval carries the
    /// swap. Complements the existing front-run test, which uses a permit-capable token.
    function test_executeSwap_permitOnTokenWithoutPermit_doesNotBrick() public {
        MockUSDC plainUsdc = new MockUSDC();
        GyldAtomicSwap s = _deploySwap(address(plainUsdc));
        vm.prank(admin);
        s.registerSeries(address(token), address(navFeed));
        token.mint(address(s), 1_000e18);
        plainUsdc.mint(taker, 10_000e6);

        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: 19,
            taker: taker,
            tokenIn: address(plainUsdc),
            maxAmountIn: 1_000e6,
            tokenOut: address(token),
            price: 1e28,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
        bytes memory sig = _signFor(s, m, SIGNER_PK);

        // Garbage permit data with a non-zero value: the permit call MUST be attempted
        // (there is no permit() on this token) and MUST NOT abort the swap.
        GyldAtomicSwap.PermitData memory p =
            GyldAtomicSwap.PermitData(1_000e6, block.timestamp + 1 hours, 27, bytes32(uint256(1)), bytes32(uint256(2)));

        vm.prank(taker);
        plainUsdc.approve(address(s), 1_000e6);
        vm.prank(taker);
        s.executeSwap(m, sig, p, m.maxAmountIn);

        assertTrue(s.isQuoteUsed(19), "a token without permit() must not brick the swap");
        assertEq(token.balanceOf(taker), 100e18 + 10e18, "bond leg not delivered");
    }

    /// A permit that succeeds for LESS than the draw does not authorise the draw — the
    /// safeTransferFrom allowance check is the sole authority.
    function test_executeSwap_permitBelowDraw_stillEnforcesAllowance() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(20, 1_000e6);
        bytes memory sig = _sign(m);

        uint256 deadline = block.timestamp + 15 minutes;
        uint256 shortValue = 400e6; // permit covers only 40% of the draw
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, taker, address(swap), shortValue, usdc.nonces(taker), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TAKER_PK, digest);
        GyldAtomicSwap.PermitData memory p = GyldAtomicSwap.PermitData(shortValue, deadline, v, r, s);

        // No prior approval — the permit is the only allowance, and it is short.
        assertEq(usdc.allowance(taker, address(swap)), 0);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSignature(
                "ERC20InsufficientAllowance(address,uint256,uint256)", address(swap), shortValue, 1_000e6
            )
        );
        swap.executeSwap(m, sig, p, m.maxAmountIn);

        assertFalse(swap.isQuoteUsed(20), "a short-allowance swap must not burn the quoteId");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F-1 (O-4) — Decimal ladder enforced on-chain
    // ═════════════════════════════════════════════════════════════════════════

    /// O-4 is now enforced on-chain, not just operationally: registerSeries probes the
    /// bond token for 18 decimals (the /1e20 ladder assumes 18dp bond / 8dp NAV / 6dp
    /// USDC and mis-scales silently for anything else). MockUSDC (6dp) stands in for a
    /// wrong-decimals series.
    function test_registerSeries_non18dpToken_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidTokenDecimals.selector, address(usdc), uint8(6)));
        swap.registerSeries(address(usdc), address(navFeed));
    }

    /// The same probe guards the cash token at initialize: a non-6dp cash token would
    /// silently vacuum the NAV band. The 18dp bond token stands in as the bad cash leg.
    function test_initialize_non6dpCashToken_reverts() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidTokenDecimals.selector, address(token), uint8(18)));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(token), MAX_BPS, MAX_NAV_AGE)
            )
        );
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F-4 (S-4, I-23) — Quote expiry is TTL-bounded
    // ═════════════════════════════════════════════════════════════════════════

    /// S-4 is now enforced on-chain: a quote must satisfy
    /// block.timestamp <= expiry <= block.timestamp + maxQuoteTtl. The upper edge is
    /// INCLUSIVE — exactly at the TTL executes; one second beyond reverts.
    function test_executeSwap_quoteExpiryTtlBound_inclusiveEdge() public {
        _approveTaker();
        uint64 ttl = swap.maxQuoteTtl();
        assertEq(ttl, 1 hours, "spec: initialize seeds DEFAULT_MAX_QUOTE_TTL = 1 hour");

        GyldAtomicSwap.SwapMessage memory atEdge = _buyQuote(24, 1_000e6);
        atEdge.expiry = uint64(block.timestamp + ttl);
        bytes memory edgeSig = _sign(atEdge);
        vm.prank(taker);
        swap.executeSwap(atEdge, edgeSig, _noPermit(), atEdge.maxAmountIn);
        assertTrue(swap.isQuoteUsed(24), "expiry exactly at block.timestamp + maxQuoteTtl must execute");

        GyldAtomicSwap.SwapMessage memory beyond = _buyQuote(25, 1_000e6);
        beyond.expiry = uint64(block.timestamp + uint256(ttl) + 1);
        bytes memory beyondSig = _sign(beyond);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.QuoteExpiryTooFar.selector, beyond.expiry, uint64(block.timestamp + ttl)
            )
        );
        swap.executeSwap(beyond, beyondSig, _noPermit(), beyond.maxAmountIn);
        assertFalse(swap.isQuoteUsed(25), "a too-far-out quote must not burn the quoteId");
    }

    /// The TTL is admin-adjustable and the setter is DEFAULT_ADMIN-gated (spec §7) —
    /// narrowing it immediately invalidates longer-dated outstanding quotes.
    function test_setMaxQuoteTtl_adminOnly_takesEffectImmediately() public {
        _approveTaker();
        vm.prank(outsider);
        vm.expectRevert();
        swap.setMaxQuoteTtl(5 minutes);

        vm.prank(admin);
        swap.setMaxQuoteTtl(5 minutes);
        assertEq(swap.maxQuoteTtl(), 5 minutes);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(26, 1_000e6); // expiry = +15 min
        bytes memory sig = _sign(m);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.QuoteExpiryTooFar.selector, m.expiry, uint64(block.timestamp + 5 minutes)
            )
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F-5 (I-24) — seriesList is observable; swap-and-pop pinned
    // ═════════════════════════════════════════════════════════════════════════

    /// seriesList MUST stay a duplicate-free mirror of registeredSeries, and the
    /// deregister swap-and-pop MUST move the last element into the removed slot. Pins
    /// the two previously untestable cases from F-5: mid-array target and last-element.
    function test_seriesList_swapAndPop_midArrayAndLastElement() public {
        MockReentrantToken seriesB = new MockReentrantToken();
        MockReentrantToken seriesC = new MockReentrantToken();
        vm.startPrank(admin);
        swap.registerSeries(address(seriesB), address(navFeed));
        swap.registerSeries(address(seriesC), address(navFeed));
        vm.stopPrank();
        assertEq(swap.seriesCount(), 3);

        // Mid-array target: [token, B, C] → deregister B → C fills slot 1.
        vm.prank(admin);
        swap.deregisterSeries(address(seriesB));
        assertEq(swap.seriesCount(), 2);
        assertEq(swap.seriesAt(0), address(token));
        assertEq(swap.seriesAt(1), address(seriesC), "swap-and-pop must move the tail into the gap");

        // Last-element target: [token, C] → deregister C → tail popped, order kept.
        vm.prank(admin);
        swap.deregisterSeries(address(seriesC));
        assertEq(swap.seriesCount(), 1);
        assertEq(swap.seriesAt(0), address(token));

        // The mirror stays exact: deregistered entries are gone from both views.
        assertFalse(swap.registeredSeries(address(seriesB)));
        assertFalse(swap.registeredSeries(address(seriesC)));
    }
}
