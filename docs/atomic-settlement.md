# Atomic Settlement — `GyldAtomicSwap` + `GyldSettlementVault`

Instant USDC ⇄ bond-token settlement against platform-signed EIP-712 quotes,
served from an LP-funded liquidity vault. The buyer gets tokens in one
transaction; the seller gets USDC in one transaction; T+2 broker settlement
happens behind the vault's balance sheet, invisibly to the user.

> **Status (2026-06): prototype, uncommitted.** Both contracts and their test
> harness exist on disk in `contracts/` and `contracts/test/` but are **not yet
> committed** — they are pending review/landing on a `feat/GYL-xxx-atomic-settlement`
> branch (Phase 1 of the rollout plan, see [Roadmap](#roadmap-this-repos-slice)).
> `forge test` passes 407/407 across 13 suites (323 pre-existing, zero
> regressions; 25 new swap tests + 59 new vault tests). Adversarial review
> verdict: **SHIP**, zero edits, seven non-blocking observations (carried into
> the [audit-prep checklist](#audit-prep-checklist)).

## Contract inventory

| Contract | File | Origin | Upgrade | Purpose |
|----------|------|--------|---------|---------|
| `GyldAtomicSwap` | `contracts/GyldAtomicSwap.sol` | Platform (MIT) | UUPS | Singleton settlement executor: verifies EIP-712 `SwapMessage` quotes, applies optional EIP-2612 permit, moves both legs atomically. Never mints, never holds funds beyond one tx |
| `GyldSettlementVault` | `contracts/GyldSettlementVault.sol` | Platform (MIT) | UUPS | Singleton LP-funded pool: bond-token inventory (buy side) + USDC (redeem side), receivable accounting for in-flight broker settlement, ERC-20 LP shares ("gyldLP") |
| `MockUSDCPermit` | `contracts/test/MockUSDCPermit.sol` | Platform (test) | None | Permit-bearing USDC mock (MockUSDC has no `permit`) |
| `MockNavForwarder` | `contracts/test/MockNavForwarder.sol` | Platform (test) | None | Settable 8-dp NAV forwarder (real `KaleidoscopeNAVFeed` enforces 1-h interval + 10% band — too rigid for band/`InvalidNav` tests) |

**Existing contracts modified: none.** Integration is wiring-only:
`IssuanceManager.addToWhitelist(vaultProxy)` (the vault becomes an AP) and
`vault.registerSeries(token, forwarder)` per bond series. Full design rationale
and rejected alternatives: the atomic-settlement design doc (to land as
`docs/decisions/atomic-settlement.md` in Phase 1).

---

## Architecture

```
User (taker)
    │  approve / EIP-2612 permit (exact value, short deadline)
    │  executeSwap(SwapMessage, signature, PermitData)     ← only approval target
    ▼
GyldAtomicSwap (ERC1967Proxy ──▶ impl, UUPS, ERC-7201)
    │  1. taker == msg.sender, expiry, epoch, EIP-712 sig vs QUOTE_SIGNER_ROLE
    │  2. consume quoteId bit (1inch BitInvalidator — BEFORE any transfer)
    │  3. optional permit (try/catch — front-run-proof)
    │  4. leg 1: safeTransferFrom(taker → vault, tokenIn)
    │  5. leg 2: vault.onSwap(...)
    ▼
GyldSettlementVault (ERC1967Proxy ──▶ impl, UUPS, ERC-7201)
    │  exactly one bond leg · NAV band check · inventory/liquidity check
    │  PUSHes tokenOut to taker (no standing allowances out of the vault, ever)
    │
    ├─ LP side:        deposit/withdraw (LP_ROLE, gyldLP shares, virtual offset)
    ├─ Treasurer side: drawForReplenishment / settleReplenishment /
    │                  forwardForBurn / repayUsdc  (NET flow only, receivables)
    ├─ NAV source:     NAVFeedForwarder per series (probed: decimals() == 8)
    └─ Replenishment:  IssuanceManager.subscribe(token, vault, n)  — vault is a
                       whitelisted AP; the vault itself has NO mint authority
```

Buys and redemptions **net** on the vault's balance sheet: collateral tokens
taken in on a redeem re-enter inventory and serve the next buyer; only net flow
is bridged to the broker by the treasurer.

---

## `GyldAtomicSwap`

### `SwapMessage` (EIP-712)

Domain: `("GyldAtomicSwap", "1")` + chainId + proxy address.

```solidity
struct SwapMessage {
    uint256 quoteId;   // single-use; consumed via bitmap
    address taker;     // must equal msg.sender at execution
    address tokenIn;   // leg the user pays
    uint256 amountIn;
    address tokenOut;  // leg the user receives (vault inventory / USDC pot)
    uint256 amountOut;
    uint64  expiry;    // unix seconds
    uint64  epoch;     // quote-signer generation
}

struct PermitData { uint256 value; uint256 deadline; uint8 v; bytes32 r; bytes32 s; } // value == 0 skips
```

```
SWAP_MESSAGE_TYPEHASH = keccak256("SwapMessage(uint256 quoteId,address taker,
  address tokenIn,uint256 amountIn,address tokenOut,uint256 amountOut,
  uint64 expiry,uint64 epoch)")
= 0xb61ceb75c757acc060b9f02779e91190b775292df96a4784edff6d184e9b7aa7
```

The **price is the ratio `amountIn / amountOut` inside the signed message** —
the chain never computes an execution price. The NAV feed only *bounds* it
(see [NAV band](#nav-sanity-band) below). Direction is implicit: BUY when
`tokenIn` is USDC and `tokenOut` a registered series; REDEEM when reversed.
`executeSwap` is direction-agnostic.

### Roles

| Role | Holder | Gates |
|------|--------|-------|
| `DEFAULT_ADMIN_ROLE` | TimelockController | upgrades, `unpause`, `setVault`, `bumpQuoteEpoch`, role grants |
| `QUOTE_SIGNER_ROLE` | quote-service KMS key(s) | passive — checked via `hasRole(QUOTE_SIGNER_ROLE, recoveredSigner)`; the role registry *is* the signer set (rotation = grant + bump + revoke) |
| `PAUSER_ROLE` | ops multisig | `pause()` only (asymmetric — see [Security model](#security-model)) |

### Storage (ERC-7201, `erc7201:gyld.GyldAtomicSwap`)

Slot: `0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300`
(independently recomputed 3×: implementation, test pass, review).

```
address vault;                                 // GyldSettlementVault proxy (probe-before-store)
uint64  quoteEpoch;                            // bumped to mass-invalidate quotes
mapping(uint256 => uint256) usedQuoteWords;    // BitInvalidator: quoteId >> 8 → 256-bit word
```

`renounceRole` is overridden to block `DEFAULT_ADMIN_ROLE` renouncement
(house idiom shared with `GyldBondToken`/`IssuanceManager`).

---

## `GyldSettlementVault`

### Roles

| Role | Holder | Gates |
|------|--------|-------|
| `DEFAULT_ADMIN_ROLE` | TimelockController | upgrades, `registerSeries`/`deregisterSeries`, `setSwap`, `setMaxQuoteDeviationBps`, `unpause` |
| `SWAP_ROLE` | GyldAtomicSwap proxy | `onSwap` — the only fund-out path on the hot path. `setSwap` atomically revokes the old holder and grants the new: at most one swap can ever drive `onSwap` |
| `TREASURER_ROLE` | Kaleidoscope ops MPC wallet | `drawForReplenishment`, `settleReplenishment`, `forwardForBurn`, `repayUsdc`. Live while paused (wind-down lever) |
| `LP_ROLE` | bridging-finance LPs (KYC'd off-chain) | `deposit`, `withdraw` |
| `PAUSER_ROLE` | ops multisig | `pause()` only |

### Storage (ERC-7201, `erc7201:gyld.GyldSettlementVault`)

Slot: `0x151c9d64c83d3cd54bf270d13fe414c5f5d542f89250a5fe95ec1c71ad52fb00`
(independently recomputed 3×).

```
IERC20  usdc;
address issuanceManager;                       // burn-commitment destination (BurnWatcher watches it)
address swap;                                  // GyldAtomicSwap proxy
uint16  maxQuoteDeviationBps;                  // quote-vs-NAV band; init 200 (2%), 0 = soft-pause, max 10_000
address[] seriesList;                          // totalAssets iteration; membership ⇔ registered
mapping(address => bool)    registeredSeries;
mapping(address => address) navForwarderOf;    // bond token → NAVFeedForwarder (8-dp probed)
mapping(address => uint256) replenishmentOwed; // USDC 6dp — treasurer drew to fund a broker buy
mapping(address => uint256) buybackOwed;       // USDC 6dp — collateral forwarded for burn, repay pending
```

### The `totalAssets` identity

```
totalAssets = freeUSDC + Σᵢ inventoryᵢ·NAVᵢ + Σᵢ replenishmentOwedᵢ + Σᵢ buybackOwedᵢ      (USDC, 6 dp)
```

Obligations are Maple-LoanManager-style USDC-denominated receivables owed by
Kaleidoscope, booked the instant the treasurer bridges net flow — so the LP
share price never dips while money is in flight:

- `drawForReplenishment`: receivable in, USDC out → `totalAssets` unchanged.
  Extinguished by `settleReplenishment` once `IssuanceManager.subscribe(token,
  vault, n)` fill-mints land (inventory is then on the balance sheet at NAV).
- `forwardForBurn`: books `buybackOwed` at the instant's NAV, sends tokens to
  the IssuanceManager (the existing on-chain burn-commitment signal that the
  backend `BurnWatcher` already consumes — zero backend code change).
  Extinguished by `repayUsdc` after the T+2 broker sale.

There is a **documented transient double-count** between fill-mint landing and
`settleReplenishment` (inventory + receivable both counted); the lifecycle test
asserts `totalAssets` at every step and an at-par LP exit at the end.

LP shares use an OZ-style virtual offset (`_VIRTUAL_SHARES = 1e3`,
`_VIRTUAL_ASSETS = 1`); deposit floors shares, withdraw floors assets — the
review verified round-trip extraction is algebraically impossible and the
inflation-attack test confirms strict attacker loss. `withdraw` reverts
`InsufficientUsdcLiquidity` **only** when free USDC can't cover it — no
buffer-minimum revert (Ondo C4 H-01 lesson). LP exit when liquidity is
deployed = wait for settle/repay or treasurer top-up; an ERC-7540 request
queue is the flagged V2.

### NAV sanity band

```solidity
// _navValueUsdc: token 18dp × NAV 8dp / 1e20 → USDC 6dp; nav <= 0 reverts InvalidNav (fail-closed)
navValue = tokenAmount * uint256(nav) / 1e20;
band     = navValue * maxQuoteDeviationBps / 10_000;
// accepted iff  navValue - band ≤ usdcAmount ≤ navValue + band   (both bounds inclusive)
```

Worked example — 10 tokens at NAV $100, 2% band (`maxQuoteDeviationBps = 200`):

- `tokenAmount = 10e18`; feed answer `nav = 100 × 1e8 = 1e10`
- `navValue = 10e18 × 1e10 / 1e20 = 1_000_000_000` micro-USDC = **$1,000.00**
- `band = 1e9 × 200 / 10_000 = 20_000_000` micro-USDC = **$20.00**
- Passes iff `980_000_000 ≤ usdcAmount ≤ 1_020_000_000` — $98.00–$102.00 per
  token. `usdcAmount = 1_020_000_001` reverts
  `QuotePriceOutOfBand(1020000001, 1000000000)`.

The 8-dp assumption is enforced at registration: `registerSeries` staticcall-
probes `decimals() == 8` or reverts `NotValidForwarder`. Forwarder reads use
`latestRoundData()`, which never reverts on staleness (existing feed design;
staleness alerting is off-chain via `isFresh()`).

---

## Security model

| Mechanism | Where | What it defeats |
|---|---|---|
| **Taker binding** (`m.taker == msg.sender`) | swap | Quote theft / MEV-bot execution of someone else's quote. Quotes are not bearer paper (0x mandatory-taker pattern). Note: Backed's production swap does *not* enforce this — we deliberately do |
| **Single-use quoteId** (BitInvalidator bitmap, consumed *before* any transfer) | swap | Replay, including replay on a different leg within the expiry window. 256 quotes per storage slot (quote IDs allocated sequentially per epoch off-chain) |
| **Quote expiry** | swap | Sitting on a favourable price while NAV moves. TTL itself (~60 s class) is off-chain QuoteService policy; on-chain only checks the timestamp |
| **`quoteEpoch` mass-kill** (`bumpQuoteEpoch`, admin/timelock) | swap | Signer-key compromise: one tx invalidates every outstanding quote (1inch epoch pattern). Rotation = grant new `QUOTE_SIGNER_ROLE`, bump, revoke old |
| **Push, not allowance** | vault | The Hashflow June-2023 class of exploit: the vault grants **zero** ERC-20 allowances to anyone, ever (`approve` appears nowhere in the contract). Outbound funds move only by push inside `onSwap`/treasurer functions; the only inbound `transferFrom`s pull from `msg.sender`. Users approve **only** the swap contract, exact-value, short-deadline via permit |
| **NAV band vs compromised signer** | vault | Bounds the damage of a fully compromised quote signer: even a valid signature can move price at most ±`maxQuoteDeviationBps` (2%) off the on-chain NAV per trade. The feed itself is write-bounded ±10%/update, ≥1 h apart, by a *different* key (`KaleidoscopeNAVFeed.updateAnswer`) — a single stolen key cannot both move the reference and exploit the band. `setMaxQuoteDeviationBps(0)` = documented on-chain soft-pause |
| **Sanctions via `GyldBondToken._update`** | token (by design, not in swap/vault) | Every swap has exactly one bond-token leg, and the token's `_update` screens `from`, `to`, **and the swap contract as spender** against the Chainalysis oracle, fail-closed. On a BUY the screen fires on the vault→taker push; a sanctioned buyer reverts the whole atomic tx (leg 1 unwinds too). No oracle call in swap/vault — consistent with the platform-wide "no internal blacklist" decision. QuoteService pre-screens off-chain only to save gas |
| **Asymmetric pause** | both | `PAUSER_ROLE` (ops multisig) halts cheaply at either layer independently; only `DEFAULT_ADMIN_ROLE` (timelock) resumes. Deliberate deviation from `GyldBondToken`'s symmetric pause: this path runs off a hot signing key. The treasurer bridge stays live while the vault is paused (tested) — the wind-down lever |
| **CEI + shared reentrancy guard** | both | `_consumeQuote` is the only state write in `executeSwap` and precedes all three external calls. `deposit`/`withdraw`/`onSwap` share one `ReentrancyGuard`, so the transient mid-swap inflated `totalAssets` (USDC landed, tokens not yet pushed) is unreadable by a reentrant LP call. All four treasurer functions write obligations before transferring |
| **Probe-before-store** (house idiom) | both | Fat-finger config: `setVault` probes `totalAssets()`, `registerSeries` probes `decimals() == 8`, `setSwap` probes `SWAP_MESSAGE_TYPEHASH()` and atomically swaps `SWAP_ROLE` |
| **`InvalidNav` fail-closed** | vault | A ≤0 feed answer reverts valuation rather than silently wrapping (the bare `uint256` cast would value at ~2²⁵⁶) or marking down LP shares |
| **Permit griefing tolerance** | swap | `permit` applied with `try/catch`; a front-run `permit()` cannot brick the swap — `safeTransferFrom` enforces the allowance regardless (tested: attacker pre-consumes nonce, swap still settles) |

---

## Proposed amendment: capped-allowance `SwapMessage`

> **Status: proposed, 2026-07-06 — not implemented.** No contract or test
> changes exist yet; this is a scoping note for a specific gap in the current
> design, not a landed change.

### Motivation

Today `SwapMessage.amountIn`/`amountOut` are literal values the quote signer
commits to — `executeSwap` moves exactly those numbers or reverts. There is
no way to sign a quote "up to $1,000" and let the taker draw $100 of it in a
single call; the taker must know the exact size *before* requesting the
quote. For AP/LP-sized flows this forces round-tripping the RFQ desk for
every size change, and wastes quote-signer capacity on quotes that end up
only partially used.

### Proposed shape

```solidity
struct SwapMessage {
    uint256 quoteId;
    address taker;
    address tokenIn;
    uint256 maxAmountIn;   // was `amountIn` — now a ceiling, not an exact value
    address tokenOut;
    uint256 price;         // was `amountOut` — fixed-point amountOut per 1e18 tokenIn
    uint64  expiry;
    uint64  epoch;
}
```

```solidity
function executeSwap(
    SwapMessage calldata m,
    bytes calldata signature,
    PermitData calldata permitIn,
    uint256 requestedAmountIn        // NEW: taker-chosen, not part of the signed message
) external;
```

Execution:

1. Signature/taker/expiry/epoch checks unchanged.
2. **New:** `0 < requestedAmountIn <= m.maxAmountIn`, else `AmountOutOfRange`.
   A `minAmountIn` floor (message field or a protocol-wide constant) belongs
   alongside this — otherwise a taker can grief the quote-signer's
   attention/rate-limit budget with near-zero-value draws.
3. `_consumeQuote(m.quoteId)` — **unchanged**: still one bit, still burned in
   full regardless of how much of `maxAmountIn` was actually drawn. The quote
   remains single-use; it cannot be drawn against twice.
4. `amountOut = requestedAmountIn * m.price / 1e18` — rounded down (vault's
   favor; a taker-favorable rounding direction turns into per-call dust
   extraction across many quotes).
5. Legs 1–2 (`transferFrom` taker→vault, `vault.onSwap`) proceed exactly as
   today, using `requestedAmountIn`/`amountOut` in place of
   `m.amountIn`/`m.amountOut`.

### What this does and doesn't fix

- **Fixes:** "quote me up to $1,000 at this price, I'll decide the size when
  I call `executeSwap`" — one atomic call, taker-chosen size, still exactly
  one use per quote.
- **Does not fix:** drawing down the same quote across *multiple*
  transactions over time (e.g. $100 now, $200 later, $700 tomorrow). That
  needs remaining-balance tracking (`filled[quoteId] += requestedAmountIn`,
  invalidated only once `filled == maxAmountIn` or on explicit cancel)
  instead of the single BitInvalidator bit — a materially bigger change: it
  swaps a 256-quotes-per-slot bitmap for a per-quote storage counter,
  re-opens "which fill's NAV/expiry applies to fill #2," and needs its own
  reentrancy analysis around a mid-lifecycle quote. **Kept as a separate,
  larger V2 item** (see [flagged follow-ups](#audit-prep-checklist)), not
  bundled into this amendment.

### Consequences for the rest of the design

- **Breaking wire change.** Repurposing `amountIn`→`maxAmountIn` and
  `amountOut`→`price` changes `SWAP_MESSAGE_TYPEHASH` and, per house
  convention, should bump the EIP-712 domain version
  (`("GyldAtomicSwap", "2")`). Needs the same 3×-independent-recompute
  discipline as the original constants. Nothing is live yet (doc status:
  prototype, uncommitted), so this is free to land pre-launch; post-launch it
  would need a side-by-side versioned domain, not an in-place field rename.
- **NAV band is unaffected.** The band already checks a ratio
  (`amountIn`/`amountOut`); `price` *is* that ratio, so `onSwap`'s
  `QuotePriceOutOfBand` check needs no logic change — only the caller passing
  the derived `amountOut`.
- **Permit sizing shifts to the taker.** `permitIn.value` must now cover
  `requestedAmountIn`, chosen at call time by the taker/wallet — not
  `maxAmountIn` signed by the platform. Same "signed allowance can exceed
  actual transfer" pattern already accepted for the existing permit leg (see
  [observation 3](#audit-prep-checklist)), just applied one layer up.
- **Rounding/decimal-scaling review needed.** `price` must be scaled
  consistently across token-decimal pairs (USDC 6dp vs. bond 18dp) with a
  fixed, audited rounding direction — new arithmetic surface the exact-amount
  design never had (today the signer does this math off-chain once per
  quote; here the chain repeats it per call).
- **Test surface grows.** Every existing `GyldAtomicSwapTest` case built
  around an exact `amountIn`/`amountOut` needs a companion case at
  `requestedAmountIn < maxAmountIn`, plus new coverage for the dust floor,
  `requestedAmountIn == 0`, and `requestedAmountIn > maxAmountIn`.

### Open question before scoping this as real work

Is single-shot-capped sizing (this amendment) actually sufficient, or is the
real requirement multi-draw-over-time (the bigger remaining-balance design)?
They solve different problems and shouldn't be conflated in estimation —
confirm which one the AP/LP flow actually needs before this moves off the
scoping-note stage.

---

## Prior-art lineage

All links verified resolving 2026-06-11.

| Design choice | Source |
|---|---|
| `executeSwap(SwapMessage, signature, Permit)` shape: signed quote + single-use quoteId + two-`transferFrom`-leg + optional EIP-2612 permit | Backed Finance `AtomicSwapUpgradeable` — verified on-chain source: [impl #1](https://eth.blockscout.com/address/0x202BDae6EA5CB576c916cF2D2A83d5a21ea2624D?tab=contract), [impl #2](https://eth.blockscout.com/address/0x3AdF98F5eF70E08af964f33D109Ac032b3d31b24?tab=contract); [audit PDF](https://github.com/backed-fi/audits/blob/main/atomic-swap-audit-report-10-2025.pdf). The direct structural twin; we add taker binding, epoch, NAV band, and a vault (Backed uses standing treasury allowances) |
| Mandatory `taker` binding; quote struct field choices (expiry, origin restriction) | 0x v4 [`OtcOrdersFeature`](https://github.com/0xProject/protocol/blob/development/contracts/zero-ex/contracts/src/features/OtcOrdersFeature.sol), [`NativeOrdersFeature`](https://github.com/0xProject/protocol/blob/development/contracts/zero-ex/contracts/src/features/NativeOrdersFeature.sol), [order docs](https://docs.0xprotocol.org/en/latest/basics/orders.html) |
| Pool-held inventory filled against signed quotes; **every approval target must be small, verified, in audit scope** | Hashflow [Router](https://github.com/hashflownetwork/x-protocol/blob/main/evm/contracts/HashflowRouter.sol)/[Pool](https://github.com/hashflownetwork/x-protocol/blob/main/evm/contracts/pools/HashflowPool.sol); [CertiK post-mortem of the June-2023 $640K exploit](https://www.certik.com/resources/blog/post-mortem-hashflow) (arbitrary `transferFrom` in an unaudited peripheral holding approvals) |
| BitInvalidator bitmap (256 quote IDs/slot) + epoch mass-cancel | 1inch [`BitInvalidatorLib`](https://github.com/1inch/limit-order-protocol/blob/master/contracts/libraries/BitInvalidatorLib.sol), [`SeriesEpochManager`](https://github.com/1inch/limit-order-protocol/blob/master/contracts/helpers/SeriesEpochManager.sol) |
| Decimal-scaling layer; asymmetric pause role split; rate-limit caps (off-chain V1, on-chain V1.1 candidate); no-buffer-minimum `withdraw` | Ondo OUSG [`ousgInstantManager`](https://github.com/code-423n4/2024-03-ondo-finance/blob/main/contracts/ousg/ousgInstantManager.sol) + `InstantMintTimeBasedRateLimiter`; [Code4rena report](https://code4rena.com/reports/2024-03-ondo-finance) (H-01: buffer-minimum revert broke redemptions) |
| Obligations as receivables inside `totalAssets` (AUM = cash + recognized receivable) | Maple v2 [`LoanManager`](https://github.com/maple-labs/fixed-term-loan-manager/blob/main/contracts/LoanManager.sol), [pool-v2](https://github.com/maple-labs/pool-v2) |
| Virtual-offset first-depositor defense; ERC-7540 as the queued-exit V2 shape | [OZ ERC-4626 docs](https://docs.openzeppelin.com/contracts/5.x/erc4626) + [implementation](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/token/ERC20/extensions/ERC4626.sol); [EIP-7540](https://eips.ethereum.org/EIPS/eip-7540); [Centrifuge reference impl](https://github.com/centrifuge/liquidity-pools/blob/main/src/ERC7540Vault.sol) |
| Instant-vs-queued redemption split; NAV-feed-driven `totalAssets` | OpenEden TBILL [`OpenEdenVaultV5` verified source](https://eth.blockscout.com/address/0xc4545Bf80f935894CbE138D86b506923Dab7c048?tab=contract), [address list](https://docs.openeden.com/tbill/smart-contract-addresses) |
| Singleton + UUPS + ERC-7201 + timelock admin + non-renounceable + probe-before-store; tokens-to-IssuanceManager as burn commitment | House style: `IssuanceManager` (singleton + probe idiom), `GyldBondToken` (storage/role/permit idiom), `NAVFeedForwarder` (probe idiom), existing two-step redemption + backend `BurnWatcher` |

---

## Deviations from the design doc

The implementation deviates from the agreed design skeleton in eight places,
each deliberate:

1. `renounceRole` param renamed `account` → `callerConfirmation` — matches both
   existing contracts' override signature.
2. `isQuoteUsed`/`_consumeQuote` bit tests restructured to `(word >> bit) & 1`
   — avoids forge-lint `incorrect-shift` false positives; one unavoidable
   `1 << bit` kept with an inline justified disable.
3. **Added `InvalidNav(address,int256)` guard** in `_navValueUsdc` — the
   skeleton's bare `uint256(nav)` cast would silently wrap a negative feed
   answer into a huge valuation. Fail-closed instead.
4. **`deregisterSeries` hardened** (not in skeleton): requires zero inventory
   AND zero obligations (`SeriesNotEmpty`), swap-and-pops `seriesList`, deletes
   both mappings — silently dropping a valued series would mark down LP shares.
5. **`setSwap` hardened** (not in skeleton): probes `SWAP_MESSAGE_TYPEHASH()`
   (mirrors IssuanceManager probing `MINTER_ROLE()`) and atomically revokes
   `SWAP_ROLE` from the previous swap / grants to the new — at most one swap
   contract can ever drive `onSwap`.
6. `setMaxQuoteDeviationBps` rejects > 10 000 (`InvalidDeviationBps`) — a band
   over 100% disables the guard rail entirely; 0 permitted (soft-pause).
7. Added explicit public getters (`usdc()`, `issuanceManager()`, `swap()`,
   `maxQuoteDeviationBps()`, `registeredSeries(address)`,
   `navForwarderOf(address)`) — house convention over ERC-7201 storage.
8. `totalAssets` loop drops the skeleton's inner `registeredSeries` re-check —
   `deregisterSeries` removes entries, so list membership ⇔ registered.

---

## Test coverage

`forge test`: **407 passed / 0 failed / 0 skipped (13 suites)** — 323
pre-existing tests all green (zero regressions). `forge build --force`: zero
warnings referencing the new files.

**`GyldAtomicSwapTest` — 25 tests:** happy-path BUY via USDC permit and via
plain allowance; happy-path REDEEM via GyldBondToken EIP-2612 permit; expired
quote; stale epoch (incl. new-epoch quote succeeding post-bump); replayed
quoteId (incl. replay on a different leg); wrong signer; tampered message;
wrong taker; paused + asymmetric unpause; permit front-run does not brick
(attacker pre-consumes nonce, swap still settles via allowance); zero
amountIn/amountOut; `setVault` probe matrix (EOA / wrong contract / zero /
non-admin / valid / invalid-at-initialize); epoch getter/events; admin
renounce guard.

**`GyldSettlementVaultTest` — 59 tests:** virtual-offset share ratio; full
round trip; proportional second depositor; first-depositor inflation attack
(victim shares > 0, attacker exits at a strict loss); `onSwap` role gating;
NAV band rejection both sides + exact band-edge acceptance + `NotOneBondLeg`
matrix; `InsufficientInventory`; `InsufficientUsdcLiquidity` on both `onSwap`
and `withdraw` (full exit reverts on free-USDC shortage, partial exit
succeeds); **full draw → fill → settle → forward → repay lifecycle with
`totalAssets` asserted at every step** (incl. the documented transient
double-count) ending in an at-par LP exit; `ObligationUnderflow` both types;
partial settle; treasurer bridge live while paused; `InvalidNav` fail-closed
(0 and −1); `registerSeries` probe matrix; `deregisterSeries`
(inventory-blocked / obligation-blocked / success drops from valuation);
`setSwap` atomic role handover; `setMaxQuoteDeviationBps` cap + band-widening;
asymmetric pause; renounce guard; initializer zero-address guards.

Constants (`_STORAGE_LOCATION` ×2, `SWAP_MESSAGE_TYPEHASH`) were independently
recomputed three times — at implementation, during test authoring, and during
review — with `cast keccak`/python; all match.

**Still to add (Phase 1):** a deploy-script fork test (all 6 steps against an
Anvil fork of `DeployDevNet.s.sol` output, then one BUY + one REDEEM
end-to-end) and a `StdInvariant` handler asserting `totalAssets` conservation
across swap/draw/settle/forward/repay sequences and that the vault never mints
bond tokens (audit packet item).

---

## Deployment & wiring run-book

To land as `contracts/script/DeployAtomicSettlement.s.sol`, following the
existing per-step + run-book-header convention (`DeployEulerStep1..6.s.sol`,
`DeployNAVFeed.s.sol` as style references). Each step idempotent and
individually broadcastable:

| Step | Action | Signer (mainnet) |
|------|--------|------------------|
| 1 | Deploy `GyldSettlementVault` impl + `ERC1967Proxy` with `abi.encodeCall(initialize, (timelock, opsMultisig, treasurerMPC, usdc, issuanceManager))` | deployer |
| 2 | Deploy `GyldAtomicSwap` impl + `ERC1967Proxy` with `abi.encodeCall(initialize, (timelock, opsMultisig, quoteSignerKMS, vaultProxy))` | deployer |
| 3 | `vault.grantRole(SWAP_ROLE, swapProxy)` | timelock tx (direct on Hoodi) |
| 4 | **`IssuanceManager.addToWhitelist(vaultProxy)`** — the **only** touch on existing contracts. The vault becomes an AP; `subscribe(token, vaultProxy, n)` replenishes it through the unchanged mint-at-fill pipeline. The swap is deliberately **not** whitelisted (never a mint recipient or redeem beneficiary; the AP whitelist doesn't gate secondary transfers) | `WHITELIST_ADMIN_ROLE` (ops multisig) |
| 5 | Per series: `vault.registerSeries(token, TokenFactory.forwarderOf(token))` — reverts unless the forwarder reports 8 decimals | timelock tx |
| 6 | `vault.grantRole(LP_ROLE, <each KYC'd LP>)` + **seed a dust LP deposit** (anti-inflation belt-and-braces on top of virtual shares) | timelock tx + treasury |

**Hoodi testnet (chain 560048):** KMS signer ARN as `quoteSigner` (Tier-4 dev
signing, `EVM_KMS_KEY_ID` convention); record proxy addresses in
`docs/blockchain-status.md`. Exit check: a manual `executeSwap` BUY with a
hand-signed quote, with `cast`/script parity verified against
`hashSwapMessage`. **Mainnet:** timelock as admin, Fordefi for treasurer/ops
signing, real USDC + live Chainalysis oracle, conservative caps +
`maxQuoteDeviationBps`, 1-week limited-notional canary.

**Backend wiring (kaleidoscope, no contract impact):** zero `BurnWatcher`
code change — `forwardForBurn` lands tokens at the IssuanceManager address it
already watches; add the vault address to backend config so vault-origin
commitments are classified as netted-redemption legs, and point the quote
service's signing key at `QUOTE_SIGNER_ROLE`.

**Users: zero setup.** Buy = USDC approve/permit to swapProxy + `executeSwap`;
redeem = single tx via GyldBondToken's existing EIP-2612 permit inside the
`executeSwap` calldata.

### Operational levers (run-book entries, sourced from review)

- **NAV-feed fault:** a permanently ≤0/bricked forwarder reverts `totalAssets`
  → freezes `deposit`/`withdraw`/`onSwap`/`forwardForBurn` vault-wide
  (`deregisterSeries` can't run with inventory; `forwardForBurn` itself needs
  the feed). **Escape hatch: re-`registerSeries(token, freshForwarder)`** —
  re-registration overwrites; timelock tx.
- **Signer rotation:** grant new `QUOTE_SIGNER_ROLE` → `bumpQuoteEpoch()`
  (mass-invalidates) → revoke old; QuoteService refreshes its epoch cache on
  `QuoteEpochBumped`.
- **Pause drill:** PAUSER halts swap and/or vault independently; only timelock
  unpauses. Treasurer bridge stays live while the vault is paused (tested) —
  use it to wind down.
- **Soft pause:** `setMaxQuoteDeviationBps(0)` forces exact-NAV quotes; halting
  the QuoteService halts new flow entirely.
- **Alert hygiene:** zero-amount `settleReplenishment`/`repayUsdc` succeed
  vacuously and emit events — filter in alerting.

---

## Audit-prep checklist

Scope: the two new contracts + wiring (whitelist grant, `registerSeries`,
`SWAP_ROLE`/`LP_ROLE` grants). Packet contents:

- [ ] ERC-7201 slot constants + `SWAP_MESSAGE_TYPEHASH` with independent
      recomputation transcript (done 3×, all match — see above).
- [ ] **Approvals inventory** (Hashflow-lesson item): users approve only
      `GyldAtomicSwap`, exact-amount, short-deadline via permit; the vault
      grants **zero** allowances to anyone; the swap holds no funds.
- [ ] Prior-art diff vs Backed `AtomicSwapUpgradeable` (incl. their Oct-2025
      audit PDF), Hashflow post-mortem, 0x OTC, 1inch invalidation, Ondo C4
      findings — links in the [lineage table](#prior-art-lineage).
- [ ] `StdInvariant` fuzz handler: `totalAssets` conservation across
      swap/draw/settle/forward/repay; vault-never-mints-bond-tokens.
- [ ] Deploy-script fork test transcript (6 steps + one BUY + one REDEEM).
- [ ] Reviewer's seven non-blocking observations, verbatim:
  1. **Feed-fault wind-down dependency** — broken NAV feed freezes the whole
     vault; escape hatch is re-`registerSeries` to a fresh forwarder
     (run-book item above).
  2. `settleReplenishment(token, 0)` / `repayUsdc(token, 0)` succeed vacuously
     and emit events (no `ZeroAmount` guard, unlike draw/forward). Cosmetic;
     ops-alert filter item.
  3. **Residual permit allowance** — `permitIn.value` may exceed `m.amountIn`,
     leaving leftover allowance to the swap. Safe (only spendable via
     taker-initiated `executeSwap`), but the QuoteService must issue
     **exact-value permits** (tests already do).
  4. **`buybackOwed` booked at forward-time NAV** — NAV drift before
     `repayUsdc` accrues to/from LPs. Matches the accepted design model;
     explicitly flagged for the auditors as an accepted risk.
  5. Probe idiom accepts any contract returning exactly 32 bytes for the
     probed selector (e.g. a returning fallback) — inherent to the house
     pattern (IssuanceManager's `MINTER_ROLE()` probe shares it).
  6. gyldLP shares are 18-dp vs 6-dp USDC — 1 share ≠ 1 USDC in explorers
     (offset makes it 1000 shares per micro-USDC). Cosmetic.
  7. `deposit` computes shares before `transferFrom` — correct for USDC; would
     misaccount for a fee-on-transfer asset. Not applicable; noted.
- [ ] Flagged follow-ups (separate issues, new audit delta if taken):
      on-chain V1.1 rate limiter in `onSwap` (Ondo
      `InstantMintTimeBasedRateLimiter` pattern; if a min size is added, keep
      min < cap remainder — the Ondo Medium); ERC-7540 request queue for LP
      exits (V2); capped-allowance `SwapMessage` for taker-sized single-use
      fills, see [Proposed amendment](#proposed-amendment-capped-allowance-swapmessage)
      (plus its own larger V2: multi-draw remaining-balance tracking).

---

## Roadmap (this repo's slice)

The full programme (QuoteService, SwapWatcher, VaultInventoryDriver, recon,
frontend, LP onboarding) lives in the kaleidoscope backend — see
`kaleidoscope/docs/design/atomic-settlement-roadmap.md`; gyld-contracts
owns the following:

| Phase | Deliverable | Exit criterion |
|-------|-------------|----------------|
| **1 — Land** | Commit the 4 untracked files + this doc + `docs/decisions/atomic-settlement.md` + audit-notes doc on `feat/GYL-xxx-atomic-settlement` (Linear epic + children first — the pre-commit hook requires `GYL-xxx`); update `docs/contracts.md` + `docs/blockchain-status.md` inventory/deployment matrix; write `DeployAtomicSettlement.s.sol` + fork test | `forge build --force` zero warnings; 407+ green incl. fork test; PR merged with Linear linkage |
| **1 — Hoodi** | Deploy via the script to chain 560048, KMS quote signer; publish proxy addresses in `docs/blockchain-status.md` | Manual `executeSwap` BUY succeeds on Hoodi with a hand-signed quote; `hashSwapMessage` parity verified |
| **5 — Audit** | External audit of the two contracts + wiring, packet per the [checklist](#audit-prep-checklist); add the `StdInvariant` suite; remediation commits re-run the full suite | Report closed, no highs/criticals outstanding |
| **5 — Mainnet** | Deploy with timelock admin, Fordefi signing, real USDC + Chainalysis live, dust seed, conservative caps; rehearse pause + key-rotation drills on Hoodi first | 1-week limited-notional canary clean (zero recon incidents); caps raised to policy targets |
| **V1.1 / V2 (flagged)** | On-chain rate limiter in `onSwap`; ERC-7540 LP exit queue; [capped-allowance `SwapMessage`](#proposed-amendment-capped-allowance-swapmessage) for taker-sized fills + its own V2 multi-draw remaining-balance tracking | Separate issues + audit deltas |

Phases 2–4 (everything off-chain) gate on Phase 1's Hoodi addresses but the
external audit can start immediately after Phase 1 lands — the final report
gates mainnet only.
