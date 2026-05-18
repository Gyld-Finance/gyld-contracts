# Morpho Blue — Base Mainnet Listing

How to get a GyldBondToken/USDC market onto the Morpho UI on Base.
Two paths: **with warning** (instant, share today) and **without warning** (clean listing, ~1 week).

---

## TL;DR

| | With Warning | Without Warning |
|---|---|---|
| Market usable? | Yes | Yes |
| UI link shareable? | Yes | Yes |
| Shows on app.morpho.org market list? | No (direct URL only) | Yes |
| Time to ready | Minutes | ~1 week |
| Cost on Base | ~$0.50 | ~$2 total |
| What's needed | `createMarket()` + seed | Above + Vault V2 + GitHub PR |

**Answer: yes, with-warning is real and usable right now.**
Teammates get a working `app.morpho.org` link, see a yellow banner, dismiss it, and trade.
The banner says "not allocated by any listed vault" — it is not a block, just an info notice.

---

## Base Contract Addresses

| Contract | Address |
|---|---|
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` |
| AdaptiveCurveIRM | `0x46415998764C29aB2a25CbeA6254146D50D22687` |
| MorphoChainlinkOracleV2Factory | `0x2DC205F24BCb6B311E5cdf0745B0741648Aebd3d` |
| VaultV2Factory | `0x4501125508079A99ebBebCE205DeC9593C2b5857` |
| MorphoMarketV1AdapterV2Factory | `0x9a1B378C43BA535cDB89934230F0D3890c51C0EB` |
| AdapterRegistry | `0x5C2531Cbd2cf112Cf687da3Cd536708aDd7DB10a` |
| USDC (Base) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

---

## Path A — With Warning (instant, share today)

Three on-chain steps. No GitHub PR. No approval.

### A1 — Deploy the oracle

Same pattern as Sepolia (see `docs/morpho-compatibility-test.md` Step 4).
Wrap the Base NAVFeedForwarder in a `MorphoChainlinkOracleV2`.

```bash
cast send $ORACLE_FACTORY \
  "createMorphoChainlinkOracleV2(address,uint256,address,address,uint256,address,uint256,address,address,uint256,bytes32)" \
  "0x0000000000000000000000000000000000000000" \
  1 \
  $FORWARDER_BASE \
  "0x0000000000000000000000000000000000000000" \
  18 \
  "0x0000000000000000000000000000000000000000" \
  1 \
  $CHAINLINK_USDC_USD_BASE \
  "0x0000000000000000000000000000000000000000" \
  6 \
  "0x0000000000000000000000000000000000000000000000000000000000000000" \
  --rpc-url $BASE_RPC --private-key $PRIVKEY
```

Verify before proceeding:
```bash
cast call $MORPHO_ORACLE_BASE "price()(uint256)" --rpc-url $BASE_RPC
# Must return a sane number (~100 × 10^24 if NAV ≈ $100)
```

### A2 — Create the market

```bash
cast send 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
  "createMarket((address,address,address,address,uint256))" \
  "($USDC_BASE,$GYLD_BOND_BASE,$MORPHO_ORACLE_BASE,0x46415998764C29aB2a25CbeA6254146D50D22687,860000000000000000)" \
  --rpc-url $BASE_RPC --private-key $PRIVKEY
```

Parameters:
- `loanToken` — USDC on Base
- `collateralToken` — GyldBondToken proxy on Base
- `oracle` — oracle deployed in A1
- `irm` — AdaptiveCurveIRM (governance-approved)
- `lltv` — `860000000000000000` = 86% (same as Sepolia test)

The `MarketCreated` event contains the **market ID** — save it.

### A3 — Seed the market

Prevents interest rate from decaying to zero before real users arrive.
Supply $1 USDC, borrow $0.90.

```bash
# Approve USDC
cast send $USDC_BASE \
  "approve(address,uint256)" 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb 1000000 \
  --rpc-url $BASE_RPC --private-key $PRIVKEY

# Supply $1
cast send 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb \
  "supply((address,address,address,address,uint256),uint256,uint256,address,bytes)" \
  "($USDC_BASE,$GYLD_BOND_BASE,$MORPHO_ORACLE_BASE,0x46415998764C29aB2a25CbeA6254146D50D22687,860000000000000000)" \
  1000000 0 $WALLET "0x" \
  --rpc-url $BASE_RPC --private-key $PRIVKEY

# Supply a little GYLD as collateral, then borrow $0.90
# (adjust amounts to your NAV price)
```

### A4 — Share the link

```
https://app.morpho.org/base/market/0x{MARKET_ID}
```

Replace `{MARKET_ID}` with the ID from the `MarketCreated` event.
This link works immediately. Teammates see a yellow warning banner — they click "I understand" and can supply, borrow, repay, withdraw normally.

---

## Path B — Without Warning (clean listing, ~1 week)

Do this after Path A is running. The market stays the same — you just add a Vault V2 layer and open one GitHub PR.

### B1 — Deploy Vault V2

Easiest via the Morpho Curator App: `https://curator.morpho.org/vaults`
Connect wallet on Base, fill in parameters, deploy.

**Or via cast:**
```bash
cast send 0x4501125508079A99ebBebCE205DeC9593C2b5857 \
  "createVaultV2(address,address,bytes32)" \
  $OWNER_MULTISIG \
  $USDC_BASE \
  $(cast keccak "gyld-vault-v1") \
  --rpc-url $BASE_RPC --private-key $PRIVKEY
```

Security requirements the Morpho bot checks on every PR (non-negotiable):

| Check | Required value |
|---|---|
| Timelock — critical ops (`increaseTimelock`, `abdicate`, `removeAdapter`) | ≥ 7 days |
| Timelock — standard ops | ≥ 3 days |
| Dead deposit | Burn 1e18 shares to `0x000...dead` |
| Permission gates | All abdicated |
| Vault name/symbol | Must NOT contain "morpho" |

### B2 — Deploy market adapter and configure caps

```bash
# Deploy adapter for your Morpho Blue market
cast send 0x9a1B378C43BA535cDB89934230F0D3890c51C0EB \
  "createMorphoMarketV1AdapterV2(address)" \
  $VAULT_V2_ADDRESS \
  --rpc-url $BASE_RPC --private-key $PRIVKEY
```

Then submit timelocked actions (Curator role):
1. `addAdapter(adapterAddress)`
2. `increaseAbsoluteCap(collateralRiskId, amount)`
3. `increaseAbsoluteCap(marketRiskId, amount)`

After the timelock elapses (3+ days), execute them and call:
```bash
# Set this market as the liquidity target
vault.setLiquidityAdapterAndData(adapterAddress, abi.encode(marketParams))

# Allocate (can be $0 initially — vault can be empty for listing purposes)
vault.allocate(adapterAddress, abi.encode(marketParams), 0)
```

The market must appear in the vault's **withdrawal queue** — that is the exact trigger that sets `listed: true` on the Morpho API.

### B3 — Open a PR to morpho-org/morpho-blue-api-metadata

Fork `https://github.com/morpho-org/morpho-blue-api-metadata` and edit three files.

**`data/vaults-v2-listing.json`** — add one entry:
```json
{
  "address": "0xYourVaultV2Address",
  "chainId": 8453,
  "image": "https://cdn.morpho.org/v2/assets/images/gyld.svg",
  "description": "Gyld bond token lending vault. Accepts USDC deposits and allocates to the GyldBondToken/USDC market on Morpho Blue.",
  "history": [{ "action": "added", "timestamp": 1234567890 }]
}
```
Address must be EIP-55 checksummed. Timestamp is Unix seconds.

**`data/tokens.json`** — add GyldBondToken (not in the registry yet):
```json
{
  "chainId": 8453,
  "address": "0xYourGyldBondTokenBase",
  "name": "Gyld Bond Token",
  "symbol": "GBT",
  "decimals": 18,
  "isListed": true,
  "isWhitelisted": true,
  "metadata": {
    "logoURI": "https://cdn.morpho.org/assets/logos/gbt.svg",
    "tags": ["rwa"]
  }
}
```

**`data/curators-listing.json`** — add Gyld as a curator:
```json
{
  "name": "Gyld",
  "image": "https://cdn.morpho.org/v2/assets/images/gyld.svg",
  "verified": true,
  "id": "gyld",
  "addresses": {
    "8453": ["0xYourOwnerOrCuratorAddress"]
  },
  "socials": {
    "url": "https://gyld.fi"
  },
  "ownerOnly": false
}
```

PR title convention (follow Morpho's bot pattern):
```
Vault V2 Listing: 0x{vaultAddress} - Gyld - {YYYY-MM-DD}
```

### B4 — Await 2 approvals

Reviewers from `@morpho-org/integration`: `albist`, `tomrpl`, `achillesbro`, `lucianken`.
Typical turnaround: same day to 4 days. No governance vote.

CI runs automatically and checks:
- EIP-55 checksum on every address
- Required fields present and correctly typed
- chainId is in the supported list (8453 ✓)
- Addresses unique per chain

Once merged: the market appears cleanly on `https://app.morpho.org/base` with no warnings.

---

## Warning Taxonomy

| Warning | Colour | Cause | User experience |
|---|---|---|---|
| `not_whitelisted` | Yellow | No listed Vault V2 has market in its withdraw queue | Banner shown, user clicks "I understand", can trade |
| `unrecognized_collateral_asset` | Red | GyldBondToken not in `tokens.json` | User must opt in explicitly, can still trade |
| `unrecognized_loan_asset` | Red | Loan token not in `tokens.json` | Same as above |
| `incorrect_oracle_configuration` | Red | Oracle scale factor wrong | Same as above |
| No warning | — | Vault V2 listed + tokens registered + oracle valid | Clean UI, no banner |

Path A gives a yellow warning (`not_whitelisted`) plus potentially red warnings for the token.
Path B eliminates all warnings.

In both cases the market is **fully functional** — warnings are informational, not access controls.

---

## Cost Summary (Base mainnet)

| Step | Est. gas | Est. USD |
|---|---|---|
| Deploy oracle | ~200k gas | ~$0.10 |
| `createMarket()` | ~100k gas | ~$0.05 |
| Seed supply + borrow | ~200k gas | ~$0.10 |
| Deploy Vault V2 (Path B only) | ~500k gas | ~$0.25 |
| Adapter deploy + configure (Path B only) | ~400k gas | ~$0.20 |
| **Total Path A** | | **~$0.25–0.50** |
| **Total Path B** | | **~$1–2** |

Estimates at 0.005 Gwei and ETH ≈ $2,100. $20 covers either path with 10× headroom.

---

## Relationship to Sepolia Test

The Sepolia test (`docs/morpho-compatibility-test.md`) proved the full pipeline:
oracle → createMarket → supply → collateral → borrow → repay → withdraw.

Base mainnet replicates the same steps with:
- Different RPC (`$BASE_RPC`)
- Base contract addresses (listed above)
- Real USDC, real GyldBondToken proxy deployed on Base
- Real ETH for gas (tiny amount needed)

Market ID format is identical: `keccak256(abi.encode(loanToken, collateralToken, oracle, irm, lltv))`.
