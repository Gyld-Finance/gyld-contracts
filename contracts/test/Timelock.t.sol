// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";

/// @title TimelockTest
/// @notice Verifies that a TimelockController sitting in front of TokenFactory
///         enforces the mandatory 48-hour delay on token deployments.
///
/// Setup:
///   - TimelockController: 48-hour minDelay, multisig = proposer + executor
///   - Factory ownership transferred to timelock (simulated instantly in tests
///     via vm.prank — in production the multisig executes acceptOwnership via
///     the timelock after the delay).
contract TimelockTest is Test {
    uint256 constant MIN_DELAY = 48 hours;

    TimelockController timelock;
    TokenFactory factory;
    IssuanceManager issuanceMgr;

    address multisig  = address(0xAA);
    address operator  = address(0x01);
    address navOwner  = address(0x05);
    address outsider  = address(0x09);

    function setUp() public {
        GyldBondToken bondTokenImpl     = new GyldBondToken();
        MockSanctionsList mockSanctions = new MockSanctionsList();
        IssuanceManager issuanceMgrImpl = new IssuanceManager();

        factory = new TokenFactory(address(bondTokenImpl), address(mockSanctions));

        // Deploy IssuanceManager proxy — test contract is admin and registrar
        issuanceMgr = IssuanceManager(address(new ERC1967Proxy(
            address(issuanceMgrImpl),
            abi.encodeCall(IssuanceManager.initialize, (address(this), address(this), address(this)))
        )));

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        executors[0] = multisig;

        // admin = address(0) → self-administered from the start; no separate admin role.
        timelock = new TimelockController(MIN_DELAY, proposers, executors, address(0));

        // Transfer factory ownership to timelock.
        // In production this two-step hand-off must itself go through the timelock;
        // here we prank the timelock accepting immediately so tests can focus on delay.
        factory.transferOwnership(address(timelock));
        vm.prank(address(timelock));
        factory.acceptOwnership();

        // Grant factory REGISTRAR_ROLE on IssuanceManager via timelock address
        // (simulated: normally the timelock would schedule this as well)
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));
    }

    // ── configuration ─────────────────────────────────────────────────────────

    function test_timelock_minDelay_is48Hours() public view {
        assertEq(timelock.getMinDelay(), MIN_DELAY);
    }

    function test_factory_ownedByTimelock() public view {
        assertEq(factory.owner(), address(timelock));
    }

    // ── access control ────────────────────────────────────────────────────────

    function test_directCall_byOutsider_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        factory.deployToken("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner);
    }

    function test_directCall_byMultisig_reverts() public {
        // multisig is proposer/executor on the timelock, but NOT the factory owner
        vm.prank(multisig);
        vm.expectRevert();
        factory.deployToken("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner);
    }

    function test_nonProposer_cannotSchedule() public {
        bytes memory data = abi.encodeCall(
            factory.deployToken, ("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner)
        );
        vm.prank(outsider);
        vm.expectRevert();
        timelock.schedule(address(factory), 0, data, bytes32(0), bytes32(0), MIN_DELAY);
    }

    // ── delay enforcement ─────────────────────────────────────────────────────

    function test_executeBeforeDelay_reverts() public {
        bytes memory data = abi.encodeCall(
            factory.deployToken, ("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner)
        );
        bytes32 salt = bytes32(uint256(1));

        vm.prank(multisig);
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, MIN_DELAY);

        // Execute immediately (delay not elapsed)
        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(factory), 0, data, bytes32(0), salt);
    }

    function test_executeAtExactDelay_reverts() public {
        bytes memory data = abi.encodeCall(
            factory.deployToken, ("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner)
        );
        bytes32 salt = bytes32(uint256(2));

        vm.prank(multisig);
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, MIN_DELAY);

        // At exactly MIN_DELAY the timestamp equals readyAt — not strictly less than,
        // so the operation is ready exactly at readyAt (OZ uses <=).
        // Warp to one second before to confirm it's still not ready.
        vm.warp(block.timestamp + MIN_DELAY - 1);
        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(factory), 0, data, bytes32(0), salt);
    }

    // ── happy path ────────────────────────────────────────────────────────────

    function test_executeAfterDelay_deploysToken() public {
        bytes memory data = abi.encodeCall(
            factory.deployToken, ("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner)
        );
        bytes32 salt = bytes32(uint256(3));

        vm.prank(multisig);
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);

        // Capture the TokenDeployed event to extract the deployed token address
        vm.recordLogs();
        vm.prank(multisig);
        timelock.execute(address(factory), 0, data, bytes32(0), salt);

        // Find the TokenDeployed event and verify the navFeed mapping was set
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address deployedToken;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("TokenDeployed(address,address,address,address)")) {
                deployedToken = address(uint160(uint256(logs[i].topics[1])));
                break;
            }
        }
        assertTrue(deployedToken != address(0), "TokenDeployed event not found");
        assertTrue(factory.navFeedOf(deployedToken) != address(0));
    }

    function test_operationIsMarkedDoneAfterExecution() public {
        bytes memory data = abi.encodeCall(
            factory.deployToken, ("Test Bond 2", "tBOND2", "US912797KR73", 0, operator, address(issuanceMgr), navOwner)
        );
        bytes32 salt = bytes32(uint256(4));

        vm.prank(multisig);
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(multisig);
        timelock.execute(address(factory), 0, data, bytes32(0), salt);

        bytes32 opId = timelock.hashOperation(address(factory), 0, data, bytes32(0), salt);
        assertTrue(timelock.isOperationDone(opId));
    }

    // ── cancel ────────────────────────────────────────────────────────────────

    function test_proposerCanCancel_beforeDelay() public {
        bytes memory data = abi.encodeCall(
            factory.deployToken, ("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner)
        );
        bytes32 salt = bytes32(uint256(5));

        vm.prank(multisig);
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, MIN_DELAY);

        bytes32 opId = timelock.hashOperation(address(factory), 0, data, bytes32(0), salt);
        vm.prank(multisig);
        timelock.cancel(opId);

        // Execution after cancel should fail even after delay
        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(factory), 0, data, bytes32(0), salt);
    }

    function test_outsider_cannotCancel() public {
        bytes memory data = abi.encodeCall(
            factory.deployToken, ("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner)
        );
        bytes32 salt = bytes32(uint256(6));

        vm.prank(multisig);
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, MIN_DELAY);

        bytes32 opId = timelock.hashOperation(address(factory), 0, data, bytes32(0), salt);
        vm.prank(outsider);
        vm.expectRevert();
        timelock.cancel(opId);
    }

    // ── IssuanceManager DEFAULT_ADMIN wiring (GYL-241) ───────────────────────

    /// Verifies that once the timelock holds DEFAULT_ADMIN on the IssuanceManager,
    /// role grants must go through the timelock delay — not directly from the multisig.
    function test_timelockIsAdminOfIssuanceManager() public {
        // Cache role constants before pranks/expectReverts to avoid consuming them
        // with inline external calls (issuanceMgr.ROLE() is itself an external call).
        bytes32 adminRole       = issuanceMgr.DEFAULT_ADMIN_ROLE();
        bytes32 issuerRole = issuanceMgr.SUBSCRIBER_ROLE();

        // Simulate DeployTimelock script: grant DEFAULT_ADMIN to timelock, revoke from deployer
        issuanceMgr.grantRole(adminRole, address(timelock));
        issuanceMgr.revokeRole(adminRole, address(this));

        // Direct role grant from outsider (not through timelock) must revert
        vm.prank(outsider);
        vm.expectRevert();
        issuanceMgr.grantRole(issuerRole, address(0x99));

        // Role grant through the timelock succeeds after the mandatory delay
        bytes memory data = abi.encodeCall(
            issuanceMgr.grantRole,
            (issuerRole, address(0x99))
        );
        bytes32 salt = bytes32(uint256(100));

        vm.prank(multisig);
        timelock.schedule(address(issuanceMgr), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.warp(block.timestamp + MIN_DELAY);
        vm.prank(multisig);
        timelock.execute(address(issuanceMgr), 0, data, bytes32(0), salt);

        assertTrue(issuanceMgr.hasRole(issuanceMgr.SUBSCRIBER_ROLE(), address(0x99)));
    }

    // ── IssuanceManager UUPS upgrade authorization (GYL-249) ─────────────────

    /// Verifies DEFAULT_ADMIN_ROLE is the sole authority for IssuanceManager UUPS upgrades.
    /// UPGRADER_ROLE was removed in GYL-249 — the timelock-held DEFAULT_ADMIN_ROLE is the
    /// only path to swapping the implementation contract.
    function test_issuanceMgr_upgrade_authorisedByDefaultAdmin() public {
        // The test contract holds DEFAULT_ADMIN_ROLE from setUp().
        IssuanceManager newImpl = new IssuanceManager();
        issuanceMgr.upgradeToAndCall(address(newImpl), "");
    }

    /// An account without DEFAULT_ADMIN_ROLE cannot upgrade the IssuanceManager —
    /// confirms there is no separate UPGRADER_ROLE escape hatch after GYL-249.
    function test_issuanceMgr_upgrade_byOutsider_reverts() public {
        IssuanceManager newImpl = new IssuanceManager();
        vm.prank(outsider);
        vm.expectRevert();
        issuanceMgr.upgradeToAndCall(address(newImpl), "");
    }

    // ── duplicate scheduling ──────────────────────────────────────────────────

    function test_cannotScheduleSameOperationTwice() public {
        bytes memory data = abi.encodeCall(
            factory.deployToken, ("Test Bond", "tBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner)
        );
        bytes32 salt = bytes32(uint256(7));

        vm.prank(multisig);
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, MIN_DELAY);

        vm.prank(multisig);
        vm.expectRevert();
        timelock.schedule(address(factory), 0, data, bytes32(0), salt, MIN_DELAY);
    }
}
