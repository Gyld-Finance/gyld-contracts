// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";

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
///   5. Allowlist any APs from ALLOWED_TAKERS: swap.setAllowed(addr, true).
///   6. Hand DEFAULT_ADMIN_ROLE on the swap proxy to the timelock, revoke deployer.
///
/// Role model (falls back to deployer in dev, like DeployDevNet):
///   TIMELOCK_ADDRESS     →  DEFAULT_ADMIN_ROLE on swap after setup (upgrades, unpause,
///                           series registry, band params, withdrawal wallet, allowlist,
///                           epoch bump)
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
///   USDC_ADDRESS           USDC token (6 decimals). Required.
///   EVM_ISSUANCE_MANAGER   IssuanceManager proxy from DeployDevNet. Required.
///
/// Optional:
///   TIMELOCK_ADDRESS       TimelockController; admin handover skipped if unset
///                          (dev: deployer keeps DEFAULT_ADMIN for convenience).
///   OPS_MULTISIG           Pauser. Defaults to deployer.
///   TREASURER_ADDRESS      Treasurer. Defaults to deployer.
///   QUOTE_SIGNER           Quote signer. Defaults to deployer.
///   WITHDRAWAL_WALLET      Fixed treasury destination for withdraw(). Defaults to
///                          TREASURER_ADDRESS (dev).
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
    function run() external {
        IERC20 usdcToken = IERC20(vm.envAddress("USDC_ADDRESS"));
        IssuanceManager issuanceMgr = IssuanceManager(vm.envAddress("EVM_ISSUANCE_MANAGER"));

        address timelock = _envOrDefault("TIMELOCK_ADDRESS", address(0));
        address opsMultisig = _envOrDefault("OPS_MULTISIG", msg.sender);
        address treasurer = _envOrDefault("TREASURER_ADDRESS", msg.sender);
        address quoteSigner = _envOrDefault("QUOTE_SIGNER", msg.sender);
        address withdrawal = _envOrDefault("WITHDRAWAL_WALLET", treasurer);
        uint16 maxBps = uint16(_envOrUint("MAX_QUOTE_DEVIATION_BPS", 200));
        uint32 maxNavAge = uint32(_envOrUint("MAX_NAV_AGE_SECS", 86400));

        vm.startBroadcast();

        // 1. Swap: impl + proxy. Deployer is DEFAULT_ADMIN during setup (step 6 hands
        //    over). Impl is inlined so its stack slot dies immediately.
        GyldAtomicSwap swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(new GyldAtomicSwap()),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (msg.sender, opsMultisig, quoteSigner, treasurer, address(usdcToken), maxBps, maxNavAge)
                    )
                )
            )
        );
        console.log("EVM_ATOMIC_SWAP=%s", address(swap));

        // 2. Whitelist the SWAP as an AP on the IssuanceManager (the only touch on
        //    existing contracts). The swap now holds inventory, so it must be a
        //    whitelisted mint recipient: IssuanceManager.subscribe(token, swap, n) seeds
        //    inventory directly into it. Requires WHITELIST_ADMIN_ROLE; if the
        //    broadcaster lacks it (prod), print the run-book instruction instead.
        if (issuanceMgr.hasRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), msg.sender)) {
            issuanceMgr.addToWhitelist(address(swap));
            console.log("Swap whitelisted as AP on IssuanceManager (subscribe mint recipient)");
        } else {
            console.log("!! Broadcaster lacks WHITELIST_ADMIN_ROLE - run via ops Safe:");
            console.log("   issuanceMgr.addToWhitelist(%s)", address(swap));
        }

        // 3. Register each series with its NAV forwarder (factory lookup).
        //    registerSeries probes forwarder.decimals() == 8 on-chain.
        _registerSeries(swap);

        // 4. Set the fixed treasury withdrawal wallet — the treasurer can only ever
        //    withdraw NET flow out to THIS address (admin-fixed safety property).
        swap.setWithdrawalWallet(withdrawal);
        console.log("withdrawalWallet set: %s", withdrawal);

        // 5. Allowlist APs permitted to be executeSwap takers.
        _allowlistTakers(swap);

        // 6. Hand DEFAULT_ADMIN on the swap proxy to the timelock and revoke the
        //    deployer (same pattern as DeployDevNet step 9). Skipped in dev when
        //    TIMELOCK_ADDRESS is unset so the deployer can keep iterating.
        if (timelock != address(0)) {
            bytes32 adminRole = swap.DEFAULT_ADMIN_ROLE();
            swap.grantRole(adminRole, timelock);
            swap.revokeRole(adminRole, msg.sender);
            console.log("DEFAULT_ADMIN handed to timelock %s on swap", timelock);
        } else {
            console.log("!! TIMELOCK_ADDRESS unset - deployer keeps DEFAULT_ADMIN (dev only)");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Atomic settlement deployment complete ===");
        console.log("Chain ID:              %d", block.chainid);
        console.log("EVM_ATOMIC_SWAP=%s", address(swap));
        console.log("");
        console.log("=== Role assignments ===");
        console.log("DEFAULT_ADMIN:         %s", timelock != address(0) ? timelock : msg.sender);
        console.log("PAUSER (ops):          %s", opsMultisig);
        console.log("TREASURER:             %s", treasurer);
        console.log("QUOTE_SIGNER:          %s", quoteSigner);
        console.log("WITHDRAWAL_WALLET:     %s", withdrawal);
        console.log("");
        console.log("=== Next steps (docs/atomic-settlement.md run-book) ===");
        console.log("  1. Point the QuoteService signing key at QUOTE_SIGNER_ROLE");
        console.log("  2. Seed swap inventory: IssuanceManager.subscribe(token, swap, n)");
        console.log("     after broker fills (mint-at-fill; swap is now a whitelisted AP)");
        console.log("  3. Fund the swap with USDC for the redeem leg (transfer to the swap)");
        console.log("  4. Gateway env: EVM_ATOMIC_SWAP (above)");
    }

    /// @dev Step 3 — register SERIES_TOKENS with forwarders looked up from the factory.
    ///      Extracted to keep run()'s live-local count below the Yul stack limit.
    function _registerSeries(GyldAtomicSwap swap) internal {
        address[] memory tokens;
        try vm.envAddress("SERIES_TOKENS", ",") returns (address[] memory t) {
            tokens = t;
        } catch {
            console.log("SERIES_TOKENS unset - register series later via swap.registerSeries");
            return;
        }
        TokenFactory factory = TokenFactory(vm.envAddress("EVM_FACTORY_ADDRESS"));
        for (uint256 i = 0; i < tokens.length; i++) {
            address forwarder = factory.forwarderOf(tokens[i]);
            require(forwarder != address(0), "DeployAtomicSettlement: token has no forwarder in factory");
            swap.registerSeries(tokens[i], forwarder);
            console.log("Registered series %s (forwarder %s)", tokens[i], forwarder);
        }
    }

    /// @dev Step 5 — allowlist each ALLOWED_TAKERS entry as an executeSwap taker.
    function _allowlistTakers(GyldAtomicSwap swap) internal {
        try vm.envAddress("ALLOWED_TAKERS", ",") returns (address[] memory takers) {
            for (uint256 i = 0; i < takers.length; i++) {
                swap.setAllowed(takers[i], true);
                console.log("Allowlisted taker: %s", takers[i]);
            }
        } catch {
            console.log("ALLOWED_TAKERS unset - allowlist takers later via swap.setAllowed");
        }
    }

    function _envOrDefault(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            return val;
        } catch {
            return fallback_;
        }
    }

    function _envOrUint(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 val) {
            return val;
        } catch {
            return fallback_;
        }
    }
}
