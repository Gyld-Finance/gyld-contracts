// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "../test/MockSanctionsList.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title DeployDevNet
/// @notice Deploys the Kaleidoscope token stack using GyldBondToken.
///
/// Compliance: each token reads from the configured on-chain sanctions oracle (read-only).
/// On every production EVM chain that is the platform-operated SanctionsOracleMirror,
/// passed in via the SANCTIONS_LIST env var (GYL-1051). On a dev chain (Anvil 31337 /
/// Sepolia 11155111) a MockSanctionsList is deployed instead so the gateway
/// `mock_sanction_address` endpoint can flip addresses without a live oracle.
///
/// ── Dev vs production (GYL-1135) ──────────────────────────────────────────────
/// Development chains are an ALLOWLIST: 31337 and 11155111 only (see
/// {DeployGuards.isDevChain}). Everything else — Ethereum, Arbitrum, every L2, and every
/// chain that does not exist yet — takes the production path, where:
///   * every privileged env var below is REQUIRED and must not be the deployer EOA;
///   * TIMELOCK_DELAY_SECONDS is REQUIRED and must be >= 48h;
///   * SANCTIONS_LIST is REQUIRED and must be a contract (no mock is ever deployed);
///   * SUBSCRIBER_ADDRESS and REDEEMER_ADDRESS must differ (mint/burn quorum split);
///   * Anvil account[1] is NOT whitelisted (its private key is public);
///   * the final role topology is asserted in-band, inside the broadcast, so a
///     mismatch aborts the deploy instead of shipping a half-configured stack.
///
/// Role model — each role gets a dedicated address, all fall back to the deployer on
/// a dev chain ONLY:
///
///   GOVERNANCE_MULTISIG  →  TimelockController proposer; IssuanceManager DEFAULT_ADMIN
///                           passes through the timelock (>= 48-hour delay in prod)
///   OPS_MULTISIG         →  Token operator: PAUSER_ROLE on each token
///                           (no delay — hot wallet for emergency pause)
///   SUBSCRIBER_ADDRESS   →  IssuanceManager SUBSCRIBER_ROLE (subscribe/mint calls only)
///                           In prod: platform MPC wallet / Fordefi — mint quorum
///   REDEEMER_ADDRESS     →  IssuanceManager REDEEMER_ROLE (redeem/burn calls only)
///                           In prod: platform MPC wallet / Fordefi — burn quorum (separate)
///   WHITELIST_ADMIN      →  IssuanceManager WHITELIST_ADMIN_ROLE (AP whitelist mgmt)
///                           In prod: ops Gnosis Safe
///   NAV_FEED_OWNER       →  KaleidoscopeNAVFeed owner (updateAnswer calls)
///                           In prod: KMS signer
///   SANCTIONS_LIST       →  SanctionsOracleMirror (prod) / MockSanctionsList (dev)
///
/// A TimelockController is deployed and wired as:
///   - DEFAULT_ADMIN_ROLE on each GyldBondToken
///   - DEFAULT_ADMIN_ROLE on IssuanceManager (after initial setup)
///   - Owner of TokenFactory
///
/// ── Deterministic addresses ───────────────────────────────────────────────────
/// Bootstrap contracts are deployed through the canonical CREATE2 proxy with a
/// chain-scoped salt (see {DeployGuards.saltFor}) so the same deployer+nonce can no
/// longer produce the SAME address for DIFFERENT contracts on two chains. Every bootstrap
/// contract goes through it, TokenFactory included (it took an explicit `owner_` parameter
/// in GYL-1135 so that the CREATE2 proxy does not end up owning it).
///
/// Usage — Anvil (local):
///   anvil &
///   forge script contracts/script/DeployDevNet.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key <anvil_account_0_key>
///
/// Usage — production (every env var is a real Gnosis Safe / KMS address):
///   export GOVERNANCE_MULTISIG=<gnosis_safe_address>
///   export OPS_MULTISIG=<gnosis_safe_address>
///   export SUBSCRIBER_ADDRESS=<fordefi_mint_mpc_address>
///   export REDEEMER_ADDRESS=<fordefi_burn_mpc_address>
///   export WHITELIST_ADMIN=<gnosis_safe_address>
///   export NAV_FEED_OWNER=<kms_signer_address>
///   export SANCTIONS_LIST=<sanctions_oracle_mirror>
///   export TIMELOCK_DELAY_SECONDS=172800
///   forge script contracts/script/DeployDevNet.s.sol \
///     --rpc-url $EVM_RPC_URL --broadcast --private-key $PRIVKEY_SIGNING_KEY
///
/// Outputs (set as gateway env vars):
///   EVM_FACTORY_ADDRESS      — TokenFactory
///   EVM_ISSUANCE_MANAGER     — IssuanceManager
///   MOCK_SANCTIONS_ADDRESS   — MockSanctionsList (dev chains only)
///   TOKEN_CAT                — Caterpillar Inc 3.7% 2028 (CUSIP 14913UBF6)
///   TOKEN_C                  — Citigroup Inc 3.887% 2028 (CUSIP 172967LD1)
///   TOKEN_KO                 — Coca-Cola Co 2.25% 2032 (CUSIP 191216DP2)
contract DeployDevNet is Script {
    /// Resolved deployment configuration. Held in one memory struct rather than a
    /// dozen locals so `run()` stays under the Yul 16-slot stack limit.
    struct Config {
        address deployer;
        address governanceMultisig;
        address opsMultisig;
        address subscriber;
        address redeemer;
        address whitelistAdmin;
        address navFeedOwner;
        address sanctionsList; // address(0) on a dev chain ⇒ deploy a MockSanctionsList
        uint256 delay;
    }

    // ── Outputs — public storage so tests and follow-up scripts can read them ──
    TimelockController public timelock;
    IssuanceManager public issuanceMgr;
    TokenFactory public factory;
    address public sanctionsOracle;
    uint256 public timelockDelay;
    /// True when the factory ownership hand-off completed in this run (dev, delay == 0).
    bool public factoryOwnershipAccepted;
    /// Bond-token proxies deployed by THIS run. Empty unless {factoryOwnershipAccepted};
    /// on production the series are deployed in Phase 2, by governance, not here.
    address[] public bondTokens;

    function bondTokenCount() external view returns (uint256) {
        return bondTokens.length;
    }

    function run() external {
        Config memory cfg = _config();
        timelockDelay = cfg.delay;

        vm.startBroadcast();

        _deployTimelock(cfg);
        _deployIssuanceManager(cfg);
        _deploySanctionsAndFactory(cfg);
        _wireIssuanceManager(cfg);
        _handOverToTimelock(cfg);

        if (factoryOwnershipAccepted) {
            // factory.owner() is now the timelock, so TokenFactory._wireRoles() assigns
            // DEFAULT_ADMIN_ROLE on each token to the timelock — never the deployer EOA.
            _deployBondTokens(factory, cfg.opsMultisig, address(issuanceMgr), cfg.navFeedOwner);
        }

        // In-band post-deploy assertions: still inside the broadcast, so any mismatch
        // aborts the deployment rather than leaving a half-configured stack on chain.
        _assertFinalTopology(cfg);

        vm.stopBroadcast();

        _logSummary(cfg);
    }

    // ── Configuration ─────────────────────────────────────────────────────────

    /// @dev Resolves and validates every env var BEFORE any gas is spent.
    function _config() internal view returns (Config memory c) {
        c.deployer = DeployGuards.broadcaster();

        c.governanceMultisig = DeployGuards.envAddressProdRequired("GOVERNANCE_MULTISIG", c.deployer);
        c.opsMultisig = DeployGuards.envAddressProdRequired("OPS_MULTISIG", c.deployer);
        c.subscriber = DeployGuards.envAddressProdRequired("SUBSCRIBER_ADDRESS", c.deployer);
        c.redeemer = DeployGuards.envAddressProdRequired("REDEEMER_ADDRESS", c.deployer);
        c.whitelistAdmin = DeployGuards.envAddressProdRequired("WHITELIST_ADMIN", c.deployer);
        c.navFeedOwner = DeployGuards.envAddressProdRequired("NAV_FEED_OWNER", c.deployer);

        // On production none of these may be the broadcasting EOA — that is precisely
        // the shape of the GYL-1135 incident, where "handover complete" meant nothing moved.
        DeployGuards.requireNotDeployer(c.governanceMultisig, c.deployer, "GOVERNANCE_MULTISIG");
        DeployGuards.requireNotDeployer(c.opsMultisig, c.deployer, "OPS_MULTISIG");
        DeployGuards.requireNotDeployer(c.subscriber, c.deployer, "SUBSCRIBER_ADDRESS");
        DeployGuards.requireNotDeployer(c.redeemer, c.deployer, "REDEEMER_ADDRESS");
        DeployGuards.requireNotDeployer(c.whitelistAdmin, c.deployer, "WHITELIST_ADMIN");
        DeployGuards.requireNotDeployer(c.navFeedOwner, c.deployer, "NAV_FEED_OWNER");

        // Mint and burn are a deliberate two-key quorum; one address holding both
        // collapses it back into a single point of compromise.
        DeployGuards.requireDistinct(c.subscriber, c.redeemer, "SUBSCRIBER_ADDRESS", "REDEEMER_ADDRESS");

        // Delay: required on production and never below 48h. On Anvil it defaults to 0
        // (instant schedule+execute for dev convenience); on any other dev chain, 48h.
        c.delay = DeployGuards.envUintProdRequired(
            "TIMELOCK_DELAY_SECONDS", block.chainid == DeployGuards.ANVIL_CHAIN_ID ? 0 : 48 hours
        );
        DeployGuards.requireProdMinDelay(c.delay);

        // Sanctions oracle: required (and must be a real contract) on production;
        // may be omitted on a dev chain, where a MockSanctionsList is deployed instead.
        c.sanctionsList = DeployGuards.envAddressProdRequired("SANCTIONS_LIST", address(0));
        if (c.sanctionsList != address(0)) {
            DeployGuards.requireProdContract(c.sanctionsList, "SANCTIONS_LIST");
            // `code.length != 0` cannot tell a real oracle from a mock, and a mock the
            // scripts deployed earlier (on a chain where they used to be ungated) would
            // otherwise sail through as SANCTIONS_LIST. Refuse this repo's mock by bytecode.
            DeployGuards.requireProdNotMock(
                c.sanctionsList, type(MockSanctionsList).runtimeCode, "SANCTIONS_LIST"
            );
        }
    }

    // ── Deployment steps ──────────────────────────────────────────────────────

    /// @dev 1. TimelockController.
    ///        proposers = [governanceMultisig]
    ///        executors = [address(0)]  (anyone can execute after the delay)
    ///        admin     = address(0)    (self-administered — no bypass role)
    function _deployTimelock(Config memory c) internal {
        address[] memory proposers = new address[](1);
        proposers[0] = c.governanceMultisig;
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        timelock = new TimelockController{
            salt: DeployGuards.vacantSalt(
                "DeployDevNet:TimelockController",
                abi.encodePacked(
                    type(TimelockController).creationCode, abi.encode(c.delay, proposers, executors, address(0))
                )
            )
        }(c.delay, proposers, executors, address(0));

        console.log("TIMELOCK_ADDRESS=%s", address(timelock));
        console.log("  Delay: %d seconds", c.delay);
    }

    /// @dev 2. IssuanceManager implementation + ERC1967 proxy. The deployer is the
    ///         initial DEFAULT_ADMIN purely so it can complete setup; it is revoked in
    ///         {_handOverToTimelock} and the revocation is asserted before the broadcast ends.
    function _deployIssuanceManager(Config memory c) internal {
        address impl = address(
            new IssuanceManager{
                salt: DeployGuards.vacantSalt("DeployDevNet:IssuanceManager.impl", type(IssuanceManager).creationCode)
            }()
        );
        bytes memory initData =
            abi.encodeCall(IssuanceManager.initialize, (c.deployer, c.subscriber, c.redeemer));

        issuanceMgr = IssuanceManager(
            address(
                new ERC1967Proxy{
                    salt: DeployGuards.vacantSalt(
                        "DeployDevNet:IssuanceManager.proxy",
                        abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData))
                    )
                }(impl, initData)
            )
        );
        console.log("ISSUANCE_MANAGER=%s", address(issuanceMgr));
    }

    /// @dev 3. Sanctions oracle (real on production, mock on a dev chain) + TokenFactory.
    function _deploySanctionsAndFactory(Config memory c) internal {
        sanctionsOracle = c.sanctionsList;
        if (sanctionsOracle == address(0)) {
            // Wiring a writable mock as the compliance oracle would silently defeat the
            // whole sanctions model, so it is allowed on dev chains ONLY. This replaces
            // the old `block.chainid != 1` check, which every L2 walked straight past.
            DeployGuards.requireProdSafe("deploying a MockSanctionsList as the compliance oracle");
            // The mock's list is writable by its OWNER only, and the owner is passed
            // explicitly: deployed through the CREATE2 proxy, `msg.sender` inside the
            // constructor is 0x4e59…4956C, so an `owner = msg.sender` mock would be owned
            // by the proxy and unusable by the gateway.
            bytes memory mockInit =
                abi.encodePacked(type(MockSanctionsList).creationCode, abi.encode(c.deployer));
            sanctionsOracle = address(
                new MockSanctionsList{salt: DeployGuards.vacantSalt("DeployDevNet:MockSanctionsList", mockInit)}(
                    c.deployer
                )
            );
            console.log("MOCK_SANCTIONS_ADDRESS=%s", sanctionsOracle);
            console.log("  (set CHAINALYSIS_SANCTIONS_CONTRACT=%s for the gateway)", sanctionsOracle);
            console.log("  (sanctions list is writable by MOCK_SANCTIONS_OWNER=%s only)", c.deployer);
        }

        address bondImpl = address(
            new GyldBondToken{
                salt: DeployGuards.vacantSalt("DeployDevNet:GyldBondToken.impl", type(GyldBondToken).creationCode)
            }()
        );

        // TokenFactory now takes an explicit `owner_` (GYL-1135), so it can join the other
        // bootstrap contracts on the chain-salted CREATE2 proxy: previously
        // `Ownable(msg.sender)` would have made 0x4e59…4956C the owner and permanently
        // bricked `transferOwnership`. Deployed with plain CREATE it was the LAST bootstrap
        // contract whose address was `keccak(deployer, nonce)` — no chain component — which
        // is exactly how `0x18ce55…6317` ended up a GyldBondToken on Sepolia and a
        // TokenFactory on a production L2. The deployer owns it only transiently; {_handOverToTimelock}
        // moves ownership to the timelock inside this same broadcast.
        bytes memory factoryInit =
            abi.encodePacked(type(TokenFactory).creationCode, abi.encode(bondImpl, sanctionsOracle, c.deployer));
        factory = new TokenFactory{salt: DeployGuards.vacantSalt("DeployDevNet:TokenFactory", factoryInit)}(
            bondImpl, sanctionsOracle, c.deployer
        );
        console.log("FACTORY_ADDRESS=%s", address(factory));
    }

    /// @dev 4-8. Role grants and the AP whitelist.
    function _wireIssuanceManager(Config memory c) internal {
        // WHITELIST_ADMIN_ROLE goes to its dedicated address, and transiently to the
        // deployer — addToWhitelist below is gated on that role, not on DEFAULT_ADMIN,
        // so without this the production path would revert here. The transient copy is
        // dropped again in {_handOverToTimelock}.
        issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), c.whitelistAdmin);
        if (c.whitelistAdmin != c.deployer) {
            issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), c.deployer);
        }

        // The factory needs REGISTRAR_ROLE so deployToken can register tokens.
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));

        issuanceMgr.addToWhitelist(c.subscriber);

        // Anvil account[1] — its private key is printed in the Anvil banner. It exists so
        // the redemption e2e test has an investor/beneficiary. Whitelisting a publicly
        // known key as an AP on a production chain would let anyone receive minted bond
        // tokens, so it is dev-only. In prod all investors are whitelisted during KYC.
        if (DeployGuards.isDevChain()) {
            issuanceMgr.addToWhitelist(DeployGuards.ANVIL_ACCOUNT_1);
        }
    }

    /// @dev 9-10. Hand DEFAULT_ADMIN to the timelock and start the factory hand-off.
    function _handOverToTimelock(Config memory c) internal {
        // Drop the deployer's transient whitelist-admin grant before it loses the ability
        // to change roles at all (after the DEFAULT_ADMIN revoke, recovery would need a
        // full timelock proposal).
        if (c.whitelistAdmin != c.deployer) {
            issuanceMgr.revokeRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), c.deployer);
        }

        bytes32 adminRole = issuanceMgr.DEFAULT_ADMIN_ROLE();
        issuanceMgr.grantRole(adminRole, address(timelock));
        issuanceMgr.revokeRole(adminRole, c.deployer);

        // Transfer factory ownership to the timelock BEFORE deploying tokens.
        // TokenFactory._wireRoles() assigns DEFAULT_ADMIN_ROLE on each token to
        // factory.owner() at call time, so ownership must already be the timelock.
        factory.transferOwnership(address(timelock));

        // The accept can only be executed in this run when the delay is zero AND the
        // deployer is itself the timelock proposer (i.e. the dev fallback). Otherwise the
        // governance multisig completes it in Phase 2.
        if (c.delay == 0 && timelock.hasRole(DeployGuards.PROPOSER_ROLE, c.deployer)) {
            bytes memory acceptData = abi.encodeCall(factory.acceptOwnership, ());
            timelock.schedule(address(factory), 0, acceptData, bytes32(0), bytes32("accept"), 0);
            timelock.execute(address(factory), 0, acceptData, bytes32(0), bytes32("accept"));
            factoryOwnershipAccepted = true;
            console.log("Factory ownership accepted by timelock (delay=0, dev chain).");
        }
    }

    // ── In-band post-deploy assertions ────────────────────────────────────────

    /// @dev Runs inside the broadcast. Asserts the FINAL role topology rather than the
    ///      individual grants, so that a wiring change that happens to leave the deployer
    ///      privileged can never ship silently again.
    function _assertFinalTopology(Config memory c) internal view {
        // 1. Governance sits at the timelock and the deployer is out.
        DeployGuards.assertRoleHandover(
            address(issuanceMgr),
            issuanceMgr.DEFAULT_ADMIN_ROLE(),
            address(timelock),
            c.deployer,
            "IssuanceManager DEFAULT_ADMIN_ROLE"
        );

        // 2. The timelock is a real gate: >= 48h and the deployer proposes nothing.
        DeployGuards.assertTimelockSane(payable(address(timelock)), c.deployer);

        // 3. The deployer holds NO operational role on the IssuanceManager either.
        _assertDeployerHoldsNothing(c.deployer);

        // 4. Factory ownership. Two-step: either fully accepted, or the timelock is the
        //    pending owner and Phase 2 completes it. In neither case may it stay put.
        if (factoryOwnershipAccepted) {
            require(factory.owner() == address(timelock), "DeployDevNet: factory owner is not the timelock");
            require(factory.pendingOwner() == address(0), "DeployDevNet: factory still has a pending owner");
        } else {
            require(
                factory.pendingOwner() == address(timelock),
                "DeployDevNet: factory pendingOwner is not the timelock"
            );
        }

        // 5. The compliance oracle must be a real contract on production — never a mock,
        //    never an EOA, never an empty address that silently screens nothing.
        DeployGuards.requireProdContract(sanctionsOracle, "sanctions oracle");
        DeployGuards.requireProdNotMock(sanctionsOracle, type(MockSanctionsList).runtimeCode, "sanctions oracle");
        require(factory.sanctionsList() == sanctionsOracle, "DeployDevNet: factory sanctions oracle mismatch");

        // 6. The publicly-known Anvil key is not an AP on a production chain.
        if (!DeployGuards.isDevChain()) {
            require(
                !issuanceMgr.whitelisted(DeployGuards.ANVIL_ACCOUNT_1),
                "DeployDevNet: Anvil account[1] must not be whitelisted on a production chain"
            );
        }
    }

    /// @dev Extracted so {_assertFinalTopology} keeps a shallow stack.
    function _assertDeployerHoldsNothing(address deployer) internal view {
        IssuanceManager im = issuanceMgr;
        // Unconditional: DEFAULT_ADMIN is always handed to the timelock, and REGISTRAR
        // belongs to the factory on every chain.
        require(!im.hasRole(im.DEFAULT_ADMIN_ROLE(), deployer), "DeployDevNet: deployer kept DEFAULT_ADMIN_ROLE");
        require(!im.hasRole(im.REGISTRAR_ROLE(), deployer), "DeployDevNet: deployer kept REGISTRAR_ROLE");

        // The remaining operational roles legitimately fall back to the deployer on a dev
        // chain (that is the whole point of the zero-config Anvil flow); on production
        // they each have a dedicated holder, so the deployer must end up with nothing.
        if (!DeployGuards.isDevChain()) {
            require(!im.hasRole(im.WHITELIST_ADMIN_ROLE(), deployer), "DeployDevNet: deployer kept WHITELIST_ADMIN_ROLE");
            require(!im.hasRole(im.SUBSCRIBER_ROLE(), deployer), "DeployDevNet: deployer kept SUBSCRIBER_ROLE");
            require(!im.hasRole(im.REDEEMER_ROLE(), deployer), "DeployDevNet: deployer kept REDEEMER_ROLE");
        }
    }

    // ── Bond tokens (dev chains only — needs the accepted factory ownership) ──

    /// @dev Deploy the three dev bond tokens via the timelock and log their addresses.
    ///      factory.owner() must already be the timelock before calling this.
    ///      Return values from deployToken are unavailable through timelock.execute, so
    ///      we predict each token address with predictTokenAddress and read navFeed/forwarder
    ///      from factory mappings after the execute call.
    function _deployBondTokens(
        TokenFactory factory_,
        address operator,
        address issuanceMgr_,
        address navFeedOwner
    ) internal {
        TimelockController tl = TimelockController(payable(factory_.owner()));

        // CAT — Caterpillar Inc 3.7% 2028 (ISIN US14913UBF62, CUSIP 14913UBF6, matures 2028-09-06)
        {
            address cat = factory_.predictTokenAddress("Caterpillar Inc 3.7% 2028", "14913UBF6", "US14913UBF62", 1_788_739_200);
            bytes memory data = abi.encodeCall(
                factory_.deployToken,
                ("Caterpillar Inc 3.7% 2028", "14913UBF6", "US14913UBF62",
                 1_788_739_200, operator, issuanceMgr_, navFeedOwner)
            );
            tl.schedule(address(factory_), 0, data, bytes32(0), bytes32("deploy_cat"), 0);
            tl.execute(address(factory_), 0, data, bytes32(0), bytes32("deploy_cat"));
            bondTokens.push(cat);
            console.log("TOKEN_CAT=%s", cat);
            console.log("NAVFEED_CAT=%s", factory_.navFeedOf(cat));
            console.log("FORWARDER_CAT=%s  (give this to Morpho/Aave)", factory_.forwarderOf(cat));
        }

        // C — Citigroup Inc 3.887% 2028 (ISIN US172967LD16, CUSIP 172967LD1, matures 2028-01-10)
        {
            address c = factory_.predictTokenAddress("Citigroup Inc 3.887% 2028", "172967LD1", "US172967LD16", 1_767_052_800);
            bytes memory data = abi.encodeCall(
                factory_.deployToken,
                ("Citigroup Inc 3.887% 2028", "172967LD1", "US172967LD16",
                 1_767_052_800, operator, issuanceMgr_, navFeedOwner)
            );
            tl.schedule(address(factory_), 0, data, bytes32(0), bytes32("deploy_c"), 0);
            tl.execute(address(factory_), 0, data, bytes32(0), bytes32("deploy_c"));
            bondTokens.push(c);
            console.log("TOKEN_C=%s", c);
            console.log("NAVFEED_C=%s", factory_.navFeedOf(c));
            console.log("FORWARDER_C=%s  (give this to Morpho/Aave)", factory_.forwarderOf(c));
        }

        // KO — Coca-Cola Co 2.25% 2032 (ISIN US191216DP29, CUSIP 191216DP2, matures 2032-09-01)
        {
            address ko = factory_.predictTokenAddress("Coca-Cola Co 2.25% 2032", "191216DP2", "US191216DP29", 1_975_017_600);
            bytes memory data = abi.encodeCall(
                factory_.deployToken,
                ("Coca-Cola Co 2.25% 2032", "191216DP2", "US191216DP29",
                 1_975_017_600, operator, issuanceMgr_, navFeedOwner)
            );
            tl.schedule(address(factory_), 0, data, bytes32(0), bytes32("deploy_ko"), 0);
            tl.execute(address(factory_), 0, data, bytes32(0), bytes32("deploy_ko"));
            bondTokens.push(ko);
            console.log("TOKEN_KO=%s", ko);
            console.log("NAVFEED_KO=%s", factory_.navFeedOf(ko));
            console.log("FORWARDER_KO=%s  (give this to Morpho/Aave)", factory_.forwarderOf(ko));
        }
    }

    // ── Logging ───────────────────────────────────────────────────────────────

    function _logSummary(Config memory c) internal view {
        console.log("");
        if (factoryOwnershipAccepted) {
            console.log("=== Deployment complete ===");
        } else {
            console.log("=== Phase 1 deployment complete ===");
        }
        console.log("Chain ID:              %d", block.chainid);
        console.log("Deployer:              %s", c.deployer);
        console.log("Timelock:              %s  (delay: %d s)", address(timelock), c.delay);
        console.log("Factory:               %s", address(factory));
        console.log("IssuanceManager:       %s", address(issuanceMgr));
        console.log("SanctionsList:         %s", sanctionsOracle);
        console.log("");
        console.log("=== Role assignments ===");
        console.log("GOVERNANCE_MULTISIG:   %s  (timelock proposer)", c.governanceMultisig);
        console.log("TIMELOCK:              %s  (IssuanceManager DEFAULT_ADMIN)", address(timelock));
        console.log("OPS_MULTISIG:          %s  (token PAUSER)", c.opsMultisig);
        console.log("SUBSCRIBER_ADDRESS:    %s  (IssuanceManager SUBSCRIBER_ROLE)", c.subscriber);
        console.log("REDEEMER_ADDRESS:      %s  (IssuanceManager REDEEMER_ROLE)", c.redeemer);
        console.log("WHITELIST_ADMIN:       %s  (IssuanceManager WHITELIST_ADMIN_ROLE)", c.whitelistAdmin);
        console.log("NAV_FEED_OWNER:        %s  (KaleidoscopeNAVFeed owner)", c.navFeedOwner);
        console.log("");

        if (!factoryOwnershipAccepted) {
            console.log("=== Phase 2 required (timelock delay has not elapsed) ===");
            console.log("  Step 1: Governance multisig schedules factory.acceptOwnership() via timelock");
            console.log("          target = %s (factory)", address(factory));
            console.log("          data   = factory.acceptOwnership() (0x79ba5097)");
            console.log("          delay  >= %d seconds", c.delay);
            console.log("  Step 2: Wait %d seconds, then execute acceptOwnership", c.delay);
            console.log("  Step 3: Deploy bond tokens via deployToken calls through the timelock");
            console.log("          (factory.owner() is then the timelock, so DEFAULT_ADMIN on each");
            console.log("           token is the timelock - not the deployer EOA)");
            console.log("");
        }

        console.log("Next: set these env vars:");
        console.log("  EVM_FACTORY_ADDRESS=%s", address(factory));
        console.log("  EVM_ISSUANCE_MANAGER=%s", address(issuanceMgr));
        console.log("  TIMELOCK_ADDRESS=%s", address(timelock));
        console.log("  CHAINALYSIS_SANCTIONS_CONTRACT=%s", sanctionsOracle);
    }
}
