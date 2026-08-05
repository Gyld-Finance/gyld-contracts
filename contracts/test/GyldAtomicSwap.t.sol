// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockUSDCPermit} from "./MockUSDCPermit.sol";
import {MockNavForwarder} from "./MockNavForwarder.sol";
import {MockReentrantToken, ISwapReentryTarget} from "./MockReentrantToken.sol";

contract GyldAtomicSwapTest is Test {
    // Mirror events for vm.expectEmit (test pragma predates ContractName.Event syntax)
    event SwapExecuted(
        uint256 indexed quoteId,
        address indexed taker,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    );
    // amountIn/amountOut above are the ACTUAL executed amounts (requestedAmountIn and its
    // derived amountOut) — not the quote's maxAmountIn/price ceiling.
    event QuoteEpochBumped(uint64 indexed newEpoch);
    event WithdrawalWalletUpdated(address indexed previous, address indexed next);
    event AllowedSet(address indexed account, bool allowed);
    event MaxQuoteTtlUpdated(uint64 newTtl);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    GyldAtomicSwap swap;
    GyldBondToken token;
    MockUSDCPermit usdc;
    MockNavForwarder navFeed;
    MockSanctionsList mockSanctions;

    address admin = address(0xA0); // DEFAULT_ADMIN_ROLE on swap
    address pauser = address(0xA1); // PAUSER_ROLE on swap
    address treasurer = address(0xA2); // TREASURER_ROLE on swap
    address wallet = address(0xA3); // fixed withdrawalWallet
    address allowlistAdmin = address(0xA4); // ALLOWLIST_ADMIN_ROLE on swap (setAllowed only)
    address outsider = address(0xFF);

    // Known private keys — vm.addr(PK) is the corresponding address.
    // SIGNER_PK signs SwapMessages (QUOTE_SIGNER_ROLE); TAKER_PK signs permits.
    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK = 0xA11CE;
    address signer;
    address taker;

    // NAV $100.00 per token (8dp): 1e18 token ⇔ 100e6 USDC. The standard quote
    // below (10 tokens for 1_000 USDC) sits exactly on NAV — inside the 2% band.
    int256 constant NAV = 100e8;
    uint16 constant MAX_BPS = 200; // 2% band
    uint32 constant MAX_NAV_AGE = 1 days;

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        vm.warp(1_750_000_000); // realistic timestamp so expiry math is meaningful
        signer = vm.addr(SIGNER_PK);
        taker = vm.addr(TAKER_PK);

        mockSanctions = new MockSanctionsList(address(this));
        usdc = new MockUSDCPermit();
        navFeed = new MockNavForwarder(NAV);

        // ── GyldBondToken proxy ───────────────────────────────────────────────
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

        // ── GyldAtomicSwap proxy (self-custodial) ─────────────────────────────
        GyldAtomicSwap swapImpl = new GyldAtomicSwap();
        swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(swapImpl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, signer, treasurer, address(usdc), MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );

        // Wire: register the series (NAV band), set the withdrawal wallet, allowlist taker.
        vm.prank(admin);
        swap.registerSeries(address(token), address(navFeed));
        vm.prank(admin);
        swap.setWithdrawalWallet(wallet);

        // setAllowed is gated on ALLOWLIST_ADMIN_ROLE, not DEFAULT_ADMIN_ROLE (GYL-1050).
        // Cache the role bytes before pranking — the getter call would consume the prank.
        bytes32 allowlistRole = swap.ALLOWLIST_ADMIN_ROLE();
        vm.prank(admin);
        swap.grantRole(allowlistRole, allowlistAdmin);
        vm.prank(allowlistAdmin);
        swap.setAllowed(taker, true);

        // Fund the SWAP's own inventory (self-custodial): tokens minted straight to the
        // swap stand in for the IssuanceManager.subscribe mint-at-fill path.
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(this));
        token.mint(address(swap), 1_000e18);
        token.mint(taker, 100e18);
        usdc.mint(taker, 1_000_000e6);
        usdc.mint(address(swap), 100_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// BUY: taker may draw up to 1_000 USDC, priced exactly at NAV (10 tokens per 1_000 USDC).
    function _buyQuote(uint256 quoteId) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return _buyQuoteCapped(quoteId, 1_000e6);
    }

    /// BUY quote with an explicit `maxAmountIn` cap, same $100/token price as `_buyQuote`.
    function _buyQuoteCapped(uint256 quoteId, uint256 maxAmountIn)
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
            price: 1e28, // amountOut per 1e18 tokenIn: 10e18 tokens / 1_000e6 USDC * 1e18
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
    }

    /// REDEEM: taker may draw up to 10 bond tokens, priced exactly at NAV ($100/token).
    function _redeemQuote(uint256 quoteId) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return _redeemQuoteCapped(quoteId, 10e18);
    }

    /// REDEEM quote with an explicit `maxAmountIn` cap, same $100/token price as `_redeemQuote`.
    function _redeemQuoteCapped(uint256 quoteId, uint256 maxAmountIn)
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
            price: 100e6, // amountOut per 1e18 tokenIn: 1_000e6 USDC / 10e18 tokens * 1e18
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
    }

    /// amountOut a quote's price implies for a given draw, rounded down like the contract.
    function _impliedAmountOut(GyldAtomicSwap.SwapMessage memory m, uint256 requestedAmountIn)
        internal
        pure
        returns (uint256)
    {
        return (requestedAmountIn * m.price) / 1e18;
    }

    function _sign(GyldAtomicSwap.SwapMessage memory m, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, swap.hashSwapMessage(m));
        return abi.encodePacked(r, s, v);
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    /// EIP-2612 permit signed by the taker for `asset`, spender = the swap contract.
    /// Works for both MockUSDCPermit and GyldBondToken (standard Permit typehash).
    function _signPermit(address asset, uint256 value, uint256 deadline)
        internal
        view
        returns (GyldAtomicSwap.PermitData memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(PERMIT_TYPEHASH, taker, address(swap), value, IERC20Permit(asset).nonces(taker), deadline)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(asset).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TAKER_PK, digest);
        return GyldAtomicSwap.PermitData(value, deadline, v, r, s);
    }

    // ── Happy path: BUY (USDC in via permit, bond token out) ──────────────────

    function test_executeSwap_buy_withPermit_succeeds() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1);
        bytes memory sig = _sign(m, SIGNER_PK);
        GyldAtomicSwap.PermitData memory p = _signPermit(address(usdc), 1_000e6, block.timestamp + 15 minutes);

        vm.expectEmit(true, true, false, true, address(swap));
        emit SwapExecuted(1, taker, address(usdc), 1_000e6, address(token), 10e18);

        vm.prank(taker);
        swap.executeSwap(m, sig, p, m.maxAmountIn);

        // Self-custody: the swap itself holds inventory and the USDC pot.
        assertEq(usdc.balanceOf(taker), 1_000_000e6 - 1_000e6, "taker USDC not debited");
        assertEq(usdc.balanceOf(address(swap)), 100_000e6 + 1_000e6, "swap USDC not credited");
        assertEq(token.balanceOf(taker), 100e18 + 10e18, "taker tokens not credited");
        assertEq(token.balanceOf(address(swap)), 1_000e18 - 10e18, "swap inventory not debited");
        assertEq(usdc.allowance(taker, address(swap)), 0, "permit allowance not fully consumed");
        assertTrue(swap.isQuoteUsed(1), "quoteId not consumed");
    }

    /// permitIn.value == 0 skips the permit — a plain pre-approval works too.
    function test_executeSwap_buy_withAllowance_succeeds() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(2);
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);

        assertEq(token.balanceOf(taker), 100e18 + 10e18);
        assertEq(usdc.balanceOf(address(swap)), 100_000e6 + 1_000e6);
    }

    /// Partial draw: taker requests less than `maxAmountIn`; amountOut derives from `price`.
    function test_executeSwap_buy_partialDraw_succeeds() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuoteCapped(50, 1_000e6); // cap $1,000
        uint256 requested = 250e6; // draw a quarter of the cap
        uint256 expectedOut = _impliedAmountOut(m, requested); // 2.5 tokens
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        usdc.approve(address(swap), requested);

        vm.expectEmit(true, true, false, true, address(swap));
        emit SwapExecuted(50, taker, address(usdc), requested, address(token), expectedOut);

        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requested);

        assertEq(usdc.balanceOf(taker), 1_000_000e6 - requested, "taker USDC not debited for partial draw");
        assertEq(token.balanceOf(taker), 100e18 + expectedOut, "taker tokens not credited for partial draw");
        assertEq(usdc.allowance(taker, address(swap)), 0, "unused allowance should be fully consumed by transferFrom");
        assertTrue(swap.isQuoteUsed(50), "quoteId must be consumed even on a partial draw");
    }

    // ── Happy path: REDEEM (bond token in via GyldBondToken permit, USDC out) ─

    function test_executeSwap_redeem_withBondPermit_succeeds() public {
        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(3);
        bytes memory sig = _sign(m, SIGNER_PK);
        GyldAtomicSwap.PermitData memory p = _signPermit(address(token), 10e18, block.timestamp + 15 minutes);

        vm.expectEmit(true, true, false, true, address(swap));
        emit SwapExecuted(3, taker, address(token), 10e18, address(usdc), 1_000e6);

        vm.prank(taker);
        swap.executeSwap(m, sig, p, m.maxAmountIn);

        assertEq(token.balanceOf(taker), 100e18 - 10e18, "taker tokens not debited");
        assertEq(token.balanceOf(address(swap)), 1_000e18 + 10e18, "swap collateral not credited");
        assertEq(usdc.balanceOf(taker), 1_000_000e6 + 1_000e6, "taker USDC not credited");
        assertEq(usdc.balanceOf(address(swap)), 100_000e6 - 1_000e6, "swap USDC not debited");
        assertTrue(swap.isQuoteUsed(3));
    }

    // ── Quote validation ──────────────────────────────────────────────────────

    function test_executeSwap_expiredQuote_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(4);
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.warp(uint256(m.expiry) + 1);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteExpired.selector, m.expiry));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// F-4: a quote expiring beyond block.timestamp + maxQuoteTtl is rejected even
    /// though it has not expired — immortal quotes are unsignable.
    function test_executeSwap_expiryBeyondMaxQuoteTtl_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(70);
        m.expiry = uint64(block.timestamp + swap.maxQuoteTtl() + 1);
        bytes memory sig = _sign(m, SIGNER_PK);
        // Cache before vm.prank — a getter call would consume the prank.
        uint64 maxAllowed = uint64(block.timestamp + swap.maxQuoteTtl());

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteExpiryTooFar.selector, m.expiry, maxAllowed));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertFalse(swap.isQuoteUsed(70), "a too-far-out quote must not burn the quoteId");
    }

    /// The TTL bound is INCLUSIVE: expiry == block.timestamp + maxQuoteTtl executes.
    function test_executeSwap_expiryExactlyMaxQuoteTtl_succeeds() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(71);
        m.expiry = uint64(block.timestamp + swap.maxQuoteTtl());
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(71), "expiry exactly at the TTL bound must execute");
    }

    function test_executeSwap_staleEpoch_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(5); // epoch 0
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(admin);
        swap.bumpQuoteEpoch(); // current epoch is now 1

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteEpochStale.selector, uint64(0), uint64(1)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    function test_executeSwap_replayedQuoteId_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(6);
        bytes memory sig = _sign(m, SIGNER_PK);
        GyldAtomicSwap.PermitData memory p = _signPermit(address(usdc), 1_000e6, block.timestamp + 15 minutes);

        vm.prank(taker);
        swap.executeSwap(m, sig, p, m.maxAmountIn);

        // Same quoteId signed again (even on a different leg) must be rejected.
        GyldAtomicSwap.SwapMessage memory replay = _redeemQuote(6);
        bytes memory replaySig = _sign(replay, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteAlreadyUsed.selector, uint256(6)));
        swap.executeSwap(replay, replaySig, _noPermit(), replay.maxAmountIn);
    }

    function test_executeSwap_wrongSigner_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(7);
        uint256 badPk = 0xBADBADBAD;
        bytes memory sig = _sign(m, badPk); // valid signature, wrong key

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteSigner.selector, vm.addr(badPk)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    function test_executeSwap_wrongTaker_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(8);
        bytes memory sig = _sign(m, SIGNER_PK);

        // Allowlist the outsider so the revert is proven to come from the taker binding,
        // not the allowlist gate (taker binding is checked first regardless).
        vm.prank(allowlistAdmin);
        swap.setAllowed(outsider, true);

        vm.prank(outsider); // quote pins `taker` — anyone else must be rejected
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotTaker.selector, taker, outsider));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    function test_executeSwap_tamperedMessage_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(9);
        bytes memory sig = _sign(m, SIGNER_PK);

        m.price = 100e28; // taker tries to get 10x the tokens on a real signature

        vm.prank(taker);
        vm.expectRevert(); // recovered signer is garbage → InvalidQuoteSigner
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ── Allowlist ───────────────────────────────────────────────────────────────

    /// A taker who is NOT on the allowlist is rejected even with a valid signed quote.
    function test_executeSwap_nonAllowlistedTaker_reverts() public {
        // Revoke the taker's allowlisting.
        vm.prank(allowlistAdmin);
        swap.setAllowed(taker, false);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(30);
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotAllowed.selector, taker));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    function test_setAllowed_onlyAllowlistAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.setAllowed(outsider, true);
    }

    /// GYL-1050 structural pin: `setAllowed` must NOT be callable by the
    /// DEFAULT_ADMIN_ROLE holder. In production that role is the 48h TimelockController,
    /// so gating the live per-taker allowlist on it would make the gateway's synchronous
    /// allowlist API revert on every call. This test fails the moment the gate regresses.
    function test_setAllowed_defaultAdminCannotCall_reverts() public {
        bytes32 allowlistRole = swap.ALLOWLIST_ADMIN_ROLE();
        assertTrue(swap.hasRole(swap.DEFAULT_ADMIN_ROLE(), admin), "admin must hold DEFAULT_ADMIN_ROLE");
        assertFalse(swap.hasRole(allowlistRole, admin), "DEFAULT_ADMIN must not hold ALLOWLIST_ADMIN_ROLE");

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", admin, allowlistRole)
        );
        swap.setAllowed(outsider, true);
    }

    function test_setAllowed_allowlistAdmin_succeeds() public {
        assertFalse(swap.isAllowed(outsider));

        vm.expectEmit(true, false, false, true, address(swap));
        emit AllowedSet(outsider, true);
        vm.prank(allowlistAdmin);
        swap.setAllowed(outsider, true);

        assertTrue(swap.isAllowed(outsider));
    }

    /// Unlike DEFAULT_ADMIN_ROLE, the operational allowlist role is renounceable —
    /// it bricks nothing (the timelock can always re-grant it).
    function test_renounceRole_allowlistAdmin_succeeds() public {
        bytes32 allowlistRole = swap.ALLOWLIST_ADMIN_ROLE();
        vm.prank(allowlistAdmin);
        swap.renounceRole(allowlistRole, allowlistAdmin);
        assertFalse(swap.hasRole(allowlistRole, allowlistAdmin));
    }

    function test_setAllowed_zeroAddress_reverts() public {
        vm.prank(allowlistAdmin);
        vm.expectRevert(GyldAtomicSwap.ZeroAddress.selector);
        swap.setAllowed(address(0), true);
    }

    function test_setAllowed_emitsAndReAllows() public {
        vm.prank(allowlistAdmin);
        swap.setAllowed(taker, false);
        assertFalse(swap.isAllowed(taker));

        vm.expectEmit(true, false, false, true, address(swap));
        emit AllowedSet(taker, true);
        vm.prank(allowlistAdmin);
        swap.setAllowed(taker, true);
        assertTrue(swap.isAllowed(taker));

        // A freshly re-allowed taker can execute again.
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(31);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(31));
    }

    // ── Withdraw (TREASURER_ROLE → fixed withdrawalWallet) ───────────────────────

    function test_withdraw_byTreasurer_toWithdrawalWallet_succeeds() public {
        uint256 swapUsdcBefore = usdc.balanceOf(address(swap));
        uint256 swapTokenBefore = token.balanceOf(address(swap));

        // Withdraw USDC.
        vm.expectEmit(true, true, false, true, address(swap));
        emit Withdrawn(address(usdc), wallet, 5_000e6);
        vm.prank(treasurer);
        swap.withdraw(address(usdc), 5_000e6);

        assertEq(usdc.balanceOf(wallet), 5_000e6, "wallet USDC not credited");
        assertEq(usdc.balanceOf(address(swap)), swapUsdcBefore - 5_000e6, "swap USDC not debited");

        // Withdraw a second ERC-20 (the bond token stands in for USDG / any inventory).
        vm.prank(treasurer);
        swap.withdraw(address(token), 100e18);
        assertEq(token.balanceOf(wallet), 100e18, "wallet tokens not credited");
        assertEq(token.balanceOf(address(swap)), swapTokenBefore - 100e18, "swap tokens not debited");
    }

    function test_withdraw_nonTreasurer_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.withdraw(address(usdc), 1e6);
    }

    function test_withdraw_zeroAmount_reverts() public {
        vm.prank(treasurer);
        vm.expectRevert(GyldAtomicSwap.ZeroAmount.selector);
        swap.withdraw(address(usdc), 0);
    }

    /// A fresh proxy without a withdrawalWallet set: withdraw fails closed (ZeroAddress).
    function test_withdraw_walletNotSet_reverts() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        GyldAtomicSwap fresh = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, signer, treasurer, address(usdc), MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );
        usdc.mint(address(fresh), 1_000e6);

        assertEq(fresh.withdrawalWallet(), address(0), "fresh proxy should have no withdrawalWallet");
        vm.prank(treasurer);
        vm.expectRevert(GyldAtomicSwap.ZeroAddress.selector);
        fresh.withdraw(address(usdc), 1_000e6);
    }

    /// withdraw() is deliberately live while paused (funds must be evacuable in an incident).
    function test_withdraw_worksWhilePaused() public {
        vm.prank(pauser);
        swap.pause();

        vm.prank(treasurer);
        swap.withdraw(address(usdc), 1_000e6);
        assertEq(usdc.balanceOf(wallet), 1_000e6, "withdraw must work while paused");
    }

    // ── setWithdrawalWallet (DEFAULT_ADMIN only) ─────────────────────────────────

    function test_setWithdrawalWallet_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.setWithdrawalWallet(outsider);
    }

    function test_setWithdrawalWallet_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(GyldAtomicSwap.ZeroAddress.selector);
        swap.setWithdrawalWallet(address(0));
    }

    function test_setWithdrawalWallet_updatesAndEmits() public {
        address newWallet = address(0xBEEF);
        vm.expectEmit(true, true, false, false, address(swap));
        emit WithdrawalWalletUpdated(wallet, newWallet);
        vm.prank(admin);
        swap.setWithdrawalWallet(newWallet);
        assertEq(swap.withdrawalWallet(), newWallet);

        // Subsequent withdraws now route to the new wallet.
        vm.prank(treasurer);
        swap.withdraw(address(usdc), 1_000e6);
        assertEq(usdc.balanceOf(newWallet), 1_000e6, "withdraw routed to old wallet");
    }

    // ── NAV band ──────────────────────────────────────────────────────────────

    /// A quote priced far ABOVE NAV (too much USDC per token) is outside the 2% band.
    function test_executeSwap_quoteAboveBand_reverts() public {
        // NAV drops to $50/token; the standard 10-tokens-for-1000-USDC quote now implies
        // $100/token — double NAV, well outside the 2% band.
        navFeed.setAnswer(50e8);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(40);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        // 10 tokens at $50 NAV = 500e6 navValue; quoted usdcAmount = 1_000e6 > band.
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.QuotePriceOutOfBand.selector, uint256(1_000e6), uint256(500e6))
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// A quote priced far BELOW NAV (too little USDC per token) is outside the 2% band.
    function test_executeSwap_quoteBelowBand_reverts() public {
        // NAV rises to $200/token; the standard quote implies $100/token — half of NAV.
        navFeed.setAnswer(200e8);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(41);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        // 10 tokens at $200 NAV = 2_000e6 navValue; quoted 1_000e6 + band < navValue.
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.QuotePriceOutOfBand.selector, uint256(1_000e6), uint256(2_000e6))
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// Edge pinning (GYL-724 style): NAV fixed at $100. A BUY of ~10 tokens (the price
    /// floor lands amountOut at 9.999…e18 → navValue 999_999_999, band 19_999_999, so
    /// the inclusive upper edge navValue+band = 1_019_999_998). A quote just inside that
    /// (1_019e6 USDC in) must pass; 1_021e6 lands one notch above the edge and reverts.
    function test_executeSwap_justInsideUpperBandEdge_succeeds() public {
        uint256 price = uint256(10e18) * 1e18 / uint256(1_019e6);
        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: 42,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: 1_019e6,
            tokenOut: address(token),
            price: price,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_019e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(42), "quote just inside the upper edge should pass");
    }

    /// One notch past the upper edge (1_021e6 > navValue+band) reverts.
    function test_executeSwap_justAboveUpperBandEdge_reverts() public {
        uint256 price = uint256(10e18) * 1e18 / uint256(1_021e6);
        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: 48,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: 1_021e6,
            tokenOut: address(token),
            price: price,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
        uint256 amountOut = _impliedAmountOut(m, m.maxAmountIn);
        uint256 navValue = (amountOut * uint256(NAV)) / 1e20;
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_021e6);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuotePriceOutOfBand.selector, uint256(1_021e6), navValue));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    function test_executeSwap_invalidNav_reverts() public {
        navFeed.setAnswer(0); // non-positive NAV is a hard feed fault → fail closed

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(43);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNav.selector, address(token), int256(0)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    function test_executeSwap_staleNav_reverts() public {
        uint256 stale = block.timestamp - (uint256(MAX_NAV_AGE) + 1); // just past the max age
        navFeed.setUpdatedAt(stale);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(44);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.StaleNav.selector, address(token), stale));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// F-6: a future-dated updatedAt would satisfy the age check forever
    /// (updatedAt + maxNavAgeSecs stays ahead of block.timestamp) — it must revert
    /// StaleNav just like an old feed. The inclusive fresh edge updatedAt ==
    /// block.timestamp is the mock's default, exercised by every happy-path test.
    function test_executeSwap_futureDatedNav_reverts() public {
        uint256 future = block.timestamp + 1;
        navFeed.setUpdatedAt(future);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(73);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.StaleNav.selector, address(token), future));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// A quote where NEITHER leg is a registered series against USDC → NotOneBondLeg.
    function test_executeSwap_unregisteredSeries_reverts() public {
        // Deregister the series (after draining inventory so the guard passes).
        vm.prank(treasurer);
        swap.withdraw(address(token), 1_000e18);
        vm.prank(admin);
        swap.deregisterSeries(address(token));

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(45);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotOneBondLeg.selector, address(usdc), address(token)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ── Inventory insufficiency ─────────────────────────────────────────────────

    /// BUY with the swap's bond inventory drained → InsufficientInventory.
    function test_executeSwap_insufficientInventory_reverts() public {
        // Drain the swap's entire bond inventory to the withdrawalWallet.
        vm.prank(treasurer);
        swap.withdraw(address(token), 1_000e18);
        assertEq(token.balanceOf(address(swap)), 0);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(46);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.InsufficientInventory.selector, address(token), uint256(10e18), uint256(0)
            )
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// REDEEM with the swap's USDC drained → InsufficientUsdcLiquidity.
    function test_executeSwap_insufficientUsdcLiquidity_reverts() public {
        // Drain the swap's entire USDC pot.
        vm.prank(treasurer);
        swap.withdraw(address(usdc), 100_000e6);
        assertEq(usdc.balanceOf(address(swap)), 0);

        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(47);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        token.approve(address(swap), 10e18);

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(GyldAtomicSwap.InsufficientUsdcLiquidity.selector, uint256(1_000e6), uint256(0))
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ── Series registry admin ───────────────────────────────────────────────────

    function test_registerSeries_eoaForwarder_reverts() public {
        address eoa = address(0xEEEE);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotValidForwarder.selector, eoa));
        swap.registerSeries(address(0xD00D), eoa);
    }

    /// F-1: the bond token's decimals are probed on-chain — a 6-decimal "series"
    /// (MockUSDC standing in) would silently vacuum the /1e20 NAV band.
    function test_registerSeries_wrongDecimalsToken_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidTokenDecimals.selector, address(usdc), uint8(6)));
        swap.registerSeries(address(usdc), address(navFeed));
    }

    /// F-1: a token with no decimals() at all (EOA) is rejected too — reported as 0.
    function test_registerSeries_tokenWithoutDecimals_reverts() public {
        address eoa = address(0xD00D);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidTokenDecimals.selector, eoa, uint8(0)));
        swap.registerSeries(eoa, address(navFeed));
    }

    function test_registerSeries_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(GyldAtomicSwap.ZeroAddress.selector);
        swap.registerSeries(address(0), address(navFeed));
    }

    function test_registerSeries_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.registerSeries(address(0xD00D), address(navFeed));
    }

    function test_deregisterSeries_nonEmpty_reverts() public {
        // The swap still holds 1_000e18 of the series from setUp.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.SeriesNotEmpty.selector, address(token)));
        swap.deregisterSeries(address(token));
    }

    function test_deregisterSeries_unregistered_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.UnregisteredSeries.selector, address(0xD00D)));
        swap.deregisterSeries(address(0xD00D));
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    function test_executeSwap_whenPaused_reverts() public {
        vm.prank(pauser);
        swap.pause();

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(10);
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// Asymmetric pause: PAUSER halts but cannot resume; admin resumes.
    function test_pause_asymmetric_onlyAdminUnpauses() public {
        vm.prank(pauser);
        swap.pause();

        vm.prank(pauser);
        vm.expectRevert();
        swap.unpause();

        vm.prank(admin);
        swap.unpause();

        // Swap works again post-unpause.
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(11);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(11));
    }

    // ── Permit front-run griefing ─────────────────────────────────────────────

    /// An attacker who observes the permit in the mempool and submits it directly
    /// consumes the nonce — the in-swap permit then fails, but the try/catch
    /// swallows it and the allowance (already set by the front-run) still covers
    /// the transferFrom. The swap MUST NOT brick.
    function test_executeSwap_permitFrontRun_doesNotBrick() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(12);
        bytes memory sig = _sign(m, SIGNER_PK);
        uint256 deadline = block.timestamp + 15 minutes;
        GyldAtomicSwap.PermitData memory p = _signPermit(address(usdc), 1_000e6, deadline);

        // Front-run: outsider lands the exact same permit first.
        vm.prank(outsider);
        usdc.permit(taker, address(swap), 1_000e6, deadline, p.v, p.r, p.s);
        assertEq(usdc.nonces(taker), 1, "front-run permit not consumed");
        assertEq(usdc.allowance(taker, address(swap)), 1_000e6);

        // Taker's original transaction still succeeds.
        vm.prank(taker);
        swap.executeSwap(m, sig, p, m.maxAmountIn);

        assertEq(token.balanceOf(taker), 100e18 + 10e18, "swap bricked by permit front-run");
        assertTrue(swap.isQuoteUsed(12));
    }

    // ── Requested-amount range (capped-allowance SwapMessage) ──────────────────

    function test_executeSwap_zeroRequestedAmountIn_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(13);
        bytes memory sig = _sign(m, SIGNER_PK);
        uint256 minAllowed = (m.maxAmountIn * swap.MIN_DRAW_BPS()) / swap.BPS_DENOMINATOR();

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.RequestedAmountOutOfRange.selector, uint256(0), minAllowed, m.maxAmountIn
            )
        );
        swap.executeSwap(m, sig, _noPermit(), 0);
    }

    function test_executeSwap_requestedAmountInBelowDustFloor_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(14);
        bytes memory sig = _sign(m, SIGNER_PK);
        uint256 minAllowed = (m.maxAmountIn * swap.MIN_DRAW_BPS()) / swap.BPS_DENOMINATOR(); // 1% of 1_000e6
        uint256 dustDraw = minAllowed - 1;

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.RequestedAmountOutOfRange.selector, dustDraw, minAllowed, m.maxAmountIn
            )
        );
        swap.executeSwap(m, sig, _noPermit(), dustDraw);
    }

    function test_executeSwap_requestedAmountInAboveMaxAmountIn_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(15);
        bytes memory sig = _sign(m, SIGNER_PK);
        uint256 minAllowed = (m.maxAmountIn * swap.MIN_DRAW_BPS()) / swap.BPS_DENOMINATOR();
        uint256 overDraw = m.maxAmountIn + 1;

        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.RequestedAmountOutOfRange.selector, overDraw, minAllowed, m.maxAmountIn
            )
        );
        swap.executeSwap(m, sig, _noPermit(), overDraw);
    }

    function test_executeSwap_zeroPrice_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(16);
        m.price = 0;
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(GyldAtomicSwap.ZeroAmount.selector);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// A draw so small that `requestedAmountIn * price / 1e18` truncates to zero must
    /// revert rather than silently move `tokenIn` for zero `tokenOut`. A tiny-enough
    /// `maxAmountIn` puts even the 1%-dust-floor draw below the rounding threshold.
    function test_executeSwap_impliedAmountOutRoundsToZero_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _redeemQuoteCapped(17, 1e11); // minAllowed = 1e9
        uint256 minAllowed = (m.maxAmountIn * swap.MIN_DRAW_BPS()) / swap.BPS_DENOMINATOR();
        assertEq(_impliedAmountOut(m, minAllowed), 0, "test fixture must actually round amountOut to zero");
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(GyldAtomicSwap.ZeroAmount.selector);
        swap.executeSwap(m, sig, _noPermit(), minAllowed);
    }

    // ── Quote epoch ───────────────────────────────────────────────────────────

    function test_bumpQuoteEpoch_incrementsAndEmits() public {
        assertEq(swap.quoteEpoch(), 0);

        vm.expectEmit(true, false, false, false, address(swap));
        emit QuoteEpochBumped(1);

        vm.prank(admin);
        swap.bumpQuoteEpoch();
        assertEq(swap.quoteEpoch(), 1);
    }

    function test_bumpQuoteEpoch_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.bumpQuoteEpoch();
    }

    /// Quotes signed for the NEW epoch execute fine after a bump.
    function test_executeSwap_newEpochQuote_succeedsAfterBump() public {
        vm.prank(admin);
        swap.bumpQuoteEpoch();

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(18);
        m.epoch = 1;
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(18));
    }

    // ── Band-param admin ────────────────────────────────────────────────────────

    function test_setMaxQuoteDeviationBps_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.setMaxQuoteDeviationBps(300);
    }

    /// GYL-1135: the bound is MAX_QUOTE_DEVIATION_BPS_CEILING (1000 bps), NOT
    /// BPS_DENOMINATOR. 10_001 was always rejected; 10_000 (±100%, i.e. no band at all)
    /// and everything else above the ceiling now is too.
    function test_setMaxQuoteDeviationBps_aboveCeiling_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, uint16(10_001)));
        swap.setMaxQuoteDeviationBps(10_001);

        // The old permitted maximum — a ±100% band — is no longer settable.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, uint16(10_000)));
        swap.setMaxQuoteDeviationBps(10_000);

        // One basis point past the ceiling.
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidDeviationBps.selector, uint16(1001)));
        swap.setMaxQuoteDeviationBps(1001);

        assertEq(swap.maxQuoteDeviationBps(), MAX_BPS, "rejected setters must not move the band");
    }

    /// GYL-1135: setMaxQuoteTtl previously had no validation at all.
    function test_setMaxQuoteTtl_aboveCeiling_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteTtl.selector, uint64(1 hours + 1)));
        swap.setMaxQuoteTtl(1 hours + 1);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteTtl.selector, type(uint64).max));
        swap.setMaxQuoteTtl(type(uint64).max);

        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL(), "rejected setters must not move the TTL");
    }

    function test_setMaxNavAgeSecs_zero_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidNavAge.selector, uint32(0)));
        swap.setMaxNavAgeSecs(0);
    }

    /// initialize deliberately does NOT seed maxQuoteTtl (F-4): the storage slot stays
    /// zero and the effective cap comes from the DEFAULT_MAX_QUOTE_TTL fallback. That is
    /// what keeps a proxy upgraded across the field's addition working — see
    /// GyldAtomicSwap.upgrade.t.sol. The getter reports the effective value.
    function test_initialize_leavesTtlSlotUnsetAndFallsBackToDefault() public view {
        assertEq(swap.maxQuoteTtl(), 15 minutes);
        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL());
    }

    function test_setMaxQuoteTtl_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.setMaxQuoteTtl(2 hours);
    }

    function test_setMaxQuoteTtl_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true, address(swap));
        emit MaxQuoteTtlUpdated(5 minutes);
        vm.prank(admin);
        swap.setMaxQuoteTtl(5 minutes);
        assertEq(swap.maxQuoteTtl(), 5 minutes);

        // A 10-minute quote was legal under the 15-minute default but is now too far out.
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(72);
        m.expiry = uint64(block.timestamp + 10 minutes);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.QuoteExpiryTooFar.selector, m.expiry, uint64(block.timestamp + 5 minutes)
            )
        );
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    /// Zero is the UNSET sentinel, not "zero seconds" — passing it resets the cap to the
    /// compiled-in default rather than pinning expiry to the current block. This is the
    /// property that makes an un-migrated upgrade safe; if it ever regresses to literal
    /// zero-seconds, every real quote reverts QuoteExpiryTooFar.
    function test_setMaxQuoteTtl_zeroResetsToDefaultRatherThanBricking() public {
        vm.prank(admin);
        swap.setMaxQuoteTtl(5 minutes);
        assertEq(swap.maxQuoteTtl(), 5 minutes);

        vm.prank(admin);
        swap.setMaxQuoteTtl(0);
        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL(), "zero must fall back, not disable");

        // And a normal quote still settles at the restored default.
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(73);
        m.expiry = uint64(block.timestamp + 10 minutes);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(73));
    }

    function test_initialize_zeroUsdc_reverts() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        vm.expectRevert(GyldAtomicSwap.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(0), MAX_BPS, MAX_NAV_AGE)
            )
        );
    }

    /// F-1: initialize probes the cash token's decimals on-chain — an 18-decimal
    /// "USDC" (the bond token standing in) must be rejected before any state is set.
    function test_initialize_wrongDecimalsUsdc_reverts() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidTokenDecimals.selector, address(token), uint8(18)));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, address(token), MAX_BPS, MAX_NAV_AGE)
            )
        );
    }

    /// F-1, the other half of the initialize probe: a cash token with NO usable
    /// `decimals()` at all. `registerSeries` covers this for the bond leg
    /// (test_registerSeries_tokenWithoutDecimals_reverts); this pins the initialize leg,
    /// which matters more because `usdc` has NO SETTER — a bad cash token bricks the proxy
    /// permanently, recoverable only by upgrading in a setter that does not exist. The
    /// probe reports decimals 0 to mean "no answer", distinct from a token that genuinely
    /// answers 0.
    function test_initialize_cashTokenWithoutDecimals_reverts() public {
        // An EOA: the staticcall succeeds with empty returndata, so length != 32.
        address eoa = address(0xDECAF);
        GyldAtomicSwap impl = new GyldAtomicSwap();
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidTokenDecimals.selector, eoa, uint8(0)));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldAtomicSwap.initialize, (admin, pauser, signer, treasurer, eoa, MAX_BPS, MAX_NAV_AGE))
        );
    }

    /// The swap half of the cross-contract decimals invariant (F-1). The probes in
    /// registerSeries/initialize enforce this at admission time, but that only helps if the
    /// three values the /1e20 divisor is built from are the ones actually deployed. Assert
    /// the live wiring, not just the rejection paths: 18 (bond) + 8 (NAV) - 6 (cash) = 20.
    /// GyldBondToken.t.sol carries the matching assertion on the token side — if either
    /// contract's precision moves, one of the two fails and names the divisor.
    function test_decimalsLadder_matchesHardcodedDivisor() public view {
        assertEq(token.decimals(), 18, "bond leg");
        assertEq(navFeed.decimals(), 8, "NAV leg");
        assertEq(usdc.decimals(), 6, "cash leg");

        // The exponent the divisor encodes, derived rather than restated.
        uint256 exponent = uint256(token.decimals()) + uint256(navFeed.decimals()) - uint256(usdc.decimals());
        assertEq(10 ** exponent, 1e20, "_checkQuoteBand's /1e20 no longer matches the deployed decimals");
    }

    // ── Reentrancy ──────────────────────────────────────────────────────────────

    /// A malicious series token that re-enters executeSwap inside its transfer hook
    /// (the swap → taker push) must trip the nonReentrant guard and revert the whole tx.
    function test_executeSwap_reentrancy_reverts() public {
        // Deploy a malicious ERC-20 posing as a bond series, with its own NAV forwarder.
        MockReentrantToken evil = new MockReentrantToken();
        MockNavForwarder evilFeed = new MockNavForwarder(NAV);
        vm.prank(admin);
        swap.registerSeries(address(evil), address(evilFeed));

        // Seed the swap with EVIL inventory + fund the taker with USDC.
        evil.mint(address(swap), 1_000e18);
        // taker already has USDC from setUp; allowlist already includes taker.

        // A valid BUY quote: USDC in, EVIL out at NAV (10 EVIL per 1_000 USDC).
        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: 60,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: 1_000e6,
            tokenOut: address(evil),
            price: 1e28, // 10e18 EVIL per 1_000e6 USDC
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
        bytes memory sig = _sign(m, SIGNER_PK);

        // Arm the re-entrancy: when EVIL is pushed to the taker, its hook re-enters
        // executeSwap. Build the ISwapReentryTarget message mirror.
        ISwapReentryTarget.SwapMessage memory rm = ISwapReentryTarget.SwapMessage({
            quoteId: m.quoteId,
            taker: m.taker,
            tokenIn: m.tokenIn,
            maxAmountIn: m.maxAmountIn,
            tokenOut: m.tokenOut,
            price: m.price,
            expiry: m.expiry,
            epoch: m.epoch
        });
        evil.armExecuteSwap(address(swap), rm, sig, m.maxAmountIn);

        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ── renounceRole guard ────────────────────────────────────────────────────

    function test_renounceRole_defaultAdmin_reverts() public {
        // Cache role bytes before pranking — getter call would consume the prank.
        bytes32 adminRole = swap.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(GyldAtomicSwap.CannotRenounceAdminRole.selector);
        swap.renounceRole(adminRole, admin);
    }

    /// DEFAULT_ADMIN_ROLE is the ONLY non-renounceable role. The incident-response pair
    /// stays renounceable on purpose (F-7 was considered and rejected): a holder who knows
    /// their key is compromised must be able to shed the role immediately rather than wait
    /// on a timelocked revokeRole. Renouncing is not a loss of capability — the admin
    /// re-grants in one transaction, asserted below.
    function test_renounceRole_pauser_succeedsAndIsRegrantable() public {
        bytes32 pauserRole = swap.PAUSER_ROLE();
        vm.prank(pauser);
        swap.renounceRole(pauserRole, pauser);
        assertFalse(swap.hasRole(pauserRole, pauser), "a holder must be able to shed a hot role");

        // Nothing is stranded: DEFAULT_ADMIN_ROLE administers every role.
        vm.prank(admin);
        swap.grantRole(pauserRole, pauser);
        assertTrue(swap.hasRole(pauserRole, pauser), "admin must be able to re-grant");
    }

    function test_renounceRole_treasurer_succeedsAndIsRegrantable() public {
        bytes32 treasurerRole = swap.TREASURER_ROLE();
        vm.prank(treasurer);
        swap.renounceRole(treasurerRole, treasurer);
        assertFalse(swap.hasRole(treasurerRole, treasurer));

        vm.prank(admin);
        swap.grantRole(treasurerRole, treasurer);
        assertTrue(swap.hasRole(treasurerRole, treasurer));
    }

    /// The property that made F-7 unnecessary, pinned directly: renounceRole can only ever
    /// affect the caller, so there is no accidental or third-party path into it.
    function test_renounceRole_cannotRenounceSomeoneElsesRole() public {
        bytes32 pauserRole = swap.PAUSER_ROLE();
        vm.prank(outsider);
        vm.expectRevert();
        swap.renounceRole(pauserRole, pauser);
        assertTrue(swap.hasRole(pauserRole, pauser), "a third party must not be able to strip a role");
    }

    function test_renounceRole_quoteSigner_succeeds() public {
        bytes32 signerRole = swap.QUOTE_SIGNER_ROLE();
        vm.prank(signer);
        swap.renounceRole(signerRole, signer);
        assertFalse(swap.hasRole(signerRole, signer));
    }

    // ── M2: EIP-712 typehash / domain regression ──────────────────────────────

    /// The hardcoded SWAP_MESSAGE_TYPEHASH literal must exactly equal keccak256 of
    /// the canonical EIP-712 type string. Any struct field add/remove/reorder/rename
    /// silently changes this hash and breaks every off-chain signature — this test
    /// fails loudly the moment that happens.
    function test_swapMessageTypehash_matchesCanonicalString() public view {
        bytes32 expected = keccak256(
            bytes(
                "SwapMessage(uint256 quoteId,address taker,address tokenIn,uint256 maxAmountIn,address tokenOut,uint256 price,uint64 expiry,uint64 epoch)"
            )
        );
        assertEq(swap.SWAP_MESSAGE_TYPEHASH(), expected, "SWAP_MESSAGE_TYPEHASH drifted from canonical type string");
    }

    /// Cross-check hashSwapMessage against a hand-built _hashTypedDataV4 equivalent:
    /// reconstruct the domain separator from name "GyldAtomicSwap" / version "2" (bumped
    /// for the capped-allowance breaking wire change) and the struct hash from the
    /// canonical typehash, then assert the contract produces the identical digest the
    /// off-chain signer would. Guards both the typehash AND the EIP-712 domain
    /// (name/version/chainId/verifyingContract).
    function test_hashSwapMessage_matchesHandBuiltDigest() public view {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(100);

        bytes32 EIP712_DOMAIN_TYPEHASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("GyldAtomicSwap")),
                keccak256(bytes("2")),
                block.chainid,
                address(swap)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                swap.SWAP_MESSAGE_TYPEHASH(),
                m.quoteId,
                m.taker,
                m.tokenIn,
                m.maxAmountIn,
                m.tokenOut,
                m.price,
                m.expiry,
                m.epoch
            )
        );
        bytes32 expectedDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        assertEq(swap.hashSwapMessage(m), expectedDigest, "hashSwapMessage diverged from EIP-712 hand-built digest");
    }

    // ── N2: signature malleability / malformed signature ──────────────────────

    /// A valid signature has an ECDSA-counterpart (s' = n - s, v flipped) recovering
    /// the SAME signer. OZ's ECDSA.recover rejects high-s to prevent malleability —
    /// the malleated variant must revert with ECDSAInvalidSignatureS, never execute.
    function test_executeSwap_highSMalleableSignature_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(20);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, swap.hashSwapMessage(m));

        // secp256k1 order n.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(r, highS, flippedV);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureS(bytes32)", highS));
        swap.executeSwap(m, malleable, _noPermit(), m.maxAmountIn);
    }

    /// A zero-length signature is malformed — ECDSA.recover rejects the bad length.
    function test_executeSwap_zeroLengthSignature_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(21);
        bytes memory empty = "";

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", uint256(0)));
        swap.executeSwap(m, empty, _noPermit(), m.maxAmountIn);
    }

    /// A wrong-length (64-byte, truncated) signature is malformed and rejected.
    function test_executeSwap_wrongLengthSignature_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(22);
        (, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, swap.hashSwapMessage(m));
        bytes memory truncated = abi.encodePacked(r, s); // 64 bytes, missing v

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", uint256(64)));
        swap.executeSwap(m, truncated, _noPermit(), m.maxAmountIn);
    }

    /// A well-formed signature from a key that does NOT hold QUOTE_SIGNER_ROLE
    /// recovers a real-but-unauthorized address → InvalidQuoteSigner(recovered).
    function test_executeSwap_nonSignerRoleKey_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(23);
        uint256 strangerPk = 0xC0FFEE;
        bytes memory sig = _sign(m, strangerPk);

        assertFalse(swap.hasRole(swap.QUOTE_SIGNER_ROLE(), vm.addr(strangerPk)));

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteSigner.selector, vm.addr(strangerPk)));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ── Upgrade safety for the appended maxQuoteTtl slot (F-4) ────────────────
    //
    // maxQuoteTtl is an APPEND-ONLY ERC-7201 field added after the first deployments
    // (there is a live pre-F-4 proxy on Sepolia). A proxy upgraded onto this
    // implementation never re-runs `initialize`, so that slot has never been written and
    // reads ZERO. An earlier revision of this change seeded the field in `initialize`
    // and read it raw in executeSwap, which meant the upgraded proxy enforced
    // `expiry <= block.timestamp + 0` — directly contradicting the `block.timestamp >
    // m.expiry` check one line above it. Every quote a real service can issue reverted
    // QuoteExpiryTooFar; the only satisfiable expiry was exactly the inclusion block's
    // timestamp, which no service can target. That is a total executeSwap outage whose
    // only remedy, setMaxQuoteTtl, sits behind the 48h production timelock.
    //
    // The fix is that the field is read through `_effectiveMaxQuoteTtl`, which treats an
    // unset slot as "use DEFAULT_MAX_QUOTE_TTL". These tests pin that, because the
    // scenario had NO coverage before — every other test deploys fresh.

    /// Zeroing the slot IS the un-migrated-upgrade state, so write it directly and prove
    /// a normal quote still settles. This assertion is what the seed-based design failed.
    function test_upgrade_unsetTtlSlot_stillSettlesNormalQuotes() public {
        // erc7201:gyld.GyldAtomicSwap base; maxQuoteTtl is the appended field at B+8.
        bytes32 base = 0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300;
        bytes32 slot = bytes32(uint256(base) + 8);
        vm.store(address(swap), slot, bytes32(0));
        assertEq(uint256(vm.load(address(swap), slot)), 0, "precondition: slot unset");

        // The getter reports the fallback, not zero.
        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL());

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(901);
        m.expiry = uint64(block.timestamp + 10 minutes);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 2_000e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
        assertTrue(swap.isQuoteUsed(901), "an unset TTL slot must not brick executeSwap");

        // The cap is still enforced at the fallback value, not disabled.
        GyldAtomicSwap.SwapMessage memory tooFar = _buyQuote(902);
        tooFar.expiry = uint64(block.timestamp + 15 minutes + 1);
        bytes memory farSig = _sign(tooFar, SIGNER_PK);
        vm.prank(taker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldAtomicSwap.QuoteExpiryTooFar.selector, tooFar.expiry, uint64(block.timestamp + 15 minutes)
            )
        );
        swap.executeSwap(tooFar, farSig, _noPermit(), tooFar.maxAmountIn);
    }

    /// A real UUPS round-trip with NO initializer call in the upgrade, which is how an
    /// existing proxy is actually migrated. Storage survives; the TTL guard still works.
    function test_upgrade_withoutReinitializer_preservesStateAndTtlGuard() public {
        // Settle one swap pre-upgrade so there is real state to preserve.
        GyldAtomicSwap.SwapMessage memory before_ = _buyQuote(903);
        bytes memory beforeSig = _sign(before_, SIGNER_PK);
        vm.prank(taker);
        usdc.approve(address(swap), 2_000e6);
        vm.prank(taker);
        swap.executeSwap(before_, beforeSig, _noPermit(), before_.maxAmountIn);

        GyldAtomicSwap newImpl = new GyldAtomicSwap();
        vm.prank(admin);
        swap.upgradeToAndCall(address(newImpl), ""); // empty calldata: no initializer

        // Pre-upgrade state intact.
        assertTrue(swap.isQuoteUsed(903), "quoteId bitmap must survive the upgrade");
        assertEq(swap.maxQuoteDeviationBps(), MAX_BPS);
        assertEq(swap.maxNavAgeSecs(), MAX_NAV_AGE);
        assertTrue(swap.registeredSeries(address(token)));
        assertTrue(swap.isAllowed(taker));

        // And the TTL guard is live at the fallback rather than bricked at zero.
        assertEq(swap.maxQuoteTtl(), swap.DEFAULT_MAX_QUOTE_TTL());
        GyldAtomicSwap.SwapMessage memory after_ = _buyQuote(904);
        after_.expiry = uint64(block.timestamp + 10 minutes);
        bytes memory afterSig = _sign(after_, SIGNER_PK);
        vm.prank(taker);
        swap.executeSwap(after_, afterSig, _noPermit(), after_.maxAmountIn);
        assertTrue(swap.isQuoteUsed(904), "executeSwap must work after an un-migrated upgrade");
    }

    /// An admin-set TTL survives an upgrade — the fallback must not clobber a real value.
    function test_upgrade_preservesAdminSetTtl() public {
        vm.prank(admin);
        swap.setMaxQuoteTtl(5 minutes);

        GyldAtomicSwap newImpl = new GyldAtomicSwap();
        vm.prank(admin);
        swap.upgradeToAndCall(address(newImpl), "");

        assertEq(swap.maxQuoteTtl(), 5 minutes, "a configured TTL must survive the upgrade");
    }
}
