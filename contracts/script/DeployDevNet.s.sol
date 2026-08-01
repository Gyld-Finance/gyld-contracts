// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "../test/MockSanctionsList.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";

/// @title DeployDevNet
/// @notice Deploys the Kaleidoscope token stack to Anvil / Hoodi using GyldBondToken.
///
/// Compliance: each token reads from the configured on-chain sanctions oracle (read-only).
/// On every production EVM chain — including Ethereum mainnet — that is the
/// platform-operated SanctionsOracleMirror, passed in via the SANCTIONS_LIST env var
/// (GYL-1051). On devnet/Hoodi a MockSanctionsList is deployed instead so the gateway
/// `mock_sanction_address` endpoint can flip addresses without a live oracle.
///
/// Role model — each role gets a dedicated address, all fall back to deployer in dev:
///
///   GOVERNANCE_MULTISIG  →  TimelockController proposer; IssuanceManager DEFAULT_ADMIN
///                           passes through the timelock (48-hour delay in prod)
///   OPS_MULTISIG         →  Token operator: PAUSER_ROLE on each token
///                           (no delay — hot wallet for emergency pause)
///   SUBSCRIBER_ADDRESS   →  IssuanceManager SUBSCRIBER_ROLE (subscribe/mint calls only)
///                           In prod: platform MPC wallet / Fordefi — mint quorum
///   REDEEMER_ADDRESS     →  IssuanceManager REDEEMER_ROLE (redeem/burn calls only)
///                           In prod: platform MPC wallet / Fordefi — burn quorum (separate)
///   WHITELIST_ADMIN      →  IssuanceManager WHITELIST_ADMIN_ROLE (AP whitelist mgmt)
///                           In prod: ops Gnosis Safe
///   NAV_FEED_OWNER       →  KaleidoscopeNAVFeed owner (updateAnswer calls) and
///                           UI_MULTIPLIER_ROLE on each GyldBondToken
///                           (setUiMultiplier calls — published in lockstep with NAV
///                           by the same process, so one signer serves both)
///                           In prod: KMS signer
///
/// A TimelockController is deployed and wired as:
///   - DEFAULT_ADMIN_ROLE on each GyldBondToken
///   - DEFAULT_ADMIN_ROLE on IssuanceManager (after initial setup)
///   - Owner of TokenFactory
///
/// Env vars (optional, all default to zero-delay on Anvil):
///   TIMELOCK_DELAY_SECONDS — override delay; default 0 for Anvil (chainId 31337),
///                            172800 (48 h) for all other chains.
///
/// Usage — Anvil (local):
///   anvil &
///   forge script contracts/script/DeployDevNet.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key ANVIL_TEST_KEY_REDACTED
///
/// Usage — Hoodi testnet (each env var is a real Gnosis Safe / KMS address):
///   export GOVERNANCE_MULTISIG=<gnosis_safe_address>
///   export OPS_MULTISIG=<gnosis_safe_address>
///   export SUBSCRIBER_ADDRESS=<fordefi_mint_mpc_address>
///   export REDEEMER_ADDRESS=<fordefi_burn_mpc_address>
///   export WHITELIST_ADMIN=<gnosis_safe_address>
///   export NAV_FEED_OWNER=<kms_signer_address>
///   forge script contracts/script/DeployDevNet.s.sol \
///     --rpc-url https://rpc.hoodi.ethpandaops.io \
///     --broadcast \
///     --private-key $PRIVKEY_SIGNING_KEY
///
/// Outputs (set as gateway env vars):
///   EVM_FACTORY_ADDRESS      — TokenFactory
///   EVM_ISSUANCE_MANAGER     — IssuanceManager
///   MOCK_SANCTIONS_ADDRESS   — MockSanctionsList (devnet only)
///   TOKEN_CAT                — Caterpillar Inc 3.7% 2028 (CUSIP 14913UBF6)
///   TOKEN_C                  — Citigroup Inc 3.887% 2028 (CUSIP 172967LD1)
///   TOKEN_KO                 — Coca-Cola Co 2.25% 2032 (CUSIP 191216DP2)
contract DeployDevNet is Script {
    function run() external {
        // Each role resolves to its own env var, falling back to msg.sender so that
        // `forge script ... --private-key <deployer>` works with zero config in dev.
        // msg.sender is used inline rather than stored in a local to keep the function's
        // live-variable count below the Yul stack limit (16 simultaneous slots).
        address governanceMultisig = _envOrDefault("GOVERNANCE_MULTISIG", msg.sender);
        address opsMultisig        = _envOrDefault("OPS_MULTISIG",        msg.sender);
        address subscriberAddress  = _envOrDefault("SUBSCRIBER_ADDRESS",  msg.sender);
        address redeemerAddress    = _envOrDefault("REDEEMER_ADDRESS",    msg.sender);
        address whitelistAdmin     = _envOrDefault("WHITELIST_ADMIN",     msg.sender);
        address navFeedOwner       = _envOrDefault("NAV_FEED_OWNER",      msg.sender);

        // Timelock delay: 0 for Anvil (instant execution for dev convenience),
        // 172800 seconds (48 h) for any other chain. Override via TIMELOCK_DELAY_SECONDS.
        uint256 timelockDelay;
        try vm.envUint("TIMELOCK_DELAY_SECONDS") returns (uint256 d) {
            timelockDelay = d;
        } catch {
            timelockDelay = block.chainid == 31337 ? 0 : 172800;
        }

        vm.startBroadcast();

        // 1. Deploy TimelockController.
        //    proposers = [governanceMultisig]
        //    executors = [address(0)]  (anyone can execute after the delay)
        //    admin     = address(0)    (self-administered — no bypass role)
        TimelockController timelock;
        {
            address[] memory proposers = new address[](1);
            proposers[0] = governanceMultisig;
            address[] memory executors = new address[](1);
            executors[0] = address(0);
            timelock = new TimelockController(
                timelockDelay,
                proposers,
                executors,
                address(0)
            );
        }
        console.log("TIMELOCK_ADDRESS=%s", address(timelock));
        console.log("  Delay: %d seconds", timelockDelay);

        // 2 + 3. Deploy logic contracts and wrap in proxy immediately so their
        //        stack slots are freed before the rest of the deployment proceeds.
        //        (Inlining avoids two dead local variables that would otherwise
        //        exhaust the EVM stack when coverage instrumentation is enabled.)
        IssuanceManager issuanceMgr = IssuanceManager(address(new ERC1967Proxy(
            address(new IssuanceManager()),
            abi.encodeCall(IssuanceManager.initialize, (msg.sender, subscriberAddress, redeemerAddress))
        )));

        // 4. Grant WHITELIST_ADMIN_ROLE to its dedicated address.
        issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), whitelistAdmin);

        console.log("ISSUANCE_MANAGER=%s", address(issuanceMgr));

        // 5. Sanctions oracle: use SANCTIONS_LIST env var if set — on production chains that
        //    is the platform SanctionsOracleMirror address; otherwise deploy MockSanctionsList
        //    on devnet. Blocked on mainnet — wiring a mock would silently defeat the
        //    compliance model.
        address sanctionsOracle = _envOrDefault("SANCTIONS_LIST", address(0));
        if (sanctionsOracle == address(0)) {
            require(block.chainid != 1, "DeployDevNet: set SANCTIONS_LIST=<sanctions_oracle> on mainnet");
            MockSanctionsList mock = new MockSanctionsList();
            sanctionsOracle = address(mock);
            console.log("MOCK_SANCTIONS_ADDRESS=%s", sanctionsOracle);
            console.log("  (set CHAINALYSIS_SANCTIONS_CONTRACT=%s for the gateway)", sanctionsOracle);
        }

        // 6. Deploy TokenFactory — all tokens share the same sanctions oracle.
        //    Bond logic impl is inlined to avoid a dead stack slot from step 2.
        TokenFactory factory = new TokenFactory(address(new GyldBondToken()), sanctionsOracle);
        console.log("FACTORY_ADDRESS=%s", address(factory));

        // 7. Grant factory REGISTRAR_ROLE so deployToken can register tokens with the manager.
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));

        // 8. Whitelist the subscriber address so it can act as AP in dev end-to-end tests.
        issuanceMgr.addToWhitelist(subscriberAddress);
        // Also whitelist Anvil account[1] so the redemption e2e test can use it as
        // the investor (beneficiary in IssuanceManager.redeem). In prod all investors
        // are whitelisted during KYC onboarding.
        issuanceMgr.addToWhitelist(0x70997970C51812dc3A010C7d01b50e0d17dc79C8);

        // 9. Hand DEFAULT_ADMIN on IssuanceManager to the timelock.
        {
            bytes32 adminRole = issuanceMgr.DEFAULT_ADMIN_ROLE();
            issuanceMgr.grantRole(adminRole, address(timelock));
            issuanceMgr.revokeRole(adminRole, msg.sender);
        }

        // 10. Transfer factory ownership to timelock BEFORE deploying tokens.
        //     TokenFactory._wireRoles() assigns DEFAULT_ADMIN_ROLE on each token to
        //     factory.owner() at call time. Ownership must be the timelock before any
        //     deployToken call so that every token's DEFAULT_ADMIN is the timelock —
        //     not the deployer EOA — from birth.
        factory.transferOwnership(address(timelock));

        if (timelockDelay == 0) {
            // Dev path (Anvil): immediately schedule + execute acceptOwnership so the
            // factory owner is the timelock before we deploy any bond tokens.
            bytes memory acceptData = abi.encodeCall(factory.acceptOwnership, ());
            timelock.schedule(address(factory), 0, acceptData, bytes32(0), bytes32("accept"), 0);
            timelock.execute(address(factory), 0, acceptData, bytes32(0), bytes32("accept"));
            console.log("Factory ownership accepted by timelock (delay=0, instant on Anvil).");
            require(factory.owner() == address(timelock), "DeployDevNet: factory owner must be timelock before deployToken");
        } else {
            // Non-Anvil path: the timelock delay has not elapsed, so acceptOwnership
            // cannot be executed in this script run. Token deployment requires the
            // factory owner to be the timelock, so we stop here.
            //
            // Phase 2 instructions — after the delay has elapsed:
            //   a) Governance multisig: schedule factory.acceptOwnership() via timelock
            //   b) Wait %d seconds, then execute acceptOwnership
            //   c) Deploy each bond token via a separate deployToken call through the timelock
            console.log("Factory pending owner: timelock. Delay not yet elapsed - skipping token deployment.");
            console.log("=== Phase 2 required (non-Anvil) ===");
            console.log("After %d seconds have elapsed:", timelockDelay);
            console.log("  Step 1: Governance multisig schedules factory.acceptOwnership() via timelock");
            console.log("          target = %s (factory)", address(factory));
            console.log("          data   = factory.acceptOwnership() (0x79ba5097)");
            console.log("          delay  >= %d seconds", timelockDelay);
            console.log("  Step 2: Wait %d seconds, then execute acceptOwnership", timelockDelay);
            console.log("  Step 3: Deploy bond tokens via separate deployToken calls through the timelock");
            console.log("          (factory.owner() will then be the timelock, so DEFAULT_ADMIN on each");
            console.log("           token will be set correctly to the timelock - not the deployer EOA)");

            vm.stopBroadcast();

            console.log("");
            console.log("=== Phase 1 deployment complete ===");
            console.log("Chain ID:              %d", block.chainid);
            console.log("Timelock:              %s  (delay: %d s)", address(timelock), timelockDelay);
            console.log("Factory:               %s  (pending owner: timelock)", address(factory));
            console.log("IssuanceManager:       %s", address(issuanceMgr));
            console.log("SanctionsList:         %s", factory.sanctionsList());
            console.log("");
            console.log("=== Role assignments ===");
            console.log("GOVERNANCE_MULTISIG:   %s  (timelock proposer)", governanceMultisig);
            console.log("TIMELOCK:              %s  (IssuanceManager DEFAULT_ADMIN, pending factory owner)", address(timelock));
            console.log("OPS_MULTISIG:          %s  (token PAUSER - set at Phase 2)", opsMultisig);
            console.log("SUBSCRIBER_ADDRESS:    %s  (IssuanceManager SUBSCRIBER_ROLE)", subscriberAddress);
            console.log("REDEEMER_ADDRESS:      %s  (IssuanceManager REDEEMER_ROLE)", redeemerAddress);
            console.log("WHITELIST_ADMIN:       %s  (IssuanceManager WHITELIST_ADMIN_ROLE)", whitelistAdmin);
            console.log("NAV_FEED_OWNER:        %s  (NAVFeed owner, token UI_MULTIPLIER_ROLE - set at Phase 2)", navFeedOwner);
            console.log("");
            console.log("Next: set these env vars for Phase 2:");
            console.log("  EVM_FACTORY_ADDRESS=%s", address(factory));
            console.log("  EVM_ISSUANCE_MANAGER=%s", address(issuanceMgr));
            console.log("  EVM_RPC_URL=<rpc_url>");
            console.log("  TIMELOCK_ADDRESS=%s", address(timelock));
            return;
        }

        // 11. Deploy dev bond tokens — factory.owner() is now the timelock, so
        //     _wireRoles() will assign DEFAULT_ADMIN_ROLE on each token to the timelock.
        //     Extracted into a helper to keep the run() stack below 16 live locals.
        _deployBondTokens(factory, opsMultisig, address(issuanceMgr), navFeedOwner);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("Chain ID:              %d", block.chainid);
        console.log("Timelock:              %s  (delay: %d s)", address(timelock), timelockDelay);
        console.log("Factory:               %s", address(factory));
        console.log("IssuanceManager:       %s", address(issuanceMgr));
        console.log("SanctionsList:         %s", factory.sanctionsList());
        console.log("(TOKEN_CAT, TOKEN_C, TOKEN_KO and their feeds logged above)");
        console.log("");
        console.log("=== Role assignments ===");
        console.log("GOVERNANCE_MULTISIG:   %s  (timelock proposer)", governanceMultisig);
        console.log("TIMELOCK:              %s  (token DEFAULT_ADMIN, IssuanceManager DEFAULT_ADMIN, factory owner)", address(timelock));
        console.log("OPS_MULTISIG:          %s  (token PAUSER)", opsMultisig);
        console.log("SUBSCRIBER_ADDRESS:    %s  (IssuanceManager SUBSCRIBER_ROLE)", subscriberAddress);
        console.log("REDEEMER_ADDRESS:      %s  (IssuanceManager REDEEMER_ROLE)", redeemerAddress);
        console.log("WHITELIST_ADMIN:       %s  (IssuanceManager WHITELIST_ADMIN_ROLE)", whitelistAdmin);
        console.log("NAV_FEED_OWNER:        %s  (NAVFeed owner, token UI_MULTIPLIER_ROLE)", navFeedOwner);
        console.log("");
        console.log("Next: set these env vars for the gateway:");
        console.log("  EVM_FACTORY_ADDRESS=%s", address(factory));
        console.log("  EVM_ISSUANCE_MANAGER=%s", address(issuanceMgr));
        console.log("  (TOKEN_CAT, TOKEN_C, TOKEN_KO logged above)");
        console.log("  EVM_RPC_URL=http://127.0.0.1:8545");
        console.log("  EVM_CHAIN_ID=31337");
        console.log("  PRIVKEY_SIGNING_KEY=<anvil-account-private-key>");
        console.log("  CHAINALYSIS_SANCTIONS_CONTRACT=%s", factory.sanctionsList());
    }

    /// @dev Deploy the three dev bond tokens via the timelock and log their addresses.
    ///      factory.owner() must already be the timelock before calling this.
    ///      Return values from deployToken are unavailable through timelock.execute, so
    ///      we predict each token address with predictTokenAddress and read navFeed/forwarder
    ///      from factory mappings after the execute call.
    function _deployBondTokens(
        TokenFactory factory,
        address operator,
        address issuanceMgr,
        address navFeedOwner
    ) internal {
        TimelockController timelock = TimelockController(payable(factory.owner()));

        // CAT — Caterpillar Inc 3.7% 2028 (ISIN US14913UBF62, CUSIP 14913UBF6, matures 2028-09-06)
        {
            address cat = factory.predictTokenAddress("Caterpillar Inc 3.7% 2028", "14913UBF6", "US14913UBF62", 1_788_739_200);
            bytes memory data = abi.encodeCall(
                factory.deployToken,
                ("Caterpillar Inc 3.7% 2028", "14913UBF6", "US14913UBF62",
                 1_788_739_200, operator, issuanceMgr, navFeedOwner)
            );
            timelock.schedule(address(factory), 0, data, bytes32(0), bytes32("deploy_cat"), 0);
            timelock.execute(address(factory), 0, data, bytes32(0), bytes32("deploy_cat"));
            console.log("TOKEN_CAT=%s", cat);
            console.log("NAVFEED_CAT=%s", factory.navFeedOf(cat));
            console.log("FORWARDER_CAT=%s  (give this to Morpho/Aave)", factory.forwarderOf(cat));
        }

        // C — Citigroup Inc 3.887% 2028 (ISIN US172967LD16, CUSIP 172967LD1, matures 2028-01-10)
        {
            address c = factory.predictTokenAddress("Citigroup Inc 3.887% 2028", "172967LD1", "US172967LD16", 1_767_052_800);
            bytes memory data = abi.encodeCall(
                factory.deployToken,
                ("Citigroup Inc 3.887% 2028", "172967LD1", "US172967LD16",
                 1_767_052_800, operator, issuanceMgr, navFeedOwner)
            );
            timelock.schedule(address(factory), 0, data, bytes32(0), bytes32("deploy_c"), 0);
            timelock.execute(address(factory), 0, data, bytes32(0), bytes32("deploy_c"));
            console.log("TOKEN_C=%s", c);
            console.log("NAVFEED_C=%s", factory.navFeedOf(c));
            console.log("FORWARDER_C=%s  (give this to Morpho/Aave)", factory.forwarderOf(c));
        }

        // KO — Coca-Cola Co 2.25% 2032 (ISIN US191216DP29, CUSIP 191216DP2, matures 2032-09-01)
        {
            address ko = factory.predictTokenAddress("Coca-Cola Co 2.25% 2032", "191216DP2", "US191216DP29", 1_975_017_600);
            bytes memory data = abi.encodeCall(
                factory.deployToken,
                ("Coca-Cola Co 2.25% 2032", "191216DP2", "US191216DP29",
                 1_975_017_600, operator, issuanceMgr, navFeedOwner)
            );
            timelock.schedule(address(factory), 0, data, bytes32(0), bytes32("deploy_ko"), 0);
            timelock.execute(address(factory), 0, data, bytes32(0), bytes32("deploy_ko"));
            console.log("TOKEN_KO=%s", ko);
            console.log("NAVFEED_KO=%s", factory.navFeedOf(ko));
            console.log("FORWARDER_KO=%s  (give this to Morpho/Aave)", factory.forwarderOf(ko));
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
