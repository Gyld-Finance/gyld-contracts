# Euler V2 Base Mainnet — Step 6: Seed and Verify Full Borrow Flow

Deployed on Base mainnet on 2026-05-19.

---

## What Step 6 Does

End-to-end verification of the Euler V2 market. The deployer acts as both
lender and borrower to confirm the full flow works on-chain.

---

## Flow

```
Lender side (deployer):
  USDC.approve(lendingVault, 755962)
  lendingVault.deposit(755962, deployer)  →  755962 shares

Borrower side (deployer):
  TBA.approve(escrowVault, 0.5e18)
  escrowVault.deposit(0.5e18, deployer)   →  500000000000000000 shares
  EVC.enableCollateral(deployer, escrowVault)
  EVC.enableController(deployer, lendingVault)
  lendingVault.borrow(300000, deployer)   →  300000 USDC received
```

---

## Why EVC Calls Are Needed

Euler's EVC (Ethereum Vault Connector) tracks which vaults are authorised to
act as collateral and which are authorised to accrue debt for a given account.

- `enableCollateral(account, escrowVault)` — tells the EVC that shares held in
  the escrow vault can be counted as collateral for this account
- `enableController(account, lendingVault)` — tells the EVC that the lending
  vault is allowed to freeze the account's collateral during solvency checks

Both must be called before `borrow()`. The lending vault's internal solvency
check calls the EVC to verify these registrations exist.

---

## Post-Borrow State (verified on-chain)

| Metric | Value |
|---|---|
| `lendingVault.totalAssets()` | `755962` USDC |
| `lendingVault.totalBorrows()` | `300000` USDC (~40% utilisation) |
| `lendingVault.debtOf(deployer)` | `300000` (debt shares) |
| `escrowVault.balanceOf(deployer)` | `500000000000000000` (0.5 TBA shares) |
| Deployer USDC after borrow | `300000` received |

Utilisation ~40% sits below the 80% kink — borrow APY is in the low-slope
region of the KinkIRM (between 0% and 5%).

---

## Transactions

| Action | Tx hash |
|---|---|
| `USDC.approve(lendingVault)` | [0x4912ecaf...](https://basescan.org/tx/0x4912ecafe9502a238a04e3e286def42862d65996c49f4ac453e77883760b8012) |
| `lendingVault.deposit(USDC)` | [0xde25ea37...](https://basescan.org/tx/0xde25ea37f998d355cb8eba601a3a1a0c664bbcc9a406e515a6d70e5637b68f2f) |
| `TBA.approve(escrowVault)` | [0xd6163cca...](https://basescan.org/tx/0xd6163ccaa2106094cf42680662ad9f5104f9c64ca095231eac3aff64125f32e9) |
| `escrowVault.deposit(TBA)` | [0x838bdad1...](https://basescan.org/tx/0x838bdad1fdd5eba547ed0d8690bef0d024c8f625847207fde0df323c6d7bf3e0) |
| `EVC.enableCollateral(escrowVault)` | [0xe0371d6d...](https://basescan.org/tx/0xe0371d6d142cd03a0b7ac5b3ba2f1078ec1facbccac6d1321d086c0678c404b7) |
| `EVC.enableController(lendingVault)` | [0x9aed99b2...](https://basescan.org/tx/0x9aed99b2f72a1fc7b6db42c241a7e1c21436af550af192da600fcf8478dc463c) |
| `lendingVault.borrow(USDC)` | [0xd0f33df5...](https://basescan.org/tx/0xd0f33df51db90af9e95693c56cbfb3f675ce8acfde40a81fad6354f31dc56e86) |

---

## Euler V2 Deployment Complete

All 6 steps finished. Full contract registry:

| Step | Contract | Address |
|---|---|---|
| 1 | ChainlinkOracle adapter | `0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d` |
| 2 | EulerRouter (retired) | `0xe2Cf003AA0855D035c01c32B1cdEb081f7666428` |
| 3 | KinkIRM | `0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d` |
| 4 | TBA Escrow Vault | `0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4` |
| 5a | EulerRouter V2 (active) | `0xBD8535B344293e96C0eFE7E9224aB54CE880471E` |
| 5b | USDC Lending Vault | `0xCF8930030FbA9c8599A534304B94972762d79F71` |

The market is live and operational on Base mainnet. Lenders can deposit USDC,
borrowers can deposit TBA as collateral and draw USDC, and the KinkIRM
accrues interest on outstanding borrows.
