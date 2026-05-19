# Euler V2 — GyldBondToken Integration Research

Research date: 2026-05-19.
This document covers what Euler V2 is, how it compares to Morpho Blue, whether we can
do a similar quick mainnet test, and why the UI experience is fundamentally different.

---

## 1. What Is Euler V2

Euler V2 (also called the Euler Vault Kit / EVK) is a modular lending protocol where
anyone can deploy isolated lending vaults for any ERC-20 token without permission from
anyone. It launched in mid-2024 after a complete rewrite following the $197M V1 hack in
March 2023.

Two core components:

**EVK (Euler Vault Kit)** — the vault framework. Each vault holds one underlying asset
and handles deposits, borrowing, interest accrual, and liquidations independently. Vaults
are ERC-4626 compliant.

**EVC (Ethereum Vault Connector)** — the orchestrator that links vaults together. It lets
one deposited asset serve as collateral across multiple borrowing vaults simultaneously.
This is the key architectural difference from Morpho where each market is strictly isolated.

---

## 2. Euler V2 vs Morpho Blue — Full Comparison

| Dimension | Morpho Blue | Euler V2 |
|---|---|---|
| **Permissioned?** | No — fully open | No — fully open |
| **On Base mainnet?** | Yes | Yes |
| **Market structure** | Strictly isolated — 1 collateral + 1 loan asset + 1 oracle per market | Isolated single-asset vaults linked by EVC — one deposit can collateralise loans across multiple vaults |
| **Oracle format** | Custom `price()` — needed `MorphoChainlinkOracleV2` wrapper | `ChainlinkOracle` adapter accepts any `AggregatorV3Interface` directly — **NAVFeedForwarder works without a wrapper** |
| **Steps to create market** | 1 — single `createMarket()` call, 5 parameters | 4–6 steps: oracle adapter + router + IRM + vault(s) |
| **Instant UI listing?** | Yes — every market appears on `app.morpho.org` immediately | **No** — permissionless vaults are invisible on `app.euler.finance` until manually labeled by Euler Labs |
| **Liquidation model** | Fixed discount set at market creation | Dutch auction — discount starts small and grows dynamically as health worsens |
| **Collateral rehypothecation** | No — collateral is locked, cannot be lent out | Yes — governed vaults can lend out deposited collateral, earning extra yield for depositors |
| **Risk parameters** | Immutable after `createMarket()` | Choice: governed (mutable by curator) or ungoverned (permanently immutable) |
| **Interest rate model** | AdaptiveCurveIRM (fixed at creation) | Kink IRM or Adaptive Curve IRM — configurable at deployment |
| **V1 security incident** | N/A | $197M hack in March 2023 (V1). V2 is a full rewrite with 60+ audits and formal verification. |

---

## 3. Is Our Oracle Compatible

Yes. Euler V2 uses a `ChainlinkOracle` adapter that calls `AggregatorV3Interface.latestRoundData()`
directly — the same interface our `NAVFeedForwarder` implements.

| Protocol | Oracle needed | Wrapper needed |
|---|---|---|
| Morpho Blue | `MorphoChainlinkOracleV2` wrapping `NAVFeedForwarder` | Yes — Morpho uses a different `price()` format |
| Euler V2 | `ChainlinkOracle` adapter pointing at `NAVFeedForwarder` | No — directly compatible |
| Aave V3 | `AaveOracle.setAssetSources` pointing at `NAVFeedForwarder` | No — directly compatible |

One thing to verify: `ChainlinkOracle` has a configurable `maxStaleness` parameter. If no
NAV price has been pushed recently enough, the adapter reverts. We must push a fresh price
before deploying or the vault will be unusable from birth.

---

## 4. Contract Addresses on Base Mainnet (Official)

Source: [euler-xyz/euler-interfaces — EulerChains.json](https://github.com/euler-xyz/euler-interfaces)

| Contract | Address |
|---|---|
| EVC | `0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989` |
| eVaultFactory | `0x7F321498A801A191a93C840750ed637149dDf8D0` |
| oracleRouterFactory | `0xA9287853987B107969f181Cce5e25e0D09c1c116` |
| oracleAdapterRegistry | `0x3cD76476bB7933A99Fa5bAa05446e71e07CDe0ca` |
| kinkIRMFactory | `0x2d94C898a17f9D8c0bA75010A51cd61BF55b402E` |
| adaptiveCurveIRMFactory | `0xae752d786ecAf6683f61b7D910F221edD003895b` |

There is no official Euler V2 testnet deployment on Base Sepolia or Ethereum Sepolia.

---

## 5. The UI Problem — Why We Will Not Get a Link Like Morpho

This is the most important practical difference for testing purposes.

### What happened with Morpho

When we called `createMarket()` on Morpho Blue, the market immediately appeared at:
```
https://app.morpho.org/base/market/0x9840633...
```
Anyone with that URL could open it, see the market parameters, supply USDC, and borrow.
No action required from the Morpho team. The UI indexes all markets permissionlessly.

### What happens with Euler

When we deploy vaults on Euler V2, **nothing appears on `app.euler.finance`**.

The official Euler UI uses a manual labeling/verification system. Vault metadata
(name, description, risk tier, curator) is maintained in a GitHub repository called
`euler-labels`. A vault that is not in that repo simply does not show up in the UI.
There is no automatic indexing of permissionless vaults.

This is a deliberate product decision by Euler Labs — they want the UI to show curated,
reviewed vaults rather than every permissionless deployment. From their perspective it
protects users from interacting with poorly configured or malicious vaults.

### The consequence for us

| Step | Morpho | Euler |
|---|---|---|
| Deploy market/vault | Instant public URL | Nothing on UI |
| Share with teammates | Share the URL | Cannot share a UI link |
| Teammates interact | Via `app.morpho.org` | Must use BaseScan read/write or direct `cast call` |
| Get on official UI | Instant (automatic) | Submit PR to `euler-labels` repo → Euler Labs review → merge → UI update |

Third-party aggregators like **vaults.fyi** and **DefiLlama** do index all EVK vaults
permissionlessly — so our vault would eventually appear there. But there is no timeline
guarantee and these are not the primary Euler UI that most users go to.

### Bottom line

If the goal is a shareable link that teammates can open and interact with immediately,
**Euler does not give us that today without manual intervention from the Euler Labs team.**
Morpho remains the better protocol for quick permissionless testing with a public UI.

---

## 6. What the Deployment Would Look Like (If We Proceed)

Unlike Morpho's single `createMarket()`, Euler requires 6 steps:

**Step 1 — Deploy ChainlinkOracle adapter**
Points at `NAVFeedForwarder`. Configures `maxStaleness` (e.g. 86400 = 24 hours).
```
ChainlinkOracle(base=TBA, quote=USDC, feed=NAVFeedForwarder, maxStaleness=86400)
```

**Step 2 — Deploy EulerRouter**
The router dispatches price queries to the right adapter per asset pair.
```
oracleRouterFactory.deploy(governor=deployer)
router.govSetConfig(TBA, USDC, chainlinkAdapter)
```

**Step 3 — Deploy KinkIRM**
Interest rate model. Parameters: base rate, kink rate, max rate, kink utilisation.
```
kinkIRMFactory.deploy(baseRate, kinkRate, maxRate, kinkUtilisation)
```

**Step 4 — Deploy escrowed collateral vault for TBA**
Holds TBA as collateral only — no borrowing out of it, no interest for depositors.
```
eVaultFactory.createProxy(asset=TBA, upgradeable=false)
```

**Step 5 — Deploy lending vault for USDC**
This is where borrowers get USDC and lenders earn yield.
```
eVaultFactory.createProxy(asset=USDC, upgradeable=false)
// configure: oracle=router, IRM=kinkIRM, LTV for TBA collateral, caps
```

**Step 6 — Seed USDC into the lending vault**
Standard ERC-4626 `deposit()` — no special seeding mechanism like Morpho.
```
USDC.approve(lendingVault, amount)
lendingVault.deposit(amount, receiver)
```

After this the vaults are live on-chain. Interaction is via direct contract calls or
BaseScan until Euler Labs labels them.

---

## 7. Governed vs Ungoverned Vaults

Euler gives a choice at deployment time that Morpho does not:

**Ungoverned vault** — governor is set to `address(0)` at deployment. All parameters
(LTV, IRM, caps, oracle) are permanently immutable. Trustless — no one can change the
rules after launch. Same philosophy as Morpho.

**Governed vault** — governor is a multisig or DAO. Parameters can be adjusted as
market conditions change. Better for active risk management but introduces curator trust.

For our test we would use ungoverned vaults to keep it simple and trustless.

---

## 8. Euler V1 Hack and V2 Security

The $197M V1 hack (March 2023) was caused by a `donateToReserves()` function that
inadvertently allowed attackers to manipulate their own health check via flash loans.

V2 response:
- Complete rewrite with isolated-vault modular design — a compromise in one vault
  cannot cascade to others
- 60+ security reviews by 16+ firms: OpenZeppelin, Spearbit, Certora, Trail of Bits,
  Zellic, Ottersec, and others
- Certora formal verification proved the "Holy Grail" property: accounts stay solvent
  under all conditions — this would have mathematically prevented the V1 exploit
- $4M+ spent on security before launch, $7.5M active bug bounty on Cantina
- Running in production since mid-2024 across 15+ chains without major incidents

---

## 9. Recommendation

| Goal | Best choice |
|---|---|
| Quick permissionless mainnet test with shareable UI link | **Morpho Blue** (already done) |
| Cross-vault collateral (one TBA deposit backs multiple borrows) | Euler V2 |
| Active risk management (adjust LTV/caps over time) | Euler V2 (governed vault) |
| Production mainnet listing on a well-known protocol UI | Aave V3 (governance) or Euler V2 (with euler-labels PR) |

Euler V2 is technically compatible with our stack and is fully permissionless on Base
mainnet. The blocker for a Morpho-equivalent test is the UI — not the contracts.
If Euler Labs labels our vault, the experience becomes comparable to Morpho.

The practical path: complete the Morpho test (done), then pursue Euler if cross-vault
or governed-vault features become relevant for the product.
