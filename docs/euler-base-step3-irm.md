# Euler V2 Base Mainnet — Step 3: KinkIRM

Deployed on Base mainnet on 2026-05-19.

---

## What Step 3 Does

Deploys an `IRMLinearKink` (interest rate model) via the `kinkIRMFactory`.

The IRM determines how the borrow APY changes with utilisation in the USDC lending vault.
It is a piecewise-linear curve with two slopes that meet at a "kink" point.

---

## Rate Curve Chosen

Conservative parameters suitable for a bond token collateral market:

| Utilisation | Borrow APY |
|---|---|
| 0% | 0% |
| 80% (kink) | 5% |
| 100% (max) | 100% |

**Why these values:**
- 0% base rate — lenders earn nothing when no one is borrowing (normal)
- 5% at 80% kink — reasonable yield for USDC lenders at normal utilisation
- 100% at max — extreme rate deters the pool from being fully drained; incentivises repayment

---

## Raw Parameters

All rates are in SPY (Second Percent Yield) format scaled by 1e27.
Formula: `rate = ln(1 + APY) / 31,556,952 * 1e27` (continuous compounding)
`kink` is `uint32` where `type(uint32).max = 100%` utilisation.

| Parameter | Value | Human meaning |
|---|---|---|
| `baseRate` | `0` | 0% APY at 0% utilisation |
| `slope1` | `449,973,958` | Rate increase per utilisation unit below kink |
| `slope2` | `23,770,682,707` | Rate increase per utilisation unit above kink |
| `kink` | `3,435,973,836` | 80% utilisation (`floor(0.80 * 2^32)`) |

Values verified using Euler's official `calculate-irm-linear-kink.js` utility.

---

## Deployed Address

| Contract | Address | BaseScan |
|---|---|---|
| **KinkIRM** | **`0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d`** | [view](https://basescan.org/address/0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d) |

---

## Transaction

| Action | Tx hash | Block |
|---|---|---|
| Deploy KinkIRM via factory | [0xdda2bab0...](https://basescan.org/tx/0xdda2bab0117e92a939bcfdb64e0c4676d1d0ebb6c7b368dfbe1e1a40be860315) | 46,197,616 |

---

## Note: IRM Is Immutable

The IRM is deployed as a standalone immutable contract. Parameters cannot be changed
after deployment. The factory stores deployment metadata (`deployer`, `deployedAt`)
and emits `ContractDeployed(irm, deployer, timestamp)` for indexing.

---

## Step 3 Complete

The three infrastructure contracts are now deployed:

| Step | Contract | Address |
|---|---|---|
| 1 | ChainlinkOracle adapter | `0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d` |
| 2 | EulerRouter (immutable) | `0xe2Cf003AA0855D035c01c32B1cdEb081f7666428` |
| 3 | KinkIRM (immutable) | `0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d` |

**Step 4 — Deploy escrowed collateral vault for TBA**
This vault holds TBA tokens as collateral. Users deposit TBA here, then use it
to borrow USDC from the lending vault in Step 5.
