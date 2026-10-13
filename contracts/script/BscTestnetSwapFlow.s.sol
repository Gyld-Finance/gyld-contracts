// SPDX-License-Identifier: UNLICENSED
/// @title BscTestnetSwapFlow
/// @notice BSC TESTNET (chain 97) proof for GLD-713 — drives the complete self-custodial
///         atomic-settlement flow against an 18-decimal cash token in one `forge script`
///         run: deploy a minimal stack + NAV + BUY + REDEEM + treasurer withdraw, with
///         require() asserts at every step so the run FAILS LOUD on any drift.
///
///         The BSC twin of AtomicSettlementFlow (Anvil, 6dp MockUSDC). It is NOT a
///         deployment recipe for the gateway stack (use DeployDevNet +
///         DeployAtomicSettlement for that; see docs/deploy/bsc-testnet.md).
///
/// ── Keys ────────────────────────────────────────────────────────────────────
///   BSC_TESTNET_PK  The ONE funded key (~0.05 tBNB is plenty at 0.1 gwei). It is the
///                   deployer and every admin/ops role. The taker, quote signer and
///                   token operator are throwaway keys DERIVED from it (testnet only),
///                   so nothing else needs funding; the deployer tops the taker up
///                   with gas.
///
/// ── Run command ─────────────────────────────────────────────────────────────
///   forge script contracts/script/BscTestnetSwapFlow.s.sol \
///     --rpc-url bsc_testnet --broadcast --slow \
///     --private-key $BSC_TESTNET_PK
///
/// ── Prices on an 18dp cash token ────────────────────────────────────────────
///   NAV $1.00 (8dp feed answer 1e8). `price` = tokenOut raw per 1e18 tokenIn raw:
///   10e18 bond tokens <-> 10e18 gUSD, so price = 1e18 both ways. The contract's band
///   divisor is 10**(26-18) = 1e8, so navValue = 10e18 * 1e8 / 1e8 = 10e18 gUSD.
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {MockSanctionsList} from "../test/MockSanctionsList.sol";
import {GyldTestUSD} from "../test/GyldTestUSD.sol";
import {DeployGuards} from "./lib/DeployGuards.sol";

contract BscTestnetSwapFlow is Script {
    uint256 constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    int256 constant NAV = 1e8; // $1.00 per token, 8dp
    uint16 constant MAX_BPS = 200; // 2% NAV band
    uint32 constant MAX_NAV_AGE = 86400; // 1 day
    uint8 constant CASH_DECIMALS = 18;
    uint256 constant TAKER_GAS = 0.005 ether; // tBNB for the taker's 4 txs, with slack

    uint256 deployerPk;
    uint256 takerPk;
    uint256 signerPk;
    uint256 operatorPk;

    function run() external {
        require(block.chainid == 97, "BscTestnetSwapFlow: BSC testnet (chainId 97) only");

        deployerPk = vm.envUint("BSC_TESTNET_PK");
        takerPk = _derive("taker");
        signerPk = _derive("quote-signer");
        // Must differ from the NAV feed owner (TokenFactory NavFeedOwnerIsOperator).
        operatorPk = _derive("token-operator");

        address deployer = vm.addr(deployerPk);
        address taker = vm.addr(takerPk);
        address signer = vm.addr(signerPk);
        address operator = vm.addr(operatorPk);

        console2.log("=== BscTestnetSwapFlow (chain 97, 18dp cash, GLD-713) ===");
        console2.log("deployer:       %s", deployer);
        console2.log("taker:          %s", taker);
        console2.log("quote signer:   %s", signer);
        console2.log("token operator: %s", operator);

        vm.startBroadcast(deployerPk);

        // ── Step 1: minimal base stack ───────────────────────────────────────
        MockSanctionsList sanctions = new MockSanctionsList(deployer);
        GyldTestUSD usd = new GyldTestUSD(CASH_DECIMALS, deployer);

        IssuanceManager issuanceMgr = IssuanceManager(
            address(
                new ERC1967Proxy(
                    address(new IssuanceManager()),
                    abi.encodeCall(IssuanceManager.initialize, (deployer, deployer, deployer))
                )
            )
        );
        issuanceMgr.grantRole(issuanceMgr.WHITELIST_ADMIN_ROLE(), deployer);
        issuanceMgr.grantRole(issuanceMgr.ISSUANCE_PAUSER_ROLE(), operator);

        TokenFactory factory = new TokenFactory(address(new GyldBondToken()), address(sanctions), deployer);
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));

        DeployGuards.requireValidIsin("US14913UBF66");
        DeployGuards.requireIsinVacant(address(factory), "US14913UBF66");
        (address token_, address navFeed_, address forwarder_) = factory.deployToken(
            "Caterpillar Inc 3.7% 2028",
            "14913UBF6",
            "US14913UBF66",
            1_851_811_200,
            operator,
            address(issuanceMgr),
            deployer // NAV feed owner — the broadcaster, so it can push NAV below
        );
        GyldBondToken token = GyldBondToken(token_);
        console2.log("[1] base wired");
        console2.log("    IssuanceManager: %s", address(issuanceMgr));
        console2.log("    TokenFactory:    %s", address(factory));
        console2.log("    Token (CAT):     %s", token_);
        console2.log("    NAVFeed:         %s", navFeed_);
        console2.log("    Forwarder:       %s", forwarder_);
        console2.log("    Sanctions:       %s", address(sanctions));
        console2.log("    gUSD (18dp):     %s", address(usd));

        // ── Step 2: NAV FIRST (registerSeries reverts on an unpriced feed) ───
        KaleidoscopeNAVFeed(navFeed_).updateAnswer(NAV);
        console2.log("[2] NAV pushed: %d (8dp = $1.00)", uint256(NAV));

        // ── Step 3: swap on an 18dp cash token + wiring ──────────────────────
        GyldAtomicSwap swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(new GyldAtomicSwap()),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (deployer, deployer, signer, deployer, address(usd), MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );
        issuanceMgr.addToWhitelist(address(swap));
        swap.registerSeries(address(token), factory.forwarderOf(address(token)));
        swap.setWithdrawalWallet(deployer);
        swap.grantRole(swap.ALLOWLIST_ADMIN_ROLE(), deployer);
        swap.setAllowed(taker, true);

        require(swap.cashDecimals() == CASH_DECIMALS, "swap did not store 18 cash decimals");
        require(swap.registeredSeries(address(token)), "series not registered");
        require(swap.isAllowed(taker), "taker not allowlisted");
        require(issuanceMgr.whitelisted(address(swap)), "swap not whitelisted AP");
        console2.log("[3] swap wired: %s (cashDecimals=%d)", address(swap), swap.cashDecimals());

        // ── Step 4: inventory, cash liquidity, taker funding ─────────────────
        issuanceMgr.subscribe(address(token), address(swap), 100e18);
        usd.mint(address(swap), 100e18);
        usd.mint(taker, 1_000e18);
        payable(taker).transfer(TAKER_GAS);
        require(token.balanceOf(address(swap)) == 100e18, "subscribe mint did not land in swap");
        console2.log("[4] 100 tokens + 100 gUSD in swap; taker funded with 1000 gUSD + gas");

        vm.stopBroadcast();

        // ── Step 5: BUY 10 tokens for 10 gUSD ───────────────────────────────
        uint256 swapUsdBeforeBuy = usd.balanceOf(address(swap));
        GyldAtomicSwap.SwapMessage memory buy = GyldAtomicSwap.SwapMessage({
            quoteId: 1,
            taker: taker,
            tokenIn: address(usd),
            maxAmountIn: 10e18,
            tokenOut: address(token),
            price: 1e18, // 1e18 token raw per 1e18 gUSD raw — exactly at NAV
            expiry: uint64(block.timestamp + 80 seconds), // inside the 90s TTL cap
            epoch: swap.quoteEpoch()
        });
        bytes memory buySig = _sign(swap, signerPk, buy);
        vm.broadcast(takerPk);
        usd.approve(address(swap), buy.maxAmountIn);
        vm.broadcast(takerPk);
        swap.executeSwap(buy, buySig, _noPermit(), buy.maxAmountIn);

        require(token.balanceOf(taker) == 10e18, "BUY: taker did not receive 10 tokens");
        require(usd.balanceOf(address(swap)) == swapUsdBeforeBuy + 10e18, "BUY: swap gUSD not credited");
        require(usd.balanceOf(taker) == 990e18, "BUY: taker gUSD not debited");
        console2.log("[5] BUY ok: taker holds %d tokens", token.balanceOf(taker));

        // ── Step 6: REDEEM 10 tokens for 10 gUSD ────────────────────────────
        GyldAtomicSwap.SwapMessage memory redeem = GyldAtomicSwap.SwapMessage({
            quoteId: 2,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: 10e18,
            tokenOut: address(usd),
            price: 1e18,
            expiry: uint64(block.timestamp + 80 seconds),
            epoch: swap.quoteEpoch()
        });
        bytes memory redeemSig = _sign(swap, signerPk, redeem);
        vm.broadcast(takerPk);
        token.approve(address(swap), redeem.maxAmountIn);
        vm.broadcast(takerPk);
        swap.executeSwap(redeem, redeemSig, _noPermit(), redeem.maxAmountIn);

        require(token.balanceOf(taker) == 0, "REDEEM: taker tokens not debited");
        require(usd.balanceOf(taker) == 1_000e18, "REDEEM: taker not made whole");
        console2.log("[6] REDEEM ok: taker back to %d gUSD", usd.balanceOf(taker));

        // ── Step 7: treasurer withdraw ──────────────────────────────────────
        uint256 walletBefore = usd.balanceOf(deployer);
        vm.broadcast(deployerPk);
        swap.withdraw(address(usd), 10e18);
        require(usd.balanceOf(deployer) == walletBefore + 10e18, "WITHDRAW: wallet not credited");
        console2.log("[7] WITHDRAW ok: 10 gUSD to withdrawalWallet");

        console2.log("");
        console2.log("=== BSC FLOW OK: 18dp deploy -> NAV -> BUY -> REDEEM -> WITHDRAW ===");
    }

    /// Throwaway testnet key derived from the funded key — never for real funds.
    function _derive(string memory label) internal view returns (uint256 pk) {
        pk = uint256(keccak256(abi.encodePacked(deployerPk, label))) % (SECP256K1_N - 1) + 1;
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
