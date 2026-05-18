# Base Mainnet Deployment — Step 2: Oracle Setup

NAV price pushed and `MorphoChainlinkOracleV2` deployed on Base mainnet (chain ID 8453) on 2026-05-18.
This oracle is the `oracle` parameter for `createMarket()` in Step 3.

---

## Deployed addresses

| Contract | Address | BaseScan |
|---|---|---|
| Deployer wallet | `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd` | [view](https://basescan.org/address/0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd) |
| KaleidoscopeNAVFeed (TBA) | `0xC69e88136D52D0ADb911F03A2E71d374cA668DeC` | [view](https://basescan.org/address/0xC69e88136D52D0ADb911F03A2E71d374cA668DeC) |
| NAVFeedForwarder (TBA) | `0x09907C78D4eB531495962120464BFd9044390337` | [view](https://basescan.org/address/0x09907C78D4eB531495962120464BFd9044390337) |
| **MorphoChainlinkOracleV2 (TBA/USDC)** | **`0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A`** | [view](https://basescan.org/address/0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A) |

### External contracts used (not deployed by us)

| Contract | Address | Purpose |
|---|---|---|
| MorphoChainlinkOracleV2Factory | `0x2DC205F24BCb6B311E5cdf0745B0741648Aebd3d` | Creates oracle via `CREATE2` |
| Chainlink USDC/USD feed | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | Quote-side price (6-decimal token) |

---

## Actions

### 2a — Push NAV price

Called `updateAnswer(int256)` on the `KaleidoscopeNAVFeed` to set the initial TBA NAV.

| Field | Value |
|---|---|
| Contract | `0xC69e88136D52D0ADb911F03A2E71d374cA668DeC` |
| Function | `updateAnswer(int256)` |
| Argument | `10000000000` ($100.00 in 8-decimal Chainlink format) |
| Caller | `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd` |
| Tx | [0x7b0ae454...](https://basescan.org/tx/0x7b0ae4548fd32a1bd6bdc148f5b1ab07df8fb89b05b9cdf673b347178d579d0c) |
| Block | 46,154,905 |
| Gas used | 92,117 |

```bash
cast send 0xC69e88136D52D0ADb911F03A2E71d374cA668DeC \
  'updateAnswer(int256)' 10000000000 \
  --rpc-url $BASE_RPC --private-key $PRIVKEY
# 10000000000 = $100.00 in 8-decimal Chainlink format
```

---

### 2b — Verify price through Forwarder

Called `latestRoundData()` on the `NAVFeedForwarder` to confirm the price propagated correctly.

| Field | Value |
|---|---|
| Contract | `0x09907C78D4eB531495962120464BFd9044390337` |
| Function | `latestRoundData()` |
| Result | `roundId=1`, `answer=10000000000` ✅ |

```bash
cast call 0x09907C78D4eB531495962120464BFd9044390337 \
  'latestRoundData()(uint80,int256,uint256,uint256,uint80)' \
  --rpc-url $BASE_RPC
# expected: 1, 10000000000, ...
```

---

### 2c — Deploy MorphoChainlinkOracleV2

Deployed the oracle wrapper via the Morpho factory. This wraps the NAVFeedForwarder (base) and
the Chainlink USDC/USD feed (quote) into the `price()` format Morpho Blue expects.

| Field | Value |
|---|---|
| Factory | `0x2DC205F24BCb6B311E5cdf0745B0741648Aebd3d` |
| Tx | [0x2ba0506d...](https://basescan.org/tx/0x2ba0506de2c313a79c8f7c21ea018e3c18a3e6cd8f75027a341c9e035e539fc5) |
| Block | 46,154,914 |
| Gas used | 620,794 |
| **Deployed oracle** | **`0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A`** |

**Constructor parameters:**

| Parameter | Value | Notes |
|---|---|---|
| `baseVault` | `address(0)` | No ERC-4626 vault on base side |
| `baseVaultConversionSample` | `1` | Unused (no vault) |
| `baseFeed1` | `0x09907C78D4eB531495962120464BFd9044390337` | NAVFeedForwarder — TBA/USD, 18-decimal token |
| `baseFeed2` | `address(0)` | No second base feed |
| `baseTokenDecimals` | `18` | TBA is 18 decimals |
| `quoteVault` | `address(0)` | No ERC-4626 vault on quote side |
| `quoteVaultConversionSample` | `1` | Unused (no vault) |
| `quoteFeed1` | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` | Chainlink USDC/USD — 6-decimal token |
| `quoteFeed2` | `address(0)` | No second quote feed |
| `quoteTokenDecimals` | `6` | USDC is 6 decimals |
| `salt` | `bytes32(0)` | Default salt |

---

### 2d — Verify price()

Called `price()` on the deployed oracle to confirm the output is in range.

| Field | Value |
|---|---|
| Contract | `0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A` |
| Function | `price()(uint256)` |
| Result | `100027005290888434059427364` ✅ |

```bash
cast call 0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A \
  'price()(uint256)' \
  --rpc-url $BASE_RPC
# expected: ~100 × 10^24
```

**Why the result is not exactly 100 × 10²⁴:**

The oracle divides the base price (TBA/USD = $100.00) by the quote price (USDC/USD = $0.9997).
Because USDC trades slightly below $1.00, the oracle correctly adjusts upward:

```
price() = (TBA_USD / USDC_USD) × 10^(36 + quoteDecimals − baseDecimals)
        = (100 / 0.9997) × 10^(36 + 6 − 18)
        = 100.027 × 10^24
        ≈ 100027005290888434059427364  ✅
```

This is the expected and correct behaviour.

---

## Gas summary

| Action | Block | Gas used |
|---|---|---|
| 2a — updateAnswer | 46,154,905 | 92,117 |
| 2c — deploy oracle | 46,154,914 | 620,794 |
| **Total** | | **712,911** |

---

## Step 2 complete — what's next

Step 2 is done. The `MorphoChainlinkOracleV2` at `0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A`
is ready to use as the `oracle` parameter in `createMarket()`.

**Step 3 — `createMarket()`** on Morpho Blue `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`
with the following `MarketParams`:

| Parameter | Value |
|---|---|
| `loanToken` | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `collateralToken` | TOKEN_TBA `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` |
| `oracle` | `0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A` |
| `irm` | Adaptive Curve IRM `0x46415998764C29aB2a25CbeA6254146D50D22687` |
| `lltv` | To be decided (e.g. `770000000000000000` for 77%) |

**Step 4 — seed + share link** `https://app.morpho.org/base/market/0x{MARKET_ID}`.
