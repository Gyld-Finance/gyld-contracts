// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDCPermit} from "./MockUSDCPermit.sol";

/// @title AtomicSettlementDeployTest
/// @notice Integration test for the self-custodial DeployAtomicSettlement recipe against
///         REAL contracts (no token/feed mocks). setUp replicates a minimal DeployDevNet
///         stack (IssuanceManager proxy + MockSanctionsList + TokenFactory deploying
///         a real GyldBondToken/KaleidoscopeNAVFeed/NAVFeedForwarder triple), then
///         runs the DeployAtomicSettlement steps inline. The timelock handover is
///         intentionally skipped — the dev path — so the test contract keeps
///         DEFAULT_ADMIN on the swap, standing in for the script broadcaster.
///
///         End-to-end coverage: BUY via the real IssuanceManager.subscribe mint path
///         (inventory minted directly into the SWAP), REDEEM against the swap's own
///         inventory + a treasurer withdraw() of the returned collateral to the fixed
///         withdrawalWallet (the off-chain broker bridge), and the Chainalysis
///         fail-closed screen on the swap → taker push.
contract AtomicSettlementDeployTest is Test {
    IssuanceManager issuanceMgr;
    TokenFactory factory;
    GyldBondToken token;
    KaleidoscopeNAVFeed navFeed;
    address forwarder;
    GyldAtomicSwap swap;
    MockUSDCPermit usdc;
    MockSanctionsList mockSanctions;

    // The test contract itself is the "deployer/broadcaster": IssuanceManager
    // DEFAULT_ADMIN + WHITELIST_ADMIN, factory owner, swap DEFAULT_ADMIN.
    address pauser = address(0xA1); // PAUSER_ROLE on swap; token operator
    address treasurer = address(0xA2); // swap TREASURER_ROLE
    address subscriber = address(0xA3); // IssuanceManager SUBSCRIBER_ROLE
    address redeemer = address(0xA4); // IssuanceManager REDEEMER_ROLE
    address navFeedOwner = address(0xA5); // KaleidoscopeNAVFeed owner (KMS stand-in)
    address withdrawal = address(0xB1); // fixed treasury withdrawal destination
    address allowlistAdmin = address(0xB2); // swap ALLOWLIST_ADMIN_ROLE (KMS allowlist key)

    // Known private keys — vm.addr(PK) is the corresponding address.
    // SIGNER_PK signs SwapMessages (QUOTE_SIGNER_ROLE); TAKER_PK is the end user.
    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK = 0xA11CE;
    address signer;
    address taker;

    // NAV $100.00 per token (8dp): 1e18 token ⇔ 100e6 USDC. Quotes below sit
    // exactly on NAV — inside the swap's 2% band.
    int256 constant NAV = 100e8;
    uint16 constant MAX_BPS = 200; // 2% band
    uint32 constant MAX_NAV_AGE = 1 days;

    function setUp() public {
        vm.warp(1_750_000_000); // realistic timestamp so expiry math is meaningful
        signer = vm.addr(SIGNER_PK);
        taker = vm.addr(TAKER_PK);

        // ── Minimal DevNet stack (mirrors DeployDevNet; no timelock — the test
        //    contract stays factory owner so deployToken is called directly) ─────
        mockSanctions = new MockSanctionsList(address(this));
        usdc = new MockUSDCPermit();

        issuanceMgr = IssuanceManager(
            address(
                new ERC1967Proxy(
                    address(new IssuanceManager()),
                    abi.encodeCall(IssuanceManager.initialize, (address(this), subscriber, redeemer))
                )
            )
        );
        issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), address(this));

        factory = new TokenFactory(address(new GyldBondToken()), address(mockSanctions), address(this));
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));

        // Real bond series deployed through the factory (CAT, same params as DeployDevNet).
        (address token_, address navFeed_, address forwarder_) = factory.deployToken(
            "Caterpillar Inc 3.7% 2028",
            "14913UBF6",
            "US14913UBF62",
            1_788_739_200,
            pauser,
            address(issuanceMgr),
            navFeedOwner
        );
        token = GyldBondToken(token_);
        navFeed = KaleidoscopeNAVFeed(navFeed_);
        forwarder = forwarder_;

        // Initial NAV push by the feed owner — first update has no interval/deviation guard.
        vm.prank(navFeedOwner);
        navFeed.updateAnswer(NAV);

        // ── DeployAtomicSettlement steps inline (self-custodial) ──────────────

        // 1. Swap impl + proxy; deployer (this) is DEFAULT_ADMIN during setup.
        swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(new GyldAtomicSwap()),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (address(this), pauser, signer, treasurer, address(usdc), MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );

        // 2. Whitelist the SWAP as an AP on the IssuanceManager — the only touch on
        //    existing contracts; lets subscribe() mint inventory directly to the swap.
        issuanceMgr.addToWhitelist(address(swap));

        // 3. Register the series with the REAL forwarder looked up from the factory
        //    (registerSeries probes forwarder.decimals() == 8 on-chain).
        swap.registerSeries(address(token), factory.forwarderOf(address(token)));

        // 4. Set the fixed treasury withdrawal wallet.
        swap.setWithdrawalWallet(withdrawal);

        // 5. Grant ALLOWLIST_ADMIN_ROLE (setAllowed's gate since GYL-1050) to the
        //    broadcaster — the script does this BEFORE the timelock handover.
        swap.grantRole(swap.ALLOWLIST_ADMIN_ROLE(), address(this));

        // 6. Allowlist the taker.
        swap.setAllowed(taker, true);

        // 7. Timelock handover intentionally SKIPPED (dev path: TIMELOCK_ADDRESS
        //    unset) — the deployer keeps DEFAULT_ADMIN, asserted in the wiring test.
        //    The prod handover is covered by
        //    test_deployRecipe_afterTimelockHandover_allowlistAdminStillWorks.
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Inventory via the REAL mint path (swap is a whitelisted AP) + USDC liquidity
    /// funded directly into the swap.
    function _seedInventoryAndLiquidity() internal {
        vm.prank(subscriber);
        issuanceMgr.subscribe(address(token), address(swap), 100e18); // 100 tokens @ $100 minted to the swap

        usdc.mint(address(swap), 10_000e6); // USDC liquidity for the redeem leg
        usdc.mint(taker, 100_000e6);
    }

    /// BUY: taker pays up to 1_000 USDC, receives bond tokens at 1:100 (exactly at NAV).
    function _buyQuote(uint256 quoteId) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: 1_000e6,
            tokenOut: address(token),
            price: 10e18 * 1e18 / 1_000e6, // 10e18 tokenOut per 1_000e6 tokenIn
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
    }

    /// REDEEM: taker pays up to 10 bond tokens, receives USDC at 100:1 (exactly at NAV).
    function _redeemQuote(uint256 quoteId) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: 10e18,
            tokenOut: address(usdc),
            price: 1_000e6 * 1e18 / 10e18, // 1_000e6 tokenOut per 10e18 tokenIn
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

    /// Approve-then-execute a BUY for `quoteId` as the taker.
    function _executeBuy(uint256 quoteId) internal {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(quoteId);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        usdc.approve(address(swap), m.maxAmountIn);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);
    }

    // ── Deployment recipe wiring ──────────────────────────────────────────────

    function test_deployRecipe_wiresSwapWhitelistSeriesAndTreasury() public view {
        // Swap holds its own inventory and is a whitelisted AP (subscribe mint recipient).
        assertTrue(issuanceMgr.whitelisted(address(swap)), "swap not whitelisted as AP");

        // Series registered with the factory's REAL forwarder.
        assertTrue(swap.registeredSeries(address(token)), "series not registered");
        assertEq(swap.navForwarderOf(address(token)), forwarder, "forwarder mismatch");
        assertEq(factory.forwarderOf(address(token)), forwarder, "factory forwarder mapping drift");
        assertEq(factory.navFeedOf(address(token)), address(navFeed), "factory navFeed mapping drift");

        // Band params, withdrawal wallet, allowlist.
        assertEq(swap.maxQuoteDeviationBps(), MAX_BPS, "band bps mismatch");
        assertEq(swap.maxNavAgeSecs(), MAX_NAV_AGE, "nav age mismatch");
        assertEq(swap.usdc(), address(usdc), "usdc mismatch");
        assertEq(swap.withdrawalWallet(), withdrawal, "withdrawalWallet mismatch");
        assertTrue(swap.isAllowed(taker), "taker not allowlisted");

        // Roles. setUp deliberately replays the DEV path (TIMELOCK_ADDRESS unset), so the
        // deployer still holds DEFAULT_ADMIN here. That is legitimate ONLY on a development
        // chain, and this suite runs on Anvil's 31337 — asserted, so the expectation can
        // never silently become "the deployer keeps admin everywhere", which is exactly the
        // fail-open shape this used to encode. Since GYL-1135 DeployAtomicSettlement
        // requires TIMELOCK_ADDRESS on every production chain and refuses to skip the
        // handover there, so this state is unreachable in production; the production
        // topology is pinned by the handover test below and by DeployScripts.t.sol.
        assertEq(block.chainid, 31337, "dev-path assertion assumes a development chain");
        assertTrue(swap.hasRole(swap.DEFAULT_ADMIN_ROLE(), address(this)), "deployer lost swap admin on the dev path");
        assertTrue(swap.hasRole(swap.TREASURER_ROLE(), treasurer), "treasurer lacks TREASURER_ROLE");
        assertTrue(swap.hasRole(swap.QUOTE_SIGNER_ROLE(), signer), "signer lacks QUOTE_SIGNER_ROLE");

        // GYL-1050: the recipe grants the dedicated operational allowlist role.
        assertTrue(
            swap.hasRole(swap.ALLOWLIST_ADMIN_ROLE(), address(this)),
            "deploy recipe did not grant ALLOWLIST_ADMIN_ROLE"
        );

        // DevNet base wiring: token registered + IssuanceManager holds mint/burn.
        assertTrue(issuanceMgr.registeredTokens(address(token)), "token not registered with manager");
        assertTrue(token.hasRole(token.MINTER_ROLE(), address(issuanceMgr)), "manager lacks MINTER_ROLE");
        assertTrue(token.hasRole(token.BURNER_ROLE(), address(issuanceMgr)), "manager lacks BURNER_ROLE");
    }

    /// GYL-1050 regression pin — the actual production defect this ticket closes.
    ///
    /// The rest of this suite deliberately skips the timelock handover (dev path), which
    /// is exactly why the incompatibility shipped: after
    /// DeployAtomicSettlement.s.sol hands DEFAULT_ADMIN_ROLE to the 48h
    /// TimelockController and revokes the deployer, the gateway's synchronous allowlist
    /// API (`POST /api/v1/admin/swap/allowlist`, signed by the EVM_KMS_SWAP_ADMIN_ key)
    /// used to revert on every call. This replays the prod handover and asserts the KMS
    /// allowlist key survives it.
    function test_deployRecipe_afterTimelockHandover_allowlistAdminStillWorks() public {
        address[] memory multisig = new address[](1);
        multisig[0] = address(0xB3);
        // admin = address(0) → self-administered, same shape as Timelock.t.sol.
        TimelockController timelock = new TimelockController(48 hours, multisig, multisig, address(0));

        bytes32 adminRole = swap.DEFAULT_ADMIN_ROLE();
        bytes32 allowlistRole = swap.ALLOWLIST_ADMIN_ROLE();

        // Script step 5: grant the operational role to the KMS allowlist key BEFORE the
        // handover (ordering is load-bearing — after the revoke the deployer can grant
        // nothing and recovery would need a 48h timelock proposal).
        swap.grantRole(allowlistRole, allowlistAdmin);

        // Script step 7: hand DEFAULT_ADMIN to the timelock and revoke the deployer
        // (including its transient allowlist grant from setUp).
        swap.grantRole(adminRole, address(timelock));
        swap.revokeRole(allowlistRole, address(this));
        swap.revokeRole(adminRole, address(this));

        // (c) The timelock now owns governance; the deployer owns nothing.
        assertTrue(swap.hasRole(adminRole, address(timelock)), "timelock lacks DEFAULT_ADMIN after handover");
        assertFalse(swap.hasRole(adminRole, address(this)), "deployer kept DEFAULT_ADMIN after handover");

        // (c2) GYL-1135: the hand-over must not be cosmetic. On the production L2 the timelock had a
        // zero delay and the deployer as its sole proposer, so "admin is the timelock"
        // was true and meant nothing. These are the properties
        // DeployGuards.assertTimelockSane now enforces in-band during the deploy.
        assertGe(timelock.getMinDelay(), 48 hours, "timelock delay below the production minimum");
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(this)), "deployer can propose through the timelock");
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), address(this)), "deployer can cancel through the timelock");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)), "deployer administers the timelock");

        // (a) The KMS allowlist key can STILL allowlist a taker synchronously — the
        //     property the whole ticket exists to guarantee.
        address newTaker = address(0xC0FFEE);
        assertFalse(swap.isAllowed(newTaker));
        vm.prank(allowlistAdmin);
        swap.setAllowed(newTaker, true);
        assertTrue(swap.isAllowed(newTaker), "ALLOWLIST_ADMIN could not allowlist after handover");

        // (b) The revoked deployer cannot.
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(this), allowlistRole
            )
        );
        swap.setAllowed(address(0xDEAD), true);

        // And the timelock — the DEFAULT_ADMIN holder — is deliberately NOT the gate.
        vm.prank(address(timelock));
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", address(timelock), allowlistRole
            )
        );
        swap.setAllowed(address(0xDEAD), true);
    }

    // ── E2E BUY through the real mint path ────────────────────────────────────

    function test_e2e_buy_inventoryFromRealSubscribeMint() public {
        _seedInventoryAndLiquidity();

        // Real mint path landed: 100 tokens minted by IssuanceManager.subscribe to the swap.
        assertEq(token.balanceOf(address(swap)), 100e18, "subscribe mint did not land in swap");
        assertEq(token.totalSupply(), 100e18);

        uint256 swapUsdcBefore = usdc.balanceOf(address(swap)); // seeded liquidity

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);

        assertEq(token.balanceOf(taker), 10e18, "taker did not receive tokens");
        assertEq(token.balanceOf(address(swap)), 90e18, "swap inventory not debited");
        assertEq(usdc.balanceOf(taker), 100_000e6 - 1_000e6, "taker USDC not debited");
        assertEq(usdc.balanceOf(address(swap)), swapUsdcBefore + 1_000e6, "swap USDC not credited");
        assertEq(token.totalSupply(), 100e18, "buy must not mint or burn");
        assertTrue(swap.isQuoteUsed(1), "quoteId not consumed");
    }

    // ── E2E REDEEM against swap inventory + treasurer withdraw bridge ──────────

    function test_e2e_redeem_thenTreasurerWithdrawsCollateral() public {
        _seedInventoryAndLiquidity();
        _executeBuy(1); // taker now holds 10e18

        // 1. Taker swaps tokens back for USDC at NAV — collateral re-enters swap inventory.
        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(2);
        bytes memory sig = _sign(m);

        vm.prank(taker);
        token.approve(address(swap), 10e18);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);

        assertEq(token.balanceOf(taker), 0, "taker tokens not debited");
        assertEq(token.balanceOf(address(swap)), 100e18, "collateral not back in inventory");
        assertEq(usdc.balanceOf(taker), 100_000e6, "taker did not get full round trip");

        // 2. Treasurer evacuates the returned NET collateral out to the fixed
        //    withdrawalWallet — off-chain ops then bridges it to the IssuanceManager
        //    for the BurnWatcher commitment. withdraw() can only ever send to the
        //    admin-fixed wallet.
        vm.prank(treasurer);
        swap.withdraw(address(token), 10e18);

        assertEq(token.balanceOf(withdrawal), 10e18, "collateral not delivered to withdrawalWallet");
        assertEq(token.balanceOf(address(swap)), 90e18, "swap not debited by withdraw");

        // 3. Off-chain, ops forwards the collateral to the IssuanceManager and the
        //    redeemer burns it (the existing BurnWatcher-compatible commitment path).
        //    Simulate the bridge: withdrawalWallet transfers to the manager, redeemer burns.
        vm.prank(withdrawal);
        token.transfer(address(issuanceMgr), 10e18);
        issuanceMgr.addToWhitelist(taker); // beneficiary must be a whitelisted AP
        vm.prank(redeemer);
        issuanceMgr.redeem(address(token), taker, 10e18);

        assertEq(token.balanceOf(address(issuanceMgr)), 0, "burn did not consume manager balance");
        assertEq(token.totalSupply(), 90e18, "supply not reduced by burn");
    }

    // ── Sanctions integration: fail-closed on the swap → taker push ───────────

    function test_executeSwap_sanctionedTaker_revertsFailClosed() public {
        _seedInventoryAndLiquidity();
        mockSanctions.setSanctioned(taker, true);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        // The USDC leg has no screen; the bond token's _update on the swap → taker
        // push must revert AccountSanctioned (bubbled through SafeERC20). The taker is
        // already allowlisted, so the revert comes from the sanctions screen, not NotAllowed.
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.AccountSanctioned.selector, taker));
        swap.executeSwap(m, sig, _noPermit(), m.maxAmountIn);

        assertEq(token.balanceOf(taker), 0, "sanctioned taker received tokens");
    }
}
