# Euler V2 Base Mainnet — Step 1: ChainlinkOracle Adapter

Deployed on Base mainnet on 2026-05-19.
This is the first of 6 steps to create a TBA/USDC lending market on Euler V2.

---

## What Step 1 Does

Deploys a `ChainlinkOracle` adapter from the `euler-xyz/euler-price-oracle` library.

This adapter is the price source for TBA in Euler vaults. When a vault needs to know
the value of TBA collateral in USDC, it calls `getQuote(amount, TBA, USDC)` on this
adapter. Internally the adapter calls `NAVFeedForwarder.latestRoundData()`, reads the
8-decimal USD NAV price, and converts it to the correct USDC amount using scale math.

Unlike Morpho (which needed a `MorphoChainlinkOracleV2` wrapper to reformat the price),
Euler's `ChainlinkOracle` accepts `AggregatorV3Interface` feeds directly — our
`NAVFeedForwarder` is plug-in compatible with no additional wrapping.

---

## Parameters Used

| Parameter | Value | Notes |
|---|---|---|
| `base` | `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` | TBA token |
| `quote` | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | USDC |
| `feed` | `0x09907C78D4eB531495962120464BFd9044390337` | NAVFeedForwarder |
| `maxStaleness` | `86400` (24 hours) | Adapter reverts if price older than this |

---

## Deployed Address

| Contract | Address | BaseScan |
|---|---|---|
| **ChainlinkOracle adapter** | **`0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d`** | [view](https://basescan.org/address/0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d) |

---

## Transactions

| Action | Tx hash | Block |
|---|---|---|
| Push fresh NAV price ($100.00) | [0x6c7137d9...](https://basescan.org/tx/0x6c7137d9b2206e112c9888e77b8ebda3691961af638a505228557c4d5f6d5022) | 46195691 |
| Deploy ChainlinkOracle adapter | [0xc4360c37...](https://basescan.org/tx/0xc4360c37ddc86b54bb3df1a0be53023086e88efd2d4fa5cd5cf0f556c9e58383) | — |

---

## Verification

Confirmed `getQuote` returns correct prices in both directions:

```bash
# 1 TBA -> USDC (should be ~$100 = 100000000 in 6-decimal USDC)
cast call 0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d \
  'getQuote(uint256,address,address)(uint256)' \
  1000000000000000000 \
  0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3 \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  --rpc-url https://mainnet.base.org
# Result: 100000000 = $100.00 USDC ✅

# 1 USDC -> TBA (should be 0.01 TBA = 10000000000000000 in 18-decimal TBA)
cast call 0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d \
  'getQuote(uint256,address,address)(uint256)' \
  1000000 \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3 \
  --rpc-url https://mainnet.base.org
# Result: 10000000000000000 = 0.01 TBA ✅
```

---

## Note: OracleAdapterRegistry

The Euler `OracleAdapterRegistry` at `0x3cD76476bB7933A99Fa5bAa05446e71e07CDe0ca` is
owned by the Euler team — we cannot register our adapter there directly.
Registration is optional; it is only for discoverability in Euler tooling.
The adapter functions fully without it.

---

## Step 1 Complete

The oracle adapter is live and price-verified.

**Step 2 — Deploy EulerRouter**
The router dispatches `getQuote` calls to the right adapter per asset pair.
It will be configured to route TBA/USDC queries to the ChainlinkOracle adapter above.
