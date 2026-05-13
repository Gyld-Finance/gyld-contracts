// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockSanctionsList} from "../MockSanctionsList.sol";

contract DeployMockSanctionsList is Script {
    function run() external {
        vm.startBroadcast();
        MockSanctionsList mock = new MockSanctionsList();
        vm.stopBroadcast();

        // Both vars are set so callers can:
        //   CHAINALYSIS_SANCTIONS_CONTRACT — point ChainalysisSanctionsList at the mock
        //   MOCK_SANCTIONS_ADDRESS         — point EvmChain::mock_sanction_address at the mock
        console.log("MOCK_SANCTIONS_ADDRESS=%s", address(mock));
        console.log("CHAINALYSIS_SANCTIONS_CONTRACT=%s", address(mock));
    }
}
