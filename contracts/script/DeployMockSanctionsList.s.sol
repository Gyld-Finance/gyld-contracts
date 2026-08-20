// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {MockSanctionsList} from "../test/MockSanctionsList.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title DeployMockSanctionsList
/// @notice Dev-only: deploys the writable {MockSanctionsList} used by the gateway's
///         `mock_sanction_address` admin endpoint.
///
/// ── Why the chain guard exists (GYL-1135) ─────────────────────────────────────
/// This script had NO chain guard whatsoever, and it is the one contract in the repo whose
/// entire purpose is to be a fake compliance oracle. Since
/// {DeployGuards.requireProdContract} can only check `code.length != 0`, a mock deployed
/// on a production L2 or BSC by this script SATISFIES the production `SANCTIONS_LIST` requirement —
/// which is a live route straight around the hardening the rest of GYL-1135 added. It is
/// now gated on the same dev ALLOWLIST every other script uses (Anvil 31337 /
/// Sepolia 11155111); anything else fails closed, before any gas is spent.
///
/// The mock's write functions are additionally owner-gated (see {MockSanctionsList}), so
/// even on a dev chain the list is not permissionlessly writable. The owner is the
/// broadcaster — i.e. the key the gateway signs `mock_sanction_address` with.
contract DeployMockSanctionsList is Script {
    /// Output — public so tests and follow-up scripts can read it.
    MockSanctionsList public mock;

    function run() external {
        // Guard BEFORE the broadcast: a dry run names the problem instead of the
        // transaction reverting mid-flight.
        DeployGuards.requireProdSafe("deploying a MockSanctionsList (a writable fake compliance oracle)");

        address owner = DeployGuards.broadcaster();

        vm.startBroadcast();
        mock = new MockSanctionsList(owner);
        vm.stopBroadcast();

        // Both vars are set so callers can:
        //   CHAINALYSIS_SANCTIONS_CONTRACT — point ChainalysisSanctionsList at the mock
        //   MOCK_SANCTIONS_ADDRESS         — point EvmChain::mock_sanction_address at the mock
        console.log("MOCK_SANCTIONS_ADDRESS=%s", address(mock));
        console.log("CHAINALYSIS_SANCTIONS_CONTRACT=%s", address(mock));
        // Only this address can add/remove sanctions on the mock.
        console.log("MOCK_SANCTIONS_OWNER=%s", owner);
    }
}
