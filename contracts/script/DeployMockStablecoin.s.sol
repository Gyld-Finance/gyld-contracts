// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {GyldTestUSD} from "../test/GyldTestUSD.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

/// @title DeployMockStablecoin
/// @notice Dev-only: deploys a {GyldTestUSD} ("Gyld Test USD" / gUSD) as the cash leg
///         of a public-testnet stack — primarily BSC testnet (97), whose stablecoins are
///         18dp (GLD-713). Pass the printed address as `USDC_ADDRESS` to
///         DeployAtomicSettlement. Runbook: docs/deploy/bsc-testnet.md.
///
/// Gated on the same dev ALLOWLIST as every other script ({DeployGuards.requireProdSafe}:
/// Anvil 31337 / Sepolia 11155111 / BSC testnet 97). Any other chain — BSC mainnet (56)
/// included — fails closed before any gas is spent. A minter-gated test stablecoin has
/// no business on a production chain, where the cash leg must be the real token.
///
/// ── Environment variables (all optional) ──────────────────────────────────────
///   MOCK_STABLE_DECIMALS     Token decimals. Default 18. Must be 6 or 18 — the only
///                            values GyldAtomicSwap.initialize accepts for its cash token.
///   MOCK_STABLE_MINT_TO      Recipient of the initial supply. Default: the broadcaster.
///   MOCK_STABLE_MINT_AMOUNT  Initial supply in WHOLE tokens (scaled by decimals).
///                            Default 1,000,000. 0 skips the initial mint.
///
/// The broadcaster becomes the token's permanent `minter`; top up later with
///   cast send $USDC_ADDRESS "mint(address,uint256)" <to> <raw_amount> --private-key $PRIVKEY
///
/// ── Usage ─────────────────────────────────────────────────────────────────────
///   forge script contracts/script/DeployMockStablecoin.s.sol \
///     --rpc-url $RPC --broadcast --private-key $PRIVKEY
///
/// ── Output ────────────────────────────────────────────────────────────────────
///   USDC_ADDRESS=<gUSD>   (the swap's cash-token env var keeps its historical name)
contract DeployMockStablecoin is Script {
    /// Bounds mirrored from GyldAtomicSwap.initialize's cash-decimals probe (GLD-713).

    /// Output — public so tests and follow-up scripts can read it.
    GyldTestUSD public stable;

    function run() external {
        // Guard BEFORE the broadcast: a dry run names the problem instead of the
        // transaction reverting mid-flight.
        DeployGuards.requireProdSafe("deploying the Gyld Test USD (gUSD) mock stablecoin");

        uint256 decimals_ = _envOrUint("MOCK_STABLE_DECIMALS", 18);
        require(
            decimals_ == 6 || decimals_ == 18,
            string.concat("DeployMockStablecoin: MOCK_STABLE_DECIMALS=", vm.toString(decimals_), " is not 6 or 18")
        );
        address deployer = DeployGuards.broadcaster();
        address mintTo = _envOrAddress("MOCK_STABLE_MINT_TO", deployer);
        uint256 wholeTokens = _envOrUint("MOCK_STABLE_MINT_AMOUNT", 1_000_000);

        vm.startBroadcast();
        stable = new GyldTestUSD(uint8(decimals_), deployer);
        if (wholeTokens > 0) {
            stable.mint(mintTo, wholeTokens * 10 ** decimals_);
        }
        vm.stopBroadcast();

        console.log("GyldTestUSD (gUSD): %s  decimals=%d  minter=%s", address(stable), decimals_, deployer);
        console.log("USDC_ADDRESS=%s", address(stable));
    }

    /// @dev `try` rather than `vm.envOr` so an EMPTY value (how tests unset a var) also
    ///      falls back to the default — same idiom as DeployAtomicSettlement.
    function _envOrUint(string memory key, uint256 fallback_) internal view returns (uint256) {
        try vm.envUint(key) returns (uint256 val) {
            return val;
        } catch {
            return fallback_;
        }
    }

    function _envOrAddress(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address val) {
            return val;
        } catch {
            return fallback_;
        }
    }
}
