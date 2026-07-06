// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldSettlementVault} from "../GyldSettlementVault.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {MockSanctionsList} from "../test/MockSanctionsList.sol";
import {MockUSDC} from "../test/MockUSDC.sol";

/// @title AtomicSettlementFlow
/// @notice LOCAL / DEV DEMO — drives the COMPLETE atomic-settlement flow against a
///         live Anvil node in a single `forge script` run. This is the committed,
///         repeatable replacement for the throwaway scratch script used during the
///         initial bring-up: a fresh deploy + BUY + REDEEM round trip, with require()
///         asserts at every step so the run FAILS LOUD the moment anything drifts.
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
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///   # ^ Anvil account[0] default key. Local dev only — never reuse anywhere else.
///
/// ── The NAV-FIRST gotcha (documented, enforced below) ───────────────────────
///   A NAV price MUST be pushed to the feed BEFORE the first vault.deposit /
///   vault.totalAssets call. The vault values its bond inventory through the NAV
///   forwarder; with no price set, totalAssets() reverts NoPriceSet and the dust
///   seed deposit (and every quote after it) reverts. Step 2 below pushes the
///   price first, on purpose.
///
/// ── What it proves ──────────────────────────────────────────────────────────
///   1. Minimal base wired: IssuanceManager + TokenFactory + a real CAT-style
///      GyldBondToken/NAVFeed/forwarder + MockSanctionsList + MockUSDC.
///   2. NAV pushed first ($100, 8dp).
///   3. Vault + Swap deployed, setSwap, vault whitelisted as AP, series registered,
///      dust LP seed deposited.
///   4. Inventory seeded via IssuanceManager.subscribe(token, vault, n).
///   5. BUY: taker signs nothing — the QUOTE_SIGNER signs an EIP-712 BUY quote, the
///      taker executes it. Asserts: taker tokens up, vault USDC up, supply unchanged.
///   6. REDEEM: QUOTE_SIGNER signs a REDEEM quote, taker executes it. Asserts: USDC
///      back to taker, tokens back to vault.
contract AtomicSettlementFlow is Script {
    // Anvil deterministic keys. Local-only; account[0] is the broadcaster.
    uint256 constant TAKER_PK  = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // acct[1]
    uint256 constant SIGNER_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // acct[2]

    // NAV $100.00 per token (8dp): 1e18 token <-> 100e6 USDC. 8 decimals.
    int256  constant NAV  = 100e8; // 10000000000
    uint256 constant DUST = 1e6;   // 1 USDC seed deposit (6dp)

    function run() external {
        require(block.chainid == 31337, "AtomicSettlementFlow: Anvil (chainId 31337) only");

        address taker  = vm.addr(TAKER_PK);
        address signer = vm.addr(SIGNER_PK);
        address deployer = msg.sender; // broadcaster = deployer = every admin/ops role (dev)

        console2.log("=== AtomicSettlementFlow (LOCAL DEV) ===");
        console2.log("deployer/broadcaster: %s", deployer);
        console2.log("taker (acct[1]):      %s", taker);
        console2.log("quote signer (acct[2]): %s", signer);

        vm.startBroadcast();

        // ── Step 1: minimal base stack ───────────────────────────────────────
        MockSanctionsList sanctions = new MockSanctionsList();
        MockUSDC usdc = new MockUSDC();

        IssuanceManager issuanceMgr = IssuanceManager(address(new ERC1967Proxy(
            address(new IssuanceManager()),
            abi.encodeCall(IssuanceManager.initialize, (deployer, deployer, deployer))
        )));
        issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), deployer);

        TokenFactory factory = new TokenFactory(address(new GyldBondToken()), address(sanctions));
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));

        // CAT-style series — deployer is factory owner so deployToken is called directly
        // (DEFAULT_ADMIN on the token is the deployer; fine for a dev demo).
        (address token_, address navFeed_, address forwarder_) = factory.deployToken(
            "Caterpillar Inc 3.7% 2028",
            "14913UBF6",
            "US14913UBF62",
            1_788_739_200,
            deployer,           // token operator / pauser
            address(issuanceMgr),
            deployer            // NAV feed owner
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

        // ── Step 3: vault + swap + wiring + dust seed ────────────────────────
        GyldSettlementVault vault = GyldSettlementVault(address(new ERC1967Proxy(
            address(new GyldSettlementVault()),
            abi.encodeCall(
                GyldSettlementVault.initialize,
                (deployer, deployer, deployer, address(usdc), address(issuanceMgr))
            )
        )));
        GyldAtomicSwap swap = GyldAtomicSwap(address(new ERC1967Proxy(
            address(new GyldAtomicSwap()),
            abi.encodeCall(GyldAtomicSwap.initialize, (deployer, deployer, signer, address(vault)))
        )));
        vault.setSwap(address(swap));
        issuanceMgr.addToWhitelist(address(vault));
        vault.registerSeries(address(token), factory.forwarderOf(address(token)));

        vault.grantRole(vault.LP_ROLE(), deployer);
        usdc.mint(deployer, DUST);
        usdc.approve(address(vault), DUST);
        uint256 dustShares = vault.deposit(DUST);

        require(vault.swap() == address(swap), "vault.swap mismatch");
        require(swap.vault() == address(vault), "swap.vault mismatch");
        require(vault.hasRole(vault.SWAP_ROLE(), address(swap)), "swap lacks SWAP_ROLE");
        require(issuanceMgr.whitelisted(address(vault)), "vault not whitelisted AP");
        require(vault.registeredSeries(address(token)), "series not registered");
        require(dustShares > 0, "dust deposit minted 0 shares");
        require(vault.totalAssets() == DUST, "totalAssets != dust after seed");
        console2.log("[3] vault + swap wired; dust seeded");
        console2.log("    Vault: %s", address(vault));
        console2.log("    Swap:  %s", address(swap));
        console2.log("    dust shares: %d, totalAssets: %d", dustShares, vault.totalAssets());

        // ── Step 4: seed inventory via the real subscribe mint path ──────────
        issuanceMgr.subscribe(address(token), address(vault), 100e18); // 100 tokens @ $100
        require(token.balanceOf(address(vault)) == 100e18, "subscribe mint did not land in vault");
        require(token.totalSupply() == 100e18, "unexpected supply after subscribe");
        console2.log("[4] inventory seeded: 100 tokens minted to vault; supply=%d", token.totalSupply());

        // Add USDC liquidity to the vault so it can pay out the redeem leg, and fund the taker.
        usdc.mint(deployer, 10_000e6);
        usdc.approve(address(vault), 10_000e6);
        vault.deposit(10_000e6);
        usdc.mint(taker, 100_000e6);
        // Whitelist taker now (needed later if a redeem beneficiary path is exercised;
        // harmless for the swap legs which never touch the AP whitelist).
        issuanceMgr.addToWhitelist(taker);
        console2.log("    LP liquidity added: vault USDC=%d; taker funded with 100000 USDC", usdc.balanceOf(address(vault)));

        vm.stopBroadcast();

        // ── Step 5: BUY leg ──────────────────────────────────────────────────
        uint256 supplyBeforeBuy = token.totalSupply();
        uint256 vaultUsdcBeforeBuy = usdc.balanceOf(address(vault));
        uint256 vaultTokensBeforeBuy = token.balanceOf(address(vault));

        GyldAtomicSwap.SwapMessage memory buy = GyldAtomicSwap.SwapMessage({
            quoteId:     1,
            taker:       taker,
            tokenIn:     address(usdc),
            maxAmountIn: 1_000e6,   // pays up to 1,000 USDC
            tokenOut:    address(token),
            price:       10e18 * 1e18 / 1_000e6, // 10 bond tokens per 1,000 USDC (exactly at NAV)
            expiry:      uint64(block.timestamp + 15 minutes),
            epoch:       0
        });
        bytes memory buySig = _sign(swap, SIGNER_PK, buy);

        // Taker executes its own swap (msg.sender must == taker). Broadcast AS the taker.
        vm.broadcast(TAKER_PK);
        usdc.approve(address(swap), buy.maxAmountIn);
        vm.broadcast(TAKER_PK);
        swap.executeSwap(buy, buySig, _noPermit(), buy.maxAmountIn);

        require(token.balanceOf(taker) == 10e18, "BUY: taker did not receive 10 tokens");
        require(token.balanceOf(address(vault)) == vaultTokensBeforeBuy - 10e18, "BUY: vault inventory not debited");
        require(usdc.balanceOf(address(vault)) == vaultUsdcBeforeBuy + 1_000e6, "BUY: vault USDC not credited");
        require(usdc.balanceOf(taker) == 100_000e6 - 1_000e6, "BUY: taker USDC not debited");
        require(token.totalSupply() == supplyBeforeBuy, "BUY: totalSupply changed (must not mint/burn)");
        require(swap.isQuoteUsed(1), "BUY: quoteId 1 not consumed");
        console2.log("[5] BUY executed at NAV");
        console2.log("    taker tokens: %d (10e18)", token.balanceOf(taker));
        console2.log("    vault USDC:   %d (+1000 USDC)", usdc.balanceOf(address(vault)));
        console2.log("    totalSupply:  %d (unchanged)", token.totalSupply());

        // ── Step 6: REDEEM leg ───────────────────────────────────────────────
        uint256 takerUsdcBeforeRedeem = usdc.balanceOf(taker);
        uint256 vaultTokensBeforeRedeem = token.balanceOf(address(vault));

        GyldAtomicSwap.SwapMessage memory redeem = GyldAtomicSwap.SwapMessage({
            quoteId:     2,
            taker:       taker,
            tokenIn:     address(token),
            maxAmountIn: 10e18,     // pays back up to 10 bond tokens
            tokenOut:    address(usdc),
            price:       1_000e6 * 1e18 / 10e18, // 1,000 USDC per 10 bond tokens (exactly at NAV)
            expiry:      uint64(block.timestamp + 15 minutes),
            epoch:       0
        });
        bytes memory redeemSig = _sign(swap, SIGNER_PK, redeem);

        vm.broadcast(TAKER_PK);
        token.approve(address(swap), redeem.maxAmountIn);
        vm.broadcast(TAKER_PK);
        swap.executeSwap(redeem, redeemSig, _noPermit(), redeem.maxAmountIn);

        require(token.balanceOf(taker) == 0, "REDEEM: taker tokens not debited");
        require(token.balanceOf(address(vault)) == vaultTokensBeforeRedeem + 10e18, "REDEEM: tokens not back in vault");
        require(usdc.balanceOf(taker) == takerUsdcBeforeRedeem + 1_000e6, "REDEEM: taker did not get USDC back");
        require(usdc.balanceOf(taker) == 100_000e6, "REDEEM: taker not made whole on round trip");
        require(swap.isQuoteUsed(2), "REDEEM: quoteId 2 not consumed");
        console2.log("[6] REDEEM executed at NAV");
        console2.log("    taker tokens: %d (back to 0)", token.balanceOf(taker));
        console2.log("    taker USDC:   %d (100000 USDC, full round trip)", usdc.balanceOf(taker));
        console2.log("    vault tokens: %d (collateral returned)", token.balanceOf(address(vault)));

        console2.log("");
        console2.log("=== FLOW OK: deploy -> NAV -> wire -> seed -> BUY -> REDEEM all asserted ===");
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
