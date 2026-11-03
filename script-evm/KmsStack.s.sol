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
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title KmsStack
/// @notice Fresh stack on a rehearsal testnet (Katana Bokuto 737373), every role its own
///         AWS KMS key, production guards on (not a dev chain; timelock floor 5 min). The
///         swap is the audited GyldAtomicSwap, so CASH_TOKEN must be a 6dp stablecoin
///         (initialize refuses any other). GLD-807, GLD-850. Runbook: docs/deploy/kms-stack.md; rehearsal:
///         script-evm/simulate-kms-stack.sh <chain>.
///
///   runA()   --sender KMS_DEPLOYER   deployer + sanctions owner: SanctionsOracleMirror seeded
///                                    with a live SDN probe, then DeployDevNet (TIMELOCK_DELAY_SECONDS)
///   runB()   --sender KMS_GOVERNANCE schedules ONE batch: factory accept + CAT/C/KO deployToken
///   runC()   --sender KMS_DEPLOYER   after the delay: governance executes, NAV owner pushes,
///                                    DeployAtomicSettlement (CASH_TOKEN), swap whitelisted; no
///                                    inventory (the platform's fund-inventory route mints it).
///                                    Every step skips what is done: re-run to finish a partial C
///   verify() any sender              reads every role holder back; reverts on drift
///
/// Env: script-evm/chains/<chain>.env (CHAIN_ID, CASH_TOKEN, CASH_DECIMALS,
/// TIMELOCK_DELAY_SECONDS), script-evm/kms-roles.env (KMS_*), KMS_GOVERNANCE_SIG (from
/// check-kms-addresses.sh), SANCTIONS_PROBE_FLAGGED, NAV_ANSWER_8DP, DEPLOY_SALT_TAG; then EVM_FACTORY_ADDRESS + EVM_ISSUANCE_MANAGER (printed by runA) and
/// EVM_ATOMIC_SWAP_ADDRESS (printed by runC).
contract KmsStack is Script {
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
        address probe = vm.envAddress("SANCTIONS_PROBE_FLAGGED");

        bytes memory init = abi.encodePacked(
            type(SanctionsOracleMirror).creationCode, abi.encode(r.governance, r.sanctionsOwner, address(0))
        );
        vm.broadcast(r.deployer);
        // Salt name kept from GLD-807 (BSC): the deployed Katana mirror's address depends on it.
        SanctionsOracleMirror mirror = new SanctionsOracleMirror{
            salt: DeployGuards.vacantSalt("BscKmsStack:SanctionsOracleMirror", init)
        }(
            r.governance, r.sanctionsOwner, address(0)
        );

        address[] memory seed = new address[](1);
        seed[0] = probe;
        vm.broadcast(r.sanctionsOwner);
        mirror.addToSanctionsList(seed);

        _setEnv("GOVERNANCE_MULTISIG", r.governance);
        _setEnv("OPS_MULTISIG", r.ops);
        _setEnv("SUBSCRIBER_ADDRESS", r.subscriber);
        _setEnv("REDEEMER_ADDRESS", r.redeemer);
        _setEnv("WHITELIST_ADMIN", r.whitelistAdmin);
        _setEnv("ISSUANCE_PAUSER", r.issuancePauser);
        _setEnv("NAV_FEED_OWNER", r.navOwner);
        _setEnv("SANCTIONS_LIST", address(mirror));
        _setEnv("SANCTIONS_PROBE_FLAGGED", probe);
        DeployDevNet d = new DeployDevNet();
        d.run(); // broadcasts as --sender (the deployer); stops with the factory hand-off pending

        console.log("=== run A done: export these for runs B and C ===");
        _kv("SANCTIONS_ORACLE_MIRROR", address(mirror));
        _kv("TIMELOCK_ADDRESS", address(d.timelock()));
        _kv("EVM_FACTORY_ADDRESS", address(d.factory()));
        _kv("EVM_ISSUANCE_MANAGER", address(d.issuanceMgr()));
    }

    // ══ Run B — governance schedules Phase 2 ═════════════════════════════════

    function runB() external {
        Roles memory r = _roles();
        _requireSender(r.governance);
        TokenFactory f = _factory();
        TimelockController tl = TimelockController(payable(f.pendingOwner()));
        require(address(tl) != address(0), "KmsStack: factory has no pending owner (run A missing or B done)");
        for (uint256 i; i < N_SERIES; ++i) {
            DeployGuards.requireValidIsin(_bond(i).isin);
            DeployGuards.requireIsinVacant(address(f), _bond(i).isin);
        }
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase2(f, r);
        uint256 delay = tl.getMinDelay();
        vm.broadcast(r.governance);
        tl.scheduleBatch(targets, values, payloads, bytes32(0), PHASE2_SALT, delay);
        console.log("Phase 2 scheduled; executable after %d s", delay);
    }

    // ══ Run C — execute, NAV, swap, whitelist ════════════════════════════════

    function runC() external {
        Roles memory r = _roles();
        _requireSender(r.deployer);
        int256 nav = int256(vm.envUint("NAV_ANSWER_8DP"));
        TokenFactory f = _factory();
        IssuanceManager im = IssuanceManager(vm.envAddress("EVM_ISSUANCE_MANAGER"));
        address pending = f.pendingOwner(); // zero once Phase 2 has executed
        TimelockController tl = TimelockController(payable(pending != address(0) ? pending : f.owner()));
        (address[] memory targets, uint256[] memory values, bytes[] memory payloads) = _phase2(f, r);
        bytes32 id = tl.hashOperationBatch(targets, values, payloads, bytes32(0), PHASE2_SALT);
        if (!tl.isOperationDone(id)) {
            if (!tl.isOperationReady(id)) {
                uint256 at = tl.getTimestamp(id);
                require(at != 0, "KmsStack: Phase 2 is not scheduled (run B)");
                revert(string.concat("KmsStack: Phase 2 executable in ", vm.toString(at - block.timestamp), " s"));
            }
            vm.broadcast(r.governance);
            tl.executeBatch(targets, values, payloads, bytes32(0), PHASE2_SALT);
        }

        address[N_SERIES] memory tokens;
        string memory series;
        vm.startBroadcast(r.navOwner); // first NAV push: registerSeries refuses an unpriced feed
        for (uint256 i; i < N_SERIES; ++i) {
            tokens[i] = f.tokenByIsin(_bond(i).isin);
            KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(f.navFeedOf(tokens[i]));
            if (!_priced(feed)) feed.updateAnswer(nav);
            series = string.concat(series, i == 0 ? "" : ",", vm.toString(tokens[i]));
        }
        vm.stopBroadcast();

        (address impl, address swap) = _predictSwap(r);
        if (swap.code.length == 0) {
            // DeployAtomicSettlement's vacantSalt would revert on the impl forever: say why.
            _requireSwapStep(impl.code.length == 0, "proxy deploy (impl is on chain, the proxy is not)");
            _setEnv("USDC_ADDRESS", vm.envAddress("CASH_TOKEN"));
            _setEnv("EVM_ISSUANCE_MANAGER", address(im));
            _setEnv("EVM_FACTORY_ADDRESS", address(f));
            _setEnv("TIMELOCK_ADDRESS", address(tl));
            _setEnv("OPS_MULTISIG", r.ops);
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
            require(address(d.swap()) == swap, "KmsStack: swap landed off its predicted address");
        }
        // Fail closed before the swap is whitelisted: a swap deploy that stopped midway may still
        // be administered by the deployer.
        _requireSwapComplete(r, GyldAtomicSwap(swap), tokens, address(tl));

        // Whitelisted so it can receive inventory. GLD-1054: the script mints NO inventory. A
        // mint outside the platform never reaches its ledger, and supply reconciliation then
        // halts every series; fund it through the platform's POST /admin/swap/fund-inventory.
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

    // ══ Verify ═══════════════════════════════════════════════════════════════

    function verify() external {
        Roles memory r = _roles();
        TokenFactory f = _factory();
        IssuanceManager im = IssuanceManager(vm.envAddress("EVM_ISSUANCE_MANAGER"));
        GyldAtomicSwap w = GyldAtomicSwap(vm.envAddress("EVM_ATOMIC_SWAP_ADDRESS"));
        TimelockController tl = TimelockController(payable(f.owner()));
        address dep = r.deployer;

        uint256 delay = vm.envUint("TIMELOCK_DELAY_SECONDS");
        _check(tl.getMinDelay() == delay, string.concat("timelock minDelay == ", vm.toString(delay), " s"));
        _check(
            tl.hasRole(tl.PROPOSER_ROLE(), r.governance) && tl.hasRole(tl.CANCELLER_ROLE(), r.governance),
            "timelock PROPOSER + CANCELLER = KMS governance"
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
                && address(m.forwardingOracle()) == address(0),
            "sanctionsList = SanctionsOracleMirror (admin governance, updater sanctions owner, no forwarding)"
        );
        _check(
            m.isSanctioned(vm.envAddress("SANCTIONS_PROBE_FLAGGED")) && !m.isSanctioned(dep)
                && !m.hasRole(m.DEFAULT_ADMIN_ROLE(), dep) && !m.hasRole(m.SANCTIONS_UPDATER_ROLE(), dep),
            "mirror flags the SDN probe, not the deployer; deployer holds no mirror role"
        );

        _check(
            im.hasRole(im.DEFAULT_ADMIN_ROLE(), address(tl)) && im.hasRole(im.REGISTRAR_ROLE(), address(f))
                && im.hasRole(im.SUBSCRIBER_ROLE(), r.subscriber) && im.hasRole(im.REDEEMER_ROLE(), r.redeemer)
                && im.hasRole(im.WHITELIST_ADMIN_ROLE(), r.whitelistAdmin)
                && im.hasRole(im.ISSUANCE_PAUSER_ROLE(), r.issuancePauser),
            "IssuanceManager: admin timelock, registrar factory, KMS subscriber/redeemer/whitelist/pauser"
        );
        _check(
            !im.hasRole(im.DEFAULT_ADMIN_ROLE(), dep) && !im.hasRole(im.SUBSCRIBER_ROLE(), dep)
                && !im.hasRole(im.REDEEMER_ROLE(), dep) && !im.hasRole(im.WHITELIST_ADMIN_ROLE(), dep)
                && !im.hasRole(im.ISSUANCE_PAUSER_ROLE(), dep) && !im.hasRole(im.REGISTRAR_ROLE(), dep),
            "deployer holds no IssuanceManager role"
        );
        _check(im.whitelisted(address(w)), "swap whitelisted on IssuanceManager");

        _check(
            w.hasRole(w.DEFAULT_ADMIN_ROLE(), address(tl)) && w.hasRole(w.PAUSER_ROLE(), r.ops)
                && w.hasRole(w.QUOTE_SIGNER_ROLE(), r.quoteSigner) && w.hasRole(w.TREASURER_ROLE(), r.treasurer)
                && w.hasRole(w.ALLOWLIST_ADMIN_ROLE(), r.allowlistAdmin) && w.withdrawalWallet() == r.withdrawalWallet,
            "swap: admin timelock, KMS pauser/quote signer/treasurer/allowlist admin/withdrawal wallet"
        );
        _check(
            !w.hasRole(w.DEFAULT_ADMIN_ROLE(), dep) && !w.hasRole(w.PAUSER_ROLE(), dep)
                && !w.hasRole(w.QUOTE_SIGNER_ROLE(), dep) && !w.hasRole(w.TREASURER_ROLE(), dep)
                && !w.hasRole(w.ALLOWLIST_ADMIN_ROLE(), dep),
            "deployer holds no swap role"
        );
        uint256 dp = vm.envUint("CASH_DECIMALS");
        _check(
            w.usdc() == vm.envAddress("CASH_TOKEN") && IERC20Metadata(w.usdc()).decimals() == dp && !w.paused(),
            string.concat("swap cash = CASH_TOKEN, ", vm.toString(dp), "dp, unpaused")
        );

        for (uint256 i; i < N_SERIES; ++i) {
            _verifySeries(r, f, im, w, address(tl), i);
        }
        console.log("=== ALL %d CHECKS PASSED ===", _checks);
    }

    function _verifySeries(Roles memory r, TokenFactory f, IssuanceManager im, GyldAtomicSwap w, address tl, uint256 i)
        internal
    {
        string memory p = string.concat(_bond(i).tag, ": ");
        GyldBondToken t = GyldBondToken(f.tokenByIsin(_bond(i).isin));
        KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(f.navFeedOf(address(t)));
        NAVFeedForwarder fw = NAVFeedForwarder(f.forwarderOf(address(t)));
        address dep = r.deployer;
        _check(
            address(t) != address(0) && im.registeredTokens(address(t)) && t.hasRole(t.DEFAULT_ADMIN_ROLE(), tl)
                && t.hasRole(t.MINTER_ROLE(), address(im)) && t.hasRole(t.PAUSER_ROLE(), r.ops)
                && !t.hasRole(t.DEFAULT_ADMIN_ROLE(), dep) && !t.hasRole(t.PAUSER_ROLE(), dep)
                && !t.hasRole(t.MINTER_ROLE(), dep),
            string.concat(p, "token admin timelock, minter IssuanceManager, pauser KMS ops, deployer none")
        );
        _check(
            feed.owner() == r.navOwner && feed.pendingOwner() == address(0) && feed.emergencyUpdater() == r.ops
                && feed.rangeGovernor() == tl && fw.owner() == tl && fw.upstreamOracle() == address(feed),
            string.concat(p, "feed owner KMS NAV, guardian ops, range governor + forwarder owner timelock")
        );
        (, int256 answer,, uint256 updatedAt,) = fw.latestRoundData();
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
                r.ops,
                r.quoteSigner,
                r.treasurer,
                vm.envAddress("CASH_TOKEN"),
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
                    "KmsStack: swap deploy stopped midway - missing ",
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

    /// Step 0 proof (check-kms-addresses.sh): the KMS governance key signed (EIP-191) the chain id,
    /// the full KMS address set and DEPLOY_SALT_TAG. Without it a mistyped KMS_GOVERNANCE
    /// would become the timelock's only proposer, and governance would be lost for good.
    function _requireGovernanceProof(Roles memory r) internal view {
        bytes32 tag = keccak256(bytes(DeployGuards.saltTag()));
        bytes32 h = keccak256(abi.encode(PROOF_TAG, block.chainid, keccak256(abi.encode(_addresses(r))), tag));
        (address signer,,) =
            ECDSA.tryRecover(MessageHashUtils.toEthSignedMessageHash(h), vm.envBytes("KMS_GOVERNANCE_SIG"));
        if (signer != r.governance) revert GovernanceProofInvalid(signer);
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

    function _bond(uint256 i) internal pure returns (Bond memory) {
        if (i == 0) return Bond("Caterpillar Inc 3.7% 2028", "14913UBF6", "US14913UBF66", 1_851_811_200, "CAT");
        if (i == 1) return Bond("Citigroup Inc 3.887% 2028", "172967LD1", "US172967LD18", 1_831_075_200, "C");
        return Bond("Coca-Cola Co 2.25% 2032", "191216DP2", "US191216DP21", 1_977_609_600, "KO");
    }

    /// Every role from the KMS env file, pairwise distinct (stricter than the guards, which
    /// only split the quorum pairs).
    function _roles() internal view returns (Roles memory r) {
        require(block.chainid == vm.envUint("CHAIN_ID"), "KmsStack: block.chainid != CHAIN_ID (chains/<chain>.env)");
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
            userWithdrawal: vm.envAddress("KMS_USER_WITHDRAWAL")
        });
        address[14] memory a = _addresses(r);
        for (uint256 i; i < a.length; ++i) {
            require(a[i] != address(0), "KmsStack: a KMS_* address is zero");
            for (uint256 j = i + 1; j < a.length; ++j) {
                require(a[i] != a[j], "KmsStack: two KMS roles share an address");
            }
        }
    }

    function _factory() internal view returns (TokenFactory f) {
        f = TokenFactory(vm.envAddress("EVM_FACTORY_ADDRESS"));
        require(address(f).code.length != 0, "KmsStack: EVM_FACTORY_ADDRESS has no code");
    }

    /// The nested deploy scripts read their deployer from tx.origin (DeployGuards.broadcaster).
    function _requireSender(address who) internal view {
        require(tx.origin == who, string.concat("KmsStack: run with --sender ", vm.toString(who)));
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
