// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployDevNet} from "../contracts/script/DeployDevNet.s.sol";
import {DeployAtomicSettlement} from "../contracts/script/DeployAtomicSettlement.s.sol";
import {DeployGuards} from "../contracts/script/lib/DeployGuards.sol";
import {IssuanceManager} from "../contracts/IssuanceManager.sol";
import {TokenFactory} from "../contracts/TokenFactory.sol";
import {GyldBondToken} from "../contracts/GyldBondToken.sol";
import {KaleidoscopeNAVFeed} from "../contracts/KaleidoscopeNAVFeed.sol";
import {NAVFeedForwarder} from "../contracts/NAVFeedForwarder.sol";
import {GyldAtomicSwap} from "../contracts/GyldAtomicSwap.sol";
import {MockSanctionsList} from "../contracts/test/MockSanctionsList.sol";
import {MockUSDC} from "../contracts/test/MockUSDC.sol";

/// @title KatanaTestnetStack
/// @notice Full-stack KATANA TESTNET "Bokuto" (chain 737373) deployment in the PRODUCTION
///         role topology,
///         driven by `script-katana/deploy-katana-testnet.sh` (read that first — runbook:
///         docs/deploy/katana-testnet.md). GLD-738.
///
///         It runs the repo's own deploy scripts UNCHANGED — `DeployDevNet` and
///         `DeployAtomicSettlement` are instantiated and their `run()` called — with every
///         role env var pinned to a dedicated key, deploys the repo's 6-decimal `MockUSDC`
///         as the cash leg (the Halborn-audited `GyldAtomicSwap.initialize` requires a
///         6dp cash token — F-1 — and there is no Circle USDC on Bokuto), then does
///         the steps those scripts leave to other key holders on production: governance
///         Phase 2 through the timelock, the first NAV push, the swap's AP whitelisting,
///         inventory, the taker allowlist, and a BUY + REDEEM smoke settlement.
///
/// ── Keys ────────────────────────────────────────────────────────────────────────
///   KATANA_TESTNET_PK (env, 0x-prefixed) is the ONE funded key: deployer + gas funder. Every
///   other role is a throwaway key DERIVED from it:
///       pk(role) = uint256(keccak256(abi.encodePacked(KATANA_TESTNET_PK, "gyld.katana737373.", role)))
///                  % (secp256k1.n - 1) + 1
///   Keys are only ever read from the environment; nothing here logs one except
///   `exportKeys()`, whose output the shell driver writes straight to a chmod-600 file.
///
/// ── Entry points (`--sig`) ──────────────────────────────────────────────────────
///   plan()        role → address table (no keys, no transactions)
///   exportKeys()  derived keys as KEY=VALUE lines — for the driver's chmod-600 file ONLY
///   deploy()      the whole stack (needs `--sender <deployer>`; see deploy-katana-testnet.sh)
///   pushNav()     re-push each feed's current NAV from the NAV owner key (keep-alive)
///   smoke()       BUY + REDEEM through the swap with an EIP-712 quote from the quote signer
///   verify()      read every role holder and parameter back from chain; reverts on drift
///   dryRun()      deploy() + smoke() + verify() in ONE simulation (run without --broadcast)
///   smoke/pushNav/verify read EVM_FACTORY_ADDRESS + EVM_ATOMIC_SWAP_ADDRESS from env.
contract KatanaTestnetStack is Script {
    // ── Chain / derivation ────────────────────────────────────────────────────
    uint256 internal constant KATANA_BOKUTO = 737373;
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    string internal constant LABEL_PREFIX = "gyld.katana737373.";

    // ── Economics (cash token is 6dp MockUSDC; bond tokens 18dp; NAV 8dp) ──────
    //   Quote price = tokenOut raw per 1e18 tokenIn raw; the swap's band values a bond
    //   amount as tokenAmount * nav / 1e20 USDC raw (18dp + 8dp - 6dp = 20).
    int256 internal constant NAV_ONE_DOLLAR = 1e8; // $1.00, inside the FIND-003 $0.10-$2.00 range
    uint16 internal constant MAX_QUOTE_DEVIATION_BPS = 200; // 2% band (DeployAtomicSettlement default)
    uint32 internal constant MAX_NAV_AGE_SECS = 86_400; // 24 h (FIND-022 parity with the feed)
    uint8 internal constant CASH_DECIMALS = 6; // the swap's F-1 probe requires exactly 6
    uint256 internal constant INVENTORY_PER_SERIES = 1_000e18; // bond tokens minted into the swap
    uint256 internal constant SWAP_CASH = 10_000e6; // USDC redeem-leg liquidity in the swap
    uint256 internal constant TAKER_CASH = 1_000e6; // USDC for the smoke taker
    uint256 internal constant SMOKE_CASH = 10e6; // 10 USDC -> 10 CAT at $1.00
    /// Quote lifetime from the SIMULATION timestamp: as long as possible (the broadcast
    /// runs after the simulation) while staying under the swap's 90 s DEFAULT_MAX_QUOTE_TTL.
    uint64 internal constant SMOKE_QUOTE_TTL = 85;

    // ── Expected on-chain constants (asserted by verify) ──────────────────────
    uint256 internal constant FEED_MIN_ANSWER = 1e7; // $0.10
    uint256 internal constant FEED_MAX_ANSWER = 2e8; // $2.00
    uint256 internal constant FEED_ABS_MIN = 1e7; // $0.10
    uint256 internal constant FEED_ABS_MAX = 5e8; // $5.00

    // ── Roles (index into Actors arrays) ──────────────────────────────────────
    uint256 internal constant DEPLOYER = 0;
    uint256 internal constant GOVERNANCE = 1;
    uint256 internal constant OPS = 2;
    uint256 internal constant NAV_OWNER = 3;
    uint256 internal constant SUBSCRIBER = 4;
    uint256 internal constant REDEEMER = 5;
    uint256 internal constant WHITELIST_ADMIN = 6;
    uint256 internal constant ISSUANCE_PAUSER = 7;
    uint256 internal constant QUOTE_SIGNER = 8;
    uint256 internal constant TREASURER = 9;
    uint256 internal constant ALLOWLIST_ADMIN = 10;
    uint256 internal constant DISTRIBUTION = 11;
    uint256 internal constant SANCTIONS_ADMIN = 12;
    uint256 internal constant TAKER = 13;
    uint256 internal constant N_ROLES = 14;
    uint256 internal constant N_SERIES = 3;

    struct Actors {
        uint256[N_ROLES] pk;
        address[N_ROLES] addr;
    }

    struct Stack {
        TimelockController timelock;
        IssuanceManager im;
        TokenFactory factory;
        MockSanctionsList sanctions;
        MockUSDC usdc;
        GyldAtomicSwap swap;
        address[N_SERIES] tokens;
        address[N_SERIES] feeds;
        address[N_SERIES] forwarders;
    }

    struct RoleInfo {
        string label; // derivation label suffix and display name
        string addrEnv; // env var / addresses-file key for the holder's address
        string pkEnv; // keys-file key for the holder's private key
        uint256 gasFloat; // ETH top-up target funded by the deployer
    }

    struct Bond {
        string name;
        string symbol; // CUSIP, as DeployDevNet uses it
        string isin;
        uint256 maturity;
        bytes32 salt; // timelock operation salt (same as DeployDevNet)
        string tag;
    }

    uint256 internal _checks;

    // ══ Entry points ══════════════════════════════════════════════════════════

    function plan() external view {
        Actors memory a = _actors();
        console.log("=== Katana Bokuto testnet (737373) role plan - addresses only ===");
        for (uint256 i; i < N_ROLES; ++i) {
            console.log(_planLine(_role(i), a.addr[i]));
        }
        for (uint256 i; i < N_ROLES; ++i) {
            console.log(string.concat("@@ROLE ", _role(i).addrEnv, "=", vm.toString(a.addr[i])));
        }
        console.log(string.concat("@@ROLE FUND_TOTAL_WEI=", vm.toString(_fundTotal())));
    }

    /// @notice Derived private keys as KEY=VALUE lines. The ONLY function that prints a
    ///         key; the driver pipes it straight into a chmod-600 file and never shows it.
    function exportKeys() external view {
        Actors memory a = _actors();
        console.log(string.concat("@@KEY DEPLOYER_ADDRESS=", vm.toString(a.addr[DEPLOYER])));
        for (uint256 i = 1; i < N_ROLES; ++i) {
            RoleInfo memory r = _role(i);
            console.log(string.concat("@@KEY # ", r.label, " (label ", LABEL_PREFIX, r.label, ")"));
            console.log(string.concat("@@KEY ", r.addrEnv, "=", vm.toString(a.addr[i])));
            console.log(string.concat("@@KEY ", r.pkEnv, "=", vm.toString(bytes32(a.pk[i]))));
        }
    }

    function _planLine(RoleInfo memory r, address who) internal pure returns (string memory line) {
        line = string.concat("  ", _pad(r.label, 16), " ", vm.toString(who));
        line = string.concat(line, "  ", _pad(r.addrEnv, 21), " gas float ", _fmtEth(r.gasFloat));
    }

    function deploy() external {
        Actors memory a = _actors();
        if (vm.envOr("KATANA_STACK_RESUME", false)) {
            // `forge script --resume` re-executes the script ONLY to collect the signers it
            // lacks, then resends the SAVED sequence. Re-running the deploy here would trip
            // the CREATE2 vacancy guards on the half-landed stack, so just register keys.
            for (uint256 i; i < N_ROLES; ++i) {
                vm.rememberKey(a.pk[i]);
            }
            console.log("resume: 14 signers registered; forge resends the saved deploy sequence");
            return;
        }
        Stack memory s = _deploy(a);
        _printAddresses(a, s);
    }

    function pushNav() external {
        _requireChain();
        Actors memory a = _actors();
        _pushNav(a, _loadStack());
    }

    function smoke() external {
        _requireChain();
        Actors memory a = _actors();
        _smoke(a, _loadStack());
    }

    function verify() external {
        _requireChain();
        Actors memory a = _actors();
        Stack memory s = _loadStack();
        _verify(a, s);
        _printAddresses(a, s);
    }

    /// @notice deploy + smoke + verify in ONE simulation. Run WITHOUT --broadcast: the
    ///         smoke quote expires 85 s after simulation, far too soon for a ~60-tx broadcast.
    function dryRun() external {
        Actors memory a = _actors();
        Stack memory s = _deploy(a);
        _smoke(a, s);
        _verify(a, s);
        _printAddresses(a, s);
    }

    // ══ Deploy ═══════════════════════════════════════════════════════════════

    function _deploy(Actors memory a) internal returns (Stack memory s) {
        _requireChain();
        // The nested scripts broadcast with a bare vm.startBroadcast() and read their
        // deployer from DeployGuards.broadcaster() (= tx.origin): pin both to the deployer.
        require(
            tx.origin == a.addr[DEPLOYER],
            string.concat("KatanaTestnetStack: run with --sender ", vm.toString(a.addr[DEPLOYER]))
        );
        vm.rememberKey(a.pk[DEPLOYER]);

        console.log("[0] fund derived role keys with ETH (top-up to float)");
        _fundRoles(a);

        console.log("[1] MockSanctionsList (owner = sanctions-admin, not the deployer)");
        s.sanctions = _deploySanctions(a);

        console.log("[2] DeployDevNet (TIMELOCK_DELAY_SECONDS=0, every role a dedicated key)");
        _runDeployDevNet(a, s);

        console.log("[3] MockUSDC (6dp cash leg; minted to exact destinations in [7])");
        s.usdc = _deployMockUsdc(a);

        console.log("[4] governance Phase 2 via the timelock: factory acceptOwnership + 3 series");
        _governancePhase2(a, s);

        console.log("[5] first NAV push ($1.00) from the NAV feed owner - before registerSeries");
        _pushNav(a, s);

        console.log("[6] DeployAtomicSettlement (cash = MockUSDC, series registered, admin -> timelock)");
        _runDeployAtomicSettlement(a, s);

        console.log("[7] whitelist swap as AP, mint inventory, fund cash, allowlist taker");
        _wire(a, s);
    }

    function _fundRoles(Actors memory a) internal {
        vm.startBroadcast(a.pk[DEPLOYER]);
        for (uint256 i = 1; i < N_ROLES; ++i) {
            uint256 float_ = _role(i).gasFloat;
            uint256 bal = a.addr[i].balance;
            if (float_ > bal) payable(a.addr[i]).transfer(float_ - bal);
        }
        vm.stopBroadcast();
    }

    /// The production SANCTIONS_LIST is a separately-deployed SanctionsOracleMirror run by
    /// its own keeper. Mirror that: pre-deploy the mock with a dedicated owner and pass it
    /// in, instead of letting DeployDevNet make the deployer its owner.
    function _deploySanctions(Actors memory a) internal returns (MockSanctionsList m) {
        bytes memory init = abi.encodePacked(type(MockSanctionsList).creationCode, abi.encode(a.addr[SANCTIONS_ADMIN]));
        vm.startBroadcast(a.pk[DEPLOYER]);
        m = new MockSanctionsList{salt: DeployGuards.vacantSalt("KatanaTestnetStack:MockSanctionsList", init)}(
            a.addr[SANCTIONS_ADMIN]
        );
        vm.stopBroadcast();
    }

    function _runDeployDevNet(Actors memory a, Stack memory s) internal {
        // Pin EVERY input, so a stray variable in the operator's shell cannot leak in.
        _setEnv("GOVERNANCE_MULTISIG", a.addr[GOVERNANCE]);
        _setEnv("OPS_MULTISIG", a.addr[OPS]);
        _setEnv("SUBSCRIBER_ADDRESS", a.addr[SUBSCRIBER]);
        _setEnv("REDEEMER_ADDRESS", a.addr[REDEEMER]);
        _setEnv("WHITELIST_ADMIN", a.addr[WHITELIST_ADMIN]);
        _setEnv("ISSUANCE_PAUSER", a.addr[ISSUANCE_PAUSER]);
        _setEnv("NAV_FEED_OWNER", a.addr[NAV_OWNER]);
        _setEnv("SANCTIONS_LIST", address(s.sanctions));
        vm.setEnv("SANCTIONS_PROBE_FLAGGED", ""); // production-only input; unused on 737373
        vm.setEnv("TIMELOCK_DELAY_SECONDS", "0");

        DeployDevNet d = new DeployDevNet();
        d.run();
        s.timelock = d.timelock();
        s.im = d.issuanceMgr();
        s.factory = d.factory();
        require(d.sanctionsOracle() == address(s.sanctions), "KatanaTestnetStack: DeployDevNet ignored SANCTIONS_LIST");
        // Governance is NOT the deployer, so DeployDevNet stops after Phase 1 exactly as on
        // production: the factory hand-off is pending and no series exists yet.
        require(!d.factoryOwnershipAccepted(), "KatanaTestnetStack: expected a pending factory hand-off");
    }

    /// The repo's MockUSDC (contracts/test/MockUSDC.sol, unchanged): 6dp, as the audited
    /// swap's initialize probe requires. Deployed directly rather than via DeployMockUSDC,
    /// which mints 100k to three publicly-keyed Anvil accounts — pointless on a public
    /// testnet. Same dev-chain guard DeployMockUSDC applies.
    function _deployMockUsdc(Actors memory a) internal returns (MockUSDC m) {
        DeployGuards.requireProdSafe("deploying MockUSDC (permissionless mint)");
        bytes memory init = type(MockUSDC).creationCode;
        vm.startBroadcast(a.pk[DEPLOYER]);
        m = new MockUSDC{salt: DeployGuards.vacantSalt("KatanaTestnetStack:MockUSDC", init)}();
        vm.stopBroadcast();
        require(m.decimals() == CASH_DECIMALS, "KatanaTestnetStack: MockUSDC is not 6dp");
    }

    /// What the governance multisig does on production after the 48 h delay: accept the
    /// factory through the timelock, then deploy each series through it. Same three bonds,
    /// salts and guards as DeployDevNet._deployBondTokens (which only runs when the
    /// deployer is itself the proposer). Delay 0 here, so schedule+execute run back to back.
    function _governancePhase2(Actors memory a, Stack memory s) internal {
        TimelockController tl = s.timelock;
        TokenFactory f = s.factory;
        require(f.pendingOwner() == address(tl), "KatanaTestnetStack: factory pendingOwner is not the timelock");

        vm.startBroadcast(a.pk[GOVERNANCE]);
        bytes memory accept = abi.encodeCall(f.acceptOwnership, ());
        tl.schedule(address(f), 0, accept, bytes32(0), bytes32("accept"), 0);
        tl.execute(address(f), 0, accept, bytes32(0), bytes32("accept"));
        require(f.owner() == address(tl), "KatanaTestnetStack: timelock did not accept the factory");

        for (uint256 i; i < N_SERIES; ++i) {
            address token = _deploySeries(tl, f, _bond(i), a.addr[OPS], address(s.im), a.addr[NAV_OWNER]);
            s.tokens[i] = token;
            s.feeds[i] = f.navFeedOf(token);
            s.forwarders[i] = f.forwarderOf(token);
            require(s.feeds[i] != address(0), "KatanaTestnetStack: series deploy did not land");
            console.log(string.concat("    series ", _bond(i).tag, " token ", vm.toString(token)));
            console.log(
                string.concat("      feed ", vm.toString(s.feeds[i]), " forwarder ", vm.toString(s.forwarders[i]))
            );
        }
        vm.stopBroadcast();
    }

    /// One timelock round trip per series (inside the caller's governance broadcast).
    /// deployToken's return values are lost through execute, so predict the address first.
    function _deploySeries(
        TimelockController tl,
        TokenFactory f,
        Bond memory b,
        address operator,
        address im,
        address navOwner
    ) internal returns (address token) {
        DeployGuards.requireValidIsin(b.isin);
        DeployGuards.requireIsinVacant(address(f), b.isin);
        token = f.predictTokenAddress(b.name, b.symbol, b.isin, b.maturity);
        bytes memory data =
            abi.encodeCall(f.deployToken, (b.name, b.symbol, b.isin, b.maturity, operator, im, navOwner));
        tl.schedule(address(f), 0, data, bytes32(0), b.salt, 0);
        tl.execute(address(f), 0, data, bytes32(0), b.salt);
    }

    /// First push: $1.00. Later (keep-alive): re-push each feed's CURRENT answer once the
    /// 1 h MIN_UPDATE_INTERVAL has passed — same price, fresh updatedAt, no deviation.
    function _pushNav(Actors memory a, Stack memory s) internal {
        vm.startBroadcast(a.pk[NAV_OWNER]);
        for (uint256 i; i < N_SERIES; ++i) {
            KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(s.feeds[i]);
            string memory tag = _bond(i).tag;
            (bool priced, int256 answer, uint256 updatedAt) = _navState(feed);
            if (!priced) {
                feed.updateAnswer(NAV_ONE_DOLLAR);
                console.log(string.concat("    NAV ", tag, " first push 100000000 ($1.00)"));
            } else if (block.timestamp >= updatedAt + feed.MIN_UPDATE_INTERVAL()) {
                feed.updateAnswer(answer);
                console.log(string.concat("    NAV ", tag, " refreshed at ", vm.toString(answer)));
            } else {
                console.log(string.concat("    NAV ", tag, " pushed < 1 h ago - skipped (MIN_UPDATE_INTERVAL)"));
            }
        }
        vm.stopBroadcast();
    }

    function _runDeployAtomicSettlement(Actors memory a, Stack memory s) internal {
        _setEnv("USDC_ADDRESS", address(s.usdc));
        _setEnv("EVM_ISSUANCE_MANAGER", address(s.im));
        _setEnv("EVM_FACTORY_ADDRESS", address(s.factory));
        _setEnv("TIMELOCK_ADDRESS", address(s.timelock));
        _setEnv("OPS_MULTISIG", a.addr[OPS]);
        _setEnv("TREASURER_ADDRESS", a.addr[TREASURER]);
        _setEnv("QUOTE_SIGNER", a.addr[QUOTE_SIGNER]);
        _setEnv("ALLOWLIST_ADMIN", a.addr[ALLOWLIST_ADMIN]);
        _setEnv("WITHDRAWAL_WALLET", a.addr[DISTRIBUTION]);
        vm.setEnv(
            "SERIES_TOKENS",
            string.concat(vm.toString(s.tokens[0]), ",", vm.toString(s.tokens[1]), ",", vm.toString(s.tokens[2]))
        );
        vm.setEnv("ALLOWED_TAKERS", ""); // the allowlist admin does it afterwards, as on prod
        vm.setEnv("MAX_QUOTE_DEVIATION_BPS", vm.toString(uint256(MAX_QUOTE_DEVIATION_BPS)));
        vm.setEnv("MAX_NAV_AGE_SECS", vm.toString(uint256(MAX_NAV_AGE_SECS)));

        DeployAtomicSettlement d = new DeployAtomicSettlement();
        d.run();
        s.swap = d.swap();
        require(s.swap.usdc() == address(s.usdc), "KatanaTestnetStack: swap cash leg is not MockUSDC");
    }

    function _wire(Actors memory a, Stack memory s) internal {
        address swap = address(s.swap);
        // DeployAtomicSettlement skips this when the deployer lacks WHITELIST_ADMIN_ROLE —
        // the production shape; the whitelist admin does it.
        if (!s.im.whitelisted(swap)) {
            vm.broadcast(a.pk[WHITELIST_ADMIN]);
            s.im.addToWhitelist(swap);
        }

        vm.startBroadcast(a.pk[SUBSCRIBER]);
        for (uint256 i; i < N_SERIES; ++i) {
            s.im.subscribe(s.tokens[i], swap, INVENTORY_PER_SERIES);
        }
        vm.stopBroadcast();

        vm.startBroadcast(a.pk[DEPLOYER]); // MockUSDC.mint is permissionless; the deployer pays
        s.usdc.mint(swap, SWAP_CASH);
        s.usdc.mint(a.addr[TAKER], TAKER_CASH);
        vm.stopBroadcast();

        vm.broadcast(a.pk[ALLOWLIST_ADMIN]);
        s.swap.setAllowed(a.addr[TAKER], true);
    }

    // ══ Smoke: BUY + REDEEM ═══════════════════════════════════════════════════

    function _smoke(Actors memory a, Stack memory s) internal {
        GyldAtomicSwap swap = s.swap;
        address taker = a.addr[TAKER];
        address token = s.tokens[0]; // CAT
        GyldBondToken cat = GyldBondToken(token);

        (, int256 nav,, uint256 updatedAt,) = NAVFeedForwarder(s.forwarders[0]).latestRoundData();
        require(
            block.timestamp <= updatedAt + swap.maxNavAgeSecsFor(token),
            "KatanaTestnetStack: CAT NAV is older than maxNavAgeSecs - run the `nav` step first"
        );
        require(swap.isAllowed(taker), "KatanaTestnetStack: taker is not allowlisted");

        // Unique per run (never reused across re-runs): the bitmap is global and permanent.
        uint256 qid = block.timestamp * 1000;
        console.log(string.concat("=== Smoke: BUY + REDEEM 10 CAT at NAV ", vm.toString(nav), " (8dp) ==="));

        uint256 takerCash0 = s.usdc.balanceOf(taker);
        uint256 takerCat0 = cat.balanceOf(taker);

        // BUY: USDC in, CAT out. price = CAT raw per 1e18 USDC raw. One USDC raw buys
        // 1e20 / nav CAT raw (band: usdc = cat * nav / 1e20), so price = 1e38 / nav
        // (= 1e30 at $1.00: 10e6 USDC -> 10e18 CAT; AtomicSettlementFlow uses the same).
        GyldAtomicSwap.SwapMessage memory buy =
            _quote(swap, qid + 1, taker, address(s.usdc), SMOKE_CASH, token, 1e38 / uint256(nav));
        bytes memory buySig = _sign(a.pk[QUOTE_SIGNER], swap.hashSwapMessage(buy));
        vm.startBroadcast(a.pk[TAKER]);
        s.usdc.approve(address(swap), SMOKE_CASH);
        swap.executeSwap(buy, buySig, _noPermit(), SMOKE_CASH);
        vm.stopBroadcast();
        uint256 bought = (SMOKE_CASH * buy.price) / 1e18;
        require(cat.balanceOf(taker) == takerCat0 + bought, "smoke BUY: CAT not delivered");
        require(s.usdc.balanceOf(taker) == takerCash0 - SMOKE_CASH, "smoke BUY: USDC not debited");
        require(swap.isQuoteUsed(qid + 1), "smoke BUY: quote not consumed");
        console.log(string.concat("  BUY ok    quoteId ", vm.toString(qid + 1), "  CAT +", vm.toString(bought)));

        // REDEEM: CAT in, USDC out. price = USDC raw per 1e18 CAT raw = 1e18 * nav / 1e20
        // = nav / 100 (= 1e6 at $1.00: 10e18 CAT -> 10e6 USDC).
        GyldAtomicSwap.SwapMessage memory redeem =
            _quote(swap, qid + 2, taker, token, bought, address(s.usdc), uint256(nav) / 100);
        bytes memory redeemSig = _sign(a.pk[QUOTE_SIGNER], swap.hashSwapMessage(redeem));
        vm.startBroadcast(a.pk[TAKER]);
        cat.approve(address(swap), bought);
        swap.executeSwap(redeem, redeemSig, _noPermit(), bought);
        vm.stopBroadcast();
        uint256 redeemed = (bought * redeem.price) / 1e18;
        require(cat.balanceOf(taker) == takerCat0, "smoke REDEEM: CAT not taken back");
        require(s.usdc.balanceOf(taker) == takerCash0 - SMOKE_CASH + redeemed, "smoke REDEEM: USDC not paid out");
        require(swap.isQuoteUsed(qid + 2), "smoke REDEEM: quote not consumed");
        console.log(string.concat("  REDEEM ok quoteId ", vm.toString(qid + 2), "  USDC +", vm.toString(redeemed)));
        console.log("=== SMOKE OK ===");
    }

    function _quote(
        GyldAtomicSwap swap,
        uint256 id,
        address taker,
        address tokenIn,
        uint256 maxAmountIn,
        address tokenOut,
        uint256 price
    ) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId: id,
            taker: taker,
            tokenIn: tokenIn,
            maxAmountIn: maxAmountIn,
            tokenOut: tokenOut,
            price: price,
            expiry: uint64(block.timestamp) + SMOKE_QUOTE_TTL,
            epoch: swap.quoteEpoch()
        });
    }

    // ══ Verify ═══════════════════════════════════════════════════════════════

    function _verify(Actors memory a, Stack memory s) internal {
        address dep = a.addr[DEPLOYER];
        console.log("=== Verification: every role holder read back on-chain ===");
        _check(true, "14 keys pairwise distinct (deployer + 13 derived; asserted at derivation)");

        // Timelock — governance gate.
        TimelockController tl = s.timelock;
        _check(tl.getMinDelay() == 0, "Timelock minDelay == 0 (testnet; mainnet >= 48 h)");
        _check(tl.hasRole(tl.PROPOSER_ROLE(), a.addr[GOVERNANCE]), "Timelock PROPOSER = governance");
        _check(tl.hasRole(tl.CANCELLER_ROLE(), a.addr[GOVERNANCE]), "Timelock CANCELLER = governance");
        _check(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "Timelock EXECUTOR = open (address(0))");
        _check(tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)), "Timelock self-administered");
        _check(
            !tl.hasRole(tl.PROPOSER_ROLE(), dep) && !tl.hasRole(tl.CANCELLER_ROLE(), dep)
                && !tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), dep),
            "deployer holds no timelock role"
        );

        // IssuanceManager.
        IssuanceManager im = s.im;
        _check(im.hasRole(im.DEFAULT_ADMIN_ROLE(), address(tl)), "IssuanceManager DEFAULT_ADMIN = timelock");
        _check(im.hasRole(im.SUBSCRIBER_ROLE(), a.addr[SUBSCRIBER]), "IssuanceManager SUBSCRIBER = subscriber");
        _check(im.hasRole(im.REDEEMER_ROLE(), a.addr[REDEEMER]), "IssuanceManager REDEEMER = redeemer");
        _check(
            im.hasRole(im.WHITELIST_ADMIN_ROLE(), a.addr[WHITELIST_ADMIN]),
            "IssuanceManager WHITELIST_ADMIN = whitelist-admin"
        );
        _check(
            im.hasRole(im.ISSUANCE_PAUSER_ROLE(), a.addr[ISSUANCE_PAUSER]),
            "IssuanceManager ISSUANCE_PAUSER = issuance-pauser (FIND-001)"
        );
        _check(im.hasRole(im.REGISTRAR_ROLE(), address(s.factory)), "IssuanceManager REGISTRAR = TokenFactory");
        _check(
            !im.hasRole(im.DEFAULT_ADMIN_ROLE(), dep) && !im.hasRole(im.SUBSCRIBER_ROLE(), dep)
                && !im.hasRole(im.REDEEMER_ROLE(), dep) && !im.hasRole(im.WHITELIST_ADMIN_ROLE(), dep)
                && !im.hasRole(im.ISSUANCE_PAUSER_ROLE(), dep) && !im.hasRole(im.REGISTRAR_ROLE(), dep),
            "deployer holds no IssuanceManager role"
        );
        _check(im.whitelisted(address(s.swap)), "IssuanceManager whitelisted(swap) - subscribe mints into it");

        // Factory + sanctions.
        _check(
            s.factory.owner() == address(tl) && s.factory.pendingOwner() == address(0),
            "TokenFactory owner = timelock (hand-off accepted)"
        );
        _check(s.factory.sanctionsList() == address(s.sanctions), "TokenFactory sanctionsList = MockSanctionsList");
        _check(s.sanctions.owner() == a.addr[SANCTIONS_ADMIN], "MockSanctionsList owner = sanctions-admin");

        for (uint256 i; i < N_SERIES; ++i) {
            _verifySeries(a, s, i);
        }
        _verifySwap(a, s);

        console.log("=== Balances ===");
        for (uint256 i; i < N_ROLES; ++i) {
            console.log(string.concat("  ", _pad(_role(i).label, 16), " ", _fmtEth(a.addr[i].balance), " ETH"));
        }
        console.log(
            string.concat(
                "  swap inventory  CAT ",
                _fmtUnits(GyldBondToken(s.tokens[0]).balanceOf(address(s.swap))),
                "  C ",
                _fmtUnits(GyldBondToken(s.tokens[1]).balanceOf(address(s.swap))),
                "  KO ",
                _fmtUnits(GyldBondToken(s.tokens[2]).balanceOf(address(s.swap))),
                "  USDC ",
                _fmtFixed(s.usdc.balanceOf(address(s.swap)), CASH_DECIMALS, 2)
            )
        );
        console.log(
            string.concat(
                "  note: DeployDevNet whitelists Anvil account[1] (public key) as an AP on dev chains: ",
                im.whitelisted(DeployGuards.ANVIL_ACCOUNT_1) ? "present" : "absent"
            )
        );
        console.log(string.concat("=== ALL ", vm.toString(_checks), " CHECKS PASSED ==="));
    }

    function _verifySeries(Actors memory a, Stack memory s, uint256 i) internal {
        Bond memory b = _bond(i);
        string memory p = string.concat(b.tag, " ");
        _verifyToken(a, s, GyldBondToken(s.tokens[i]), b.isin, p);
        _verifyFeed(a, s, i, p);
    }

    function _verifyToken(Actors memory a, Stack memory s, GyldBondToken t, string memory isin, string memory p)
        internal
    {
        address ops = a.addr[OPS];
        address dep = a.addr[DEPLOYER];
        address im = address(s.im);
        _check(
            s.factory.tokenByIsin(isin) == address(t) && s.im.registeredTokens(address(t)) && t.decimals() == 18,
            string.concat(p, "token: factory ISIN registry + IssuanceManager registered + 18dp")
        );
        _check(
            t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(s.timelock)), string.concat(p, "token DEFAULT_ADMIN = timelock")
        );
        _check(
            t.hasRole(t.MINTER_ROLE(), im) && t.hasRole(t.BURNER_ROLE(), im),
            string.concat(p, "token MINTER + BURNER = IssuanceManager")
        );
        _check(
            t.hasRole(t.PAUSER_ROLE(), ops) && t.hasRole(t.DOCUMENT_ROLE(), ops),
            string.concat(p, "token PAUSER + DOCUMENT = ops")
        );
        _check(
            !t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(s.factory)) && !t.hasRole(t.PAUSER_ROLE(), address(s.factory))
                && !t.hasRole(t.DEFAULT_ADMIN_ROLE(), dep) && !t.hasRole(t.PAUSER_ROLE(), dep)
                && !t.hasRole(t.MINTER_ROLE(), dep),
            string.concat(p, "token: factory shed its roles, deployer holds none")
        );
    }

    function _verifyFeed(Actors memory a, Stack memory s, uint256 i, string memory p) internal {
        KaleidoscopeNAVFeed f = KaleidoscopeNAVFeed(s.feeds[i]);
        NAVFeedForwarder fw = NAVFeedForwarder(s.forwarders[i]);
        address tl = address(s.timelock);
        _check(
            f.owner() == a.addr[NAV_OWNER] && f.pendingOwner() == address(0),
            string.concat(p, "NAV feed owner = nav-feed-owner")
        );
        _check(
            f.emergencyUpdater() == a.addr[OPS],
            string.concat(p, "NAV feed emergencyUpdater (guardian) = ops (FIND-003)")
        );
        _check(f.rangeGovernor() == tl, string.concat(p, "NAV feed rangeGovernor = timelock"));
        _check(
            f.minAnswer() == FEED_MIN_ANSWER && f.maxAnswer() == FEED_MAX_ANSWER,
            string.concat(p, "NAV feed range 1e7..2e8 ($0.10-$2.00)")
        );
        _check(
            f.ABSOLUTE_MIN_ANSWER() == FEED_ABS_MIN && f.ABSOLUTE_MAX_ANSWER() == FEED_ABS_MAX,
            string.concat(p, "NAV feed absolute bounds 1e7..5e8 ($0.10-$5.00)")
        );
        (, int256 answer,, uint256 updatedAt,) = fw.latestRoundData();
        string memory got = string.concat(vm.toString(answer), " (8dp), age ", vm.toString(block.timestamp - updatedAt));
        _check(
            answer >= int256(FEED_MIN_ANSWER) && answer <= int256(FEED_MAX_ANSWER) && updatedAt != 0,
            string.concat(p, "NAV answer ", got, " s")
        );
        _check(
            fw.owner() == tl && fw.upstreamOracle() == address(f),
            string.concat(p, "forwarder owner = timelock, upstream = feed")
        );
        _check(
            s.swap.registeredSeries(s.tokens[i]) && s.swap.navForwarderOf(s.tokens[i]) == address(fw),
            string.concat(p, "swap series registered against this forwarder")
        );
    }

    function _verifySwap(Actors memory a, Stack memory s) internal {
        GyldAtomicSwap w = s.swap;
        address dep = a.addr[DEPLOYER];
        _check(w.hasRole(w.DEFAULT_ADMIN_ROLE(), address(s.timelock)), "swap DEFAULT_ADMIN = timelock");
        _check(w.hasRole(w.PAUSER_ROLE(), a.addr[OPS]), "swap PAUSER = ops");
        _check(w.hasRole(w.QUOTE_SIGNER_ROLE(), a.addr[QUOTE_SIGNER]), "swap QUOTE_SIGNER = quote-signer");
        _check(w.hasRole(w.TREASURER_ROLE(), a.addr[TREASURER]), "swap TREASURER = treasurer");
        _check(w.hasRole(w.ALLOWLIST_ADMIN_ROLE(), a.addr[ALLOWLIST_ADMIN]), "swap ALLOWLIST_ADMIN = allowlist-admin");
        _check(
            !w.hasRole(w.DEFAULT_ADMIN_ROLE(), dep) && !w.hasRole(w.PAUSER_ROLE(), dep)
                && !w.hasRole(w.QUOTE_SIGNER_ROLE(), dep) && !w.hasRole(w.TREASURER_ROLE(), dep)
                && !w.hasRole(w.ALLOWLIST_ADMIN_ROLE(), dep),
            "deployer holds no swap role"
        );
        _check(w.withdrawalWallet() == a.addr[DISTRIBUTION], "swap withdrawalWallet = distribution");
        _check(w.usdc() == address(s.usdc), "swap cash token = MockUSDC");
        _check(s.usdc.decimals() == CASH_DECIMALS, "swap cash token decimals() == 6 (initialize F-1 probe)");
        _check(
            w.maxQuoteDeviationBps() == MAX_QUOTE_DEVIATION_BPS && w.maxNavAgeSecs() == MAX_NAV_AGE_SECS,
            "swap band 200 bps, max NAV age 86400 s"
        );
        _check(w.isAllowed(a.addr[TAKER]) && !w.paused(), "swap allowlists the smoke taker and is unpaused");
    }

    function _check(bool ok, string memory what) internal {
        require(ok, string.concat("VERIFY FAILED: ", what));
        ++_checks;
        console.log(string.concat("  [ok] ", what));
    }

    // ══ Stack I/O ════════════════════════════════════════════════════════════

    /// Everything is derived on-chain from the factory and the swap, so the addresses
    /// file only has to supply two values and cannot silently drift from the chain.
    function _loadStack() internal view returns (Stack memory s) {
        s.factory = TokenFactory(vm.envAddress("EVM_FACTORY_ADDRESS"));
        s.swap = GyldAtomicSwap(vm.envAddress("EVM_ATOMIC_SWAP_ADDRESS"));
        require(address(s.factory).code.length != 0, "KatanaTestnetStack: EVM_FACTORY_ADDRESS has no code");
        require(address(s.swap).code.length != 0, "KatanaTestnetStack: EVM_ATOMIC_SWAP_ADDRESS has no code");
        s.timelock = TimelockController(payable(s.factory.owner()));
        for (uint256 i; i < N_SERIES; ++i) {
            string memory isin = _bond(i).isin;
            s.tokens[i] = s.factory.tokenByIsin(isin);
            require(s.tokens[i] != address(0), string.concat("KatanaTestnetStack: no token for ISIN ", isin));
            s.feeds[i] = s.factory.navFeedOf(s.tokens[i]);
            s.forwarders[i] = s.factory.forwarderOf(s.tokens[i]);
        }
        s.im = IssuanceManager(s.factory.issuanceManagerOf(s.tokens[0]));
        s.sanctions = MockSanctionsList(s.factory.sanctionsList());
        s.usdc = MockUSDC(s.swap.usdc());
    }

    function _printAddresses(Actors memory a, Stack memory s) internal pure {
        console.log("=== Addresses (no secrets) ===");
        _kv("EVM_CHAIN_ID", vm.toString(KATANA_BOKUTO));
        _kv("DEPLOYER_ADDRESS", vm.toString(a.addr[DEPLOYER]));
        _kv("TIMELOCK_ADDRESS", vm.toString(address(s.timelock)));
        _kv("EVM_ISSUANCE_MANAGER", vm.toString(address(s.im)));
        _kv("EVM_FACTORY_ADDRESS", vm.toString(address(s.factory)));
        _kv("EVM_ATOMIC_SWAP_ADDRESS", vm.toString(address(s.swap)));
        _kv("USDC_ADDRESS", vm.toString(address(s.usdc)));
        _kv("USDC_CONTRACT_ADDRESS", vm.toString(address(s.usdc)));
        _kv("MOCK_SANCTIONS_ADDRESS", vm.toString(address(s.sanctions)));
        _kv("CHAINALYSIS_SANCTIONS_CONTRACT", vm.toString(address(s.sanctions)));
        for (uint256 i; i < N_SERIES; ++i) {
            string memory tag = _bond(i).tag;
            _kv(string.concat("TOKEN_", tag), vm.toString(s.tokens[i]));
            _kv(string.concat("NAVFEED_", tag), vm.toString(s.feeds[i]));
            _kv(string.concat("FORWARDER_", tag), vm.toString(s.forwarders[i]));
        }
        for (uint256 i = 1; i < N_ROLES; ++i) {
            _kv(_role(i).addrEnv, vm.toString(a.addr[i]));
        }
        _kv("SWAP_DISTRIBUTION_WALLET", vm.toString(a.addr[DISTRIBUTION]));
    }

    function _kv(string memory k, string memory v) internal pure {
        console.log(string.concat("@@ ", k, "=", v));
    }

    // ══ Keys ═════════════════════════════════════════════════════════════════

    function _actors() internal view returns (Actors memory a) {
        uint256 root = vm.envUint("KATANA_TESTNET_PK");
        require(root != 0 && root < SECP256K1_N, "KatanaTestnetStack: KATANA_TESTNET_PK is not a valid private key");
        a.pk[DEPLOYER] = root;
        for (uint256 i = 1; i < N_ROLES; ++i) {
            string memory label = _role(i).label;
            a.pk[i] = uint256(keccak256(abi.encodePacked(root, LABEL_PREFIX, label))) % (SECP256K1_N - 1) + 1;
        }
        for (uint256 i; i < N_ROLES; ++i) {
            a.addr[i] = vm.addr(a.pk[i]);
        }
        // Mainnet's requireDistinct guards are no-ops on a dev chain; hold this stack to a
        // stricter rule than they do — every holder distinct from every other.
        for (uint256 i; i < N_ROLES; ++i) {
            for (uint256 j = i + 1; j < N_ROLES; ++j) {
                require(a.addr[i] != a.addr[j], "KatanaTestnetStack: two roles derived the same address");
            }
        }
    }

    /// label (derivation + display) · address env var · key env var · ETH gas float.
    /// Floats are top-up targets: a re-run only sends the difference. Katana gas is
    /// ~0.002 gwei L2 + a small L1 data fee, so these are generous.
    function _role(uint256 i) internal pure returns (RoleInfo memory) {
        if (i == DEPLOYER) return RoleInfo("deployer", "DEPLOYER_ADDRESS", "KATANA_TESTNET_PK", 0);
        if (i == GOVERNANCE) return RoleInfo("governance", "GOVERNANCE_MULTISIG", "GOVERNANCE_PK", 0.002 ether);
        if (i == OPS) return RoleInfo("ops", "OPS_MULTISIG", "OPS_PK", 0.0005 ether);
        if (i == NAV_OWNER) return RoleInfo("nav-feed-owner", "NAV_FEED_OWNER", "NAV_FEED_OWNER_PK", 0.001 ether);
        if (i == SUBSCRIBER) return RoleInfo("subscriber", "SUBSCRIBER_ADDRESS", "SUBSCRIBER_PK", 0.001 ether);
        if (i == REDEEMER) return RoleInfo("redeemer", "REDEEMER_ADDRESS", "REDEEMER_PK", 0.0005 ether);
        if (i == WHITELIST_ADMIN) {
            return RoleInfo("whitelist-admin", "WHITELIST_ADMIN", "WHITELIST_ADMIN_PK", 0.0005 ether);
        }
        if (i == ISSUANCE_PAUSER) {
            return RoleInfo("issuance-pauser", "ISSUANCE_PAUSER", "ISSUANCE_PAUSER_PK", 0.0005 ether);
        }
        if (i == QUOTE_SIGNER) return RoleInfo("quote-signer", "QUOTE_SIGNER", "QUOTE_SIGNER_PK", 0); // off-chain only
        if (i == TREASURER) return RoleInfo("treasurer", "TREASURER_ADDRESS", "TREASURER_PK", 0.0005 ether);
        if (i == ALLOWLIST_ADMIN) {
            return RoleInfo("allowlist-admin", "ALLOWLIST_ADMIN", "ALLOWLIST_ADMIN_PK", 0.0005 ether);
        }
        if (i == DISTRIBUTION) return RoleInfo("distribution", "WITHDRAWAL_WALLET", "DISTRIBUTION_PK", 0.0005 ether);
        if (i == SANCTIONS_ADMIN) {
            return RoleInfo("sanctions-admin", "MOCK_SANCTIONS_OWNER", "SANCTIONS_ADMIN_PK", 0.0005 ether);
        }
        return RoleInfo("taker", "SMOKE_TAKER", "TAKER_PK", 0.001 ether);
    }

    function _fundTotal() internal pure returns (uint256 total) {
        for (uint256 i = 1; i < N_ROLES; ++i) {
            total += _role(i).gasFloat;
        }
    }

    // ══ Series (identical to DeployDevNet._deployBondTokens) ═══════════════════

    function _bond(uint256 i) internal pure returns (Bond memory) {
        if (i == 0) {
            return
                Bond(
                    "Caterpillar Inc 3.7% 2028",
                    "14913UBF6",
                    "US14913UBF66",
                    1_851_811_200,
                    bytes32("deploy_cat"),
                    "CAT"
                );
        }
        if (i == 1) {
            return
                Bond("Citigroup Inc 3.887% 2028", "172967LD1", "US172967LD18", 1_831_075_200, bytes32("deploy_c"), "C");
        }
        return Bond("Coca-Cola Co 2.25% 2032", "191216DP2", "US191216DP21", 1_977_609_600, bytes32("deploy_ko"), "KO");
    }

    // ══ Helpers ══════════════════════════════════════════════════════════════

    function _requireChain() internal view {
        require(block.chainid == KATANA_BOKUTO, "KatanaTestnetStack: Katana Bokuto testnet (chainId 737373) only");
    }

    function _navState(KaleidoscopeNAVFeed feed) internal view returns (bool priced, int256 answer, uint256 updatedAt) {
        try feed.latestRoundData() returns (uint80, int256 a_, uint256, uint256 u_, uint80) {
            return (true, a_, u_);
        } catch {
            return (false, 0, 0);
        }
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(pk, digest);
        return abi.encodePacked(r, s_, v);
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    function _setEnv(string memory key, address value) internal {
        vm.setEnv(key, vm.toString(value));
    }

    function _pad(string memory str, uint256 width) internal pure returns (string memory) {
        bytes memory b = bytes(str);
        if (b.length >= width) return str;
        bytes memory out = new bytes(width);
        for (uint256 i; i < width; ++i) {
            out[i] = i < b.length ? b[i] : bytes1(" ");
        }
        return string(out);
    }

    /// wei → "0.001234" (6 decimals, truncated).
    function _fmtEth(uint256 weiAmount) internal pure returns (string memory) {
        return _fmtFixed(weiAmount, 18, 6);
    }

    /// 18dp token units → whole units with 2 decimals.
    function _fmtUnits(uint256 raw) internal pure returns (string memory) {
        return _fmtFixed(raw, 18, 2);
    }

    function _fmtFixed(uint256 raw, uint256 decimals, uint256 shown) internal pure returns (string memory) {
        uint256 whole = raw / 10 ** decimals;
        uint256 frac = (raw % 10 ** decimals) / 10 ** (decimals - shown);
        bytes memory f = bytes(vm.toString(frac));
        bytes memory padded = new bytes(shown);
        for (uint256 i; i < shown; ++i) {
            padded[i] = i < shown - f.length ? bytes1("0") : f[i - (shown - f.length)];
        }
        return string.concat(vm.toString(whole), ".", string(padded));
    }
}
