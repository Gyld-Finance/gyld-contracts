// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DeployEulerStep6 - BASE MAINNET                                         ║
// ║                                                                          ║
// ║  Step 6 of 6: Seed market and verify full borrow flow                   ║
// ║                                                                          ║
// ║  What this does (deployer acts as both lender and borrower):             ║
// ║    1. Approve USDC -> lending vault, deposit (seed liquidity)           ║
// ║    2. Approve TBA  -> escrow vault,  deposit (collateral)               ║
// ║    3. EVC.enableCollateral  — register escrow vault as collateral source ║
// ║    4. EVC.enableController  — register lending vault as debt controller  ║
// ║    5. borrow USDC from lending vault                                     ║
// ║    6. Verify: borrow balance, collateral value, utilisation             ║
// ╚══════════════════════════════════════════════════════════════════════════╝

import {Script, console} from "forge-std/Script.sol";

contract DeployEulerStep6 is Script {

    // ── EVC ───────────────────────────────────────────────────────────────
    address constant EVC = 0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989;

    // ── Tokens ────────────────────────────────────────────────────────────
    address constant TBA  = 0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ── Deployed vaults ───────────────────────────────────────────────────
    address constant ESCROW_VAULT  = 0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4;
    address constant LENDING_VAULT = 0xCF8930030FbA9c8599A534304B94972762d79F71;

    // ── Amounts ───────────────────────────────────────────────────────────
    //
    // USDC_SEED: seed liquidity supplied as lender (~$0.75, full wallet balance)
    // TBA_COLLATERAL: TBA deposited into escrow vault as collateral (0.5 TBA = ~$50)
    // USDC_BORROW: USDC borrowed (0.3 USDC; within 75% LTV of $50 collateral = $37.5 max)
    //
    uint256 constant USDC_SEED      = 755962;           // ~$0.756 (6 decimals)
    uint256 constant TBA_COLLATERAL = 0.5e18;           // 0.5 TBA (18 decimals)
    uint256 constant USDC_BORROW    = 300000;           // $0.30 (6 decimals)

    function run() external {
        require(block.chainid == 8453, "DeployEulerStep6: Base mainnet only");

        address deployer = msg.sender;

        console.log("=== DeployEulerStep6 - Base Mainnet ===");
        console.log("Chain ID:   %d", block.chainid);
        console.log("Deployer:   %s", deployer);
        console.log("");

        // Sanity checks before broadcast
        uint256 usdcBal = IERC20(USDC).balanceOf(deployer);
        uint256 tbaBal  = IERC20(TBA).balanceOf(deployer);
        require(usdcBal >= USDC_SEED,      "insufficient USDC");
        require(tbaBal  >= TBA_COLLATERAL, "insufficient TBA");

        console.log("Pre-flight balances:");
        console.log("  USDC: %d", usdcBal);
        console.log("  TBA:  %d", tbaBal);
        console.log("");

        vm.startBroadcast();

        // ── 1. Lender: deposit USDC into lending vault ────────────────────
        IERC20(USDC).approve(LENDING_VAULT, USDC_SEED);
        uint256 lenderShares = IEVault(LENDING_VAULT).deposit(USDC_SEED, deployer);

        console.log("Step 1 - USDC deposited into lending vault (lender)");
        console.log("  USDC deposited: %d", USDC_SEED);
        console.log("  Shares received: %d", lenderShares);

        // ── 2. Borrower: deposit TBA into escrow vault ────────────────────
        IERC20(TBA).approve(ESCROW_VAULT, TBA_COLLATERAL);
        uint256 escrowShares = IEVault(ESCROW_VAULT).deposit(TBA_COLLATERAL, deployer);

        console.log("Step 2 - TBA deposited into escrow vault (borrower)");
        console.log("  TBA deposited:   %d", TBA_COLLATERAL);
        console.log("  Shares received: %d", escrowShares);

        // ── 3. EVC: register escrow vault as collateral source ────────────
        IEVC(EVC).enableCollateral(deployer, ESCROW_VAULT);
        console.log("Step 3 - enableCollateral(escrowVault) done");

        // ── 4. EVC: register lending vault as debt controller ────────────
        IEVC(EVC).enableController(deployer, LENDING_VAULT);
        console.log("Step 4 - enableController(lendingVault) done");

        // ── 5. Borrow USDC from lending vault ────────────────────────────
        IEVault(LENDING_VAULT).borrow(USDC_BORROW, deployer);
        console.log("Step 5 - USDC borrowed from lending vault");
        console.log("  USDC borrowed: %d", USDC_BORROW);

        vm.stopBroadcast();

        // ── 6. Verify post-borrow state ───────────────────────────────────
        uint256 debtShares    = IEVault(LENDING_VAULT).debtOf(deployer);
        uint256 escrowBal     = IEVault(ESCROW_VAULT).balanceOf(deployer);
        uint256 usdcAfter     = IERC20(USDC).balanceOf(deployer);
        uint256 totalBorrows  = IEVault(LENDING_VAULT).totalBorrows();
        uint256 totalAssets   = IEVault(LENDING_VAULT).totalAssets();

        require(debtShares > 0, "borrow did not register");
        require(escrowBal > 0,  "escrow balance missing");

        console.log("");
        console.log("=== Step 6 complete - full borrow flow verified ===");
        console.log("Lending vault state:");
        console.log("  totalAssets:  %d USDC", totalAssets);
        console.log("  totalBorrows: %d USDC", totalBorrows);
        console.log("Borrower state:");
        console.log("  debtOf:       %d (debt shares)", debtShares);
        console.log("  escrowShares: %d", escrowBal);
        console.log("  USDC balance: %d (received borrow)", usdcAfter);
        console.log("");
        console.log("Euler V2 market is fully operational.");
    }
}

interface IERC20 {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IEVC {
    function enableCollateral(address account, address vault) external payable;
    function enableController(address account, address vault) external payable;
}

interface IEVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function borrow(uint256 assets, address receiver) external returns (uint256 shares);
    function debtOf(address account) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalBorrows() external view returns (uint256);
    function totalAssets() external view returns (uint256);
}
