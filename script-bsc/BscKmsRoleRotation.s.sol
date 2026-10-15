// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IssuanceManager} from "../contracts/IssuanceManager.sol";
import {GyldBondToken} from "../contracts/GyldBondToken.sol";
import {KaleidoscopeNAVFeed} from "../contracts/KaleidoscopeNAVFeed.sol";
import {GyldAtomicSwap} from "../contracts/GyldAtomicSwap.sol";

/// @title BscKmsRoleRotation
/// @notice GLD-807: move the live BSC testnet (97) roles from the derived keys to AWS KMS.
///         Holds no keys (the signer comes from the CLI). Every phase skips what is done and
///         reverts on drift. Runbook: docs/deploy/bsc-testnet.md.
contract BscKmsRoleRotation is Script {
    bytes32 internal constant PROOF_TAG = keccak256("GLD-807.kms-governance-proof");
    bytes32 internal constant SALT = keccak256("GLD-807.kms-role-rotation");
    // Holder indices; same order as check-kms-addresses.sh (index 11 = sanctions owner).
    uint256 internal constant GOV = 0;
    uint256 internal constant OPS = 1;
    uint256 internal constant NAV = 2;
    uint256 internal constant SUB = 3;
    uint256 internal constant RED = 4;
    uint256 internal constant WL = 5;
    uint256 internal constant IP = 6;
    uint256 internal constant QS = 7;
    uint256 internal constant TR = 8;
    uint256 internal constant AL = 9;
    uint256 internal constant WW = 10;

    error WrongChain(uint256 chainId);
    error GovernanceProofInvalid(address recovered);
    error Drift(address target, bytes32 what);
    error NotRotated(address target, bytes32 what);

    struct Rotation {
        address target;
        bytes32 role;
        address from;
        address to;
    }

    TimelockController internal timelock;
    IssuanceManager internal im;
    GyldAtomicSwap internal swap;
    address[3] internal tokens;
    address[3] internal feeds;
    address[12] internal o; // current holders (docs/deploy/bsc-testnet-addresses.env)
    address[12] internal n; // KMS targets (script-bsc/kms-roles.bsc-testnet.env)

    function setUp() public {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        timelock = TimelockController(payable(vm.envAddress("TIMELOCK_ADDRESS")));
        im = IssuanceManager(vm.envAddress("EVM_ISSUANCE_MANAGER"));
        swap = GyldAtomicSwap(vm.envAddress("EVM_ATOMIC_SWAP_ADDRESS"));
        string[3] memory tags = ["CAT", "C", "KO"];
        for (uint256 i; i < 3; ++i) {
            tokens[i] = vm.envAddress(string.concat("TOKEN_", tags[i]));
            feeds[i] = vm.envAddress(string.concat("NAVFEED_", tags[i]));
        }
        string[12] memory kms = [
            "GOVERNANCE",
            "OPS",
            "NAV_FEED_OWNER",
            "SUBSCRIBER",
            "REDEEMER",
            "WHITELIST_ADMIN",
            "ISSUANCE_PAUSER",
            "QUOTE_SIGNER",
            "TREASURER",
            "ALLOWLIST_ADMIN",
            "WITHDRAWAL_WALLET",
            "SANCTIONS_OWNER"
        ];
        string[11] memory old = [
            "GOVERNANCE_MULTISIG",
            "OPS_MULTISIG",
            "NAV_FEED_OWNER",
            "SUBSCRIBER_ADDRESS",
            "REDEEMER_ADDRESS",
            "WHITELIST_ADMIN",
            "ISSUANCE_PAUSER",
            "QUOTE_SIGNER",
            "TREASURER_ADDRESS",
            "ALLOWLIST_ADMIN",
            "WITHDRAWAL_WALLET"
        ];
        for (uint256 i; i < 12; ++i) {
            n[i] = vm.envAddress(string.concat("KMS_", kms[i]));
            if (i < 11) o[i] = vm.envAddress(old[i]);
        }
    }

    /// Phase A (old governance): one timelock batch. Refused unless KMS_GOVERNANCE has signed
    /// this rotation (check-kms-addresses.sh): the batch hands it the timelock for good.
    function rotateRoles() external {
        address[12] memory targets_ = n;
        bytes32 h = keccak256(abi.encode(PROOF_TAG, block.chainid, address(timelock), keccak256(abi.encode(targets_))));
        (address signer,,) =
            ECDSA.tryRecover(MessageHashUtils.toEthSignedMessageHash(h), vm.envBytes("KMS_GOVERNANCE_SIG"));
        if (signer != n[GOV]) revert GovernanceProofInvalid(signer);

        Rotation[16] memory r = _rotations();
        address[] memory targets = new address[](34);
        bytes[] memory data = new bytes[](34);
        uint256 k;
        bool quoteSignerRevoked;
        for (uint256 i; i < 16; ++i) {
            if (i == 14) {
                // Swap follow-ups, before the timelock PROPOSER + CANCELLER handover (r[14..15]).
                address w = swap.withdrawalWallet();
                if (w == o[WW]) {
                    targets[k] = address(swap);
                    data[k++] = abi.encodeCall(GyldAtomicSwap.setWithdrawalWallet, (n[WW]));
                } else if (w != n[WW]) {
                    revert Drift(address(swap), "withdrawalWallet");
                }
                if (quoteSignerRevoked) {
                    // The role is the signer registry: kill every quote the old signer issued.
                    targets[k] = address(swap);
                    data[k++] = abi.encodeCall(GyldAtomicSwap.bumpQuoteEpoch, ());
                }
            }
            // old == new would grant nothing then revoke: the role ends with no holder.
            if (r[i].from == r[i].to) revert Drift(r[i].target, r[i].role);
            IAccessControl ac = IAccessControl(r[i].target);
            bool hasOld = ac.hasRole(r[i].role, r[i].from);
            bool hasNew = ac.hasRole(r[i].role, r[i].to);
            if (!hasOld && !hasNew) revert Drift(r[i].target, r[i].role);
            if (!hasNew) {
                targets[k] = r[i].target;
                data[k++] = abi.encodeCall(IAccessControl.grantRole, (r[i].role, r[i].to));
            }
            if (hasOld) {
                targets[k] = r[i].target;
                data[k++] = abi.encodeCall(IAccessControl.revokeRole, (r[i].role, r[i].from));
                quoteSignerRevoked = quoteSignerRevoked || i == 0;
            }
        }
        if (k == 0) return;
        assembly {
            mstore(targets, k)
            mstore(data, k)
        }
        uint256[] memory values = new uint256[](k);
        bytes32 id = timelock.hashOperationBatch(targets, values, data, 0, SALT);
        vm.startBroadcast(o[GOV]);
        // Already scheduled by an interrupted run: just execute it.
        if (!timelock.isOperation(id)) timelock.scheduleBatch(targets, values, data, 0, SALT, 0);
        timelock.executeBatch(targets, values, data, 0, SALT);
        vm.stopBroadcast();
    }

    /// Phase B (old NAV owner): Ownable2Step transferOwnership(KMS NAV owner) on each feed.
    function transferNavOwnership() external {
        vm.startBroadcast(o[NAV]);
        for (uint256 i; i < 3; ++i) {
            KaleidoscopeNAVFeed f = KaleidoscopeNAVFeed(feeds[i]);
            if (f.owner() == n[NAV] || f.pendingOwner() == n[NAV]) continue;
            if (f.owner() != o[NAV]) revert Drift(feeds[i], "owner");
            f.transferOwnership(n[NAV]);
        }
        vm.stopBroadcast();
    }

    /// Phase C (KMS NAV owner): acceptOwnership() on each feed.
    function acceptNavOwnership() external {
        vm.startBroadcast(n[NAV]);
        for (uint256 i; i < 3; ++i) {
            KaleidoscopeNAVFeed f = KaleidoscopeNAVFeed(feeds[i]);
            if (f.owner() == n[NAV]) continue;
            if (f.pendingOwner() != n[NAV]) revert Drift(feeds[i], "pendingOwner");
            f.acceptOwnership();
        }
        vm.stopBroadcast();
    }

    /// Phase V (read-only): reverts unless every role, the wallet, the quote epoch and the
    /// feed owners are rotated. QUOTE_EPOCH_BEFORE is recorded before Phase A (no default).
    function verify() external view {
        Rotation[16] memory r = _rotations();
        for (uint256 i; i < 16; ++i) {
            IAccessControl ac = IAccessControl(r[i].target);
            if (!ac.hasRole(r[i].role, r[i].to) || ac.hasRole(r[i].role, r[i].from)) {
                revert NotRotated(r[i].target, r[i].role);
            }
        }
        if (swap.withdrawalWallet() != n[WW]) revert NotRotated(address(swap), "withdrawalWallet");
        if (swap.quoteEpoch() <= vm.envUint("QUOTE_EPOCH_BEFORE")) revert NotRotated(address(swap), "quoteEpoch");
        for (uint256 i; i < 3; ++i) {
            KaleidoscopeNAVFeed f = KaleidoscopeNAVFeed(feeds[i]);
            if (f.owner() != n[NAV] || f.pendingOwner() != address(0)) revert NotRotated(feeds[i], "owner");
        }
    }

    /// Every AccessControl role moved; the quote signer first, the timelock's own roles last.
    function _rotations() internal view returns (Rotation[16] memory r) {
        address s = address(swap);
        address m = address(im);
        r[0] = Rotation(s, swap.QUOTE_SIGNER_ROLE(), o[QS], n[QS]);
        r[1] = Rotation(s, swap.TREASURER_ROLE(), o[TR], n[TR]);
        r[2] = Rotation(s, swap.ALLOWLIST_ADMIN_ROLE(), o[AL], n[AL]);
        r[3] = Rotation(s, swap.PAUSER_ROLE(), o[OPS], n[OPS]);
        r[4] = Rotation(m, im.SUBSCRIBER_ROLE(), o[SUB], n[SUB]);
        r[5] = Rotation(m, im.REDEEMER_ROLE(), o[RED], n[RED]);
        r[6] = Rotation(m, im.WHITELIST_ADMIN_ROLE(), o[WL], n[WL]);
        r[7] = Rotation(m, im.ISSUANCE_PAUSER_ROLE(), o[IP], n[IP]);
        for (uint256 i; i < 3; ++i) {
            GyldBondToken t = GyldBondToken(tokens[i]);
            r[8 + 2 * i] = Rotation(tokens[i], t.PAUSER_ROLE(), o[OPS], n[OPS]);
            r[9 + 2 * i] = Rotation(tokens[i], t.DOCUMENT_ROLE(), o[OPS], n[OPS]);
        }
        r[14] = Rotation(address(timelock), timelock.PROPOSER_ROLE(), o[GOV], n[GOV]);
        r[15] = Rotation(address(timelock), timelock.CANCELLER_ROLE(), o[GOV], n[GOV]);
    }
}
