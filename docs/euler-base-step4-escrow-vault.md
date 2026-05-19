# Euler V2 Base Mainnet — Step 4: Escrowed Collateral Vault (TBA)

Deployed on Base mainnet on 2026-05-19.

---

## What Step 4 Does

Deploys an EVault in "escrow mode" for TBA tokens.

This vault accepts TBA deposits but cannot lend. Users deposit TBA here to obtain
vault shares, which they then use as collateral to borrow USDC from the lending
vault (Step 5). Because the vault never lends TBA out, depositors bear no
counterparty risk from borrowers.

---

## Why oracle = address(0)

An escrow vault does not need an oracle at the vault level. Oracle lookups happen
in the **lending vault** when it needs to price the collateral. The lending vault
will call `EulerRouter.getQuote(TBA → USDC)` — the oracle and unitOfAccount are
configured in the **lending vault's** proxy metadata, not in the escrow vault.

Passing `address(0)` for both oracle and unitOfAccount is the correct EVK pattern
for a collateral-only vault, verified against Euler V2 source (`Initialize.sol`).

---

## Key Discovery: Correct trailingData Format

The EVK `createProxy()` requires **60-byte trailingData**:

```
abi.encodePacked(address asset, address oracle, address unitOfAccount)
```

The factory prepends `bytes4(0)` making the proxy store 64 bytes
(`= PROXY_METADATA_LENGTH`). Passing only 40 bytes (oracle + unitOfAccount)
triggers `E_ProxyMetadata()` at initialization — the `asset` field comes first
and must be non-zero.

---

## Deployed Address

| Contract | Address | BaseScan |
|---|---|---|
| **TBA Escrow Vault** | **`0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4`** | [view](https://basescan.org/address/0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4) |

Post-deploy state (verified on-chain):

| Property | Value |
|---|---|
| `asset()` | `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` (TBA) |
| `oracle()` | `address(0)` — collateral-only, no pricing |
| `unitOfAccount()` | `address(0)` — collateral-only, no pricing |
| `governorAdmin()` | `address(0)` — governance renounced |

---

## Transactions

| Action | Tx hash | Block |
|---|---|---|
| `createProxy()` — deploy escrow vault | [0x7129e655...](https://basescan.org/tx/0x7129e655339f71071f829b8610d351c5ee193de5432eb81e34709a35b34c1dff) | — |
| `setHookConfig(address(0), 0)` — clear hooked ops | [0x3fab7b01...](https://basescan.org/tx/0x3fab7b016cbca1ff1ba7d1b58f0821ed9b875dfef389e99469af9f808cfa282b) | — |
| `setGovernorAdmin(address(0))` — renounce governance | [0xb5ead05b...](https://basescan.org/tx/0xb5ead05bc9a1dd2790d0ec4575bf6a197ae1253452cd2105ae041d0a7ac2c7ff) | — |

---

## Note: Governance Is Permanently Renounced

The vault is configured and governance renounced in a single script run. The
`setGovernorAdmin(address(0))` call is the last transaction. After this, no one
can change the vault's configuration — it is permanently immutable.

`EscrowedCollateralPerspective` at `0x977590fA311755DA2fa1421c1A944520b684f90F`
enforces this: it requires `upgradeable=true`, zero governor, and cleared hooked
ops before it will recognise this vault as valid collateral in any lending vault.

---

## Step 4 Complete

Four infrastructure contracts are now deployed:

| Step | Contract | Address |
|---|---|---|
| 1 | ChainlinkOracle adapter | `0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d` |
| 2 | EulerRouter (immutable) | `0xe2Cf003AA0855D035c01c32B1cdEb081f7666428` |
| 3 | KinkIRM (immutable) | `0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d` |
| 4 | TBA Escrow Vault (immutable) | `0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4` |

**Step 5 — Deploy USDC lending vault**
This vault holds USDC supplied by lenders. Borrowers post TBA escrow shares as
collateral and borrow USDC from this vault. The KinkIRM determines the borrow rate.
