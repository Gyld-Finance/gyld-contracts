// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title DeployTimelock
/// @notice Deploys a TimelockController and wires it as the governance authority over:
///           1. TokenFactory (via Ownable2Step ownership)
///           2. IssuanceManager (as DEFAULT_ADMIN_ROLE)
///
/// This enforces a mandatory delay on all sensitive operations:
///   - New token deployments (factory.deployToken)
///   - Role grants on IssuanceManager (subscriber, redeemer, whitelist-admin, registrar)
///   - IssuanceManager UUPS upgrades (via DEFAULT_ADMIN_ROLE holder)
///
/// Delay: 48 hours minimum. On any production chain a shorter delay is rejected before
/// gas is spent — `TIMELOCK_DELAY_SECONDS=0` on a production L2 is exactly how the live stack ended
/// up with a timelock that gates nothing (GYL-1135).
///
/// ── Environment variables ──────────────────────────────────────────────────
/// Required on EVERY chain:
///   MULTISIG_ADDRESS            — Gnosis Safe / MPC multisig that proposes operations.
///                                 On production this must not be the deployer EOA.
///   EVM_FACTORY_ADDRESS         — address of the already-deployed TokenFactory
///
/// Required on PRODUCTION chains (optional on Anvil / Sepolia):
///   ISSUANCE_MANAGER_ADDRESS    — deployed IssuanceManager proxy. The timelock is granted
///                                 DEFAULT_ADMIN_ROLE and the deployer's is revoked
///                                 atomically. Previously an unset value SILENTLY skipped
///                                 the handover and left the deployer as sole admin.
///   TIMELOCK_DELAY_SECONDS      — delay in seconds; must be >= 172800 (48h) on production
///
/// Usage:
///   forge script contracts/script/DeployTimelock.s.sol \
///     --rpc-url $EVM_RPC_URL \
///     --broadcast \
///     --private-key $PRIVKEY_SIGNING_KEY
///
/// After broadcasting, the multisig must complete the two-step ownership hand-off
/// for the factory by scheduling and executing factory.acceptOwnership() via the timelock.
/// The IssuanceManager admin hand-off is completed inline — no follow-up step.
contract DeployTimelock is Script {
    uint256 constant DEFAULT_DELAY = 48 hours;

    // ── Outputs — public storage so tests and follow-up scripts can read them ──
    TimelockController public timelock;
    address public factoryAddress;
    address public issuanceManagerAddress;
    uint256 public delay;

    function run() external {
        address deployer = DeployGuards.broadcaster();

        address multisig = DeployGuards.envAddressRequired("MULTISIG_ADDRESS");
        // A timelock whose sole proposer is the deployer is not a governance gate at all.
        DeployGuards.requireNotDeployer(multisig, deployer, "MULTISIG_ADDRESS");

        factoryAddress = DeployGuards.envAddressRequired("EVM_FACTORY_ADDRESS");
        DeployGuards.requireProdContract(factoryAddress, "EVM_FACTORY_ADDRESS");

        // Required on production: skipping the IssuanceManager hand-off leaves the
        // deployer EOA as sole DEFAULT_ADMIN, which used to happen silently.
        issuanceManagerAddress = DeployGuards.envAddressProdRequired("ISSUANCE_MANAGER_ADDRESS", address(0));
        if (issuanceManagerAddress != address(0)) {
            DeployGuards.requireProdContract(issuanceManagerAddress, "ISSUANCE_MANAGER_ADDRESS");
        }

        delay = DeployGuards.envUintProdRequired("TIMELOCK_DELAY_SECONDS", DEFAULT_DELAY);
        DeployGuards.requireProdMinDelay(delay);

        vm.startBroadcast();

        // Proposers = [multisig]; executors = [address(0)] (anyone can execute
        // after the delay — reduces operational friction while preserving the
        // mandatory wait window). admin = address(0) → self-administered from birth;
        // no separate admin role that could bypass the delay.
        {
            address[] memory proposers = new address[](1);
            proposers[0] = multisig;
            address[] memory executors = new address[](1);
            executors[0] = address(0);

            timelock = new TimelockController{
                salt: DeployGuards.vacantSalt(
                    "DeployTimelock:TimelockController",
                    abi.encodePacked(
                        type(TimelockController).creationCode, abi.encode(delay, proposers, executors, address(0))
                    )
                )
            }(delay, proposers, executors, address(0));
        }

        // ── Factory ownership ─────────────────────────────────────────────────
        // Initiate the factory ownership transfer. The timelock becomes
        // pendingOwner; the multisig must schedule + execute acceptOwnership()
        // through the timelock after `delay` seconds to complete the hand-off.
        TokenFactory(factoryAddress).transferOwnership(address(timelock));

        // ── IssuanceManager DEFAULT_ADMIN ─────────────────────────────────────
        // Grant DEFAULT_ADMIN_ROLE on the IssuanceManager to the timelock, then
        // immediately revoke it from the deployer, so all role grants and UUPS upgrades
        // require the timelock delay with no parallel bypass path.
        if (issuanceManagerAddress != address(0)) {
            IssuanceManager im = IssuanceManager(issuanceManagerAddress);
            bytes32 adminRole = im.DEFAULT_ADMIN_ROLE();
            im.grantRole(adminRole, address(timelock));
            im.revokeRole(adminRole, deployer);
        }

        // ── In-band post-deploy assertions ────────────────────────────────────
        // Still inside the broadcast: a mismatch aborts the deploy.
        _assertFinalTopology(deployer);

        vm.stopBroadcast();

        console.log("=== DeployTimelock complete ===");
        console.log("Chain ID:           %d", block.chainid);
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

    /// @dev Asserts the FINAL topology rather than the individual calls: the timelock is
    ///      a real gate, the deployer proposes nothing through it, admin actually moved,
    ///      and the factory hand-off is genuinely in flight.
    function _assertFinalTopology(address deployer) internal view {
        DeployGuards.assertTimelockSane(payable(address(timelock)), deployer);

        if (issuanceManagerAddress != address(0)) {
            DeployGuards.assertRoleHandover(
                issuanceManagerAddress,
                IssuanceManager(issuanceManagerAddress).DEFAULT_ADMIN_ROLE(),
                address(timelock),
                deployer,
                "IssuanceManager DEFAULT_ADMIN_ROLE"
            );
        }

        // Ownable2Step: ownership completes when the multisig executes acceptOwnership
        // through the timelock, so at this point the timelock must be the pending owner.
        require(
            TokenFactory(factoryAddress).pendingOwner() == address(timelock),
            "DeployTimelock: factory pendingOwner is not the timelock"
        );
    }
}
