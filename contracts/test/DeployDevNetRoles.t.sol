// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeployDevNet} from "../script/DeployDevNet.s.sol";
import {IssuanceManager} from "../IssuanceManager.sol";

/// @title DeployDevNetRolesTest
/// @notice Regression cover for the whitelist-role handover in DeployDevNet, run
///         against the real script on a non-Anvil chain id.
///
///         The discriminator is `WHITELIST_ADMIN != deployer` — the configuration every
///         non-Anvil chain uses (Sepolia/Hoodi give the subscriber KMS key the whitelist
///         role). Under it, `initialize` grants the deployer only DEFAULT_ADMIN_ROLE,
///         which in OpenZeppelin AccessControl permits *granting* a role but not
///         exercising it, so the step-8 `addToWhitelist` calls reverted with
///         AccessControlUnauthorizedAccount and no deployment could complete.
///
///         The Anvil-shaped default (`WHITELIST_ADMIN == deployer`) has its own test
///         because it is the leg a naive "grant, then always revoke" fix breaks: it
///         would leave the chain with nobody holding WHITELIST_ADMIN_ROLE.
contract DeployDevNetRolesTest is Test {
    /// Anvil account[1] — hardcoded in DeployDevNet step 8 as the e2e investor.
    address constant ANVIL_INVESTOR = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    /// The wrapper scripts point governance/ops at the deployer on devnet; the timelock
    /// proposer must be the broadcaster or `schedule` itself reverts.
    address deployer;
    address subscriber = address(0xA3);
    address redeemer = address(0xA4);
    address navFeedOwner = address(0xA5);

    function setUp() public {
        // A realistic timestamp: TimelockController treats a scheduled timestamp of 1 as
        // its "done" sentinel, so at the default block.timestamp a zero-delay operation
        // is never Ready.
        vm.warp(1_750_000_000);
        vm.chainId(11155111); // Sepolia — deliberately not the 31337 branch
        // Under `forge script`, run()'s msg.sender and the vm.startBroadcast sender are
        // the same account. DEFAULT_SENDER is that account in test mode; the run() call
        // is pranked to it in _run so the two agree here too.
        deployer = DEFAULT_SENDER;
        vm.setEnv("GOVERNANCE_MULTISIG", vm.toString(deployer));
        vm.setEnv("OPS_MULTISIG", vm.toString(deployer));
        vm.setEnv("SUBSCRIBER_ADDRESS", vm.toString(subscriber));
        vm.setEnv("REDEEMER_ADDRESS", vm.toString(redeemer));
        vm.setEnv("NAV_FEED_OWNER", vm.toString(navFeedOwner));
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
    }

    /// @notice Both legs in one test body. `vm.setEnv` mutates the *process* environment,
    ///         which forge's parallel test execution shares, so two tests configuring
    ///         WHITELIST_ADMIN differently would race; they are sequenced here instead.
    function test_whitelistAdminHandover() public {
        _separateWhitelistAdmin_completesAndRevokesDeployer();
        _deployerAsWhitelistAdmin_keepsTheRole();
    }

    /// @notice The bug: a whitelist admin distinct from the deployer made the script
    ///         unable to whitelist anybody. Asserts the full post-conditions.
    function _separateWhitelistAdmin_completesAndRevokesDeployer() internal {
        address whitelistAdmin = subscriber; // exactly what deploy-sepolia-contracts.sh exports
        IssuanceManager issuanceMgr = _run(whitelistAdmin);

        bytes32 role = issuanceMgr.WHITELIST_ADMIN_ROLE();

        // The whitelisting actually happened (this is what reverted before the fix).
        assertTrue(issuanceMgr.whitelisted(subscriber), "subscriber must be whitelisted");
        assertTrue(issuanceMgr.whitelisted(ANVIL_INVESTOR), "e2e investor must be whitelisted");

        // The configured admin keeps the role...
        assertTrue(issuanceMgr.hasRole(role, whitelistAdmin), "WHITELIST_ADMIN must hold the role");
        // ...and the deployer's bootstrap grant is handed back.
        assertFalse(issuanceMgr.hasRole(role, deployer), "deployer must not retain WHITELIST_ADMIN_ROLE");

        // The revoke is real, not cosmetic: the deployer can no longer whitelist, and
        // no longer holds DEFAULT_ADMIN to re-grant itself.
        assertFalse(issuanceMgr.hasRole(issuanceMgr.DEFAULT_ADMIN_ROLE(), deployer), "deployer must not retain DEFAULT_ADMIN");
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, role)
        );
        issuanceMgr.addToWhitelist(address(0xBEEF));

        // The configured admin can.
        vm.prank(whitelistAdmin);
        issuanceMgr.addToWhitelist(address(0xBEEF));
        assertTrue(issuanceMgr.whitelisted(address(0xBEEF)), "WHITELIST_ADMIN must be able to whitelist");
    }

    /// @notice The combined-role leg: when the deployer *is* the whitelist admin the
    ///         role is permanent, so an unconditional revoke would strand the chain
    ///         with no whitelist admin at all.
    function _deployerAsWhitelistAdmin_keepsTheRole() internal {
        IssuanceManager issuanceMgr = _run(deployer);

        assertTrue(issuanceMgr.whitelisted(subscriber), "subscriber must be whitelisted");
        assertTrue(
            issuanceMgr.hasRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), deployer),
            "deployer configured as WHITELIST_ADMIN must keep the role"
        );

        vm.prank(deployer);
        issuanceMgr.addToWhitelist(address(0xC0FFEE));
        assertTrue(issuanceMgr.whitelisted(address(0xC0FFEE)), "configured admin must be able to whitelist");
    }

    /// Runs the real script and recovers the deployed IssuanceManager proxy.
    function _run(address whitelistAdmin) internal returns (IssuanceManager) {
        vm.setEnv("WHITELIST_ADMIN", vm.toString(whitelistAdmin));

        DeployDevNet script = new DeployDevNet();
        vm.recordLogs();
        // run() must be entered with msg.sender == the broadcast sender, as it is under
        // `forge script`. vm.prank is rejected while a broadcast is active, so the call
        // is made *from* the broadcast sender by etching a trampoline at its address.
        vm.etch(deployer, address(new ScriptRunner()).code);
        ScriptRunner(deployer).go(script);

        return IssuanceManager(_issuanceManagerFromLogs(whitelistAdmin));
    }

    /// The script emits `RoleGranted(WHITELIST_ADMIN_ROLE, whitelistAdmin, deployer)` from
    /// the IssuanceManager proxy at step 4; its emitter is the proxy address. Reading it
    /// off an event avoids depending on nonce arithmetic inside the script.
    function _issuanceManagerFromLogs(address whitelistAdmin) internal returns (address) {
        bytes32 roleGranted = keccak256("RoleGranted(bytes32,address,address)");
        bytes32 whitelistRole = keccak256("WHITELIST_ADMIN_ROLE");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.topics.length != 4) continue;
            if (entry.topics[0] != roleGranted) continue;
            if (entry.topics[1] != whitelistRole) continue;
            if (address(uint160(uint256(entry.topics[2]))) != whitelistAdmin) continue;
            return entry.emitter;
        }
        revert("DeployDevNetRolesTest: IssuanceManager not found in logs - did the script reach step 4?");
    }
}

/// @dev Etched at the broadcast sender's address so that DeployDevNet.run() sees the
///      same msg.sender that vm.startBroadcast() uses — the invariant `forge script`
///      provides and the whole role model depends on.
contract ScriptRunner {
    function go(DeployDevNet script) external {
        script.run();
    }
}
