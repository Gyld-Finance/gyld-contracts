# Euler V2 Integration — GyldBondToken

Complete record covering research, architecture, Base mainnet deployment,
lessons learned, and protocol comparison with Morpho Blue.

Deployer: `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd`
Deployed: 2026-05-19 on Base mainnet (chain ID 8453)

---

## Table of Contents

1. [What Is Euler V2](#1-what-is-euler-v2)
2. [Protocol Addresses (Base Mainnet)](#2-protocol-addresses-base-mainnet)
3. [Oracle Architecture](#3-oracle-architecture)
4. [Deployed Contracts](#4-deployed-contracts)
5. [Deployment Steps](#5-deployment-steps)
6. [Borrow Flow Reference](#6-borrow-flow-reference)
7. [UI Listing Problem](#7-ui-listing-problem)
8. [Key Lessons Learned](#8-key-lessons-learned)
9. [Comparison with Morpho Blue](#9-comparison-with-morpho-blue)
10. [Euler V1 Hack and V2 Security](#10-euler-v1-hack-and-v2-security)

---

## 1. What Is Euler V2

Euler V2 (Euler Vault Kit / EVK) is a modular lending protocol where anyone can
deploy isolated lending vaults for any ERC-20 token without permission. It launched
mid-2024 after a complete rewrite following the $197M V1 hack in March 2023.

**EVK (Euler Vault Kit)** — the vault framework. Each vault holds one underlying
asset and handles deposits, borrowing, interest accrual, and liquidations. Vaults
are ERC-4626 compliant.

**EVC (Ethereum Vault Connector)** — the orchestrator that links vaults together.
Lets one deposited asset serve as collateral across multiple borrowing vaults
simultaneously. Borrowers must register collateral (`enableCollateral`) and debt
controller (`enableController`) via the EVC before borrowing.

**Key difference from Morpho:** no single `createMarket()` call exists. Each
component (oracle adapter, router, IRM, vaults) is deployed separately. This is
a deliberate architectural tradeoff — the same oracle and IRM can be reused across
multiple vaults, enabling cross-vault collateral positions.

---

## 2. Protocol Addresses (Base Mainnet)

### Official Euler V2 Contracts (do not change)

| Contract | Address |
|---|---|
| EVC | `0x5301c7dD20bD945D2013b48ed0DEE3A284ca8989` |
| eVaultFactory | `0x7F321498A801A191a93C840750ed637149dDf8D0` |
| oracleRouterFactory | `0xA9287853987B107969f181Cce5e25e0D09c1c116` |
| kinkIRMFactory | `0x2d94C898a17f9D8c0bA75010A51cd61BF55b402E` |
| adaptiveCurveIRMFactory | `0xae752d786ecAf6683f61b7D910F221edD003895b` |
| oracleAdapterRegistry | `0x3cD76476bB7933A99Fa5bAa05446e71e07CDe0ca` |
| EscrowedCollateralPerspective | `0x977590fA311755DA2fa1421c1A944520b684f90F` |

> No official Euler V2 testnet deployment exists on Base Sepolia or Ethereum Sepolia.
> All Euler testing must be done on Base mainnet.

### Token and Infrastructure (shared with Morpho deployment)

| Contract | Address |
|---|---|
| TOKEN_TBA (GyldBondToken proxy) | `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` |
| NAVFeedForwarder (TBA) | `0x09907C78D4eB531495962120464BFd9044390337` |
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

---

## 3. Oracle Architecture

Euler's `ChainlinkOracle` adapter accepts `AggregatorV3Interface` feeds directly —
NAVFeedForwarder is plug-in compatible with no wrapper needed (unlike Morpho).

```
NAVFeedForwarder (AggregatorV3Interface, 8-decimal USD NAV)
  └─ ChainlinkOracle adapter
       ├─ base:         TBA token
       ├─ quote:        USDC
       ├─ feed:         NAVFeedForwarder
       └─ maxStaleness: 86400s (24h) — reverts if price older than this
            └─ EulerRouter V2
                 ├─ govSetConfig(TBA, USDC, chainlinkAdapter)
                 └─ govSetResolvedVault(escrowVault, true)
                      └─ Resolves: escrowVault shares → TBA amount (convertToAssets)
                           └─ Then prices: TBA → USDC via ChainlinkOracle adapter
                                └─ USDC Lending Vault oracle
```

**Why `govSetResolvedVault` is critical:**
The lending vault calls `oracle.getQuote(shares, escrowVaultAddress, USDC)`.
The router must know that `escrowVaultAddress` is a vault — it then calls
`escrowVault.convertToAssets(shares)` to get the TBA amount before pricing.
Without this registration: `revert PriceOracle_NotSupported(escrowVaultAddress, USDC)`.

**Verify after deploy:**
```bash
# 1 TBA → USDC (~$100)
cast call 0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d \
  'getQuote(uint256,address,address)(uint256)' \
  1000000000000000000 \
  0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3 \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  --rpc-url https://mainnet.base.org
# Result: 100000000 = $100.00 USDC ✅

# 1 USDC → TBA (~0.01 TBA)
cast call 0xe2Cf003AA0855D035c01c32B1cdEb081f7666428 \
  'getQuote(uint256,address,address)(uint256)' \
  1000000 \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3 \
  --rpc-url https://mainnet.base.org
# Result: 10000000000000000 = 0.01 TBA ✅
```

---

## 4. Deployed Contracts

| Step | Contract | Address | BaseScan |
|---|---|---|---|
| 1 | ChainlinkOracle adapter (TBA/USDC) | `0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d` | [view](https://basescan.org/address/0xC976C499a86aDAf73E4b258BDb3EB3A8e5BE134d) |
| 2 | EulerRouter V1 (retired — see note) | `0xe2Cf003AA0855D035c01c32B1cdEb081f7666428` | [view](https://basescan.org/address/0xe2Cf003AA0855D035c01c32B1cdEb081f7666428) |
| 3 | KinkIRM | `0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d` | [view](https://basescan.org/address/0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d) |
| 4 | TBA Escrow Vault | `0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4` | [view](https://basescan.org/address/0x155872FAA8c6C47BAE55cbE14deFb324663ec3F4) |
| 5a | EulerRouter V2 (active) | `0xBD8535B344293e96C0eFE7E9224aB54CE880471E` | [view](https://basescan.org/address/0xBD8535B344293e96C0eFE7E9224aB54CE880471E) |
| 5b | USDC Lending Vault | `0xCF8930030FbA9c8599A534304B94972762d79F71` | [view](https://basescan.org/address/0xCF8930030FbA9c8599A534304B94972762d79F71) |

> **Retired router note:** Step 2 router was deployed and configured with
> `govSetConfig(TBA, USDC, adapter)` but `govSetResolvedVault()` was missed before
> governance was renounced. A replacement (Router V2) was deployed in Step 5 with
> the correct full configuration.

### Escrow Vault State

| Property | Value |
|---|---|
| `asset()` | TBA `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` |
| `oracle()` | `address(0)` — collateral-only, no pricing needed |
| `unitOfAccount()` | `address(0)` — collateral-only |
| `governorAdmin()` | `address(0)` — renounced |

### Lending Vault State

| Property | Value |
|---|---|
| `asset()` | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| `oracle()` | EulerRouter V2 `0xBD8535B344293e96C0eFE7E9224aB54CE880471E` |
| `unitOfAccount()` | USDC |
| `interestRateModel()` | KinkIRM `0xE0EF36466d5d6Fce7764339d278Fe786a4cA573d` |
| Borrow LTV | 75% |
| Liquidation LTV | 80% |
| `governorAdmin()` | `address(0)` — renounced |

---

## 5. Deployment Steps

### Step 1 — ChainlinkOracle Adapter ✅

Parameters:

| | Value |
|---|---|
| base | TBA `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` |
| quote | USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| feed | NAVFeedForwarder `0x09907C78D4eB531495962120464BFd9044390337` |
| maxStaleness | 86400 (24h) |

| Action | Tx hash |
|---|---|
| Push fresh NAV price ($100.00) | [0x6c7137d9...](https://basescan.org/tx/0x6c7137d9b2206e112c9888e77b8ebda3691961af638a505228557c4d5f6d5022) |
| Deploy ChainlinkOracle adapter | [0xc4360c37...](https://basescan.org/tx/0xc4360c37ddc86b54bb3df1a0be53023086e88efd2d4fa5cd5cf0f556c9e58383) |

`OracleAdapterRegistry` at `0x3cD76476...` is owned by Euler Labs — we cannot register
our adapter there. Registration is optional; the adapter works without it.

### Step 2 — EulerRouter V1 (retired) ✅

Deployed and configured with `govSetConfig(TBA, USDC, adapter)`. Governance renounced.
**Missing:** `govSetResolvedVault(escrowVault, true)` — could not be added after governance
was renounced. Replaced in Step 5.

| Action | Tx hash |
|---|---|
| Deploy EulerRouter | [0xc1f0839e...](https://basescan.org/tx/0xc1f0839e19a1fcf0800b1289796ef81033261db1a98757bed16510993516143a) |
| `govSetConfig(TBA, USDC, adapter)` | [0xd286fa69...](https://basescan.org/tx/0xd286fa690a126864ab0e7d7dc2bba1ad530c140ec8ee462e44fda9f36c8dc9d2) |
| `transferGovernance(address(0))` | [0x701aec18...](https://basescan.org/tx/0x701aec184ffe39c8eb0361448d5e8b2c6e9f889b35aec674e1f196131082ef6d) |

### Step 3 — KinkIRM ✅

Rate curve: 0% base → 5% APY at 80% utilisation (kink) → 100% APY at 100%.

| Parameter | Value | Meaning |
|---|---|---|
| `baseRate` | `0` | 0% APY at 0% utilisation |
| `slope1` | `449,973,958` | Rate increase per util-unit below kink |
| `slope2` | `23,770,682,707` | Rate increase per util-unit above kink |
| `kink` | `3,435,973,836` | 80% utilisation (`floor(0.80 × 2^32)`) |

All rates in SPY (Second Percent Yield) scaled by 1e27. `kink` is `uint32` where `type(uint32).max = 100%` utilisation. Values verified using Euler's `calculate-irm-linear-kink.js` utility.

| Action | Tx hash | Block |
|---|---|---|
| Deploy KinkIRM | [0xdda2bab0...](https://basescan.org/tx/0xdda2bab0117e92a939bcfdb64e0c4676d1d0ebb6c7b368dfbe1e1a40be860315) | 46,197,616 |

IRM is immutable after deployment.

### Step 4 — TBA Escrow Vault ✅

Holds TBA as collateral only — no borrowing, no interest for depositors.
Users deposit TBA here to get vault shares, then use shares as collateral in the lending vault.

**trailingData format (critical):**
```solidity
// EVK requires abi.encodePacked(asset, oracle, unitOfAccount) = 60 bytes
// NOT just (oracle, unitOfAccount) = 40 bytes — that triggers E_ProxyMetadata()
bytes memory trailingData = abi.encodePacked(TBA, address(0), address(0));
```

| Action | Tx hash |
|---|---|
| `createProxy(address(0), true, trailingData)` | [0x7129e655...](https://basescan.org/tx/0x7129e655339f71071f829b8610d351c5ee193de5432eb81e34709a35b34c1dff) |
| `setHookConfig(address(0), 0)` | [0x3fab7b01...](https://basescan.org/tx/0x3fab7b016cbca1ff1ba7d1b58f0821ed9b875dfef389e99469af9f808cfa282b) |
| `setGovernorAdmin(address(0))` | [0xb5ead05b...](https://basescan.org/tx/0xb5ead05bc9a1dd2790d0ec4575bf6a197ae1253452cd2105ae041d0a7ac2c7ff) |

`EscrowedCollateralPerspective` at `0x977590fA...` enforces: `upgradeable=true`, zero governor, cleared hooked ops.

### Step 5 — EulerRouter V2 + USDC Lending Vault ✅

**Part A — Router V2** (fixes missing `govSetResolvedVault` from Step 2):

```solidity
router.govSetConfig(TBA, USDC, chainlinkAdapter);
router.govSetResolvedVault(escrowVault, true);  // critical — enables solvency checks
router.transferGovernance(address(0));
```

| Action | Tx hash |
|---|---|
| Deploy EulerRouter V2 | [0x885f24dd...](https://basescan.org/tx/0x885f24dda4469358321fba8211cc1c61054bb40ff6d7b088a46e8afda6a4be06) |
| `govSetConfig(TBA, USDC, adapter)` | [0x6e552a73...](https://basescan.org/tx/0x6e552a73dd62d4166e243212c4dcd9a165ea9309613fbb39db3c3950fed8a7e2) |
| `govSetResolvedVault(escrowVault, true)` | [0x7fb81d5d...](https://basescan.org/tx/0x7fb81d5d365278454003bd07aa0ab4c63ddd71f9c70e924bdc83f8b1b1bcfda8) |
| `transferGovernance(address(0))` | [0x35eccb25...](https://basescan.org/tx/0x35eccb25284bd782b51fabaa14b90cb67859a87b51a33b7c88d797f47f420381) |

**Part B — USDC Lending Vault:**

```solidity
// trailingData = abi.encodePacked(USDC, routerV2, USDC)
// asset=USDC, oracle=routerV2, unitOfAccount=USDC
```

LTV: 75% borrow / 80% liquidation. Gap of 5pp gives liquidators an incentive window.

| Action | Tx hash |
|---|---|
| Deploy USDC lending vault | [0xf1fe3a76...](https://basescan.org/tx/0xf1fe3a760e2b3381161246708768a4c0d97610899dd97dfe9d3d2ba2ad1acb04) |
| `setInterestRateModel(KinkIRM)` | [0x0ac0e768...](https://basescan.org/tx/0x0ac0e76848a4c66fe94154dd08b17ae1cb3efdfcbae56baf1387d54b52df01ea) |
| `setHookConfig(address(0), 0)` | [0x0af7685e...](https://basescan.org/tx/0x0af7685e1658eb94dabd7b5d9100849fd8a8127a0403eff2b3c7ed046b8d5a44) |
| `setLTV(escrowVault, 7500, 8000, 0)` | [0x9b161e60...](https://basescan.org/tx/0x9b161e607c91d2e16a9773a8938a1701fe59cd85e528b99a52dfa6fa5cd5c0b7) |
| `setGovernorAdmin(address(0))` | [0x7d8db020...](https://basescan.org/tx/0x7d8db02039f4e606724bd21a7047d6367b5a703f8f6d00e9e79c31fe4244c9ef) |

### Step 6 — Seed and Verify ✅

Deployer acts as both lender and borrower to verify the full flow end-to-end.

| Action | Tx hash |
|---|---|
| `USDC.approve(lendingVault)` | [0x4912ecaf...](https://basescan.org/tx/0x4912ecafe9502a238a04e3e286def42862d65996c49f4ac453e77883760b8012) |
| `lendingVault.deposit(755962 USDC)` | [0xde25ea37...](https://basescan.org/tx/0xde25ea37f998d355cb8eba601a3a1a0c664bbcc9a406e515a6d70e5637b68f2f) |
| `TBA.approve(escrowVault)` | [0xd6163cca...](https://basescan.org/tx/0xd6163ccaa2106094cf42680662ad9f5104f9c64ca095231eac3aff64125f32e9) |
| `escrowVault.deposit(0.5 TBA)` | [0x838bdad1...](https://basescan.org/tx/0x838bdad1fdd5eba547ed0d8690bef0d024c8f625847207fde0df323c6d7bf3e0) |
| `EVC.enableCollateral(deployer, escrowVault)` | [0xe0371d6d...](https://basescan.org/tx/0xe0371d6d142cd03a0b7ac5b3ba2f1078ec1facbccac6d1321d086c0678c404b7) |
| `EVC.enableController(deployer, lendingVault)` | [0x9aed99b2...](https://basescan.org/tx/0x9aed99b2f72a1fc7b6db42c241a7e1c21436af550af192da600fcf8478dc463c) |
| `lendingVault.borrow(300000 USDC)` | [0xd0f33df5...](https://basescan.org/tx/0xd0f33df51db90af9e95693c56cbfb3f675ce8acfde40a81fad6354f31dc56e86) |

Post-borrow state verified on-chain:

| Metric | Value |
|---|---|
| `totalAssets` | 755,962 USDC |
| `totalBorrows` | 300,000 USDC (~40% utilisation, below kink) |
| `debtOf(deployer)` | 300,000 |
| `escrowVault.balanceOf(deployer)` | 500,000,000,000,000,000 (0.5 TBA shares) |

---

## 6. Borrow Flow Reference

```
# Lender side
USDC.approve(lendingVault, amount)
lendingVault.deposit(assets, receiver)          ← ERC-4626, returns shares

# Borrower side — must happen in this order
TBA.approve(escrowVault, amount)
escrowVault.deposit(assets, receiver)           ← ERC-4626, returns escrow shares
EVC.enableCollateral(account, escrowVault)      ← register collateral source
EVC.enableController(account, lendingVault)     ← register debt controller
lendingVault.borrow(assets, receiver)           ← draw USDC

# Repay
USDC.approve(lendingVault, amount)
lendingVault.repay(assets, receiver)

# Withdraw collateral
escrowVault.withdraw(assets, receiver, owner)   ← only if position is healthy
```

`EVC.enableCollateral` and `EVC.enableController` must be called BEFORE `borrow()`.
The lending vault's solvency check reads EVC state to verify these registrations.

---

## 7. UI Listing Problem

Permissionless Euler vaults do **not** appear on `app.euler.finance` automatically.

| Step | Morpho | Euler |
|---|---|---|
| Deploy market/vault | Instant public URL | Nothing on UI |
| Share with teammates | Share `app.morpho.org` URL | BaseScan or direct `cast call` only |
| Get on official UI | Instant (automatic) | Submit PR to `euler-labels` repo → Euler Labs review |

Third-party aggregators (vaults.fyi, DefiLlama) do index EVK vaults permissionlessly —
our vault may eventually appear there, but with no timeline guarantee.

**Bottom line:** if the goal is a shareable link teammates can open immediately,
Euler does not provide that without manual intervention from Euler Labs.

---

## 8. Key Lessons Learned

### 1. EVK trailingData must be 60 bytes, not 40

`createProxy()` expects `abi.encodePacked(asset, oracle, unitOfAccount)`.
`asset` comes first and must be a non-zero deployed contract.
Passing only `(oracle, unitOfAccount)` = 40 bytes triggers `E_ProxyMetadata()`.

```solidity
// Wrong — triggers E_ProxyMetadata()
bytes memory bad = abi.encodePacked(address(0), address(0));  // 40 bytes

// Correct
bytes memory good = abi.encodePacked(TBA, address(0), address(0));  // 60 bytes
```

### 2. govSetResolvedVault must be called before governance is renounced

The lending vault calls `oracle.getQuote(shares, escrowVaultAddress, USDC)`.
The router needs `govSetResolvedVault(escrowVault, true)` to resolve
`escrowVaultAddress → TBA` before pricing. Missing this causes every solvency check
to revert. Configure the router fully, then renounce — never the reverse.

Correct sequence:
```solidity
router.govSetConfig(TBA, USDC, chainlinkAdapter);
router.govSetResolvedVault(escrowVault, true);   // ← do not skip
router.transferGovernance(address(0));            // ← renounce LAST
```

### 3. BaseScan shows "execution reverted" on successful EVault deposits

This is a display artifact from the EVC's deferred liquidity check mechanism.
When `deposit()` is called, the EVC internally calls `checkVaultStatus()` via a
try/catch probe — an intentional internal revert that BaseScan surfaces as
"execution reverted" even though the outer transaction completed successfully.

**Verify success by checking token transfer events, not the revert label.**
If TBA transferred in and vault shares transferred out — the deposit succeeded.

### 4. No single-step createMarket() equivalent exists

Euler V2 has no `createMarket()` shortcut. The 6-step multi-contract path is the
canonical approach for any new ERC-20 with a custom oracle. Verified against
official Euler documentation and whitepaper.

### 5. EVC registration calls are required before borrowing

Two EVC calls must precede `borrow()`:
- `EVC.enableCollateral(account, escrowVault)` — marks the escrow vault as a collateral source
- `EVC.enableController(account, lendingVault)` — authorises the lending vault to freeze collateral

Skipping either causes `borrow()` to revert with an EVC access control error.

---

## 9. Comparison with Morpho Blue

See `morpho-integration.md` for the full Morpho deployment. Summary:

| Dimension | Euler V2 | Morpho Blue |
|---|---|---|
| Steps to create market | 6 | 2 |
| Total contracts we deploy | 5 | 1 |
| UI auto-listing | No — manual `euler-labels` PR | Yes — instant on `app.morpho.org` |
| Oracle wrapper needed | No — direct `AggregatorV3Interface` | Yes — `MorphoChainlinkOracleV2` |
| IRM | Deploy custom `KinkIRM` | Use pre-deployed `AdaptiveCurveIRM` |
| Collateral model | Escrow vault + lending vault (ERC-4626) | Unified market |
| Borrow flow steps | 7 calls (incl. 2 EVC registrations) | 5 calls |
| Liquidation | Dutch auction | Fixed discount at creation |
| Cross-vault collateral | Yes — EVC links vaults | No — strictly isolated |

**When to use Euler:** cross-vault collateral positions, governed risk management,
or when Euler Labs lists the vault for production use.
**When to use Morpho:** quick test with shareable UI link, simplest deployment path.

---

## 10. Euler V1 Hack and V2 Security

The $197M V1 hack (March 2023) was caused by `donateToReserves()` allowing
attackers to manipulate their own health check via flash loans.

V2 response:
- Complete rewrite with isolated-vault modular design — a compromise in one vault
  cannot cascade to others
- 60+ security reviews by 16+ firms: OpenZeppelin, Spearbit, Certora, Trail of Bits,
  Zellic, Ottersec, and others
- Certora formal verification proved accounts stay solvent under all conditions —
  this would have mathematically prevented the V1 exploit
- $4M+ spent on security before launch, $7.5M active bug bounty on Cantina
- Running in production since mid-2024 across 15+ chains without major incidents
