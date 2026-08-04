// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ScriptRevertAsserts} from "./ScriptRevertAsserts.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DeployGuards} from "../script/lib/DeployGuards.sol";
import {DeployDevNet} from "../script/DeployDevNet.s.sol";
import {DeployTimelock} from "../script/DeployTimelock.s.sol";
import {DeployAtomicSettlement} from "../script/DeployAtomicSettlement.s.sol";
import {DeployNAVFeed} from "../script/DeployNAVFeed.s.sol";
import {DeployMockSanctionsList} from "../script/DeployMockSanctionsList.s.sol";

import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {SanctionsOracleMirror} from "../SanctionsOracleMirror.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @dev External wrapper around the library.
///
/// {DeployGuards.isDevChain} reads `block.chainid`, and CHAINID is a pure opcode that
/// solc's optimizer common-subexpression-eliminates across a whole function body. Calling
/// the inlined internal function repeatedly after `vm.chainId(...)` would therefore keep
/// returning the FIRST chain's answer. Going through an external call forces a fresh read.
contract GuardsHarness {
    function isDevChain() external view returns (bool) {
        return DeployGuards.isDevChain();
    }

    function saltFor(string memory name) external view returns (bytes32) {
        return DeployGuards.saltFor(name);
    }
}

/// @title DeployGuardsTest
/// @notice Pure guard-library semantics. Touches no environment variables, so unlike
///         {DeployScriptsTest} it is safe to split into as many test functions as useful.
contract DeployGuardsTest is Test {
    GuardsHarness harness;

    function setUp() public {
        harness = new GuardsHarness();
    }

    /// Catches the root cause of the whole ticket.
    ///
    /// Every "mainnet protection" guard in the scripts was `require(block.chainid != 1)`.
    /// Base — the chain the incident happened on — is 8453, so it walked straight through,
    /// as does every other L2 and every chain that does not exist yet. The replacement is
    /// an ALLOWLIST: an unrecognised chain is production and gets the strict path.
    function test_isDevChain_isAnAllowlist_notADenylist() public {
        assertTrue(_isDev(31337), "Anvil must be a dev chain");
        assertTrue(_isDev(11155111), "Sepolia must be a dev chain");

        // The old `chainid != 1` denylist classified every one of these as "not mainnet".
        uint256[7] memory production =
            [uint256(1), 8453, 42161, 10, 137, 84532, 999_999_999];
        for (uint256 i = 0; i < production.length; i++) {
            assertFalse(
                _isDev(production[i]),
                string.concat("chainId ", vm.toString(production[i]), " must be treated as production")
            );
        }
    }

    /// Catches: the same bootstrap contract landing on the SAME address on two chains.
    /// Plain CREATE addresses are `keccak(deployer, nonce)` — no chain component at all,
    /// which is why `0x7c1798…70ad` is a live GyldBondToken on Base and a
    /// MockSanctionsList on Sepolia. The salt now carries `block.chainid`.
    function test_saltFor_isChainScoped() public {
        string[6] memory names = [
            "DeployDevNet:TimelockController",
            "DeployDevNet:IssuanceManager.impl",
            "DeployDevNet:IssuanceManager.proxy",
            "DeployDevNet:GyldBondToken.impl",
            "DeployDevNet:MockSanctionsList",
            // The last bootstrap contract to move off plain CREATE (GYL-1135): its
            // constructor was `Ownable(msg.sender)`, so CREATE2 would have made the
            // canonical proxy its owner until `owner_` became an explicit parameter.
            "DeployDevNet:TokenFactory"
        ];
        for (uint256 i = 0; i < names.length; i++) {
            vm.chainId(8453);
            bytes32 onBase = harness.saltFor(names[i]);
            vm.chainId(11155111);
            bytes32 onSepolia = harness.saltFor(names[i]);
            vm.chainId(31337);
            bytes32 onAnvil = harness.saltFor(names[i]);

            assertTrue(onBase != onSepolia, string.concat("Base/Sepolia salt collision: ", names[i]));
            assertTrue(onBase != onAnvil, string.concat("Base/Anvil salt collision: ", names[i]));
            assertTrue(onSepolia != onAnvil, string.concat("Sepolia/Anvil salt collision: ", names[i]));
        }
    }

    /// Two DIFFERENT contracts must never share a salt, or the second deploy on a chain
    /// would silently target the first one's address.
    function test_saltFor_isUniquePerContractName() public {
        vm.chainId(8453);
        assertTrue(
            harness.saltFor("DeployDevNet:TimelockController") != harness.saltFor("DeployDevNet:GyldBondToken.impl"),
            "distinct contracts share a salt"
        );
    }

    function _isDev(uint256 chainId) internal returns (bool) {
        vm.chainId(chainId);
        return harness.isDevChain();
    }
}

/// @title DeployScriptsTest
/// @notice Executes the deploy scripts themselves — nothing in the suite did before.
///
/// Every scenario below is calibrated against THE CONFIGURATION THAT IS LIVE ON BASE
/// MAINNET TODAY (GYL-1135): a TimelockController with `delay = 0` whose sole proposer is
/// the deployer EOA, and `IssuanceManager.initialize(deployer, deployer, deployer)` with
/// no hand-over at all. Each `_reject…` scenario feeds the scripts one slice of that
/// configuration and asserts they now refuse to deploy it.
///
/// ── Why this is ONE test function ─────────────────────────────────────────────
/// `forge test` (1.5.x) executes the test functions of a suite IN PARALLEL, while
/// `vm.setEnv` mutates process-global state that every thread shares. Splitting these
/// scenarios into separate test functions makes them race: one test blanks
/// `GOVERNANCE_MULTISIG` while another is mid-`run()` expecting it set, and the suite
/// fails a different subset on every invocation. They are therefore driven sequentially
/// from a single entry point, with `vm.snapshotState` / `vm.revertToState` isolating EVM
/// state between scenarios (also required because two successful runs on one chain would
/// otherwise collide at the same deterministic CREATE2 addresses). Guard behaviour that
/// needs no environment variables lives in {DeployGuardsTest} above, split normally.
///
/// ── How a `forge script` runs inside `forge test` ─────────────────────────────
/// `vm.startBroadcast()` executes as `tx.origin` (DEFAULT_SENDER) while `msg.sender`
/// inside `run()` is this test contract; under a real `forge script` the two are the same
/// account. That is why the scripts identify the deployer via {DeployGuards.broadcaster}
/// (`tx.origin`). Foundry also rewrites CREATE2 to the canonical `0x4e59…4956C` proxy here
/// exactly as it does when broadcasting, so the deterministic addressing below is the real
/// production scheme rather than a test-only approximation.
contract DeployScriptsTest is ScriptRevertAsserts {
    uint256 constant BASE = 8453; // the chain the incident happened on
    uint256 constant SEPOLIA = 11155111;
    uint256 constant ANVIL = 31337;

    // Distinct production role holders — none of them the deployer.
    address constant GOVERNANCE = address(0x60E1);
    address constant OPS = address(0x0B5);
    address constant SUBSCRIBER = address(0x5BC1);
    address constant REDEEMER = address(0xEDEE);
    address constant WHITELIST_ADMIN = address(0x117E);
    address constant NAV_OWNER = address(0x0AC1);
    address constant TREASURER = address(0x77EA);
    address constant QUOTE_SIGNER = address(0x519E);
    address constant ALLOWLIST_ADMIN = address(0xA110);
    address constant WITHDRAWAL = address(0x7DA5);

    /// The dev mock. Production scenarios must REFUSE this contract as SANCTIONS_LIST.
    MockSanctionsList sanctions;
    /// The real production oracle (GYL-1051) — what a production run must be given.
    SanctionsOracleMirror prodOracle;
    MockUSDC usdc;
    uint256 snap;

    function setUp() public {
        // TimelockController treats timestamp 1 as its "done" sentinel, and forge starts
        // tests at timestamp 1, so a delay-0 schedule+execute would look already-executed.
        vm.warp(1_750_000_000);
        sanctions = new MockSanctionsList(address(this));
        prodOracle = new SanctionsOracleMirror(GOVERNANCE, OPS, address(0));
        usdc = new MockUSDC();
    }

    /// Single entry point — see the contract-level note on why these are not separate
    /// test functions. Each scenario restores EVM state before the next one starts.
    function test_deployScripts_rejectTheLiveBaseConfiguration() public {
        snap = vm.snapshotState();

        // ── DeployDevNet ──────────────────────────────────────────────────────
        _run(this.reject_devNet_unsetGovernanceMultisig);
        _run(this.reject_devNet_governanceIsTheDeployer);
        _run(this.reject_devNet_zeroTimelockDelayOnBase);
        _run(this.reject_devNet_unsetTimelockDelayOnBase);
        _run(this.reject_devNet_unsetSanctionsListOnBase);
        _run(this.reject_devNet_sanctionsListWithoutCode);
        _run(this.reject_devNet_sanctionsListIsADevMock);
        _run(this.reject_devNet_subscriberEqualsRedeemer);
        _run(this.accept_devNet_productionHappyPath);
        _run(this.accept_devNet_anvilDevPathStillWorks);
        _run(this.accept_devNet_everySeriesTokenAdminIsTheTimelock);
        _run(this.accept_bootstrapAddressesDifferAcrossChains);

        // ── DeployTimelock ────────────────────────────────────────────────────
        _run(this.reject_timelock_unsetIssuanceManagerOnProd);
        _run(this.reject_timelock_zeroDelayOnBase);
        _run(this.reject_timelock_multisigIsTheDeployer);
        _run(this.accept_timelock_productionHappyPath);

        // ── DeployAtomicSettlement ────────────────────────────────────────────
        _run(this.reject_atomic_unsetTimelockOnProd);
        _run(this.reject_atomic_treasurerIsTheDeployer);
        _run(this.reject_atomic_cosmeticZeroDelayTimelock);
        _run(this.reject_atomic_deployerIsSoleProposer);
        _run(this.accept_atomic_productionHappyPath);

        // ── DeployNAVFeed ─────────────────────────────────────────────────────
        _run(this.reject_navFeed_forwarderOwnerIsAnEoa);
        _run(this.reject_navFeed_unsetForwarderOwnerOnProd);
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  DeployDevNet
    // ══════════════════════════════════════════════════════════════════════════

    /// Catches: the deployer silently becoming governance because the var was never
    /// exported. `_envOrDefault("GOVERNANCE_MULTISIG", msg.sender)` made an unset var
    /// indistinguishable from "the deployer is governance".
    function reject_devNet_unsetGovernanceMultisig() external {
        vm.chainId(BASE);
        _devNetProdEnv();
        vm.setEnv("GOVERNANCE_MULTISIG", "");
        _expectRunRevert(address(new DeployDevNet()), "env var GOVERNANCE_MULTISIG is required on chainId 8453");
    }

    /// Catches: the exact live Base topology — a privileged role pointed at the
    /// broadcaster. Setting the var is not enough; it must not name the deployer.
    function reject_devNet_governanceIsTheDeployer() external {
        vm.chainId(BASE);
        _devNetProdEnv();
        _setAddr("GOVERNANCE_MULTISIG", DEFAULT_SENDER);
        _expectRunRevert(address(new DeployDevNet()), "GOVERNANCE_MULTISIG must not be the deployer EOA");
    }

    /// Catches: `TIMELOCK_DELAY_SECONDS=0` on a production chain — the single value that
    /// turned the live Base timelock into a rubber stamp, and what `.env.example` shipped
    /// on line 2. The old guard (`block.chainid == 31337 ? 0 : 172800`) had no floor at all.
    function reject_devNet_zeroTimelockDelayOnBase() external {
        vm.chainId(BASE);
        _devNetProdEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        _expectRunRevert(
            address(new DeployDevNet()),
            "TIMELOCK_DELAY_SECONDS=0 is below the 172800s (48h) minimum on production chainId 8453"
        );
    }

    /// Catches: relying on an implicit default for the delay on production.
    function reject_devNet_unsetTimelockDelayOnBase() external {
        vm.chainId(BASE);
        _devNetProdEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "");
        _expectRunRevert(address(new DeployDevNet()), "env var TIMELOCK_DELAY_SECONDS is required");
    }

    /// Catches: deploying a WRITABLE MockSanctionsList as the compliance oracle on a
    /// production chain. The old guard was `require(block.chainid != 1)`, so on Base this
    /// would have wired in a mock that screens nobody.
    function reject_devNet_unsetSanctionsListOnBase() external {
        vm.chainId(BASE);
        _devNetProdEnv();
        vm.setEnv("SANCTIONS_LIST", "");
        _expectRunRevert(address(new DeployDevNet()), "env var SANCTIONS_LIST is required on chainId 8453");
    }

    /// Catches: a sanctions oracle that is an EOA or a typo'd address with no code —
    /// every `isSanctioned` staticcall against it fails or returns nothing.
    function reject_devNet_sanctionsListWithoutCode() external {
        vm.chainId(BASE);
        _devNetProdEnv();
        _setAddr("SANCTIONS_LIST", address(0xDEAD));
        _expectRunRevert(address(new DeployDevNet()), "SANCTIONS_LIST (0x000000000000000000000000000000000000dEaD) has no code");
    }

    /// Catches: an ALREADY-DEPLOYED dev mock handed to a production run as SANCTIONS_LIST.
    ///
    /// `requireProdContract` only proves `code.length != 0`, which a MockSanctionsList
    /// satisfies — so before {DeployGuards.requireProdNotMock} the whole production path
    /// accepted a writable fake oracle as long as it was already on chain (and
    /// `DeployMockSanctionsList.s.sol` had no chain guard at all, so putting one there was
    /// a single unguarded `forge script` away). Screening is fail-closed in GyldBondToken,
    /// so whoever can write that list can freeze every holder of every series.
    function reject_devNet_sanctionsListIsADevMock() external {
        vm.chainId(BASE);
        _devNetProdEnv();
        _setAddr("SANCTIONS_LIST", address(sanctions));
        _expectRunRevert(
            address(new DeployDevNet()),
            "is a DEV MOCK whose sanctions list is writable - it must never be used on production chainId 8453"
        );
    }

    /// Catches: collapsing the deliberate mint/burn two-key quorum into one address.
    function reject_devNet_subscriberEqualsRedeemer() external {
        vm.chainId(BASE);
        _devNetProdEnv();
        _setAddr("REDEEMER_ADDRESS", SUBSCRIBER);
        _expectRunRevert(
            address(new DeployDevNet()),
            "SUBSCRIBER_ADDRESS and REDEEMER_ADDRESS must be different addresses on production"
        );
    }

    /// Every bond series this run deploys must leave DEFAULT_ADMIN_ROLE with the timelock
    /// and NOT with the broadcaster — the per-token form of the Base-incident property
    /// (the other scenarios in this file assert it for IssuanceManager and the swap, but
    /// this is the only place it is checked on the tokens themselves).
    ///
    /// Asserted on Anvil because that is the only path where the delay-0 factory hand-off
    /// completes inside a single run and the series are actually deployed.
    function accept_devNet_everySeriesTokenAdminIsTheTimelock() external {
        vm.chainId(ANVIL);
        _clearEnv();

        DeployDevNet script = new DeployDevNet();
        script.run();

        assertEq(script.bondTokenCount(), 3, "expected the three dev series to be deployed");
        for (uint256 i = 0; i < script.bondTokenCount(); i++) {
            GyldBondToken t = GyldBondToken(script.bondTokens(i));
            assertTrue(t.hasRole(bytes32(0), address(script.timelock())), "timelock is not the token admin");
            assertFalse(t.hasRole(bytes32(0), DEFAULT_SENDER), "deployer kept DEFAULT_ADMIN on a series");
        }
    }

    /// The production happy path. Asserts the property the incident violated: when the
    /// script finishes, the deployer holds NOTHING, the timelock is a real 48h gate the
    /// deployer cannot propose through, and the publicly-known Anvil key is not an AP.
    function accept_devNet_productionHappyPath() external {
        vm.chainId(BASE);
        _devNetProdEnv();

        DeployDevNet script = new DeployDevNet();
        script.run();

        IssuanceManager im = script.issuanceMgr();
        TimelockController tl = script.timelock();

        assertTrue(im.hasRole(im.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock is not IssuanceManager admin");
        assertFalse(im.hasRole(im.DEFAULT_ADMIN_ROLE(), DEFAULT_SENDER), "deployer kept DEFAULT_ADMIN");
        assertFalse(im.hasRole(im.WHITELIST_ADMIN_ROLE(), DEFAULT_SENDER), "deployer kept WHITELIST_ADMIN");
        assertFalse(im.hasRole(im.SUBSCRIBER_ROLE(), DEFAULT_SENDER), "deployer kept SUBSCRIBER_ROLE");
        assertFalse(im.hasRole(im.REDEEMER_ROLE(), DEFAULT_SENDER), "deployer kept REDEEMER_ROLE");
        assertFalse(im.hasRole(im.REGISTRAR_ROLE(), DEFAULT_SENDER), "deployer kept REGISTRAR_ROLE");

        // A timelock that gates nothing is the heart of the incident.
        assertEq(tl.getMinDelay(), 48 hours, "production timelock delay must be 48h");
        assertFalse(tl.hasRole(DeployGuards.PROPOSER_ROLE, DEFAULT_SENDER), "deployer is a timelock proposer");
        assertFalse(tl.hasRole(DeployGuards.CANCELLER_ROLE, DEFAULT_SENDER), "deployer is a timelock canceller");
        assertFalse(tl.hasRole(bytes32(0), DEFAULT_SENDER), "deployer is timelock admin");
        assertTrue(tl.hasRole(DeployGuards.PROPOSER_ROLE, GOVERNANCE), "governance multisig cannot propose");

        // Ownable2Step hand-off is genuinely in flight; the multisig accepts it through
        // the timelock once the delay elapses.
        assertEq(script.factory().pendingOwner(), address(tl), "factory pendingOwner is not the timelock");
        assertFalse(script.factoryOwnershipAccepted(), "a 48h delay cannot be executed inside the deploy");

        // The real oracle was used — no mock deployed — and Anvil account[1], whose
        // private key is printed in the Anvil banner, is not a whitelisted AP.
        assertEq(script.sanctionsOracle(), address(prodOracle), "sanctions oracle mismatch");
        assertFalse(
            im.whitelisted(DeployGuards.ANVIL_ACCOUNT_1),
            "publicly-known Anvil key was whitelisted on a production chain"
        );
    }

    /// Regression: hardening production is worthless if it breaks local development.
    /// The zero-config Anvil flow must still deploy end to end.
    function accept_devNet_anvilDevPathStillWorks() external {
        vm.chainId(ANVIL);
        _clearEnv();

        DeployDevNet script = new DeployDevNet();
        script.run();

        assertEq(script.timelockDelay(), 0, "Anvil delay should default to 0");
        assertTrue(script.factoryOwnershipAccepted(), "factory ownership not accepted on Anvil");
        assertEq(script.factory().owner(), address(script.timelock()), "factory owner is not the timelock");
        assertEq(script.factory().pendingOwner(), address(0), "factory still has a pending owner");
        assertTrue(script.issuanceMgr().whitelisted(DeployGuards.ANVIL_ACCOUNT_1), "Anvil acct[1] not whitelisted");
        assertGt(script.sanctionsOracle().code.length, 0, "no mock sanctions oracle deployed");

        // Even on Anvil the deployer does not keep admin — the hand-over is not
        // production-only behaviour that first executes on the day it matters.
        IssuanceManager im = script.issuanceMgr();
        assertFalse(im.hasRole(im.DEFAULT_ADMIN_ROLE(), DEFAULT_SENDER), "deployer kept admin on Anvil");
    }

    /// Catches: identical bootstrap addresses on different chains — the H-3 finding, where
    /// `0x7c1798…70ad` is a MockSanctionsList on Sepolia but a live GyldBondToken on Base,
    /// and `0x18ce55…6317` is a GyldBondToken on Sepolia but a TokenFactory on Base.
    ///
    /// Deployed through the canonical CREATE2 proxy, an address depends ONLY on
    /// (salt, initcode) — the deployer's nonce is irrelevant. The constructor arguments
    /// below are byte-identical across the two runs, so without the `block.chainid` term
    /// in the salt these deployments would land on exactly the same addresses (and the
    /// second run would revert on the collision).
    ///
    /// EVM state is rolled back between the two runs on purpose. That is what reproduces
    /// the real-world shape of the incident: the SAME deployer at the SAME nonce, running
    /// on two chains. Without it a plain-CREATE contract would land on two different
    /// addresses merely because the second script instance sits at a different address,
    /// and the collision this test exists to catch would be invisible — TokenFactory,
    /// which used plain CREATE until GYL-1135, collides here if the salted CREATE2 path
    /// is removed.
    function accept_bootstrapAddressesDifferAcrossChains() external {
        _devNetProdEnv();
        uint256 pristine = vm.snapshotState();

        vm.chainId(BASE);
        DeployDevNet onBase = new DeployDevNet();
        onBase.run();
        address baseScript = address(onBase);
        address baseTimelock = address(onBase.timelock());
        address baseIssuance = address(onBase.issuanceMgr());
        address baseFactory = address(onBase.factory());

        // Rewind everything the Base run touched, including nonces, so the Sepolia run
        // starts from a byte-identical world with only `block.chainid` differing.
        vm.revertToState(pristine);

        vm.chainId(SEPOLIA);
        DeployDevNet onSepolia = new DeployDevNet();
        onSepolia.run();

        // Guard on the premise: if the two runs did not start from the same deployer+nonce
        // the divergence assertions below would pass for the wrong reason.
        assertEq(baseScript, address(onSepolia), "the two runs must model the same deployer at the same nonce");

        assertTrue(baseTimelock != address(onSepolia.timelock()), "TimelockController collides across chains");
        assertTrue(baseIssuance != address(onSepolia.issuanceMgr()), "IssuanceManager proxy collides across chains");
        assertTrue(baseFactory != address(onSepolia.factory()), "TokenFactory collides across chains");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  DeployTimelock
    // ══════════════════════════════════════════════════════════════════════════

    /// Catches: the silent skip. `try vm.envAddress("ISSUANCE_MANAGER_ADDRESS") {} catch {}`
    /// meant a forgotten export left the deployer as the IssuanceManager's sole
    /// DEFAULT_ADMIN while the script still printed "complete".
    function reject_timelock_unsetIssuanceManagerOnProd() external {
        vm.chainId(BASE);
        _timelockProdEnv();
        vm.setEnv("ISSUANCE_MANAGER_ADDRESS", "");
        _expectRunRevert(
            address(new DeployTimelock()), "env var ISSUANCE_MANAGER_ADDRESS is required on chainId 8453"
        );
    }

    /// Catches: `TIMELOCK_DELAY_SECONDS=0` on Base. The old check was
    /// `block.chainid != 1 || d >= 48 hours` — it accepted 0 on every chain except Ethereum.
    function reject_timelock_zeroDelayOnBase() external {
        vm.chainId(BASE);
        _timelockProdEnv();
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");
        _expectRunRevert(
            address(new DeployTimelock()),
            "TIMELOCK_DELAY_SECONDS=0 is below the 172800s (48h) minimum on production chainId 8453"
        );
    }

    /// Catches: a timelock whose only proposer is the deployer — governance in name only.
    function reject_timelock_multisigIsTheDeployer() external {
        vm.chainId(BASE);
        _timelockProdEnv();
        _setAddr("MULTISIG_ADDRESS", DEFAULT_SENDER);
        _expectRunRevert(address(new DeployTimelock()), "MULTISIG_ADDRESS must not be the deployer EOA");
    }

    function accept_timelock_productionHappyPath() external {
        vm.chainId(BASE);
        (TokenFactory factory, IssuanceManager im) = _timelockProdEnv();

        DeployTimelock script = new DeployTimelock();
        script.run();

        TimelockController tl = script.timelock();
        assertEq(tl.getMinDelay(), 48 hours, "delay");
        assertTrue(im.hasRole(im.DEFAULT_ADMIN_ROLE(), address(tl)), "timelock is not IssuanceManager admin");
        assertFalse(im.hasRole(im.DEFAULT_ADMIN_ROLE(), DEFAULT_SENDER), "deployer kept DEFAULT_ADMIN");
        assertEq(factory.pendingOwner(), address(tl), "factory hand-off not started");
        assertFalse(tl.hasRole(DeployGuards.PROPOSER_ROLE, DEFAULT_SENDER), "deployer can propose");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  DeployAtomicSettlement
    // ══════════════════════════════════════════════════════════════════════════

    /// Catches: the silent skip that leaves the deployer permanent DEFAULT_ADMIN of the
    /// contract that HOLDS the settlement inventory. It used to print
    /// "!! TIMELOCK_ADDRESS unset - deployer keeps DEFAULT_ADMIN (dev only)" and continue.
    function reject_atomic_unsetTimelockOnProd() external {
        vm.chainId(BASE);
        _atomicProdEnv();
        vm.setEnv("TIMELOCK_ADDRESS", "");
        _expectRunRevert(
            address(new DeployAtomicSettlement()), "env var TIMELOCK_ADDRESS is required on chainId 8453"
        );
    }

    /// Catches: a privileged swap role pointed back at the broadcaster.
    function reject_atomic_treasurerIsTheDeployer() external {
        vm.chainId(BASE);
        _atomicProdEnv();
        _setAddr("TREASURER_ADDRESS", DEFAULT_SENDER);
        _expectRunRevert(address(new DeployAtomicSettlement()), "TREASURER_ADDRESS must not be the deployer EOA");
    }

    /// Catches the subtlest form of the incident: the hand-over is performed CORRECTLY —
    /// the timelock really does hold DEFAULT_ADMIN and the deployer really was revoked —
    /// but the timelock has `delay = 0` and the deployer is its proposer, so the deployer
    /// can still execute anything instantly. Role-level assertions all pass here; only
    /// {DeployGuards.assertTimelockSane} catches it. This is the live Base timelock.
    function reject_atomic_cosmeticZeroDelayTimelock() external {
        vm.chainId(BASE);
        _atomicProdEnv();
        _setAddr("TIMELOCK_ADDRESS", address(_timelock(0, DEFAULT_SENDER)));
        _expectRunRevert(
            address(new DeployAtomicSettlement()), "minDelay is 0s, below the 172800s (48h) production minimum"
        );
    }

    /// Same shape with a compliant 48h delay but the deployer still holding PROPOSER_ROLE:
    /// the delay alone does not make governance non-unilateral.
    function reject_atomic_deployerIsSoleProposer() external {
        vm.chainId(BASE);
        _atomicProdEnv();
        _setAddr("TIMELOCK_ADDRESS", address(_timelock(48 hours, DEFAULT_SENDER)));
        _expectRunRevert(
            address(new DeployAtomicSettlement()), "holds PROPOSER_ROLE on the timelock - the handover is cosmetic"
        );
    }

    function accept_atomic_productionHappyPath() external {
        vm.chainId(BASE);
        _atomicProdEnv();

        DeployAtomicSettlement script = new DeployAtomicSettlement();
        script.run();

        address swap = address(script.swap());
        assertTrue(_hasRole(swap, bytes32(0), script.timelockAddress()), "timelock is not swap admin");
        assertFalse(_hasRole(swap, bytes32(0), DEFAULT_SENDER), "deployer kept swap DEFAULT_ADMIN");

        // GYL-1050: the KMS allowlist key survives the hand-over; the deployer's transient
        // copy of the same role does not.
        assertTrue(_hasRole(swap, keccak256("ALLOWLIST_ADMIN_ROLE"), ALLOWLIST_ADMIN), "allowlist admin lost its role");
        assertFalse(_hasRole(swap, keccak256("ALLOWLIST_ADMIN_ROLE"), DEFAULT_SENDER), "deployer kept ALLOWLIST_ADMIN");
        assertFalse(_hasRole(swap, keccak256("TREASURER_ROLE"), DEFAULT_SENDER), "deployer kept TREASURER_ROLE");
        assertFalse(_hasRole(swap, keccak256("PAUSER_ROLE"), DEFAULT_SENDER), "deployer kept PAUSER_ROLE");
        assertTrue(_hasRole(swap, keccak256("TREASURER_ROLE"), TREASURER), "treasurer lost TREASURER_ROLE");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  DeployNAVFeed
    // ══════════════════════════════════════════════════════════════════════════

    /// Catches: the forwarder — the permanent address Morpho/Aave read prices from —
    /// owned by a single EOA that can repoint `setUpstreamOracle` at anything it likes.
    function reject_navFeed_forwarderOwnerIsAnEoa() external {
        vm.chainId(BASE);
        _navFeedEnv();
        _setAddr("FORWARDER_OWNER", address(0xB0B));
        _expectRunRevert(
            address(new DeployNAVFeed()), "FORWARDER_OWNER (0x0000000000000000000000000000000000000B0b) has no code"
        );
    }

    /// Catches: FORWARDER_OWNER silently falling back to OPERATOR_ADDRESS (the hot
    /// NAV-pushing key) on a production chain — what `catch { forwarderOwner = operator; }` did.
    function reject_navFeed_unsetForwarderOwnerOnProd() external {
        vm.chainId(BASE);
        _navFeedEnv();
        vm.setEnv("FORWARDER_OWNER", "");
        _expectRunRevert(address(new DeployNAVFeed()), "env var FORWARDER_OWNER is required on chainId 8453");
    }

    // ══════════════════════════════════════════════════════════════════════════
    //  Fixtures
    // ══════════════════════════════════════════════════════════════════════════

    /// Runs one scenario and restores EVM state afterwards, so scenarios cannot leak
    /// contracts into each other or collide at the same deterministic CREATE2 address.
    function _run(function() external scenario) internal {
        scenario();
        // A scenario whose in-band assertion fired reverted INSIDE `vm.startBroadcast()`,
        // so `vm.stopBroadcast()` never ran. Broadcast state is cheatcode state, not EVM
        // state, so `revertToState` does not clear it and the next scenario's prank would
        // fail. Clearing it is best-effort: it reverts when no broadcast is active.
        (bool cleared,) = address(vm).call(abi.encodeWithSignature("stopBroadcast()"));
        cleared;
        vm.revertToState(snap);
    }

    /// Full, valid production environment for DeployDevNet.
    function _devNetProdEnv() internal {
        _clearEnv();
        _setAddr("GOVERNANCE_MULTISIG", GOVERNANCE);
        _setAddr("OPS_MULTISIG", OPS);
        _setAddr("SUBSCRIBER_ADDRESS", SUBSCRIBER);
        _setAddr("REDEEMER_ADDRESS", REDEEMER);
        _setAddr("WHITELIST_ADMIN", WHITELIST_ADMIN);
        _setAddr("NAV_FEED_OWNER", NAV_OWNER);
        _setAddr("SANCTIONS_LIST", address(prodOracle));
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "172800");
    }

    /// Valid production environment for DeployTimelock, with a factory owned by the
    /// deployer and an IssuanceManager whose DEFAULT_ADMIN is the deployer — the
    /// pre-hand-over state this script exists to resolve.
    function _timelockProdEnv() internal returns (TokenFactory factory, IssuanceManager im) {
        _clearEnv();
        vm.startPrank(DEFAULT_SENDER, DEFAULT_SENDER);
        factory = new TokenFactory(address(new GyldBondToken()), address(sanctions), DEFAULT_SENDER);
        im = _issuanceManager();
        vm.stopPrank();

        _setAddr("MULTISIG_ADDRESS", GOVERNANCE);
        _setAddr("EVM_FACTORY_ADDRESS", address(factory));
        _setAddr("ISSUANCE_MANAGER_ADDRESS", address(im));
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "172800");
    }

    /// Valid production environment for DeployAtomicSettlement.
    function _atomicProdEnv() internal {
        _clearEnv();
        vm.startPrank(DEFAULT_SENDER, DEFAULT_SENDER);
        IssuanceManager im = _issuanceManager();
        vm.stopPrank();

        _setAddr("USDC_ADDRESS", address(usdc));
        _setAddr("EVM_ISSUANCE_MANAGER", address(im));
        _setAddr("TIMELOCK_ADDRESS", address(_timelock(48 hours, GOVERNANCE)));
        _setAddr("OPS_MULTISIG", OPS);
        _setAddr("TREASURER_ADDRESS", TREASURER);
        _setAddr("QUOTE_SIGNER", QUOTE_SIGNER);
        _setAddr("ALLOWLIST_ADMIN", ALLOWLIST_ADMIN);
        _setAddr("WITHDRAWAL_WALLET", WITHDRAWAL);
    }

    function _navFeedEnv() internal {
        _clearEnv();
        _setAddr("OPERATOR_ADDRESS", NAV_OWNER);
        vm.setEnv("FEED_DESCRIPTION", "TBA / USD NAV");
    }

    function _issuanceManager() internal returns (IssuanceManager) {
        return IssuanceManager(
            address(
                new ERC1967Proxy(
                    address(new IssuanceManager()),
                    abi.encodeCall(IssuanceManager.initialize, (DEFAULT_SENDER, SUBSCRIBER, REDEEMER))
                )
            )
        );
    }

    function _timelock(uint256 minDelay, address proposer) internal returns (TimelockController) {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        return new TimelockController(minDelay, proposers, executors, address(0));
    }

    /// Every env var any script reads is explicitly blanked. A real `.env` is auto-loaded
    /// from the project root, and an empty value makes `vm.envAddress` / `vm.envUint`
    /// revert — exactly how an unset variable behaves.
    function _clearEnv() internal {
        string[24] memory keys = [
            "GOVERNANCE_MULTISIG",
            "OPS_MULTISIG",
            "SUBSCRIBER_ADDRESS",
            "REDEEMER_ADDRESS",
            "WHITELIST_ADMIN",
            "NAV_FEED_OWNER",
            "SANCTIONS_LIST",
            "TIMELOCK_DELAY_SECONDS",
            "MULTISIG_ADDRESS",
            "EVM_FACTORY_ADDRESS",
            "ISSUANCE_MANAGER_ADDRESS",
            "USDC_ADDRESS",
            "EVM_ISSUANCE_MANAGER",
            "TIMELOCK_ADDRESS",
            "TREASURER_ADDRESS",
            "QUOTE_SIGNER",
            "ALLOWLIST_ADMIN",
            "WITHDRAWAL_WALLET",
            "MAX_QUOTE_DEVIATION_BPS",
            "MAX_NAV_AGE_SECS",
            "SERIES_TOKENS",
            "ALLOWED_TAKERS",
            "OPERATOR_ADDRESS",
            "FORWARDER_OWNER"
        ];
        for (uint256 i = 0; i < keys.length; i++) {
            vm.setEnv(keys[i], "");
        }
        vm.setEnv("FEED_DESCRIPTION", "");
    }

    function _setAddr(string memory key, address value) internal {
        vm.setEnv(key, vm.toString(value));
    }

    function _hasRole(address target, bytes32 role, address account) internal view returns (bool) {
        (bool ok, bytes memory ret) =
            target.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", role, account));
        require(ok, "hasRole staticcall failed");
        return abi.decode(ret, (bool));
    }

    // Revert assertions (_expectRunRevert / _revertReason / _contains) live in
    // {ScriptRevertAsserts}.
}

/// @title DeployMockSanctionsListTest
/// @notice The one script whose entire product is a FAKE compliance oracle.
///
/// It shipped with no chain guard of any kind — not even the `block.chainid != 1` denylist
/// the other scripts had — so `forge script DeployMockSanctionsList --rpc-url <base>` put a
/// writable sanctions oracle on a production chain. Combined with
/// {DeployGuards.requireProdContract}, which can only assert `code.length != 0`, that mock
/// then SATISFIED the production `SANCTIONS_LIST` requirement: a live route straight around
/// the rest of the GYL-1135 hardening. GyldBondToken screening is fail-closed, so anyone
/// able to write that list can freeze transfers for every holder of every series.
///
/// Safe to split into parallel test functions: this script reads no environment variables,
/// so unlike {DeployScriptsTest} there is no process-global state to race on.
contract DeployMockSanctionsListTest is ScriptRevertAsserts {
    /// The guard is an ALLOWLIST, so every chain that is not Anvil/Sepolia is refused —
    /// including chains that do not exist yet (999_999_999 stands in for one).
    function test_run_refusedOnEveryProductionChain() public {
        uint256[7] memory production = [uint256(1), 8453, 56, 42161, 10, 137, 999_999_999];
        for (uint256 i = 0; i < production.length; i++) {
            vm.chainId(production[i]);
            _expectRunRevert(
                address(new DeployMockSanctionsList()),
                string.concat(
                    "deploying a MockSanctionsList (a writable fake compliance oracle) is dev-only",
                    " and is NOT production-safe on chainId ",
                    vm.toString(production[i])
                )
            );
        }
    }

    /// Base Sepolia (84532) is NOT on the dev allowlist — only Anvil and Ethereum Sepolia
    /// are. A near-miss chain id must not slip through.
    function test_run_refusedOnBaseSepolia() public {
        vm.chainId(84532);
        _expectRunRevert(address(new DeployMockSanctionsList()), "is dev-only and is NOT production-safe on chainId 84532");
    }

    /// The dev path still works, and the deployed mock is owned by the broadcaster — not
    /// by whoever calls it. Nobody else can mutate the list.
    function test_run_deploysAnOwnedMockOnADevChain() public {
        vm.chainId(31337);
        DeployMockSanctionsList script = new DeployMockSanctionsList();
        script.run();

        MockSanctionsList mock = script.mock();
        assertGt(address(mock).code.length, 0, "no mock deployed on Anvil");
        assertEq(mock.owner(), DEFAULT_SENDER, "mock owner is not the broadcaster");

        address stranger = address(0xBAD);
        address[] memory addrs = new address[](1);
        addrs[0] = address(0xB0B);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MockSanctionsList.NotOwner.selector, stranger));
        mock.addToSanctionsList(addrs);
    }

    function test_run_deploysOnSepolia() public {
        vm.chainId(11155111);
        DeployMockSanctionsList script = new DeployMockSanctionsList();
        script.run();
        assertGt(address(script.mock()).code.length, 0, "no mock deployed on Sepolia");
    }
}
