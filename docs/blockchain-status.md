# Blockchain Component Status

Current state of the EVM blockchain plane: contracts, adapters, tests, and wiring.

---

## Quick reference — run blockchain tests

```bash
# 1. Compile Solidity contracts
forge build

# 2. All unit tests (no Anvil needed — uses FakeChain)
cargo test --workspace

# 3. Anvil integration test (exercises real OZ bytecode)
anvil &
cargo test -p kaleidoscope-adapter-chain-evm -- --ignored
pkill -f anvil

# 4. Wallet unit tests (no RPC needed)
cargo test -p kaleidoscope-adapter-wallet-privkey

# 5. Full pipeline validation
cargo xtask validate
```

## Developer setup (one-time)

OZ v4 upgradeable (`lib/openzeppelin-contracts-upgradeable/`) and OZ v4
non-upgradeable (`lib/openzeppelin-contracts/`) are Forge submodules tracked in
`foundry.lock`. Run `forge install` if missing.

Foundry tools (`forge`, `anvil`): https://getfoundry.sh

**Compiler version — why it is pinned to 0.8.28 (L-2, GYL-309):**

All six contracts use `pragma solidity =0.8.28` (exact, no caret). `foundry.toml`
also sets `solc = "0.8.28"`. Both pins are required and they must agree:

- `=0.8.28` in the source file means "compile this file with exactly 0.8.28 — reject
  any other version." Without this, any compiler `>=0.8.20 <0.9.0` is legal.
- `solc = "0.8.28"` in `foundry.toml` locks what Forge actually downloads and uses.
  Without it, Forge picks the highest compatible version in its local cache and may
  compile with a different version from what an auditor or CI pipeline used elsewhere.

**Why not `=0.8.20`:** OZ's `UUPSUpgradeable.sol` and `ERC1967Utils.sol` use
`pragma solidity ^0.8.22`, meaning they require `>=0.8.22`. Version 0.8.20 is
outside that range — the Forge compiler rejects the combination as incompatible.

**Why 0.8.28 specifically:** It is the lowest stable release that satisfies all
OZ library constraints (`>=0.8.22`) while being a widely deployed, well-audited
release. Using the exact same version across all environments means the bytecode
that is audited is byte-for-byte identical to what is deployed.

---

## Contracts

All compile with `forge build`. **261 Forge tests pass** — see `docs/contracts.md` for
the full breakdown.

| Contract | File | Origin | Upgrade | Purpose |
|----------|------|--------|---------|---------|
| `GyldBondToken` | `contracts/GyldBondToken.sol` | Platform (MIT) | UUPS | Standard ERC-20 per bond series; fixed balances; value reflected in NAV feed only; reads the configured platform sanctions oracle |
| `IssuanceManager` | `contracts/IssuanceManager.sol` | Platform (MIT) | UUPS | AP whitelist; mint (subscribe) and burn (redeem) gate |
| `TokenFactory` | `contracts/TokenFactory.sol` | Platform (MIT) | None (Ownable2Step) | Deploys GyldBondToken proxy + KaleidoscopeNAVFeed per bond series |
| `KaleidoscopeNAVFeed` | `contracts/KaleidoscopeNAVFeed.sol` | Platform (MIT) | None | Push oracle — publishes bond NAV in AggregatorV3Interface format |
| `NAVFeedForwarder` | `contracts/NAVFeedForwarder.sol` | Platform (MIT) | None | Permanent DeFi-facing oracle; delegates to swappable upstream |
| `MockSanctionsList` | `contracts/MockSanctionsList.sol` | Platform (MIT) | None | Dev/test stub for the on-chain sanctions oracle |
| `SanctionsOracleMirror` | `contracts/SanctionsOracleMirror.sol` | Platform (MIT) | None | Platform-operated Chainalysis-compatible sanctions oracle (local list + optional composite forwarding) |

**Compliance model:** `GyldBondToken` reads from the platform-operated
`SanctionsOracleMirror`, the production sanctions oracle on **every** EVM chain including
Ethereum mainnet (GYL-1051). There is no internal blocklist — sanctions decisions are made
by the oracle. Secondary transfers fail-closed: if the oracle call reverts, the transfer
reverts. The mirror may forward lookups to a vendor oracle (on mainnet, Chainalysis at
`0x40C57923924B5c5c5455c48D93317139ADDaC8fb`) via its optional gas-capped, fail-closed
`forwardingOracle`.

> **Note (GYL-250):** The Fireblocks ERC20F / DenyList contracts (`contracts/erc20f/`)
> remain in the repo for reference only. They are **not deployed** for any bond series.
> All tokens use the GyldBondToken + platform sanctions oracle path. The legacy Anvil integration
> test in `adapter-chain-evm` has been stubbed out pending a rewrite for the new stack.

Full architecture and role documentation: **`docs/contracts.md`**

**DEFAULT_ADMIN_ROLE is wired to `factory.owner()`** — the `TimelockController` in production.

`_wireRoles` self-revokes both `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` from the factory at the
end of `deployToken`. No manual cleanup needed; the factory holds no permissions after deploy.

---

## IChain implementation status (`adapter-chain-evm`)

Uses `GyldBondToken` (UUPS RBAC) + `IssuanceManager` (mint/burn gate). All compliance
for secondary transfers is enforced by the configured sanctions oracle inside `GyldBondToken`.

| Method | Status | Notes |
|--------|--------|-------|
| `chain_id()` | ✅ | Returns `ChainId::Ethereum` |
| `deploy_token()` | ✅ | Calls `TokenFactory.deployToken(...)` via alloy; requires `EVM_FACTORY_ADDRESS` |
| `mint_token()` | ✅ | Calls `IssuanceManager.subscribe(token, to, amount)` — enforces AP whitelist |
| `burn_token()` | ✅ | Calls `IssuanceManager.redeem(token, beneficiary, amount)` |
| `token_balance()` | ✅ | Calls `GyldBondToken.balanceOf()`, converts to Decimal |
| `is_paused()` | ✅ | Calls `GyldBondToken.paused()` |
| `pause_token()` | ✅ | Calls `GyldBondToken.pause()` |
| `unpause_token()` | ✅ | Calls `GyldBondToken.unpause()` |
| `freeze_token_holder()` | ✅ | Calls `MockSanctionsList.addToSanctionsList()` (dev only); prod writes go to the platform `SanctionsOracleMirror` via the keeper |
| `thaw_token_holder()` | ✅ | Calls `MockSanctionsList.removeFromSanctionsList()` (dev only) |
| `forced_transfer()` | ✅ removed | Removed — sanctioned addresses are frozen in place by the oracle; no on-chain recovery function exists |
| `send_tx()` | ✅ | Works with `PRIVKEY_SIGNING_KEY`; KMS path not yet implemented |
| `finality()` | ✅ | Maps confirmations: <6 Processed, 6–63 Confirmed, ≥64 Finalized |
| `call()` | ❌ | `NotImplemented` — generic on-chain reads not wired |
| `events_since()` | ⚠️ | Returns empty vec + latest cursor (no `eth_getLogs` filtering) |
| `supports_global_pause()` | ✅ | Hardcoded `true` |

**Signing modes:**

| Env var set | Signing | Suitable for |
|-------------|---------|--------------|
| `PRIVKEY_SIGNING_KEY` | In-process private key | Anvil, Hoodi testnet, local dev |
| `EVM_KMS_KEY_ID` (alone) | ❌ Not yet implemented | — |
| Neither | Read-only; write ops fail | — |

---

## IWallet implementation status

### PrivkeyWallet (`adapter-wallet-privkey`) — dev/test

| Method | Status |
|--------|--------|
| `create_wallet()` | ✅ Returns shared dev address (idempotent per user) |
| `balance()` | ✅ ETH (`eth_getBalance`) + USDC (ERC-20 `balanceOf`) |
| `transfer()` | ✅ ETH native + ERC-20 transfers via alloy |

Env vars: `PRIVKEY_SIGNING_KEY`, `PRIVKEY_RPC_URL`, `PRIVKEY_CHAIN_ID` (default 560048), `PRIVKEY_USDC_ADDRESS`

### EvmWallet (`adapter-wallet-evm`) — planned KMS-backed

All three methods (`create_wallet`, `balance`, `transfer`) return `NotImplemented`. Not wired in bootstrap.

### FordefiWallet, SolWallet

All methods return `NotImplemented`.

---

## IAddressScreener implementation status

| Adapter | `screen_address()` | `screen_tx()` | Wired in bootstrap |
|---------|--------------------|----------------|-------------------|
| `ChainalysisSanctionsList` | ✅ Queries on-chain contract `0x40C5...` | ❌ `NotImplemented` | ❌ **NO — hardcoded FakeScreener** |
| `FakeScreener` | ✅ Always returns `Allow` | ✅ Always returns `Allow` | ✅ Default |

**Gap:** Chainalysis adapter exists and implements `screen_address()` but is not wired in bootstrap.
Production runs with `FakeScreener`, meaning **no AML/sanctions screening occurs at the Rust service layer**.

> Note: `GyldBondToken` enforces sanctions on-chain via the configured platform oracle
> for all secondary transfers. The `FakeScreener` gap affects the pre-mint/pre-transfer
> Rust-layer screening step — not the on-chain transfer guard.

To wire it, bootstrap needs:
1. `kaleidoscope-adapter-sanctions-chainalysis` added to bootstrap `Cargo.toml`
2. Env-driven selection: if `CHAINALYSIS_RPC_URL` is set → use real adapter, else fall back to `FakeScreener`

---

## Bootstrap wiring summary

| Component | Env var(s) | Real adapter | Fallback |
|-----------|------------|--------------|----------|
| IChain (ETH) | `EVM_RPC_URL` | `EvmChain` | `FakeChain` |
| IWallet (ETH) | `PRIVKEY_SIGNING_KEY` + `PRIVKEY_RPC_URL` | `PrivkeyWallet` | `FakeWallet` |
| IAddressScreener | — (none) | — (not wired) | `FakeScreener` (hardcoded) |

---

## Test coverage

| Tier | What | Status |
|------|------|--------|
| Forge unit tests | 252 tests across 10 suites — see breakdown below | ✅ `forge test` |
| FakeChain contract compliance | All IChain assertions | ✅ Always runs (`cargo test`) |
| EvmChain + Anvil | Full contract suite against real OZ bytecode | ✅ Defined, `#[ignore]` gate — run manually |
| PrivkeyWallet unit | `create_wallet` + address derivation | ✅ Always runs |
| PrivkeyWallet + live node | Full contract against Hoodi | ⏸️ `#[ignore = "pending live Hoodi node"]` |
| E2E golden path | Full cross-plane | Uses FakeChain/FakeWallet only |

**Forge test breakdown:**

| Suite | Tests | Coverage area |
|-------|-------|---------------|
| `IssuanceManagerTest` | 44 | subscribe/redeem, whitelist, registry, role isolation (SUBSCRIBER/REDEEMER split), UUPS |
| `TokenFactoryTest` | 53 | deploy, roles, mint, burn, pause, sanctions compliance, CREATE2 predict, REGISTRAR_ROLE preflight |
| `GyldBondTokenTest` | 12 | core token functions |
| `GyldBondTokenUnitTest` | 15 | sanctions transfer paths, setSanctionsList, pause |
| `KaleidoscopeNAVFeedTest` | 44 | updateAnswer, deviation cap, staleness, round ID, Ownable2Step |
| `NAVFeedForwarderTest` | 29 | delegation, oracle swap scenario, access control |
| `SanctionsOracleMirrorTest` | 29 | L2 mirror updates, role gating, delta sync |
| `TimelockTest` | 15 | 48h delay enforcement, cancel, IssuanceManager admin wiring |
| `GyldBondTokenFuzzTest` | 11 | mint/burn round-trip, transfer conservation, sanctions, pause, NAV model |
| `GyldBondTokenInvariantsTest` | 3 | totalSupply == sum(balances), per-actor balance bounds |
| `MockSanctionsListTest` | 6 | dev stub behaviour |

---

## Oracle architecture

Two contracts form the on-chain price pipeline:

```
Backend (KMS signer)
    │ updateAnswer(navPerToken)
    ▼
KaleidoscopeNAVFeed          ← AggregatorV3Interface + latestAnswer()
    │                           36-hr staleness cap, ±10% deviation cap, 1-hr min interval
    │
    ▼
NAVFeedForwarder              ← permanent address given to DeFi protocols
    │  setUpstreamOracle()       (Morpho Blue, Aave, etc.)
    ▼
DeFi protocols read price
```

**Why two contracts:**
- Morpho Blue bakes oracle address into immutable market parameters at creation. If we pointed Morpho at `KaleidoscopeNAVFeed` directly, every oracle upgrade (self → RedStone → Chainlink NAVLink) would require full market redeployment and liquidity migration.
- `NAVFeedForwarder` is the permanent address. Owner calls `setUpstreamOracle()` once to flip the pointer. All integrations update instantly.

**Upgrade path:**

| Phase | Upstream | When |
|-------|----------|------|
| 1 | `KaleidoscopeNAVFeed` (platform-operated) | Launch |
| 2 | RedStone Classic feed | Weeks after launch |
| 3 | Chainlink NAVLink feed | Institutional grade |

**Deploy script:** `contracts/script/DeployNAVFeed.s.sol` — deploys both contracts; prints addresses and next-step Morpho instructions.

**Safety constraints on `KaleidoscopeNAVFeed`:**

| Constant | Value | Effect |
|----------|-------|--------|
| `MAX_STALENESS` | 36 hours | `latestRoundData()` / `latestAnswer()` revert if price is older |
| `MIN_UPDATE_INTERVAL` | 1 hour | `updateAnswer()` reverts if called too soon after last update |
| `MAX_PRICE_DEVIATION_BPS` | 1000 (10%) | `updateAnswer()` reverts if new price deviates >10% from last |

**Important: `MAX_PRICE_DEVIATION_BPS` has no emergency override — this is intentional.**

`KaleidoscopeNAVFeed` is not upgradeable (no proxy). The deviation cap applies to
the owner too: even a compromised KMS signer can move the price at most 10% per
hour. This is the contract's primary defence against key compromise — it limits the
blast radius and gives the ops team time to detect and respond.

An emergency bypass was evaluated during the pre-mainnet security audit (GYL-309 M-3)
and explicitly rejected for three reasons:
1. T-bills and IG bonds do not move 10%+ in a single hour in practice.
2. Large legitimate moves can be published via chained `updateAnswer()` calls spaced
   1 hour apart — a 25% total move takes 3 hours, which is acceptable for this asset class.
3. Any bypass callable by the owner would eliminate the rate-limit protection entirely;
   a compromised key could push NAV to near-zero in one transaction and trigger mass
   Morpho Blue liquidations.

Full analysis: [`docs/decisions/gyld-bond-token-design.md`](decisions/gyld-bond-token-design.md) — Section 4.

---

### Why `MAX_STALENESS` exists — the weekend gap problem

**The root cause:** Bond markets close on weekends and US public holidays. Alpaca (our broker data source) publishes no NAV on those days because there is no market activity to price. Our backend cannot push a price it does not have. The oracle feed goes silent from Friday market close (~4pm ET) to Monday market open (~9:30am ET) — a gap of roughly 65 hours.

**What Morpho does during that gap:**

Morpho Blue calls `KaleidoscopeNAVFeed.latestRoundData()` on every borrow, repay, and liquidation check against bIB01 collateral. Without `MAX_STALENESS`, this call would succeed and return Friday's last pushed price, no matter how much time has passed.

```
Friday  4:00pm  → we push NAV = $95.42
Saturday        → markets closed, nothing pushed
Sunday  11:00pm → Morpho uses $95.42 for a liquidation check  ← stale, but no revert
```

**Why that is dangerous:**

Bond prices do not move on weekends because markets are closed — but that does not mean the *true* value is unchanged. If a significant event occurs over the weekend (central bank emergency meeting, sovereign credit event, geopolitical shock), the bond price will gap sharply when markets reopen Monday. Using Friday's price on Sunday to assess whether a borrower is adequately collateralised means:

- A borrower who is actually undercollateralised at the true Monday price looks healthy on Sunday
- Morpho does not liquidate them
- When the Monday NAV price is pushed ($88.00 in the example below), the position is suddenly deep underwater with no gradual liquidation — a bad debt spike

```
Friday  4pm   NAV pushed = $95.42
[weekend]     Fed announces emergency rate hike
Monday  9am   true NAV  = $88.00  (7.8% drop)
Sunday night  Morpho used $95.42 — borrower looked safe — was not
```

**What `MAX_STALENESS = 36 hours` does instead:**

After 36 hours without a price update, every call to `latestRoundData()` and `latestAnswer()` **reverts**. Morpho cannot read the price. All borrowing and liquidation activity against bIB01 collateral halts.

```
Friday  4pm   NAV pushed = $95.42
Saturday 4am  MAX_STALENESS exceeded → feed reverts
Saturday+     Morpho cannot borrow against bIB01, cannot liquidate
Monday  9am   we push new NAV = $88.00 → feed live again
Monday  9am+  Morpho runs correct liquidations at $88.00
```

**The tradeoff:**

| | No staleness check | `MAX_STALENESS = 36hr` (our model) |
|---|---|---|
| Weekend behaviour | Market runs on stale Friday price | Market freezes at Saturday 4am |
| Risk during freeze | Bad debt if price gaps at Monday open | None — no new positions, no liquidations |
| Who bears risk | Morpho lenders (bad debt) | Nobody — positions frozen but intact |
| Resumes | Automatically on next price push | Automatically on next price push |

For a regulated fixed-income platform, **freezing is correct**. Lenders deposit capital expecting it is protected by accurate real-time collateral pricing. Allowing Sunday liquidation decisions based on Friday prices violates that expectation. A temporary freeze is operationally inconvenient but financially safe.

**Why 36 hours specifically:**

- Friday market close (4pm ET) + 36 hours = Saturday 4am ET
- This leaves the weekend freeze window clearly visible before Monday open
- It covers US market holidays (typically 1–3 day gaps) with headroom
- It does not expire so early that a delayed Monday push (e.g. 10am) risks a brief stale window

**Why we added a staleness check:**

The deviation cap, update interval, and forwarder pattern follow established oracle design conventions. The key divergence is `MAX_STALENESS`: ETF iNAV feeds update continuously throughout trading hours (every few seconds), so a missing staleness check is tolerable there. Bond NAV is pushed once per market day — silently returning a 65-hour-old price over a weekend is not. We added the staleness check to match our update cadence and own a fresh audit requirement as a result.

---

## Design decisions — what was removed and why

### `deployToken` rejects duplicate ISINs with a human-readable error (GYL-300)

`deployToken` uses CREATE2 with the ISIN as the salt — the salt is ISIN-only. However, the full CREATE2 address also depends on the initcode, which includes `name`, `symbol`, and `maturityTimestamp`. This means the same ISIN deployed with a different name/symbol/maturity would deploy to a **different address** — creating two on-chain tokens for the same real-world bond with no collision.

Previously the guard checked `navFeedOf[predictedAddress] == address(0)`, which only caught exact-duplicate calls (same name, symbol, maturity, isin). A call with the same ISIN but a different name bypassed the check.

Now `deployToken` maintains a `mapping(bytes32 => bool) private _deployedIsins` keyed by `_bondSalt(isin)` (ISIN + chainId). Any deployment of the same ISIN — regardless of name, symbol, or maturity — reverts immediately with `"TokenFactory: ISIN already deployed"` before any CREATE2 is attempted. This eliminates the opaque EVM revert that would otherwise surface after the 48h TimelockController delay.

### `registerToken` validates the address is a real `GyldBondToken` (GYL-298)

`registerToken` now validates the address via a raw `staticcall` to `MINTER_ROLE()`. If the address is an EOA or a contract that doesn't implement `GyldBondToken`, it reverts with `"IssuanceManager: not a valid token contract"` at registration time rather than silently failing downstream in `subscribe` or `redeem`. Raw `staticcall` (not `try/catch`) is used because Solidity's `try/catch` does not catch ABI decode failures that occur when an EOA returns empty data for an interface call.

### `setUpstreamOracle` validates the address implements `AggregatorV3Interface` (GYL-299)

`setUpstreamOracle` now calls `IUpstreamOracle(newUpstream).decimals()` inside a `try/catch` before storing the address. A wrong address (EOA, random contract) is rejected immediately with `"NAVFeedForwarder: invalid oracle"` rather than bricking DeFi integrations after the fact. Uses `decimals()` rather than `latestRoundData()` because `decimals()` is always available on a valid oracle regardless of whether a price has been pushed yet.

### `ReentrancyGuardUpgradeable` removed from `GyldBondToken`

`ReentrancyGuardUpgradeable` was inherited but never used — a leftover from the `recoverTokens` removal. No function in `GyldBondToken` needs it:

- **`transfer` / `transferFrom`**: The only external call is the read-only sanctions oracle in `_requireAccess()`. This is a CHECK (Checks-Effects-Interactions) that happens before `_update()` writes any state. The oracle cannot call back into the token mid-transfer because state has not changed yet when the oracle is called. CEI is correct.
- **`mint` / `burn`**: Role-gated (`MINTER_ROLE` / `BURNER_ROLE`), no external calls at all. OZ v5 also removed all `_afterTokenTransfer` hooks, so there are no post-state callbacks anywhere in the lifecycle.
- **`approve` / `permit` / `setSanctionsList` / `pause` / `unpause`**: No balance changes, no external calls.

Adding `nonReentrant` to transfers is non-standard, breaks composability with DeFi protocols that call `transfer` inside their own `nonReentrant` flows, and adds unnecessary gas overhead. Adding it to `mint`/`burn` provides zero protection since those functions have no external calls.

Resolved audit pre-finding: *"ReentrancyGuardUpgradeable inherited but never used."*

---

## Known gaps (by priority)

1. **Chainalysis screener not wired** — production Rust service layer has no AML/sanctions pre-screening (HIGH). Note: on-chain transfer guard via `GyldBondToken` + the platform sanctions oracle IS active for secondary transfers.
2. **`freeze_token_holder` / `thaw_token_holder` / `is_holder_frozen` / `forced_transfer` broken** — `adapter-chain-evm` still calls `factory.denyListOf(token)` and `DenyList.accessListAdd/Remove` which do not exist for tokens deployed after GYL-250. `GyldBondToken` has no internal freeze mechanism — sanctions writes go to the platform `SanctionsOracleMirror` via the keeper, not through the token. Sanctioned addresses are frozen in place by the oracle; there is no on-chain recovery function. The Rust adapter needs a rewrite for these four methods. (HIGH)
3. **`call()` not implemented** — generic on-chain reads fail (MEDIUM)
4. **`events_since()` returns empty** — no event indexing, no audit trail from chain (MEDIUM)
5. **EvmWallet all stubs** — production user wallets need KMS implementation (HIGH)
6. **KMS signer not implemented** — production deployment blocked (HIGH)
7. ~~**DEFAULT_ADMIN_ROLE cleanup**~~ — resolved in GYL-262: factory self-revokes `DEFAULT_ADMIN_ROLE` in `_wireRoles`; no manual step needed.
8. **Delegated transfer (gasless / EIP-2612 permit)** — permit() is implemented in `GyldBondToken` (ERC20Permit); whether to expose a relayer path is pending decision by Chuan/Bhom (LOW)
