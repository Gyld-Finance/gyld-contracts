// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../test/MockUSDC.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @dev Dev-only. This script mints to the three well-known Anvil accounts,
///      whose private keys are PUBLIC, so anyone could spend the balance. It also
///      deploys a MockUSDC with an unrestricted mint. Neither belongs on a chain
///      anybody else can reach.
///
///      Note this script previously had NO chain guard of any kind — not even the
///      `block.chainid != 1` denylist the rest of the suite used. The CI check
///      (ci/check_chain_guards.py) cannot catch that class: it flags a WRONG guard,
///      not a MISSING one. Found by reading the scripts rather than by tooling.
contract DeployMockUSDC is Script {
    function run() external {
        DeployGuards.requireProdSafe("deploying MockUSDC and minting to public Anvil keys is");

        address account0 = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        address account1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
        address account2 = 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC;

        vm.startBroadcast();
        MockUSDC usdc = new MockUSDC();

        // Mint 100,000 USDC (6 decimals) to each test account
        usdc.mint(account0, 100_000 * 1e6);
        usdc.mint(account1, 100_000 * 1e6);
        usdc.mint(account2, 100_000 * 1e6);

        vm.stopBroadcast();

        console.log("USDC_CONTRACT_ADDRESS=%s", address(usdc));
    }
}
