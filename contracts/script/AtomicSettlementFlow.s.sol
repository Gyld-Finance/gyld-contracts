// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {MockSanctionsList} from "../test/MockSanctionsList.sol";
import {MockUSDC} from "../test/MockUSDC.sol";

/// @title AtomicSettlementFlow
/// @notice LOCAL / DEV DEMO — drives the COMPLETE self-custodial atomic-settlement flow
///         against a live Anvil node in a single `forge script` run. This is the
///         committed, repeatable replacement for the throwaway scratch script used
///         during bring-up: a fresh deploy + BUY + REDEEM round trip + a treasurer
///         withdraw, with require() asserts at every step so the run FAILS LOUD the
///         moment anything drifts.
///
///         It is NOT a deployment recipe (use DeployDevNet + DeployAtomicSettlement
///         for that). It deploys its own self-contained, minimal stack so it can be
///         run end-to-end with zero prior on-chain state.
///
/// ── Run command (start anvil first) ─────────────────────────────────────────
///   anvil &
///   forge script contracts/script/AtomicSettlementFlow.s.sol \
///     --rpc-url http://127.0.0.1:8545 \
///     --broadcast \
///     --private-key $ANVIL_ACCT0_KEY
///   # Anvil prints its deterministic keys in the startup banner. This script is
///   # hard-guarded to chainId 31337, so those keys can never reach a real chain —
///   # but do not paste a key literal on a command line as a habit.
///
/// ── The NAV-FIRST gotcha (documented, enforced below) ───────────────────────
///   A NAV price MUST be pushed to the feed BEFORE the first executeSwap. The swap
///   enforces a NAV band on every quote; with no price set (or a non-positive answer),
///   executeSwap fails closed (InvalidNav). Step 2 below pushes the price first.
///
/// ── What it proves ──────────────────────────────────────────────────────────
///   1. Minimal base wired: IssuanceManager + TokenFactory + a real CAT-style
///      GyldBondToken/NAVFeed/forwarder + MockSanctionsList + MockUSDC.
///   2. NAV pushed first ($100, 8dp).
///   3. Self-custodial swap deployed, whitelisted as AP, series registered,
///      withdrawal wallet set, taker allowlisted.
///   4. Inventory seeded DIRECTLY into the swap via IssuanceManager.subscribe(token,
///      swap, n); USDC funded directly to the swap for the redeem leg.
///   5. BUY: the QUOTE_SIGNER signs an EIP-712 BUY quote, the taker executes it.
///      Asserts: taker tokens up, swap USDC up, supply unchanged.
///   6. REDEEM: QUOTE_SIGNER signs a REDEEM quote, taker executes it. Asserts: USDC
///      back to taker, tokens back to the swap.
///   7. WITHDRAW: treasurer withdraws USDC out to the fixed withdrawalWallet.
contract AtomicSettlementFlow is Script {
    // Anvil's deterministic accounts, DERIVED rather than pasted. Same addresses as
    // the raw literals this replaced, but no private-key constant appears in the repo:
    // a key literal in source trains people to paste keys, and a reader cannot tell a
    // throwaway from a real one at a glance. Guarded to chainId 31337 regardless.
    string constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";
    uint256 immutable DEPLOYER_PK = vm.deriveKey(ANVIL_MNEMONIC, 0); // acct[0]
    uint256 immutable TAKER_PK    = vm.deriveKey(ANVIL_MNEMONIC, 1); // acct[1]
    uint256 immutable SIGNER_PK   = vm.deriveKey(ANVIL_MNEMONIC, 2); // acct[2]

    // NAV $100.00 per token (8dp): 1e18 token <-> 100e6 USDC. 8 decimals.
    int256 constant NAV = 100e8; // 10000000000
    uint16 constant MAX_BPS = 200; // 2% NAV band
    uint32 constant MAX_NAV_AGE = 86400; // 1 day

    function run() external {
        require(block.chainid == 31337, "AtomicSettlementFlow: Anvil (chainId 31337) only");

        address taker = vm.addr(TAKER_PK);
        address signer = vm.addr(SIGNER_PK);
        address deployer = msg.sender; // broadcaster = deployer = every admin/ops role (dev)

        console2.log("=== AtomicSettlementFlow (LOCAL DEV, self-custodial) ===");
        console2.log("deployer/broadcaster: %s", deployer);
        console2.log("taker (acct[1]):      %s", taker);
        console2.log("quote signer (acct[2]): %s", signer);

        vm.startBroadcast();

        // ── Step 1: minimal base stack ───────────────────────────────────────
        MockSanctionsList sanctions = new MockSanctionsList(deployer);
        MockUSDC usdc = new MockUSDC();

        IssuanceManager issuanceMgr = IssuanceManager(
            address(
                new ERC1967Proxy(
                    address(new IssuanceManager()),
                    abi.encodeCall(IssuanceManager.initialize, (deployer, deployer, deployer))
                )
            )
        );
        issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), deployer);

        TokenFactory factory = new TokenFactory(address(new GyldBondToken()), address(sanctions), deployer);
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));

        // CAT-style series — deployer is factory owner so deployToken is called directly
        // (DEFAULT_ADMIN on the token is the deployer; fine for a dev demo).
        (address token_, address navFeed_, address forwarder_) = factory.deployToken(
            "Caterpillar Inc 3.7% 2028",
            "14913UBF6",
            "US14913UBF62",
            1_788_739_200,
            deployer, // token operator / pauser
            address(issuanceMgr),
            deployer // NAV feed owner
        );
        GyldBondToken token = GyldBondToken(token_);
        KaleidoscopeNAVFeed navFeed = KaleidoscopeNAVFeed(navFeed_);
        console2.log("[1] base wired");
        console2.log("    IssuanceManager: %s", address(issuanceMgr));
        console2.log("    TokenFactory:    %s", address(factory));
        console2.log("    Token (CAT):     %s", token_);
        console2.log("    NAVFeed:         %s", navFeed_);
        console2.log("    Forwarder:       %s", forwarder_);
        console2.log("    Sanctions:       %s", address(sanctions));
        console2.log("    MockUSDC:        %s", address(usdc));

        // ── Step 2: NAV FIRST (the gotcha) ───────────────────────────────────
        navFeed.updateAnswer(NAV);
        console2.log("[2] NAV pushed FIRST: %d (8dp = $100.00)", uint256(NAV));

        // ── Step 3: self-custodial swap + wiring ─────────────────────────────
        GyldAtomicSwap swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(new GyldAtomicSwap()),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (deployer, deployer, signer, deployer, address(usdc), MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );
        // The swap holds inventory, so it MUST be a whitelisted AP (subscribe recipient).
        issuanceMgr.addToWhitelist(address(swap));
        swap.registerSeries(address(token), factory.forwarderOf(address(token)));
        swap.setWithdrawalWallet(deployer); // fixed treasury destination (deployer in dev)
        // setAllowed is gated on ALLOWLIST_ADMIN_ROLE, not DEFAULT_ADMIN_ROLE (GYL-1050).
        swap.grantRole(swap.ALLOWLIST_ADMIN_ROLE(), deployer);
        swap.setAllowed(taker, true); // taker must be allowlisted to execute swaps

        require(swap.registeredSeries(address(token)), "series not registered");
        require(swap.navForwarderOf(address(token)) == factory.forwarderOf(address(token)), "forwarder mismatch");
        require(swap.withdrawalWallet() == deployer, "withdrawalWallet mismatch");
        require(swap.isAllowed(taker), "taker not allowlisted");
        require(issuanceMgr.whitelisted(address(swap)), "swap not whitelisted AP");
        console2.log("[3] self-custodial swap wired");
        console2.log("    Swap:  %s", address(swap));

        // ── Step 4: seed the swap's OWN inventory + USDC liquidity ───────────
        issuanceMgr.subscribe(address(token), address(swap), 100e18); // 100 tokens @ $100 minted to the swap
        require(token.balanceOf(address(swap)) == 100e18, "subscribe mint did not land in swap");
        require(token.totalSupply() == 100e18, "unexpected supply after subscribe");

        // USDC for the redeem leg goes directly to the swap; fund the taker for buying.
        usdc.mint(address(swap), 10_000e6);
        usdc.mint(taker, 100_000e6);
        console2.log("[4] inventory seeded: 100 tokens minted to swap; supply=%d", token.totalSupply());
        console2.log("    swap USDC liquidity=%d; taker funded with 100000 USDC", usdc.balanceOf(address(swap)));

        vm.stopBroadcast();

        // ── Step 5: BUY leg ──────────────────────────────────────────────────
        uint256 supplyBeforeBuy = token.totalSupply();
        uint256 swapUsdcBeforeBuy = usdc.balanceOf(address(swap));
        uint256 swapTokensBeforeBuy = token.balanceOf(address(swap));

        GyldAtomicSwap.SwapMessage memory buy = GyldAtomicSwap.SwapMessage({
            quoteId: 1,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: 1_000e6, // pays up to 1,000 USDC
            tokenOut: address(token),
            price: 10e18 * 1e18 / 1_000e6, // 10 bond tokens per 1,000 USDC (exactly at NAV)
            // Inside GyldAtomicSwap.DEFAULT_MAX_QUOTE_TTL (90s), with slack to spare.
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });
        bytes memory buySig = _sign(swap, SIGNER_PK, buy);

        // Taker executes its own swap (msg.sender must == taker). Broadcast AS the taker.
        vm.broadcast(TAKER_PK);
        usdc.approve(address(swap), buy.maxAmountIn);
        vm.broadcast(TAKER_PK);
        swap.executeSwap(buy, buySig, _noPermit(), buy.maxAmountIn);

        require(token.balanceOf(taker) == 10e18, "BUY: taker did not receive 10 tokens");
        require(token.balanceOf(address(swap)) == swapTokensBeforeBuy - 10e18, "BUY: swap inventory not debited");
        require(usdc.balanceOf(address(swap)) == swapUsdcBeforeBuy + 1_000e6, "BUY: swap USDC not credited");
        require(usdc.balanceOf(taker) == 100_000e6 - 1_000e6, "BUY: taker USDC not debited");
        require(token.totalSupply() == supplyBeforeBuy, "BUY: totalSupply changed (must not mint/burn)");
        require(swap.isQuoteUsed(1), "BUY: quoteId 1 not consumed");
        console2.log("[5] BUY executed at NAV");
        console2.log("    taker tokens: %d (10e18)", token.balanceOf(taker));
        console2.log("    swap USDC:    %d (+1000 USDC)", usdc.balanceOf(address(swap)));
        console2.log("    totalSupply:  %d (unchanged)", token.totalSupply());

        // ── Step 6: REDEEM leg ───────────────────────────────────────────────
        uint256 takerUsdcBeforeRedeem = usdc.balanceOf(taker);
        uint256 swapTokensBeforeRedeem = token.balanceOf(address(swap));

        GyldAtomicSwap.SwapMessage memory redeem = GyldAtomicSwap.SwapMessage({
            quoteId: 2,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: 10e18, // pays back up to 10 bond tokens
            tokenOut: address(usdc),
            price: 1_000e6 * 1e18 / 10e18, // 1,000 USDC per 10 bond tokens (exactly at NAV)
            // Inside GyldAtomicSwap.DEFAULT_MAX_QUOTE_TTL (90s), with slack to spare.
            expiry: uint64(block.timestamp + 60 seconds),
            epoch: 0
        });
        bytes memory redeemSig = _sign(swap, SIGNER_PK, redeem);

        vm.broadcast(TAKER_PK);
        token.approve(address(swap), redeem.maxAmountIn);
        vm.broadcast(TAKER_PK);
        swap.executeSwap(redeem, redeemSig, _noPermit(), redeem.maxAmountIn);

        require(token.balanceOf(taker) == 0, "REDEEM: taker tokens not debited");
        require(token.balanceOf(address(swap)) == swapTokensBeforeRedeem + 10e18, "REDEEM: tokens not back in swap");
        require(usdc.balanceOf(taker) == takerUsdcBeforeRedeem + 1_000e6, "REDEEM: taker did not get USDC back");
        require(usdc.balanceOf(taker) == 100_000e6, "REDEEM: taker not made whole on round trip");
        require(swap.isQuoteUsed(2), "REDEEM: quoteId 2 not consumed");
        console2.log("[6] REDEEM executed at NAV");
        console2.log("    taker tokens: %d (back to 0)", token.balanceOf(taker));
        console2.log("    taker USDC:   %d (100000 USDC, full round trip)", usdc.balanceOf(taker));
        console2.log("    swap tokens:  %d (collateral returned)", token.balanceOf(address(swap)));

        // ── Step 7: WITHDRAW leg (treasurer evacuates NET USDC to the wallet) ─
        uint256 walletUsdcBefore = usdc.balanceOf(deployer);
        uint256 swapUsdcBeforeWithdraw = usdc.balanceOf(address(swap));
        vm.broadcast(DEPLOYER_PK); // treasurer = deployer (acct[0]); a bare vm.broadcast() would sign with anvil acct[1], which holds no roles
        swap.withdraw(address(usdc), 1_000e6);
        require(usdc.balanceOf(deployer) == walletUsdcBefore + 1_000e6, "WITHDRAW: wallet not credited");
        require(usdc.balanceOf(address(swap)) == swapUsdcBeforeWithdraw - 1_000e6, "WITHDRAW: swap not debited");
        console2.log("[7] WITHDRAW: 1000 USDC evacuated to withdrawalWallet (%s)", deployer);

        console2.log("");
        console2.log("=== FLOW OK: deploy -> NAV -> wire -> seed -> BUY -> REDEEM -> WITHDRAW all asserted ===");
    }

    function _sign(GyldAtomicSwap swap, uint256 pk, GyldAtomicSwap.SwapMessage memory m)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, swap.hashSwapMessage(m));
        return abi.encodePacked(r, s, v);
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }
}
