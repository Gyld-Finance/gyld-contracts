# Base Mainnet Morpho Market — Step 3: createMarket + Seed

Market created and seeded on Base mainnet on 2026-05-18.
The market is live and accessible at the URL below.

---

## Market URL (shareable)

**https://app.morpho.org/base/market/0x9840633fea7b077c2efac0f819ccef9fa69e2641844fcc749e756cafb0bfd453**

The market shows with a yellow warning ("unrecognized oracle / curator") — this is expected for Path A.
Anyone with the URL can supply USDC, supply TBA collateral, and borrow.

---

## Market parameters

| Parameter | Value |
|---|---|
| Loan token | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| Collateral token | TOKEN_TBA `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` |
| Oracle | MorphoChainlinkOracleV2 `0xeD5F6eFb1a4D486642dAc48AC129af5834d7ca6A` |
| IRM | AdaptiveCurveIRM `0x46415998764C29aB2a25CbeA6254146D50D22687` |
| LLTV | 86% (`860000000000000000`) |
| Market ID | `0x9840633fea7b077c2efac0f819ccef9fa69e2641844fcc749e756cafb0bfd453` |

---

## Transactions

All transactions executed by deployer `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd`.

### Pre-seeding

| Action | Tx hash | Block |
|---|---|---|
| Mint 2 TBA (IssuanceManager.subscribe) | [0xc501ed69...](https://basescan.org/tx/0xc501ed6971dbba7b82f6281db3383a5d1906c20ed3726fb4de6f62fbf552ec36) | 46155905 |
| Swap 0.0005 ETH → 1.057 USDC (Uniswap V3) | [0x25a57fff...](https://basescan.org/tx/0x25a57fff97e02ce85b5a714e675cb471134aaca2424cfc8571b8a13280b187c6) | ~46155905 |

### createMarket

| Action | Tx hash | Block |
|---|---|---|
| `Morpho.createMarket(marketParams)` | [0x88016968...](https://basescan.org/tx/0x8801696821bb81dc193e2d9682357d59e962cb4d997a2648f287e221562cc509) | 46155905 |

Market ID confirmed from `CreateMarket` event topic:
`0x9840633fea7b077c2efac0f819ccef9fa69e2641844fcc749e756cafb0bfd453`

### Market seeding

| Action | Amount | Tx hash | Block |
|---|---|---|---|
| Approve USDC for Morpho | max | [0x2edb7f88...](https://basescan.org/tx/0x2edb7f88149c551d3e18fca02c624089ef4bc76d4996821d26cc763ba37a0a8b) | ~46155940 |
| `Morpho.supply` (loan side) | 1 USDC | [0x83cd1f07...](https://basescan.org/tx/0x83cd1f07ea45ef5a5a72f5063e93cfb739f6a12a7212edd598d3f2be1cece4c8) | ~46155950 |
| Approve TBA for Morpho | max | [0x6d98e6e2...](https://basescan.org/tx/0x6d98e6e240b4d187a9b6d6362b6cce40d5bd2fcf852837887bd9cf9295cfd1aa) | ~46155980 |
| `Morpho.supplyCollateral` | 0.01 TBA | [0x1d1c1d22...](https://basescan.org/tx/0x1d1c1d22ad90f5dd3eab8447a6f0ddc7627aa93631b58df01c869de169f548d8) | 46155988 |
| `Morpho.borrow` | 0.5 USDC | [0x0abbf7a8...](https://basescan.org/tx/0x0abbf7a80051f163e7742bda5cfbcc4ea10a91f9419d4a8cf924281d701342b6) | 46155995 |

**Seeding positions (all held by deployer):**
- Supplied: 1 USDC (lender position)
- Collateral: 0.01 TBA (~$1 at $100/TBA NAV)
- Borrowed: 0.5 USDC (50% utilization, well below 86% LLTV)

---

## Why seeding matters

Without an initial supply + borrow, the AdaptiveCurveIRM has zero utilization and decays toward
its minimum borrow rate. A small seed position establishes non-zero utilization so the rate
display is meaningful when teammates visit the URL.

---

## Steps complete

| Step | Status |
|---|---|
| Step 1 — Deploy token stack (TimelockController, IssuanceManager, TokenFactory, TBA) | Done |
| Step 2 — Deploy MorphoChainlinkOracleV2 + push NAV price | Done |
| Step 3 — createMarket() + seed | Done |

**Market is live. Share the URL above.**

---

## What teammates can do now

1. **Supply USDC** — earn interest as a lender
2. **Supply TBA + borrow USDC** — use TBA as collateral
3. **Repay** borrowed USDC at any time

To get TBA tokens: contact the deployer wallet — they hold the SUBSCRIBER_ROLE and can mint
more TBA via `IssuanceManager.subscribe(BASE_TOKEN_TBA, recipient, amount)`.
