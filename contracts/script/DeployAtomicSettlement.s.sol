// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldSettlementVault} from "../GyldSettlementVault.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";

/// @title DeployAtomicSettlement
/// @notice Deploys the instant atomic-settlement stack on top of an existing
///         DeployDevNet deployment: GyldSettlementVault (LP-funded inventory +
///         USDC pool) and GyldAtomicSwap (EIP-712 RFQ settlement executor).
///
///         Design + run-book: docs/atomic-settlement.md. Both contracts are UUPS
///         singletons (one across all series, like IssuanceManager); per-series
///         state lives in the vault via registerSeries.
///
/// Steps (single broadcast, admin-gated setup BEFORE timelock handover):
///   1. Vault impl + ERC1967Proxy   initialize(deployer, pauser, treasurer, usdc, issuanceMgr)
///   2. Swap  impl + ERC1967Proxy   initialize(deployer, pauser, quoteSigner, vaultProxy)
///   3. vault.setSwap(swapProxy)    — probes SWAP_MESSAGE_TYPEHASH(), grants SWAP_ROLE atomically
///   4. issuanceMgr.addToWhitelist(vaultProxy)
///        — the ONLY touch on existing contracts; makes the vault an AP so
///          IssuanceManager.subscribe(token, vault, n) replenishes inventory
///          through the unchanged mint-at-fill pipeline. The swap contract is
///          deliberately NOT whitelisted (never a mint recipient / redeem
///          beneficiary). Skipped with instructions if the broadcaster lacks
///          WHITELIST_ADMIN_ROLE (prod: ops Safe runs it separately).
///   5. Per series: vault.registerSeries(token, factory.forwarderOf(token))
///        — forwarder probed for decimals() == 8 on-chain; reverts otherwise.
///   6. LP_ROLE grants + optional dust seed deposit (anti-inflation belt-and-
///      braces on top of the virtual-shares offset).
///   7. Hand DEFAULT_ADMIN_ROLE on both proxies to the timelock, revoke deployer.
///
/// Role model (falls back to deployer in dev, like DeployDevNet):
///   TIMELOCK_ADDRESS     →  DEFAULT_ADMIN_ROLE on vault + swap after setup
///                           (upgrades, unpause, series registry, epoch bump)
///   OPS_MULTISIG         →  PAUSER_ROLE on vault + swap (pause only — asymmetric;
///                           resume requires the timelock)
///   TREASURER_ADDRESS    →  vault TREASURER_ROLE (Kaleidoscope ops MPC wallet:
///                           drawForReplenishment / settleReplenishment /
///                           forwardForBurn / repayUsdc — the T+2 net-flow bridge)
///   QUOTE_SIGNER         →  swap QUOTE_SIGNER_ROLE (QuoteService KMS key that
///                           signs EIP-712 SwapMessages)
///
/// Pre-requisites:
///   - Each SERIES_TOKENS forwarder must have a NAV pushed (NoPriceSet otherwise:
///     totalAssets() reverts, which bricks the step-6 dust deposit until a price
///     lands). Push via KaleidoscopeNAVFeed.updateAnswer before running.
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
///   EVM_FACTORY_ADDRESS    TokenFactory; required only when SERIES_TOKENS is set
///                          (used to look up forwarderOf per token).
///   SERIES_TOKENS          Comma-separated GyldBondToken addresses to register.
///   LP_ADDRESSES           Comma-separated KYC'd LP addresses to grant LP_ROLE.
///   DUST_DEPOSIT_USDC      Dust seed amount in 6dp units (e.g. 1000000 = 1 USDC).
///                          Broadcaster must hold that USDC; it receives LP_ROLE.
///
/// ── Usage — Anvil (local, after DeployDevNet + DeployMockUSDC) ─────────────
///   USDC_ADDRESS=<mock_usdc> \
///   EVM_ISSUANCE_MANAGER=<issuance_manager> \
///   EVM_FACTORY_ADDRESS=<factory> \
///   SERIES_TOKENS=<token_cat>,<token_c>,<token_ko> \
///   DUST_DEPOSIT_USDC=1000000 \
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
///   export EVM_FACTORY_ADDRESS=<factory>
///   export SERIES_TOKENS=<token0>,<token1>
///   forge script contracts/script/DeployAtomicSettlement.s.sol \
///     --rpc-url https://rpc.hoodi.ethpandaops.io \
///     --broadcast \
///     --private-key $PRIVKEY_SIGNING_KEY \
///     --verify
///
/// ── Outputs (set as gateway env vars) ──────────────────────────────────────
///   EVM_ATOMIC_SWAP        — GyldAtomicSwap proxy (users approve/permit THIS)
///   EVM_SETTLEMENT_VAULT   — GyldSettlementVault proxy (holds inventory + USDC)
contract DeployAtomicSettlement is Script {
    function run() external {
        IERC20 usdcToken = IERC20(vm.envAddress("USDC_ADDRESS"));
        IssuanceManager issuanceMgr = IssuanceManager(vm.envAddress("EVM_ISSUANCE_MANAGER"));

        address timelock    = _envOrDefault("TIMELOCK_ADDRESS",  address(0));
        address opsMultisig = _envOrDefault("OPS_MULTISIG",      msg.sender);
        address treasurer   = _envOrDefault("TREASURER_ADDRESS", msg.sender);
        address quoteSigner = _envOrDefault("QUOTE_SIGNER",      msg.sender);

        vm.startBroadcast();

        // 1. Vault: impl + proxy. Deployer is DEFAULT_ADMIN during setup (step 7
        //    hands over). Impl is inlined so its stack slot dies immediately.
        GyldSettlementVault vault = GyldSettlementVault(address(new ERC1967Proxy(
            address(new GyldSettlementVault()),
            abi.encodeCall(
                GyldSettlementVault.initialize,
                (msg.sender, opsMultisig, treasurer, address(usdcToken), address(issuanceMgr))
            )
        )));
        console.log("EVM_SETTLEMENT_VAULT=%s", address(vault));

        // 2. Swap: impl + proxy. initialize probes vault.totalAssets() — vault
        //    must already exist (it does).
        GyldAtomicSwap swap = GyldAtomicSwap(address(new ERC1967Proxy(
            address(new GyldAtomicSwap()),
            abi.encodeCall(
                GyldAtomicSwap.initialize,
                (msg.sender, opsMultisig, quoteSigner, address(vault))
            )
        )));
        console.log("EVM_ATOMIC_SWAP=%s", address(swap));

        // 3. Wire vault -> swap. setSwap probes SWAP_MESSAGE_TYPEHASH() and grants
        //    SWAP_ROLE atomically (revoking any previous holder), so at most one
        //    swap contract can ever drive onSwap.
        vault.setSwap(address(swap));
        console.log("SWAP_ROLE granted to swap proxy via vault.setSwap");

        // 4. Whitelist the vault as an AP on the IssuanceManager (the only touch
        //    on existing contracts). Requires WHITELIST_ADMIN_ROLE; if the
        //    broadcaster lacks it (prod), print the run-book instruction instead.
        if (issuanceMgr.hasRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), msg.sender)) {
            issuanceMgr.addToWhitelist(address(vault));
            console.log("Vault whitelisted as AP on IssuanceManager");
        } else {
            console.log("!! Broadcaster lacks WHITELIST_ADMIN_ROLE - run via ops Safe:");
            console.log("   issuanceMgr.addToWhitelist(%s)", address(vault));
        }

        // 5. Register each series with its NAV forwarder (factory lookup).
        //    registerSeries probes forwarder.decimals() == 8 on-chain.
        _registerSeries(vault);

        // 6. LP_ROLE grants + optional dust seed deposit.
        _onboardLps(vault, usdcToken);

        // 7. Hand DEFAULT_ADMIN on both proxies to the timelock and revoke the
        //    deployer (same pattern as DeployDevNet step 9). Skipped in dev when
        //    TIMELOCK_ADDRESS is unset so the deployer can keep iterating.
        if (timelock != address(0)) {
            bytes32 adminRole = vault.DEFAULT_ADMIN_ROLE();
            vault.grantRole(adminRole, timelock);
            vault.revokeRole(adminRole, msg.sender);
            swap.grantRole(adminRole, timelock);
            swap.revokeRole(adminRole, msg.sender);
            console.log("DEFAULT_ADMIN handed to timelock %s on vault + swap", timelock);
        } else {
            console.log("!! TIMELOCK_ADDRESS unset - deployer keeps DEFAULT_ADMIN (dev only)");
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Atomic settlement deployment complete ===");
        console.log("Chain ID:              %d", block.chainid);
        console.log("EVM_SETTLEMENT_VAULT=%s", address(vault));
        console.log("EVM_ATOMIC_SWAP=%s", address(swap));
        console.log("");
        console.log("=== Role assignments ===");
        console.log("DEFAULT_ADMIN:         %s", timelock != address(0) ? timelock : msg.sender);
        console.log("PAUSER (ops):          %s", opsMultisig);
        console.log("TREASURER:             %s", treasurer);
        console.log("QUOTE_SIGNER:          %s", quoteSigner);
        console.log("");
        console.log("=== Next steps (docs/atomic-settlement.md run-book) ===");
        console.log("  1. Point the QuoteService signing key at QUOTE_SIGNER_ROLE");
        console.log("  2. Seed vault inventory: IssuanceManager.subscribe(token, vault, n)");
        console.log("     after broker fills (mint-at-fill; vault is now a whitelisted AP)");
        console.log("  3. Gateway env: EVM_ATOMIC_SWAP / EVM_SETTLEMENT_VAULT (above)");
    }

    /// @dev Step 5 — register SERIES_TOKENS with forwarders looked up from the factory.
    ///      Extracted to keep run()'s live-local count below the Yul stack limit.
    function _registerSeries(GyldSettlementVault vault) internal {
        address[] memory tokens;
        try vm.envAddress("SERIES_TOKENS", ",") returns (address[] memory t) {
            tokens = t;
        } catch {
            console.log("SERIES_TOKENS unset - register series later via vault.registerSeries");
            return;
        }
        TokenFactory factory = TokenFactory(vm.envAddress("EVM_FACTORY_ADDRESS"));
        for (uint256 i = 0; i < tokens.length; i++) {
            address forwarder = factory.forwarderOf(tokens[i]);
            require(forwarder != address(0), "DeployAtomicSettlement: token has no forwarder in factory");
            vault.registerSeries(tokens[i], forwarder);
            console.log("Registered series %s (forwarder %s)", tokens[i], forwarder);
        }
    }

    /// @dev Step 6 — grant LP_ROLE to each LP_ADDRESSES entry; optionally seed a
    ///      dust deposit from the broadcaster (granted LP_ROLE for the purpose).
    function _onboardLps(GyldSettlementVault vault, IERC20 usdcToken) internal {
        bytes32 lpRole = vault.LP_ROLE();
        try vm.envAddress("LP_ADDRESSES", ",") returns (address[] memory lps) {
            for (uint256 i = 0; i < lps.length; i++) {
                vault.grantRole(lpRole, lps[i]);
                console.log("LP_ROLE granted: %s", lps[i]);
            }
        } catch {
            console.log("LP_ADDRESSES unset - grant LP_ROLE later via vault.grantRole");
        }
        try vm.envUint("DUST_DEPOSIT_USDC") returns (uint256 dust) {
            if (dust > 0) {
                vault.grantRole(lpRole, msg.sender);
                usdcToken.approve(address(vault), dust);
                vault.deposit(dust);
                console.log("Dust seed deposited: %d (6dp USDC)", dust);
            }
        } catch {
            console.log("DUST_DEPOSIT_USDC unset - seed a dust deposit before first real LP");
        }
    }

    function _envOrDefault(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            return val;
        } catch {
            return fallback_;
        }
    }
}
