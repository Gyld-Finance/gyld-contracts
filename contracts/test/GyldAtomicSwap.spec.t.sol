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
// Spec-conformance suite for docs/ARCHITECTURE.md.
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

    // ── docs/ARCHITECTURE.md §5 normative constants ──────────────────────
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
            expiry: uint64(block.timestamp + 60 seconds),
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
            expiry: uint64(block.timestamp + 60 seconds),
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

    /// The navValue _checkQuoteBand will compute for a BUY drawing `amountIn` USDC at
    /// `price` — mirrors the contract's 18dp bond / 8dp NAV / 6dp USDC /1e20 ladder.
    /// Lets the band tests state their fixtures in dollars instead of magic constants.
    function _navValueForBuy(uint256 amountIn, uint256 price) internal pure returns (uint256) {
        uint256 amountOut = (amountIn * price) / 1e18;
        // forge-lint: disable-next-line(unsafe-typecast)
        return (amountOut * uint256(NAV)) / 1e20;
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
    /// docs/ARCHITECTURE.md must be exactly reproducible from the CONTRACT's own
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
    /// On a production chain the NAV feed stopped being pushed on 2026-05-19. Euler froze on
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
    // I-15b (GYL-1135) — the NAV band is structurally bounded
    // ═════════════════════════════════════════════════════════════════════════
    //
    // Context. The NAV band and the quote TTL are the two defences against a
    // COMPROMISED QUOTE-SIGNER KEY: the signer can mint arbitrarily-priced valid
    // signatures, and the band is what caps the value extractable per swap. Until
    // GYL-1135 the only bound on setMaxQuoteDeviationBps was BPS_DENOMINATOR itself —
    // a ±100% band, which admits any price from zero to 2× NAV and makes the band
    // decorative while every getter still reported it as "enforced".
    // MAX_QUOTE_DEVIATION_BPS_CEILING (1000 bps) closes that.

    /// No admin call, for any input above the ceiling, can widen the band.
    function testFuzz_setMaxQuoteDeviationBps_revertsAboveCeiling(uint16 newBps) public {
        uint16 ceiling = swap.MAX_QUOTE_DEVIATION_BPS_CEILING();
        newBps = uint16(bound(uint256(newBps), uint256(ceiling) + 1, uint256(type(uint16).max)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, newBps));
        swap.setMaxQuoteDeviationBps(newBps);

        assertEq(swap.maxQuoteDeviationBps(), MAX_BPS, "a rejected setter must leave the band untouched");
    }

    /// The ceiling itself is accepted — the bound is inclusive, so a deliberately wide
    /// band for a volatile session remains configurable. 1000 bps is not arbitrary: it
    /// is KaleidoscopeNAVFeed.MAX_PRICE_DEVIATION_BPS, this system's own definition of
    /// the largest plausible single-step price move (the feed rejects any push beyond it).
    function test_setMaxQuoteDeviationBps_ceilingExactlyIsAccepted() public {
        uint16 ceiling = swap.MAX_QUOTE_DEVIATION_BPS_CEILING();
        assertEq(ceiling, 1000, "ceiling must match the NAV feed's own per-update deviation cap");
        assertLt(
            uint256(ceiling), swap.BPS_DENOMINATOR(), "the ceiling must be strictly tighter than the old +-100% bound"
        );

        vm.prank(admin);
        swap.setMaxQuoteDeviationBps(ceiling);
        assertEq(swap.maxQuoteDeviationBps(), ceiling);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, ceiling + 1));
        swap.setMaxQuoteDeviationBps(ceiling + 1);

        // Zero stays legal: that is the RESTRICTIVE end (quotes must match NAV exactly),
        // which is a soft-pause and therefore safe to permit.
        vm.prank(admin);
        swap.setMaxQuoteDeviationBps(0);
        assertEq(swap.maxQuoteDeviationBps(), 0);
    }

    /// The same bound applies at construction — otherwise a fresh deployment could be
    /// born with the band already decorative and never trip the setter check.
    function test_initialize_revertsAboveDeviationCeiling() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        uint16 ceiling = impl.MAX_QUOTE_DEVIATION_BPS_CEILING();

        uint16 tooWide = ceiling + 1;
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, tooWide));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(usdc), tooWide, MAX_NAV_AGE)
            )
        );

        // REGRESSION: BPS_DENOMINATOR (10_000 = +-100%) was the old permitted maximum, so
        // this exact call used to SUCCEED and produce a live deployment with no band.
        uint16 hundredPercent = uint16(impl.BPS_DENOMINATOR());
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, hundredPercent));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(usdc), hundredPercent, MAX_NAV_AGE)
            )
        );

        // uint16 max — the "just make it never trip" value — is rejected too.
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, type(uint16).max));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize,
                (admin, pauser, signer, treasurer, address(usdc), type(uint16).max, MAX_NAV_AGE)
            )
        );

        // The ceiling still deploys, and so does zero (soft-pause).
        GyldAtomicSwap atCeiling = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, signer, treasurer, address(usdc), ceiling, MAX_NAV_AGE)
                    )
                )
            )
        );
        assertEq(atCeiling.maxQuoteDeviationBps(), ceiling);
    }

    /// REGRESSION TEST FOR THE DEFECT CLASS (GYL-1135), band edition.
    ///
    /// A ±100% band is not a band. Under the old bound an admin could set 10_000 bps and
    /// every price from zero to 2× NAV would validate — so a compromised quote signer
    /// could hand a taker 20 bond tokens for the price of 10 and the contract would call
    /// it in-band. This test asserts the band survives a full-authority attempt to remove
    /// it: hold DEFAULT_ADMIN_ROLE, fail to set an absurd width, widen to the maximum
    /// permitted, and confirm the 2×-NAV steal STILL fails closed.
    function test_navBandCannotBeDisabledByAdmin() public {
        _approveTaker();

        // Full authority: a fresh admin account holding DEFAULT_ADMIN_ROLE, i.e. the
        // strongest caller that exists on this contract.
        address rogueAdmin = address(0xBADBA9D);
        bytes32 adminRole = swap.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        swap.grantRole(adminRole, rogueAdmin);
        assertTrue(swap.hasRole(adminRole, rogueAdmin));

        // Attempt 1: the direct "never trip" value.
        vm.prank(rogueAdmin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, type(uint16).max));
        swap.setMaxQuoteDeviationBps(type(uint16).max);

        // Attempt 2: 10_000 bps — the value the OLD bound explicitly allowed.
        uint16 hundredPercent = uint16(swap.BPS_DENOMINATOR());
        vm.prank(rogueAdmin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, hundredPercent));
        swap.setMaxQuoteDeviationBps(hundredPercent);

        // Attempt 3: one basis point past the ceiling.
        // Cache the ceiling before pranking — a getter call would consume the prank.
        uint16 ceiling = swap.MAX_QUOTE_DEVIATION_BPS_CEILING();
        vm.prank(rogueAdmin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, ceiling + 1));
        swap.setMaxQuoteDeviationBps(ceiling + 1);

        // The band is unchanged, and is still meaningfully narrow.
        assertEq(swap.maxQuoteDeviationBps(), MAX_BPS);
        assertLe(swap.maxQuoteDeviationBps(), ceiling);

        // The widest the admin CAN go is 10% — apply it, to prove the band still bites
        // even at maximum permitted laxity.
        vm.prank(rogueAdmin);
        swap.setMaxQuoteDeviationBps(ceiling);
        assertEq(swap.maxQuoteDeviationBps(), ceiling);

        // The widening was real, not cosmetic: a 5%-off-NAV quote is rejected under the
        // 2% default but settles under the 10% ceiling. (price 1.05e28 → 10.5 tokens for
        // 1_000 USDC, i.e. navValue 1_050 USDC against 1_000 paid.)
        uint256 draw = 1_000e6;
        GyldAtomicSwap.SwapMessage memory inBand = _buyQuote(101, draw);
        inBand.price = 1.05e28;
        assertEq(_navValueForBuy(draw, inBand.price), 1_050e6, "fixture: 5% off NAV");
        // Sign BEFORE pranking — _sign calls hashSwapMessage, which would consume the prank.
        bytes memory inBandSig = _sign(inBand);
        vm.prank(taker);
        swap.executeSwap(inBand, inBandSig, _noPermit(), draw);
        assertTrue(swap.isQuoteUsed(101), "a 5%-off quote must settle under a 10% band");

        // Now the compromised-signer steal that a +-100% band would have waved through:
        // 20 bond tokens (navValue 2_000 USDC) for 1_000 USDC paid — 50% off NAV.
        GyldAtomicSwap.SwapMessage memory steal = _buyQuote(102, draw);
        steal.price = 2e28;
        uint256 stolenNavValue = _navValueForBuy(draw, steal.price);
        assertEq(stolenNavValue, 2_000e6, "fixture: 2x NAV, the extreme a +-100% band admits");
        bytes memory stealSig = _sign(steal);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuotePriceOutOfBand.selector, draw, stolenNavValue));
        swap.executeSwap(steal, stealSig, _noPermit(), draw);
        assertFalse(swap.isQuoteUsed(102), "no swap may settle 50% off NAV at any admin setting");

        // And a quote AT NAV still settles — the band is a band, not a brick.
        GyldAtomicSwap.SwapMessage memory atNav = _buyQuote(103, draw);
        bytes memory atNavSig = _sign(atNav);
        vm.prank(taker);
        swap.executeSwap(atNav, atNavSig, _noPermit(), draw);
        assertTrue(swap.isQuoteUsed(103), "an at-NAV quote must remain tradable");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // I-15c (GYL-1135) — the quote TTL is structurally bounded
    // ═════════════════════════════════════════════════════════════════════════
    //
    // Context. setMaxQuoteTtl had NO validation at all and the field is uint64, so one
    // DEFAULT_ADMIN_ROLE call could push the cap past any real elapsed time and defeat
    // quote expiry outright — after which a leaked signed quote stays executable
    // indefinitely, the exact failure the F-4 TTL was added to prevent.
    //
    // What the TTL is and is NOT. It is one of THREE containments on a leaked quote, and
    // the only timelocked one. pause() (PAUSER_ROLE, ops multisig) and
    // setAllowed(taker,false) (ALLOWLIST_ADMIN_ROLE, split off DEFAULT_ADMIN precisely so
    // it need not wait on governance) both land in a single block on hot keys — quotes are
    // taker-bound, so revoking one taker kills every quote naming them. Nor does the TTL
    // protect the NAV band: _checkQuoteBand re-reads the feed LIVE on every execution.
    // What the TTL bounds is the WINDOW in which a leaked quote can be exercised as an
    // AMERICAN OPTION before anyone notices — the taker holds a frozen price and picks
    // its most favourable moment, so the leak costs close to the full band width rather
    // than a fraction of it. That is the case the two hot keys do not cover, because they
    // require someone to already know.

    /// No admin call, for any input above the ceiling, can extend quote lifetime.
    function testFuzz_setMaxQuoteTtl_revertsAboveCeiling(uint64 newTtl) public {
        uint64 ceiling = swap.MAX_QUOTE_TTL_CEILING();
        newTtl = uint64(bound(uint256(newTtl), uint256(ceiling) + 1, uint256(type(uint64).max)));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteTtl.selector, newTtl));
        swap.setMaxQuoteTtl(newTtl);

        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL(), "a rejected setter must leave the TTL untouched");
    }

    /// The ceiling itself is accepted — the bound is inclusive. The ceiling sits ABOVE
    /// DEFAULT_MAX_QUOTE_TTL, so the knob is genuinely two-way: the TTL can be tuned
    /// operationally in either direction without an upgrade, while the catastrophic
    /// setting (anything past the 10-minute incident headroom) stays unreachable.
    function test_setMaxQuoteTtl_ceilingExactlyIsAccepted() public {
        uint64 ceiling = swap.MAX_QUOTE_TTL_CEILING();
        assertEq(ceiling, 10 minutes, "ceiling must be the 10-minute incident headroom");
        assertGt(ceiling, swap.DEFAULT_MAX_QUOTE_TTL(), "the default must leave room to tune upward");

        vm.prank(admin);
        swap.setMaxQuoteTtl(ceiling);
        assertEq(swap.maxQuoteTtl(), ceiling);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteTtl.selector, ceiling + 1));
        swap.setMaxQuoteTtl(ceiling + 1);

        // Zero is the UNSET sentinel, NOT "zero seconds" — it resets to the compiled-in
        // default. Literal zero-seconds would contradict the QuoteExpired check one line
        // above it in executeSwap and reject every quote a real service can issue.
        vm.prank(admin);
        swap.setMaxQuoteTtl(0);
        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL(), "zero must fall back, never disable");
    }

    /// The initialize side of the bound. initialize deliberately does NOT write the TTL
    /// slot — the effective cap comes from the DEFAULT_MAX_QUOTE_TTL fallback, so a fresh
    /// deploy and a proxy upgraded across the field's addition enforce the same value with
    /// no migration step. Pin BOTH halves: the constant satisfies the ceiling, and the
    /// slot really is left at zero (which is what the fallback exists to absorb).
    function test_initialize_leavesTtlUnsetAndFallbackIsWithinCeiling() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        assertLe(
            impl.DEFAULT_MAX_QUOTE_TTL(),
            impl.MAX_QUOTE_TTL_CEILING(),
            "the fallback default must itself satisfy the ceiling"
        );

        GyldAtomicSwap fresh = _deploySwap(address(usdc));
        assertLe(fresh.maxQuoteTtl(), fresh.MAX_QUOTE_TTL_CEILING(), "a fresh deployment must be born bounded");
        assertEq(fresh.maxQuoteTtl(), fresh.DEFAULT_MAX_QUOTE_TTL(), "fresh deploy enforces the fallback");

        // The raw slot at B+8 is untouched by initialize — the getter's value is the
        // fallback, not a stored seed. This is the invariant that makes an un-migrated
        // upgrade safe; if initialize ever starts seeding again, this fails and the
        // upgrade path silently regains its brick.
        bytes32 base = 0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300;
        bytes32 raw = vm.load(address(fresh), bytes32(uint256(base) + 8));
        assertEq(uint256(raw), 0, "initialize must leave maxQuoteTtl unset");

        // A fresh deployment cannot be widened past the ceiling afterwards either.
        uint64 ceiling = fresh.MAX_QUOTE_TTL_CEILING();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteTtl.selector, ceiling + 1));
        fresh.setMaxQuoteTtl(ceiling + 1);
    }

    /// REGRESSION TEST FOR THE DEFECT CLASS (GYL-1135), TTL edition.
    ///
    /// An unbounded TTL defeats quote expiry, so a leaked signed quote stays executable
    /// indefinitely — and with bumpQuoteEpoch behind the production timelock, expiry is
    /// the only fast containment. This test asserts it survives a full-authority attempt
    /// to remove it: hold DEFAULT_ADMIN_ROLE, fail to set an immortal TTL, widen to the
    /// maximum permitted, and confirm a long-dated quote STILL fails closed.
    function test_quoteTtlCannotBeDisabledByAdmin() public {
        _approveTaker();

        address rogueAdmin = address(0xBADDA7E); // "bad date"
        bytes32 adminRole = swap.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        swap.grantRole(adminRole, rogueAdmin);
        assertTrue(swap.hasRole(adminRole, rogueAdmin));

        // Attempt 1: the direct "never expire" value.
        vm.prank(rogueAdmin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteTtl.selector, type(uint64).max));
        swap.setMaxQuoteTtl(type(uint64).max);

        // Attempt 2: a plausible-looking but still guard-defeating 10 years.
        uint64 tenYears = 3650 days;
        vm.prank(rogueAdmin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteTtl.selector, tenYears));
        swap.setMaxQuoteTtl(tenYears);

        // Attempt 3: a merely "operationally convenient" 1 day — still 144x the ceiling.
        vm.prank(rogueAdmin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteTtl.selector, uint64(1 days)));
        swap.setMaxQuoteTtl(1 days);

        // The TTL is unchanged, and is still meaningfully short.
        // Cache the ceiling before pranking — a getter call would consume the prank.
        uint64 ceiling = swap.MAX_QUOTE_TTL_CEILING();
        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL());
        assertLe(swap.maxQuoteTtl(), ceiling);

        // The widest the admin CAN go is 10 minutes — apply it, to prove expiry still bites
        // even at maximum permitted laxity.
        vm.prank(rogueAdmin);
        swap.setMaxQuoteTtl(ceiling);

        // Now the leaked-quote scenario: a 30-day quote from a compromised signer. Under
        // an unbounded TTL this executes; it must fail closed at every admin setting.
        uint256 draw = 1_000e6;
        GyldAtomicSwap.SwapMessage memory immortal = _buyQuote(111, draw);
        immortal.expiry = uint64(block.timestamp + 30 days);
        // Sign BEFORE pranking — _sign calls hashSwapMessage, which would consume the prank.
        bytes memory immortalSig = _sign(immortal);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.QuoteExpiryTooFar.selector, immortal.expiry, uint64(block.timestamp + ceiling)
            )
        );
        swap.executeSwap(immortal, immortalSig, _noPermit(), draw);
        assertFalse(swap.isQuoteUsed(111), "a 30-day quote must not settle at any admin setting");

        // Even one second past the widest permitted TTL is refused.
        GyldAtomicSwap.SwapMessage memory oneOver = _buyQuote(112, draw);
        oneOver.expiry = uint64(block.timestamp + ceiling + 1);
        bytes memory oneOverSig = _sign(oneOver);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.QuoteExpiryTooFar.selector, oneOver.expiry, uint64(block.timestamp + ceiling)
            )
        );
        swap.executeSwap(oneOver, oneOverSig, _noPermit(), draw);
        assertFalse(swap.isQuoteUsed(112));

        // A quote inside the TTL still settles — the cap is a bound, not a brick.
        GyldAtomicSwap.SwapMessage memory nearTerm = _buyQuote(113, draw);
        nearTerm.expiry = uint64(block.timestamp + ceiling);
        bytes memory nearTermSig = _sign(nearTerm);
        vm.prank(taker);
        swap.executeSwap(nearTerm, nearTermSig, _noPermit(), draw);
        assertTrue(swap.isQuoteUsed(113), "a quote at exactly the TTL edge must remain tradable");
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
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });
        // The re-entrant call dies on the guard (the FIRST modifier), so the message and
        // signature never get validated — an empty signature is sufficient.
        evil.armExecuteSwap(address(swap), rm, "", 1_000e6);

        vm.prank(treasurer);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        swap.withdraw(address(evil), 10e18);
    }

    /// The FIND-024 sweep is the third path that moves tokens out, so it carries the same
    /// exclusion: a malicious series cannot use the sweep's transfer hook to enter
    /// executeSwap. Same guard, so the re-entrant call dies before the message is read.
    function test_deregisterSeriesSweep_cannotReenterExecuteSwap() public {
        MockReentrantToken evil = new MockReentrantToken();
        evil.mint(address(swap), 100e18); // mint BEFORE arming (the hook fires on mint too)

        vm.prank(admin);
        swap.registerSeries(address(evil), address(navFeed)); // reports 18 decimals

        ISwapReentryTarget.SwapMessage memory rm = ISwapReentryTarget.SwapMessage({
            quoteId: 998,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: 1_000e6,
            tokenOut: address(evil),
            price: 1e28,
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });
        evil.armExecuteSwap(address(swap), rm, "", 1_000e6);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        swap.deregisterSeries(address(evil));
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

    /// I-8 is scoped to DEFAULT_ADMIN_ROLE alone: EVERY other role stays renounceable.
    ///
    /// F-7 proposed extending the block to PAUSER and TREASURER on the theory that a sole
    /// holder self-renouncing would strand incident response. Rejected, and this test pins
    /// the rejection so it is not silently reintroduced. The theory fails because
    /// DEFAULT_ADMIN_ROLE administers every role — no `_setRoleAdmin` call exists anywhere
    /// and `getRoleAdmin`/`grantRole` are unoverridden — so a renounce costs one re-grant,
    /// never a permanent loss. And the guard removed the case that matters: a holder who
    /// knows their key is compromised shedding it immediately, rather than waiting on a
    /// timelocked revokeRole.
    function test_renounceRole_onlyAdminRoleIsBlocked() public {
        // The incident-response pair: renounceable, and re-grantable.
        bytes32 pauserRole = swap.PAUSER_ROLE();
        vm.prank(pauser);
        swap.renounceRole(pauserRole, pauser);
        assertFalse(swap.hasRole(pauserRole, pauser));
        vm.prank(admin);
        swap.grantRole(pauserRole, pauser);
        assertTrue(swap.hasRole(pauserRole, pauser), "nothing is stranded by a renounce");

        bytes32 treasurerRole = swap.TREASURER_ROLE();
        vm.prank(treasurer);
        swap.renounceRole(treasurerRole, treasurer);
        assertFalse(swap.hasRole(treasurerRole, treasurer));

        // Signer rotation and ops-key retirement stay available too.
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
    /// B+3..B+7 were UNPINNED before GYL-1208. Five reference-type fields sat
    /// unasserted between the packed head (B+0..B+2) and the appended tail (B+8).
    ///
    /// The two negative assertions at the end are why this matters most:
    /// `registeredSeries` (B+5) and `allowed` (B+7) are BOTH `mapping(address => bool)`.
    /// Swapping them compiles clean and leaves every other test in the suite passing,
    /// while on a live proxy it makes every allowlisted taker a registered bond series —
    /// and the swap's whole leg classification (`buy`/`redeem` in _checkQuoteBand) is
    /// built on exactly those two mappings.
    ///
    /// Kept separate from test_storageLayout_erc7201SlotAndPacking because that test
    /// bumps the epoch and holds a prank, which a real executeSwap here would fight.
    function test_storageLayout_referenceTypeFieldsPinned() public {
        bytes32 B = keccak256(abi.encode(uint256(keccak256("gyld.GyldAtomicSwap")) - 1)) & ~bytes32(uint256(0xff));
        _approveTaker();

        // usedQuoteWords (B+3): one 256-bit word per (quoteId >> 8), bit (quoteId & 0xff).
        uint256 usedId = 24;
        GyldAtomicSwap.SwapMessage memory used = _buyQuote(usedId, 1_000e6);
        // Sign BEFORE pranking: _sign calls swap.hashSwapMessage, and an external call
        // consumes the prank (the same trap the role-getter comments warn about), which
        // would make the test contract the caller and revert NotTaker.
        bytes memory sig = _sign(used);
        vm.prank(taker);
        swap.executeSwap(used, sig, _noPermit(), used.maxAmountIn);
        assertTrue(swap.isQuoteUsed(usedId), "precondition: the quote was consumed");
        uint256 word = uint256(vm.load(address(swap), keccak256(abi.encode(usedId >> 8, uint256(B) + 3))));
        assertEq((word >> (usedId & 0xff)) & 1, 1, "usedQuoteWords must occupy B+3");

        // seriesList (B+4): dynamic array — length at the slot, elements at keccak(slot).
        assertEq(uint256(vm.load(address(swap), bytes32(uint256(B) + 4))), 1, "seriesList length at B+4");
        assertEq(
            address(uint160(uint256(vm.load(address(swap), keccak256(abi.encode(bytes32(uint256(B) + 4))))))),
            address(token),
            "seriesList[0] must be the registered series"
        );

        // registeredSeries (B+5), navForwarderOf (B+6), allowed (B+7).
        assertEq(
            uint256(vm.load(address(swap), keccak256(abi.encode(address(token), uint256(B) + 5)))),
            1,
            "registeredSeries must occupy B+5"
        );
        assertEq(
            address(
                uint160(uint256(vm.load(address(swap), keccak256(abi.encode(address(token), uint256(B) + 6)))))
            ),
            address(navFeed),
            "navForwarderOf must occupy B+6"
        );
        assertEq(
            uint256(vm.load(address(swap), keccak256(abi.encode(taker, uint256(B) + 7)))),
            1,
            "allowed must occupy B+7"
        );

        // NEGATIVE: the two address=>bool mappings must not be interchangeable.
        assertEq(
            uint256(vm.load(address(swap), keccak256(abi.encode(address(token), uint256(B) + 7)))),
            0,
            "a registered series must NOT appear in allowed's slot (B+5/B+7 swapped?)"
        );
        assertEq(
            uint256(vm.load(address(swap), keccak256(abi.encode(taker, uint256(B) + 5)))),
            0,
            "an allowlisted taker must NOT appear in registeredSeries' slot (B+5/B+7 swapped?)"
        );
    }

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
        // append-only: nothing above moved. Prove the slot is REACHABLE and correctly
        // placed by writing it through the setter, since initialize deliberately leaves
        // it zero (the fallback absorbs the unset case — see
        // test_initialize_leavesTtlUnsetAndFallbackIsWithinCeiling).
        vm.prank(admin);
        swap.setMaxQuoteTtl(7 minutes);
        assertEq(
            uint64(uint256(vm.load(address(swap), bytes32(uint256(derived) + 8)))),
            7 minutes,
            "maxQuoteTtl must occupy B+8 offset 0 (8 bytes)"
        );
        assertEq(swap.maxQuoteTtl(), 7 minutes, "getter must read the slot it wrote");

        // Back to unset: the slot clears and the getter reports the fallback, not zero.
        vm.prank(admin);
        swap.setMaxQuoteTtl(0);
        assertEq(uint256(vm.load(address(swap), bytes32(uint256(derived) + 8))), 0, "slot must clear");

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
            expiry: uint64(block.timestamp + 60 seconds),
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
        assertEq(ttl, 90 seconds, "spec: the effective cap is the DEFAULT_MAX_QUOTE_TTL fallback");

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
        swap.setMaxQuoteTtl(30 seconds);

        vm.prank(admin);
        swap.setMaxQuoteTtl(30 seconds);
        assertEq(swap.maxQuoteTtl(), 30 seconds);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(26, 1_000e6); // expiry = +60 s, i.e. beyond the 30 s cap just set
        bytes memory sig = _sign(m);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.QuoteExpiryTooFar.selector, m.expiry, uint64(block.timestamp + 30 seconds)
            )
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }
}
