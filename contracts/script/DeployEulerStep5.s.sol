// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DeployEulerStep5 - BASE MAINNET                                         ║
// ║                                                                          ║
// ║  Step 5 of 6: Deploy replacement EulerRouter + USDC lending vault       ║
// ║                                                                          ║
// ║  Why a new EulerRouter?                                                  ║
// ║    The Step 2 router had governance renounced before the escrow vault    ║
// ║    was deployed, so govSetResolvedVault() was never called on it.        ║
// ║                                                                          ║
// ║    When the lending vault checks solvency it calls:                      ║
// ║      oracle.getQuote(shares, escrowVaultAddress, USDC)                  ║
// ║    The router must know that escrowVaultAddress resolves to TBA shares   ║
// ║    (via convertToAssets) before it can price TBA -> USDC. Without       ║
// ║    govSetResolvedVault() this call reverts with PriceOracle_NotSupported.║
// ║                                                                          ║
// ║  This script (in one broadcast):                                         ║
// ║    A. Deploy new EulerRouter, configure it correctly, renounce.         ║
// ║    B. Deploy USDC lending vault pointing at the new router.             ║
// ║       Set IRM, clear hooks, set LTV for TBA escrow, renounce governor.  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

import {Script, console} from "forge-std/Script.sol";

contract DeployEulerStep5 is Script {

    // ── Euler V2 factories on Base mainnet ────────────────────────────────
    address constant EVAULT_FACTORY        = 0x7F321498A801A191a93C840750ed637149dDf8D0;
    address constant ORACLE_ROUTER_FACTORY = 0xA9287853987B107969f181Cce5e25e0D09c1c116;

    // ── Tokens ────────────────────────────────────────────────────────────
    address constant TBA  = 0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    // ── Deployed in earlier steps ─────────────────────────────────────────
    address constant CHAINLINK_ADAPTER = 0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d;
    address constant EULER_IRM         = 0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d;
    address constant ESCROW_VAULT      = 0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4;

    // ── LTV configuration (basis points, 10000 = 100%) ───────────────────
    //
    // borrowLTV (75%): max debt a borrower can take relative to collateral value.
    // liquidationLTV (80%): threshold at which the position becomes liquidatable.
    // Gap of 5pp gives liquidators an incentive window before the vault loses money.
    //
    uint16 constant BORROW_LTV      = 7500;  // 75%
    uint16 constant LIQUIDATION_LTV = 8000;  // 80%

    function run() external {
        require(block.chainid == 8453, "DeployEulerStep5: Base mainnet only");

        address deployer = msg.sender;

        console.log("=== DeployEulerStep5 - Base Mainnet ===");
        console.log("Chain ID:    %d", block.chainid);
        console.log("Deployer:    %s", deployer);
        console.log("");

        vm.startBroadcast();

        // ── Part A: New EulerRouter ───────────────────────────────────────
        //
        // Deploy with deployer as governor so we can configure it, then
        // renounce before we leave this script.

        address newRouter = IEulerRouterFactory(ORACLE_ROUTER_FACTORY).deploy(deployer);

        // 1. Configure TBA -> USDC price route (same as Step 2 router)
        IEulerRouter(newRouter).govSetConfig(TBA, USDC, CHAINLINK_ADAPTER);

        // 2. Register the TBA escrow vault so the router can resolve
        //    escrow vault shares -> TBA amount (via convertToAssets) before
        //    pricing TBA -> USDC. Without this, solvency checks revert with
        //    PriceOracle_NotSupported(escrowVaultAddress, USDC).
        IEulerRouter(newRouter).govSetResolvedVault(ESCROW_VAULT, true);

        // 3. Renounce governance — router is now permanently immutable
        IEulerRouter(newRouter).transferGovernance(address(0));

        console.log("=== Part A: New EulerRouter ===");
        console.log("EULER_ROUTER_V2=%s", newRouter);
        console.log("  govSetConfig:        TBA/USDC -> ChainlinkAdapter");
        console.log("  govSetResolvedVault: escrow vault registered");
        console.log("  governance:          renounced");
        console.log("");

        // ── Part B: USDC Lending Vault ────────────────────────────────────
        //
        // EVK trailingData: abi.encodePacked(asset, oracle, unitOfAccount) = 60 bytes.
        // asset = USDC   (depositors supply USDC, borrowers draw USDC)
        // oracle = newRouter (prices TBA escrow shares -> USDC for solvency checks)
        // unitOfAccount = USDC (all values denominated in USDC)

        bytes memory trailingData = abi.encodePacked(USDC, newRouter, USDC);

        address lendingVault = IEVaultFactory(EVAULT_FACTORY).createProxy(
            address(0),  // accept any implementation
            true,        // upgradeable
            trailingData
        );

        // 1. Set interest rate model (KinkIRM: 0% base | 5% at 80% kink | 100% max)
        IEVault(lendingVault).setInterestRateModel(EULER_IRM);

        // 2. Clear hooked ops (all ops hooked by default post-init; clearing enables
        //    deposit, withdraw, borrow, repay)
        IEVault(lendingVault).setHookConfig(address(0), 0);

        // 3. Accept TBA escrow vault shares as collateral
        IEVault(lendingVault).setLTV(ESCROW_VAULT, BORROW_LTV, LIQUIDATION_LTV, 0);

        // 4. Renounce governance — lending vault is now permanently immutable
        IEVault(lendingVault).setGovernorAdmin(address(0));

        vm.stopBroadcast();

        // ── Verify post-deploy state ──────────────────────────────────────
        address lAsset      = IEVault(lendingVault).asset();
        address lOracle     = IEVault(lendingVault).oracle();
        address lUnit       = IEVault(lendingVault).unitOfAccount();
        address lGovernor   = IEVault(lendingVault).governorAdmin();
        address lIRM        = IEVault(lendingVault).interestRateModel();

        require(lAsset    == USDC,      "lending vault asset mismatch");
        require(lOracle   == newRouter, "lending vault oracle mismatch");
        require(lUnit     == USDC,      "lending vault unitOfAccount mismatch");
        require(lGovernor == address(0),"lending vault governor not renounced");
        require(lIRM      == EULER_IRM, "lending vault IRM mismatch");

        console.log("=== Part B: USDC Lending Vault ===");
        console.log("EULER_LENDING_VAULT=%s", lendingVault);
        console.log("  asset:          %s (USDC)", lAsset);
        console.log("  oracle:         %s (new router)", lOracle);
        console.log("  unitOfAccount:  %s (USDC)", lUnit);
        console.log("  IRM:            %s (KinkIRM)", lIRM);
        console.log("  borrowLTV:      7500 (75%%)");
        console.log("  liquidationLTV: 8000 (80%%)");
        console.log("  governorAdmin:  renounced");
        console.log("");
        console.log("=== Step 5 complete ===");
        console.log("Next: run DeployEulerStep6.s.sol (seed USDC, verify borrow flow)");
    }
}

interface IEulerRouterFactory {
    function deploy(address governor) external returns (address);
}

interface IEulerRouter {
    function govSetConfig(address base, address quote, address oracle) external;
    function govSetResolvedVault(address vault, bool set) external;
    function transferGovernance(address newGovernor) external;
}

interface IEVaultFactory {
    function createProxy(
        address desiredImplementation,
        bool upgradeable,
        bytes memory trailingData
    ) external returns (address);
}

interface IEVault {
    function setInterestRateModel(address newModel) external;
    function setHookConfig(address newHookTarget, uint32 newHookedOps) external;
    function setLTV(address collateral, uint16 borrowLTV, uint16 liquidationLTV, uint32 rampDuration) external;
    function setGovernorAdmin(address newGovernorAdmin) external;
    function asset() external view returns (address);
    function oracle() external view returns (address);
    function unitOfAccount() external view returns (address);
    function governorAdmin() external view returns (address);
    function interestRateModel() external view returns (address);
}
