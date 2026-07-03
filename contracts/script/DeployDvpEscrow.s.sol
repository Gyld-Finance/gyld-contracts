// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GyldDvpEscrow} from "../GyldDvpEscrow.sol";

/// @title DeployDvpEscrow
/// @notice Deploys GyldDvpEscrow (GYL-724): the deferred delivery-versus-payment
///         escrow for GyldBondToken <-> USDC. NON-UPGRADEABLE by design (plain
///         constructor, no proxy) — a deliberate deviation from the house UUPS
///         style so no admin key can ever redirect escrowed funds.
///
/// Steps (single broadcast, admin-gated setup BEFORE timelock handover):
///   1. new GyldDvpEscrow(deployer, pauser, termsSigner, settler, guardian,
///                        usdc, issuanceMgr, treasury)
///        — deployer is DEFAULT_ADMIN during setup; step 3 hands over.
///   2. Optional dev convenience: setNavConfig(DVP_NAV_TOKEN, DVP_NAV_FORWARDER,
///        DVP_NAV_MAX_DEVIATION_BPS, DVP_NAV_MAX_AGE_SECS) — the P2P-fill NAV
///        sanity band. Skipped with a log unless BOTH addresses are set.
///        setNavConfig probes forwarder.decimals() == 8 on-chain.
///   3. Hand DEFAULT_ADMIN_ROLE to the timelock, revoke deployer (skipped in dev
///        when TIMELOCK_ADDRESS is unset so the deployer can keep iterating).
///   4. Post-deploy sanity probes: immutables (USDC / ISSUANCE_MANAGER / TREASURY)
///        read back, all five roles verified via hasRole, EIP-712 domain logged
///        (the off-chain terms signer needs exactly name/version/chainId/address).
///
/// Role model (falls back to deployer in dev, like DeployDevNet):
///   TIMELOCK_ADDRESS     →  DEFAULT_ADMIN_ROLE after setup (unpause, setNavConfig,
///                           bumpTermsEpoch, role grants incl. signer rotation)
///   OPS_MULTISIG         →  PAUSER_ROLE (pause only — gates deposit() exclusively;
///                           settle/fill/refund are never pausable)
///   TERMS_SIGNER         →  TERMS_SIGNER_ROLE (terms-service KMS/Fordefi key;
///                           passive — checked against recovered EIP-712 signers)
///   SETTLER_ADDRESS      →  SETTLER_ROLE (platform ops key; spends the treasury
///                           USDC allowance in settle() — must not be public)
///   GUARDIAN_ADDRESS     →  GUARDIAN_ROLE (ops multisig; guardianRefund() only —
///                           defaults to OPS_MULTISIG, the documented prod holder)
///   TREASURY_ADDRESS     →  TREASURY immutable (address whose USDC allowance
///                           settle() spends; NOT a role — approve USDC to the
///                           escrow from this address before the first settle)
///
/// ── Environment variables ──────────────────────────────────────────────────
///   USDC_ADDRESS           USDC token (6 decimals). Required.
///   EVM_ISSUANCE_MANAGER   IssuanceManager proxy from DeployDevNet. Required.
///                          (Constructor zero-checks but does not probe it;
///                          deposit() consults registeredTokens at run time.)
///
/// Optional:
///   TIMELOCK_ADDRESS       TimelockController; admin handover skipped if unset
///                          (dev: deployer keeps DEFAULT_ADMIN for convenience).
///   OPS_MULTISIG           Pauser. Defaults to deployer.
///   TERMS_SIGNER           Terms signer. Defaults to deployer.
///   SETTLER_ADDRESS        Settler. Defaults to deployer.
///   GUARDIAN_ADDRESS       Guardian. Defaults to OPS_MULTISIG (then deployer).
///   TREASURY_ADDRESS       Treasury whose allowance settle() spends. Defaults to
///                          deployer (dev only — set the platform treasury in prod).
///   DVP_NAV_TOKEN          GyldBondToken series to NAV-band on P2P fills. The
///   DVP_NAV_FORWARDER      NAVFeedForwarder (8 decimals) for that series. BOTH
///                          must be set or step 2 is skipped with a log.
///   DVP_NAV_MAX_DEVIATION_BPS  NAV band width in bps. Defaults to 200 (2%).
///   DVP_NAV_MAX_AGE_SECS       Max feed age at fill time. Defaults to 86400 (24 h).
///
/// ── Usage — Anvil (local, after DeployDevNet + DeployMockUSDC) ─────────────
///   USDC_ADDRESS=<mock_usdc> \
///   EVM_ISSUANCE_MANAGER=<issuance_manager> \
///   forge script contracts/script/DeployDvpEscrow.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key $ANVIL_DEPLOYER_KEY
///
/// ── Usage — Hoodi testnet ──────────────────────────────────────────────────
///   export USDC_ADDRESS=<usdc_or_mock>
///   export EVM_ISSUANCE_MANAGER=<issuance_manager>
///   export TIMELOCK_ADDRESS=<timelock>
///   export OPS_MULTISIG=<gnosis_safe_address>
///   export TERMS_SIGNER=<kms_signer_address>
///   export SETTLER_ADDRESS=<ops_mpc_address>
///   export GUARDIAN_ADDRESS=<gnosis_safe_address>
///   export TREASURY_ADDRESS=<platform_treasury>
///   forge script contracts/script/DeployDvpEscrow.s.sol \
///     --rpc-url https://rpc.hoodi.ethpandaops.io \
///     --broadcast \
///     --private-key $PRIVKEY_SIGNING_KEY \
///     --verify
///
/// ── Outputs (set as gateway env vars) ──────────────────────────────────────
///   EVM_DVP_ESCROW         — GyldDvpEscrow (APs approve/permit bond tokens to THIS;
///                            treasury approves USDC to THIS before settles)
contract DeployDvpEscrow is Script {
    /// @dev Env-resolved constructor/handover config, bundled to keep run()'s
    ///      live-local count below the Yul stack limit (house idiom).
    struct Config {
        address usdc;
        address issuanceManager;
        address timelock;
        address pauser;
        address termsSigner;
        address settler;
        address guardian;
        address treasury;
    }

    function run() external {
        Config memory cfg = _loadConfig();

        vm.startBroadcast();

        // 1. Deploy — non-upgradeable, everything fixed in the constructor.
        //    Deployer is DEFAULT_ADMIN during setup (step 3 hands over) so the
        //    optional step-2 setNavConfig call is admin-authorized.
        GyldDvpEscrow escrow = new GyldDvpEscrow(
            msg.sender,
            cfg.pauser,
            cfg.termsSigner,
            cfg.settler,
            cfg.guardian,
            cfg.usdc,
            cfg.issuanceManager,
            cfg.treasury
        );
        console.log("EVM_DVP_ESCROW=%s", address(escrow));

        // 2. Optional dev convenience: per-series NAV band for P2P fills.
        //    Broadcaster == DEFAULT_ADMIN here by construction (pre-handover).
        _maybeSetNavConfig(escrow);

        // 3. Hand DEFAULT_ADMIN to the timelock and revoke the deployer (same
        //    pattern as DeployAtomicSettlement step 7). Skipped in dev when
        //    TIMELOCK_ADDRESS is unset so the deployer can keep iterating.
        if (cfg.timelock != address(0)) {
            bytes32 adminRole = escrow.DEFAULT_ADMIN_ROLE();
            escrow.grantRole(adminRole, cfg.timelock);
            escrow.revokeRole(adminRole, msg.sender);
            console.log("DEFAULT_ADMIN handed to timelock %s", cfg.timelock);
        } else {
            console.log("!! TIMELOCK_ADDRESS unset - deployer keeps DEFAULT_ADMIN (dev only)");
        }

        vm.stopBroadcast();

        // 4. Post-deploy sanity probes (view calls, outside the broadcast).
        _assertDeployment(escrow, cfg);
        _logEip712Domain(escrow);

        console.log("");
        console.log("=== DvP escrow deployment complete ===");
        console.log("Chain ID:              %d", block.chainid);
        console.log("EVM_DVP_ESCROW=%s", address(escrow));
        console.log("");
        console.log("=== Role assignments ===");
        console.log("DEFAULT_ADMIN:         %s", cfg.timelock != address(0) ? cfg.timelock : msg.sender);
        console.log("PAUSER (ops):          %s", cfg.pauser);
        console.log("TERMS_SIGNER:          %s", cfg.termsSigner);
        console.log("SETTLER:               %s", cfg.settler);
        console.log("GUARDIAN:              %s", cfg.guardian);
        console.log("TREASURY (immutable):  %s", cfg.treasury);
        console.log("");
        console.log("=== Next steps (docs/design/ap-dvp-escrow.md run-book) ===");
        console.log("  1. Treasury approves USDC to the escrow before the first settle():");
        console.log("     USDC.approve(%s, <allowance>) from %s", address(escrow), cfg.treasury);
        console.log("  2. Point the terms-service signing key at TERMS_SIGNER_ROLE and pin");
        console.log("     the EIP-712 domain logged above (golden-digest parity check)");
        console.log("  3. Gateway env: EVM_DVP_ESCROW (above)");
    }

    /// @dev Resolve every env var up front and log each parameter before any
    ///      state change, so a mis-set variable is visible in the dry run.
    function _loadConfig() internal view returns (Config memory cfg) {
        cfg.usdc            = vm.envAddress("USDC_ADDRESS");
        cfg.issuanceManager = vm.envAddress("EVM_ISSUANCE_MANAGER");
        cfg.timelock        = _envOrDefault("TIMELOCK_ADDRESS",  address(0));
        cfg.pauser          = _envOrDefault("OPS_MULTISIG",      msg.sender);
        cfg.termsSigner     = _envOrDefault("TERMS_SIGNER",      msg.sender);
        cfg.settler         = _envOrDefault("SETTLER_ADDRESS",   msg.sender);
        cfg.guardian        = _envOrDefault("GUARDIAN_ADDRESS",  cfg.pauser);
        cfg.treasury        = _envOrDefault("TREASURY_ADDRESS",  msg.sender);

        console.log("=== DeployDvpEscrow parameters ===");
        console.log("Broadcaster:           %s", msg.sender);
        console.log("USDC_ADDRESS:          %s", cfg.usdc);
        console.log("EVM_ISSUANCE_MANAGER:  %s", cfg.issuanceManager);
        console.log("TIMELOCK_ADDRESS:      %s", cfg.timelock);
        console.log("OPS_MULTISIG (pauser): %s", cfg.pauser);
        console.log("TERMS_SIGNER:          %s", cfg.termsSigner);
        console.log("SETTLER_ADDRESS:       %s", cfg.settler);
        console.log("GUARDIAN_ADDRESS:      %s", cfg.guardian);
        console.log("TREASURY_ADDRESS:      %s", cfg.treasury);
    }

    /// @dev Step 2 — optional per-series NAV band. Requires BOTH DVP_NAV_TOKEN and
    ///      DVP_NAV_FORWARDER; anything less is skipped with a log (prod default:
    ///      unset — the band is configured later via the timelock).
    function _maybeSetNavConfig(GyldDvpEscrow escrow) internal {
        address navToken     = _envOrDefault("DVP_NAV_TOKEN",     address(0));
        address navForwarder = _envOrDefault("DVP_NAV_FORWARDER", address(0));
        if (navToken == address(0) || navForwarder == address(0)) {
            console.log("DVP_NAV_TOKEN/DVP_NAV_FORWARDER unset - configure NAV band later via setNavConfig");
            return;
        }
        uint16 maxDeviationBps = uint16(vm.envOr("DVP_NAV_MAX_DEVIATION_BPS", uint256(200)));
        uint32 maxAgeSecs      = uint32(vm.envOr("DVP_NAV_MAX_AGE_SECS",      uint256(86400)));

        // setNavConfig probes forwarder.decimals() == 8 on-chain; reverts otherwise.
        escrow.setNavConfig(navToken, navForwarder, maxDeviationBps, maxAgeSecs);
        console.log("NAV band set: token %s forwarder %s", navToken, navForwarder);
        console.log("  maxDeviationBps: %d, maxAgeSecs: %d", maxDeviationBps, maxAgeSecs);

        GyldDvpEscrow.NavConfig memory nc = escrow.navConfigOf(navToken);
        require(nc.forwarder == navForwarder,      "DeployDvpEscrow: navConfig forwarder mismatch");
        require(nc.maxDeviationBps == maxDeviationBps, "DeployDvpEscrow: navConfig bps mismatch");
        require(nc.maxAgeSecs == maxAgeSecs,       "DeployDvpEscrow: navConfig maxAge mismatch");
    }

    /// @dev Step 4a — read back every immutable and verify all five role grants.
    ///      A failure here means the deployment is mis-wired: stop and investigate
    ///      before pointing any off-chain service at the address.
    function _assertDeployment(GyldDvpEscrow escrow, Config memory cfg) internal view {
        require(address(escrow.USDC()) == cfg.usdc,                         "DeployDvpEscrow: USDC immutable mismatch");
        require(address(escrow.ISSUANCE_MANAGER()) == cfg.issuanceManager,  "DeployDvpEscrow: ISSUANCE_MANAGER immutable mismatch");
        require(escrow.TREASURY() == cfg.treasury,                          "DeployDvpEscrow: TREASURY immutable mismatch");

        address expectedAdmin = cfg.timelock != address(0) ? cfg.timelock : msg.sender;
        require(escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), expectedAdmin), "DeployDvpEscrow: DEFAULT_ADMIN_ROLE not held by expected admin");
        if (cfg.timelock != address(0)) {
            require(!escrow.hasRole(escrow.DEFAULT_ADMIN_ROLE(), msg.sender), "DeployDvpEscrow: deployer still holds DEFAULT_ADMIN_ROLE");
        }
        require(escrow.hasRole(escrow.PAUSER_ROLE(),       cfg.pauser),      "DeployDvpEscrow: PAUSER_ROLE not held by pauser");
        require(escrow.hasRole(escrow.TERMS_SIGNER_ROLE(), cfg.termsSigner), "DeployDvpEscrow: TERMS_SIGNER_ROLE not held by terms signer");
        require(escrow.hasRole(escrow.SETTLER_ROLE(),      cfg.settler),     "DeployDvpEscrow: SETTLER_ROLE not held by settler");
        require(escrow.hasRole(escrow.GUARDIAN_ROLE(),     cfg.guardian),    "DeployDvpEscrow: GUARDIAN_ROLE not held by guardian");

        console.log("");
        console.log("=== Post-deploy assertions PASSED ===");
        console.log("USDC:                  %s (read back)", address(escrow.USDC()));
        console.log("ISSUANCE_MANAGER:      %s (read back)", address(escrow.ISSUANCE_MANAGER()));
        console.log("TREASURY:              %s (read back)", escrow.TREASURY());
        console.log("All five roles verified via hasRole.");
    }

    /// @dev Step 4b — log (and assert) the EIP-712 domain via ERC-5267. The
    ///      off-chain terms service must reproduce exactly these four fields
    ///      (name/version/chainId/verifyingContract) or every signature will
    ///      recover to a stranger and deposit() will revert InvalidTermsSigner.
    function _logEip712Domain(GyldDvpEscrow escrow) internal view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            escrow.eip712Domain();
        require(keccak256(bytes(name)) == keccak256("GyldDvpEscrow"), "DeployDvpEscrow: EIP-712 domain name mismatch");
        require(keccak256(bytes(version)) == keccak256("1"),          "DeployDvpEscrow: EIP-712 domain version mismatch");
        require(chainId == block.chainid,                             "DeployDvpEscrow: EIP-712 domain chainId mismatch");
        require(verifyingContract == address(escrow),                 "DeployDvpEscrow: EIP-712 verifyingContract mismatch");

        console.log("");
        console.log("=== EIP-712 domain (pin these in the terms service) ===");
        console.log("name:                  %s", name);
        console.log("version:               %s", version);
        console.log("chainId:               %d", chainId);
        console.log("verifyingContract:     %s", verifyingContract);
    }

    function _envOrDefault(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            return val;
        } catch {
            return fallback_;
        }
    }
}
