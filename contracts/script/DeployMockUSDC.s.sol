// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../test/MockUSDC.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title DeployMockUSDC
/// @notice Dev-only: deploys a {MockUSDC} and funds the standard Anvil accounts used by
///         the local docker-compose flow.
///
/// ── Why the chain guard exists (GYL-1135) ─────────────────────────────────────
/// This was the LAST script under `contracts/script/` with no chain guard of any kind —
/// not even the `block.chainid != 1` denylist the others had. `forge script DeployMockUSDC
/// --rpc-url <base>` therefore deployed a fake "USD Coin" on a production chain and minted
/// 100,000 of it to three hardcoded Anvil accounts, one of which (`0x7099…79C8`,
/// {DeployGuards.ANVIL_ACCOUNT_1}) has a private key published in the Anvil banner. The
/// token is worthless, so the direct blast radius is small — but {MockUSDC} has a
/// permissionless `mint`, no EIP-2612 permit and a name that reads as the real thing, and
/// an ungated deploy script is precisely the defect class this ticket exists to close.
///
/// It is now gated on the same dev ALLOWLIST every other script uses (Anvil 31337 /
/// Sepolia 11155111); anything else fails closed, before any gas is spent.
///
/// Note this script is for LOCAL dev only even where it is permitted: on Sepolia, use real
/// Circle USDC (`0x1c7D…7238`) — {MockUSDC} has no permit, so the `permitIn` settlement
/// path cannot be exercised against it (see docs/atomic-settlement-testnet-runbook.md).
contract DeployMockUSDC is Script {
    /// Output — public so tests and follow-up scripts can read it.
    MockUSDC public usdc;

    function run() external {
        // Guard BEFORE the broadcast: a dry run names the problem instead of the
        // transaction reverting mid-flight.
        DeployGuards.requireProdSafe("deploying MockUSDC and minting to publicly-keyed Anvil accounts");

        address account0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        address account1 = DeployGuards.ANVIL_ACCOUNT_1;
        address account2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

        vm.startBroadcast();
        usdc = new MockUSDC();

        // Mint 100,000 USDC (6 decimals) to each test account
        usdc.mint(account0, 100_000 * 1e6);
        usdc.mint(account1, 100_000 * 1e6);
        usdc.mint(account2, 100_000 * 1e6);

        vm.stopBroadcast();

        console.log("USDC_CONTRACT_ADDRESS=%s", address(usdc));
    }
}
