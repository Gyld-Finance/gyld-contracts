# Morpho Blue Integration — GyldBondToken

Complete record covering Sepolia compatibility testing, Base mainnet deployment,
UI listing paths, and protocol comparison with Euler V2.

Deployer: `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd`

---

## Table of Contents

1. [What Is Morpho Blue](#1-what-is-morpho-blue)
2. [Protocol Addresses](#2-protocol-addresses)
3. [Oracle Architecture](#3-oracle-architecture)
4. [Sepolia Compatibility Test](#4-sepolia-compatibility-test)
5. [Base Mainnet Deployment](#5-base-mainnet-deployment)
6. [UI Listing — Path A vs Path B](#6-ui-listing--path-a-vs-path-b)
7. [Borrow Flow Reference](#7-borrow-flow-reference)
8. [Comparison with Euler V2](#8-comparison-with-euler-v2)
9. [Audit Notes](#9-audit-notes)

---

## 1. What Is Morpho Blue

Morpho Blue is a permissionless lending protocol where anyone can create an
isolated lending market in a single `createMarket()` call — no approval from
Morpho, no governance vote. Each market is defined by five immutable parameters
baked in at creation: loan token, collateral token, oracle, IRM, LLTV.

Key properties:
- **Strictly isolated** — each market is independent, no shared liquidity
- **Single call** — one `createMarket()` creates a fully functional market
- **Instant UI** — every market appears on `app.morpho.org` immediately
- **Oracle format** — requires `price()` returning 1e36-scaled output
  (NAVFeedForwarder must be wrapped in `MorphoChainlinkOracleV2`)
- **IRM** — uses pre-deployed `AdaptiveCurveIRM`; no custom IRM deployment needed

---

## 2. Protocol Addresses

### Ethereum Sepolia (testing)

| Contract | Address |
|---|---|
| Morpho Blue | `0xd011EE229E7459ba1ddd22631eF7bF528d424A14` |
| AdaptiveCurveIRM | `0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c` |
| MorphoChainlinkOracleV2Factory | `0xa6c843fc53aAf6EF1d173C4710B26419667bF6CD` |
| USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Chainlink USDC/USD feed (working) | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` |

> Note: `0xf08A50178dfcDe18524640EA6618a1f965821715` (from Morpho deployment files)
> is inactive on Sepolia — `latestRoundData()` reverts. Use `0xA2F78ab2355...` above.

### Base Mainnet (production test)

| Contract | Address |
|---|---|
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| AdaptiveCurveIRM | `0x46415998764C29aB2a25CbeA6254146D50D22687` |
| MorphoChainlinkOracleV2Factory | `0x2DC205F24BCb6B311E5cdf0745B0741648Aebd3d` |
| VaultV2Factory | `0x4501125508079A99ebBebCE205DeC9593C2b5857` |
| MorphoMarketV1AdapterV2Factory | `0x9a1B378C43BA535cDB89934230F0D3890c51C0EB` |
| AdapterRegistry | `0x5C2531Cbd2cf112Cf687da3Cd536708aDd7DB10a` |
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Chainlink USDC/USD feed | `0x7e860098F58bBFC8648a4311b374B1D669a2bc6B` |

### Our Deployed Contracts (Base Mainnet)

| Contract | Address | BaseScan |
|---|---|---|
| TOKEN_TBA (GyldBondToken proxy) | `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` | [view](https://basescan.org/address/0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3) |
| KaleidoscopeNAVFeed (TBA) | `0xC69e88136D52D0ADb911F03A2E71d374cA668DeC` | [view](https://basescan.org/address/0xC69e88136D52D0ADb911F03A2E71d374cA668DeC) |
| NAVFeedForwarder (TBA) | `0x09907C78D4eB531495962120464BFd9044390337` | [view](https://basescan.org/address/0x09907C78D4eB531495962120464BFd9044390337) |
| IssuanceManager (proxy) | `0x5BA267367f06378816c58d47C5850fC9863Ce67F` | [view](https://basescan.org/address/0x5BA267367f06378816c58d47C5850fC9863Ce67F) |
| TimelockController (delay=0) | `0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72` | [view](https://basescan.org/address/0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72) |
| TokenFactory | `0x18Ce55785bD24Dd096dAC11111168B1E94A76317` | [view](https://basescan.org/address/0x18Ce55785bD24Dd096dAC11111168B1E94A76317) |
| **MorphoChainlinkOracleV2 (TBA/USDC)** | **`0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A`** | [view](https://basescan.org/address/0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A) |
| Chainalysis sanctions oracle (Base official) | `0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B` | [view](https://basescan.org/address/0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B) |

### Live Market

| | |
|---|---|
| **Market URL** | **https://app.morpho.org/base/market/0x9840633fea7b077c2efac0f819ccef9fa69e2641844fcc749e756cafb0bfd453** |
| Market ID | `0x9840633fea7b077c2efac0f819ccef9fa69e2641844fcc749e756cafb0bfd453` |
| Loan token | USDC |
| Collateral token | TBA |
| LLTV | 86% |

---

## 3. Oracle Architecture

Morpho requires a custom `price()` function returning 1e36-scaled output.
NAVFeedForwarder implements `AggregatorV3Interface` (`latestRoundData()`), which
is a different format. A `MorphoChainlinkOracleV2` wrapper bridges the gap.

```
NAVFeedForwarder (AggregatorV3Interface, 8-decimal USD NAV)
  └─ MorphoChainlinkOracleV2
       ├─ baseFeed1:      NAVFeedForwarder  (TBA/USD)
       ├─ baseDecimals:   18  (TBA token decimals)
       ├─ quoteFeed1:     Chainlink USDC/USD feed
       ├─ quoteDecimals:  6   (USDC token decimals)
       └─ price()  →  ~100 × 10^24  (Morpho's 1e36 format)
             └─ Morpho Blue market oracle
```

**Price formula:** `(TBA/USD) / (USDC/USD) × 10^(36 + quoteDecimals - baseDecimals)`
= `100 / 1 × 10^(36 + 6 - 18)` = `100 × 10^24`

**Critical parameters:**
- `baseVaultConversionSample = 1` — required when no vault is used; `0` causes a revert
- `quoteVaultConversionSample = 1` — same reason
- All vault and feed2 fields = `address(0)`

**Verify after deploy:**
```bash
cast call $MORPHO_ORACLE "price()(uint256)" --rpc-url $BASE_RPC
# Expected: ~100000000000000000000000000  (100 × 10^24)
```

---

## 4. Sepolia Compatibility Test

Completed 2026-05-14 to 2026-05-15. Proved the full pipeline before mainnet.

### Sepolia Deployed Contracts

| Contract | Address |
|---|---|
| TimelockController (delay=0) | `0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72` |
| IssuanceManager (proxy) | `0x5BA267367f06378816c58d47C5850fC9863Ce67F` |
| TokenFactory | `0xb11BdcFE08c69c461F410453BdF80A8cb9Cd07aE` |
| MockSanctionsList | `0x7C1798643e0793EAB998B777b2CD0B7c2F2870Ad` |
| TOKEN_CAT proxy (Caterpillar) | `0xC545645b889027F5C2e7c1460566B08673273B07` |
| NAVFEED_CAT | `0x0e21b8E3D40d92244a07977905c056EBF5f88DDE` |
| FORWARDER_CAT | `0xDcBd2c177212aebD18e8F1429457483644C50C00` |
| MorphoChainlinkOracleV2 | `0xeB66EB06EE848d9cF587EB1EeA3d11b0992cbd98` |
| Morpho Market ID | `0x987fa2f626c00d51e4faf314d524cc034e1743e1d783368a8b3584cd6d40dcc9` |

### Step 1 — Deploy contracts (2026-05-14) ✅

All contracts deployed including TimelockController, IssuanceManager, TokenFactory,
MockSanctionsList, and three test bond tokens (TOKEN_CAT, TOKEN_C, TOKEN_KO).
All roles wired, deployer wallet whitelisted as subscriber.

### Step 2 — Mint test tokens (2026-05-14) ✅

| Tx | Action |
|---|---|
| [0x1ae962d2...](https://sepolia.etherscan.io/tx/0x1ae962d2408ebf004e5c9186c8e740a42ead8507ec88d3ee9e0d3821a898b14c) | `IssuanceManager.subscribe(TOKEN_CAT, wallet, 1_000_000e18)` |

### Step 3 — Push NAV price (2026-05-15) ✅

| Tx | Action |
|---|---|
| [0xbe60a8dd...](https://sepolia.etherscan.io/tx/0xbe60a8ddf90f9e9163e886cbb46fb37569e5eb240bb02bb912e60d9481474b4b) | `NAVFEED_CAT.updateAnswer(10000000000)` — $100.00 in 8-decimal format |

### Step 4 — Deploy MorphoChainlinkOracleV2 (2026-05-15) ✅

| Tx | Address |
|---|---|
| [0x7bbf0ed9...](https://sepolia.etherscan.io/tx/0x7bbf0ed9c7701e475fd5a1b774528cc304b1108b84c7c1ad66faf195d6f54663) | `0xeB66EB06EE848d9cF587EB1EeA3d11b0992cbd98` |

`price()` result: `100027007291968831584527822` ≈ 100 × 10^24 ✅

```bash
cast send $ORACLE_FACTORY \
  "createMorphoChainlinkOracleV2(address,uint256,address,address,uint256,address,uint256,address,address,uint256,bytes32)" \
  "0x0000000000000000000000000000000000000000" 1 \
  $FORWARDER_CAT \
  "0x0000000000000000000000000000000000000000" 18 \
  "0x0000000000000000000000000000000000000000" 1 \
  $CHAINLINK_USDC_USD \
  "0x0000000000000000000000000000000000000000" 6 \
  "0x0000000000000000000000000000000000000000000000000000000000000000" \
  --rpc-url $RPC --private-key $PRIVKEY
```

### Step 5 — Create market (2026-05-15) ✅

| Tx | Market ID |
|---|---|
| [0x4317a0ea...](https://sepolia.etherscan.io/tx/0x4317a0ea49887cc40ff9be8b9312a6b1f4856add7ff3a671cc4277a0788bd7a2) | `0x987fa2f626c0...d6d40dcc9` |

```bash
cast send $MORPHO \
  "createMarket((address,address,address,address,uint256))" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  --rpc-url $RPC --private-key $PRIVKEY
```

### Step 6 — Supply USDC as lender (2026-05-15) ✅

Supplied 20 USDC (full faucet balance).

| Tx | Action |
|---|---|
| [0x0f805069...](https://sepolia.etherscan.io/tx/0x0f805069c8b3a4aaeb5e6bca9ca1da7947a0d98b8a44dc43b12bef3b3998adc5) | `USDC.approve(morpho, 20000000)` |
| [0x480374ff...](https://sepolia.etherscan.io/tx/0x480374ffad1ced6bf9a0ee03f6a52b407bb7071dbbe9197d91f678e79d880113) | `Morpho.supply(params, 20000000, 0, wallet, 0x)` |

### Step 7 — Supply GYLD as collateral (2026-05-15) ✅

Supplied 0.1 GYLD (~$11 at $110 NAV). Tests that Morpho can `transferFrom` on
GyldBondToken — i.e., Morpho's address passes the Chainalysis sanctions check.

| Tx | Action |
|---|---|
| [0xd138fcfe...](https://sepolia.etherscan.io/tx/0xd138fcfe6238885d1a80b1c1526f5452554869968f67d591bd16017103ab5ed7) | `TOKEN_CAT.approve(morpho, 0.1e18)` |
| [0x0a737fee...](https://sepolia.etherscan.io/tx/0x0a737feeadd56d8a74660965ade2574ffe0ff941428d9152f05d721019940d19) | `Morpho.supplyCollateral(params, 0.1e18, wallet, 0x)` |

### Step 8 — Borrow USDC (2026-05-15) ✅

0.1 GYLD × $110 NAV × 86% LLTV = $9.46 max borrow.
Over-borrow tested first to confirm LLTV enforcement.

| Tx | Amount | Result |
|---|---|---|
| (gas estimation failed) | 10 USDC | Reverted — `insufficient collateral` ✅ |
| [0x7b0d771a...](https://sepolia.etherscan.io/tx/0x7b0d771aa5846b86cf9b62cd9f631b793f4a9f335f4804e11d873af38af6f722) | 9 USDC | Success ✅ |

### Step 9 — Repay + partial withdraw (2026-05-15) ✅

Partial round-trip to prove position management. Remaining position (4.5 USDC debt,
0.048 GYLD collateral) left open intentionally for the pause test.

| Tx | Action |
|---|---|
| [0xd7dfc3d2...](https://sepolia.etherscan.io/tx/0xd7dfc3d21f4447b65179ccd5e72d885c66782b71d266a0043cc1959825f0d0a0) | `USDC.approve(morpho, 4500000)` |
| [0x24a0d8f1...](https://sepolia.etherscan.io/tx/0x24a0d8f1967083f8619e5fac0c4ac869dfc5c79324f39afa34c235ca6c5c6dff) | `Morpho.repay(params, 4500000, 0, wallet, 0x)` |
| [0x68903a9a...](https://sepolia.etherscan.io/tx/0x68903a9a75ff0e32f7f5109812e09a76c815afef678199facd3a5b007985d706) | `Morpho.withdrawCollateral(params, 52000000000000000, wallet, wallet)` |

Interest observed: 37 units ($0.000037) accrued during test session.
Rounding note: withdrawing exact-max collateral (`52443742177484144`) reverted —
Morpho's rounding is stricter than computed. Use a slightly lower value.

### Step 10 — Pause test ✅

Pause blocks all Morpho interactions including liquidations (expected, intentional).

```bash
cast send $TOKEN_CAT "pause()" --rpc-url $RPC --private-key $PRIVKEY
# Morpho.supplyCollateral now reverts with EnforcedPause()
cast send $TOKEN_CAT "unpause()" --rpc-url $RPC --private-key $PRIVKEY
# Operations resume normally
```

### What Each Step Proves

| Step | Passes if | Fails if |
|---|---|---|
| Deploy | All contracts live, roles wired | Script error or missing env vars |
| Push NAV | Price flows through NAVFeedForwarder | Feed not 8-decimal or wrong format |
| Deploy oracle | `price()` returns ~100 × 10^24 | Wrong decimals or stale price |
| createMarket | Morpho accepted params | Wrong address or IRM not enabled |
| supplyCollateral | Morpho can `transferFrom` GYLD | Sanctions oracle rejects Morpho's address |
| borrow | Oracle priced collateral correctly | Wrong price format → wrong borrow limit |
| round trip | No accounting corruption | State bug in token or Morpho integration |
| pause | Pause blocks all Morpho ops | Unexpected behaviour during emergency |

---

## 5. Base Mainnet Deployment

Deployed 2026-05-18. Three steps.

### Step 1 — Token Stack (2026-05-18) ✅

All 13 transactions landed in block **46,154,075**.

| Tx | Action |
|---|---|
| [0x67b3f266...](https://basescan.org/tx/0x67b3f266bceeecefb648d9877fc5e4d05186f403e71c151b580d83975315f697) | Deploy TimelockController |
| [0x5d7d8702...](https://basescan.org/tx/0x5d7d8702601c87e584ca1fca58d672d7fd70b80ab09734195c727cefc4d03b96) | Deploy IssuanceManager logic |
| [0x70cccf12...](https://basescan.org/tx/0x70cccf12a5c2d86df3cb06605fdaa6d77bc6be33b55b75abbb81449e39991add) | Deploy IssuanceManager proxy |
| [0x93de3a37...](https://basescan.org/tx/0x93de3a37de8a2ff0f43b50f01dbda06b7a63a90470deb062aee3a2a349c27504) | Grant roles on IssuanceManager |
| [0xd425600a...](https://basescan.org/tx/0xd425600abc63dc8241d25978c69a3fde87055753ea5cd7fe941fe113735706fa) | Deploy GyldBondToken logic |
| [0x125ef161...](https://basescan.org/tx/0x125ef1611e08464d2712f7b1e7fdefa91e60f8aa1efe0f5f979f0a88ddcf24a9) | Deploy TokenFactory |
| [0x7a3175e5...](https://basescan.org/tx/0x7a3175e50253dd39427a737f795f411f93f4c6f65704f9a611222a3a63783e53) | Wire IssuanceManager roles + whitelist deployer |
| [0x55d9d30b...](https://basescan.org/tx/0x55d9d30b17b3583277f87710ece16d3d9cdc77453067fdcdc7fa1baba42f2242) | Transfer factory ownership to timelock |

Token metadata (test/dummy):

| Field | Value |
|---|---|
| Name | Test Bond Alpha |
| Symbol | TBA |
| ISIN | US000000TBA0 (fake) |
| Maturity | 2030-01-01 |
| Decimals | 18 |

### Step 2 — Oracle (2026-05-18) ✅

Pushed NAV price and deployed `MorphoChainlinkOracleV2`.

| Tx | Action |
|---|---|
| Push NAV $100.00 | `KaleidoscopeNAVFeed.updateAnswer(10000000000)` |
| [0x62acda39...](https://basescan.org/tx/0x62acda394a0d5640fc73a3e22c25c0a5399fda7e8fb40d7c44c24bef7e2d8e64) | Deploy MorphoChainlinkOracleV2 |

Oracle address: `0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A`

### Step 3 — createMarket + Seed (2026-05-18) ✅

Pre-seeding: minted 2 TBA via `IssuanceManager.subscribe()`, swapped 0.0005 ETH → 1.057 USDC via Uniswap V3.

| Tx | Action | Block |
|---|---|---|
| [0xc501ed69...](https://basescan.org/tx/0xc501ed6971dbba7b82f6281db3383a5d1906c20ed3726fb4de6f62fbf552ec36) | Mint 2 TBA | 46155905 |
| [0x25a57fff...](https://basescan.org/tx/0x25a57fff97e02ce85b5a714e675cb471134aaca2424cfc8571b8a13280b187c6) | Swap 0.0005 ETH → 1.057 USDC | 46155905 |
| [0x88016968...](https://basescan.org/tx/0x8801696821bb81dc193e2d9682357d59e962cb4d997a2648f287e221562cc509) | `Morpho.createMarket(params)` | 46155905 |
| [0x2edb7f88...](https://basescan.org/tx/0x2edb7f88149c551d3e18fca02c624089ef4bc76d4996821d26cc763ba37a0a8b) | Approve USDC | ~46155940 |
| [0x83cd1f07...](https://basescan.org/tx/0x83cd1f07ea45ef5a5a72f5063e93cfb739f6a12a7212edd598d3f2be1cece4c8) | `Morpho.supply(1 USDC)` | ~46155950 |
| [0x6d98e6e2...](https://basescan.org/tx/0x6d98e6e240b4d187a9b6d6362b6cce40d5bd2fcf852837887bd9cf9295cfd1aa) | Approve TBA | ~46155980 |
| [0x1d1c1d22...](https://basescan.org/tx/0x1d1c1d22ad90f5dd3eab8447a6f0ddc7627aa93631b58df01c869de169f548d8) | `Morpho.supplyCollateral(0.01 TBA)` | 46155988 |
| [0x0abbf7a8...](https://basescan.org/tx/0x0abbf7a80051f163e7742bda5cfbcc4ea10a91f9419d4a8cf924281d701342b6) | `Morpho.borrow(0.5 USDC)` | 46155995 |

Seeding positions: 1 USDC supplied (lender), 0.01 TBA collateral, 0.5 USDC borrowed (50% utilisation).

---

## 6. UI Listing — Path A vs Path B

### TL;DR

| | Path A — With Warning | Path B — Without Warning |
|---|---|---|
| Market usable? | Yes | Yes |
| UI link shareable? | Yes | Yes |
| Shows on market list? | No (direct URL only) | Yes |
| Time to ready | Minutes | ~1 week |
| Cost on Base | ~$0.50 | ~$2 |
| What's needed | `createMarket()` + seed | Above + Vault V2 + GitHub PR |

**Path A is live now.** Yellow banner shown, user clicks "I understand", can trade normally.

### Path B — Clean Listing Steps

**B1 — Deploy Vault V2:**
```bash
cast send 0x4501125508079A99ebBebCE205DeC9593C2b5857 \
  "createVaultV2(address,address,bytes32)" \
  $OWNER_MULTISIG $USDC_BASE $(cast keccak "gyld-vault-v1") \
  --rpc-url $BASE_RPC --private-key $PRIVKEY
```

Security requirements (non-negotiable, checked by Morpho bot):

| Check | Required value |
|---|---|
| Timelock critical ops | ≥ 7 days |
| Timelock standard ops | ≥ 3 days |
| Dead deposit | Burn 1e18 shares to `0x000...dead` |
| Permission gates | All abdicated |
| Vault name/symbol | Must NOT contain "morpho" |

**B2 — Deploy market adapter, configure caps, allocate.**
After 3-day timelock: `addAdapter`, `increaseAbsoluteCap` (×2), `setLiquidityAdapterAndData`, `allocate`.
The market must appear in the vault's withdrawal queue — this is the exact trigger that sets `listed: true` on the Morpho API.

**B3 — Open PR to `morpho-org/morpho-blue-api-metadata`.** Add entries to:
- `data/vaults-v2-listing.json` — vault address, chainId=8453, image, description
- `data/tokens.json` — GyldBondToken with `isListed: true, isWhitelisted: true`
- `data/curators-listing.json` — Gyld as curator with verified=true

**B4 — Await 2 approvals** from `@morpho-org/integration` reviewers. Typical: same day to 4 days.

### Warning Taxonomy

| Warning | Colour | Cause |
|---|---|---|
| `not_whitelisted` | Yellow | No listed Vault V2 has market in its withdraw queue |
| `unrecognized_collateral_asset` | Red | GyldBondToken not in `tokens.json` |
| `unrecognized_loan_asset` | Red | Loan token not in `tokens.json` |
| `incorrect_oracle_configuration` | Red | Oracle scale factor wrong |
| No warning | — | Vault V2 listed + tokens registered + oracle valid |

All warnings are informational — users can dismiss them and trade normally.

### Cost Summary (Base mainnet)

| Step | Est. USD |
|---|---|
| Deploy oracle + createMarket + seed (Path A) | ~$0.25–0.50 |
| Vault V2 + adapter + configure (Path B extra) | ~$0.75–1.50 |
| **Total Path A** | **~$0.50** |
| **Total Path B** | **~$1–2** |

---

## 7. Borrow Flow Reference

```
# Lender side
USDC.approve(morpho, amount)
Morpho.supply(marketParams, assets, shares=0, onBehalf, data="0x")

# Borrower side
TOKEN.approve(morpho, amount)
Morpho.supplyCollateral(marketParams, assets, onBehalf, data="0x")
Morpho.borrow(marketParams, assets, shares=0, onBehalf, receiver)

# Repay
USDC.approve(morpho, amount)
Morpho.repay(marketParams, assets, shares=0, onBehalf, data="0x")

# Withdraw collateral (stay within healthy LTV)
Morpho.withdrawCollateral(marketParams, assets, onBehalf, receiver)
```

MarketParams field order: `(loanToken, collateralToken, oracle, irm, lltv)`

Rounding note on `withdrawCollateral`: Morpho's rounding is stricter than computed
exact-max. Use a slightly conservative amount (e.g. `52000000000000000` not
`52443742177484144`) to avoid unexpected reverts.

---

## 8. Comparison with Euler V2

See `euler-integration.md` for the full Euler deployment. Summary:

| Dimension | Morpho Blue | Euler V2 |
|---|---|---|
| Steps to create market | 2 (oracle wrapper + `createMarket`) | 6 (oracle adapter, router, IRM, 2 vaults, seed) |
| Total contracts we deploy | 1 | 5 |
| UI auto-listing | Yes — instant on `app.morpho.org` | No — requires manual PR to `euler-labels` |
| Oracle wrapper needed | Yes — `MorphoChainlinkOracleV2` | No — direct `AggregatorV3Interface` |
| IRM | Use pre-deployed `AdaptiveCurveIRM` | Deploy custom `KinkIRM` |
| Collateral model | Unified market | Escrow vault + lending vault (ERC-4626) |
| Borrow flow steps | 5 calls | 7 calls (2 extra EVC registrations) |
| Liquidation | Fixed discount at market creation | Dutch auction |

**When to use Morpho:** quick test with shareable UI link, simplest path.
**When to use Euler:** cross-vault collateral, governed risk management, or when Euler Labs lists the vault.

---

## 9. Audit Notes

- **Pause freezes Morpho positions:** when GyldBondToken is paused, all Morpho interactions
  revert including liquidations. Undercollateralised positions cannot be closed until unpause.
  The ops multisig must weigh this when triggering emergency pause.
- **Morpho as `transferFrom` spender:** Morpho's contract address is screened against the
  Chainalysis oracle on every collateral deposit/withdrawal. Verified passing on Sepolia and Base.
- **MorphoChainlinkOracleV2 is not our contract:** it is Morpho's published adapter.
  NAVFeedForwarder remains the stable oracle address for all integrations. The adapter
  wraps it for protocol-specific format compatibility.
- **Market params are immutable:** once `createMarket()` is called, oracle, IRM, and LLTV
  cannot be changed. A new market must be created to change any parameter.
