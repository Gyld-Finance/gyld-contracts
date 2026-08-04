// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @dev Minimal view surface of OpenZeppelin's TimelockController needed for the
///      sanity assertions — avoids pulling the full implementation into every script.
interface ITimelockLike {
    function getMinDelay() external view returns (uint256);
    function hasRole(bytes32 role, address account) external view returns (bool);
}

/// @title DeployGuards
/// @notice Shared fail-closed guard rails for every Gyld deploy script.
///
/// ## Why this exists (GYL-1135)
///
/// The live Base mainnet stack was deployed with `delay = 0`, `executors[0] = address(0)`
/// and `initialize(deployer, deployer, deployer)` — the deployer EOA ended up holding
/// every privileged role behind a timelock that imposes no delay at all. Two design
/// defects made that possible and both are fixed here:
///
///  1. **Denylist chain guards.** Every "mainnet protection" check in the scripts was
///     `require(block.chainid != 1, ...)`. Base (8453), Arbitrum, Optimism, Polygon and
///     every future L2 sail straight through it. {isDevChain} inverts this into an
///     ALLOWLIST: only Anvil (31337) and Sepolia (11155111) are development chains, and
///     an unrecognised chain defaults to "production". A new chain now fails closed.
///
///  2. **Silent fallbacks.** Privileged addresses fell back to the deployer EOA and the
///     timelock handover was skipped with at most a `console.log` when its env var was
///     unset. {envAddressProdRequired} keeps that ergonomic on dev chains and turns it
///     into a hard revert everywhere else.
///
/// ## Deterministic addresses
///
/// {saltFor} / {requireVacant} give every bootstrap contract a CREATE2 salt that includes
/// `block.chainid`, so the same deployer+nonce can no longer produce COLLIDING addresses
/// across chains (today `0x7c1798…70ad` is a live GyldBondToken on Base and a
/// MockSanctionsList on Sepolia).
library DeployGuards {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ── Chain allowlist ───────────────────────────────────────────────────────
    /// Local Anvil / Hardhat devnet.
    uint256 internal constant ANVIL_CHAIN_ID = 31337;
    /// The single supported public testnet (docs/atomic-settlement-testnet-runbook.md).
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    /// Minimum TimelockController delay on any production chain.
    uint256 internal constant MIN_PROD_TIMELOCK_DELAY = 48 hours;

    /// Canonical deterministic CREATE2 proxy (Arachnid / `forge script` default).
    /// Present on Anvil and on every major chain at the same address.
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// Anvil account[1]. Its private key is published in the Anvil banner, so this
    /// address must never be granted anything on a production chain.
    address internal constant ANVIL_ACCOUNT_1 = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;

    // TimelockController role ids (recomputed here so scripts need not import it).
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    // ── Identity ──────────────────────────────────────────────────────────────

    /// @notice The EOA that actually signs and sends the deployment transactions.
    /// @dev    Under `forge script` this is identical to `msg.sender` inside `run()` —
    ///         both are the `--sender` / `--private-key` account. Under `forge test`,
    ///         however, `msg.sender` is the calling test contract while `vm.startBroadcast()`
    ///         executes as the default sender, so `msg.sender` would name an address that
    ///         holds nothing. `tx.origin` is the one identity that is correct in BOTH
    ///         contexts, which is what makes these scripts executable from a test at all.
    function broadcaster() internal view returns (address) {
        return tx.origin;
    }

    // ── Chain classification ──────────────────────────────────────────────────

    /// @notice True ONLY for the two chains where deployer-held roles, zero delays and
    ///         mock contracts are acceptable.
    /// @dev    ALLOWLIST, deliberately. Anything not named here — including chains that
    ///         do not exist yet — is treated as production and gets the strict path.
    function isDevChain() internal view returns (bool) {
        return block.chainid == ANVIL_CHAIN_ID || block.chainid == SEPOLIA_CHAIN_ID;
    }

    /// @notice Reverts unless the current chain is a development chain.
    /// @param  what human-readable description of the dev-only action being attempted.
    function requireProdSafe(string memory what) internal view {
        if (isDevChain()) return;
        revert(
            string.concat(
                "DeployGuards: ",
                what,
                " is dev-only and is NOT production-safe on chainId ",
                vm.toString(block.chainid),
                " (dev chains: 31337 Anvil, 11155111 Sepolia)"
            )
        );
    }

    // ── Environment variables ─────────────────────────────────────────────────

    /// @notice Reads `key` as an address. Reverts if unset, unparseable or zero.
    function envAddressRequired(string memory key) internal view returns (address addr) {
        bool set;
        try vm.envAddress(key) returns (address v) {
            addr = v;
            set = true;
        } catch {}
        if (!set) {
            revert(string.concat("DeployGuards: env var ", key, " is required on chainId ", vm.toString(block.chainid)));
        }
        if (addr == address(0)) {
            revert(string.concat("DeployGuards: env var ", key, " must not be the zero address"));
        }
    }

    /// @notice Reads `key` as an address, falling back to `devFallback` ONLY on a dev
    ///         chain. On any production chain an unset (or zero) value reverts.
    function envAddressProdRequired(string memory key, address devFallback) internal view returns (address) {
        if (!isDevChain()) return envAddressRequired(key);
        try vm.envAddress(key) returns (address v) {
            return v == address(0) ? devFallback : v;
        } catch {
            return devFallback;
        }
    }

    /// @notice uint equivalent of {envAddressProdRequired}. On production the var must be set.
    function envUintProdRequired(string memory key, uint256 devFallback) internal view returns (uint256) {
        bool set;
        uint256 value;
        try vm.envUint(key) returns (uint256 v) {
            value = v;
            set = true;
        } catch {}
        if (set) return value;
        if (isDevChain()) return devFallback;
        revert(string.concat("DeployGuards: env var ", key, " is required on chainId ", vm.toString(block.chainid)));
    }

    /// @notice On production, a timelock delay below 48h is rejected before any gas is
    ///         spent. `TIMELOCK_DELAY_SECONDS=0` on Base is exactly how the incident happened.
    function requireProdMinDelay(uint256 delay) internal view {
        if (isDevChain()) return;
        if (delay < MIN_PROD_TIMELOCK_DELAY) {
            revert(
                string.concat(
                    "DeployGuards: TIMELOCK_DELAY_SECONDS=",
                    vm.toString(delay),
                    " is below the 172800s (48h) minimum on production chainId ",
                    vm.toString(block.chainid)
                )
            );
        }
    }

    // ── Address hygiene ───────────────────────────────────────────────────────

    /// @notice On production, `who` must not be the deployer EOA. No-op on dev chains.
    /// @dev    A privileged role pointed at the broadcaster is the exact shape of the
    ///         Base incident: the handover reads as done but nothing actually moved.
    function requireNotDeployer(address who, address deployer, string memory key) internal view {
        if (isDevChain()) return;
        if (who == deployer) {
            revert(
                string.concat(
                    "DeployGuards: ",
                    key,
                    " must not be the deployer EOA (",
                    vm.toString(deployer),
                    ") on production chainId ",
                    vm.toString(block.chainid)
                )
            );
        }
    }

    /// @notice On production, two roles that exist to split a quorum must be distinct.
    function requireDistinct(address a, address b, string memory keyA, string memory keyB) internal view {
        if (isDevChain()) return;
        if (a == b) {
            revert(
                string.concat(
                    "DeployGuards: ",
                    keyA,
                    " and ",
                    keyB,
                    " must be different addresses on production chainId ",
                    vm.toString(block.chainid),
                    " (single address defeats the split)"
                )
            );
        }
    }

    /// @notice On production, `target` must be a deployed contract — not an EOA.
    /// @dev    Catches a sanctions "oracle" or forwarder owner that is silently a wallet.
    function requireProdContract(address target, string memory label) internal view {
        if (isDevChain()) return;
        if (target.code.length == 0) {
            revert(
                string.concat(
                    "DeployGuards: ",
                    label,
                    " (",
                    vm.toString(target),
                    ") has no code - a contract is required on production chainId ",
                    vm.toString(block.chainid)
                )
            );
        }
    }

    /// @notice On production, `target` must not be one of the dev mocks compiled into
    ///         this repo. No-op on dev chains.
    /// @dev    {requireProdContract} can only see `code.length != 0`, which a mock trivially
    ///         satisfies — that is how a writable MockSanctionsList could pass as the
    ///         production `SANCTIONS_LIST`. This closes the gap for the mocks we ship by
    ///         comparing EXTCODEHASH against the mock's runtime bytecode taken from THE SAME
    ///         COMPILATION, e.g.
    ///
    ///             requireProdNotMock(oracle, type(MockSanctionsList).runtimeCode, "SANCTIONS_LIST")
    ///
    ///         so the expected hash cannot drift from the artifact it protects against
    ///         (a compiler or optimiser change moves both together). It is deliberately
    ///         NOT a general "is this a mock" oracle: any third-party writable oracle still
    ///         passes, so this is a second line of defence behind the mock's own access
    ///         control and the dev-only chain guard on its deploy script — not a substitute.
    /// @param  devMockRuntimeCode `type(SomeMock).runtimeCode` of a mock that must never be
    ///         wired in on production.
    function requireProdNotMock(address target, bytes memory devMockRuntimeCode, string memory label)
        internal
        view
    {
        if (isDevChain()) return;
        if (target.codehash == keccak256(devMockRuntimeCode)) {
            revert(
                string.concat(
                    "DeployGuards: ",
                    label,
                    " (",
                    vm.toString(target),
                    ") is a DEV MOCK whose sanctions list is writable - it must never be used on production chainId ",
                    vm.toString(block.chainid)
                )
            );
        }
    }

    // ── Post-deploy assertions (run in-band, inside the broadcast) ─────────────

    /// @notice Asserts a role handover actually happened: `holder` HAS `role` on
    ///         `target` and `mustNotHold` (the deployer) does NOT.
    function assertRoleHandover(address target, bytes32 role, address holder, address mustNotHold, string memory label)
        internal
        view
    {
        if (!IAccessControl(target).hasRole(role, holder)) {
            revert(string.concat("DeployGuards: ", label, " - intended holder ", vm.toString(holder), " does NOT hold the role"));
        }
        if (IAccessControl(target).hasRole(role, mustNotHold)) {
            revert(string.concat("DeployGuards: ", label, " - ", vm.toString(mustNotHold), " STILL holds the role after handover"));
        }
    }

    /// @notice Asserts the timelock is a real governance gate and not a rubber stamp.
    /// @dev    On production: `getMinDelay() >= 48h`, and the deployer holds NONE of
    ///         PROPOSER / CANCELLER / DEFAULT_ADMIN on the timelock itself. Without the
    ///         second half a handover can look perfect while the deployer remains the
    ///         sole proposer of a zero-delay timelock — i.e. still unilateral. No-op on dev.
    function assertTimelockSane(address payable tl, address deployer) internal view {
        if (isDevChain()) return;
        ITimelockLike t = ITimelockLike(tl);

        uint256 delay = t.getMinDelay();
        if (delay < MIN_PROD_TIMELOCK_DELAY) {
            revert(
                string.concat(
                    "DeployGuards: timelock ",
                    vm.toString(tl),
                    " minDelay is ",
                    vm.toString(delay),
                    "s, below the 172800s (48h) production minimum on chainId ",
                    vm.toString(block.chainid)
                )
            );
        }
        _requireDeployerLacks(t, PROPOSER_ROLE, deployer, "PROPOSER_ROLE");
        _requireDeployerLacks(t, CANCELLER_ROLE, deployer, "CANCELLER_ROLE");
        _requireDeployerLacks(t, DEFAULT_ADMIN_ROLE, deployer, "DEFAULT_ADMIN_ROLE");
    }

    function _requireDeployerLacks(ITimelockLike t, bytes32 role, address deployer, string memory roleName)
        private
        view
    {
        if (t.hasRole(role, deployer)) {
            revert(
                string.concat(
                    "DeployGuards: deployer ",
                    vm.toString(deployer),
                    " holds ",
                    roleName,
                    " on the timelock - the handover is cosmetic, governance is still unilateral"
                )
            );
        }
    }

    // ── Deterministic (CREATE2) bootstrap addresses ───────────────────────────

    /// @notice Namespaced, chain-scoped CREATE2 salt.
    /// @dev    `keccak256("gyld.v1" ++ name ++ chainId)`. The chainId term is what stops
    ///         the same logical contract from landing on the same address on two chains.
    function saltFor(string memory name) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("gyld.v1", name, block.chainid));
    }

    /// @notice CREATE2 address for `initCodeHash` deployed by the canonical proxy.
    function predictCreate2(bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash)))));
    }

    /// @notice Pre-flight check that the predicted CREATE2 address is empty, so a dry run
    ///         names the clash instead of the broadcast reverting mid-deploy.
    /// @dev    `forge script` rewrites the CREATE2 caller to {CREATE2_DEPLOYER}, which is
    ///         what the prediction assumes. Under `forge test` without an active broadcast
    ///         the real deployer is the script contract, so this degrades to a no-op rather
    ///         than a false alarm.
    /// @notice {saltFor} + {requireVacant} in one expression, so a deployment reads
    ///         `new Foo{salt: DeployGuards.vacantSalt("Script:Foo", initCode)}(...)`
    ///         and cannot drift from the address it just pre-checked.
    /// @dev    `type(Foo).creationCode` and `new Foo` reference the same solc sub-object,
    ///         so passing the init code here does not duplicate bytecode in the script.
    function vacantSalt(string memory name, bytes memory initCode) internal view returns (bytes32 salt) {
        salt = saltFor(name);
        requireVacant(salt, initCode, name);
    }

    function requireVacant(bytes32 salt, bytes memory initCode, string memory name)
        internal
        view
        returns (address predicted)
    {
        predicted = predictCreate2(salt, keccak256(initCode));
        if (predicted.code.length != 0) {
            revert(
                string.concat(
                    "DeployGuards: predicted CREATE2 address ",
                    vm.toString(predicted),
                    " for '",
                    name,
                    "' already has code on chainId ",
                    vm.toString(block.chainid)
                )
            );
        }
    }
}
