// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldSettlementVault} from "../GyldSettlementVault.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDCPermit} from "./MockUSDCPermit.sol";

/// @title AtomicSettlementDeployTest
/// @notice Integration test for the DeployAtomicSettlement recipe against REAL
///         contracts (no token/feed mocks). setUp replicates a minimal DeployDevNet
///         stack (IssuanceManager proxy + MockSanctionsList + TokenFactory deploying
///         a real GyldBondToken/KaleidoscopeNAVFeed/NAVFeedForwarder triple), then
///         runs DeployAtomicSettlement steps 1–6 inline. Step 7 (timelock handover)
///         is intentionally skipped — the dev path — so the test contract keeps
///         DEFAULT_ADMIN on vault + swap, standing in for the script broadcaster.
///
///         End-to-end coverage: BUY via the real IssuanceManager.subscribe mint
///         path, REDEEM via the real forwardForBurn → IssuanceManager.redeem burn
///         commitment path (BurnWatcher-compatible), and the Chainalysis fail-closed
///         screen on the vault → taker push.
contract AtomicSettlementDeployTest is Test {
    IssuanceManager     issuanceMgr;
    TokenFactory        factory;
    GyldBondToken       token;
    KaleidoscopeNAVFeed navFeed;
    address             forwarder;
    GyldSettlementVault vault;
    GyldAtomicSwap      swap;
    MockUSDCPermit      usdc;
    MockSanctionsList   mockSanctions;

    // The test contract itself is the "deployer/broadcaster": IssuanceManager
    // DEFAULT_ADMIN + WHITELIST_ADMIN, factory owner, vault/swap DEFAULT_ADMIN.
    address pauser       = address(0xA1); // PAUSER_ROLE on vault + swap; token operator
    address treasurer    = address(0xA2); // vault TREASURER_ROLE
    address subscriber   = address(0xA3); // IssuanceManager SUBSCRIBER_ROLE
    address redeemer     = address(0xA4); // IssuanceManager REDEEMER_ROLE
    address navFeedOwner = address(0xA5); // KaleidoscopeNAVFeed owner (KMS stand-in)
    address lp           = address(0xB0); // vault LP_ROLE

    // Known private keys — vm.addr(PK) is the corresponding address.
    // SIGNER_PK signs SwapMessages (QUOTE_SIGNER_ROLE); TAKER_PK is the end user.
    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK  = 0xA11CE;
    address          signer;
    address          taker;

    // NAV $100.00 per token (8dp): 1e18 token ⇔ 100e6 USDC. Quotes below sit
    // exactly on NAV — inside the vault's 2% band.
    int256 constant NAV = 100e8;

    // Dust seed deposit (DUST_DEPOSIT_USDC analog): 1 USDC in 6dp units.
    uint256 constant DUST = 1e6;
    uint256 dustShares;

    function setUp() public {
        vm.warp(1_750_000_000); // realistic timestamp so expiry math is meaningful
        signer = vm.addr(SIGNER_PK);
        taker  = vm.addr(TAKER_PK);

        // ── Minimal DevNet stack (mirrors DeployDevNet; no timelock — the test
        //    contract stays factory owner so deployToken is called directly) ─────
        mockSanctions = new MockSanctionsList();
        usdc          = new MockUSDCPermit();

        issuanceMgr = IssuanceManager(address(new ERC1967Proxy(
            address(new IssuanceManager()),
            abi.encodeCall(IssuanceManager.initialize, (address(this), subscriber, redeemer))
        )));
        issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), address(this));

        factory = new TokenFactory(address(new GyldBondToken()), address(mockSanctions));
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
        token     = GyldBondToken(token_);
        navFeed   = KaleidoscopeNAVFeed(navFeed_);
        forwarder = forwarder_;

        // Initial NAV push by the feed owner — first update has no interval/deviation guard.
        vm.prank(navFeedOwner);
        navFeed.updateAnswer(NAV);

        // ── DeployAtomicSettlement steps 1–7 inline ───────────────────────────

        // 1. Vault impl + proxy; deployer (this) is DEFAULT_ADMIN during setup.
        vault = GyldSettlementVault(address(new ERC1967Proxy(
            address(new GyldSettlementVault()),
            abi.encodeCall(
                GyldSettlementVault.initialize,
                (address(this), pauser, treasurer, address(usdc), address(issuanceMgr))
            )
        )));

        // 2. Swap impl + proxy; initialize probes vault.totalAssets().
        swap = GyldAtomicSwap(address(new ERC1967Proxy(
            address(new GyldAtomicSwap()),
            abi.encodeCall(GyldAtomicSwap.initialize, (address(this), pauser, signer, address(vault)))
        )));

        // 3. Wire vault → swap (probes SWAP_MESSAGE_TYPEHASH, grants SWAP_ROLE atomically).
        vault.setSwap(address(swap));

        // 4. Whitelist the vault as an AP on the IssuanceManager — the only touch
        //    on existing contracts; lets subscribe() mint inventory to the vault.
        issuanceMgr.addToWhitelist(address(vault));

        // 5. Register the series with the REAL forwarder looked up from the factory
        //    (registerSeries probes forwarder.decimals() == 8 on-chain).
        vault.registerSeries(address(token), factory.forwarderOf(address(token)));

        // 6. LP_ROLE grants + dust seed deposit from the broadcaster.
        bytes32 lpRole = vault.LP_ROLE();
        vault.grantRole(lpRole, lp);
        vault.grantRole(lpRole, address(this));
        usdc.mint(address(this), DUST);
        usdc.approve(address(vault), DUST);
        dustShares = vault.deposit(DUST);

        // 7. Timelock handover intentionally SKIPPED (dev path: TIMELOCK_ADDRESS
        //    unset) — the deployer keeps DEFAULT_ADMIN, asserted in the wiring test.
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Inventory via the REAL mint path (vault is a whitelisted AP) + LP liquidity.
    function _seedInventoryAndLiquidity() internal {
        vm.prank(subscriber);
        issuanceMgr.subscribe(address(token), address(vault), 100e18); // 100 tokens @ $100

        usdc.mint(lp, 10_000e6);
        vm.startPrank(lp);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6);
        vm.stopPrank();

        usdc.mint(taker, 100_000e6);
    }

    /// BUY: taker pays 1_000 USDC, receives 10 bond tokens (exactly at NAV).
    function _buyQuote(uint256 quoteId) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId:   quoteId,
            taker:     taker,
            tokenIn:   address(usdc),
            amountIn:  1_000e6,
            tokenOut:  address(token),
            amountOut: 10e18,
            expiry:    uint64(block.timestamp + 15 minutes),
            epoch:     0
        });
    }

    /// REDEEM: taker pays 10 bond tokens, receives 1_000 USDC (exactly at NAV).
    function _redeemQuote(uint256 quoteId) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId:   quoteId,
            taker:     taker,
            tokenIn:   address(token),
            amountIn:  10e18,
            tokenOut:  address(usdc),
            amountOut: 1_000e6,
            expiry:    uint64(block.timestamp + 15 minutes),
            epoch:     0
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
        usdc.approve(address(swap), m.amountIn);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit());
    }

    // ── Deployment recipe wiring ──────────────────────────────────────────────

    function test_deployRecipe_wiresVaultSwapWhitelistAndSeries() public view {
        // Step 3: vault ↔ swap wiring; SWAP_ROLE held by the swap proxy only.
        assertEq(vault.swap(), address(swap), "vault.swap() != swap proxy");
        assertTrue(vault.hasRole(vault.SWAP_ROLE(), address(swap)), "swap proxy lacks SWAP_ROLE");
        assertEq(swap.vault(), address(vault), "swap.vault() != vault proxy");

        // Step 4: vault is a whitelisted AP; the swap contract deliberately is NOT.
        assertTrue(issuanceMgr.whitelisted(address(vault)), "vault not whitelisted as AP");
        assertFalse(issuanceMgr.whitelisted(address(swap)), "swap must NOT be whitelisted");

        // Step 5: series registered with the factory's REAL forwarder.
        assertTrue(vault.registeredSeries(address(token)), "series not registered");
        assertEq(vault.navForwarderOf(address(token)), forwarder, "forwarder mismatch");
        assertEq(factory.forwarderOf(address(token)), forwarder, "factory forwarder mapping drift");
        assertEq(factory.navFeedOf(address(token)), address(navFeed), "factory navFeed mapping drift");

        // Step 6: dust deposit produced shares; vault values exactly the dust.
        assertGt(dustShares, 0, "dust deposit produced zero shares");
        assertEq(vault.totalAssets(), DUST, "totalAssets != dust seed");

        // Step 7 skipped: deployer keeps DEFAULT_ADMIN on both proxies (dev path).
        assertTrue(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), address(this)), "deployer lost vault admin");
        assertTrue(swap.hasRole(swap.DEFAULT_ADMIN_ROLE(), address(this)), "deployer lost swap admin");

        // DevNet base wiring: token registered + IssuanceManager holds mint/burn.
        assertTrue(issuanceMgr.registeredTokens(address(token)), "token not registered with manager");
        assertTrue(token.hasRole(token.MINTER_ROLE(), address(issuanceMgr)), "manager lacks MINTER_ROLE");
        assertTrue(token.hasRole(token.BURNER_ROLE(), address(issuanceMgr)), "manager lacks BURNER_ROLE");
    }

    // ── E2E BUY through the real mint path ────────────────────────────────────

    function test_e2e_buy_inventoryFromRealSubscribeMint() public {
        _seedInventoryAndLiquidity();

        // Real mint path landed: 100 tokens minted by IssuanceManager.subscribe.
        assertEq(token.balanceOf(address(vault)), 100e18, "subscribe mint did not land in vault");
        assertEq(token.totalSupply(), 100e18);

        uint256 vaultUsdcBefore = usdc.balanceOf(address(vault)); // dust + LP deposit
        uint256 totalAssetsBefore = vault.totalAssets();

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit());

        assertEq(token.balanceOf(taker), 10e18, "taker did not receive tokens");
        assertEq(token.balanceOf(address(vault)), 90e18, "vault inventory not debited");
        assertEq(usdc.balanceOf(taker), 100_000e6 - 1_000e6, "taker USDC not debited");
        assertEq(usdc.balanceOf(address(vault)), vaultUsdcBefore + 1_000e6, "vault USDC not credited");
        assertEq(token.totalSupply(), 100e18, "buy must not mint or burn");
        assertTrue(swap.isQuoteUsed(1), "quoteId not consumed");

        // Quote at exact NAV: USDC in exactly replaces inventory out.
        assertEq(vault.totalAssets(), totalAssetsBefore, "buy at NAV moved totalAssets");
    }

    // ── E2E REDEEM through the burn-commitment path ───────────────────────────

    function test_e2e_redeem_forwardForBurn_redeemAndRepay() public {
        _seedInventoryAndLiquidity();
        _executeBuy(1); // taker now holds 10e18

        // 1. Taker swaps tokens back for USDC at NAV.
        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(2);
        bytes memory sig = _sign(m);
        uint256 totalAssetsBefore = vault.totalAssets();

        vm.prank(taker);
        token.approve(address(swap), 10e18);
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit());

        assertEq(token.balanceOf(taker), 0, "taker tokens not debited");
        assertEq(token.balanceOf(address(vault)), 100e18, "collateral not back in inventory");
        assertEq(usdc.balanceOf(taker), 100_000e6, "taker did not get full round trip");
        assertEq(vault.totalAssets(), totalAssetsBefore, "redeem at NAV moved totalAssets");

        // 2. Treasurer forwards NET collateral for burn — the on-chain commitment
        //    signal the backend BurnWatcher consumes (tokens land at the manager).
        vm.prank(treasurer);
        vault.forwardForBurn(address(token), 10e18);

        assertEq(token.balanceOf(address(issuanceMgr)), 10e18, "commitment not at IssuanceManager");
        assertEq(token.balanceOf(address(vault)), 90e18);
        (, uint256 buyback) = vault.obligationsOf(address(token));
        assertEq(buyback, 1_000e6, "buyback receivable != NAV value"); // 10e18 * 100e8 / 1e20
        assertEq(vault.totalAssets(), totalAssetsBefore, "forwardForBurn moved totalAssets");

        // 3. Redeemer burns from the manager's own balance (proves the existing
        //    BurnWatcher-compatible commitment path works for vault-forwarded tokens).
        issuanceMgr.addToWhitelist(taker); // beneficiary must be a whitelisted AP
        vm.prank(redeemer);
        issuanceMgr.redeem(address(token), taker, 10e18);

        assertEq(token.balanceOf(address(issuanceMgr)), 0, "burn did not consume manager balance");
        assertEq(token.totalSupply(), 90e18, "supply not reduced by burn");
        assertEq(vault.totalAssets(), totalAssetsBefore, "off-vault burn moved totalAssets");

        // 4. Treasurer repays USDC from the T+2 broker sale — obligation closes.
        usdc.mint(treasurer, 1_000e6);
        vm.startPrank(treasurer);
        usdc.approve(address(vault), 1_000e6);
        vault.repayUsdc(address(token), 1_000e6);
        vm.stopPrank();

        (, buyback) = vault.obligationsOf(address(token));
        assertEq(buyback, 0, "buyback obligation not closed");
        assertEq(vault.totalAssets(), totalAssetsBefore, "repayUsdc moved totalAssets");
    }

    // ── Sanctions integration: fail-closed on the vault → taker push ──────────

    function test_executeSwap_sanctionedTaker_revertsFailClosed() public {
        _seedInventoryAndLiquidity();
        mockSanctions.setSanctioned(taker, true);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1);
        bytes memory sig = _sign(m);
        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        // The USDC leg has no screen; the bond token's _update on the vault → taker
        // push must revert AccountSanctioned (bubbled through SafeERC20 + onSwap).
        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.AccountSanctioned.selector, taker));
        swap.executeSwap(m, sig, _noPermit());

        assertEq(token.balanceOf(taker), 0, "sanctioned taker received tokens");
    }
}
