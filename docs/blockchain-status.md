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
| `MockSanctionsList` | `contracts/test/MockSanctionsList.sol` | Platform (MIT) | None | Dev/test stub for the on-chain sanctions oracle. Writes are gated on an `owner` set at construction (the deploying key), and its deploy script refuses every non-dev chain (GYL-1135) |
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
| `freeze_token_holder()` | ✅ | Calls `MockSanctionsList.addToSanctionsList()` (dev only; the signing key must be the mock's `owner`, i.e. the key that deployed it); prod writes go to the platform `SanctionsOracleMirror` via the keeper |
| `thaw_token_holder()` | ✅ | Calls `MockSanctionsList.removeFromSanctionsList()` (dev only; owner-gated as above) |
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
| `MockSanctionsListTest` | 14 | dev stub behaviour + owner-only write access |

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
| `MAX_STALENESS` | 96 hours | Threshold for the `isFresh()` monitoring view **only**. Reads do **not** revert when it is exceeded. |
| `MIN_UPDATE_INTERVAL` | 1 hour | `updateAnswer()` reverts if called sooner than 1 h after the last update |
| `MAX_PRICE_DEVIATION_BPS` | 1000 (10%) | `updateAnswer()` reverts if the new price deviates >10% from the last |

Monitoring views (neither is enforced anywhere on-chain):

| View | Returns |
|------|---------|
| `isFresh()` | `true` if the last push is within `MAX_STALENESS`; `false` if stale **or never set** |
| `stalenessSeconds()` | Seconds since the last push; `type(uint256).max` if never set |

> **Corrected 2026-07-30 (GYL-1134).** This table previously read
> "`MAX_STALENESS` | 36 hours | `latestRoundData()` / `latestAnswer()` revert if price is
> older". **Both halves were wrong** and had been since the contract was first written:
> the constant is 96 hours, and no read function has ever reverted on staleness. The
> only revert on a read is `NoPriceSet`, before the first push
> (`KaleidoscopeNAVFeed.sol`, `latestRoundData`). A `PriceStale` error was declared but
> never thrown; it has been deleted (GYL-1135) so the source no longer implies a revert
> path that does not exist. `docs/contracts.md` has described this correctly throughout.
>
> `stalenessSeconds()` was added in GYL-1135 and is **not retrofittable** — this contract
> is not upgradeable (no proxy, `Ownable2Step` only), so feeds already deployed,
> including the Base mainnet feed, do not have it. Alerting on existing feeds must derive
> age off-chain from `latestRoundData().updatedAt` or from `AnswerUpdated` /
> `EmergencyAnswerUpdated` events, both of which work on every version.

**`MAX_PRICE_DEVIATION_BPS` and `MIN_UPDATE_INTERVAL` have a separate-key emergency override.**

`KaleidoscopeNAVFeed` is not upgradeable (no proxy). Both caps apply to the owner: even a
compromised KMS signer can move the price at most 10% per hour via `updateAnswer`. That is
the contract's primary defence against key compromise — it limits blast radius and gives
the ops team time to detect and respond.

`emergencyUpdateAnswer(int256)` bypasses **both** guards. It is callable only by the
`emergencyUpdater` address, which `setEmergencyUpdater` forbids from equalling `owner()`
(enforced in both directions — `transferOwnership` and `_transferOwnership` reject
collapsing the two roles). The rate limit therefore still holds against a single
compromised key; it does not hold against a compromise of both. Emergency use emits
`EmergencyAnswerUpdated`, deliberately a different event from `AnswerUpdated`, so
monitoring can page on any use. See `docs/contracts.md` → KaleidoscopeNAVFeed for the
full mechanism.

> **Corrected 2026-07-30 (GYL-1134).** This section previously asserted
> "`MAX_PRICE_DEVIATION_BPS` has no emergency override — this is intentional", and cited
> the GYL-309 M-3 audit rejection of a bypass. That decision was later **reversed**:
> `emergencyUpdateAnswer` ships and bypasses both the deviation cap and the update
> interval. The original reasoning (T-bills do not move 10%+ in an hour; large moves can
> be chained hourly; an owner-callable bypass would erase the rate limit) is retained
> below as history, because the *third* point is why the shipped override is gated on a
> **separate key** rather than on the owner:
>
> 1. T-bills and IG bonds do not move 10%+ in a single hour in practice.
> 2. Large legitimate moves can be published via chained `updateAnswer()` calls spaced
>    1 hour apart — a 25% total move takes 3 hours, acceptable for this asset class.
> 3. Any bypass callable by *the owner* would eliminate the rate-limit protection
>    entirely; a compromised key could push NAV to near-zero in one transaction and
>    trigger mass Morpho Blue liquidations.
>
> What changed the decision: a fat-finger *within* the 10% band can strand the correct
> price out of reach (correcting a 9.9% error requires a >10% move back), leaving a wrong
> NAV live with no on-chain remedy. Key separation answers point 3 without reintroducing
> the single-key risk.

Full history: [`docs/decisions/gyld-bond-token-design.md`](decisions/gyld-bond-token-design.md) — Section 4.

---

### Staleness: what the feed actually does, and who is responsible for it

**The gap is real.** Bond markets close on weekends and US public holidays. Alpaca (our
broker data source) publishes no NAV on those days, so the backend has nothing to push.
The feed goes silent from Friday close (~4pm ET) to Monday open (~9:30am ET) — roughly
65 hours, and longer across a 3-day holiday weekend.

**What the feed does about it: reports, does not enforce.**

```
Friday  4:00pm  → push NAV = $95.42
Saturday        → markets closed, nothing pushed
Sunday  11:00pm → latestRoundData() returns ($95.42, updatedAt = Friday 4pm)
                  isFresh() == true   (55 h < 96 h)
                  stalenessSeconds() == 198_000
Wednesday       → latestRoundData() returns ($95.42, updatedAt = Friday 4pm)
                  isFresh() == false  (>96 h)
                  stalenessSeconds() == 450_000
                  ← still no revert. Ever.
```

Reads always succeed and always carry the true `updatedAt`. **Every consumer is
responsible for its own age check.** This is the Chainlink aggregator contract, and it is
a deliberate choice, not an oversight — see below.

**This is not theoretical — it happened.** The Base mainnet feed has been stale since
2026-05-19. The two live integrations diverged exactly along the "does the consumer
age-check?" line:

| Consumer | Own staleness check | Behaviour during the outage |
|---|---|---|
| Euler | Yes — `PriceOracle_TooStale` | Froze the market. Correct. |
| Morpho Blue | None | Kept quoting the pinned $100.00 indefinitely. |
| `GyldAtomicSwap` | Yes — `StaleNav`, bound `maxNavAgeSecs` | Fails closed on `executeSwap` |

Morpho's behaviour is the risk this section used to claim was impossible. It is a real,
open exposure, and **no change to the feed fixes it** — see "Why not just make reads
revert" below.

**The tradeoff, stated honestly:**

| | Feed does not revert (**what we ship**) | Feed reverts when stale |
|---|---|---|
| Weekend / holiday behaviour | Consumers that age-check freeze; consumers that do not run on the last price | Everything freezes uniformly |
| Risk during a freeze | **Bad debt on non-checking consumers (Morpho) if price gaps at reopen** | Position drift; no liquidations possible |
| Who bears the risk | **Morpho lenders**, and any integrator that skips the age check | Borrowers who cannot be liquidated → lenders again, via unrecoverable bad debt |
| Liquidations during the gap | Still possible (correctly, on Euler; on a stale price on Morpho) | **Impossible — including for positions that were already unhealthy before the gap** |
| Recovery | Automatic on next push | Automatic on next push |

> **Corrected 2026-07-30 (GYL-1134).** The previous version of this table described the
> *right-hand* column as our model and recorded "Risk during freeze: **None**" and "Who
> bears risk: **Nobody** — positions frozen but intact". The bytecode implements the
> left-hand column, and the risk is neither none nor nobody's. The "Nobody" claim was
> also wrong on its own terms even for a reverting feed: a market that cannot liquidate
> is not a market with no risk, it is a market that has deferred and concentrated it.

**Why not just make reads revert:**

1. **It breaks the consumers that behave correctly.** Euler age-checks and froze exactly
   as designed. A reverting feed would give it a raw revert instead of a price plus a
   timestamp — same freeze, less information, and a failure mode its error handling does
   not model.
2. **It destroys diagnosability.** `updatedAt` is what told us the feed died on
   2026-05-19 and for how long. A revert carries no timestamp.
3. **It freezes liquidations, unfixably.** This is the decisive one. On Morpho, a
   reverting oracle blocks *liquidations* as well as borrows. Positions that were already
   underwater before the outage cannot be closed, and the bad debt grows for the entire
   duration of the outage with no operator action available. Failing closed is right for
   opening new risk; it is wrong for unwinding existing risk.
4. **It is not the Chainlink contract.** Chainlink's own aggregators do not revert on
   stale answers. Integrators — and their audit checklists — are built around
   "check `updatedAt` yourself". Diverging surprises the careful ones and does not help
   the careless ones.

This decision is pinned by
`contracts/test/KaleidoscopeNAVFeed.t.sol::test_noStalenessRevertPathExists`, which warps
1000 days and asserts `latestRoundData()`, `latestAnswer()` and `getRoundData()` all still
succeed. If a future requirement genuinely needs reverting reads, deploy a separate
wrapper — do not change these semantics under live integrators.

**Where the defence actually lives:**

1. **Consumer-side age checks.** `GyldAtomicSwap._checkQuoteBand` reverts `StaleNav` when
   `block.timestamp > updatedAt + maxNavAgeSecs` (default 24 h), and also when `updatedAt`
   is in the future. As of GYL-1135 `maxNavAgeSecs` is bounded above by
   `MAX_NAV_AGE_CEILING = 72 hours` in both `initialize` and `setMaxNavAgeSecs` — before
   that, a single `DEFAULT_ADMIN_ROLE` call could raise it toward the `uint32` ceiling
   (~136 years) and silently turn the guard into a no-op while every getter still reported
   it as configured. 72 h matches Euler's structural `MAX_STALENESS_UPPER_BOUND` and keeps
   3-day-holiday tolerance reachable.
2. **`NAVFeedForwarder` upstream probe.** `setUpstreamOracle` (and the constructor) reject
   an upstream whose `latestRoundData()` reports a **future-dated** `updatedAt` (GYL-1135).
   A future timestamp satisfies every consumer's `now - updatedAt <= maxAge` check
   unconditionally, so one pointer swap could disarm every integrator's staleness defence
   at once — a silent fail-open, strictly worse than the loud fail-closed of a stale feed.
   An upstream that merely has *no price yet* is still accepted; that is a legitimate
   deploy order.
3. **Ops — and this is the part no contract change substitutes for.** The NAV keeper must
   push after every market close, and alerting must page when it does not. The 2026-05-19
   outage was a keeper/alerting failure, not a contract failure: every contract behaved as
   written. `isFresh()` and `stalenessSeconds()` exist to be *polled*; they protect nobody
   if nothing polls them.

**Why `MAX_STALENESS` is 96 hours:** it is a monitoring threshold, so it is sized to
"something is genuinely wrong", not to "market is closed". A normal weekend is ~65 h and a
3-day holiday weekend ~87 h; 96 h clears both, so `isFresh() == false` means a missed push
rather than a calendar. Operational alerting should fire far earlier than 96 h — a missed
daily push is visible within ~26 h — which is why `stalenessSeconds()` returns a magnitude
rather than a bool pinned to this constant.

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
