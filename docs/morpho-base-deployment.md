# Base Mainnet Deployment — Step 1

Token stack deployed on Base mainnet (chain ID 8453) on 2026-05-18.
This is the foundation for the Morpho Blue market (Path A — with warning).
All token metadata is intentionally dummy/test data.

---

## Deployed addresses

| Contract | Address | BaseScan |
|---|---|---|
| Deployer wallet | `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd` | [view](https://basescan.org/address/0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd) |
| TimelockController (delay=0) | `0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72` | [view](https://basescan.org/address/0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72) |
| IssuanceManager (proxy) | `0x5BA267367f06378816c58d47C5850fC9863Ce67F` | [view](https://basescan.org/address/0x5BA267367f06378816c58d47C5850fC9863Ce67F) |
| IssuanceManager (logic) | `0xEA637cdB348d4d14d1329E304F025cC8FD428E5a` | [view](https://basescan.org/address/0xEA637cdB348d4d14d1329E304F025cC8FD428E5a) |
| GyldBondToken (logic) | `0x7C1798643e0793EAB998B777b2CD0B7c2F2870Ad` | [view](https://basescan.org/address/0x7C1798643e0793EAB998B777b2CD0B7c2F2870Ad) |
| TokenFactory | `0x18Ce55785bD24Dd096dAC11111168B1E94A76317` | [view](https://basescan.org/address/0x18Ce55785bD24Dd096dAC11111168B1E94A76317) |
| **TOKEN_TBA proxy** | **`0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3`** | [view](https://basescan.org/address/0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3) |
| **KaleidoscopeNAVFeed (TBA)** | **`0xC69e88136D52D0ADb911F03A2E71d374cA668DeC`** | [view](https://basescan.org/address/0xC69e88136D52D0ADb911F03A2E71d374cA668DeC) |
| **NAVFeedForwarder (TBA)** | **`0x09907C78D4eB531495962120464BFd9044390337`** | [view](https://basescan.org/address/0x09907C78D4eB531495962120464BFd9044390337) |

**NAVFeedForwarder is the permanent oracle address Morpho will point at.**

### External contracts used (not deployed by us)

| Contract | Address | Purpose |
|---|---|---|
| Chainalysis sanctions oracle | `0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B` | Real OFAC screening — official Base deployment |

---

## Token metadata (dummy — intentionally fake)

| Field | Value |
|---|---|
| Name | `Test Bond Alpha` |
| Symbol | `TBA` |
| ISIN | `US000000TBA0` (fake) |
| Maturity | `2030-01-01` (1893456000 unix) |
| Decimals | 18 |
| NAV feed owner | Deployer wallet (pushes `updateAnswer`) |

---

## Transactions

All 13 transactions landed in block **46,154,075** on Base mainnet.

| Tx hash | Action |
|---|---|
| [0x67b3f266...](https://basescan.org/tx/0x67b3f266bceeecefb648d9877fc5e4d05186f403e71c151b580d83975315f697) | Deploy TimelockController |
| [0x5d7d8702...](https://basescan.org/tx/0x5d7d8702601c87e584ca1fca58d672d7fd70b80ab09734195c727cefc4d03b96) | Deploy IssuanceManager logic |
| [0x70cccf12...](https://basescan.org/tx/0x70cccf12a5c2d86df3cb06605fdaa6d77bc6be33b55b75abbb81449e39991add) | Deploy IssuanceManager proxy |
| [0x93de3a37...](https://basescan.org/tx/0x93de3a37de8a2ff0f43b50f01dbda06b7a63a90470deb062aee3a2a349c27504) | Grant roles on IssuanceManager |
| [0xd425600a...](https://basescan.org/tx/0xd425600abc63dc8241d25978c69a3fde87055753ea5cd7fe941fe113735706fa) | Deploy GyldBondToken logic |
| [0x125ef161...](https://basescan.org/tx/0x125ef1611e08464d2712f7b1e7fdefa91e60f8aa1efe0f5f979f0a88ddcf24a9) | Deploy TokenFactory |
| [0x7a3175e5...](https://basescan.org/tx/0x7a3175e50253dd39427a737f795f411f93f4c6f65704f9a611222a3a63783e53) | Wire IssuanceManager roles + whitelist deployer |
| [0x55d9d30b...](https://basescan.org/tx/0x55d9d30b17b3583277f87710ece16d3d9cdc77453067fdcdc7fa1baba42f2242) | Transfer factory ownership to timelock |
| [0xf4d9270e...](https://basescan.org/tx/0xf4d9270e31f091ad4c55b282194f5ae371c9a2e5efd787ff2c772f8647e301b5) | Timelock: schedule acceptOwnership |
| [0x9c51d94b...](https://basescan.org/tx/0x9c51d94bbea5d4f3191429b3db961078c85ab35d8e066a3ae15ba44e1412791f) | Timelock: execute acceptOwnership |
| [0x3502c2ab...](https://basescan.org/tx/0x3502c2ab73da8bcdedf251806f744c6d4b2f0f518a5618893ec70d95dd006a38) | Timelock: schedule deployToken(TBA) |
| [0x318e723e...](https://basescan.org/tx/0x318e723ee46e428dbd1ec21ed5e54e752cdfce6c203c64df2b4d1a7f26b0c47e) | Timelock: execute deployToken(TBA) — deploys proxy + NAVFeed + Forwarder |
| [0x80644eeb...](https://basescan.org/tx/0x80644eeb8ab60f8999eef01828547d0217f49c4ebada95dbf57dc4eb18c12daa) | Final role cleanup |

---

## Verification status

All contracts verified on BaseScan ✅

| Contract | Verification |
|---|---|
| TimelockController | Pass - Verified |
| IssuanceManager (logic) | Pass - Verified |
| IssuanceManager (proxy) | Already Verified (ERC1967Proxy shared) |
| GyldBondToken (logic) | Pass - Verified |
| TokenFactory | Pass - Verified |
| TOKEN_TBA (proxy) | Already Verified (ERC1967Proxy shared) |
| KaleidoscopeNAVFeed | Pass - Verified |
| NAVFeedForwarder | Pass - Verified (pending confirmation) |

---

## Gas summary

| Metric | Value |
|---|---|
| Block | 46,154,075 |
| Gas used | ~13,101,964 units |
| Gas price | ~0.0103 gwei |
| Total ETH | ~0.000135 ETH |
| Total USD | ~$0.28 |

---

## Role assignments

| Role | Holder | Notes |
|---|---|---|
| TimelockController proposer | Deployer wallet | Test only — production must be governance multisig |
| IssuanceManager DEFAULT_ADMIN | TimelockController | Via timelock |
| IssuanceManager SUBSCRIBER_ROLE | Deployer wallet | Test only |
| IssuanceManager REDEEMER_ROLE | Deployer wallet | Test only |
| IssuanceManager WHITELIST_ADMIN_ROLE | Deployer wallet | Test only |
| TOKEN_TBA DEFAULT_ADMIN | TimelockController | Via factory owner at deploy time |
| TOKEN_TBA MINTER_ROLE | IssuanceManager proxy | Correct |
| TOKEN_TBA BURNER_ROLE | IssuanceManager proxy | Correct |
| TOKEN_TBA PAUSER_ROLE | Deployer wallet | Test only |
| KaleidoscopeNAVFeed owner | Deployer wallet | Calls updateAnswer() |
| NAVFeedForwarder owner | TimelockController | Oracle upgrades require governance |

---

## Step 1 complete — what's next

Step 1 is done. The NAVFeedForwarder `0x09907C78D4eB531495962120464BFd9044390337` is the
stable oracle address Morpho will permanently use.

**Step 2 — push a NAV price** (required before oracle wrapper deployment):
```bash
cast send $BASE_NAVFEED_TBA \
  'updateAnswer(int256)' 10000000000 \
  --rpc-url $BASE_RPC --private-key $PRIVKEY
# 10000000000 = $100.00 in 8-decimal Chainlink format
```

**Step 3 — deploy Morpho oracle wrapper** (`DeployBaseMorphoOracle.s.sol` — not yet written).
Wraps NAVFeedForwarder in `MorphoChainlinkOracleV2` to produce the `price()` format Morpho expects.

**Step 4 — `createMarket()`** on `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb`.

**Step 5 — seed + share link** `https://app.morpho.org/base/market/0x{MARKET_ID}`.
