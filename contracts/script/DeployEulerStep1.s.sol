// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DeployEulerStep1 - BASE MAINNET                                         ║
// ║                                                                          ║
// ║  Step 1 of 6: Deploy ChainlinkOracle adapter for TBA/USDC               ║
// ║                                                                          ║
// ║  What this does:                                                         ║
// ║    Deploys a ChainlinkOracle adapter from euler-price-oracle that wraps  ║
// ║    our NAVFeedForwarder. Euler vaults call getQuote(amount, TBA, USDC)   ║
// ║    on this adapter — it internally calls NAVFeedForwarder.latestRoundData║
// ║    and converts the 8-decimal USD price to ERC-7726 format.             ║
// ║                                                                          ║
// ║  Pre-requisites:                                                         ║
// ║    - NAVFeedForwarder has a fresh price (pushed within maxStaleness)     ║
// ║    - BASE_FORWARDER_TBA is set in .env                                   ║
// ║                                                                          ║
// ║  After this step:                                                        ║
// ║    Save EULER_CHAINLINK_ADAPTER to .env                                  ║
// ║    Run DeployEulerStep2.s.sol (EulerRouter)                              ║
// ╚══════════════════════════════════════════════════════════════════════════╝

import {Script, console} from "forge-std/Script.sol";
import {ChainlinkOracle} from "euler-price-oracle/adapter/chainlink/ChainlinkOracle.sol";

contract DeployEulerStep1 is Script {

    // ── Base mainnet token addresses ──────────────────────────────────────
    address constant TBA  = 0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ── Our NAVFeedForwarder — AggregatorV3Interface, 8-decimal USD ───────
    address constant NAV_FEED_FORWARDER = 0x09907C78D4eB531495962120464BFd9044390337;

    // ── Euler OracleAdapterRegistry on Base mainnet ───────────────────────
    // After deploying, register the adapter here so Euler tooling can find it
    address constant ORACLE_ADAPTER_REGISTRY = 0x3cD76476bB7933A99Fa5bAa05446e71e07CDe0ca;

    // ── maxStaleness: 86400 = 24 hours ───────────────────────────────────
    // Must be in [60, 259200]. Adapter reverts if price is older than this.
    uint256 constant MAX_STALENESS = 86400;

    function run() external {
        require(block.chainid == 8453, "DeployEulerStep1: Base mainnet only");

        // Verify NAVFeedForwarder has a non-stale price before deploying.
        // Constructor calls feed.decimals() live — also serves as a reachability check.
        (, int256 answer,, uint256 updatedAt,) =
            IAggregatorV3(NAV_FEED_FORWARDER).latestRoundData();
        require(answer > 0, "NAVFeedForwarder: zero or negative price");
        require(block.timestamp - updatedAt <= MAX_STALENESS,
            "NAVFeedForwarder: price too stale - push a fresh price first");

        address deployer = msg.sender;
        console.log("=== DeployEulerStep1 - Base Mainnet ===");
        console.log("Chain ID:           %d", block.chainid);
        console.log("Deployer:           %s", deployer);
        console.log("TBA:                %s", TBA);
        console.log("USDC:               %s", USDC);
        console.log("NAVFeedForwarder:   %s", NAV_FEED_FORWARDER);
        console.log("Current NAV price:  %d (8 decimals)", uint256(answer));
        console.log("Price age (secs):   %d", block.timestamp - updatedAt);
        console.log("maxStaleness:       %d", MAX_STALENESS);
        console.log("");

        vm.startBroadcast();

        // Deploy ChainlinkOracle adapter.
        // Constructor calls feed.decimals() live — reverts if feed is invalid.
        // scale is computed once from (baseDecimals, quoteDecimals, feedDecimals).
        ChainlinkOracle adapter = new ChainlinkOracle(
            TBA,
            USDC,
            NAV_FEED_FORWARDER,
            MAX_STALENESS
        );

        // Note: OracleAdapterRegistry.add() is owned by the Euler team — we cannot
        // call it directly. The adapter works without registration; the registry is
        // only for discoverability in Euler tooling. Euler Labs can add it later.

        vm.stopBroadcast();

        console.log("=== Step 1 complete ===");
        console.log("EULER_CHAINLINK_ADAPTER=%s", address(adapter));
        console.log("");
        console.log("Verify on BaseScan:");
        console.log("  https://basescan.org/address/%s", address(adapter));
        console.log("");
        console.log("Verify getQuote works:");
        console.log("  cast call %s", address(adapter));
        console.log("    'getQuote(uint256,address,address)(uint256)'");
        console.log("    1000000000000000000 %s %s", TBA, USDC);
        console.log("    --rpc-url $BASE_RPC");
        console.log("  (1 TBA should return ~1000000 = $1.00 in USDC 6 decimals)");
        console.log("");
        console.log("Next: run DeployEulerStep2.s.sol (EulerRouter)");
    }
}

interface IAggregatorV3 {
    function latestRoundData() external view returns (
        uint80 roundId, int256 answer, uint256 startedAt,
        uint256 updatedAt, uint80 answeredInRound
    );
}

interface ISnapshotRegistry {
    function add(address element, address base, address quote) external;
}
