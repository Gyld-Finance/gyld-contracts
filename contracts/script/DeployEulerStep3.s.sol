// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DeployEulerStep3 - BASE MAINNET                                         ║
// ║                                                                          ║
// ║  Step 3 of 6: Deploy KinkIRM (interest rate model)                      ║
// ║                                                                          ║
// ║  What this does:                                                         ║
// ║    Deploys an IRMLinearKink via the kinkIRMFactory. This determines how  ║
// ║    the borrow rate changes with utilisation in the USDC lending vault.   ║
// ║                                                                          ║
// ║  Rate curve chosen (conservative — bond token market):                  ║
// ║    0% APY  at   0% utilisation (base rate)                              ║
// ║    5% APY  at  80% utilisation (kink)                                   ║
// ║    100% APY at 100% utilisation (max — deters full drain)               ║
// ║                                                                          ║
// ║  The IRM is immutable after deployment — parameters cannot be changed.  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

import {Script, console} from "forge-std/Script.sol";

contract DeployEulerStep3 is Script {

    // ── KinkIRM factory on Base mainnet ───────────────────────────────────
    address constant KINK_IRM_FACTORY = 0x2d94C898a17f9D8c0bA75010A51cd61BF55b402E;

    // ── Rate parameters (verified via Euler's calculate-irm-linear-kink.js)
    //
    // Curve: 0% base | 5% APY at 80% kink | 100% APY at 100% utilisation
    //
    // Units: SPY (Second Percent Yield) scaled by 1e27.
    // Formula: rate = ln(1 + APY) / seconds_per_year * 1e27
    //          seconds_per_year = 31,556,952 (365.2425 days)
    //
    // kink is uint32 where type(uint32).max = 100% utilisation
    // kink = floor(0.80 * 2^32) = 3,435,973,836
    //
    uint256 constant BASE_RATE = 0;
    uint256 constant SLOPE1    = 449973958;     // rate per util-unit below kink
    uint256 constant SLOPE2    = 23770682707;   // rate per util-unit above kink
    uint32  constant KINK      = 3435973836;    // 80% utilisation

    function run() external {
        require(block.chainid == 8453, "DeployEulerStep3: Base mainnet only");

        console.log("=== DeployEulerStep3 - Base Mainnet ===");
        console.log("Chain ID:    %d", block.chainid);
        console.log("Deployer:    %s", msg.sender);
        console.log("Rate curve:  0%% base | 5%% at 80%% kink | 100%% max APY");
        console.log("baseRate:    %d", BASE_RATE);
        console.log("slope1:      %d", SLOPE1);
        console.log("slope2:      %d", SLOPE2);
        console.log("kink:        %d (80%% utilisation)", KINK);
        console.log("");

        vm.startBroadcast();

        address irm = IKinkIRMFactory(KINK_IRM_FACTORY).deploy(
            BASE_RATE,
            SLOPE1,
            SLOPE2,
            KINK
        );

        vm.stopBroadcast();

        console.log("=== Step 3 complete ===");
        console.log("EULER_IRM=%s", irm);
        console.log("");
        console.log("Next: run DeployEulerStep4.s.sol (escrowed collateral vault for TBA)");
    }
}

interface IKinkIRMFactory {
    function deploy(uint256 baseRate, uint256 slope1, uint256 slope2, uint32 kink)
        external returns (address);
}
