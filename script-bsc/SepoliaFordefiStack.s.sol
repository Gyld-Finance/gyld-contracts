// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {console} from "forge-std/Script.sol";
import {BscFordefiStack} from "./BscFordefiStack.s.sol";
import {DeployGuards} from "../contracts/script/lib/DeployGuards.sol";
import {IssuanceManager} from "../contracts/IssuanceManager.sol";
import {MockUSDC} from "../contracts/test/MockUSDC.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title SepoliaFordefiStack
/// @notice The GLD-978 hybrid (KMS deployer + one Fordefi vault per role) on Ethereum Sepolia
///         (11155111) for the UAT environment. Same role layout, sub-phases, replay and
///         verify() as BscFordefiStack; only the per-chain config differs:
///
///   - cash leg: a fresh MockUSDC (6 dp, mint() open to anyone), deployed by runA0 at a
///     CREATE2 address, so a re-run finds it;
///   - timelock: TIMELOCK_DELAY_SECONDS, default and floor 300 s, cap 7 d;
///   - sanctions: SanctionsOracleMirror with no forwarding oracle (Chainalysis has none on
///     Sepolia), seeded with a synthetic SANCTIONS_PROBE_FLAGGED by the Blocklist Updater;
///   - ONE starter series from BOND_0_* and NAV_ANSWER_8DP_<TAG> (later series through the
///     platform's admin panel).
///
/// Sepolia is a DEV chain in the audited DeployGuards, so DeployDevNet and
/// DeployAtomicSettlement skip their production-only checks there and DeployDevNet
/// whitelists Anvil account[1] (a public key). This script makes up for it without touching
/// contracts/: the delay floor above, run C4 removes Anvil account[1] from the whitelist,
/// and verify() checks every role holder (as on BSC) plus that removal.
///
///   runA0()  KMS      MockUSDC (prints CASH_TOKEN)
///   runA1()..runC4(), verify(): as BscFordefiStack. Runbook: docs/deploy/sepolia-uat.md.
///
/// Env: script-bsc/fordefi-roles.sepolia-uat.env, FORDEFI_GOVERNANCE_SIG (signed on Sepolia),
/// DEPLOY_SALT_TAG (unique: DEV already has a stack on Sepolia), SANCTIONS_PROBE_FLAGGED,
/// BOND_0_*, NAV_ANSWER_8DP_<TAG>, TIMELOCK_DELAY_SECONDS (optional).
contract SepoliaFordefiStack is BscFordefiStack {
    uint256 internal constant SEPOLIA = 11_155_111;
    uint256 internal constant MIN_UAT_TIMELOCK_DELAY = 5 minutes;
    uint8 internal constant UAT_CASH_DECIMALS = 6;
    uint256 internal constant UAT_N_SERIES = 1;

    function _requireChain() internal view override {
        require(block.chainid == SEPOLIA, "SepoliaFordefiStack: Ethereum Sepolia (11155111) only");
        // CREATE2 addresses depend on the tag; DEV's Sepolia stack used none.
        require(bytes(DeployGuards.saltTag()).length != 0, "SepoliaFordefiStack: set DEPLOY_SALT_TAG (DEV already has a Sepolia stack)");
    }

    /// The UAT cash leg, deployed by the KMS deployer.
    function runA0() external {
        Roles memory r = _kmsStep();
        if (_mockUsdc().code.length == 0) {
            vm.broadcast(r.deployer);
            new MockUSDC{salt: DeployGuards.vacantSalt("SepoliaFordefiStack:MockUSDC", type(MockUSDC).creationCode)}();
        }
        console.log("=== run A0 done ===");
        _kv("CASH_TOKEN", _mockUsdc());
    }

    function _mockUsdc() internal view returns (address) {
        return DeployGuards.predictCreate2(
            DeployGuards.saltFor("SepoliaFordefiStack:MockUSDC"), keccak256(type(MockUSDC).creationCode)
        );
    }

    function _cash() internal view override returns (address c) {
        c = _mockUsdc();
        require(c.code.length != 0, "SepoliaFordefiStack: MockUSDC not deployed (run A0)");
        require(IERC20Metadata(c).decimals() == UAT_CASH_DECIMALS, "SepoliaFordefiStack: cash token is not 6 decimals");
    }

    function _cashDecimals() internal pure override returns (uint8) {
        return UAT_CASH_DECIMALS;
    }

    /// TIMELOCK_DELAY_SECONDS, default and floor 300 s (DeployGuards has no floor on a dev
    /// chain, and 0 would make the timelock a rubber stamp), cap 7 d.
    function _timelockDelay() internal view override returns (uint256 d) {
        d = vm.envOr("TIMELOCK_DELAY_SECONDS", MIN_UAT_TIMELOCK_DELAY);
        require(d >= MIN_UAT_TIMELOCK_DELAY, "SepoliaFordefiStack: TIMELOCK_DELAY_SECONDS below 300 s");
        require(d <= MAX_TIMELOCK_DELAY, "SepoliaFordefiStack: TIMELOCK_DELAY_SECONDS above 7 days (604800) - a typo?");
    }

    function _nSeries() internal pure override returns (uint256) {
        return UAT_N_SERIES;
    }

    function _bond(uint256 i) internal view override returns (Bond memory) {
        return _envBond(i);
    }

    function _envConfig() internal pure override returns (bool) {
        return true;
    }

    /// DeployDevNet whitelists Anvil account[1] on a dev chain; its key is public.
    function _afterWhitelistSwap(Roles memory r, IssuanceManager im) internal override {
        if (!im.whitelisted(DeployGuards.ANVIL_ACCOUNT_1)) return;
        vm.broadcast(r.whitelistAdmin);
        im.removeFromWhitelist(DeployGuards.ANVIL_ACCOUNT_1);
    }

    function _verifyExtra(IssuanceManager im) internal override {
        _check(!im.whitelisted(DeployGuards.ANVIL_ACCOUNT_1), "Anvil account[1] (public key) not whitelisted");
    }
}
