# Morpho Blue Compatibility Test — Sepolia

Pre-audit compatibility test for GyldBondToken on Morpho Blue.
Goal: verify oracle pipeline, transfer behaviour under DeFi interactions, and pause semantics before the audit scope is finalised.

## Verified addresses

| Contract | Sepolia address |
|---|---|
| Morpho Blue | `0xd011EE229E7459ba1ddd22631eF7bF528d424A14` |
| AdaptiveCurveIRM | `0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c` |
| MorphoChainlinkOracleV2Factory | `0xa6c843fc53aAf6EF1d173C4710B26419667bF6CD` |
| USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Chainlink USDC/USD feed | `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` |

Sources: official Morpho docs (docs.morpho.org/get-started/resources/addresses, Sepolia tab), Chainlink feed registry, LTV Protocol testnet deployment.
Note: `0xf08A50178dfcDe18524640EA6618a1f965821715` (from Morpho's deployment files) is inactive on Sepolia — `latestRoundData()` reverts. Using `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` which returns ~$0.998.

---

## ✅ Step 1 — Deploy contracts on Sepolia — DONE (2026-05-14)

All contracts deployed and verified on Sepolia. Do not redeploy.

### Deployed addresses

| Contract | Address | Etherscan |
|---|---|---|
| Deployer wallet | `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd` | — |
| TimelockController (delay=0) | `0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72` | [view](https://sepolia.etherscan.io/address/0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72) |
| IssuanceManager (proxy) | `0x5BA267367f06378816c58d47C5850fC9863Ce67F` | [view](https://sepolia.etherscan.io/address/0x5BA267367f06378816c58d47C5850fC9863Ce67F) |
| TokenFactory | `0xb11BdcFE08c69c461F410453BdF80A8cb9Cd07aE` | [view](https://sepolia.etherscan.io/address/0xb11BdcFE08c69c461F410453BdF80A8cb9Cd07aE) |
| MockSanctionsList | `0x7C1798643e0793EAB998B777b2CD0B7c2F2870Ad` | [view](https://sepolia.etherscan.io/address/0x7C1798643e0793EAB998B777b2CD0B7c2F2870Ad) |
| GyldBondToken logic | `0x18Ce55785bD24Dd096dAC11111168B1E94A76317` | [view](https://sepolia.etherscan.io/address/0x18Ce55785bD24Dd096dAC11111168B1E94A76317) |
| TOKEN_CAT proxy | `0xC545645b889027F5C2e7c1460566B08673273B07` | [view](https://sepolia.etherscan.io/address/0xC545645b889027F5C2e7c1460566B08673273B07) |
| NAVFEED_CAT | `0x0e21b8E3D40d92244a07977905c056EBF5f88DDE` | [view](https://sepolia.etherscan.io/address/0x0e21b8E3D40d92244a07977905c056EBF5f88DDE) |
| FORWARDER_CAT | `0xDcBd2c177212aebD18e8F1429457483644C50C00` | [view](https://sepolia.etherscan.io/address/0xDcBd2c177212aebD18e8F1429457483644C50C00) |
| TOKEN_C proxy | `0xF62dd0722ed16593B0e8A00dD80D0Ea43A0e0c1E` | [view](https://sepolia.etherscan.io/address/0xF62dd0722ed16593B0e8A00dD80D0Ea43A0e0c1E) |
| NAVFEED_C | `0x0248FaB2aa4a481b6c7C81DDdd28ac24E8EacEc7` | [view](https://sepolia.etherscan.io/address/0x0248FaB2aa4a481b6c7C81DDdd28ac24E8EacEc7) |
| FORWARDER_C | `0x24A5eb80F6ab34C9563f5667D1bc1ccB3167B9c0` | [view](https://sepolia.etherscan.io/address/0x24A5eb80F6ab34C9563f5667D1bc1ccB3167B9c0) |
| TOKEN_KO proxy | `0xb7Fc5791910CeddB54BbD53136D2cfc67719A2B4` | [view](https://sepolia.etherscan.io/address/0xb7Fc5791910CeddB54BbD53136D2cfc67719A2B4) |
| NAVFEED_KO | `0x5039770267e05A8A38023CF925b3b7FF6a8076d8` | [view](https://sepolia.etherscan.io/address/0x5039770267e05A8A38023CF925b3b7FF6a8076d8) |
| FORWARDER_KO | `0x38Bc14C8C39C62F712207c950d423957A51550bA` | [view](https://sepolia.etherscan.io/address/0x38Bc14C8C39C62F712207c950d423957A51550bA) |

All addresses are saved in `.env`. Load them before any step:
```bash
source .env
```

We use TOKEN_CAT for all Morpho test steps below.

Note: the script also whitelists `msg.sender` automatically (via `subscriberAddress`
defaulting to `msg.sender`), so your deployer wallet can call `subscribe()` in Step 2.

---

## ✅ Step 2 — Mint test tokens — DONE (2026-05-14)

Called via Etherscan UI (Write as Proxy) with Metamask.

| Field | Value |
|---|---|
| Contract | IssuanceManager `0x5BA267367f06378816c58d47C5850fC9863Ce67F` |
| Function | `subscribe(address token, address recipient, uint256 amount)` |
| token | TOKEN_CAT `0xC545645b889027F5C2e7c1460566B08673273B07` |
| recipient | `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd` |
| amount | `1000000000000000000000000` (1,000,000 GYLD) |
| Tx | [0x1ae962d2...b14c](https://sepolia.etherscan.io/tx/0x1ae962d2408ebf004e5c9186c8e740a42ead8507ec88d3ee9e0d3821a898b14c) |
| Balance confirmed | `1000000000000000000000000` ✓ |

---

## ✅ Step 3 — Push a NAV price — DONE (2026-05-15)

| Field | Value |
|---|---|
| Contract | NAVFEED_CAT `0x0e21b8E3D40d92244a07977905c056EBF5f88DDE` |
| Function | `updateAnswer(int256)` |
| Value | `10000000000` (= $100 in 8-decimal Chainlink format) |
| Tx | [0xbe60a8dd...474b4b](https://sepolia.etherscan.io/tx/0xbe60a8ddf90f9e9163e886cbb46fb37569e5eb240bb02bb912e60d9481474b4b) |

---

## ✅ Step 4 — Deploy Morpho oracle adapter — DONE (2026-05-15)

`MorphoChainlinkOracleV2` wraps NAVFeedForwarder and exposes `price()` in Morpho's format.
NAVFeedForwarder stays unchanged — no code modifications needed.

### Deployed oracle

| Field | Value |
|---|---|
| MORPHO_ORACLE | `0xeB66EB06EE848d9cF587EB1EeA3d11b0992cbd98` |
| Tx | [0x7bbf0ed9c7701e475fd5a1b774528cc304b1108b84c7c1ad66faf195d6f54663](https://sepolia.etherscan.io/tx/0x7bbf0ed9c7701e475fd5a1b774528cc304b1108b84c7c1ad66faf195d6f54663) |
| `price()` result | `100027007291968831584527822` ≈ 100 × 10^24 ✓ |

Note: the Chainlink USDC/USD feed in the Morpho deployment files (`0xf08A50178dfcDe18524640EA6618a1f965821715`)
is inactive on Sepolia. The working feed is `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E`
(returns ~$0.998). `CHAINLINK_USDC_USD` in `.env` has been updated accordingly.

```bash
cast send $ORACLE_FACTORY \
  "createMorphoChainlinkOracleV2(address,uint256,address,address,uint256,address,uint256,address,address,uint256,bytes32)" \
  "0x0000000000000000000000000000000000000000" \
  1 \
  $FORWARDER_CAT \
  "0x0000000000000000000000000000000000000000" \
  18 \
  "0x0000000000000000000000000000000000000000" \
  1 \
  $CHAINLINK_USDC_USD \
  "0x0000000000000000000000000000000000000000" \
  6 \
  "0x0000000000000000000000000000000000000000000000000000000000000000" \
  --rpc-url $RPC --private-key $PRIVKEY
```

Parameters:
- `baseVaultConversionSample` = 1 (required when no vault; 0 reverts)
- `baseFeed1` = FORWARDER_CAT — GYLD/USD (18-decimal token)
- `baseTokenDecimals` = 18
- `quoteVaultConversionSample` = 1 (required when no vault; 0 reverts)
- `quoteFeed1` = Chainlink USDC/USD `0xA2F78ab2355fe2f984D808B5CeE7FD0A93D5270E` — USDC (6-decimal token)
- `quoteTokenDecimals` = 6
- all vault and feed2 fields = address(0)
- salt = bytes32(0) (no CREATE2 vanity address needed)

**Verify oracle price:**
```bash
cast call $MORPHO_ORACLE "price()(uint256)" --rpc-url $RPC
# Expected: ~100000000000000000000000000  (100 × 10^24)
# Formula: (GYLD/USD) / (USDC/USD) × 10^(36 + 6 - 18) = 100 × 10^24
```

This is the most critical check. If `price()` returns a sane number the full oracle pipeline works.

---

## ✅ Step 5 — Create the Morpho market — DONE (2026-05-15)

| Field | Value |
|---|---|
| Tx | [0x4317a0ea49887cc40ff9be8b9312a6b1f4856add7ff3a671cc4277a0788bd7a2](https://sepolia.etherscan.io/tx/0x4317a0ea49887cc40ff9be8b9312a6b1f4856add7ff3a671cc4277a0788bd7a2) |
| Market ID | `0x987fa2f626c00d51e4faf314d524cc034e1743e1d783368a8b3584cd6d40dcc9` |
| loanToken | USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| collateralToken | TOKEN_CAT `0xC545645b889027F5C2e7c1460566B08673273B07` |
| oracle | MORPHO_ORACLE `0xeB66EB06EE848d9cF587EB1EeA3d11b0992cbd98` |
| irm | AdaptiveCurveIRM `0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c` |
| lltv | `860000000000000000` (86%) |

```bash
cast send $MORPHO \
  "createMarket((address,address,address,address,uint256))" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  --rpc-url $RPC --private-key $PRIVKEY
```

MarketParams field order: `(loanToken, collateralToken, oracle, irm, lltv)`.

No approval from Morpho required — markets are permissionless.

---

## ✅ Step 6 — Supply USDC as lender — DONE (2026-05-15)

You play both sides (lender and borrower) in this test.
Note: only 20 USDC available from Circle faucet — amounts scaled down from 10,000 USDC; mechanics identical.

| Field | Value |
|---|---|
| Approve tx | [0x0f805069c8b3a4aaeb5e6bca9ca1da7947a0d98b8a44dc43b12bef3b3998adc5](https://sepolia.etherscan.io/tx/0x0f805069c8b3a4aaeb5e6bca9ca1da7947a0d98b8a44dc43b12bef3b3998adc5) |
| Supply tx | [0x480374ffad1ced6bf9a0ee03f6a52b407bb7071dbbe9197d91f678e79d880113](https://sepolia.etherscan.io/tx/0x480374ffad1ced6bf9a0ee03f6a52b407bb7071dbbe9197d91f678e79d880113) |
| Amount supplied | 20 USDC (`20000000`) |

```bash
# Approve Morpho to spend USDC
cast send $USDC \
  "approve(address,uint256)" $MORPHO 20000000 \
  --rpc-url $RPC --private-key $PRIVKEY

# Supply 20 USDC into the market
cast send $MORPHO \
  "supply((address,address,address,address,uint256),uint256,uint256,address,bytes)" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  20000000 0 $WALLET "0x" \
  --rpc-url $RPC --private-key $PRIVKEY
```

---

## ✅ Step 7 — Supply GYLD as collateral — DONE (2026-05-15)

Note: supplied 0.1 GYLD (not 100) — scaled to match 20 USDC pool. At $110 NAV, 0.1 GYLD = $11 collateral → $9.46 max borrow at 86% LLTV.

| Field | Value |
|---|---|
| Approve tx | [0xd138fcfe6238885d1a80b1c1526f5452554869968f67d591bd16017103ab5ed7](https://sepolia.etherscan.io/tx/0xd138fcfe6238885d1a80b1c1526f5452554869968f67d591bd16017103ab5ed7) |
| supplyCollateral tx | [0x0a737feeadd56d8a74660965ade2574ffe0ff941428d9152f05d721019940d19](https://sepolia.etherscan.io/tx/0x0a737feeadd56d8a74660965ade2574ffe0ff941428d9152f05d721019940d19) |
| Amount | 0.1 GYLD (`100000000000000000`) |

```bash
# Approve Morpho to spend 0.1 GYLD
cast send $TOKEN_CAT \
  "approve(address,uint256)" $MORPHO 100000000000000000 \
  --rpc-url $RPC --private-key $PRIVKEY

# Supply 0.1 GYLD as collateral
cast send $MORPHO \
  "supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  100000000000000000 $WALLET "0x" \
  --rpc-url $RPC --private-key $PRIVKEY
```

What is being tested: Morpho calls `transferFrom(wallet, morpho, 0.1e18)` on GYLD.
Morpho's contract is `msg.sender`. `GyldBondToken._requireAccess(msg.sender)` screens
Morpho against the Chainalysis oracle. Must not revert.

---

## ✅ Step 8 — Borrow USDC — DONE (2026-05-15)

0.1 GYLD at $110 NAV = $11 collateral. At 86% LLTV, max borrow = $9.46.
Deliberately tested over-borrow first to confirm LLTV enforcement, then borrowed $9.

| Action | Amount | Result |
|---|---|---|
| Borrow 10 USDC | `10000000` | ✗ reverted — `insufficient collateral` ✓ |
| Borrow 9 USDC | `9000000` | ✓ success — 9 USDC landed in wallet ✓ |

| Field | Value |
|---|---|
| Over-borrow tx | reverted (no hash — gas estimation failed before broadcast) |
| Borrow tx | [0x7b0d771aa5846b86cf9b62cd9f631b793f4a9f335f4804e11d873af38af6f722](https://sepolia.etherscan.io/tx/0x7b0d771aa5846b86cf9b62cd9f631b793f4a9f335f4804e11d873af38af6f722) |
| USDC balance after | `9000000` (9 USDC) ✓ |

```bash
# Over-borrow — confirms LLTV enforcement (will revert)
cast send $MORPHO \
  "borrow((address,address,address,address,uint256),uint256,uint256,address,address)" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  10000000 0 $WALLET $WALLET \
  --rpc-url $RPC --private-key $PRIVKEY
# Expected: revert — insufficient collateral

# Valid borrow within limit
cast send $MORPHO \
  "borrow((address,address,address,address,uint256),uint256,uint256,address,address)" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  9000000 0 $WALLET $WALLET \
  --rpc-url $RPC --private-key $PRIVKEY
```

The oracle price was read correctly and the full pipeline works end to end.

---

## ✅ Step 9 — Repay and withdraw (partial round trip) — DONE (2026-05-15)

Tested partial repay + partial collateral withdrawal to prove position management.
Remaining open position (4.5 USDC debt, 0.048 GYLD collateral) left intentionally
for Step 10 pause test — interest accrual continues on the live position.

| Action | Amount | Tx |
|---|---|---|
| Approve USDC repay | 4.5 USDC (`4500000`) | [0xd7dfc3d2...0d0a0](https://sepolia.etherscan.io/tx/0xd7dfc3d21f4447b65179ccd5e72d885c66782b71d266a0043cc1959825f0d0a0) |
| Repay | 4.5 USDC (`4500000`) | [0x24a0d8f1...6dff](https://sepolia.etherscan.io/tx/0x24a0d8f1967083f8619e5fac0c4ac869dfc5c79324f39afa34c235ca6c5c6dff) |
| withdrawCollateral | 0.052 GYLD (`52000000000000000`) | [0x68903a9a...d706](https://sepolia.etherscan.io/tx/0x68903a9a75ff0e32f7f5109812e09a76c815afef678199facd3a5b007985d706) |

Interest observed: repaid 4,500,000 USDC units but borrow shares reduced by 4,500,037 —
37 units ($0.000037) of interest accrued during the test session. Went to supply position (lender side).

Partial withdraw boundary test:
- Tried `52443742177484144` (computed exact max) → reverted — Morpho's rounding is stricter
- Tried `52000000000000000` (0.052 GYLD) → success

Position state after:
- Debt remaining: ~4.5 USDC
- Collateral remaining: 0.048 GYLD (locked in Morpho)

```bash
# Approve and repay partial debt
cast send $USDC \
  "approve(address,uint256)" $MORPHO 4500000 \
  --rpc-url $RPC --private-key $PRIVKEY

cast send $MORPHO \
  "repay((address,address,address,address,uint256),uint256,uint256,address,bytes)" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  4500000 0 $WALLET "0x" \
  --rpc-url $RPC --private-key $PRIVKEY

# Withdraw partial collateral (within healthy LTV)
cast send $MORPHO \
  "withdrawCollateral((address,address,address,address,uint256),uint256,address,address)" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  52000000000000000 $WALLET $WALLET \
  --rpc-url $RPC --private-key $PRIVKEY
```

---

## Step 10 — Pause test

Confirms that pausing GYLD freezes all Morpho interactions including liquidations.
This is expected and intentional — document it in the audit brief.

Note: PAUSER_ROLE must be held by the caller. On Sepolia the deployer wallet holds it.

```bash
# Pause the token
cast send $TOKEN_CAT "pause()" --rpc-url $RPC --private-key $PRIVKEY

# Attempt to supply collateral — must revert with EnforcedPause
cast send $MORPHO \
  "supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  100000000000000000 $WALLET "0x" \
  --rpc-url $RPC --private-key $PRIVKEY
# Expected: revert EnforcedPause()

# Unpause and verify recovery
cast send $TOKEN_CAT "unpause()" --rpc-url $RPC --private-key $PRIVKEY
cast send $MORPHO \
  "supplyCollateral((address,address,address,address,uint256),uint256,address,bytes)" \
  "($USDC,$TOKEN_CAT,$MORPHO_ORACLE,$IRM,$LLTV)" \
  100000000000000000 $WALLET "0x" \
  --rpc-url $RPC --private-key $PRIVKEY
# Expected: success
```

---

## What each step proves

| Step | Passes if | Fails if |
|---|---|---|
| Step 1 — deploy | All contracts live on Sepolia, roles wired correctly | Script errors, insufficient ETH, or missing env vars |
| Step 3 — latestRoundData | NAV price flows through NAVFeedForwarder | KaleidoscopeNAVFeed not pushing or wrong format |
| Step 4 — price() | Full oracle pipeline works end to end | NAVFeedForwarder not 8-decimal or USDC feed wrong |
| Step 5 — createMarket | Morpho accepted the market params | Wrong address or IRM not enabled |
| Step 7 — supplyCollateral | Morpho can transferFrom on GYLD | Sanctions oracle rejects Morpho's address |
| Step 8 — borrow | Oracle price valued collateral correctly | Wrong price format → wrong or zero borrow limit |
| Step 9 — round trip | No accounting corruption | State bug in token or Morpho integration |
| Step 10 — pause | Pause blocks all Morpho interactions | Unexpected behaviour during emergency |

---

## Notes for audit brief

- **Pause freezes Morpho positions**: when GYLD is paused, all Morpho interactions revert
  including liquidations. Undercollateralised positions cannot be closed until unpause.
  This is intentional — the ops multisig must weigh this when triggering emergency pause.
- **Morpho as transferFrom spender**: Morpho's contract address is screened against
  the Chainalysis oracle on every collateral deposit/withdrawal. This is expected to pass
  in all normal circumstances but is explicitly verified here.
- **MorphoChainlinkOracleV2 is not our contract**: it is Morpho's published adapter.
  NAVFeedForwarder remains the stable oracle address for all integrations. The Morpho
  adapter wraps it for protocol-specific format compatibility.
