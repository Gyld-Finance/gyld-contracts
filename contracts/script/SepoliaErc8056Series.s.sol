// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title SepoliaErc8056Series
/// @notice Deploys a THROWAWAY bond series on Sepolia for ERC-8056 + atomic-swap
///         integrator testing, then upgrades its token proxy to the ERC-8056
///         (Scaled UI Amount) implementation. The existing Kaleidoscope-integrated
///         series (TOKEN_C / TOKEN_CAT / TOKEN_KO) are never touched.
///
///         The TokenFactory is owned by the Sepolia TimelockController
///         (minDelay = 0, open EXECUTOR_ROLE), so factory.deployToken, the UUPS
///         upgrade and the UI_MULTIPLIER_ROLE grant are all routed through
///         schedule+execute timelock batches from the PROPOSER key ($PRIVKEY).
///
/// ── CHAIN GUARD (added on review) ────────────────────────────────────────────
/// This script is pinned to Sepolia (11155111) and nothing else. It was written
/// with NO chain guard at all, which made a "Sepolia" script that would happily
/// broadcast to any chain whose FACTORY/TIMELOCK env vars happened to be set —
/// exactly the denylist-vs-allowlist defect {DeployGuards} exists to prevent. A
/// dry run on Anvil is deliberately NOT permitted either: every step depends on
/// pre-existing live Sepolia infrastructure (an already-deployed factory owned by
/// an already-deployed delay-0 timelock), so an Anvil run could only ever fail
/// half-way and leave a partially-configured series behind.
///
/// ── The `require`s below are SIMULATION-time assertions ──────────────────────
/// `forge script` executes `run()` against a simulated fork, collects the
/// state-changing calls, and only then broadcasts them. Every `require` therefore
/// asserts the SIMULATED outcome; it is a pre-flight gate, not on-chain
/// verification. After a broadcast, re-read the values with `cast call` against
/// the live node before trusting them.
///
/// Env:  PRIVKEY           proposer/deployer key (passed via --private-key)
///       DEPLOYER          address of PRIVKEY — token operator, navFeed owner and
///                         UI_MULTIPLIER_ROLE holder for this throwaway series
///       FACTORY           live Sepolia TokenFactory
///       TIMELOCK          live Sepolia TimelockController (factory owner, minDelay 0)
///       ISSUANCE_MANAGER  live Sepolia IssuanceManager (gets MINTER/BURNER)
///       ISIN / NAME / SYMBOL / MATURITY   optional; throwaway defaults provided
///
/// Run:  source .env && forge script contracts/script/SepoliaErc8056Series.s.sol \
///         --rpc-url $RPC --broadcast --private-key $PRIVKEY
contract SepoliaErc8056Series is Script {
    /// ERC-1967 implementation slot — read directly so the upgrade is verified against
    /// proxy STORAGE rather than against a getter the new implementation supplies itself.
    bytes32 private constant _IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function run() external {
        require(
            block.chainid == DeployGuards.SEPOLIA_CHAIN_ID,
            "SepoliaErc8056Series: Sepolia (chainId 11155111) only"
        );

        TokenFactory factory = TokenFactory(vm.envAddress("FACTORY"));
        TimelockController timelock = TimelockController(payable(vm.envAddress("TIMELOCK")));
        address issuanceManager = vm.envAddress("ISSUANCE_MANAGER");
        address deployer = vm.envAddress("DEPLOYER");

        string memory isin = vm.envOr("ISIN", string("TEST8056A00001"));
        string memory name_ = vm.envOr("NAME", string("Gyld Test Bond 8056"));
        string memory symbol = vm.envOr("SYMBOL", string("GTB8056"));
        uint256 maturity = vm.envOr("MATURITY", uint256(1867420800)); // 2028-01-01

        // ── Pre-flight: fail before spending gas, with a readable reason ──────
        // Every one of these was an unchecked assumption in the original script.
        require(deployer == DeployGuards.broadcaster(), "DEPLOYER does not match the broadcasting key");
        require(factory.owner() == address(timelock), "TIMELOCK is not the factory owner");
        require(timelock.getMinDelay() == 0, "timelock minDelay != 0: this script schedules+executes in one run");
        require(
            timelock.hasRole(DeployGuards.PROPOSER_ROLE, deployer), "deployer lacks PROPOSER_ROLE on the timelock"
        );
        require(
            timelock.hasRole(keccak256("EXECUTOR_ROLE"), deployer)
                || timelock.hasRole(keccak256("EXECUTOR_ROLE"), address(0)),
            "deployer cannot execute on the timelock (EXECUTOR_ROLE is neither open nor granted)"
        );

        vm.startBroadcast();

        // 1. New implementation carrying the ERC-8056 extension.
        GyldBondToken newImpl = new GyldBondToken();
        console.log("NEW_BOND_IMPL=%s", address(newImpl));

        // 2. Deterministic proxy address (salt = ISIN + chainId), then deploy the
        //    series via the factory THROUGH the timelock (factory owner).
        address predicted = factory.predictTokenAddress(name_, symbol, isin, maturity);
        require(predicted.code.length == 0, "ISIN already deployed");
        _timelock(
            timelock,
            address(factory),
            abi.encodeCall(
                TokenFactory.deployToken, (name_, symbol, isin, maturity, deployer, issuanceManager, deployer)
            ),
            // Salts are derived from the ISIN so a second run with a different ISIN
            // does not collide with this run's timelock operation ids.
            keccak256(abi.encodePacked("deploy:", isin))
        );
        require(predicted.code.length != 0, "series deploy failed");
        console.log("TEST_TOKEN=%s", predicted);
        console.log("TEST_NAVFEED=%s", factory.navFeedOf(predicted));
        console.log("TEST_FORWARDER=%s", factory.forwarderOf(predicted));

        // 3. Upgrade the new proxy to the ERC-8056 implementation (admin = timelock,
        //    assigned by TokenFactory._wireRoles from factory.owner()).
        //    Bare upgradeToAndCall(impl, "") is sufficient: _uiMultiplierState()
        //    normalises the never-written multiplier slots to 1.0x (spec F-1/F-2).
        //    Verified against a real pre-ERC-8056 proxy on Anvil — see
        //    docs/anvil-verification-erc8056-2026-07-31.md section 1.
        address implBefore = address(uint160(uint256(vm.load(predicted, _IMPL_SLOT))));
        _timelock(
            timelock,
            predicted,
            abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(newImpl), bytes("")),
            keccak256(abi.encodePacked("upgrade:", isin))
        );
        // Assert against the proxy's own ERC-1967 slot, not a getter.
        require(
            address(uint160(uint256(vm.load(predicted, _IMPL_SLOT)))) == address(newImpl),
            "upgrade did not move the ERC-1967 implementation slot"
        );
        console.log("IMPL_BEFORE=%s", implBefore);
        console.log("IMPL_AFTER=%s", address(newImpl));

        // 4. Grant UI_MULTIPLIER_ROLE to the deployer (test-only wiring; production
        //    wires this in DeployDevNet from the UI_MULTIPLIER_ADMIN env var).
        _timelock(
            timelock,
            predicted,
            abi.encodeWithSignature("grantRole(bytes32,address)", keccak256("UI_MULTIPLIER_ROLE"), deployer),
            keccak256(abi.encodePacked("uirole:", isin))
        );

        // 5. Push the first NAV ($100.00, 8dp) so the swap's NAV band is live.
        //    Deployer is navFeedOwner (step 2 wiring).
        KaleidoscopeNAVFeed(factory.navFeedOf(predicted)).updateAnswer(100e8);
        console.log("NAV pushed: 100.00 (8dp)");

        // 6. Verify ERC-8056 conformance on the live proxy.
        GyldBondToken token = GyldBondToken(predicted);
        require(token.supportsInterface(0xa60bf13d), "IScaledUIAmount not advertised");
        require(token.supportsInterface(0x4bd27648), "IScaledUIAmountNewUIMultiplier not advertised");
        require(token.supportsInterface(0x57854fc3), "IScaledUIAmountConversion not advertised");
        require(token.supportsInterface(0xd890fd71), "IScaledUIAmountBalances not advertised");
        require(token.uiMultiplier() == 1e18, "uiMultiplier != 1.0x after upgrade");
        require(token.newUIMultiplier() == 1e18, "newUIMultiplier != 1.0x after upgrade");
        require(token.effectiveAt() == 0, "effectiveAt != 0 sentinel");
        require(token.hasRole(keccak256("UI_MULTIPLIER_ROLE"), deployer), "UI_MULTIPLIER_ROLE grant did not land");
        require(
            token.hasRole(0x00, address(timelock)), "timelock does not hold DEFAULT_ADMIN_ROLE on the new series"
        );
        console.log("ERC-8056 verified on Sepolia: all 4 ERC-165 ids, multiplier 1.0x");

        vm.stopBroadcast();

        console.log("");
        console.log("Re-verify on the LIVE node (the asserts above are simulation-time only):");
        console.log("  cast call %s 'uiMultiplier()(uint256)' --rpc-url $RPC", predicted);
        console.log("  cast call %s 'supportsInterface(bytes4)(bool)' 0x4bd27648 --rpc-url $RPC", predicted);
    }

    /// @dev schedule + execute a single call through the delay-0 testnet timelock.
    ///      `salt` must be unique per (target, data) pair or `schedule` reverts with
    ///      an already-scheduled operation id.
    function _timelock(TimelockController tl, address target, bytes memory data, bytes32 salt) internal {
        tl.schedule(target, 0, data, bytes32(0), salt, 0);
        tl.execute(target, 0, data, bytes32(0), salt);
    }
}
