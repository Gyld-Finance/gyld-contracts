// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockUSDC} from "../test/MockUSDC.sol";

contract DeployMockUSDC is Script {
    function run() external {
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
