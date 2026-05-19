// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DeployEulerStep4 - BASE MAINNET                                         ║
// ║                                                                          ║
// ║  Step 4 of 6: Deploy escrowed collateral vault for TBA                  ║
// ║                                                                          ║
// ║  What this does:                                                         ║
// ║    Creates an EVault in "escrow mode" — no oracle, no borrowing,        ║
// ║    accepts only TBA deposits. Users deposit TBA here, then use it       ║
// ║    as collateral to borrow USDC from the lending vault (Step 5).        ║
// ║                                                                          ║
// ║  Why oracle = address(0):                                                ║
// ║    Escrow vaults hold one asset and do not lend. The oracle is only     ║
// ║    needed by the lending vault (which reads TBA price via EulerRouter). ║
// ║    Passing address(0) / address(0) as trailingData is the correct       ║
// ║    pattern for escrow vaults (verified against Euler docs).             ║
// ║                                                                          ║
// ║  EscrowedCollateralPerspective (on Base):                               ║
// ║    0x977590fA311755DA2fa1421c1A944520b684f90F                           ║
// ║    This perspective enforces that the vault is properly set up:         ║
// ║    upgradeable=true, zero governor, hooked ops cleared, unitOfAccount=0 ║
// ║                                                                          ║
// ║  Governance is renounced immediately after config — immutable.          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

import {Script, console} from "forge-std/Script.sol";

contract DeployEulerStep4 is Script {

    // ── Euler V2 factory on Base mainnet ──────────────────────────────────
    address constant EVAULT_FACTORY = 0x7F321498A801A191a93C840750ed637149dDf8D0;

    // ── TBA bond token on Base mainnet ────────────────────────────────────
    address constant TBA = 0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3;

    // ── EscrowedCollateralPerspective on Base (official Euler deployment) ─
    address constant ESCROW_PERSPECTIVE = 0x977590fA311755DA2fa1421c1A944520b684f90F;

    function run() external {
        require(block.chainid == 8453, "DeployEulerStep4: Base mainnet only");

        console.log("=== DeployEulerStep4 - Base Mainnet ===");
        console.log("Chain ID:        %d", block.chainid);
        console.log("Deployer:        %s", msg.sender);
        console.log("Asset (TBA):     %s", TBA);
        console.log("Oracle:          address(0) - escrow vault, no pricing needed");
        console.log("unitOfAccount:   address(0) - escrow vault, no pricing needed");
        console.log("");

        // EVK trailingData format: abi.encodePacked(asset, oracle, unitOfAccount) = 60 bytes.
        // The factory prepends bytes4(0) making it 64 bytes (= PROXY_METADATA_LENGTH).
        // Oracle and unitOfAccount are zero: valid for collateral-only vaults (checked at
        // borrow time, not during init). Asset MUST be non-zero and a deployed contract.
        bytes memory trailingData = abi.encodePacked(TBA, address(0), address(0));

        vm.startBroadcast();

        // 1. Deploy escrow vault (upgradeable=true required by EscrowedCollateralPerspective)
        address escrowVault = IEVaultFactory(EVAULT_FACTORY).createProxy(
            address(0),  // accept any implementation from factory
            true,        // upgradeable — required by EscrowedCollateralPerspective
            trailingData
        );

        // 2. Clear hooked ops (post-init all ops are hooked by default; clearing enables
        //    deposit/withdraw. No IRM means borrow is still unavailable regardless.)
        IEVault(escrowVault).setHookConfig(address(0), 0);

        // 3. Renounce governance — vault is now permanently immutable
        IEVault(escrowVault).setGovernorAdmin(address(0));

        vm.stopBroadcast();

        // ── Verify post-deploy state ──────────────────────────────────────
        address governor    = IEVault(escrowVault).governorAdmin();
        address oracle      = IEVault(escrowVault).oracle();
        address unitOfAcct  = IEVault(escrowVault).unitOfAccount();
        address asset       = IEVault(escrowVault).asset();

        require(governor   == address(0), "governor not renounced");
        require(oracle     == address(0), "oracle should be zero for escrow vault");
        require(unitOfAcct == address(0), "unitOfAccount should be zero for escrow vault");
        require(asset      == TBA,        "asset mismatch");

        console.log("=== Step 4 complete ===");
        console.log("EULER_ESCROW_VAULT=%s", escrowVault);
        console.log("  asset:         %s (TBA)", asset);
        console.log("  oracle:        %s (none - collateral-only)", oracle);
        console.log("  unitOfAccount: %s (none - collateral-only)", unitOfAcct);
        console.log("  governorAdmin: %s (renounced)", governor);
        console.log("");
        console.log("Next: run DeployEulerStep5.s.sol (USDC lending vault)");
    }
}

interface IEVaultFactory {
    function createProxy(
        address desiredImplementation,
        bool upgradeable,
        bytes memory trailingData
    ) external returns (address);
}

interface IEVault {
    function setHookConfig(address newHookTarget, uint32 newHookedOps) external;
    function setGovernorAdmin(address newGovernorAdmin) external;
    function governorAdmin() external view returns (address);
    function oracle() external view returns (address);
    function unitOfAccount() external view returns (address);
    function asset() external view returns (address);
}
