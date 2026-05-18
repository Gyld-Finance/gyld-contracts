# Aave V3 — GyldBondToken Listing Research & Roadmap

Research date: 2026-05-18.
This document covers what is needed to list a GyldBondToken (e.g. TBA) on Aave V3,
how Aave differs from Morpho Blue, and the three testing paths available.

---

## 1. Morpho Blue vs Aave V3 — Key Differences

| Dimension | Morpho Blue | Aave V3 |
|---|---|---|
| **Market creation** | Permissionless — anyone calls `createMarket()`. Done in minutes. No governance. | Permissioned — requires `ASSET_LISTING_ADMIN` or `POOL_ADMIN` role. Both are governance-controlled on mainnet. Cannot list without a governance vote. |
| **Oracle format** | Custom `price()` returning `uint256` — needed `MorphoChainlinkOracleV2` wrapper to convert NAV → Morpho price format | Standard Chainlink `latestAnswer()` returning 8-decimal USD `int256` — **NAVFeedForwarder is directly compatible, no wrapper needed** |
| **Liquidity model** | Isolated per market — each market has its own supply/borrow pool | Shared pool — all suppliers share one pool, exposed to collective risk of all listed assets |
| **Risk parameters** | Set once at `createMarket()` time (LLTV only), immutable | Set and adjusted by governance / risk admins (LTV, liquidation threshold, bonus, caps, isolation mode) |
| **Listing time** | Instant | Minimum 10 days (fast track), 4–8 weeks typical for new assets |
| **Listing authority** | No one — open to all | Governance vote (AAVE/stkAAVE token holders, 320k quorum) |
| **Isolation mode** | N/A — each market is already isolated | Required for new/unproven assets. Caps total USD debt against the asset. |
| **Emergency bypass** | N/A | Protocol Emergency Guardian (5-of-9) can pause/freeze but **cannot list new assets** |

### Why the shared pool matters for us

In Morpho, a bad oracle on the TBA market only affects TBA/USDC borrowers. In Aave, every
asset in the pool shares risk — a broken TBA oracle could impact all Aave Base suppliers.
This is why Aave governance is strict about new listings and almost always requires isolation
mode with conservative caps first.

---

## 2. Oracle Compatibility — Good News

Unlike Morpho (which required a `MorphoChainlinkOracleV2` wrapper), Aave is simpler:

| | Morpho | Aave |
|---|---|---|
| Oracle interface | `price()` → `uint256` in `10^(36 + quoteDecimals - baseDecimals)` format | `latestAnswer()` → `int256` USD price, 8 decimals |
| What we deployed | `MorphoChainlinkOracleV2` wrapping `NAVFeedForwarder` | **Register `NAVFeedForwarder` directly** |
| Wrapper needed? | Yes | **No** |

`NAVFeedForwarder` implements `AggregatorV3Interface` which exposes `latestAnswer()`.
It returns NAV in 8-decimal USD (e.g. `10000000000` = $100.00) — exactly what `AaveOracle` expects.

`AaveOracle.setAssetSources([tokenAddress], [NAVFeedForwarder])` is all that is needed.

One edge case to verify: `AaveOracle` reverts if `latestAnswer()` returns zero or negative.
`NAVFeedForwarder` forwards the latest round from `KaleidoscopeNAVFeed` — if no price has
been pushed, `latestAnswer()` returns 0. Always push a price before registering the oracle.

---

## 3. Contract Addresses

### Aave V3 on Base Mainnet (official — do not change)

| Contract | Address | BaseScan |
|---|---|---|
| PoolAddressesProvider | `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D` | [view](https://basescan.org/address/0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D) |
| Pool (proxy) | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` | [view](https://basescan.org/address/0xA238Dd80C259a72e81d7e4664a9801593F98d1c5) |
| PoolConfigurator | `0x5731a04B1E775f0fdd454Bf70f3335886e9A96be` | [view](https://basescan.org/address/0x5731a04B1E775f0fdd454Bf70f3335886e9A96be) |
| AaveOracle | `0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156` | [view](https://basescan.org/address/0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156) |
| ACLManager | `0x43955b0899Ab7232E3a454cf84AedD22Ad46FD33` | [view](https://basescan.org/address/0x43955b0899Ab7232E3a454cf84AedD22Ad46FD33) |

Source: [bgd-labs/aave-address-book — AaveV3Base.sol](https://github.com/bgd-labs/aave-address-book/blob/main/src/AaveV3Base.sol)

### Aave V3 on Base Sepolia Testnet

| Contract | Address |
|---|---|
| PoolAddressesProvider | `0xE4C23309117Aa30342BFaae6c95c6478e0A4Ad00` |
| Pool | `0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27` |
| PoolConfigurator | `0x0Bf6bdFF4da24C272BC524d521Ab0db20601D384` |
| AaveOracle | `0x943b0dE18d4abf4eF02A85912F8fc07684C141dF` |
| ACLManager | `0x9f09F541Adf314341d8d45E5B18961147b9050E9` |

Source: [bgd-labs/aave-address-book — AaveV3BaseSepolia.sol](https://github.com/bgd-labs/aave-address-book/blob/main/src/AaveV3BaseSepolia.sol)

Note: On the public Base Sepolia deployment, `POOL_ADMIN` is held by the Aave/BGD team —
we do not have direct admin access. Use Path A (fork) or Path B (own deployment) for testing.

---

## 4. Risk Parameters We Would Propose

These are starting values for a bond token in isolation mode. Final values require a risk
service provider (Chaos Labs or BGD) sign-off before any mainnet governance proposal.

| Parameter | Proposed value | Rationale |
|---|---|---|
| Mode | Isolation | Required for new/unproven asset. Limits protocol-wide exposure. |
| LTV | 0% as collateral (isolation) | In isolation mode the collateral LTV is effectively capped by the debt ceiling. Set 0 for simple collateral-only use. |
| Liquidation Threshold | 75% | Conservative for bond — real bond NAV moves slowly. |
| Liquidation Bonus | 5% (10500 bps) | Standard. Incentivises liquidators without over-discounting. |
| Debt Ceiling | $100,000 USD | Isolation mode hard cap on total borrows against TBA. |
| Supply Cap | 10,000 TBA | Limits protocol exposure while testing demand. |
| Borrow Cap | 0 (not borrowable) | Bond tokens should be collateral only, not borrowable assets. |
| Reserve Factor | 10% | 10% of interest income to Aave treasury. Standard for new assets. |
| Borrowable in isolation | USDC, USDT, GHO | Only stablecoins borrowable against isolated collateral. |

---

## 5. The Governance Process (Path C — Mainnet)

### Full process for a brand new asset

| Stage | Platform | Duration |
|---|---|---|
| 1. Temp Check forum post | governance.aave.com | 5 days |
| 2. Temp Check Snapshot vote | snapshot.org | 3 days |
| 3. ARFC (Aave Request for Final Comments) | governance.aave.com | 5 days |
| 4. ARFC Snapshot vote | snapshot.org | 3 days |
| 5. AIP on-chain vote | vote.onaave.com | 3 days |
| 6. Short Executor timelock | Ethereum mainnet | 1 day |

**Minimum: ~20 days. Realistic with delays: 4–8 weeks.**

### Fast track (asset already listed on another Aave market)

Skips Temp Check forum + Snapshot entirely. Requires:
- ARFC + ARFC Snapshot + AIP only (~10 days minimum)
- Chainlink price feed live for 90+ days
- Supply cap ≤ 50% of on-chain token supply
- Risk service provider feedback (Chaos Labs / BGD)

### Who votes

- Tokens: AAVE, stkAAVE (staked AAVE in Safety Module), aAAVE (AAVE supplied to Aave V3 Ethereum)
- Quorum: 320,000 votes required on both sides
- Voting power is based on Ethereum mainnet balances — even for Base listings

### No bypass exists for listings

The Protocol Emergency Guardian (5-of-9 multisig) holds `EMERGENCY_ADMIN` — it can
pause or freeze reserves but **cannot list new assets**. There is no shortcut.

---

## 6. Testing Roadmap — Three Paths

### Path A — Local Fork Test (recommended first step)

**Goal:** Verify GyldBondToken works end-to-end on Aave V3 before touching any live network.
**Cost:** Zero ETH. No deployment. Runs in CI.
**Time:** 1–2 days to write the Forge test.

Steps:
1. Fork Base mainnet in Foundry test: `vm.createFork("https://mainnet.base.org")`
2. Impersonate an existing `POOL_ADMIN` address (readable from ACLManager on-chain)
3. Grant our deployer `ASSET_LISTING_ADMIN` via `ACLManager.addAssetListingAdmin(deployer)`
4. Register `NAVFeedForwarder` as TBA price source: `AaveOracle.setAssetSources([TBA], [forwarder])`
5. Call `PoolConfigurator.initReserves([...TBA params...])` — deploys aTBA + variableDebtTBA
6. Set isolation mode, debt ceiling, supply cap, liquidation params via PoolConfigurator
7. Test: supply TBA → borrow USDC → repay → withdraw
8. Test: simulate price drop via `vm.mockCall` on NAVFeedForwarder → trigger liquidation
9. Assert: Chainalysis oracle does not block Aave Pool address (it should not be sanctioned)

**Deliverable:** `AaveV3Integration.t.sol` — a Forge fork test that lives in the repo and
runs in CI. Proves compatibility before any live deployment.

**Key unknown to resolve in this test:**
- Does Aave's aToken `transfer()` trigger GyldBondToken's Chainalysis check?
  (It should not — aTBA is a separate ERC-20; the underlying TBA only moves on supply/withdraw/liquidation)
- Does Aave Pool address pass Chainalysis screening? (Yes — it is not sanctioned)
- Does `latestAnswer()` on NAVFeedForwarder return the correct 8-decimal price? (Should — needs assertion)

---

### Path B — Own Aave V3 Deployment on Base Sepolia (public testnet)

**Goal:** Shareable public testnet market — teammates can interact via Aave UI.
**Cost:** Minimal Sepolia ETH for gas.
**Time:** 3–5 days.

Steps:
1. Clone `aave-v3-deploy` and deploy a fresh Aave V3 instance to Base Sepolia (chain ID 84532)
   — deployer holds all admin roles, no governance needed
2. Deploy TBA token on Base Sepolia using a modified `DeployBaseTest.s.sol`:
   - Chain guard: `require(block.chainid == 84532)`
   - Use `MockSanctionsList` (Chainalysis oracle is not deployed on testnets)
3. Push NAV price to `KaleidoscopeNAVFeed`
4. Register `NAVFeedForwarder` as TBA oracle in our Aave instance's `AaveOracle`
5. List TBA via `PoolConfigurator.initReserves` + configure isolation mode params
6. Seed: supply TBA + borrow USDC
7. Share the Aave testnet UI link pointing at our custom pool

**Deliverable:** `DeployAaveBaseSepolia.s.sol` + shareable testnet URL.

**Complication:** The Aave UI at `app.aave.com` only shows known pool addresses. A custom
deployment would need a custom UI or direct contract interaction. Use `cast call` or
BaseScan's Read Contract for teammate demos until the UI is configured.

---

### Path C — Base Mainnet Governance Listing (production)

**Goal:** TBA listed on official Aave V3 Base — visible to all Aave users.
**Cost:** Governance proposal fees + risk provider engagement + ~$20–50 in gas.
**Time:** 4–8 weeks minimum.

Pre-requisites before submitting:
- [ ] NAVFeedForwarder has been live and pushing prices for 90+ days
- [ ] Path A fork test passes — proves technical compatibility
- [ ] Risk report commissioned from Chaos Labs or BGD Labs
- [ ] Internal legal sign-off on listing a tokenised bond on a public DeFi protocol
- [ ] AAVE token holders with 320k+ voting power willing to support

Governance payload needs to call (via Short Executor after vote):
```solidity
AaveOracle.setAssetSources([TBA], [NAVFeedForwarder]);
PoolConfigurator.initReserves([InitReserveInput{...}]);
PoolConfigurator.setReserveIsolationMode(TBA, true);
PoolConfigurator.setDebtCeiling(TBA, 10_000_00); // $10,000 in Aave units
PoolConfigurator.setSupplyCap(TBA, 10_000);
PoolConfigurator.configureReserveAsCollateral(TBA, 0, 7500, 10500);
```

**Deliverable:** AIP payload contract + governance forum posts + on-chain vote.

---

## 7. Immediate Next Actions

| Priority | Action | Path |
|---|---|---|
| 1 | Write `AaveV3Integration.t.sol` fork test | Path A |
| 2 | Confirm `NAVFeedForwarder.latestAnswer()` returns correct price on Base | Path A |
| 3 | Confirm Aave Pool address (`0xA238Dd...`) is not sanctioned by Chainalysis | Path A |
| 4 | Decide: do we need a public testnet (Path B) or is fork test sufficient? | Path B |
| 5 | Commission risk report | Path C pre-req |

---

## 8. Open Questions

1. **aToken transfers and Chainalysis:** When a user supplies TBA, Aave calls `transferFrom(user, aavePool, amount)` on GyldBondToken. This hits `_update()` which screens both addresses via Chainalysis. Aave Pool should pass. But during liquidation, Aave transfers TBA to the liquidator — if the liquidator is a smart contract, does Chainalysis screen it? Need to verify in fork test.

2. **NAVFeedForwarder price staleness:** AaveOracle has no built-in staleness check on the feed — it just calls `latestAnswer()`. If we stop pushing NAV prices, the price goes stale silently. We should consider wrapping NAVFeedForwarder in a CAPO (Capped Asset Price Oracle) or adding staleness revert logic before a mainnet listing.

3. **Isolation mode only vs full collateral:** Initially isolation mode is the right choice. The path to full collateral (non-isolated) requires a separate governance proposal after the asset proves itself — potentially 6–12 months after initial listing.

4. **GHO borrowing:** Aave has its own stablecoin GHO on Base. Whether GHO is enabled as borrowable-in-isolation for TBA is a governance decision — worth including in the AIP if we pursue Path C.
