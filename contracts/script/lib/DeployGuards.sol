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
/// The live production stack was deployed with `delay = 0`, `executors[0] = address(0)`
/// and `initialize(deployer, deployer, deployer)` — the deployer EOA ended up holding
/// every privileged role behind a timelock that imposes no delay at all. Two design
/// defects made that possible and both are fixed here:
///
///  1. **Denylist chain guards.** Every "mainnet protection" check in the scripts was
///     `require(block.chainid != 1, ...)`. A production L2 (chain 8453), Arbitrum, Optimism, Polygon and
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
/// across chains (today `0x7c1798…70ad` is a live GyldBondToken on a production L2 and a
/// MockSanctionsList on Sepolia).
library DeployGuards {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    // ── Chain allowlist ───────────────────────────────────────────────────────
    /// Local Anvil / Hardhat devnet.
    uint256 internal constant ANVIL_CHAIN_ID = 31337;
    /// The single supported public testnet (docs/ARCHITECTURE.md).
    uint256 internal constant SEPOLIA_CHAIN_ID = 11155111;

    /// Minimum TimelockController delay on any production chain.
    uint256 internal constant MIN_PROD_TIMELOCK_DELAY = 48 hours;

    /// @notice Gas one `isSanctioned` read may consume in {requireSanctionsOracleAnswers}
    ///         before the oracle is refused. Audit FIND-006.
    /// @dev    The budget is MEASURED, not imposed — {_screens} calls with a far larger
    ///         ceiling and then checks what was actually spent. That distinction is the
    ///         whole design, and the first attempt got it wrong: capping the guard's own
    ///         staticcall at `SanctionsOracleMirror.FORWARDING_GAS` (40_000) starves the
    ///         mirror of the gas it needs to hand its upstream the full allowance, so the
    ///         guard would refuse a vendor oracle that costs 30k and works perfectly at
    ///         runtime. A cap cannot both give the upstream its real allowance and sit
    ///         below "mirror overhead + that allowance". Observing sidesteps the conflict.
    ///
    ///         Why any budget, when an upstream that OOGs behind a mirror already fails
    ///         this guard on the answer itself: a deploy script runs with the whole
    ///         transaction behind it, so the mirror always reaches its full allowance
    ///         here. A transfer does not. EIP-150 forwards 63/64 of what remains, so a
    ///         transfer far enough along to hold under ~41k hands the third-party hop
    ///         LESS than the deploy probe did. An upstream sitting just inside the
    ///         allowance is admitted and then fails in production — exactly the gap
    ///         FIND-006 names. What separates the two is margin, and margin is a number
    ///         you can only get by measuring.
    ///
    ///         20_000 sits between two measured populations, cold-slot (`vm.cool`) on the
    ///         shapes this repo actually deploys:
    ///           - healthy: local-list-only mirror 5,420; mirror forwarding to a leaf
    ///             oracle 8,573; mirror chained through a second mirror 8,188
    ///           - spent:   mirror whose upstream burns its allowance 41,185
    ///         2.3x above the worst healthy read and under half the spent one. Pinned
    ///         from both sides in `DeployScripts.t.sol` so neither edge drifts silently.
    uint256 internal constant SCREENING_GAS_BUDGET = 20_000;

    /// @notice Hard ceiling on a single screening staticcall, so an oracle that never
    ///         returns cannot consume the deploy transaction. Audit FIND-006.
    /// @dev    4x {SCREENING_GAS_BUDGET}: high enough that an over-budget oracle still
    ///         RETURNS and can be reported with the figure it actually spent, low enough
    ///         to bound the damage. A ceiling at the budget itself would collapse "too
    ///         expensive" into "did not answer" and lose the diagnosis.
    uint256 internal constant SCREENING_GAS_CEILING = SCREENING_GAS_BUDGET * 4;

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
    ///         spent. `TIMELOCK_DELAY_SECONDS=0` on a production L2 is exactly how the incident happened.
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
    ///         GYL-1135 incident: the handover reads as done but nothing actually moved.
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

    /// @notice `who` must not be `forbidden`. Not dev-gated, unlike {requireDistinct}: a role
    ///         pointed at the contract that grants it is wrong on every chain (audit FIND-011).
    function requireNotSelf(address who, address forbidden, string memory key, string memory forbiddenKey)
        internal
        view
    {
        if (who == forbidden) {
            revert(
                string.concat(
                    "DeployGuards: ",
                    key,
                    " must not be ",
                    forbiddenKey,
                    " (",
                    vm.toString(forbidden),
                    ")"
                )
            );
        }
    }

    /// @notice `isin` must be a well-formed ISO 6166 identifier, check digit included.
    /// @dev    Audit FIND-012. deployToken claims an ISIN permanently and nothing on-chain
    ///         validates it, so a typo burns the identifier on that factory. Checked here,
    ///         where a typo is still free. Not dev-gated: a malformed ISIN is malformed on
    ///         every chain.
    function requireValidIsin(string memory isin) internal pure {
        bytes memory b = bytes(isin);
        if (b.length != 12) revert("DeployGuards: ISIN must be 12 characters");

        // Two-letter country prefix, 9 alphanumeric, 1 numeric check digit.
        for (uint256 i; i < 2; ++i) {
            if (b[i] < 0x41 || b[i] > 0x5A) revert("DeployGuards: ISIN prefix must be two A-Z letters");
        }
        for (uint256 i = 2; i < 11; ++i) {
            bool digit = b[i] >= 0x30 && b[i] <= 0x39;
            bool upper = b[i] >= 0x41 && b[i] <= 0x5A;
            if (!digit && !upper) revert("DeployGuards: ISIN body must be 0-9 or A-Z");
        }
        if (b[11] < 0x30 || b[11] > 0x39) revert("DeployGuards: ISIN check digit must be numeric");

        // Expand the 11-char body to digits (A=10..Z=35, each letter becoming two digits),
        // then Luhn from the right. Same algorithm the check digit was issued under.
        uint8[24] memory d;
        uint256 n;
        for (uint256 i; i < 11; ++i) {
            uint8 c = uint8(b[i]);
            if (c >= 0x30 && c <= 0x39) {
                d[n++] = c - 0x30;
            } else {
                uint8 v = c - 0x41 + 10;
                d[n++] = v / 10;
                d[n++] = v % 10;
            }
        }
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            uint256 digit = d[n - 1 - i];
            if (i % 2 == 0) {
                digit *= 2;
                if (digit > 9) digit -= 9;
            }
            sum += digit;
        }
        if ((10 - (sum % 10)) % 10 != uint8(b[11]) - 0x30) {
            revert(string.concat("DeployGuards: ISIN ", isin, " has a bad check digit"));
        }
    }

    /// @notice `factory` must not already have deployed `isin`.
    /// @dev    Audit FIND-012. The claim is one-way, so hitting IsinAlreadyDeployed on-chain
    ///         costs the identifier. Fail here, before the timelock proposal is built.
    function requireIsinVacant(address factory, string memory isin) internal view {
        (bool ok, bytes memory data) =
            factory.staticcall(abi.encodeWithSignature("tokenByIsin(string)", isin));
        if (!ok || data.length != 32) revert("DeployGuards: factory did not answer tokenByIsin");
        address existing = abi.decode(data, (address));
        if (existing != address(0)) {
            revert(
                string.concat(
                    "DeployGuards: ISIN ", isin, " is already deployed at ", vm.toString(existing)
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

    /// @notice On production, `oracle` must give the RIGHT answers, not merely well-formed
    ///         ones: `true` for `knownFlagged` and `false` for `knownClean`. No-op on dev.
    /// @dev    Audit FIND-008. `GyldBondToken`'s own admission probe is an interface check —
    ///         it asks about `address(0)`, whose correct answer is `false`, which is also
    ///         what an oracle wired to `false` returns. It therefore cannot distinguish a
    ///         working compliance gate from a disabled one, and the finding is right that
    ///         nothing reverts to signal the difference. Detecting that needs an address
    ///         genuinely on the list, and this is the layer that can supply one: a deploy
    ///         script takes a **live SDN designation** from the operator at run time, where
    ///         a fixture stored in the contract would go stale the moment OFAC delisted it
    ///         and would then brick the compliance recovery path (D-33).
    ///
    ///         This is what catches the case the token cannot: a freshly deployed,
    ///         **unseeded** `SanctionsOracleMirror` — empty local list, no forwarding oracle
    ///         — answers `false` for everything, satisfies every structural check, satisfies
    ///         {requireProdContract} and {requireProdNotMock}, and screens nobody.
    ///
    ///         Audit FIND-006 adds the third term: both reads are measured against
    ///         {SCREENING_GAS_BUDGET}, so this asserts the oracle answers correctly AND
    ///         affordably. Without it the guard read every oracle with the whole deploy
    ///         transaction behind it, which is not the budget the transfer path offers —
    ///         see the constant for the EIP-150 reasoning.
    ///
    ///         Point-in-time by nature. The mirror's list is rewritten by the keeper every
    ///         few hours, so this proves the oracle was answering correctly at deploy; the
    ///         continuous equivalent is the keeper re-running the same two `eth_call`s each
    ///         cycle against the installed oracle — with the same gas cap, or the drift
    ///         this guard now catches at deploy goes unnoticed after it.
    /// @param  knownFlagged an address on the CURRENT OFAC/SDN feed — read it at run time,
    ///         never hardcode it.
    /// @param  knownClean   an address that must not be flagged; the deployer EOA will do.
    function requireSanctionsOracleAnswers(
        address oracle,
        address knownFlagged,
        address knownClean,
        string memory label
    ) internal view {
        if (isDevChain()) return;
        if (!_screens(oracle, knownFlagged)) {
            revert(
                string.concat(
                    "DeployGuards: ",
                    label,
                    " (",
                    vm.toString(oracle),
                    ") does NOT flag known-sanctioned ",
                    vm.toString(knownFlagged),
                    " - the oracle is unseeded or screening is disabled"
                )
            );
        }
        if (_screens(oracle, knownClean)) {
            revert(
                string.concat(
                    "DeployGuards: ",
                    label,
                    " (",
                    vm.toString(oracle),
                    ") flags known-clean ",
                    vm.toString(knownClean),
                    " - it would revert every transfer"
                )
            );
        }
    }

    /// Read one screening answer on the same terms `GyldBondToken._requireAccess` decodes on,
    /// inside {SCREENING_GAS_BUDGET} (audit FIND-006). Reverts rather than returning false if
    /// the oracle cannot answer at all, so an unreachable oracle fails the deploy loudly
    /// instead of reading as "does not flag".
    ///
    /// The two failures are kept apart on purpose, because they are different fixes: an
    /// oracle that cannot answer is unreachable or broken, while one that answers over
    /// budget is live and correct and simply too expensive to screen with. Both carry the
    /// gas actually spent, so the operator does not have to guess which they are looking at.
    function _screens(address oracle, address who) private view returns (bool) {
        uint256 startGas = gasleft();
        (bool ok, bytes memory data) = oracle.staticcall{gas: SCREENING_GAS_CEILING}(
            abi.encodeWithSignature("isSanctioned(address)", who)
        );
        uint256 gasUsed = startGas - gasleft();

        // Not `require(cond, string.concat(...))`: the argument would be built on every
        // successful screen too. This guard runs inside a broadcast.
        if (!ok || data.length != 32) {
            revert(
                string.concat(
                    "DeployGuards: sanctions oracle did not answer for ",
                    vm.toString(who),
                    " (spent ",
                    vm.toString(gasUsed),
                    " gas)"
                )
            );
        }
        // Audit FIND-006. Checked AFTER the answer, so "cannot answer" and "answers too
        // expensively" cannot be reported as each other.
        if (gasUsed > SCREENING_GAS_BUDGET) {
            revert(
                string.concat(
                    "DeployGuards: sanctions oracle answered for ",
                    vm.toString(who),
                    " but spent ",
                    vm.toString(gasUsed),
                    " gas, over the ",
                    vm.toString(SCREENING_GAS_BUDGET),
                    " budget - it has no margin left on the transfer path"
                )
            );
        }
        return abi.decode(data, (uint256)) == 1;
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
