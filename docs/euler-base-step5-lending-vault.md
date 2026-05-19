# Euler V2 Base Mainnet — Step 5: New EulerRouter + USDC Lending Vault

Deployed on Base mainnet on 2026-05-19.

---

## What Step 5 Does

Two things in one broadcast:

**Part A — Replacement EulerRouter**
The Step 2 router had `govSetResolvedVault()` missing because governance was
renounced before the escrow vault existed. Without this registration, solvency
checks on the lending vault would always revert — the oracle can't price escrow
vault shares unless it knows to "resolve" them through to TBA first.

A new router is deployed with the correct full configuration before governance
is renounced.

**Part B — USDC Lending Vault**
An EVault where lenders deposit USDC and earn interest. Borrowers lock TBA in
the escrow vault (Step 4) and draw USDC from this vault, paying the KinkIRM
borrow rate.

---

## Why govSetResolvedVault Matters

When the lending vault checks if a borrower is solvent, the EVK calls:

```
oracle.getQuote(shares, escrowVaultAddress, USDC)
```

The `escrowVaultAddress` is NOT the TBA token address — it is the vault contract
itself. The EulerRouter must know this address is a vault whose shares resolve to
an underlying token. With `govSetResolvedVault(escrowVault, true)` registered, the
router:

1. Calls `escrowVault.convertToAssets(shares)` → TBA amount
2. Then prices TBA → USDC via the ChainlinkOracle adapter

Without it: `revert PriceOracle_NotSupported(escrowVaultAddress, USDC)`.

---

## LTV Configuration

| Parameter | Value | Meaning |
|---|---|---|
| `borrowLTV` | `7500` (75%) | Max USDC a borrower can draw per $1 of TBA collateral |
| `liquidationLTV` | `8000` (80%) | LTV at which the position can be liquidated |
| Gap | 5 pp | Liquidator profit window — incentivises timely liquidation |

Bond token TBA has a stable NAV (~$100), so 75% borrow LTV is conservative.

---

## Deployed Addresses

| Contract | Address | BaseScan |
|---|---|---|
| **EulerRouter V2** | **`0xBD8535B344293e96C0eFE7E9224aB54CE880471E`** | [view](https://basescan.org/address/0xBD8535B344293e96C0eFE7E9224aB54CE880471E) |
| **USDC Lending Vault** | **`0xCF8930030FbA9c8599A534304B94972762d79F71`** | [view](https://basescan.org/address/0xCF8930030FbA9c8599A534304B94972762d79F71) |

Lending vault post-deploy state (verified on-chain):

| Property | Value |
|---|---|
| `asset()` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC) |
| `oracle()` | `0xBD8535B344293e96C0eFE7E9224aB54CE880471E` (EulerRouter V2) |
| `unitOfAccount()` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` (USDC) |
| `interestRateModel()` | `0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d` (KinkIRM) |
| `governorAdmin()` | `address(0)` — renounced |

---

## Transactions

| Action | Tx hash |
|---|---|
| Deploy EulerRouter V2 | [0x885f24dd...](https://basescan.org/tx/0x885f24dda4469358321fba8211cc1c61054bb40ff6d7b088a46e8afda6a4be06) |
| `govSetConfig(TBA, USDC, adapter)` | [0x6e552a73...](https://basescan.org/tx/0x6e552a73dd62d4166e243212c4dcd9a165ea9309613fbb39db3c3950fed8a7e2) |
| `govSetResolvedVault(escrowVault, true)` | [0x7fb81d5d...](https://basescan.org/tx/0x7fb81d5d365278454003bd07aa0ab4c63ddd71f9c70e924bdc83f8b1b1bcfda8) |
| `transferGovernance(address(0))` | [0x35eccb25...](https://basescan.org/tx/0x35eccb25284bd782b51fabaa14b90cb67859a87b51a33b7c88d797f47f420381) |
| Deploy USDC lending vault | [0xf1fe3a76...](https://basescan.org/tx/0xf1fe3a760e2b3381161246708768a4c0d97610899dd97dfe9d3d2ba2ad1acb04) |
| `setInterestRateModel(KinkIRM)` | [0x0ac0e768...](https://basescan.org/tx/0x0ac0e76848a4c66fe94154dd08b17ae1cb3efdfcbae56baf1387d54b52df01ea) |
| `setHookConfig(address(0), 0)` | [0x0af7685e...](https://basescan.org/tx/0x0af7685e1658eb94dabd7b5d9100849fd8a8127a0403eff2b3c7ed046b8d5a44) |
| `setLTV(escrowVault, 7500, 8000, 0)` | [0x9b161e60...](https://basescan.org/tx/0x9b161e607c91d2e16a9773a8938a1701fe59cd85e528b99a52dfa6fa5cd5c0b7) |
| `setGovernorAdmin(address(0))` | [0x7d8db020...](https://basescan.org/tx/0x7d8db02039f4e606724bd21a7047d6367b5a703f8f6d00e9e79c31fe4244c9ef) |

---

## Step 5 Complete

All five infrastructure contracts are now deployed:

| Step | Contract | Address |
|---|---|---|
| 1 | ChainlinkOracle adapter | `0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d` |
| 2 | EulerRouter (retired — missing govSetResolvedVault) | `0xe2Cf003AA0855D035c01c32B1cdEb081f7666428` |
| 3 | KinkIRM | `0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d` |
| 4 | TBA Escrow Vault | `0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4` |
| 5a | EulerRouter V2 (active) | `0xBD8535B344293e96C0eFE7E9224aB54CE880471E` |
| 5b | USDC Lending Vault | `0xCF8930030FbA9c8599A534304B94972762d79F71` |

**Step 6 — Seed and verify**
Supply USDC to the lending vault, deposit TBA into the escrow vault, enable
collateral via EVC, borrow USDC, confirm the full flow works end-to-end.
