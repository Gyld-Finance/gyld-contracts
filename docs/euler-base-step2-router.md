# Euler V2 Base Mainnet — Step 2: EulerRouter

Deployed on Base mainnet on 2026-05-19.

---

## What Step 2 Does

Deploys and configures an `EulerRouter` — the price dispatcher that sits between
Euler vaults and the underlying oracle adapters.

Euler vaults never call oracle adapters directly. They call
`router.getQuote(amount, base, quote)`. The router looks up which adapter is
registered for that pair and forwards the call. One router serves all vaults in
a cluster.

**Three transactions in this step:**
1. Deploy the router (via `oracleRouterFactory.deploy(governor)`)
2. Configure the TBA/USDC route to use our ChainlinkOracle adapter
3. Renounce governance — router becomes permanently immutable

---

## Why Governance Is Renounced Immediately

The router constructor requires a non-zero governor so it can be configured.
After configuration we call `transferGovernance(address(0))` to make it
immutable. This means:
- No one can change the TBA/USDC route in future
- No one can add new routes
- Vaults that point to this router trust it will never be tampered with

This is the same trustless philosophy as our Morpho setup — immutable once deployed.

---

## Deployed Address

| Contract | Address | BaseScan |
|---|---|---|
| **EulerRouter** | **`0xe2Cf003AA0855D035c01c32B1cdEb081f7666428`** | [view](https://basescan.org/address/0xe2Cf003AA0855D035c01c32B1cdEb081f7666428) |

---

## Transactions

| Action | Tx hash | Notes |
|---|---|---|
| Deploy EulerRouter | [0xc1f0839e...](https://basescan.org/tx/0xc1f0839e19a1fcf0800b1289796ef81033261db1a98757bed16510993516143a) | Via `oracleRouterFactory.deploy(deployer)` |
| `govSetConfig(TBA, USDC, adapter)` | [0xd286fa69...](https://basescan.org/tx/0xd286fa690a126864ab0e7d7dc2bba1ad530c140ec8ee462e44fda9f36c8dc9d2) | One call covers both TBA→USDC and USDC→TBA |
| `transferGovernance(address(0))` | [0x701aec18...](https://basescan.org/tx/0x701aec184ffe39c8eb0361448d5e8b2c6e9f889b35aec674e1f196131082ef6d) | Router is now permanently immutable |

---

## Verification

Confirmed `getQuote` returns correct prices through the router in both directions:

```bash
# 1 TBA -> USDC (should be 100000000 = $100.00)
cast call 0xe2Cf003AA0855D035c01c32B1cdEb081f7666428 \
  'getQuote(uint256,address,address)(uint256)' \
  1000000000000000000 \
  0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3 \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  --rpc-url https://mainnet.base.org
# Result: 100000000 = $100.00 USDC ✅

# 1 USDC -> TBA (should be 10000000000000000 = 0.01 TBA)
cast call 0xe2Cf003AA0855D035c01c32B1cdEb081f7666428 \
  'getQuote(uint256,address,address)(uint256)' \
  1000000 \
  0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3 \
  --rpc-url https://mainnet.base.org
# Result: 10000000000000000 = 0.01 TBA ✅
```

---

## Step 2 Complete

Oracle layer is fully set up:
- `ChainlinkOracle adapter` reads NAV from NAVFeedForwarder
- `EulerRouter` dispatches vault price queries to the adapter
- Both are immutable

**Step 3 — Deploy KinkIRM**
The interest rate model that determines the borrow rate based on utilisation.
