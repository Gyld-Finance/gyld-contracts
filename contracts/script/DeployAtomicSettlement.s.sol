// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title DeployAtomicSettlement
/// @notice Deploys the self-custodial instant atomic-settlement contract on top of an
///         existing DeployDevNet deployment: a single GyldAtomicSwap (EIP-712 RFQ
///         settlement executor that HOLDS its own inventory — USDC, USDG, bond tokens).
///
///         Design + run-book: docs/atomic-settlement.md. The swap is a UUPS singleton
///         (one across all series, like IssuanceManager); per-series NAV-band state
///         lives in the swap via registerSeries.
///
/// Steps (single broadcast, admin-gated setup BEFORE timelock handover):
///   1. Swap impl + ERC1967Proxy
///      initialize(deployer, pauser, quoteSigner, treasurer, usdc, maxBps, maxNavAge)
///   2. issuanceMgr.addToWhitelist(swapProxy)
///        — the ONLY touch on existing contracts; makes the SWAP an AP so
///          IssuanceManager.subscribe(token, swap, n) mints inventory DIRECTLY to it
///          through the unchanged mint-at-fill pipeline. The swap now holds inventory,
///          so it MUST be a whitelisted mint recipient (this reverses the old vault-era
///          topology where the swap was deliberately NOT whitelisted). Skipped with
///          instructions if the broadcaster lacks WHITELIST_ADMIN_ROLE (prod: ops Safe
///          runs it separately).
///   3. Per series: swap.registerSeries(token, factory.forwarderOf(token))
///        — forwarder probed for decimals() == 8 on-chain; reverts otherwise.
///   4. swap.setWithdrawalWallet(WITHDRAWAL_WALLET) — fixed treasury destination the
///        treasurer withdraws NET flow to (required env; defaults to treasurer in dev).
///   5. Grant ALLOWLIST_ADMIN_ROLE to the deployer (needed for step 6) and to
///        ALLOWLIST_ADMIN — the KMS allowlist key that must keep calling setAllowed
///        AFTER the timelock handover (GYL-1050).
///   6. Allowlist any APs from ALLOWED_TAKERS: swap.setAllowed(addr, true).
///   7. Hand DEFAULT_ADMIN_ROLE on the swap proxy to the timelock, revoke deployer
///        (and revoke the deployer's transient ALLOWLIST_ADMIN_ROLE).
///
/// Role model (falls back to deployer in dev, like DeployDevNet):
///   TIMELOCK_ADDRESS     →  DEFAULT_ADMIN_ROLE on swap after setup (upgrades, unpause,
///                           series registry, band params, withdrawal wallet,
///                           epoch bump)
///   ALLOWLIST_ADMIN      →  ALLOWLIST_ADMIN_ROLE on swap (KMS allowlist key; setAllowed
///                           only — stays LIVE after the timelock handover so the gateway
///                           allowlist routes keep working without a 48h proposal per user)
///   OPS_MULTISIG         →  PAUSER_ROLE on swap (pause only — asymmetric; resume
///                           requires the timelock)
///   TREASURER_ADDRESS    →  swap TREASURER_ROLE (Kaleidoscope ops MPC wallet:
///                           withdraw() NET flow out to the fixed withdrawalWallet for
///                           the T+2 broker bridge)
///   QUOTE_SIGNER         →  swap QUOTE_SIGNER_ROLE (QuoteService KMS key that signs
///                           EIP-712 SwapMessages)
///
/// Pre-requisites:
///   - Each SERIES_TOKENS forwarder must have a NAV pushed (executeSwap fails closed on
///     a non-positive or stale NAV). Push via KaleidoscopeNAVFeed.updateAnswer first.
///
/// ── Environment variables ──────────────────────────────────────────────────
/// Required on EVERY chain:
///   USDC_ADDRESS           USDC token (6 decimals).
///   EVM_ISSUANCE_MANAGER   IssuanceManager proxy from DeployDevNet.
///
/// Required on PRODUCTION chains; each falls back to the deployer on a dev chain
/// (Anvil 31337 / Sepolia 11155111) ONLY, and on production none of them may BE the
/// deployer EOA (GYL-1135):
///   TIMELOCK_ADDRESS       TimelockController that receives DEFAULT_ADMIN. Previously an
///                          unset value silently SKIPPED the handover and left the
///                          deployer as permanent admin of the settlement contract.
///   OPS_MULTISIG           Pauser.
///   TREASURER_ADDRESS      Treasurer.
///   QUOTE_SIGNER           Quote signer.
///   ALLOWLIST_ADMIN        Holder of ALLOWLIST_ADMIN_ROLE (setAllowed). On prod this MUST
///                          be the address of the EVM_KMS_SWAP_ADMIN_KEY_ID key or the
///                          gateway allowlist routes revert after the timelock handover
///                          (GYL-1050).
///   WITHDRAWAL_WALLET      Fixed treasury destination for withdraw(). Defaults to
///                          TREASURER_ADDRESS on a dev chain.
///   MAX_QUOTE_DEVIATION_BPS  Quote-vs-NAV band, basis points. Default 200 (2%).
///   MAX_NAV_AGE_SECS       Max NAV feed age before StaleNav. Default 86400 (1 day).
///   EVM_FACTORY_ADDRESS    TokenFactory; required only when SERIES_TOKENS is set
///                          (used to look up forwarderOf per token).
///   SERIES_TOKENS          Comma-separated GyldBondToken addresses to register.
///   ALLOWED_TAKERS         Comma-separated AP addresses to allowlist for executeSwap.
///
/// ── Usage — Anvil (local, after DeployDevNet + DeployMockUSDC) ─────────────
///   USDC_ADDRESS=<mock_usdc> \
///   EVM_ISSUANCE_MANAGER=<issuance_manager> \
///   EVM_FACTORY_ADDRESS=<factory> \
///   SERIES_TOKENS=<token_cat>,<token_c>,<token_ko> \
///   ALLOWED_TAKERS=<ap0>,<ap1> \
///   forge script contracts/script/DeployAtomicSettlement.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key $ANVIL_DEPLOYER_KEY
///
/// ── Usage — Hoodi testnet ──────────────────────────────────────────────────
///   export USDC_ADDRESS=<usdc_or_mock>
///   export EVM_ISSUANCE_MANAGER=<issuance_manager>
///   export TIMELOCK_ADDRESS=<timelock>
///   export OPS_MULTISIG=<gnosis_safe_address>
///   export TREASURER_ADDRESS=<ops_mpc_address>
///   export QUOTE_SIGNER=<kms_signer_address>
///   export ALLOWLIST_ADMIN=<kms_swap_admin_address>
///   export WITHDRAWAL_WALLET=<treasury_safe>
///   export EVM_FACTORY_ADDRESS=<factory>
///   export SERIES_TOKENS=<token0>,<token1>
///   forge script contracts/script/DeployAtomicSettlement.s.sol \
///     --rpc-url https://rpc.hoodi.ethpandaops.io \
///     --broadcast \
///     --private-key $PRIVKEY_SIGNING_KEY \
///     --verify
///
/// ── Outputs (set as gateway env vars) ──────────────────────────────────────
///   EVM_ATOMIC_SWAP        — GyldAtomicSwap proxy (users approve/permit THIS; it holds
///                            the settlement inventory)
contract DeployAtomicSettlement is Script {
    /// Resolved configuration, held in one memory struct so `run()` stays under the
    /// Yul 16-slot stack limit.
    struct Config {
        address deployer;
        address usdc;
        address issuanceManager;
        address timelock;
        address opsMultisig;
        address treasurer;
        address quoteSigner;
        address allowlistAdmin;
        address withdrawal;
        uint16 maxBps;
        uint32 maxNavAge;
    }

    // ── Outputs — public storage so tests and follow-up scripts can read them ──
    GyldAtomicSwap public swap;
    address public timelockAddress;

    function run() external {
        Config memory c = _config();
        timelockAddress = c.timelock;

        vm.startBroadcast();

        _deploySwap(c);
        _whitelistSwapAsAp(c);

        // 3. Register each series with its NAV forwarder (factory lookup).
        //    registerSeries probes forwarder.decimals() == 8 on-chain.
        _registerSeries();

        // 4. Set the fixed treasury withdrawal wallet — the treasurer can only ever
        //    withdraw NET flow out to THIS address (admin-fixed safety property).
        swap.setWithdrawalWallet(c.withdrawal);
        console.log("withdrawalWallet set: %s", c.withdrawal);

        // 5. Grant ALLOWLIST_ADMIN_ROLE. ORDERING IS LOAD-BEARING (GYL-1050): this must
        //    happen BEFORE step 6 (the deployer needs the role to call setAllowed at all)
        //    and BEFORE the step 7 revoke (after revokeRole(DEFAULT_ADMIN, deployer) the
        //    deployer can grant nothing, and recovery would need a 48h timelock proposal).
        swap.grantRole(swap.ALLOWLIST_ADMIN_ROLE(), c.deployer);
        if (c.allowlistAdmin != c.deployer) {
            swap.grantRole(swap.ALLOWLIST_ADMIN_ROLE(), c.allowlistAdmin);
        }
        console.log("ALLOWLIST_ADMIN_ROLE granted: %s (setAllowed only)", c.allowlistAdmin);

        // 6. Allowlist APs permitted to be executeSwap takers.
        _allowlistTakers();

        _handOverToTimelock(c);

        // In-band post-deploy assertions — still inside the broadcast, so a mismatch
        // aborts the deployment instead of leaving a deployer-controlled swap on chain.
        _assertFinalTopology(c);

        vm.stopBroadcast();

        _logSummary(c);
    }

    // ── Configuration ─────────────────────────────────────────────────────────

    /// @dev Resolves and validates every env var BEFORE any gas is spent. On a
    ///      production chain every privileged address is required and none may be the
    ///      deployer EOA; on Anvil/Sepolia they all still fall back to the deployer.
    function _config() internal view returns (Config memory c) {
        c.deployer = DeployGuards.broadcaster();

        c.usdc = DeployGuards.envAddressRequired("USDC_ADDRESS");
        DeployGuards.requireProdContract(c.usdc, "USDC_ADDRESS");
        c.issuanceManager = DeployGuards.envAddressRequired("EVM_ISSUANCE_MANAGER");
        DeployGuards.requireProdContract(c.issuanceManager, "EVM_ISSUANCE_MANAGER");

        // Required on production: an unset TIMELOCK_ADDRESS used to skip the handover
        // entirely and leave the deployer as the swap's permanent DEFAULT_ADMIN.
        c.timelock = DeployGuards.envAddressProdRequired("TIMELOCK_ADDRESS", address(0));
        if (c.timelock != address(0)) {
            DeployGuards.requireProdContract(c.timelock, "TIMELOCK_ADDRESS");
        }

        c.opsMultisig = DeployGuards.envAddressProdRequired("OPS_MULTISIG", c.deployer);
        c.treasurer = DeployGuards.envAddressProdRequired("TREASURER_ADDRESS", c.deployer);
        c.quoteSigner = DeployGuards.envAddressProdRequired("QUOTE_SIGNER", c.deployer);
        c.allowlistAdmin = DeployGuards.envAddressProdRequired("ALLOWLIST_ADMIN", c.deployer);
        c.withdrawal = DeployGuards.envAddressProdRequired("WITHDRAWAL_WALLET", c.treasurer);

        DeployGuards.requireNotDeployer(c.opsMultisig, c.deployer, "OPS_MULTISIG");
        DeployGuards.requireNotDeployer(c.treasurer, c.deployer, "TREASURER_ADDRESS");
        DeployGuards.requireNotDeployer(c.quoteSigner, c.deployer, "QUOTE_SIGNER");
        DeployGuards.requireNotDeployer(c.allowlistAdmin, c.deployer, "ALLOWLIST_ADMIN");
        DeployGuards.requireNotDeployer(c.withdrawal, c.deployer, "WITHDRAWAL_WALLET");

        c.maxBps = uint16(_envOrUint("MAX_QUOTE_DEVIATION_BPS", 200));
        c.maxNavAge = uint32(_envOrUint("MAX_NAV_AGE_SECS", 86400));
    }

    // ── Deployment steps ──────────────────────────────────────────────────────

    /// @dev 1. Swap impl + proxy, both at chain-scoped CREATE2 addresses. The deployer is
    ///         DEFAULT_ADMIN during setup only; {_handOverToTimelock} revokes it and
    ///         {_assertFinalTopology} proves the revoke landed.
    function _deploySwap(Config memory c) internal {
        address impl = address(
            new GyldAtomicSwap{
                salt: DeployGuards.vacantSalt(
                    "DeployAtomicSettlement:GyldAtomicSwap.impl", type(GyldAtomicSwap).creationCode
                )
            }()
        );
        bytes memory initData = abi.encodeCall(
            GyldAtomicSwap.initialize,
            (c.deployer, c.opsMultisig, c.quoteSigner, c.treasurer, c.usdc, c.maxBps, c.maxNavAge)
        );

        swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy{
                    salt: DeployGuards.vacantSalt(
                        "DeployAtomicSettlement:GyldAtomicSwap.proxy",
                        abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData))
                    )
                }(impl, initData)
            )
        );
        console.log("EVM_ATOMIC_SWAP=%s", address(swap));
    }

    /// @dev 2. Whitelist the SWAP as an AP on the IssuanceManager (the only touch on
    ///         existing contracts). The swap holds inventory, so it must be a whitelisted
    ///         mint recipient: IssuanceManager.subscribe(token, swap, n) seeds inventory
    ///         directly into it. Requires WHITELIST_ADMIN_ROLE; if the broadcaster lacks
    ///         it (prod, where the role is the ops Safe), print the run-book instruction.
    function _whitelistSwapAsAp(Config memory c) internal {
        IssuanceManager issuanceMgr = IssuanceManager(c.issuanceManager);
        if (issuanceMgr.hasRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), c.deployer)) {
            issuanceMgr.addToWhitelist(address(swap));
            console.log("Swap whitelisted as AP on IssuanceManager (subscribe mint recipient)");
        } else {
            console.log("!! Broadcaster lacks WHITELIST_ADMIN_ROLE - run via ops Safe:");
            console.log("   issuanceMgr.addToWhitelist(%s)", address(swap));
        }
    }

    /// @dev 7. Hand DEFAULT_ADMIN on the swap proxy to the timelock and revoke the
    ///         deployer (same pattern as DeployDevNet). Skipped ONLY on a dev chain with
    ///         TIMELOCK_ADDRESS unset, so the deployer can keep iterating; on production
    ///         {_config} has already made TIMELOCK_ADDRESS mandatory.
    ///         ALLOWLIST_ADMIN_ROLE deliberately survives on allowlistAdmin — that is the
    ///         whole point of the split; only the deployer's transient copy is dropped.
    function _handOverToTimelock(Config memory c) internal {
        if (c.timelock == address(0)) {
            DeployGuards.requireProdSafe("skipping the swap DEFAULT_ADMIN handover (TIMELOCK_ADDRESS unset)");
            console.log("!! TIMELOCK_ADDRESS unset - deployer keeps DEFAULT_ADMIN (dev only)");
            return;
        }
        swap.grantRole(swap.DEFAULT_ADMIN_ROLE(), c.timelock);
        if (c.allowlistAdmin != c.deployer) {
            swap.revokeRole(swap.ALLOWLIST_ADMIN_ROLE(), c.deployer);
        }
        swap.revokeRole(swap.DEFAULT_ADMIN_ROLE(), c.deployer);
        console.log("DEFAULT_ADMIN handed to timelock %s on swap", c.timelock);
    }

    // ── In-band post-deploy assertions ────────────────────────────────────────

    function _assertFinalTopology(Config memory c) internal view {
        // Operational roles landed where they were meant to.
        require(swap.hasRole(swap.PAUSER_ROLE(), c.opsMultisig), "DeployAtomicSettlement: OPS_MULTISIG lacks PAUSER_ROLE");
        require(swap.hasRole(swap.TREASURER_ROLE(), c.treasurer), "DeployAtomicSettlement: TREASURER lacks TREASURER_ROLE");
        require(swap.hasRole(swap.QUOTE_SIGNER_ROLE(), c.quoteSigner), "DeployAtomicSettlement: QUOTE_SIGNER lacks role");
        require(
            swap.hasRole(swap.ALLOWLIST_ADMIN_ROLE(), c.allowlistAdmin),
            "DeployAtomicSettlement: ALLOWLIST_ADMIN lacks ALLOWLIST_ADMIN_ROLE"
        );
        require(swap.withdrawalWallet() == c.withdrawal, "DeployAtomicSettlement: withdrawalWallet mismatch");

        if (c.timelock == address(0)) return; // dev-only path, already gated in _handOverToTimelock

        // Governance actually moved, and the timelock is a real gate rather than a
        // zero-delay rubber stamp whose sole proposer is the deployer.
        DeployGuards.assertRoleHandover(
            address(swap), swap.DEFAULT_ADMIN_ROLE(), c.timelock, c.deployer, "GyldAtomicSwap DEFAULT_ADMIN_ROLE"
        );
        DeployGuards.assertTimelockSane(payable(c.timelock), c.deployer);

        // The deployer keeps nothing at all on a production chain.
        if (!DeployGuards.isDevChain()) {
            require(!swap.hasRole(swap.ALLOWLIST_ADMIN_ROLE(), c.deployer), "DeployAtomicSettlement: deployer kept ALLOWLIST_ADMIN_ROLE");
            require(!swap.hasRole(swap.PAUSER_ROLE(), c.deployer), "DeployAtomicSettlement: deployer kept PAUSER_ROLE");
            require(!swap.hasRole(swap.TREASURER_ROLE(), c.deployer), "DeployAtomicSettlement: deployer kept TREASURER_ROLE");
            require(!swap.hasRole(swap.QUOTE_SIGNER_ROLE(), c.deployer), "DeployAtomicSettlement: deployer kept QUOTE_SIGNER_ROLE");
        }
    }

    // ── Logging ───────────────────────────────────────────────────────────────

    function _logSummary(Config memory c) internal view {
        console.log("");
        console.log("=== Atomic settlement deployment complete ===");
        console.log("Chain ID:              %d", block.chainid);
        console.log("EVM_ATOMIC_SWAP=%s", address(swap));
        console.log("");
        console.log("=== Role assignments ===");
        console.log("DEFAULT_ADMIN:         %s", c.timelock != address(0) ? c.timelock : c.deployer);
        console.log("ALLOWLIST_ADMIN:       %s", c.allowlistAdmin);
        console.log("PAUSER (ops):          %s", c.opsMultisig);
        console.log("TREASURER:             %s", c.treasurer);
        console.log("QUOTE_SIGNER:          %s", c.quoteSigner);
        console.log("WITHDRAWAL_WALLET:     %s", c.withdrawal);
        console.log("");
        console.log("=== Next steps (docs/atomic-settlement.md run-book) ===");
        console.log("  1. Point the QuoteService signing key at QUOTE_SIGNER_ROLE");
        console.log("  2. Seed swap inventory: IssuanceManager.subscribe(token, swap, n)");
        console.log("     after broker fills (mint-at-fill; swap is now a whitelisted AP)");
        console.log("  3. Fund the swap with USDC for the redeem leg (transfer to the swap)");
        console.log("  4. Gateway env: EVM_ATOMIC_SWAP (above)");
        console.log("  5. PROD: ALLOWLIST_ADMIN must be the EVM_KMS_SWAP_ADMIN_KEY_ID key's");
        console.log("     address, else POST /api/v1/admin/swap/allowlist reverts (GYL-1050)");
    }

    /// @dev Step 3 — register SERIES_TOKENS with forwarders looked up from the factory.
    ///      Extracted to keep run()'s live-local count below the Yul stack limit.
    function _registerSeries() internal {
        address[] memory tokens;
        try vm.envAddress("SERIES_TOKENS", ",") returns (address[] memory t) {
            tokens = t;
        } catch {
            console.log("SERIES_TOKENS unset - register series later via swap.registerSeries");
            return;
        }
        // An EMPTY (as opposed to absent) SERIES_TOKENS parses fine as a zero-length
        // array, so without this the script would demand EVM_FACTORY_ADDRESS for a
        // deployment that registers no series at all.
        if (tokens.length == 0) {
            console.log("SERIES_TOKENS empty - register series later via swap.registerSeries");
            return;
        }
        TokenFactory factory = TokenFactory(DeployGuards.envAddressRequired("EVM_FACTORY_ADDRESS"));
        for (uint256 i = 0; i < tokens.length; i++) {
            address forwarder = factory.forwarderOf(tokens[i]);
            require(forwarder != address(0), "DeployAtomicSettlement: token has no forwarder in factory");
            swap.registerSeries(tokens[i], forwarder);
            console.log("Registered series %s (forwarder %s)", tokens[i], forwarder);
        }
    }

    /// @dev Step 6 — allowlist each ALLOWED_TAKERS entry as an executeSwap taker.
    ///      Requires the broadcaster to hold ALLOWLIST_ADMIN_ROLE (granted in step 5).
    function _allowlistTakers() internal {
        try vm.envAddress("ALLOWED_TAKERS", ",") returns (address[] memory takers) {
            for (uint256 i = 0; i < takers.length; i++) {
                swap.setAllowed(takers[i], true);
                console.log("Allowlisted taker: %s", takers[i]);
            }
        } catch {
            console.log("ALLOWED_TAKERS unset - allowlist takers later via swap.setAllowed");
        }
    }

    /// @dev Tuning knobs only — these have safe defaults and no privilege attached, so
    ///      unlike the address vars they stay optional on every chain.
    function _envOrUint(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 val) {
            return val;
        } catch {
            return fallback_;
        }
    }
}
