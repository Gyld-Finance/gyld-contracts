// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {IssuanceManager} from "../IssuanceManager.sol";

/// @title DeployTimelock
/// @notice Deploys a TimelockController and wires it as the governance authority over:
///           1. TokenFactory (via Ownable2Step ownership)
///           2. IssuanceManager (as DEFAULT_ADMIN_ROLE, if address provided)
///
/// This enforces a mandatory delay on all sensitive operations:
///   - New token deployments (factory.deployToken)
///   - Role grants on IssuanceManager (issuer, whitelist-admin, registrar)
///   - IssuanceManager UUPS upgrades (via DEFAULT_ADMIN_ROLE holder)
///
/// Delay: 48 hours for all operations (role grants, revokes, UUPS upgrades,
///   new token deployments). Override via TIMELOCK_DELAY_SECONDS env var.
///
/// Required env vars:
///   MULTISIG_ADDRESS            — Gnosis Safe / MPC multisig that proposes operations
///   EVM_FACTORY_ADDRESS         — address of the already-deployed TokenFactory
///
/// Optional env vars:
///   ISSUANCE_MANAGER_ADDRESS    — address of the deployed IssuanceManager proxy;
///                                 when set, the timelock is granted DEFAULT_ADMIN_ROLE
///                                 and the deployer's DEFAULT_ADMIN_ROLE is revoked atomically
///   TIMELOCK_DELAY_SECONDS      — override delay (defaults to 172800 = 48 hours)
///
/// Usage:
///   forge script contracts/script/DeployTimelock.s.sol \
///     --rpc-url $EVM_RPC_URL \
///     --broadcast \
///     --private-key $PRIVKEY_SIGNING_KEY
///
/// After broadcasting, the multisig must complete the two-step ownership hand-off
/// for the factory by scheduling and executing factory.acceptOwnership() via the timelock.
/// If ISSUANCE_MANAGER_ADDRESS was set, the deployer also needs to revoke its own
/// DEFAULT_ADMIN_ROLE from the IssuanceManager (schedule via timelock to avoid lockout).
contract DeployTimelock is Script {
    uint256 constant DEFAULT_DELAY = 48 hours;

    function run() external {
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        address factoryAddress = vm.envAddress("EVM_FACTORY_ADDRESS");

        // Optional: wire IssuanceManager DEFAULT_ADMIN to timelock as well
        address issuanceManagerAddress = address(0);
        try vm.envAddress("ISSUANCE_MANAGER_ADDRESS") returns (address a) {
            issuanceManagerAddress = a;
        } catch {}

        uint256 delay = DEFAULT_DELAY;
        try vm.envUint("TIMELOCK_DELAY_SECONDS") returns (uint256 d) {
            delay = d;
        } catch {}

        vm.startBroadcast();

        // Proposers = [multisig]; executors = [address(0)] (anyone can execute
        // after the delay — reduces operational friction while preserving the
        // mandatory wait window).
        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        // admin = address(0) → self-administered from birth; no separate admin
        // role that could bypass the delay.
        TimelockController timelock = new TimelockController(
            delay,
            proposers,
            executors,
            address(0)
        );

        // ── Factory ownership ─────────────────────────────────────────────────
        // Initiate the factory ownership transfer. The timelock becomes
        // pendingOwner; the multisig must schedule + execute acceptOwnership()
        // through the timelock after `delay` seconds to complete the hand-off.
        TokenFactory(factoryAddress).transferOwnership(address(timelock));

        // ── IssuanceManager DEFAULT_ADMIN ─────────────────────────────────────
        // When provided, grant DEFAULT_ADMIN_ROLE on the IssuanceManager to the
        // timelock, then immediately revoke it from the deployer. This ensures all
        // role grants (ISSUER_ROLE, WHITELIST_ADMIN_ROLE) and UUPS upgrades require
        // the timelock delay, with no parallel bypass path.
        if (issuanceManagerAddress != address(0)) {
            IssuanceManager im = IssuanceManager(issuanceManagerAddress);
            bytes32 adminRole = im.DEFAULT_ADMIN_ROLE();
            im.grantRole(adminRole, address(timelock));
            im.revokeRole(adminRole, msg.sender);
        }

        vm.stopBroadcast();

        console.log("=== DeployTimelock complete ===");
        console.log("Timelock:           %s", address(timelock));
        console.log("Delay (seconds):    %d (%d hours)", delay, delay / 3600);
        console.log("Proposer/canceller: %s", multisig);
        console.log("Executor:           address(0) = anyone after delay");
        console.log("");
        console.log("-- Factory hand-off --");
        console.log("Factory pending owner: %s", address(timelock));
        console.log("Next: multisig must complete the factory ownership hand-off:");
        console.log("  1. Schedule via timelock:");
        console.log("       target = %s (factory)", factoryAddress);
        console.log("       data   = factory.acceptOwnership() (0x79ba5097)");
        console.log("       delay  >= %d seconds", delay);
        console.log("  2. Wait %d seconds, then execute", delay);

        if (issuanceManagerAddress != address(0)) {
            console.log("");
            console.log("-- IssuanceManager admin hand-off --");
            console.log("Timelock now holds DEFAULT_ADMIN_ROLE on IssuanceManager: %s", issuanceManagerAddress);
            console.log("Deployer DEFAULT_ADMIN_ROLE revoked inline. Timelock is the sole admin.");
        }

        console.log("");
        console.log("Set env var:");
        console.log("  TIMELOCK_ADDRESS=%s", address(timelock));
    }
}
