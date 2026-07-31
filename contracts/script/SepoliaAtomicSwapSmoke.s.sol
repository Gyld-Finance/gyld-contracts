// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title SepoliaAtomicSwapSmoke
/// @notice End-to-end smoke test of the self-custodial GyldAtomicSwap on Sepolia
///         against the throwaway ERC-8056 series (SepoliaErc8056Series.s.sol):
///         seeds inventory, signs a real EIP-712 BUY quote with the deployer key,
///         executes it on-chain, then exercises the ERC-8056 multiplier live.
///
///         Deployer holds every test role (QUOTE_SIGNER / ALLOWLIST_ADMIN /
///         SUBSCRIBER / taker) because DeployAtomicSettlement ran with dev defaults.
///
/// ── CHAIN GUARD (added on review) ────────────────────────────────────────────
/// Pinned to Sepolia (11155111). The original had no chain guard whatsoever: it
/// would have signed a real quote and moved real inventory on whatever chain the
/// --rpc-url pointed at. It is not permitted on Anvil either — every address it
/// touches must already exist and already hold roles, so there is nothing for it
/// to do on a fresh local node (use AtomicSettlementFlow.s.sol for that).
///
/// ── The `require`s below are SIMULATION-time assertions ──────────────────────
/// `forge script` runs `run()` against a simulated fork and only then broadcasts
/// the collected calls, so every `require` gates the SIMULATED result. In
/// particular `block.timestamp` inside an assertion is the SIMULATION timestamp,
/// not the timestamp the transaction eventually lands at. Re-read anything that
/// matters with `cast call` after the broadcast.
///
/// ── Re-runnability ───────────────────────────────────────────────────────────
/// Assertions are DELTA-based (measured against balances read at entry) rather
/// than absolute, and QUOTE_ID is an env var that is checked unused up front, so
/// a second run against the same series does not fail on stale state. The original
/// hard-coded quoteId 1 and asserted absolute balances, making it single-use.
///
/// Env:  PRIVKEY, DEPLOYER, USDC_ADDRESS, EVM_ISSUANCE_MANAGER, EVM_ATOMIC_SWAP,
///       SERIES_TOKEN, QUOTE_ID (optional, default 1)
///
/// Run:  source .env && forge script contracts/script/SepoliaAtomicSwapSmoke.s.sol \
///         --rpc-url $RPC --broadcast --private-key $PRIVKEY
contract SepoliaAtomicSwapSmoke is Script {
    function run() external {
        require(
            block.chainid == DeployGuards.SEPOLIA_CHAIN_ID,
            "SepoliaAtomicSwapSmoke: Sepolia (chainId 11155111) only"
        );

        uint256 pk = vm.envUint("PRIVKEY");
        address deployer = vm.envAddress("DEPLOYER");
        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        IssuanceManager im = IssuanceManager(vm.envAddress("EVM_ISSUANCE_MANAGER"));
        GyldAtomicSwap swap = GyldAtomicSwap(vm.envAddress("EVM_ATOMIC_SWAP"));
        GyldBondToken token = GyldBondToken(vm.envAddress("SERIES_TOKEN"));
        uint256 quoteId = vm.envOr("QUOTE_ID", uint256(1));

        // ── Pre-flight: every prerequisite the original silently assumed ──────
        require(vm.addr(pk) == deployer, "DEPLOYER does not match PRIVKEY");
        require(swap.registeredSeries(address(token)), "series not registered on the swap (registerSeries first)");
        require(swap.isAllowed(deployer), "deployer/taker is not allowlisted on the swap (setAllowed first)");
        require(im.whitelisted(address(swap)), "swap is not a whitelisted AP (addToWhitelist first)");
        require(im.hasRole(im.SUBSCRIBER_ROLE(), deployer), "deployer lacks SUBSCRIBER_ROLE on the IssuanceManager");
        require(swap.hasRole(swap.QUOTE_SIGNER_ROLE(), deployer), "deployer lacks QUOTE_SIGNER_ROLE on the swap");
        require(
            token.hasRole(keccak256("UI_MULTIPLIER_ROLE"), deployer),
            "deployer lacks UI_MULTIPLIER_ROLE (run SepoliaErc8056Series first)"
        );
        require(!swap.isQuoteUsed(quoteId), "QUOTE_ID already consumed - pass a fresh QUOTE_ID");
        require(usdc.balanceOf(deployer) >= 4e6, "deployer needs >= 4 USDC (2 to seed the swap, 2 to buy with)");

        // Entry snapshot — all assertions below are deltas against these.
        uint256 takerBondBefore = token.balanceOf(deployer);
        uint256 swapUsdcBefore = usdc.balanceOf(address(swap));
        uint256 swapBondBefore = token.balanceOf(address(swap));
        uint256 supplyBefore = token.totalSupply();

        vm.startBroadcast(pk);

        // ── 1. Seed swap inventory ────────────────────────────────────────────
        // 100 bonds minted straight into the swap (it is a whitelisted AP) and
        // 2 USDC for the redeem leg. Mint-at-fill, same as production.
        im.subscribe(address(token), address(swap), 100e18);
        usdc.transfer(address(swap), 2e6);
        require(token.balanceOf(address(swap)) == swapBondBefore + 100e18, "subscribe mint did not land in the swap");
        require(token.totalSupply() == supplyBefore + 100e18, "totalSupply did not move by the minted amount");
        console.log("seeded: 100 bonds + 2 USDC to swap");

        // ── 2. Sign + execute a real BUY: 2 USDC -> 0.02 bonds at NAV $100 ────
        GyldAtomicSwap.SwapMessage memory m = GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: deployer,
            tokenIn: address(usdc),
            maxAmountIn: 2e6,
            tokenOut: address(token),
            price: 1e28, // 0.01 bond (18dp) per 1 USDC (6dp), in 1e18 fixed point
            // Generous validity margins: forge bakes calldata at simulation time, so
            // block.timestamp-derived args must tolerate the sim-to-mining gap (several
            // blocks). +1h expiry is exactly the default maxQuoteTtl bound (inclusive) —
            // note the bound is checked at LANDING time, where the remaining TTL is
            // strictly smaller, so a late landing loosens rather than breaks it.
            expiry: uint64(block.timestamp + 1 hours),
            epoch: swap.quoteEpoch()
        });
        bytes32 digest = swap.hashSwapMessage(m);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        usdc.approve(address(swap), 2e6);
        GyldAtomicSwap.PermitData memory noPermit; // value == 0 -> permit skipped
        swap.executeSwap(m, sig, noPermit, 2e6);

        // Settlement is priced on RAW balanceOf units. 2 USDC at price 1e28 is exactly
        // 0.02 bonds whatever the UI multiplier is — proven on Anvil in
        // docs/anvil-verification-erc8056-2026-07-31.md section 3.
        require(token.balanceOf(deployer) == takerBondBefore + 2e16, "BUY failed: expected +0.02 bonds");
        require(usdc.balanceOf(address(swap)) == swapUsdcBefore + 4e6, "swap should have taken 2 (seed) + 2 (buy) USDC");
        require(
            token.balanceOf(address(swap)) == swapBondBefore + 100e18 - 2e16, "swap bond inventory wrong after BUY"
        );
        require(swap.isQuoteUsed(quoteId), "quoteId not consumed");
        console.log("BUY executed on Sepolia: 2 USDC -> 0.02 bonds, quoteId %d burned", quoteId);

        // ── 3. ERC-8056 multiplier live on the same series ────────────────────
        // Immediate update (5% move, inside the 10% deviation cap) then a
        // pre-announced scheduled change (>= 1h after the first activation).
        uint256 rawBefore = token.balanceOf(deployer);
        token.setUiMultiplier(1.05e18);
        // Display-only: the raw balance MUST NOT move, the UI view MUST.
        require(token.balanceOf(deployer) == rawBefore, "setUiMultiplier moved a REAL balance");
        require(token.balanceOfUI(deployer) == rawBefore * 105 / 100, "balanceOfUI != raw * 1.05");
        require(token.totalSupplyUI() == token.totalSupply() * 105 / 100, "totalSupplyUI != totalSupply * 1.05");

        // +2h (not +1h): MIN_UI_MULTIPLIER_UPDATE_INTERVAL is anchored to the
        // ACTIVATION time of the setUiMultiplier tx, which lags this script's
        // simulation clock, so +1h could land inside the floor and revert
        // UiMultiplierUpdateTooSoon.
        uint256 scheduledAt = block.timestamp + 2 hours;
        token.scheduleUiMultiplier(1.04e18, scheduledAt);
        require(token.newUIMultiplier() == 1.04e18, "pending multiplier not stored");
        require(token.effectiveAt() == scheduledAt, "effectiveAt wrong");
        require(token.uiMultiplier() == 1.05e18, "current multiplier moved early");
        console.log("ERC-8056 live: setUiMultiplier 1.05x, scheduled 1.04x at +2h");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Sepolia smoke test PASSED (simulation-time asserts) ===");
        console.log("Re-verify against the live node once the txs are mined:");
        console.log("  cast call %s 'uiMultiplier()(uint256)' --rpc-url $RPC", address(token));
        console.log("  cast call %s 'balanceOfUI(address)(uint256)' %s --rpc-url $RPC", address(token), deployer);
        console.log("  cast call %s 'balanceOf(address)(uint256)' %s --rpc-url $RPC", address(token), deployer);
    }
}
