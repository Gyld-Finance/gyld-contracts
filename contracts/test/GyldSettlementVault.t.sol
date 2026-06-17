// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldSettlementVault} from "../GyldSettlementVault.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockNavForwarder} from "./MockNavForwarder.sol";
import {MockReentrantToken, ISwapReentryTarget} from "./MockReentrantToken.sol";

contract GyldSettlementVaultTest is Test {
    // Mirror events for vm.expectEmit (test pragma predates ContractName.Event syntax)
    event SwapServed(
        address indexed taker, address indexed tokenIn, uint256 amountIn, address indexed tokenOut, uint256 amountOut
    );
    event Deposited(address indexed lp, uint256 usdcAmount, uint256 shares);
    event Withdrawn(address indexed lp, uint256 shares, uint256 usdcAmount);
    event ReplenishmentDrawn(address indexed token, uint256 usdcAmount);
    event ReplenishmentSettled(address indexed token, uint256 usdcValue);
    event ForwardedForBurn(address indexed token, uint256 tokenAmount, uint256 usdcValue);
    event UsdcRepaid(address indexed token, uint256 usdcAmount);
    event SeriesRegistered(address indexed token, address indexed navForwarder);
    event SeriesDeregistered(address indexed token);
    event SwapUpdated(address indexed previousSwap, address indexed newSwap);

    GyldSettlementVault vault;
    GyldBondToken       token;
    MockUSDC            usdc;
    MockNavForwarder    navFeed;
    MockSanctionsList   mockSanctions;

    address admin       = address(0xA0); // DEFAULT_ADMIN_ROLE
    address pauser      = address(0xA1); // PAUSER_ROLE
    address treasurer   = address(0xA2); // TREASURER_ROLE
    address lp          = address(0xB0); // LP_ROLE
    address attacker    = address(0xB1); // LP_ROLE — first-depositor attack test
    address swapCaller  = address(0xC0); // SWAP_ROLE (granted directly, stands in for the swap proxy)
    address takerAddr   = address(0xD0); // end user receiving onSwap pushes
    address issuanceMgr = address(0x1111); // burn-commitment destination (plain address)
    address outsider    = address(0xFF);

    // NAV $100.00 per token (8dp): 1e18 token ⇔ 100e6 USDC.
    // Default band is 200 bps → 10 tokens (nav value 1_000e6) accept 980e6..1_020e6.
    int256 constant NAV = 100e8;

    function setUp() public {
        vm.warp(1_750_000_000);
        mockSanctions = new MockSanctionsList();
        usdc          = new MockUSDC();
        navFeed       = new MockNavForwarder(NAV);

        // ── GyldBondToken proxy ───────────────────────────────────────────────
        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(address(new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Gyld US Treasury Bond 2026-06",
                "GYLD-UST-2606",
                "US912797KR72",
                1_780_000_000,
                admin,
                pauser,
                address(mockSanctions)
            ))
        )));

        // ── GyldSettlementVault proxy ─────────────────────────────────────────
        GyldSettlementVault vaultImpl = new GyldSettlementVault();
        vault = GyldSettlementVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(GyldSettlementVault.initialize, (
                admin, pauser, treasurer, address(usdc), issuanceMgr
            ))
        )));

        // Roles + series wiring. SWAP_ROLE is granted to a test harness address
        // directly (grantRole, not setSwap) so onSwap can be driven standalone.
        bytes32 lpRole   = vault.LP_ROLE();
        bytes32 swapRole = vault.SWAP_ROLE();
        vm.startPrank(admin);
        vault.grantRole(lpRole, lp);
        vault.grantRole(lpRole, attacker);
        vault.grantRole(swapRole, swapCaller);
        vault.registerSeries(address(token), address(navFeed));
        vm.stopPrank();

        // Direct mint stands in for the IssuanceManager.subscribe mint-at-fill path.
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin); token.grantRole(minterRole, address(this));

        usdc.mint(lp, 1_000_000e6);
        usdc.mint(attacker, 2_000_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        shares = vault.deposit(amount);
        vm.stopPrank();
    }

    // ── Deposit / withdraw share math ─────────────────────────────────────────

    /// First deposit into an empty vault mints shares at the virtual-offset ratio
    /// (1_000 shares per USDC unit) — the OZ decimal-offset anti-inflation shape.
    function test_deposit_firstDeposit_virtualOffsetRatio() public {
        vm.startPrank(lp);
        usdc.approve(address(vault), 1_000e6);

        vm.expectEmit(true, false, false, true, address(vault));
        emit Deposited(lp, 1_000e6, 1_000e6 * 1_000);

        uint256 shares = vault.deposit(1_000e6);
        vm.stopPrank();
        assertEq(shares, 1_000e6 * 1_000, "first-deposit shares != assets * virtual offset");
        assertEq(vault.balanceOf(lp), shares);
        assertEq(vault.totalAssets(), 1_000e6);
    }

    function test_withdraw_fullRoundTrip_returnsDeposit() public {
        uint256 shares = _deposit(lp, 1_000e6);

        vm.prank(lp);
        uint256 out = vault.withdraw(shares);

        // Virtual offset costs at most 1 unit of rounding.
        assertApproxEqAbs(out, 1_000e6, 1, "round trip lost more than rounding");
        assertEq(vault.balanceOf(lp), 0);
    }

    /// Two LPs at the same share price get proportional shares.
    function test_deposit_secondDepositor_proportionalShares() public {
        uint256 s1 = _deposit(lp, 1_000e6);
        uint256 s2 = _deposit(attacker, 2_000e6);
        assertApproxEqAbs(s2, s1 * 2, 1_000, "second depositor shares not proportional");
    }

    /// Classic first-depositor inflation attack: deposit dust, donate big, hope the
    /// victim's deposit rounds to zero shares. With virtual offsets the victim gets
    /// shares and the attacker exits at a LOSS — the attack must be unprofitable.
    function test_firstDepositorAttack_isUnprofitable() public {
        // Attacker deposits 1 unit (1e-6 USDC) then donates 1M USDC directly.
        uint256 attackerShares = _deposit(attacker, 1);
        assertEq(attackerShares, 1_000); // 1 * virtual offset

        vm.prank(attacker);
        usdc.transfer(address(vault), 1_000_000e6); // donation — no shares minted

        // Victim deposits — must NOT round to zero shares.
        uint256 victimShares = _deposit(lp, 1_000e6);
        assertGt(victimShares, 0, "victim deposit rounded to zero shares");

        // Attacker exits with everything they can — strictly less than they put in.
        vm.prank(attacker);
        uint256 attackerOut = vault.withdraw(attackerShares);
        assertLt(attackerOut, 1 + 1_000_000e6, "first-depositor attack turned a profit");

        // And the victim can still exit with a nonzero payout.
        vm.prank(lp);
        uint256 victimOut = vault.withdraw(victimShares);
        assertGt(victimOut, 0, "victim got nothing back");
    }

    function test_deposit_zeroAmount_reverts() public {
        vm.prank(lp);
        vm.expectRevert(GyldSettlementVault.ZeroAmount.selector);
        vault.deposit(0);
    }

    function test_withdraw_zeroShares_reverts() public {
        vm.prank(lp);
        vm.expectRevert(GyldSettlementVault.ZeroAmount.selector);
        vault.withdraw(0);
    }

    function test_deposit_onlyLpRole_reverts() public {
        usdc.mint(outsider, 100e6);
        vm.startPrank(outsider);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert();
        vault.deposit(100e6);
        vm.stopPrank();
    }

    function test_withdraw_onlyLpRole_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.withdraw(1);
    }

    /// withdraw must revert ONLY on a free-USDC shortage — and a smaller withdrawal
    /// that fits in free USDC still succeeds while liquidity is deployed.
    function test_withdraw_freeUsdcShortage_revertsButPartialSucceeds() public {
        _deposit(lp, 10_000e6);

        // Treasurer deploys most of the liquidity: free USDC drops to 500e6,
        // totalAssets stays 10_000e6 (receivable replaces cash).
        vm.prank(treasurer);
        vault.drawForReplenishment(address(token), 9_500e6);
        assertEq(vault.totalAssets(), 10_000e6);

        // Full exit (worth 10_000e6) cannot be covered by 500e6 free USDC.
        uint256 allShares = vault.balanceOf(lp);
        vm.prank(lp);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.InsufficientUsdcLiquidity.selector, 10_000e6, 500e6)
        );
        vault.withdraw(allShares);

        // A 400e6-worth exit fits in free USDC and succeeds.
        uint256 partialShares = (allShares * 400e6) / 10_000e6;
        vm.prank(lp);
        uint256 out = vault.withdraw(partialShares);
        assertApproxEqAbs(out, 400e6, 1);
    }

    // ── onSwap: access + happy paths ──────────────────────────────────────────

    function test_onSwap_onlySwapRole_reverts() public {
        token.mint(address(vault), 10e18);
        vm.prank(outsider);
        vm.expectRevert();
        vault.onSwap(takerAddr, address(usdc), 1_000e6, address(token), 10e18);
    }

    function test_onSwap_buy_pushesInventoryToTaker() public {
        token.mint(address(vault), 100e18);

        vm.expectEmit(true, true, true, true, address(vault));
        emit SwapServed(takerAddr, address(usdc), 1_000e6, address(token), 10e18);

        vm.prank(swapCaller);
        vault.onSwap(takerAddr, address(usdc), 1_000e6, address(token), 10e18);

        assertEq(token.balanceOf(takerAddr), 10e18, "tokens not pushed to taker");
        assertEq(token.balanceOf(address(vault)), 90e18);
    }

    function test_onSwap_redeem_pushesUsdcToTaker() public {
        _deposit(lp, 10_000e6);

        vm.prank(swapCaller);
        vault.onSwap(takerAddr, address(token), 10e18, address(usdc), 1_000e6);

        assertEq(usdc.balanceOf(takerAddr), 1_000e6, "USDC not pushed to taker");
        assertEq(usdc.balanceOf(address(vault)), 9_000e6);
    }

    // ── onSwap: NAV sanity band ───────────────────────────────────────────────

    /// Quote ABOVE the band (buy leg): 10 tokens (nav 1_000e6) quoted at 1_025e6.
    function test_onSwap_buy_quoteAboveBand_reverts() public {
        token.mint(address(vault), 100e18);
        vm.prank(swapCaller);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.QuotePriceOutOfBand.selector, 1_025e6, 1_000e6)
        );
        vault.onSwap(takerAddr, address(usdc), 1_025e6, address(token), 10e18);
    }

    /// Quote BELOW the band (redeem leg): 10 tokens quoted at 975e6.
    function test_onSwap_redeem_quoteBelowBand_reverts() public {
        _deposit(lp, 10_000e6);
        vm.prank(swapCaller);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.QuotePriceOutOfBand.selector, 975e6, 1_000e6)
        );
        vault.onSwap(takerAddr, address(token), 10e18, address(usdc), 975e6);
    }

    /// Quotes exactly ON the band edge (±2%) are accepted on both sides.
    function test_onSwap_bandEdges_accepted() public {
        token.mint(address(vault), 100e18);
        _deposit(lp, 10_000e6);

        vm.prank(swapCaller);
        vault.onSwap(takerAddr, address(usdc), 1_020e6, address(token), 10e18); // nav + band

        vm.prank(swapCaller);
        vault.onSwap(takerAddr, address(token), 10e18, address(usdc), 980e6); // nav - band

        assertEq(token.balanceOf(takerAddr), 10e18);
        assertEq(usdc.balanceOf(takerAddr), 980e6);
    }

    function test_onSwap_neitherLegBond_reverts() public {
        vm.prank(swapCaller);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.NotOneBondLeg.selector, address(usdc), address(usdc))
        );
        vault.onSwap(takerAddr, address(usdc), 1_000e6, address(usdc), 1_000e6);
    }

    function test_onSwap_bothLegsBond_reverts() public {
        vm.prank(swapCaller);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.NotOneBondLeg.selector, address(token), address(token))
        );
        vault.onSwap(takerAddr, address(token), 10e18, address(token), 10e18);
    }

    function test_onSwap_unregisteredSeries_reverts() public {
        address unregistered = address(new MockUSDC()); // an ERC20 that is not a registered series
        vm.prank(swapCaller);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.NotOneBondLeg.selector, address(usdc), unregistered)
        );
        vault.onSwap(takerAddr, address(usdc), 1_000e6, unregistered, 10e18);
    }

    // ── onSwap: liquidity shortfalls ──────────────────────────────────────────

    function test_onSwap_insufficientInventory_reverts() public {
        token.mint(address(vault), 5e18); // less than the 10e18 requested

        vm.prank(swapCaller);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.InsufficientInventory.selector, address(token), 10e18, 5e18)
        );
        vault.onSwap(takerAddr, address(usdc), 1_000e6, address(token), 10e18);
    }

    function test_onSwap_insufficientUsdcLiquidity_reverts() public {
        // Vault holds no USDC at all.
        vm.prank(swapCaller);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.InsufficientUsdcLiquidity.selector, 1_000e6, 0)
        );
        vault.onSwap(takerAddr, address(token), 10e18, address(usdc), 1_000e6);
    }

    function test_onSwap_whenPaused_reverts() public {
        token.mint(address(vault), 100e18);
        vm.prank(pauser);
        vault.pause();

        vm.prank(swapCaller);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.onSwap(takerAddr, address(usdc), 1_000e6, address(token), 10e18);
    }

    // ── Treasurer bridge lifecycle: totalAssets conservation ─────────────────

    /// Full draw → mint-at-fill → settle → forwardForBurn → repay cycle, with
    /// totalAssets asserted at EVERY step. Receivables exactly offset cash/tokens
    /// in flight, so LP share price never dips mid-bridge.
    function test_treasurerLifecycle_totalAssetsConserved() public {
        _deposit(lp, 10_000e6);
        assertEq(vault.totalAssets(), 10_000e6);

        // 1. Draw 4_000e6 to fund a broker buy: USDC out, receivable in.
        vm.expectEmit(true, false, false, true, address(vault));
        emit ReplenishmentDrawn(address(token), 4_000e6);
        vm.prank(treasurer);
        vault.drawForReplenishment(address(token), 4_000e6);

        assertEq(usdc.balanceOf(treasurer), 4_000e6);
        (uint256 repl, uint256 buyback) = vault.obligationsOf(address(token));
        assertEq(repl, 4_000e6);
        assertEq(buyback, 0);
        assertEq(vault.totalAssets(), 10_000e6, "draw moved totalAssets");

        // 2. Subscribe-minted fills land (40 tokens @ $100 = 4_000e6). Inventory
        //    and the still-open receivable transiently coexist.
        token.mint(address(vault), 40e18);
        assertEq(vault.inventoryValue(address(token)), 4_000e6);
        assertEq(vault.totalAssets(), 14_000e6, "fill not valued");

        // 3. Settle: receivable written down as the inventory replaces it.
        vm.expectEmit(true, false, false, true, address(vault));
        emit ReplenishmentSettled(address(token), 4_000e6);
        vm.prank(treasurer);
        vault.settleReplenishment(address(token), 4_000e6);

        (repl,) = vault.obligationsOf(address(token));
        assertEq(repl, 0);
        assertEq(vault.totalAssets(), 10_000e6, "settle moved totalAssets");

        // 4. Forward the inventory for burn: tokens out, buyback receivable in.
        vm.expectEmit(true, false, false, true, address(vault));
        emit ForwardedForBurn(address(token), 40e18, 4_000e6);
        vm.prank(treasurer);
        vault.forwardForBurn(address(token), 40e18);

        assertEq(token.balanceOf(issuanceMgr), 40e18, "commitment not at IssuanceManager");
        assertEq(token.balanceOf(address(vault)), 0);
        (, buyback) = vault.obligationsOf(address(token));
        assertEq(buyback, 4_000e6);
        assertEq(vault.totalAssets(), 10_000e6, "forward moved totalAssets");

        // 5. Repay after the T+2 broker sale: USDC in, receivable out.
        vm.startPrank(treasurer);
        usdc.approve(address(vault), 4_000e6);
        vm.expectEmit(true, false, false, true, address(vault));
        emit UsdcRepaid(address(token), 4_000e6);
        vault.repayUsdc(address(token), 4_000e6);
        vm.stopPrank();

        (repl, buyback) = vault.obligationsOf(address(token));
        assertEq(repl, 0);
        assertEq(buyback, 0);
        assertEq(usdc.balanceOf(address(vault)), 10_000e6, "free USDC not restored");
        assertEq(vault.totalAssets(), 10_000e6, "repay moved totalAssets");

        // LP exits the whole position at par.
        uint256 shares = vault.balanceOf(lp);
        vm.prank(lp);
        uint256 out = vault.withdraw(shares);
        assertApproxEqAbs(out, 10_000e6, 1, "LP did not get full value back");
    }

    // ── Treasurer bridge: guards ──────────────────────────────────────────────

    function test_drawForReplenishment_unregisteredSeries_reverts() public {
        _deposit(lp, 10_000e6);
        vm.prank(treasurer);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.UnregisteredSeries.selector, address(0xDEAD)));
        vault.drawForReplenishment(address(0xDEAD), 1_000e6);
    }

    function test_drawForReplenishment_zeroAmount_reverts() public {
        vm.prank(treasurer);
        vm.expectRevert(GyldSettlementVault.ZeroAmount.selector);
        vault.drawForReplenishment(address(token), 0);
    }

    function test_drawForReplenishment_exceedsFreeUsdc_reverts() public {
        _deposit(lp, 1_000e6);
        vm.prank(treasurer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.InsufficientUsdcLiquidity.selector, 2_000e6, 1_000e6)
        );
        vault.drawForReplenishment(address(token), 2_000e6);
    }

    function test_drawForReplenishment_onlyTreasurer_reverts() public {
        _deposit(lp, 10_000e6);
        vm.prank(outsider);
        vm.expectRevert();
        vault.drawForReplenishment(address(token), 1_000e6);
    }

    function test_settleReplenishment_underflow_reverts() public {
        _deposit(lp, 10_000e6);
        vm.prank(treasurer);
        vault.drawForReplenishment(address(token), 1_000e6);

        vm.prank(treasurer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.ObligationUnderflow.selector, address(token), 1_001e6, 1_000e6)
        );
        vault.settleReplenishment(address(token), 1_001e6);
    }

    function test_settleReplenishment_partial_succeeds() public {
        _deposit(lp, 10_000e6);
        vm.prank(treasurer);
        vault.drawForReplenishment(address(token), 1_000e6);

        vm.prank(treasurer);
        vault.settleReplenishment(address(token), 400e6); // mint-at-fill streams fills

        (uint256 repl,) = vault.obligationsOf(address(token));
        assertEq(repl, 600e6);
    }

    function test_forwardForBurn_unregisteredSeries_reverts() public {
        vm.prank(treasurer);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.UnregisteredSeries.selector, address(0xDEAD)));
        vault.forwardForBurn(address(0xDEAD), 1e18);
    }

    function test_forwardForBurn_zeroAmount_reverts() public {
        vm.prank(treasurer);
        vm.expectRevert(GyldSettlementVault.ZeroAmount.selector);
        vault.forwardForBurn(address(token), 0);
    }

    function test_repayUsdc_underflow_reverts() public {
        // No buyback obligation outstanding at all.
        vm.prank(treasurer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.ObligationUnderflow.selector, address(token), 1e6, 0)
        );
        vault.repayUsdc(address(token), 1e6);
    }

    /// N8 — residual buyback receivable after a PARTIAL repay. forwardForBurn books
    /// buybackOwed at NAV; repayUsdc repays LESS than owed, leaving a residual. The
    /// residual must (a) be tracked exactly, (b) block deregisterSeries with
    /// SeriesNotEmpty, and (c) clear on a subsequent repay — documenting the
    /// by-design manual-reconcile behaviour (no auto-rollback).
    function test_repayUsdc_partialLeavesResidual_blocksDeregister_thenClears() public {
        _deposit(lp, 10_000e6);
        usdc.mint(treasurer, 4_000e6); // treasurer repays from T+2 broker-sale proceeds

        // Forward 40 tokens for burn → buybackOwed = 4_000e6 at $100 NAV.
        token.mint(address(vault), 40e18);
        vm.prank(treasurer);
        vault.forwardForBurn(address(token), 40e18);
        (, uint256 owed0) = vault.obligationsOf(address(token));
        assertEq(owed0, 4_000e6, "buyback not booked at NAV");
        assertEq(token.balanceOf(address(vault)), 0, "tokens not forwarded");

        // Partial repay: 1_500e6 of the 4_000e6 owed. Residual = 2_500e6.
        vm.startPrank(treasurer);
        usdc.approve(address(vault), 1_500e6);
        vault.repayUsdc(address(token), 1_500e6);
        vm.stopPrank();

        (, uint256 residual) = vault.obligationsOf(address(token));
        assertEq(residual, 2_500e6, "residual buyback not tracked correctly");
        // totalAssets unchanged by the repay itself: USDC in (+1_500e6) exactly
        // offsets the receivable shrinking (-1_500e6). The forwarded tokens' value
        // (4_000e6) now lives wholly in buybackOwed, so the pool stands at
        // 10_000e6 deposit + 4_000e6 outstanding buyback = 14_000e6.
        assertEq(vault.totalAssets(), 14_000e6, "partial repay moved totalAssets");

        // The residual blocks deregistration (would silently drop a live receivable).
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.SeriesNotEmpty.selector, address(token)));
        vault.deregisterSeries(address(token));

        // A repay above the residual still underflow-reverts (cannot over-repay).
        vm.startPrank(treasurer);
        usdc.approve(address(vault), 2_501e6);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.ObligationUnderflow.selector, address(token), 2_501e6, 2_500e6)
        );
        vault.repayUsdc(address(token), 2_501e6);
        vm.stopPrank();

        // A subsequent repay of the exact residual clears it.
        vm.startPrank(treasurer);
        usdc.approve(address(vault), 2_500e6);
        vault.repayUsdc(address(token), 2_500e6);
        vm.stopPrank();

        (, uint256 cleared) = vault.obligationsOf(address(token));
        assertEq(cleared, 0, "residual not cleared by final repay");

        // With the receivable cleared and no inventory, the series deregisters cleanly.
        vm.prank(admin);
        vault.deregisterSeries(address(token));
        assertFalse(vault.registeredSeries(address(token)));
    }

    /// Treasurer bridge functions are deliberately NOT pausable — receivables
    /// must be able to unwind during an incident.
    function test_treasurerBridge_worksWhilePaused() public {
        _deposit(lp, 10_000e6);
        vm.prank(pauser);
        vault.pause();

        vm.prank(treasurer);
        vault.drawForReplenishment(address(token), 1_000e6);
        (uint256 repl,) = vault.obligationsOf(address(token));
        assertEq(repl, 1_000e6);
    }

    // ── Valuation: InvalidNav fail-closed guard ───────────────────────────────

    function test_totalAssets_zeroNav_reverts() public {
        token.mint(address(vault), 10e18);
        navFeed.setAnswer(0);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.InvalidNav.selector, address(token), int256(0)));
        vault.totalAssets();
    }

    function test_totalAssets_negativeNav_reverts() public {
        token.mint(address(vault), 10e18);
        navFeed.setAnswer(-1);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.InvalidNav.selector, address(token), int256(-1)));
        vault.totalAssets();
    }

    function test_inventoryValue_unregistered_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.UnregisteredSeries.selector, address(0xDEAD)));
        vault.inventoryValue(address(0xDEAD));
    }

    // ── registerSeries probe ──────────────────────────────────────────────────

    function test_registerSeries_eoaForwarder_reverts() public {
        address eoa = address(0xEEEE);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.NotValidForwarder.selector, eoa));
        vault.registerSeries(address(token), eoa);
    }

    function test_registerSeries_wrongDecimalsForwarder_reverts() public {
        // decimals() == 6 — _navValueUsdc scaling assumes 8dp, must be rejected.
        address sixDecimals = address(new MockSixDecimalForwarder());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.NotValidForwarder.selector, sixDecimals));
        vault.registerSeries(address(token), sixDecimals);
    }

    function test_registerSeries_noDecimalsContract_reverts() public {
        address wrongContract = address(new MockUSDCNoDecimalsShim());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.NotValidForwarder.selector, wrongContract));
        vault.registerSeries(address(token), wrongContract);
    }

    function test_registerSeries_zeroAddress_reverts() public {
        vm.startPrank(admin);
        vm.expectRevert(GyldSettlementVault.ZeroAddress.selector);
        vault.registerSeries(address(0), address(navFeed));
        vm.expectRevert(GyldSettlementVault.ZeroAddress.selector);
        vault.registerSeries(address(token), address(0));
        vm.stopPrank();
    }

    function test_registerSeries_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.registerSeries(address(token), address(navFeed));
    }

    /// Re-registering an active series swaps the forwarder without duplicating it
    /// in the totalAssets iteration.
    function test_registerSeries_reRegister_updatesForwarderNoDoubleCount() public {
        token.mint(address(vault), 10e18); // worth 1_000e6 at $100

        MockNavForwarder newFeed = new MockNavForwarder(110e8); // $110
        vm.prank(admin);
        vault.registerSeries(address(token), address(newFeed));

        assertEq(vault.navForwarderOf(address(token)), address(newFeed));
        // 10 tokens at $110 — counted exactly once.
        assertEq(vault.totalAssets(), 1_100e6, "series double-counted after re-register");
    }

    // ── deregisterSeries ──────────────────────────────────────────────────────

    function test_deregisterSeries_withInventory_reverts() public {
        token.mint(address(vault), 1e18);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.SeriesNotEmpty.selector, address(token)));
        vault.deregisterSeries(address(token));
    }

    function test_deregisterSeries_withObligation_reverts() public {
        _deposit(lp, 10_000e6);
        vm.prank(treasurer);
        vault.drawForReplenishment(address(token), 1_000e6); // receivable, no inventory

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.SeriesNotEmpty.selector, address(token)));
        vault.deregisterSeries(address(token));
    }

    function test_deregisterSeries_empty_succeeds() public {
        vm.expectEmit(true, false, false, false, address(vault));
        emit SeriesDeregistered(address(token));

        vm.prank(admin);
        vault.deregisterSeries(address(token));

        assertFalse(vault.registeredSeries(address(token)));
        assertEq(vault.navForwarderOf(address(token)), address(0));
        // Dropped from valuation: a (now-unregistered) donation is not counted.
        token.mint(address(vault), 10e18);
        assertEq(vault.totalAssets(), 0);
    }

    function test_deregisterSeries_unregistered_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.UnregisteredSeries.selector, address(0xDEAD)));
        vault.deregisterSeries(address(0xDEAD));
    }

    // ── setSwap ───────────────────────────────────────────────────────────────

    function _deploySwap() internal returns (GyldAtomicSwap) {
        GyldAtomicSwap swapImpl = new GyldAtomicSwap();
        return GyldAtomicSwap(address(new ERC1967Proxy(
            address(swapImpl),
            abi.encodeCall(GyldAtomicSwap.initialize, (admin, pauser, address(0x51), address(vault)))
        )));
    }

    function test_setSwap_grantsAndRevokesSwapRoleAtomically() public {
        GyldAtomicSwap swap1 = _deploySwap();
        GyldAtomicSwap swap2 = _deploySwap();
        bytes32 swapRole = vault.SWAP_ROLE();

        vm.expectEmit(true, true, false, false, address(vault));
        emit SwapUpdated(address(0), address(swap1));
        vm.prank(admin);
        vault.setSwap(address(swap1));
        assertEq(vault.swap(), address(swap1));
        assertTrue(vault.hasRole(swapRole, address(swap1)));

        vm.prank(admin);
        vault.setSwap(address(swap2));
        assertFalse(vault.hasRole(swapRole, address(swap1)), "previous swap kept SWAP_ROLE");
        assertTrue(vault.hasRole(swapRole, address(swap2)));
        assertEq(vault.swap(), address(swap2));
    }

    function test_setSwap_eoa_reverts() public {
        address eoa = address(0xEEEE);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.NotValidSwap.selector, eoa));
        vault.setSwap(eoa);
    }

    function test_setSwap_wrongContract_reverts() public {
        address wrongContract = address(new MockUSDCNoDecimalsShim());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.NotValidSwap.selector, wrongContract));
        vault.setSwap(wrongContract);
    }

    function test_setSwap_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(GyldSettlementVault.ZeroAddress.selector);
        vault.setSwap(address(0));
    }

    function test_setSwap_onlyAdmin_reverts() public {
        GyldAtomicSwap swap1 = _deploySwap();
        vm.prank(outsider);
        vm.expectRevert();
        vault.setSwap(address(swap1));
    }

    // ── setMaxQuoteDeviationBps ───────────────────────────────────────────────

    function test_setMaxQuoteDeviationBps_overCap_reverts() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldSettlementVault.InvalidDeviationBps.selector, uint16(10_001)));
        vault.setMaxQuoteDeviationBps(10_001);
    }

    function test_setMaxQuoteDeviationBps_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        vault.setMaxQuoteDeviationBps(500);
    }

    /// Widening the band admits a quote the default band rejected.
    function test_setMaxQuoteDeviationBps_widensBand() public {
        token.mint(address(vault), 100e18);

        // 1_025e6 for 10 tokens is outside the default 200 bps band...
        vm.prank(swapCaller);
        vm.expectRevert(
            abi.encodeWithSelector(GyldSettlementVault.QuotePriceOutOfBand.selector, 1_025e6, 1_000e6)
        );
        vault.onSwap(takerAddr, address(usdc), 1_025e6, address(token), 10e18);

        vm.prank(admin);
        vault.setMaxQuoteDeviationBps(300); // 3% → max 1_030e6
        assertEq(vault.maxQuoteDeviationBps(), 300);

        vm.prank(swapCaller);
        vault.onSwap(takerAddr, address(usdc), 1_025e6, address(token), 10e18);
        assertEq(token.balanceOf(takerAddr), 10e18);
    }

    // ── Pause / roles ─────────────────────────────────────────────────────────

    function test_deposit_whenPaused_reverts() public {
        vm.prank(pauser);
        vault.pause();
        vm.startPrank(lp);
        usdc.approve(address(vault), 100e6);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        vault.deposit(100e6);
        vm.stopPrank();
    }

    /// Asymmetric pause: PAUSER halts but cannot resume; admin resumes.
    function test_pause_asymmetric_onlyAdminUnpauses() public {
        vm.prank(pauser);
        vault.pause();

        vm.prank(pauser);
        vm.expectRevert();
        vault.unpause();

        vm.prank(admin);
        vault.unpause();
        _deposit(lp, 100e6); // works again
        assertEq(vault.totalAssets(), 100e6);
    }

    function test_renounceRole_defaultAdmin_reverts() public {
        // Cache role bytes before pranking — getter call would consume the prank.
        bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(GyldSettlementVault.CannotRenounceAdminRole.selector);
        vault.renounceRole(adminRole, admin);
    }

    function test_renounceRole_lpRole_succeeds() public {
        bytes32 lpRole = vault.LP_ROLE();
        vm.prank(lp);
        vault.renounceRole(lpRole, lp);
        assertFalse(vault.hasRole(lpRole, lp));
    }

    // ── N5: reentrant-token guard ─────────────────────────────────────────────

    /// A malicious bond series whose transfer hook re-enters onSwap. The vault pushes
    /// tokenOut inside onSwap via safeTransfer; the token's _update then calls onSwap
    /// again — but the outer call is still mid-execution, so nonReentrant reverts.
    /// Because the re-entrant attempt lives inside the transfer hook, the revert
    /// bubbles up and reverts the WHOLE swap (no inventory escapes).
    function test_onSwap_reentrantTokenOnSwap_reverts() public {
        MockReentrantToken evil = new MockReentrantToken();
        MockNavForwarder evilFeed = new MockNavForwarder(NAV);
        vm.prank(admin);
        vault.registerSeries(address(evil), address(evilFeed));

        evil.mint(address(vault), 100e18); // vault inventory to push out on a buy

        // Arm the re-entry: when the vault transfers `evil` to the taker, the hook
        // re-enters onSwap with the same (valid-looking) buy args.
        evil.armOnSwap(address(vault), takerAddr, address(usdc), 1_000e6, address(evil), 10e18);

        vm.prank(swapCaller);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        vault.onSwap(takerAddr, address(usdc), 1_000e6, address(evil), 10e18);

        // Whole tx reverted: no inventory leaked, taker got nothing.
        assertEq(evil.balanceOf(takerAddr), 0, "reentrancy let inventory escape");
        assertEq(evil.balanceOf(address(vault)), 100e18, "vault inventory changed");
    }

    /// Same malicious series, but its hook re-enters the swap's executeSwap. The
    /// OUTER swap is fully valid and reaches the vault's safeTransfer push; the
    /// hook then re-enters executeSwap, which trips its OWN nonReentrant guard
    /// (it is still mid-execution). That revert bubbles out of the transfer and
    /// unwinds the entire outer swap — no inventory escapes.
    function test_executeSwap_reentrantTokenExecuteSwap_reverts() public {
        // Deploy a real swap whose QUOTE_SIGNER is a key we control, then wire it.
        uint256 signerPk = 0xC0FFEE;
        address signerAddr = vm.addr(signerPk);
        GyldAtomicSwap swapImpl = new GyldAtomicSwap();
        GyldAtomicSwap swapContract = GyldAtomicSwap(address(new ERC1967Proxy(
            address(swapImpl),
            abi.encodeCall(GyldAtomicSwap.initialize, (admin, pauser, signerAddr, address(vault)))
        )));
        vm.prank(admin);
        vault.setSwap(address(swapContract));

        MockReentrantToken evil = new MockReentrantToken();
        MockNavForwarder evilFeed = new MockNavForwarder(NAV);
        vm.prank(admin);
        vault.registerSeries(address(evil), address(evilFeed));
        evil.mint(address(vault), 100e18);

        // The re-entrant inner quote (distinct quoteId so it is not a replay; its
        // signature is valid so it reaches — and trips — the nonReentrant guard).
        ISwapReentryTarget.SwapMessage memory innerStruct = ISwapReentryTarget.SwapMessage({
            quoteId: 999,
            taker: takerAddr,
            tokenIn: address(usdc),
            amountIn: 1_000e6,
            tokenOut: address(evil),
            amountOut: 10e18,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
        GyldAtomicSwap.SwapMessage memory inner = GyldAtomicSwap.SwapMessage({
            quoteId: 999, taker: takerAddr, tokenIn: address(usdc), amountIn: 1_000e6,
            tokenOut: address(evil), amountOut: 10e18,
            expiry: uint64(block.timestamp + 15 minutes), epoch: 0
        });
        (uint8 iv, bytes32 ir, bytes32 is_) = vm.sign(signerPk, swapContract.hashSwapMessage(inner));
        evil.armExecuteSwap(address(swapContract), innerStruct, abi.encodePacked(ir, is_, iv));

        // Outer buy of `evil` — fully valid, reaches the vault push.
        GyldAtomicSwap.SwapMessage memory outer = GyldAtomicSwap.SwapMessage({
            quoteId: 1, taker: takerAddr, tokenIn: address(usdc), amountIn: 1_000e6,
            tokenOut: address(evil), amountOut: 10e18,
            expiry: uint64(block.timestamp + 15 minutes), epoch: 0
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, swapContract.hashSwapMessage(outer));
        bytes memory sig = abi.encodePacked(r, s, v);

        usdc.mint(takerAddr, 1_000e6);
        vm.prank(takerAddr);
        usdc.approve(address(swapContract), 1_000e6);

        // ReentrancyGuardReentrantCall from the re-entered executeSwap unwinds the tx.
        vm.prank(takerAddr);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        swapContract.executeSwap(outer, sig, _noPermit());

        assertEq(evil.balanceOf(takerAddr), 0, "reentrancy let inventory escape");
        assertEq(usdc.balanceOf(takerAddr), 1_000e6, "taker USDC moved despite revert");
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    // ── N6: share-math fuzz ───────────────────────────────────────────────────

    /// Round-trip safety: a withdraw immediately after a deposit of the same amount
    /// NEVER returns more than was deposited. Rounding must always favour the vault
    /// (value can only be lost to virtual-offset rounding, never extracted). Run
    /// across the full sensible deposit range.
    function testFuzz_depositWithdraw_roundTripNeverProfits(uint256 amount) public {
        amount = bound(amount, 1, 100_000_000e6); // 1e-6 USDC .. 100M USDC
        usdc.mint(lp, amount);

        uint256 before = usdc.balanceOf(lp);
        vm.startPrank(lp);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount);
        uint256 out = vault.withdraw(shares);
        vm.stopPrank();

        assertLe(out, amount, "round trip extracted value (rounding must favour the vault)");
        assertLe(usdc.balanceOf(lp), before, "LP ended with more USDC than they started");
    }

    /// Round-trip safety with a non-empty vault: a second LP depositing then
    /// immediately withdrawing the same amount cannot extract value from the first.
    function testFuzz_secondDepositorRoundTripNeverProfits(uint256 seed, uint256 amount) public {
        uint256 seedAmt = bound(seed, 1e6, 10_000_000e6);
        amount = bound(amount, 1, 10_000_000e6);
        usdc.mint(lp, seedAmt); // ensure lp can fund the seed deposit
        _deposit(lp, seedAmt); // vault already non-empty at a real share price

        usdc.mint(attacker, amount);
        vm.startPrank(attacker);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount);
        uint256 out = vault.withdraw(shares);
        vm.stopPrank();

        assertLe(out, amount, "second-depositor round trip extracted value from the pool");
    }

    /// totalAssets conservation across a draw → settle → forward → repay sequence.
    /// Receivables-in must exactly offset cash/tokens-out at every step, so
    /// totalAssets is invariant through the whole bridge cycle (LP share price
    /// never dips while money is in flight). Fuzz the deposit + draw amounts.
    function testFuzz_treasurerLifecycle_totalAssetsConserved(uint256 deposit_, uint256 draw_) public {
        uint256 dep = bound(deposit_, 1_000e6, 10_000_000e6);
        uint256 draw = bound(draw_, 1, dep); // cannot draw more than free USDC

        usdc.mint(lp, dep);
        _deposit(lp, dep);
        uint256 base = vault.totalAssets();
        assertEq(base, dep, "deposit did not credit 1:1");

        // Draw: USDC out, replenishment receivable in — totalAssets unchanged.
        vm.prank(treasurer);
        vault.drawForReplenishment(address(token), draw);
        assertEq(vault.totalAssets(), base, "draw moved totalAssets");

        // Mint-at-fill: tokens worth exactly `draw` (at $100, draw/100 tokens) land.
        // draw is USDC 6dp; token 18dp at NAV $100 → tokens = draw * 1e20 / nav.
        // Mint a round token amount and settle its NAV value to keep books exact.
        uint256 tokensIn = (draw * 1e20) / uint256(NAV); // inverse of _navValueUsdc
        token.mint(address(vault), tokensIn);
        uint256 navValue = vault.inventoryValue(address(token));
        // navValue may be 1 unit shy of `draw` due to integer division; settle the
        // smaller of the two so the receivable never underflows.
        uint256 toSettle = navValue < draw ? navValue : draw;
        vm.prank(treasurer);
        vault.settleReplenishment(address(token), toSettle);

        // Forward all inventory for burn: tokens out, buyback receivable in.
        if (tokensIn > 0) {
            vm.prank(treasurer);
            vault.forwardForBurn(address(token), tokensIn);
            assertEq(token.balanceOf(address(vault)), 0, "inventory not fully forwarded");
        }

        // totalAssets across the cycle must stay within rounding of base. Residual
        // receivable from the draw/settle integer-division gap is part of totalAssets
        // either way, so the figure is conserved up to that <=1-unit gap per series.
        assertApproxEqAbs(vault.totalAssets(), base, 2, "bridge cycle moved totalAssets beyond rounding");
    }

    // ── Initializer guards ────────────────────────────────────────────────────

    function test_initialize_zeroUsdc_reverts() public {
        GyldSettlementVault impl2 = new GyldSettlementVault();
        vm.expectRevert(GyldSettlementVault.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl2),
            abi.encodeCall(GyldSettlementVault.initialize, (admin, pauser, treasurer, address(0), issuanceMgr))
        );
    }

    function test_initialize_zeroIssuanceManager_reverts() public {
        GyldSettlementVault impl2 = new GyldSettlementVault();
        vm.expectRevert(GyldSettlementVault.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl2),
            abi.encodeCall(GyldSettlementVault.initialize, (admin, pauser, treasurer, address(usdc), address(0)))
        );
    }
}

/// @dev Forwarder stub reporting 6 decimals — must fail registerSeries's 8dp probe.
contract MockSixDecimalForwarder {
    function decimals() external pure returns (uint8) { return 6; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 100e6, block.timestamp, block.timestamp, 1);
    }
}

/// @dev A deployed contract exposing neither decimals() nor SWAP_MESSAGE_TYPEHASH() —
///      used to test probe rejection of wrong contracts.
contract MockUSDCNoDecimalsShim {
    function somethingElse() external pure returns (uint256) { return 1; }
}
