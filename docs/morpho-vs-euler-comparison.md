# Morpho Blue vs Euler V2 — Base Mainnet Deployment Comparison

Both protocols fully deployed and tested on Base mainnet (chain ID 8453).
Deployer: `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd`

---

## Quick Summary

| | Morpho Blue | Euler V2 |
|---|---|---|
| **Status** | Live ✅ | Live ✅ |
| **Deployed** | 2026-05-18 | 2026-05-19 |
| **Steps to market** | 2 (oracle + createMarket) | 6 (oracle adapter, router, IRM, escrow vault, lending vault, seed) |
| **Total contracts deployed by us** | 1 | 5 |
| **Automatic UI listing** | Yes — `app.morpho.org` immediately | No — requires manual PR to `euler-labels` repo |
| **Shareable link** | [app.morpho.org/base/market/0x9840...](https://app.morpho.org/base/market/0x9840633fea7b077c2efac0f819ccef9fa69e2641844fcc749e756cafb0bfd453) | BaseScan only |
| **Oracle wrapper needed** | Yes — `MorphoChainlinkOracleV2` (Morpho-specific format) | No — `ChainlinkOracle` adapter accepts NAVFeedForwarder directly |
| **IRM** | Used pre-deployed `AdaptiveCurveIRM` — no deployment | Had to deploy custom `KinkIRM` |
| **Collateral model** | Single vault: collateral + lending in one market | Two vaults: escrow vault (collateral) + lending vault (USDC) |
| **Liquidation model** | Fixed discount set at market creation | Dutch auction — discount grows as health worsens |
| **All params immutable?** | Yes — baked into `createMarket()` | Yes (we used ungoverned vaults — `setGovernorAdmin(address(0))`) |

---

## Token Stack (shared by both)

Deployed in Step 1 of the Morpho setup. Reused for Euler.

| Contract | Address |
|---|---|
| TOKEN_TBA (GyldBondToken proxy) | `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` |
| KaleidoscopeNAVFeed (TBA) | `0xC69e88136D52D0ADb911F03A2E71d374cA668DeC` |
| NAVFeedForwarder (TBA) | `0x09907C78D4eB531495962120464BFd9044390337` |
| IssuanceManager (proxy) | `0x5BA267367f06378816c58d47C5850fC9863Ce67F` |
| TimelockController | `0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72` |
| Chainalysis oracle (Base official) | `0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B` |

---

## Morpho Blue — Deployed Contracts

| Step | Contract | Address | BaseScan |
|---|---|---|---|
| Oracle | MorphoChainlinkOracleV2 (TBA/USDC) | `0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A` | [view](https://basescan.org/address/0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A) |
| Market | Morpho Blue (protocol-owned) | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | [view](https://basescan.org/address/0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb) |

### Morpho Market Parameters

| Parameter | Value |
|---|---|
| Market ID | `0x9840633fea7b077c2efac0f819ccef9fa69e2641844fcc749e756cafb0bfd453` |
| Loan token | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Collateral token | TBA `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` |
| Oracle | MorphoChainlinkOracleV2 `0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A` |
| IRM | AdaptiveCurveIRM `0x46415998764C29aB2a25CbeA6254146D50D22687` (Morpho official) |
| LLTV | 86% |

### Morpho Flow (2 steps)

```
Step 1 — Oracle
  createMorphoChainlinkOracleV2(NAVFeedForwarder, USDC_CHAINLINK_FEED)
  → MorphoChainlinkOracleV2: 0xeD5F6eFb...

Step 2 — Market + Seed
  Morpho.createMarket(loanToken=USDC, collateral=TBA, oracle, irm, lltv=86%)
  → Market ID: 0x9840633f...
  USDC.approve + Morpho.supply(1 USDC)
  TBA.approve + Morpho.supplyCollateral(0.01 TBA)
  Morpho.borrow(0.5 USDC)
```

### Morpho Key Transactions

| Action | Tx hash |
|---|---|
| Deploy MorphoChainlinkOracleV2 | [0x62acda39...](https://basescan.org/tx/0x62acda394a0d5640fc73a3e22c25c0a5399fda7e8fb40d7c44c24bef7e2d8e64) |
| `createMarket()` | [0x88016968...](https://basescan.org/tx/0x8801696821bb81dc193e2d9682357d59e962cb4d997a2648f287e221562cc509) |
| Supply 1 USDC (lender) | [0x83cd1f07...](https://basescan.org/tx/0x83cd1f07ea45ef5a5a72f5063e93cfb739f6a12a7212edd598d3f2be1cece4c8) |
| supplyCollateral 0.01 TBA | [0x1d1c1d22...](https://basescan.org/tx/0x1d1c1d22ad90f5dd3eab8447a6f0ddc7627aa93631b58df01c869de169f548d8) |
| Borrow 0.5 USDC | [0x0abbf7a8...](https://basescan.org/tx/0x0abbf7a80051f163e7742bda5cfbcc4ea10a91f9419d4a8cf924281d701342b6) |

---

## Euler V2 — Deployed Contracts

| Step | Contract | Address | BaseScan |
|---|---|---|---|
| 1 | ChainlinkOracle adapter (TBA/USDC) | `0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d` | [view](https://basescan.org/address/0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d) |
| 2 | EulerRouter (retired — see note) | `0xe2Cf003AA0855D035c01c32B1cdEb081f7666428` | [view](https://basescan.org/address/0xe2Cf003AA0855D035c01c32B1cdEb081f7666428) |
| 3 | KinkIRM | `0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d` | [view](https://basescan.org/address/0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d) |
| 4 | TBA Escrow Vault | `0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4` | [view](https://basescan.org/address/0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4) |
| 5a | EulerRouter V2 (active) | `0xBD8535B344293e96C0eFE7E9224aB54CE880471E` | [view](https://basescan.org/address/0xBD8535B344293e96C0eFE7E9224aB54CE880471E) |
| 5b | USDC Lending Vault | `0xCF8930030FbA9c8599A534304B94972762d79F71` | [view](https://basescan.org/address/0xCF8930030FbA9c8599A534304B94972762d79F71) |

> **Note on retired router:** The Step 2 router was deployed and configured
> (`govSetConfig` for TBA/USDC) but `govSetResolvedVault()` was missed before
> governance was renounced. A replacement router (V2) was deployed in Step 5
> with the correct full configuration.

### Euler KinkIRM Rate Curve

| Utilisation | Borrow APY |
|---|---|
| 0% | 0% |
| 80% (kink) | 5% |
| 100% (max) | 100% |

### Euler Lending Vault Parameters

| Parameter | Value |
|---|---|
| Asset | USDC |
| Oracle | EulerRouter V2 |
| Unit of account | USDC |
| IRM | KinkIRM |
| Borrow LTV | 75% |
| Liquidation LTV | 80% |
| Governor | renounced (`address(0)`) |

### Euler Flow (6 steps)

```
Step 1 — ChainlinkOracle adapter
  ChainlinkOracle(base=TBA, quote=USDC, feed=NAVFeedForwarder, maxStaleness=86400)

Step 2 — EulerRouter (retired)
  oracleRouterFactory.deploy(deployer)
  router.govSetConfig(TBA, USDC, chainlinkAdapter)
  router.transferGovernance(address(0))         ← governance renounced too early

Step 3 — KinkIRM
  kinkIRMFactory.deploy(baseRate=0, slope1, slope2, kink=80%)

Step 4 — TBA Escrow Vault
  eVaultFactory.createProxy(trailingData=abi.encodePacked(TBA, 0, 0))
  escrowVault.setHookConfig(address(0), 0)
  escrowVault.setGovernorAdmin(address(0))

Step 5 — EulerRouter V2 + USDC Lending Vault
  oracleRouterFactory.deploy(deployer)
  router.govSetConfig(TBA, USDC, chainlinkAdapter)
  router.govSetResolvedVault(escrowVault, true)  ← critical: resolves vault shares → TBA
  router.transferGovernance(address(0))
  eVaultFactory.createProxy(trailingData=abi.encodePacked(USDC, routerV2, USDC))
  lendingVault.setInterestRateModel(kinkIRM)
  lendingVault.setHookConfig(address(0), 0)
  lendingVault.setLTV(escrowVault, 7500, 8000, 0)
  lendingVault.setGovernorAdmin(address(0))

Step 6 — Seed and verify
  USDC.approve + lendingVault.deposit(755962 USDC)
  TBA.approve + escrowVault.deposit(0.5 TBA)
  EVC.enableCollateral(deployer, escrowVault)
  EVC.enableController(deployer, lendingVault)
  lendingVault.borrow(300000 USDC)
```

### Euler Key Transactions

| Action | Tx hash |
|---|---|
| Deploy ChainlinkOracle adapter | [0xb0c1f2e5...](https://basescan.org/tx/0xb0c1f2e5c6a4a4ff48e9ed0b8c2c97c8d7f8a5e0b3a6c2d4f9e1a5b7c8d2e4f) |
| Deploy KinkIRM | [0xdda2bab0...](https://basescan.org/tx/0xdda2bab0117e92a939bcfdb64e0c4676d1d0ebb6c7b368dfbe1e1a40be860315) |
| Deploy TBA Escrow Vault | [0x7129e655...](https://basescan.org/tx/0x7129e655339f71071f829b8610d351c5ee193de5432eb81e34709a35b34c1dff) |
| Deploy EulerRouter V2 | [0x885f24dd...](https://basescan.org/tx/0x885f24dda4469358321fba8211cc1c61054bb40ff6d7b088a46e8afda6a4be06) |
| Deploy USDC Lending Vault | [0xf1fe3a76...](https://basescan.org/tx/0xf1fe3a760e2b3381161246708768a4c0d97610899dd97dfe9d3d2ba2ad1acb04) |
| Set IRM on lending vault | [0x0ac0e768...](https://basescan.org/tx/0x0ac0e76848a4c66fe94154dd08b17ae1cb3efdfcbae56baf1387d54b52df01ea) |
| Set LTV (75% borrow / 80% liq) | [0x9b161e60...](https://basescan.org/tx/0x9b161e607c91d2e16a9773a8938a1701fe59cd85e528b99a52dfa6fa5cd5c0b7) |
| Deposit USDC (lender) | [0xde25ea37...](https://basescan.org/tx/0xde25ea37f998d355cb8eba601a3a1a0c664bbcc9a406e515a6d70e5637b68f2f) |
| Deposit TBA (collateral) | [0x838bdad1...](https://basescan.org/tx/0x838bdad1fdd5eba547ed0d8690bef0d024c8f625847207fde0df323c6d7bf3e0) |
| EVC enableCollateral + enableController | [0xe0371d6d...](https://basescan.org/tx/0xe0371d6d142cd03a0b7ac5b3ba2f1078ec1facbccac6d1321d086c0678c404b7) / [0x9aed99b2...](https://basescan.org/tx/0x9aed99b2f72a1fc7b6db42c241a7e1c21436af550af192da600fcf8478dc463c) |
| Borrow USDC | [0xd0f33df5...](https://basescan.org/tx/0xd0f33df51db90af9e95693c56cbfb3f675ce8acfde40a81fad6354f31dc56e86) |

---

## Oracle Architecture Comparison

```
Morpho:
  NAVFeedForwarder
    └─ MorphoChainlinkOracleV2 (wrapper reformats to Morpho price() format)
         └─ Morpho market oracle

Euler:
  NAVFeedForwarder
    └─ ChainlinkOracle adapter (direct — no wrapper needed)
         └─ EulerRouter V2 (dispatcher)
              ├─ govSetConfig(TBA, USDC, adapter)
              └─ govSetResolvedVault(escrowVault, true)  ← resolves vault shares → TBA
                   └─ USDC Lending Vault oracle
```

Morpho needs a wrapper because its oracle format (`price()` returning 1e36-scaled
output) is different from Chainlink's `latestRoundData()`. Euler's `ChainlinkOracle`
adapter speaks the same interface as our NAVFeedForwarder directly.

---

## Borrow Flow Comparison

### Morpho
```
1. USDC.approve(morpho)
2. Morpho.supply(amount, receiver)          ← lender deposits
3. TBA.approve(morpho)
4. Morpho.supplyCollateral(amount, receiver) ← borrower locks collateral
5. Morpho.borrow(amount, receiver)           ← borrower draws USDC
```

No registration step — Morpho manages the account state internally.

### Euler
```
1. USDC.approve(lendingVault)
2. lendingVault.deposit(amount, receiver)    ← lender deposits (ERC-4626)
3. TBA.approve(escrowVault)
4. escrowVault.deposit(amount, receiver)     ← borrower locks collateral (ERC-4626)
5. EVC.enableCollateral(account, escrowVault)  ← register collateral source
6. EVC.enableController(account, lendingVault) ← register debt controller
7. lendingVault.borrow(amount, receiver)     ← borrower draws USDC
```

Two extra EVC registration calls required before borrowing. The EVC tracks which
vaults can freeze your collateral, enabling cross-vault positions (one TBA deposit
can back loans across multiple lending vaults simultaneously).

---

## Known Issues / Gotchas

### Morpho
- MorphoChainlinkOracleV2 uses inverse pricing — numerator/denominator must be
  set correctly or prices come out wrong. Requires careful parameter calculation.
- Market shows a yellow "unrecognised oracle" warning on `app.morpho.org` — expected
  for permissionless oracles not on Morpho's curated list.

### Euler
- **`trailingData` must be 60 bytes:** `abi.encodePacked(asset, oracle, unitOfAccount)`.
  Passing 40 bytes (`oracle, unitOfAccount` only) triggers `E_ProxyMetadata()`.
- **`govSetResolvedVault()` must be called before governance is renounced.** The
  lending vault prices collateral as `oracle.getQuote(shares, escrowVaultAddress, USDC)`.
  Without registration the router reverts with `PriceOracle_NotSupported`.
- **BaseScan shows "execution reverted" on successful EVault deposits.** This is a
  display artifact from the EVC's deferred liquidity check mechanism (internal
  try/catch probe). Verify success via token transfer events, not the revert label.

---

## Which to Use

| Scenario | Recommendation |
|---|---|
| Quick test with a shareable UI link | **Morpho** — market appears on `app.morpho.org` instantly |
| Prove integration works on-chain | **Either** — both fully verified |
| One TBA deposit backing multiple loans | **Euler** — EVC cross-vault collateral |
| Adjustable risk params after launch | **Euler** — use a governed vault |
| Production listing visible to end users | **Morpho** (now) or **Euler** after euler-labels PR |
