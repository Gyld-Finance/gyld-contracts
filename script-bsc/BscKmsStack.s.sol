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
import {SanctionsOracleMirror} from "../contracts/SanctionsOracleMirror.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ISanctionsList} from "../contracts/interfaces/ISanctionsList.sol";

/// @title BscKmsStack
/// @notice Fresh BSC testnet (97) stack, every role its own AWS KMS key, production guards on
///         (97 is not a dev chain; timelock floor 5 min). GLD-807. Runbook:
///         docs/deploy/bsc-testnet.md; rehearsal: script-bsc/simulate-kms-stack.sh.
///
///   runA()   --sender KMS_DEPLOYER   deployer + sanctions owner: SanctionsOracleMirror seeded
///                                    with a live SDN probe, then DeployDevNet (delay 300 s)
///   runB()   --sender KMS_GOVERNANCE schedules ONE batch: factory accept + CAT/C/KO deployToken
///   runC()   --sender KMS_DEPLOYER   after the delay: governance executes, NAV owner pushes,
///                                    DeployAtomicSettlement (USDT), swap whitelisted. No
///                                    inventory: the platform's fund-inventory route mints it.
///                                    Every step skips what is done: re-run to finish a partial C
///   verify() any sender              reads every role holder back; reverts on drift
///
/// Env: script-bsc/kms-roles.bsc-testnet.env (KMS_*), KMS_GOVERNANCE_SIG (from
/// check-kms-addresses.sh), SANCTIONS_PROBE_FLAGGED, NAV_ANSWER_8DP, DEPLOY_SALT_TAG; then EVM_FACTORY_ADDRESS + EVM_ISSUANCE_MANAGER (printed by runA) and
/// EVM_ATOMIC_SWAP_ADDRESS (printed by runC). The same stack on Fordefi vaults: BscFordefiStack.
///
/// 97 uses the constants below. 56 (BscFordefiStack only) reads them from env, fail closed:
/// CASH_TOKEN, TIMELOCK_DELAY_SECONDS (48 h..7 d), SANCTIONS_FORWARDING_ORACLE, a
/// SANCTIONS_PROBE_FLAGGED it flags, NAV_ANSWER_8DP_<TAG>, BOND_<i>_* (see _envBond).
contract BscKmsStack is Script {
    uint256 internal constant BSC_TESTNET = 97;
    uint256 internal constant BSC_MAINNET = 56;
    uint256 internal constant TIMELOCK_DELAY = 5 minutes;
    /// 56: sanity cap on TIMELOCK_DELAY_SECONDS (a typo such as 1728000 would freeze governance).
    uint256 internal constant MAX_TIMELOCK_DELAY = 7 days;
    /// Real BSC testnet USDT, 18 decimals.
    address internal constant USDT = 0x337610d27c682E347C9cD60BD4b3b107C9d34dDd;
    /// BSC mainnet cash legs, both 18 decimals; CASH_TOKEN must name one of them.
    address internal constant USDT_BSC = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDC_BSC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    uint8 internal constant CASH_DECIMALS = 18;
    uint256 internal constant MAX_QUOTE_DEVIATION_BPS = 200;
    uint256 internal constant MAX_NAV_AGE_SECS = 86_400;
    bytes32 internal constant PHASE2_SALT = keccak256("GLD-807.phase2");
    uint256 internal constant N_SERIES = 3;
    /// Step 0's proof that KMS_GOVERNANCE is a key we control (same tag as the rotation, PR #25).
    bytes32 internal constant PROOF_TAG = keccak256("GLD-807.kms-governance-proof");

    error GovernanceProofInvalid(address recovered);

    struct Roles {
        address deployer;
        address governance;
        address ops;
        address navOwner;
        address subscriber;
        address redeemer;
        address whitelistAdmin;
        address issuancePauser;
        address quoteSigner;
        address treasurer;
        address allowlistAdmin;
        address withdrawalWallet;
        address sanctionsOwner;
        address userWithdrawal;
        address swapPauser; // swap PAUSER_ROLE: ops in this layout, the Swap Pause vault in BscFordefiStack
    }

    struct Bond {
        string name;
        string cusip;
        string isin;
        uint256 maturity;
        string tag; // gateway env suffix: TOKEN_<tag>, NAVFEED_<tag>, FORWARDER_<tag>
    }

    uint256 internal _checks;

    // ══ Run A — deployer + sanctions owner ═══════════════════════════════════

    function runA() external {
        Roles memory r = _roles();
        _requireSender(r.deployer);
        _requireGovernanceProof(r);
        _deployMirror(r);
        _seedMirror(r);
        _deployDevNet(r);
    }

    /// The mirror's CREATE2 deploy, as the deployer.
    function _deployMirror(Roles memory r) internal {
        vm.broadcast(r.deployer);
        new SanctionsOracleMirror{salt: DeployGuards.vacantSalt("BscKmsStack:SanctionsOracleMirror", _mirrorInit(r))}(
            r.governance, r.sanctionsOwner, _forwardingOracle()
        );
    }

    /// The sanctions owner seeds the live SDN probe (DeployDevNet refuses an oracle that does
    /// not flag it).
    function _seedMirror(Roles memory r) internal {
        SanctionsOracleMirror mirror = _mirror(r);
        address[] memory seed = new address[](1);
        seed[0] = _probe();
        if (mirror.isSanctioned(seed[0])) return;
        vm.broadcast(r.sanctionsOwner);
        mirror.addToSanctionsList(seed);
    }

    /// DeployDevNet (delay 300 s) as --sender (the deployer); stops with the factory hand-off pending.
    function _deployDevNet(Roles memory r) internal {
        address mirror = address(_mirror(r));
        _setEnv("GOVERNANCE_MULTISIG", r.governance);
        _setEnv("OPS_MULTISIG", r.ops);
        _setEnv("SUBSCRIBER_ADDRESS", r.subscriber);
        _setEnv("REDEEMER_ADDRESS", r.redeemer);
        _setEnv("WHITELIST_ADMIN", r.whitelistAdmin);
        _setEnv("ISSUANCE_PAUSER", r.issuancePauser);
        _setEnv("NAV_FEED_OWNER", r.navOwner);
        _setEnv("SANCTIONS_LIST", mirror);
        _setEnv("SANCTIONS_PROBE_FLAGGED", _probe());
        vm.setEnv("TIMELOCK_DELAY_SECONDS", vm.toString(_timelockDelay()));
        DeployDevNet d = new DeployDevNet();
        d.run();

        console.log("=== run A done: export these for runs B and C ===");
        _kv("SANCTIONS_ORACLE_MIRROR", mirror);
        _kv("TIMELOCK_ADDRESS", address(d.timelock()));
        _kv("EVM_FACTORY_ADDRESS", address(d.factory()));
        _kv("EVM_ISSUANCE_MANAGER", address(d.issuanceMgr()));
    }

    function _mirrorInit(Roles memory r) internal view returns (bytes memory) {
        return abi.encodePacked(
            type(SanctionsOracleMirror).creationCode, abi.encode(r.governance, r.sanctionsOwner, _forwardingOracle())
        );
    }

    /// The mirror _deployMirror lands at (CREATE2: salt tag + roles).
    function _mirror(Roles memory r) internal view returns (SanctionsOracleMirror m) {
        m = SanctionsOracleMirror(
            DeployGuards.predictCreate2(
                DeployGuards.saltFor("BscKmsStack:SanctionsOracleMirror"), keccak256(_mirrorInit(r))
            )
        );
        require(address(m).code.length != 0, "BscKmsStack: SanctionsOracleMirror not deployed");
    }

    // ══ Run B — governance schedules Phase 2 ═════════════════════════════════

    function runB() external {
        Roles memory r = _roles();
        _requireSender(r.governance);
        TokenFactory f = _factory();
        TimelockController tl = TimelockController(payable(f.pendingOwner()));
        require(address(tl) != address(0), "BscKmsStack: factory has no pending owner (run A missing or B done)");
        for (uint256 i; i < N_SERIES; ++i) {
            DeployGuards.requireValidIsin(_bond(i).isin);
            DeployGuards.requireIsinVacant(address(f), _bond(i).isin);
            for (uint256 j = i + 1; _isMainnet() && j < N_SERIES; ++j) { // 56: env bonds, a duplicate reverts only at execute
                require(
                    keccak256(bytes(_bond(i).isin)) != keccak256(bytes(_bond(j).isin))
                        && keccak256(bytes(_bond(i).tag)) != keccak256(bytes(_bond(j).tag)),
                    "BscKmsStack: two bonds share an ISIN or tag"
                );
            }
        }
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase2(f, r);
        uint256 delay = tl.getMinDelay();
        vm.broadcast(r.governance);
        tl.scheduleBatch(targets, values, payloads, bytes32(0), PHASE2_SALT, delay);
        console.log("Phase 2 scheduled; executable after %d s", delay);
    }

    // ══ Run C — execute, NAV, swap, inventory ════════════════════════════════

    function runC() external {
        Roles memory r = _roles();
        _requireSender(r.deployer);
        _executePhase2(r, r.governance);
        _pushNav(r);
        _deploySwap(r);
        _whitelistSwap(r);
    }

    /// `executor` runs the scheduled Phase 2 batch (executors are open: any account may).
    function _executePhase2(Roles memory r, address executor) internal {
        TokenFactory f = _factory();
        address pending = f.pendingOwner(); // zero once Phase 2 has executed
        TimelockController tl = TimelockController(payable(pending != address(0) ? pending : f.owner()));
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase2(f, r);
        bytes32 id = tl.hashOperationBatch(targets, values, payloads, bytes32(0), PHASE2_SALT);
        if (tl.isOperationDone(id)) return;
        if (!tl.isOperationReady(id)) {
            uint256 at = tl.getTimestamp(id);
            require(at != 0, "BscKmsStack: Phase 2 is not scheduled (run B)");
            revert(string.concat("BscKmsStack: Phase 2 executable in ", vm.toString(at - block.timestamp), " s"));
        }
        vm.broadcast(executor);
        tl.executeBatch(targets, values, payloads, bytes32(0), PHASE2_SALT);
    }

    /// First NAV push per series: registerSeries refuses an unpriced feed.
    function _pushNav(Roles memory r) internal {
        TokenFactory f = _factory();
        address[N_SERIES] memory tokens = _tokens(f);
        vm.startBroadcast(r.navOwner);
        for (uint256 i; i < N_SERIES; ++i) {
            KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(f.navFeedOf(tokens[i]));
            if (!_priced(feed)) feed.updateAnswer(_nav(i));
        }
        vm.stopBroadcast();
    }

    /// DeployAtomicSettlement (USDT, no takers, admin -> timelock) as --sender (the deployer).
    function _deploySwap(Roles memory r) internal {
        TokenFactory f = _factory();
        address[N_SERIES] memory tokens = _tokens(f);
        (address impl, address swap) = _predictSwap(r);
        if (swap.code.length != 0) return;
        // DeployAtomicSettlement's vacantSalt would revert on the impl forever: say why.
        _requireSwapStep(impl.code.length == 0, "proxy deploy (impl is on chain, the proxy is not)");
        string memory series;
        for (uint256 i; i < N_SERIES; ++i) {
            series = string.concat(series, i == 0 ? "" : ",", vm.toString(tokens[i]));
        }
        _setEnv("USDC_ADDRESS", _cash());
        _setEnv("EVM_ISSUANCE_MANAGER", vm.envAddress("EVM_ISSUANCE_MANAGER"));
        _setEnv("EVM_FACTORY_ADDRESS", address(f));
        _setEnv("TIMELOCK_ADDRESS", f.owner());
        _setEnv("OPS_MULTISIG", r.swapPauser); // DeployAtomicSettlement: swap PAUSER
        _setEnv("TREASURER_ADDRESS", r.treasurer);
        _setEnv("QUOTE_SIGNER", r.quoteSigner);
        _setEnv("ALLOWLIST_ADMIN", r.allowlistAdmin);
        _setEnv("WITHDRAWAL_WALLET", r.withdrawalWallet);
        vm.setEnv("SERIES_TOKENS", series);
        vm.setEnv("ALLOWED_TAKERS", "");
        vm.setEnv("MAX_QUOTE_DEVIATION_BPS", vm.toString(MAX_QUOTE_DEVIATION_BPS));
        vm.setEnv("MAX_NAV_AGE_SECS", vm.toString(MAX_NAV_AGE_SECS));
        DeployAtomicSettlement d = new DeployAtomicSettlement();
        d.run(); // broadcasts as --sender (the deployer); admin ends at the timelock
        require(address(d.swap()) == swap, "BscKmsStack: swap landed off its predicted address");
    }

    /// Whitelist admin whitelists the swap so it can receive inventory; prints run C's addresses.
    /// GLD-1054: the script mints NO inventory. A mint outside the platform never reaches its
    /// ledger, and supply reconciliation then halts every series. Inventory is funded through
    /// the platform's POST /admin/swap/fund-inventory?chain=<chain>, which mints and records it.
    function _whitelistSwap(Roles memory r) internal {
        TokenFactory f = _factory();
        IssuanceManager im = IssuanceManager(vm.envAddress("EVM_ISSUANCE_MANAGER"));
        address[N_SERIES] memory tokens = _tokens(f);
        (, address swap) = _predictSwap(r);
        // Fail closed before the swap is whitelisted: a swap deploy that stopped midway may still
        // be administered by the deployer.
        _requireSwapComplete(r, GyldAtomicSwap(swap), tokens, f.owner());

        if (!im.whitelisted(swap)) {
            vm.broadcast(r.whitelistAdmin); // the deployer holds no WHITELIST_ADMIN_ROLE
            im.addToWhitelist(swap);
        }

        console.log("=== run C done ===");
        _kv("EVM_ATOMIC_SWAP_ADDRESS", swap);
        for (uint256 i; i < N_SERIES; ++i) {
            _kv(string.concat("TOKEN_", _bond(i).tag), tokens[i]);
            _kv(string.concat("NAVFEED_", _bond(i).tag), f.navFeedOf(tokens[i]));
            _kv(string.concat("FORWARDER_", _bond(i).tag), f.forwarderOf(tokens[i]));
        }
    }

    function _tokens(TokenFactory f) internal view returns (address[N_SERIES] memory tokens) {
        for (uint256 i; i < N_SERIES; ++i) {
            tokens[i] = f.tokenByIsin(_bond(i).isin);
        }
    }

    // ══ Verify ═══════════════════════════════════════════════════════════════

    function verify() external {
        Roles memory r = _roles();
        TokenFactory f = _factory();
        IssuanceManager im = IssuanceManager(vm.envAddress("EVM_ISSUANCE_MANAGER"));
        GyldAtomicSwap w = GyldAtomicSwap(vm.envAddress("EVM_ATOMIC_SWAP_ADDRESS"));
        TimelockController tl = TimelockController(payable(f.owner()));
        address dep = r.deployer;

        _check(
            tl.getMinDelay() == _timelockDelay(),
            string.concat("timelock minDelay == ", vm.toString(_timelockDelay()), " s")
        );
        _check(
            tl.hasRole(tl.PROPOSER_ROLE(), r.governance) && tl.hasRole(tl.CANCELLER_ROLE(), r.governance),
            "timelock PROPOSER + CANCELLER = governance"
        );
        _check(tl.hasRole(tl.EXECUTOR_ROLE(), address(0)), "timelock executors open");
        _check(
            tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), address(tl)) && !tl.hasRole(tl.PROPOSER_ROLE(), dep)
                && !tl.hasRole(tl.CANCELLER_ROLE(), dep) && !tl.hasRole(tl.DEFAULT_ADMIN_ROLE(), dep),
            "timelock self-administered; deployer holds no timelock role"
        );
        _check(f.owner() == address(tl) && f.pendingOwner() == address(0), "factory owner = timelock, none pending");

        SanctionsOracleMirror m = SanctionsOracleMirror(f.sanctionsList());
        _check(
            m.hasRole(m.DEFAULT_ADMIN_ROLE(), r.governance) && m.hasRole(m.SANCTIONS_UPDATER_ROLE(), r.sanctionsOwner)
                && address(m.forwardingOracle()) == _forwardingOracle(),
            "sanctionsList = SanctionsOracleMirror (admin governance, updater sanctions owner, forwarding as configured)"
        );
        _check(
            m.isSanctioned(_probe()) && !m.isSanctioned(dep)
                && !m.hasRole(m.DEFAULT_ADMIN_ROLE(), dep) && !m.hasRole(m.SANCTIONS_UPDATER_ROLE(), dep),
            "mirror flags the SDN probe, not the deployer; deployer holds no mirror role"
        );

        _check(
            im.hasRole(im.DEFAULT_ADMIN_ROLE(), address(tl)) && im.hasRole(im.REGISTRAR_ROLE(), address(f))
                && im.hasRole(im.SUBSCRIBER_ROLE(), r.subscriber) && im.hasRole(im.REDEEMER_ROLE(), r.redeemer)
                && im.hasRole(im.WHITELIST_ADMIN_ROLE(), r.whitelistAdmin)
                && im.hasRole(im.ISSUANCE_PAUSER_ROLE(), r.issuancePauser),
            "IssuanceManager: admin timelock, registrar factory, subscriber/redeemer/whitelist/pauser"
        );
        _check(
            !im.hasRole(im.DEFAULT_ADMIN_ROLE(), dep) && !im.hasRole(im.SUBSCRIBER_ROLE(), dep)
                && !im.hasRole(im.REDEEMER_ROLE(), dep) && !im.hasRole(im.WHITELIST_ADMIN_ROLE(), dep)
                && !im.hasRole(im.ISSUANCE_PAUSER_ROLE(), dep) && !im.hasRole(im.REGISTRAR_ROLE(), dep),
            "deployer holds no IssuanceManager role"
        );
        _check(im.whitelisted(address(w)), "swap whitelisted on IssuanceManager");

        _check(
            w.hasRole(w.DEFAULT_ADMIN_ROLE(), address(tl)) && w.hasRole(w.PAUSER_ROLE(), r.swapPauser)
                && w.hasRole(w.QUOTE_SIGNER_ROLE(), r.quoteSigner) && w.hasRole(w.TREASURER_ROLE(), r.treasurer)
                && w.hasRole(w.ALLOWLIST_ADMIN_ROLE(), r.allowlistAdmin) && w.withdrawalWallet() == r.withdrawalWallet,
            "swap: admin timelock, swap pauser/quote signer/treasurer/allowlist admin/withdrawal wallet"
        );
        _check(
            !w.hasRole(w.DEFAULT_ADMIN_ROLE(), dep) && !w.hasRole(w.PAUSER_ROLE(), dep)
                && !w.hasRole(w.QUOTE_SIGNER_ROLE(), dep) && !w.hasRole(w.TREASURER_ROLE(), dep)
                && !w.hasRole(w.ALLOWLIST_ADMIN_ROLE(), dep),
            "deployer holds no swap role"
        );
        _check(
            w.usdc() == _cash() && w.cashDecimals() == CASH_DECIMALS && !w.paused(),
            "swap cash = configured cash token, 18dp, unpaused"
        );

        for (uint256 i; i < N_SERIES; ++i) {
            _verifySeries(r, f, im, w, address(tl), i);
        }
        console.log("=== ALL %d CHECKS PASSED ===", _checks);
    }

    function _verifySeries(Roles memory r, TokenFactory f, IssuanceManager im, GyldAtomicSwap w, address tl, uint256 i)
        internal
    {
        Bond memory b = _bond(i);
        string memory p = string.concat(b.tag, ": ");
        GyldBondToken t = GyldBondToken(f.tokenByIsin(b.isin));
        KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(f.navFeedOf(address(t)));
        NAVFeedForwarder fw = NAVFeedForwarder(f.forwarderOf(address(t)));
        address dep = r.deployer;
        _check(
            address(t) != address(0) && im.registeredTokens(address(t)) && t.hasRole(t.DEFAULT_ADMIN_ROLE(), tl)
                && t.hasRole(t.MINTER_ROLE(), address(im)) && t.hasRole(t.PAUSER_ROLE(), r.ops)
                && t.hasRole(t.DOCUMENT_ROLE(), r.ops) && !t.hasRole(t.DEFAULT_ADMIN_ROLE(), dep)
                && !t.hasRole(t.PAUSER_ROLE(), dep) && !t.hasRole(t.MINTER_ROLE(), dep)
                && !t.hasRole(t.DOCUMENT_ROLE(), dep),
            string.concat(p, "token admin timelock, minter IssuanceManager, pauser + document ops, deployer none")
        );
        if (_isMainnet()) _check(
            keccak256(bytes(t.name())) == keccak256(bytes(b.name)) && keccak256(bytes(t.symbol())) == keccak256(bytes(b.cusip))
                && keccak256(bytes(t.isin())) == keccak256(bytes(b.isin)) && t.maturityTimestamp() == b.maturity,
            string.concat(p, "token \"", b.name, "\" / ", b.cusip, " / ", b.isin, " / maturity ", vm.toString(b.maturity))
        );
        _check(
            feed.owner() == r.navOwner && feed.pendingOwner() == address(0) && feed.emergencyUpdater() == r.ops
                && feed.rangeGovernor() == tl && fw.owner() == tl && fw.upstreamOracle() == address(feed),
            string.concat(p, "feed owner NAV owner, guardian ops, range governor + forwarder owner timelock")
        );
        (, int256 answer,, uint256 updatedAt,) = fw.latestRoundData();
        if (_isMainnet()) {
            (, int256 feedAnswer,,,) = feed.latestRoundData();
            _check(
                answer == _nav(i) && feedAnswer == answer,
                string.concat(p, "NAV feed + forwarder answer == configured first NAV ", vm.toString(_nav(i)))
            );
        }
        _check(
            updatedAt != 0 && answer >= int256(uint256(feed.minAnswer()))
                && answer <= int256(uint256(feed.maxAnswer())),
            string.concat(
                p,
                "NAV ",
                vm.toString(answer),
                " in feed range ",
                vm.toString(uint256(feed.minAnswer())),
                "..",
                vm.toString(uint256(feed.maxAnswer()))
            )
        );
        _check(
            w.registeredSeries(address(t)) && w.navForwarderOf(address(t)) == address(fw),
            string.concat(p, "registered on the swap")
        );
    }

    // ══ Helpers ══════════════════════════════════════════════════════════════

    /// Phase 2 as one timelock batch: accept the factory, then deploy CAT / C / KO exactly as
    /// DeployDevNet._deployBondTokens does on a dev chain.
    function _phase2(TokenFactory f, Roles memory r)
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory payloads)
    {
        address im = vm.envAddress("EVM_ISSUANCE_MANAGER");
        targets = new address[](N_SERIES + 1);
        values = new uint256[](N_SERIES + 1);
        payloads = new bytes[](N_SERIES + 1);
        targets[0] = address(f);
        payloads[0] = abi.encodeCall(f.acceptOwnership, ());
        for (uint256 i; i < N_SERIES; ++i) {
            Bond memory b = _bond(i);
            targets[i + 1] = address(f);
            payloads[i + 1] =
                abi.encodeCall(f.deployToken, (b.name, b.cusip, b.isin, b.maturity, r.ops, im, r.navOwner));
        }
    }

    /// The swap's CREATE2 addresses, derived exactly as DeployAtomicSettlement deploys them.
    function _predictSwap(Roles memory r) internal view returns (address impl, address proxy) {
        impl = DeployGuards.predictCreate2(
            DeployGuards.saltFor("DeployAtomicSettlement:GyldAtomicSwap.impl"),
            keccak256(type(GyldAtomicSwap).creationCode)
        );
        bytes memory initData = abi.encodeCall(
            GyldAtomicSwap.initialize,
            (
                r.deployer,
                r.swapPauser,
                r.quoteSigner,
                r.treasurer,
                _cash(),
                uint16(MAX_QUOTE_DEVIATION_BPS),
                uint32(MAX_NAV_AGE_SECS)
            )
        );
        proxy = DeployGuards.predictCreate2(
            DeployGuards.saltFor("DeployAtomicSettlement:GyldAtomicSwap.proxy"),
            keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(impl, initData)))
        );
    }

    /// DeployAtomicSettlement's final topology, step by step, so a deploy that stopped midway
    /// names what is missing.
    function _requireSwapComplete(Roles memory r, GyldAtomicSwap w, address[N_SERIES] memory tokens, address tl)
        internal
        view
    {
        for (uint256 i; i < N_SERIES; ++i) {
            _requireSwapStep(w.registeredSeries(tokens[i]), string.concat("registerSeries ", _bond(i).tag));
        }
        _requireSwapStep(w.withdrawalWallet() == r.withdrawalWallet, "setWithdrawalWallet");
        _requireSwapStep(w.hasRole(w.ALLOWLIST_ADMIN_ROLE(), r.allowlistAdmin), "ALLOWLIST_ADMIN grant");
        _requireSwapStep(w.hasRole(w.DEFAULT_ADMIN_ROLE(), tl), "DEFAULT_ADMIN handover to the timelock");
        _requireSwapStep(
            !w.hasRole(w.DEFAULT_ADMIN_ROLE(), r.deployer) && !w.hasRole(w.ALLOWLIST_ADMIN_ROLE(), r.deployer),
            "deployer role revokes"
        );
    }

    function _requireSwapStep(bool done, string memory step) internal pure {
        if (!done) {
            revert(
                string.concat(
                    "BscKmsStack: swap deploy stopped midway - missing ",
                    step,
                    ". Finish the run C broadcast with --resume; nothing was whitelisted or minted"
                )
            );
        }
    }

    function _priced(KaleidoscopeNAVFeed feed) internal view returns (bool) {
        try feed.latestRoundData() returns (uint80, int256, uint256, uint256 updatedAt, uint80) {
            return updatedAt != 0;
        } catch {
            return false;
        }
    }

    /// The 32 bytes governance signs (EIP-191 personal_sign over the raw bytes, not their hex
    /// text) before run A: `forge script ... --sig 'governanceProofMessage()' --rpc-url <bsc>`.
    function governanceProofMessage() external view returns (bytes32 h) {
        h = _proofHash(_roles());
        console.log("personal_sign these 32 bytes, then export %s=<65-byte sig>:", _governanceSigEnv());
        console.logBytes32(h);
    }

    /// Step 0 proof (check-kms-addresses.sh): the governance key signed (EIP-191) chain 97,
    /// the full address set and DEPLOY_SALT_TAG. Without it a mistyped governance address
    /// would become the timelock's only proposer, and governance would be lost for good.
    function _requireGovernanceProof(Roles memory r) internal view {
        (address signer,,) =
            ECDSA.tryRecover(MessageHashUtils.toEthSignedMessageHash(_proofHash(r)), vm.envBytes(_governanceSigEnv()));
        if (signer != r.governance) revert GovernanceProofInvalid(signer);
    }

    function _proofHash(Roles memory r) internal view returns (bytes32) {
        bytes32 tag = keccak256(bytes(DeployGuards.saltTag()));
        return keccak256(abi.encode(_proofTag(), block.chainid, keccak256(abi.encode(_addresses(r))), tag));
    }

    function _proofTag() internal pure virtual returns (bytes32) {
        return PROOF_TAG;
    }

    function _governanceSigEnv() internal pure virtual returns (string memory) {
        return "KMS_GOVERNANCE_SIG";
    }

    /// Order is the proof's encoding: keep it in step with check-kms-addresses.sh.
    function _addresses(Roles memory r) internal pure returns (address[14] memory) {
        return [
            r.deployer,
            r.governance,
            r.ops,
            r.navOwner,
            r.subscriber,
            r.redeemer,
            r.whitelistAdmin,
            r.issuancePauser,
            r.quoteSigner,
            r.treasurer,
            r.allowlistAdmin,
            r.withdrawalWallet,
            r.sanctionsOwner,
            r.userWithdrawal
        ];
    }

    function _bond(uint256 i) internal view returns (Bond memory) {
        if (_isMainnet()) return _envBond(i);
        if (i == 0) return Bond("Caterpillar Inc 3.7% 2028", "14913UBF6", "US14913UBF66", 1_851_811_200, "CAT");
        if (i == 1) return Bond("Citigroup Inc 3.887% 2028", "172967LD1", "US172967LD18", 1_831_075_200, "C");
        return Bond("Coca-Cola Co 2.25% 2032", "191216DP2", "US191216DP21", 1_977_609_600, "KO");
    }

    /// 56: bond i (0..2) from BOND_<i>_NAME, _SYMBOL (the token symbol; the CUSIP on testnet),
    /// _CUSIP, _ISIN, _MATURITY (unix s), _COUPON (as written in the name, e.g. "3.7%") and _TAG
    /// (gateway env suffix). Every field is required; the CUSIP must be the ISIN's body and the
    /// name must carry the coupon.
    function _envBond(uint256 i) internal view returns (Bond memory b) {
        string memory k = string.concat("BOND_", vm.toString(i), "_");
        string memory cusip = vm.envString(string.concat(k, "CUSIP"));
        string memory coupon = vm.envString(string.concat(k, "COUPON"));
        b = Bond(
            vm.envString(string.concat(k, "NAME")),
            vm.envString(string.concat(k, "SYMBOL")),
            vm.envString(string.concat(k, "ISIN")),
            vm.envUint(string.concat(k, "MATURITY")),
            vm.envString(string.concat(k, "TAG"))
        );
        DeployGuards.requireValidIsin(b.isin);
        bytes memory isin = bytes(b.isin);
        bytes memory body = new bytes(9);
        for (uint256 j; j < 9; ++j) {
            body[j] = isin[j + 2];
        }
        require(keccak256(body) == keccak256(bytes(cusip)), string.concat("BscKmsStack: ", k, "CUSIP is not the ISIN's body"));
        require(
            bytes(coupon).length != 0 && vm.contains(b.name, coupon),
            string.concat("BscKmsStack: ", k, "NAME does not carry ", k, "COUPON")
        );
        require(
            bytes(b.cusip).length != 0 && bytes(b.tag).length != 0 && b.maturity > block.timestamp,
            string.concat("BscKmsStack: ", k, "SYMBOL/TAG empty or MATURITY not in the future")
        );
    }

    // ══ Per-chain config (97: the constants; 56: env, fail closed) ═══════════

    function _isMainnet() internal view returns (bool) {
        return block.chainid == BSC_MAINNET;
    }

    /// 56: CASH_TOKEN, BSC USDT or USDC, read back at 18 decimals.
    function _cash() internal view returns (address c) {
        if (!_isMainnet()) return USDT;
        c = vm.envAddress("CASH_TOKEN");
        require(c == USDT_BSC || c == USDC_BSC, "BscKmsStack: CASH_TOKEN must be BSC USDT or USDC");
        require(IERC20Metadata(c).decimals() == CASH_DECIMALS, "BscKmsStack: CASH_TOKEN is not 18 decimals");
    }

    /// 56: TIMELOCK_DELAY_SECONDS, default and floor DeployGuards.MIN_PROD_TIMELOCK_DELAY (48 h),
    /// cap MAX_TIMELOCK_DELAY (7 d).
    function _timelockDelay() internal view returns (uint256 d) {
        if (!_isMainnet()) return TIMELOCK_DELAY;
        d = vm.envOr("TIMELOCK_DELAY_SECONDS", DeployGuards.MIN_PROD_TIMELOCK_DELAY);
        require(d >= DeployGuards.MIN_PROD_TIMELOCK_DELAY, "BscKmsStack: TIMELOCK_DELAY_SECONDS below 48 h (172800)");
        require(
            d <= MAX_TIMELOCK_DELAY,
            "BscKmsStack: TIMELOCK_DELAY_SECONDS above 7 days (604800) - a typo? Phase 2 would wait that long"
        );
    }

    /// The mirror's forwarding oracle: none on 97; 56: SANCTIONS_FORWARDING_ORACLE (Chainalysis).
    function _forwardingOracle() internal view returns (address o) {
        if (!_isMainnet()) return address(0);
        o = vm.envAddress("SANCTIONS_FORWARDING_ORACLE");
        require(o.code.length != 0, "BscKmsStack: SANCTIONS_FORWARDING_ORACLE has no code");
    }

    /// SANCTIONS_PROBE_FLAGGED. 56: a real SDN address the forwarding oracle already flags, so
    /// runA2 plans no tx (and no SDN address reaches Fordefi calldata).
    function _probe() internal view returns (address p) {
        p = vm.envAddress("SANCTIONS_PROBE_FLAGGED");
        if (!_isMainnet()) return p;
        require(
            ISanctionsList(_forwardingOracle()).isSanctioned(p),
            "BscKmsStack: SANCTIONS_FORWARDING_ORACLE does not flag SANCTIONS_PROBE_FLAGGED"
        );
    }

    /// First NAV of series i (8 dp). 97: NAV_ANSWER_8DP for all; 56: NAV_ANSWER_8DP_<TAG>, no default.
    function _nav(uint256 i) internal view returns (int256 nav) {
        if (!_isMainnet()) return int256(vm.envUint("NAV_ANSWER_8DP"));
        nav = int256(vm.envUint(string.concat("NAV_ANSWER_8DP_", _bond(i).tag)));
        require(nav > 0, "BscKmsStack: NAV_ANSWER_8DP_<TAG> must be positive");
    }

    /// Every role from the KMS env file, pairwise distinct (stricter than the guards, which
    /// only split the quorum pairs).
    function _roles() internal view virtual returns (Roles memory r) {
        require(block.chainid == BSC_TESTNET, "BscKmsStack: BSC testnet (97) only");
        r = Roles({
            deployer: vm.envAddress("KMS_DEPLOYER"),
            governance: vm.envAddress("KMS_GOVERNANCE"),
            ops: vm.envAddress("KMS_OPS"),
            navOwner: vm.envAddress("KMS_NAV_FEED_OWNER"),
            subscriber: vm.envAddress("KMS_SUBSCRIBER"),
            redeemer: vm.envAddress("KMS_REDEEMER"),
            whitelistAdmin: vm.envAddress("KMS_WHITELIST_ADMIN"),
            issuancePauser: vm.envAddress("KMS_ISSUANCE_PAUSER"),
            quoteSigner: vm.envAddress("KMS_QUOTE_SIGNER"),
            treasurer: vm.envAddress("KMS_TREASURER"),
            allowlistAdmin: vm.envAddress("KMS_ALLOWLIST_ADMIN"),
            withdrawalWallet: vm.envAddress("KMS_WITHDRAWAL_WALLET"),
            sanctionsOwner: vm.envAddress("KMS_SANCTIONS_OWNER"),
            userWithdrawal: vm.envAddress("KMS_USER_WITHDRAWAL"),
            swapPauser: address(0)
        });
        r.swapPauser = r.ops;
        address[14] memory a = _addresses(r);
        for (uint256 i; i < a.length; ++i) {
            require(a[i] != address(0), "BscKmsStack: a KMS_* address is zero");
            for (uint256 j = i + 1; j < a.length; ++j) {
                require(a[i] != a[j], "BscKmsStack: two KMS roles share an address");
            }
        }
    }

    function _factory() internal view returns (TokenFactory f) {
        f = TokenFactory(vm.envAddress("EVM_FACTORY_ADDRESS"));
        require(address(f).code.length != 0, "BscKmsStack: EVM_FACTORY_ADDRESS has no code");
    }

    /// The nested deploy scripts read their deployer from tx.origin (DeployGuards.broadcaster).
    function _requireSender(address who) internal view {
        require(tx.origin == who, string.concat("BscKmsStack: run with --sender ", vm.toString(who)));
    }

    function _check(bool ok, string memory what) internal {
        require(ok, string.concat("VERIFY FAILED: ", what));
        ++_checks;
        console.log(string.concat("  [ok] ", what));
    }

    function _setEnv(string memory key, address value) internal {
        vm.setEnv(key, vm.toString(value));
    }

    function _kv(string memory k, address v) internal pure {
        console.log(string.concat("@@ ", k, "=", vm.toString(v)));
    }
}
