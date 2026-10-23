// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {BscKmsStack} from "./BscKmsStack.s.sol";

/// @title BscFordefiStack
/// @notice BscKmsStack with every role on its own Fordefi vault at deploy (GLD-978, "Option 2").
///         Only the role layout differs: the Swap Pause vault is swap PAUSER and IssuanceManager
///         ISSUANCE_PAUSER, the Whitelister vault is IssuanceManager WHITELIST_ADMIN and swap
///         ALLOWLIST_ADMIN, and there is no user-withdrawal role. The deployer (STACK_DEPLOYER,
///         the KMS deployer) signs every deploy and holds no role afterwards.
///
///         Each sub-phase has ONE signer kind. KMS: `--broadcast --aws --sender STACK_DEPLOYER`.
///         Fordefi: a dry run (never --broadcast) whose journal tools/fordefi-replay sends
///         through the vaults. Run them in order, each confirmed before the next starts.
///         Runbook: docs/deploy/bsc-testnet.md; rehearsal: script-bsc/simulate-fordefi-stack.sh.
///
///   runA1()  KMS      mirror (needs FORDEFI_GOVERNANCE_SIG, the Contract Admin's proof)
///   runA2()  Fordefi  Blocklist Updater seeds the SDN probe
///   runA3()  KMS      DeployDevNet (delay 300 s)
///   runB()   Fordefi  Contract Admin schedules the Phase 2 batch
///   runC1()  KMS      after 300 s: executes the Phase 2 batch (executors are open)
///   runC2()  Fordefi  NAV Feeder prices the three feeds
///   runC3()  KMS      DeployAtomicSettlement
///   runC4()  Fordefi  Whitelister whitelists the swap, Subscriber mints its inventory
///   verify() any sender
///
/// Env: script-bsc/fordefi-roles.bsc-testnet.env (STACK_DEPLOYER, FORDEFI_*),
/// FORDEFI_GOVERNANCE_SIG (the Contract Admin vault's personal_sign of
/// governanceProofMessage()), plus BscKmsStack's inputs. All-Fordefi instead: point
/// STACK_DEPLOYER at a Fordefi Deployer vault and dry-run + replay the KMS sub-phases too.
contract BscFordefiStack is BscKmsStack {
    /// Its own tag: the proof also binds this layout (swap PAUSER on Swap Pause, not Freeze).
    bytes32 internal constant FORDEFI_PROOF_TAG = keccak256("GLD-978.fordefi-governance-proof");

    function _roles() internal view override returns (Roles memory r) {
        require(block.chainid == BSC_TESTNET, "BscFordefiStack: BSC testnet (97) only");
        address whitelister = vm.envAddress("FORDEFI_WHITELISTER");
        address swapPause = vm.envAddress("FORDEFI_SWAP_PAUSE");
        r = Roles({
            deployer: vm.envAddress("STACK_DEPLOYER"),
            governance: vm.envAddress("FORDEFI_CONTRACT_ADMIN"),
            ops: vm.envAddress("FORDEFI_FREEZE"),
            navOwner: vm.envAddress("FORDEFI_NAV_FEEDER"),
            subscriber: vm.envAddress("FORDEFI_SUBSCRIBER"),
            redeemer: vm.envAddress("FORDEFI_BURN_ROLE"),
            whitelistAdmin: whitelister,
            issuancePauser: swapPause,
            quoteSigner: vm.envAddress("FORDEFI_QUOTE_SIGNER"),
            treasurer: vm.envAddress("FORDEFI_SWAP_TREASURER"),
            allowlistAdmin: whitelister,
            withdrawalWallet: vm.envAddress("FORDEFI_SWAP_DISTRIBUTION"),
            sanctionsOwner: vm.envAddress("FORDEFI_BLOCKLIST_UPDATER"),
            userWithdrawal: address(0), // no on-chain role in this layout
            swapPauser: swapPause
        });
        // Every vault once (the Whitelister holds both whitelist roles): pairwise distinct.
        address[12] memory a = [
            r.deployer,
            r.governance,
            r.ops,
            r.navOwner,
            r.subscriber,
            r.redeemer,
            whitelister,
            swapPause,
            r.quoteSigner,
            r.treasurer,
            r.withdrawalWallet,
            r.sanctionsOwner
        ];
        for (uint256 i; i < a.length; ++i) {
            require(a[i] != address(0), "BscFordefiStack: a role address is zero");
            for (uint256 j = i + 1; j < a.length; ++j) {
                require(a[i] != a[j], "BscFordefiStack: two roles share an address");
            }
        }
    }

    function runA1() external {
        Roles memory r = _kmsStep();
        _deployMirror(r);
    }

    function runA2() external {
        _seedMirror(_roles());
    }

    function runA3() external {
        Roles memory r = _kmsStep();
        _deployDevNet(r);
    }

    function runC1() external {
        Roles memory r = _kmsStep();
        _executePhase2(r, r.deployer);
    }

    function runC2() external {
        _pushNav(_roles());
    }

    function runC3() external {
        Roles memory r = _kmsStep();
        _deploySwap(r);
    }

    function runC4() external {
        _fillInventory(_roles());
    }

    /// A deployer sub-phase: --sender is the deployer (the nested scripts read tx.origin), and
    /// governance is proven before anything is deployed against it.
    function _kmsStep() internal view returns (Roles memory r) {
        r = _roles();
        _requireSender(r.deployer);
        _requireGovernanceProof(r);
    }

    function _proofTag() internal pure override returns (bytes32) {
        return FORDEFI_PROOF_TAG;
    }

    function _governanceSigEnv() internal pure override returns (string memory) {
        return "FORDEFI_GOVERNANCE_SIG";
    }
}
