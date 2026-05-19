// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DeployBaseTest - BASE MAINNET TEST DEPLOYMENT                          ║
// ║                                                                          ║
// ║  Purpose: deploy one dummy bond token on Base mainnet so we can create  ║
// ║  a Morpho Blue market and get a shareable app.morpho.org link.          ║
// ║                                                                          ║
// ║  Sanctions: uses the REAL Chainalysis oracle on Base mainnet.           ║
// ║  No MockSanctionsList. All transfers are screened against OFAC/SDN.     ║
// ║                                                                          ║
// ║  ⚠  THIS RUNS ON BASE MAINNET. REAL ETH IS SPENT FOR GAS.              ║
// ║  ⚠  TOKEN METADATA IS INTENTIONALLY FAKE / DUMMY.                      ║
// ║  ⚠  DO NOT USE REAL CUSIP / ISIN.                                       ║
// ╚══════════════════════════════════════════════════════════════════════════╝
//
// What this deploys:
//   TimelockController    - delay=0 for test; production must use 48h+
//   IssuanceManager       - mint / redeem
//   TokenFactory          - points at real Chainalysis oracle (no mock)
//   "Test Bond Alpha" / TBA bond token
//     KaleidoscopeNAVFeed    - NAV price source (owner = deployer wallet)
//     NAVFeedForwarder       - Morpho reads this address permanently
//
// Usage:
//   1. Fill .env: BASE_RPC, PRIVKEY, BASESCAN_API_KEY
//   2. Dry-run first (no --broadcast):
//        forge script contracts/script/DeployBaseTest.s.sol \
//          --rpc-url $BASE_RPC --private-key $PRIVKEY
//   3. If output looks correct, broadcast:
//        forge script contracts/script/DeployBaseTest.s.sol \
//          --rpc-url $BASE_RPC --broadcast \
//          --verify --etherscan-api-key $BASESCAN_API_KEY \
//          --private-key $PRIVKEY
//   4. Save all printed BASE_* addresses into .env
//   5. Next: push a NAV price, then run DeployBaseMorphoOracle.s.sol

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";

contract DeployBaseTest is Script {

    // ── Chainalysis sanctions oracle on Base mainnet ───────────────────────
    // Official address confirmed at https://go.chainalysis.com/chainalysis-oracle-docs.html
    // Different from Ethereum mainnet (0x40C5...) -- Base has its own deployment.
    // Deployed 2024-03-29 by 0xDF900dC8991474ab9d69f2c3b9c900c055fb36cd.
    address constant CHAINALYSIS_BASE = 0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B;

    // ── Dummy token metadata ──────────────────────────────────────────────
    // All values are intentionally fake. No real ISIN or bond name.
    string  constant TOKEN_NAME     = "Test Bond Alpha";
    string  constant TOKEN_SYMBOL   = "TBA";
    string  constant TOKEN_ISIN     = "US000000TBA0"; // fake
    uint256 constant TOKEN_MATURITY = 1_893_456_000;  // 2030-01-01 UTC

    function run() external {
        // ── Safety guards ─────────────────────────────────────────────────
        require(block.chainid != 1,    "DeployBaseTest: do not run on Ethereum mainnet");
        require(block.chainid == 8453, "DeployBaseTest: Base mainnet only (chainId 8453)");

        // Verify Chainalysis oracle is live and callable before spending gas
        // on the full deployment. Fails immediately if the oracle is not responsive.
        (bool ok, bytes memory ret) = CHAINALYSIS_BASE.staticcall(
            abi.encodeWithSignature("isSanctioned(address)", address(0))
        );
        require(ok && ret.length == 32, "DeployBaseTest: Chainalysis oracle not callable");

        address deployer = msg.sender;

        console.log("=== DeployBaseTest - Base Mainnet ===");
        console.log("Chain ID:         %d", block.chainid);
        console.log("Deployer:         %s", deployer);
        console.log("Sanctions oracle: %s (Chainalysis - real)", CHAINALYSIS_BASE);
        console.log("Token:            %s / %s (dummy metadata)", TOKEN_NAME, TOKEN_SYMBOL);
        console.log("");

        vm.startBroadcast();

        // 1. TimelockController (delay=0 for test).
        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = address(0); // anyone can execute after delay
        TimelockController timelock = new TimelockController(
            0,          // delay = 0 - TEST ONLY, production must use 172800+
            proposers,
            executors,
            address(0)
        );
        console.log("BASE_TIMELOCK=%s", address(timelock));

        // 2. IssuanceManager - deployer holds all roles for test convenience.
        IssuanceManager issuanceMgr = IssuanceManager(address(new ERC1967Proxy(
            address(new IssuanceManager()),
            abi.encodeCall(IssuanceManager.initialize, (deployer, deployer, deployer))
        )));
        issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), deployer);
        console.log("BASE_ISSUANCE_MANAGER=%s", address(issuanceMgr));

        // 3. TokenFactory - points at real Chainalysis oracle (no mock).
        //    sanctionsList is immutable in the factory so all tokens it deploys
        //    will use the real Chainalysis oracle from birth.
        TokenFactory factory = new TokenFactory(
            address(new GyldBondToken()),
            CHAINALYSIS_BASE
        );
        console.log("BASE_FACTORY=%s", address(factory));

        // 4. Wire IssuanceManager: factory can register tokens, deployer can mint.
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));
        issuanceMgr.addToWhitelist(deployer);

        // 5. Hand factory ownership to timelock so _wireRoles() assigns
        //    DEFAULT_ADMIN on the token to the timelock (not the deployer EOA).
        //    delay=0 means schedule+execute is instant.
        factory.transferOwnership(address(timelock));
        {
            bytes memory acceptData = abi.encodeCall(factory.acceptOwnership, ());
            timelock.schedule(address(factory), 0, acceptData, bytes32(0), bytes32("accept"), 0);
            timelock.execute(address(factory), 0, acceptData, bytes32(0), bytes32("accept"));
        }
        require(factory.owner() == address(timelock), "factory owner must be timelock");

        // 6. Predict token address before deploying (CREATE2 - deterministic).
        address tokenTBA = factory.predictTokenAddress(
            TOKEN_NAME, TOKEN_SYMBOL, TOKEN_ISIN, TOKEN_MATURITY
        );

        // 7. Deploy dummy bond token through timelock (delay=0 - instant).
        {
            bytes memory deployData = abi.encodeCall(
                factory.deployToken,
                (
                    TOKEN_NAME,
                    TOKEN_SYMBOL,
                    TOKEN_ISIN,
                    TOKEN_MATURITY,
                    deployer,             // operator - PAUSER_ROLE
                    address(issuanceMgr),
                    deployer              // navFeedOwner - deployer pushes NAV prices
                )
            );
            timelock.schedule(address(factory), 0, deployData, bytes32(0), bytes32("deploy_tba"), 0);
            timelock.execute(address(factory), 0, deployData, bytes32(0), bytes32("deploy_tba"));
        }

        address navFeedTBA   = factory.navFeedOf(tokenTBA);
        address forwarderTBA = factory.forwarderOf(tokenTBA);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment complete ===");
        console.log("BASE_TOKEN_TBA=%s", tokenTBA);
        console.log("BASE_NAVFEED_TBA=%s", navFeedTBA);
        console.log("BASE_FORWARDER_TBA=%s", forwarderTBA);
        console.log("  ^ permanent oracle address - Morpho will point here");
        console.log("");
        console.log("=== Next steps ===");
        console.log("Step 2a - push initial NAV price ($100.00):");
        console.log("  cast send $BASE_NAVFEED_TBA \\");
        console.log("    'updateAnswer(int256)' 10000000000 \\");
        console.log("    --rpc-url $BASE_RPC --private-key $PRIVKEY");
        console.log("  (10000000000 = $100.00 in 8-decimal Chainlink format)");
        console.log("");
        console.log("Step 2b - verify price flows through forwarder:");
        console.log("  cast call $BASE_FORWARDER_TBA \\");
        console.log("    'latestRoundData()(uint80,int256,uint256,uint256,uint80)' \\");
        console.log("    --rpc-url $BASE_RPC");
        console.log("  (second return value should be 10000000000)");
        console.log("");
        console.log("Then run DeployBaseMorphoOracle.s.sol");
    }
}
