// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {NAVFeedForwarder} from "../NAVFeedForwarder.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title DeployNAVFeed
/// @notice Deploys KaleidoscopeNAVFeed + NAVFeedForwarder for one instrument.
///
///         The forwarder is the stable address that DeFi protocols (Morpho,
///         Aave) should integrate. When we upgrade the oracle provider (e.g.
///         self → RedStone → Chainlink NAVLink), we call
///         forwarder.setUpstreamOracle(newFeed) once — all integrations update
///         instantly with no market redeployment.
///
/// ── Environment variables ──────────────────────────────────────────────────
///   OPERATOR_ADDRESS     Address that can call NAVFeed.updateAnswer()
///                        (your backend EOA or Gnosis Safe)
///   FEED_DESCRIPTION     Human-readable label, e.g. "TLT / USD NAV"
///
/// Required on PRODUCTION chains (optional on Anvil 31337 / Sepolia 11155111, where it
/// falls back to OPERATOR_ADDRESS):
///   FORWARDER_OWNER      Address that owns the forwarder and can call
///                        setUpstreamOracle(). On production this MUST be a contract —
///                        a TimelockController — so that repointing the oracle every DeFi
///                        market reads from carries a mandatory delay. An EOA here means
///                        one key can silently swap the price source under Morpho/Aave.
///
/// ── Usage — Anvil (local) ──────────────────────────────────────────────────
///   anvil &
///   OPERATOR_ADDRESS=<address> \
///   FEED_DESCRIPTION="TLT / USD NAV" \
///   forge script contracts/script/DeployNAVFeed.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key ANVIL_TEST_KEY_REDACTED
///
/// ── Usage — Hoodi testnet ─────────────────────────────────────────────────
///   export OPERATOR_ADDRESS=<address>
///   export FEED_DESCRIPTION="TLT / USD NAV"
///   forge script contracts/script/DeployNAVFeed.s.sol \
///     --rpc-url https://rpc.hoodi.ethpandaops.io \
///     --broadcast \
///     --private-key $PRIVKEY_SIGNING_KEY \
///     --verify
///
/// ── Outputs ───────────────────────────────────────────────────────────────
///   NAV_FEED_ADDRESS      — KaleidoscopeNAVFeed (updater writes here)
///   FORWARDER_ADDRESS     — NAVFeedForwarder    (DeFi protocols point here)
///
/// ── Morpho integration (after deploy) ────────────────────────────────────
///   Pass FORWARDER_ADDRESS as baseFeed1 to MorphoChainlinkOracleV2Factory.
///   Set quoteFeed1 to the USDC/USD Chainlink feed or address(0) for 1:1.
///
/// ── Oracle upgrade (Phase 2 / 3) ─────────────────────────────────────────
///   Deploy new oracle (e.g. RedStone feed address).
///   Call: forwarder.setUpstreamOracle(newOracleAddress)
///   All DeFi markets instantly read from the new oracle. No redeployment.

contract DeployNAVFeed is Script {
    // ── Outputs — public storage so tests and follow-up scripts can read them ──
    KaleidoscopeNAVFeed public feed;
    NAVFeedForwarder public forwarder;

    function run() external {
        address operator = DeployGuards.envAddressRequired("OPERATOR_ADDRESS");
        string memory feedDescription = vm.envString("FEED_DESCRIPTION");

        // Falls back to the operator on a dev chain only; required on production.
        address forwarderOwner = DeployGuards.envAddressProdRequired("FORWARDER_OWNER", operator);
        // On production the forwarder owner must be a contract (a TimelockController),
        // never an EOA: setUpstreamOracle repoints the price feed that every integrated
        // lending market reads, and that must not be one hot key away.
        DeployGuards.requireProdContract(forwarderOwner, "FORWARDER_OWNER");

        vm.startBroadcast();

        // 1. Deploy the NAV feed (operator pushes prices here). The salt carries the feed
        //    description so two instruments on the same chain never collide.
        feed = new KaleidoscopeNAVFeed{
            salt: DeployGuards.vacantSalt(
                string.concat("DeployNAVFeed:KaleidoscopeNAVFeed:", feedDescription),
                abi.encodePacked(type(KaleidoscopeNAVFeed).creationCode, abi.encode(operator, feedDescription))
            )
        }(operator, feedDescription);

        // 2. Deploy the forwarder pointing at the NAV feed
        //    DeFi protocols always integrate this address — never the feed directly
        forwarder = new NAVFeedForwarder{
            salt: DeployGuards.vacantSalt(
                string.concat("DeployNAVFeed:NAVFeedForwarder:", feedDescription),
                abi.encodePacked(type(NAVFeedForwarder).creationCode, abi.encode(address(feed), forwarderOwner))
            )
        }(address(feed), forwarderOwner);

        require(forwarder.owner() == forwarderOwner, "DeployNAVFeed: forwarder owner mismatch");
        require(feed.owner() == operator, "DeployNAVFeed: feed owner mismatch");

        vm.stopBroadcast();

        console.log("");
        console.log("=== NAVFeed + Forwarder deployment complete ===");
        console.log("Chain ID:         %d", block.chainid);
        console.log("");
        console.log("NAV_FEED_ADDRESS=%s",  address(feed));
        console.log("  Owner:           %s", feed.owner());
        console.log("  Description:     %s", feed.description());
        console.log("  Role:            updater writes prices here");
        console.log("");
        console.log("FORWARDER_ADDRESS=%s", address(forwarder));
        console.log("  Owner:           %s", forwarder.owner());
        console.log("  Upstream:        %s", forwarder.upstreamOracle());
        console.log("  Role:            DeFi protocols integrate THIS address");
        console.log("");
        console.log("=== Env vars for gateway ===");
        console.log("EVM_NAV_FEED_ADDRESS=%s",  address(feed));
        console.log("EVM_NAV_FORWARDER_ADDRESS=%s", address(forwarder));
        console.log("");
        console.log("=== Next: Morpho Oracle ===");
        console.log("Deploy MorphoChainlinkOracleV2 via factory:");
        console.log("  baseFeed1  = %s  (forwarder)", address(forwarder));
        console.log("  quoteFeed1 = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6 (USDC/USD)");
        console.log("  baseTokenDecimals  = 18");
        console.log("  quoteTokenDecimals = 6");
    }
}
