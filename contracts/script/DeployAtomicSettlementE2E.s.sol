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

/// @title DeployAtomicSettlementE2E
/// @notice Self-contained Anvil deploy for the Rust M7 e2e golden
///         (`crates/e2e/tests/atomic_swap_flow.rs`). Deploys a minimal but real
///         self-custodial stack, pushes a NAV, seeds the swap's own inventory +
///         USDC liquidity, allowlists the taker, and STOPS — leaving the chain in
///         a ready state at `quoteEpoch == 0` for the Rust test to drive the full
///         AP round trip (BUY → REPLENISH → REDEEM → treasurer WITHDRAW) plus the
///         allowlist / NAV-band / StaleNav revert proofs.
///
///         Unlike `AtomicSettlementFlow.s.sol` (which drives the whole flow in
///         Solidity), this script does NOT execute any swap — the Rust seam
///         (SwapQuoteService + PrivkeySwapQuoteSigner → EvmAtomicSwap adapter →
///         SwapWatcher) is what M7 exercises. This is a fixtures builder only.
///
/// ── Role model (Anvil deterministic accounts) ──────────────────────────────
///   broadcaster / deployer = account[0]  — every admin/ops role, and the
///                                           QUOTE_SIGNER + TREASURER (the Rust
///                                           PrivkeySwapQuoteSigner uses acct[0]'s
///                                           key, so recovered signer holds
///                                           QUOTE_SIGNER_ROLE).
///   taker (AP)             = account[1]  — allowlisted for executeSwap, funded
///                                           with USDC.
///   non-allowlisted taker  = account[3]  — funded, deliberately NOT allowlisted
///                                           (allowlist-revert proof).
///   withdrawalWallet       = account[5]  — a FIXED destination distinct from the
///                                           treasurer, so the withdraw proof shows
///                                           funds landing at the admin-fixed wallet.
///
/// ── Run (start anvil --chain-id 31337 first) ────────────────────────────────
///   forge script contracts/script/DeployAtomicSettlementE2E.s.sol \
///     --rpc-url http://127.0.0.1:8545 --broadcast \
///     --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
///
/// ── Outputs (grep the `KEY=VALUE` lines; feed to the Rust test env) ─────────
///   E2E_SWAP  E2E_TOKEN  E2E_USDC  E2E_NAVFEED  E2E_FORWARDER
///   E2E_ISSUANCE_MANAGER  E2E_WITHDRAWAL_WALLET
contract DeployAtomicSettlementE2E is Script {
    address constant TAKER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8; // acct[1]
    address constant BOB = 0x90F79bf6EB2c4f870365E785982E1f101E93b906; // acct[3] (not allowlisted)
    address constant WITHDRAWAL_WALLET = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc; // acct[5]

    int256 constant NAV = 100e8; // $100.00 per token, 8dp — matches the Rust market-data mid
    uint16 constant MAX_BPS = 200; // 2% NAV band
    uint32 constant MAX_NAV_AGE = 86400; // 1 day

    function run() external {
        require(block.chainid == 31337, "DeployAtomicSettlementE2E: Anvil (chainId 31337) only");

        address deployer = msg.sender; // broadcaster = every admin role + quote signer + treasurer

        vm.startBroadcast();

        // ── 1. Minimal base stack ────────────────────────────────────────────
        MockSanctionsList sanctions = new MockSanctionsList();
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

        TokenFactory factory = new TokenFactory(address(new GyldBondToken()), address(sanctions));
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));

        // CAT-style series — deployer is factory owner so deployToken is direct.
        (address token_, address navFeed_, address forwarder_) = factory.deployToken(
            "Caterpillar Inc 3.7% 2028",
            "14913UBF6",
            "US14913UBF66",
            1_788_739_200,
            deployer, // token operator / pauser
            address(issuanceMgr),
            deployer // NAV feed owner
        );
        GyldBondToken token = GyldBondToken(token_);
        KaleidoscopeNAVFeed navFeed = KaleidoscopeNAVFeed(navFeed_);

        // ── 2. NAV FIRST (executeSwap fails closed with InvalidNav otherwise) ─
        navFeed.updateAnswer(NAV);

        // ── 3. Self-custodial swap + wiring ───────────────────────────────────
        //   QUOTE_SIGNER = deployer (acct[0]) so the Rust PrivkeySwapQuoteSigner
        //   signs quotes that recover to a QUOTE_SIGNER_ROLE holder.
        GyldAtomicSwap swap = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(new GyldAtomicSwap()),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (deployer, deployer, deployer, deployer, address(usdc), MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );
        issuanceMgr.addToWhitelist(address(swap)); // swap holds inventory → whitelisted AP (subscribe recipient)
        swap.registerSeries(address(token), factory.forwarderOf(address(token)));
        swap.setWithdrawalWallet(WITHDRAWAL_WALLET); // fixed treasury destination (distinct from treasurer)
        // setAllowed is gated on ALLOWLIST_ADMIN_ROLE, not DEFAULT_ADMIN_ROLE (GYL-1050).
        swap.grantRole(swap.ALLOWLIST_ADMIN_ROLE(), deployer);
        swap.setAllowed(TAKER, true); // acct[1] may be an executeSwap taker

        // ── 4. Seed the swap's OWN inventory + USDC liquidity ─────────────────
        issuanceMgr.subscribe(address(token), address(swap), 100e18); // 100 tokens minted DIRECTLY to the swap
        usdc.mint(address(swap), 100_000e6); // redeem-leg liquidity
        usdc.mint(TAKER, 1_000_000e6); // taker buys with this
        usdc.mint(BOB, 100_000e6); // funded for the allowlist-revert proof

        // Invariants (fail-loud if the fixture drifts).
        require(swap.quoteEpoch() == 0, "swap must be at epoch 0 for the Rust test");
        require(swap.registeredSeries(address(token)), "series not registered");
        require(swap.withdrawalWallet() == WITHDRAWAL_WALLET, "withdrawalWallet mismatch");
        require(swap.isAllowed(TAKER), "taker not allowlisted");
        require(!swap.isAllowed(BOB), "bob must NOT be allowlisted");
        require(issuanceMgr.whitelisted(address(swap)), "swap not whitelisted AP");
        require(token.balanceOf(address(swap)) == 100e18, "swap inventory not seeded");
        require(token.totalSupply() == 100e18, "unexpected supply after subscribe");

        vm.stopBroadcast();

        console2.log("=== DeployAtomicSettlementE2E: fixtures ready (epoch 0) ===");
        console2.log("E2E_SWAP=%s", address(swap));
        console2.log("E2E_TOKEN=%s", token_);
        console2.log("E2E_USDC=%s", address(usdc));
        console2.log("E2E_NAVFEED=%s", navFeed_);
        console2.log("E2E_FORWARDER=%s", forwarder_);
        console2.log("E2E_ISSUANCE_MANAGER=%s", address(issuanceMgr));
        console2.log("E2E_WITHDRAWAL_WALLET=%s", WITHDRAWAL_WALLET);
    }
}
