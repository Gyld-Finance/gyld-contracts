// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DeployEulerStep2 - BASE MAINNET                                         ║
// ║                                                                          ║
// ║  Step 2 of 6: Deploy and configure EulerRouter                          ║
// ║                                                                          ║
// ║  What this does:                                                         ║
// ║    1. Deploys an EulerRouter via the oracleRouterFactory                 ║
// ║    2. Configures TBA/USDC route to point at the ChainlinkOracle adapter  ║
// ║    3. Renounces governance (transferGovernance(address(0))) making the   ║
// ║       router permanently immutable — no one can change routes after this ║
// ║                                                                          ║
// ║  Why a router is needed:                                                 ║
// ║    Euler vaults do not call the oracle adapter directly. They call       ║
// ║    router.getQuote(amount, base, quote). The router dispatches to the    ║
// ║    right adapter. One router can serve all vaults in the cluster.        ║
// ║                                                                          ║
// ║  Pre-requisites:                                                         ║
// ║    - Step 1 complete: EULER_CHAINLINK_ADAPTER deployed and verified      ║
// ║                                                                          ║
// ║  After this step:                                                        ║
// ║    Save EULER_ROUTER to .env                                             ║
// ║    Run DeployEulerStep3.s.sol (KinkIRM)                                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

import {Script, console} from "forge-std/Script.sol";

contract DeployEulerStep2 is Script {

    // ── Euler V2 on Base mainnet ──────────────────────────────────────────
    address constant ORACLE_ROUTER_FACTORY = 0xA9287853987B107969f181Cce5e25e0D09c1c116;

    // ── Token addresses ───────────────────────────────────────────────────
    address constant TBA  = 0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ── ChainlinkOracle adapter from Step 1 ──────────────────────────────
    address constant CHAINLINK_ADAPTER = 0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d;

    function run() external {
        require(block.chainid == 8453, "DeployEulerStep2: Base mainnet only");

        address deployer = msg.sender;
        console.log("=== DeployEulerStep2 - Base Mainnet ===");
        console.log("Chain ID:          %d", block.chainid);
        console.log("Deployer:          %s", deployer);
        console.log("ChainlinkAdapter:  %s", CHAINLINK_ADAPTER);
        console.log("");

        vm.startBroadcast();

        // 1. Deploy EulerRouter — deployer is governor initially so we can configure it.
        //    Constructor requires governor != address(0).
        address router = IEulerRouterFactory(ORACLE_ROUTER_FACTORY).deploy(deployer);
        console.log("EulerRouter deployed: %s", router);

        // 2. Configure TBA/USDC route to use our ChainlinkOracle adapter.
        //    govSetConfig sorts the pair addresses internally (_sort), so one call
        //    covers both TBA->USDC and USDC->TBA directions.
        IEulerRouter(router).govSetConfig(TBA, USDC, CHAINLINK_ADAPTER);
        console.log("Route configured: TBA/USDC -> ChainlinkAdapter");

        // 3. Renounce governance — makes the router permanently immutable.
        //    After this no one can change the routes.
        IEulerRouter(router).transferGovernance(address(0));
        console.log("Governance renounced: router is now immutable");

        vm.stopBroadcast();

        console.log("");
        console.log("=== Step 2 complete ===");
        console.log("EULER_ROUTER=%s", router);
        console.log("");
        console.log("Verify getQuote works through router:");
        console.log("  cast call %s", router);
        console.log("    'getQuote(uint256,address,address)(uint256)'");
        console.log("    1000000000000000000");
        console.log("    %s %s", TBA, USDC);
        console.log("    --rpc-url $BASE_RPC");
        console.log("  (should return ~100000000 = $100 USDC)");
        console.log("");
        console.log("Next: run DeployEulerStep3.s.sol (KinkIRM)");
    }
}

interface IEulerRouterFactory {
    function deploy(address governor) external returns (address);
}

interface IEulerRouter {
    function govSetConfig(address base, address quote, address oracle) external;
    function transferGovernance(address newGovernor) external;
    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256);
}
