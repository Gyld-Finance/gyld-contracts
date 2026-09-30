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
    /// Fixed start time so timestamp maths is literal — see the note in the cap test.
    uint256 constant T0 = 1_750_000_000;

    TimelockController timelock;
    TokenFactory factory;
    IssuanceManager issuanceMgr;

    address multisig  = address(0xAA);
    address operator  = address(0x01);
    address navOwner  = address(0x05);
    address outsider  = address(0x09);

    function setUp() public {
        GyldBondToken bondTokenImpl     = new GyldBondToken();
        MockSanctionsList mockSanctions = new MockSanctionsList(address(this));
        IssuanceManager issuanceMgrImpl = new IssuanceManager();

        factory = new TokenFactory(address(bondTokenImpl), address(mockSanctions), address(this));

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
            if (logs[i].topics[0] == keccak256("TokenDeployed(address,address,bytes32,address,address,string)")) {
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

    // ── FIND-001: raising the daily mint cap is itself a 48h change ────────────

    /// Deploys a REAL series through the timelock, then proves a cap change on it needs
    /// the full delay.
    ///
    /// This file already proved the delay on `deployToken` and `grantRole`, and
    /// AtomicSettlementDeploy asserts the admin handover — but nothing joined the two for
    /// `setDailyCap`. So "raising the issuance cap takes 48 hours" rested on deploy wiring
    /// plus an argument rather than on a test. It rests on this now.
    ///
    /// The series is a real factory-deployed, IssuanceManager-registered token rather than
    /// a bare address. `setDailyCap` has no registration check today (unlike the swap's
    /// `setMaxNavRoundNotionalFor`), so a made-up address would pass — but it would only
    /// prove a mapping slot moved, never that the slot belongs to a series `subscribe`
    /// actually reads, and it would silently break the day that guard is added.
    function test_setDailyCap_throughTimelock_takesFullDelay() public {
        // The delay must be the TIMELOCK's floor, not the proposer's good manners. OZ
        // schedules at `block.timestamp + delay` using the CALLER's delay and only checks
        // minDelay as a lower bound, so a 0-delay timelock plus a polite 48h proposer
        // looks identical to this test unless minDelay itself is pinned. That is the
        // GYL-1135 cosmetic-handover shape.
        assertEq(timelock.getMinDelay(), MIN_DELAY, "timelock minDelay is not the production floor");

        // ── deploy a real series through the timelock ─────────────────────────
        bytes memory deployData = abi.encodeCall(
            factory.deployToken, ("Cap Bond", "cBOND", "US912797KR72", 0, operator, address(issuanceMgr), navOwner)
        );
        bytes32 deploySalt = bytes32(uint256(0xDEB7));
        // LITERAL timestamps throughout — this test reads `block.timestamp` nowhere.
        // A local initialised from `block.timestamp` is materialised at the optimiser's
        // convenience, so one cached across a vm.warp silently takes the WARPED value:
        // `uint256 t0 = block.timestamp` here read 172801 rather than 1, pushing readyAt
        // a full window late and making the "one second early" execute succeed. Same
        // hazard already recorded at KaleidoscopeNAVFeed.t.sol:338 and
        // AtomicSettlementDeploy.t.sol:428. Every boundary below is a timestamp
        // comparison, so that failure mode is fail-OPEN and must not be reintroduced.
        vm.warp(T0);
        vm.prank(multisig);
        timelock.schedule(address(factory), 0, deployData, bytes32(0), deploySalt, MIN_DELAY);
        vm.warp(T0 + MIN_DELAY);
        vm.recordLogs();
        vm.prank(multisig);
        timelock.execute(address(factory), 0, deployData, bytes32(0), deploySalt);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address series;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("TokenDeployed(address,address,bytes32,address,address,string)")) {
                series = address(uint160(uint256(logs[i].topics[1])));
                break;
            }
        }
        assertTrue(series != address(0), "TokenDeployed event not found");
        assertTrue(issuanceMgr.registeredTokens(series), "series was not registered with the manager");

        // ── the cap change itself ─────────────────────────────────────────────
        bytes32 adminRole = issuanceMgr.DEFAULT_ADMIN_ROLE();
        uint256 defaultCap = issuanceMgr.DEFAULT_DAILY_CAP();
        uint256 raised = defaultCap * 5;

        // Production topology: the timelock is the ONLY admin.
        issuanceMgr.grantRole(adminRole, address(timelock));
        issuanceMgr.revokeRole(adminRole, address(this));
        assertFalse(issuanceMgr.hasRole(adminRole, address(this)), "deployer kept DEFAULT_ADMIN after handover");
        assertEq(issuanceMgr.dailyCap(series), defaultCap, "series did not start at the default cap");

        // Nobody raises it directly — not the revoked deployer, not an outsider, and not
        // the governance multisig either. Holding PROPOSER_ROLE buys the right to
        // propose, nothing more.
        //
        // The deployer line is load-bearing: without it this test still passes when the
        // handover forgets to revoke, because the other two callers never held the role
        // in the first place. That is the cosmetic-handover shape GYL-1135 shipped.
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", address(this), adminRole)
        );
        issuanceMgr.setDailyCap(series, raised);

        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", outsider, adminRole)
        );
        issuanceMgr.setDailyCap(series, raised);

        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSignature("AccessControlUnauthorizedAccount(address,bytes32)", multisig, adminRole)
        );
        issuanceMgr.setDailyCap(series, raised);

        // The timelock itself refuses to schedule below its own floor.
        bytes memory data = abi.encodeCall(IssuanceManager.setDailyCap, (series, raised));
        vm.prank(multisig);
        vm.expectRevert();
        timelock.schedule(address(issuanceMgr), 0, data, bytes32(0), bytes32(uint256(0xCA8)), MIN_DELAY - 1);

        bytes32 salt = bytes32(uint256(0xCA9));
        vm.prank(multisig);
        timelock.schedule(address(issuanceMgr), 0, data, bytes32(0), salt, MIN_DELAY);
        uint256 readyAt = T0 + MIN_DELAY + MIN_DELAY; // scheduled at T0 + MIN_DELAY

        // Scheduling is a public announcement, not a change.
        assertEq(issuanceMgr.dailyCap(series), defaultCap, "cap moved at schedule time");

        // Not executable immediately...
        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(issuanceMgr), 0, data, bytes32(0), salt);

        // ...nor one second short of the full 48 hours.
        vm.warp(readyAt - 1);
        vm.prank(multisig);
        vm.expectRevert();
        timelock.execute(address(issuanceMgr), 0, data, bytes32(0), salt);
        assertEq(issuanceMgr.dailyCap(series), defaultCap, "cap moved before the delay elapsed");

        // At readyAt exactly (OZ compares with <=) it lands.
        vm.warp(readyAt);
        vm.prank(multisig);
        timelock.execute(address(issuanceMgr), 0, data, bytes32(0), salt);
        assertEq(issuanceMgr.dailyCap(series), raised, "cap did not land after the delay");
    }
}
