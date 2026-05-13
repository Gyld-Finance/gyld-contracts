# Kaleidoscope — Architecture

Single-tenant platform for issuing tokenized fixed-income products (treasuries,
corporate bonds, bond ETFs) backed 1:1 by securities held at an external broker
(Alpaca on day 1). Primary chain: **Ethereum (EVM) — current focus.**
Solana, Chainlink, Pyth, and Fordefi adapters are wired through port traits but
deferred post-MVP. See [`docs/decisions/deferred-integrations.md`](decisions/deferred-integrations.md).

---

## System overview

```
                                 ┌───────────┐
                                 │ User / UI │
                                 └─────┬─────┘
                                       │ HTTPS
                                       ▼
                                 ┌───────────┐
                                 │  gateway  │   auth + validation
                                 └─────┬─────┘
                                       │ REST
                                       ▼
         ┌─────────────────────────────────────────────────────────────┐
         │                            core                             │
         │  Workflow orchestrator. Owns all state machines.            │
         │                                                             │
         │  Drivers (tokio loops):                                     │
         │    MintDriver · RedemptionDriver · KycDriver                │
         │    YieldDriver · DepositDriver · WithdrawDriver             │
         └──┬───────────────┬──────────────────┬─────────────────┬─────┘
            │ REST          │ REST             │ REST            │ REST
            ▼               ▼                  ▼                 ▼
    ┌────────────────────┐ ┌────────────────────┐ ┌────────────────┐
    │   Asset Plane      │ │ Tokenization Plane │ │   Onboarding   │
    │  ───────────────── │ │ ────────────────── │ │ ────────────── │
    │  fiat-broker       │ │  tokenization      │ │   onboarding   │
    │  securities-broker │ │    + FreezeDriver  │ │                │
    │  settlement        │ │  pricing           │ │                │
    │  custodian         │ │  screening         │ │                │
    │  instrument-catalog│ │                    │ │                │
    └─────────┬──────────┘ └──────────┬─────────┘ └────────┬───────┘
              │                       │                    │
              ▼                       ▼                    ▼
           Alpaca            Chainlink · Pyth            Onfido
                             Chainalysis                 / manual
                             ETH / SOL L1


    Observers  (event-driven; write rows directly into core's DB)
    ─────────────────────────────────────────────────────────────────
    ETH / SOL chains  ──►  deposit-watcher  ──►  core.mint_requests
    Alpaca + chains   ──►  reconciliation   ──►  core.incidents
                                            ──►  LedgerRepo backfill


    Persistence  (cross-cutting)
    ─────────────────────────────────────────────────────────────────
    Postgres  — source of truth; every service owns its schema; core owns
                workflow tables (mint / redemption / kyc / yield / hints).
    Redis     — hot cache for instrument-catalog's InstrumentRepo (10-min TTL).
```

The diagram above shows the **target distributed topology (Phase 2)**. In the
current Phase 1 monolith all arrows are in-process `async fn` calls — no REST
between services. See the **Deployment topology** section below for the actual
binary structure. Observers run independently and write rows into core's DB —
core does not call them. Every service additionally takes `Arc<dyn Clock>`
in-process; not shown.

---

## Deployment topology (Phase 1)

Phase 1 ships a **monolith**: all services compile into a single binary
(`kaleidoscope-gateway`) and run in the same OS process.  The hexagonal
architecture is preserved — each "service" is an independent struct wired
together in `bootstrap/src/main.rs` — but there are no network hops between
them.

```
kaleidoscope-gateway (single binary)
├── inbound-http          ← Axum router; auth (Keycloak JWT)
├── core services
│     Onboarding · TradeExecutor · PostTradeProcessor
│     Minting · Redemption
├── reconciliation service (in-process)
│     Reconciliation · LedgerReplicationDriver
├── tokenization service (in-process, wraps EVM chain + wallets)
│     FreezeDriver
└── adapters (in-process, via Arc<dyn Port>)
      Alpaca (custodian + fiat + securities + settlement)
      EVM chain · Fordefi wallet
      Onfido KYC · Postgres · Redis
```

**Why monolith first:**

- Eliminates network serialization and service-discovery overhead during
  initial development; all calls are in-process `async fn` invocations.
- A single `cargo run -p kaleidoscope-gateway` boots the whole platform with
  zero infra (in-memory fakes replace every adapter when env vars are absent).
- The hexagonal boundary is maintained throughout: splitting any service into
  its own binary in Phase 2 requires only adding a network transport adapter
  — no changes to `core`.

**Phase 2 split path (`instrument-catalog` already extracted; remaining services not yet scheduled):**

Each logical service already owns a clean interface (one `Arc<dyn Port>` per
dependency).  Extracting a service means:

1. Wrapping the port impl in an HTTP/gRPC adapter (outbound) on the caller
   side and an Axum/tonic handler (inbound) on the callee side.
2. Updating `bootstrap/src/main.rs` to inject the network adapter instead of
   the in-process one.
3. No changes to `core` or any other service.

The monolith and the distributed topology share the same Postgres schema;
Postgres remains the source of truth and the coordination point regardless of
deployment shape.

---

## Three planes

The business domain maps onto three planes. Each plane owns a set of port
interfaces (`core/src/ports/`); adapters implement them and live in separate
crates. `core` never depends on an adapter crate.

### Asset plane

Manages the real-world securities lifecycle and fiat flows.

| Port | Responsibility | Day-1 adapter |
|------|---------------|---------------|
| `ICustodian` | Fiat + securities custody; deposit / withdraw / lock / unlock positions | `adapter-alpaca-custodian` |
| `ISettlement` | T+1 / T+2 settlement tracking; blocks mint until `Settled` | `adapter-alpaca-settlement` |
| `IFiatBroker` | USD ↔ USDC swap | `adapter-alpaca-fiat` |
| `ISecuritiesBroker` | Bond / ETF orders, coupons, maturities, order status polling | `adapter-alpaca-securities` |
| `IInstrumentSource` | Venue's instrument catalog (assets list) | `adapter-alpaca-securities` |

### Tokenization plane

Manages on-chain token lifecycle and multi-chain dispatch.

| Port | Responsibility | Day-1 adapters |
|------|---------------|----------------|
| `IWallet` | Custodial wallet ops (create, transfer) — per chain via `WalletRouter` | `adapter-wallet-evm`, `adapter-wallet-sol`, `adapter-wallet-fordefi`, `adapter-wallet-privkey` |
| `IChain` | Contract calls (mint, burn, pause, freeze), event subscriptions — per chain via `ChainRouter` | `adapter-chain-evm` (ETH + other EVM) |
| `IPriceOracle` | Bond price / NAV feed; on-chain attestation to `KaleidoscopeNAVFeed` | `adapter-oracle-chainlink`, `adapter-oracle-pyth` |
| `IAddressScreener` | AML / sanctions screening; `Block` halts any transfer or mint | `adapter-sanctions-chainalysis` |

### Onboarding plane

Manages user identity and accreditation.

| Port | Responsibility | Day-1 adapters |
|------|---------------|----------------|
| `IKyc` | Document submission, status polling, webhook callback | `adapter-kyc-onfido`, `adapter-kyc-manual` |

#### KYC tiers

| Tier | Who | Required documents | Unlocks |
|------|-----|--------------------|---------|
| `Basic` | Retail investors | Government ID + selfie (Onfido) | Minting up to \$10 k lifetime |
| `Accredited` | Accredited investors | Basic docs + income / net-worth attestation | Full minting (no cap) |
| `Institutional` | Corporate / institutional entities | KYB pack — entity docs + beneficial-owner IDs | Institutional limits (TBD) |

The provider sets the tier at approval time; it is carried in
`KycStatus::Approved { tier, .. }` and stored on the `User` record.
The **Minting** service reads the tier to enforce per-tier limits before
issuing tokens.

---

## Core domain model

```
User ────── KycCase ─── KycStatus (NotStarted → Submitted → UnderReview → Approved { tier } / Rejected)
                        KycTier:   Basic | Accredited | Institutional
 │
 ├── CustodianAccountId      (Alpaca brokerage account; assigned on KYC approval)
 ├── WalletRef[]             (chain wallets the user controls; registered post-KYC)
 ├── SourceAddress[]         (external wallets the user will send USDC from;
 │                            registered post-KYC via KycFlow or UserAction)
 └── token_recipient_address (chain wallet where minted tokens are delivered)

Instrument ─── InstrumentId          (unified, platform-owned)
 │              Cusip / Isin          (external security identifiers — unique per Instrument)
 │              asset_class, issuer, maturity, face_value, …
 │
VenueInstrumentMap ─── (venue, venue_symbol) ──▶ InstrumentId
 │                     Multiple venues can map to the same Instrument
 │                     (same CUSIP traded at Alpaca and a future broker)
 │
── Org / membership ──────────────────────────────────────────────────────────
Org ──────────── id, name, created_at
OrgMembership ── org × user × role (Trader | ComplianceOfficer | OpsEngineer |
                                      KycReviewer | SuperAdmin)
ApprovalPolicy ─ org, action (Mint | Redeem | Withdraw), amount_threshold,
                  required_approvers: u8
                  (one row per (org, action, threshold) band)

── Cash (balance-first model) ────────────────────────────────────────────────
CashBalance ──── user × chain × currency → available + held + total
                  (source of truth for spendable USDC per chain)

DepositRequest ─ user, chain, tx_hash, log_index  -- UNIQUE (dedup)
                  amount, status, credited_at
                  States: CONFIRMING → CREDITED | FAILED

WithdrawRequest ─ user, chain, destination_address,
                   amount, fee, screening_decision,
                   status, attempt_count, next_retry_at, last_error
                   States: ACCEPTED → SCREENING → AWAITING_TRANSFER → COMPLETED
                   terminals: BLOCKED, FAILED

── Approval ──────────────────────────────────────────────────────────────────
ApprovalRequest ─ org, action_type, workflow_id, initiated_by,
                   required_approvers, approvals[], status
                   States: PENDING → APPROVED | REJECTED
                   Constraints: initiator ∉ approvers; each approval carries
                   an optional note persisted to LedgerRepo

── Issuance / Redemption ─────────────────────────────────────────────────────
MintRequest ─── funding_source (UsdcDeposit | BrokerCash)
                 deposit_chain?, deposit_tx?, deposit_log_index?  -- UNIQUE when present
                 fiat_in, mint_limit, fee, idempotency_key?
                 swap_ref?, order_id?, status,
                 attempt_count, next_retry_at, last_error
RedemptionRequest ── token_id, qty, lot_method (Fifo | Lifo | SpecificId),
                      fee, order_id, swap_ref, status,
                      attempt_count, next_retry_at, last_error
FeeSchedule ── kind, tier, flat_fee, percentage_bps, effective_from, effective_to

── Tax lots ──────────────────────────────────────────────────────────────────
TaxLot ─────── user × token × mint_request_id → qty, cost_basis_per_unit,
                acquired_at
                (one row per mint; partial redemptions consume lots in
                 lot_method order and split the lot row)

── Orders / Positions / Tokens ───────────────────────────────────────────────
Order ──────── BrokerOrderId, side (Buy/Sell), status, fill_price, fill_qty, filled_at
Position ────── held at custodian, locked by Issuance, unlocked by Redemption
Token ──────── contract address, chain, symbol, cusip
TokenHolding ── user × token × wallet × amount

── Ledger ────────────────────────────────────────────────────────────────────
LedgerEntry ─── every external event mirrored here with external_ref (idempotent)
                 LedgerChange variants:
                   FiatDeposit, FiatWithdraw, FiatSwap
                   SecurityBought, SecuritySold
                   CouponReceived, MaturityPaid
                   PositionLocked, PositionUnlocked
                   TokenMinted, TokenBurned, TokenTransferred
                   Fee { amount, description }        ← Alpaca fee / commission
                   Interest { amount }                ← cash interest accrual
                   Dividend { instrument_id, amount } ← dividend payment
                   JournalEntry { note, amount }      ← internal custodian transfer
                   CashTransfer { direction, amount, counterparty } ← ACH/wire
                   CorporateAction { instrument_id, description }   ← splits etc.
                   FreezeRequested, FreezeConfirmed
                   ApprovalGranted { note? }, ApprovalRejected { reason }
Money ────────── amount + Currency (Usd / Usdc)
```

---

## Services

**Phase 1 (current):** all services run inside the single `kaleidoscope-gateway`
binary. `bootstrap/src/main.rs` is the wiring point — each "service" is an
independent struct that receives `Arc<dyn Port>` injections, but all calls are
in-process `async fn` invocations with no network hops.

**`core`** is the workflow orchestrator — it owns the state machines
(`MintRequest`, `RedemptionRequest`, `KycCase`, `Order`) and drives progression
by calling outbound ports whose implementations are wired in at startup.

Postgres is the **durable journal**, not a coordination bus. `core`'s DB
stores every workflow's state history for crash recovery and replay. Each
adapter stores its own operations keyed by `request_id` for idempotency —
repeated calls from `core` resolve to the same external action rather than
re-invoking the vendor.

#### Phase 2 distribution path (`instrument-catalog` already extracted; others not yet scheduled)

When a service needs hard process isolation it can be extracted without changing
`core`: wrap the in-process adapter in an HTTP/gRPC server on the callee side,
and replace the in-process adapter with a REST-client impl of the same port
trait on the caller side. `bootstrap` swaps the injection; `core` sees no
difference. The `adapter-rest-instrument-catalog` crate is the deployed example
of this pattern — the instrument catalog already runs as a separate
`instrument-catalog` binary and `core` calls it over HTTP via an
`IInstrumentCatalog` REST-client adapter. All other services remain in-process.

### Service decomposition

Logical decomposition — same in Phase 1 monolith and Phase 2 distributed.
In Phase 1 "port (inbound)" is an in-process trait injection, not a REST
endpoint. In Phase 2 it would become the HTTP surface of the extracted service.

| Service | Port (inbound) | Ports (outbound) | Role | External |
|---------|----------------------|------------------|------|----------|
| `gateway` | — | — | HTTP ingress, auth, validation; creates initial workflow rows in `core`'s DB | User |
| `core` | — | — | Workflow orchestrator; holds all state machines; fee calculation is internal here | — |
| `deposit-watcher` | — | `IChain` (subscribe) | Subscribes to USDC `Transfer` events on platform-owned deposit addresses; credits `CashBalance` and writes a `DepositRequest` row (balance-first model) | ETH / SOL L1 chains |
| `onboarding` | `IKyc` | — | Submit KYC, poll status, relay provider webhooks | Onfido / Manual |
| `screening` | `IScreening` | `IAddressScreener` | Screen addresses on demand | Chainalysis |
| `fiat-broker` | `IFiatBroker` | — | Place USD/USDC swaps, report status | Alpaca (USD/USDC — Broker 1) |
| `securities-broker` | `ISecuritiesBroker` | — | Place bond orders, report fill status | Alpaca (Bond/USD — Broker 2) |
| `settlement` | `ISettlement` | — | Report T+1/T+2 settlement status on demand | Alpaca (Bond Settlement) |
| `custodian` | `ICustodian` | — | Lock / unlock positions on demand | Alpaca (Custodian) |
| `tokenization` | `ITokenization` | `IWallet`, `IChain` (via `WalletRouter` / `ChainRouter`), `IAddressScreener` | Mint, burn, transfer, freeze/pause on-chain; per-`ChainId` dispatch internal | ETH / SOL wallets + L1 chains |
| `pricing` | `IPricing` | `IPriceOracle`, `IChain` | Fetch bond prices and publish NAV to on-chain feed | Chainlink / Pyth |
| `instrument-catalog` | `IInstrumentCatalog` | — | Sync venue instrument lists; resolve unified `InstrumentId` ↔ CUSIP/ISIN ↔ venue symbol | Alpaca (+ future venues) |
| `reconciliation` | — | `ICustodian`, `ISecuritiesBroker`, `IChain` (read-only) | Multi-level recon of internal ledger vs. external sources; emits discrepancy events | Alpaca, chain RPCs |

### Core

`core` is the only service with business logic. It owns the workflow
state machines and calls outbound port traits to execute each step. In Phase 1
those traits are implemented by in-process adapters; in Phase 2 they would be
implemented by REST-client adapters.

#### Internal layers (hexagonal within core)

```
inbound (HTTP from gateway, via AppState)
  │
  ▼
application services
  MintService   RedemptionService   OnboardingService   PortfolioService
  FeeCalculator   (internal module, not a port)
  │
  ▼
domain
  MintRequest / RedemptionRequest / KycCase / Order
  state transition rules
  │
  ▼
outbound ports (in-process trait dispatch — Phase 1)
  IFiatBroker   ISecuritiesBroker   ISettlement   ICustodian
  IChain   IWallet   IAddressScreener   IKyc   IPriceOracle
  │
  ▼
infrastructure: Postgres repos, in-process adapters, Clock
```

#### Workflow drivers

Seven independent `tokio` loops advance workflows across the system — six run
inside `core`, one inside the `reconciliation` service. Each has its own tick
interval, concurrency, and failure isolation.

| Driver | Service | Workflow | Tick interval |
|--------|---------|----------|--------------|
| `MintDriver` | core | `MintRequest` lifecycle | 2 s |
| `RedemptionDriver` | core | `RedemptionRequest` lifecycle | 2 s |
| `DepositDriver` | core | `DepositRequest` lifecycle (balance-first USDC credit) | 5 s |
| `WithdrawDriver` | core | `WithdrawRequest` lifecycle | 5 s |
| `KycDriver` | core | `KycCase` lifecycle | 1 hr |
| `YieldDriver` | core | `YieldEvent` lifecycle (coupons / maturities) | 5 min |
| `LedgerReplicationDriver` | reconciliation | Alpaca activity-feed → `LedgerRepo` mirror | 30 s |

Each tick:

```sql
SELECT ... FROM <workflow_table>
WHERE status IN (<actionable states>)
  AND (next_retry_at IS NULL OR next_retry_at <= now())
FOR UPDATE SKIP LOCKED
LIMIT <batch>
```

`SKIP LOCKED` lets core scale horizontally later without replicas
contending on the same row.

Two kinds of transitions happen inside a tick:

- **Synchronous adapter call** — fast steps (screening, swap placement,
  position lock, mint). Call the adapter, wait for response, write next
  state in the same tick.
- **Status poll** — for waits on external settlement or provider review
  (`AWAITING_SWAP_SETTLEMENT`, `AWAITING_ORDER_SETTLEMENT`, `UNDER_REVIEW`),
  call the adapter's status endpoint and only advance if the external
  system reports completion.

#### Crash recovery and idempotency

- Core persists the target state and any returned refs (`swap_ref`,
  `order_id`, `case_id`) to its DB **before** the REST call.
- If core crashes mid-flight, the row is unchanged and the next tick retries.
- Every outbound REST call carries an `X-Request-Id` header, deterministic
  from the workflow: `"{order_id}:{step_name}"`. Adapters dedup on it
  and return the prior result for repeats — no duplicate external action.
  The canonical step names for `PostTradeProcessor` are `swap`, `buy`,
  `sell`, `mint`, and `burn`; for `Minting` they are `swap` and `mint`.
  Four port methods carry this parameter: `IFiatBroker::swap`,
  `ISecuritiesBroker::buy` / `sell` / `cancel` / `order_status`, and
  `IChain::mint_token` / `burn_token` / `transfer_tokens`.
- Each adapter service keeps its own idempotency + audit table, keyed by
  `request_id`, recording inbound call and outbound external result.

#### Retry policy

Every workflow row carries:

```
attempt_count    int       default 0
next_retry_at    timestamp nullable
last_error       text      nullable
```

On transient REST error (5xx, timeout, connection refused):
- increment `attempt_count`
- set `next_retry_at = now() + backoff(attempt_count)`
- write `last_error`

Backoff schedule: `1s → 5s → 30s → 2m → 10m`. After N attempts (configurable,
default 6), the row transitions to `FAILED { step }`.

On business error (`4xx` with a domain reason — order rejected, screener
blocked, etc.): transition directly to `FAILED` or `BLOCKED`, no retry.

#### Fees

Fees are computed at `ACCEPTED` time and snapshotted onto the workflow row,
so schedule changes never affect in-flight workflows.

```
fee_schedules
  id              uuid pk
  kind            enum: MINT | REDEMPTION
  tier            enum: BASIC | ACCREDITED | INSTITUTIONAL
  flat_fee        money
  percentage_bps  int           -- basis points
  effective_from  timestamp
  effective_to    timestamp nullable

  EXCLUDE USING gist (
    kind WITH =,
    tier WITH =,
    tstzrange(effective_from, effective_to, '[)') WITH &&
  )
```

Non-overlapping `(effective_from, effective_to)` ranges per `(kind, tier)` are
enforced by the exclusion constraint — `FeeCalculator` is guaranteed to find
**exactly one** active schedule per `(kind, tier)` at any point in time, so
there is no tie-break logic to maintain.

`FeeCalculator` reads the active schedule for the `(kind, tier)` pair at
`ACCEPTED` time and writes the computed fee onto the request row. Fees are
deducted at settlement time and appended to `LedgerRepo`.

#### Inbound API (gateway → core)

**Invest app (investor-facing)**

```
-- Cash / deposit / withdraw (balance-first model)
GET  /cash-balance              → { available, held, total, by_chain[] }
POST /deposit               { user_id, chain }  -- returns deposit address; watcher credits on-chain
                            → 201 { deposit_address, chain }
POST /withdraw              { user_id, chain, destination, amount }
                            → 201 { withdraw_request_id, status: ACCEPTED, fee,
                                    requires_approval? }
GET  /withdraw/:id          → { status, history[], fee, failure? }

-- Issuance (balance-first: funds from CashBalance or broker cash)
POST /mint              { user_id, token_id }    -- debit CashBalance; create MintRequest
                        → 201 { mint_request_id, status: ACCEPTED, fee }
POST /invest            { user_id, token_id, usd_amount }   -- BrokerCash path
                        Idempotency-Key: <UUID>
                        → 201 { mint_request_id }

GET  /mint/:id          → { status, history[], fee, failure?, funding_source }

-- Redemption (credits CashBalance on completion, no USDC transfer)
POST /redeem            { user_id, token_id, qty, lot_method? }
                        → 201 { redemption_request_id, status: ACCEPTED, fee,
                                requires_approval? }
GET  /redeem/:id        → { status, history[], fee, failure? }

-- KYC & portfolio
POST /kyc               { user_id, documents }
                        → 201 { case_id, status: SUBMITTED }
GET  /kyc/:id           → { status, tier?, reason? }
GET  /portfolio/:user   → { balances, positions, holdings, lots[] }

-- Approvals
GET  /approvals                     → [ ApprovalRequest ]
POST /approvals/:id/approve         { note? }  → 200 | 409 (already decided)
POST /approvals/:id/reject          { reason } → 200 | 409
```

**Console app (operator-facing, role-gated)**

All console routes require a JWT with an operator role claim; see
[§Console plane (operations screens)](#console-plane--operations-screens)
for role-to-route mapping.

```
-- System health & workflows
GET  /admin/health                  → { drivers[], queue_depths, watermarks, incidents }
GET  /admin/workflows               ?status=&driver=&instrument=&user=
                                    → [ WorkflowRow ]
GET  /admin/workflows/:id           → WorkflowDetail (shared with /mint/:id, /redeem/:id)

-- Incidents (reconciliation discrepancies)
GET  /admin/incidents               ?severity=&status=→ [ Incident ]
POST /admin/incidents/:id/release   { note } (2-person: supply-level halt only) → 200

-- Compliance: freeze / pause
POST /admin/freeze/address          { address, reason }   → 202 { freeze_request_id }
POST /admin/freeze/contract/pause   { token_id, reason }  → 202 { freeze_request_id }
POST /admin/freeze/force-redeem     { user_id, token_id } → 202 { freeze_request_id }

-- Fee schedules
GET  /admin/fee-schedules                                  → [ FeeSchedule ]
POST /admin/fee-schedules           { kind, tier, flat_fee, pct_bps,
                                      effective_from, effective_to? }  → 201
DELETE /admin/fee-schedules/:id                            → 204

-- KYC review queue
GET  /admin/kyc-queue               ?status=              → [ KycCase ]
POST /admin/kyc/:id/approve         { tier }              → 200
POST /admin/kyc/:id/reject          { reason }            → 200

-- Ledger explorer (scoped by role)
GET  /admin/ledger                  ?user=&from=&to=&type= → [ LedgerEntry ]
```

Gateway is thin: auth, validation, forwarding. No KYC webhook path on core
— `onboarding` handles Onfido webhooks internally; `KycDriver` polls
`onboarding` on its hourly tick.

#### Outbound ports (REST client traits)

Core's outbound ports are **facades** — one port per peer service, not one
port per underlying vendor. This keeps core decoupled from the internal
topology of the services it talks to (multi-chain routing, multi-vendor
screening, multi-provider oracles, etc. — all hidden behind one REST call).

| Port | Peer service | What the service hides behind it |
|------|--------------|----------------------------------|
| `IFiatBroker` | `fiat-broker` | Alpaca USD↔USDC swap |
| `ISecuritiesBroker` | `securities-broker` | Alpaca bond orders, order polling |
| `ISettlement` | `settlement` | Alpaca T+1/T+2 status polling |
| `ICustodian` | `custodian` | Alpaca position lock/unlock; activity feed (`ledger_since`) |
| `IKyc` | `onboarding` | Onfido submit/poll, manual review |
| `IPricing` | `pricing` | `IPriceOracle` (Chainlink / Pyth) + on-chain NAV publish via `IChain` |
| `ITokenization` | `tokenization` | `IWallet` + `IChain` routers (per-`ChainId` dispatch); token freeze/pause |
| `IScreening` | `screening` | `IAddressScreener` (Chainalysis et al.) |
| `IInstrumentCatalog` | `instrument-catalog` | Unified `Instrument` registry + per-venue `VenueInstrumentMap` |
| `ICashBalance` | in-process repo | `CashBalance` read/debit/credit/hold — source of truth for spendable USDC |

Core **does not** depend on `IWallet`, `IChain`, or `IAddressScreener`
directly in its workflow services — those ports live inside the tokenization
and screening services. Core calls `ITokenization` / `IScreening`; the target
service handles the per-chain or per-vendor dispatch internally.

**Phase 1 (current):** `ITokenization` and `IScreening` are satisfied
in-process by `InProcessTokenization` and `InProcessScreening` (wired in
`bootstrap`), which delegate to `ChainRouter` / `WalletRouter` /
`IAddressScreener` internally. Zero REST hops. The contracts are identical to
Phase 2 so replacing the in-process adapters with REST clients in bootstrap
requires **zero changes to core**.

**Intentional exceptions** — the following infrastructure observer services
retain direct `IChain` / `IAddressScreener` access and bypass the facades:

| Service | Direct dependency | Reason |
|---------|-----------------|--------|
| `YieldDistribution` | `IChain` | Calls `nav_accrue` to push NAV to the on-chain `KaleidoscopeNAVFeed` oracle — no matching method on `ITokenization` |
| `DepositWatcher` | `IChain` | Subscribes to raw chain events (log streaming), not a workflow call |
| `BurnWatcher` | `IChain` | Same — raw event subscription |
| `OracleAdminService` | `IChain` | Direct oracle admin calls — admin-plane only |
| `FreezeService` | `IChain` (for `mock_sanction_address` / `mock_unsanction_address` only) | Dev-only escape hatch; production flows use `ITokenization` |

All methods take `request_id` as the first argument. Transport errors are
retryable; `4xx` business errors are terminal.

```rust
// Actual signatures from crates/core/src/ports/

#[async_trait]
trait ITokenization: Send + Sync {
    // Transfer value between wallets (e.g. USDC sweep)
    async fn transfer(&self, r: &RequestId, chain: ChainId,
        from: &WalletRef, to: &WalletAddress, amount: Money) -> CoreResult<TxHash>;
    // Mint bond tokens to a holder address
    async fn mint(&self, r: &RequestId, chain: ChainId,
        contract: &ContractAddress, to: &WalletAddress, qty: Decimal) -> CoreResult<TxHash>;
    // Burn bond tokens from a holder address
    async fn burn(&self, r: &RequestId, chain: ChainId,
        contract: &ContractAddress, from: &WalletAddress, qty: Decimal) -> CoreResult<TxHash>;
    // Poll transaction finality
    async fn finality(&self, chain: ChainId, tx: &TxHash) -> CoreResult<FinalityLevel>;
    // Check USDC balance of a wallet
    async fn wallet_balance(&self, chain: ChainId, w: &WalletRef,
        currency: Currency) -> CoreResult<Decimal>;
    // Deploy a new bond token (UUPS proxy + NAV feed) via TokenFactory
    async fn deploy_token(&self, chain: ChainId,
        p: DeployTokenParams) -> CoreResult<ContractAddress>;
    // Compliance pause/unpause the entire token contract
    async fn pause_token(&self, chain: ChainId,
        contract: &ContractAddress) -> CoreResult<TxHash>;
    async fn unpause_token(&self, chain: ChainId,
        contract: &ContractAddress) -> CoreResult<TxHash>;
    // Freeze / thaw individual holder addresses
    async fn freeze_holder(&self, chain: ChainId, contract: &ContractAddress,
        holder: &WalletAddress) -> CoreResult<TxHash>;
    async fn thaw_holder(&self, chain: ChainId, contract: &ContractAddress,
        holder: &WalletAddress) -> CoreResult<TxHash>;
    // Read-only checks
    async fn is_paused(&self, chain: ChainId,
        contract: &ContractAddress) -> CoreResult<Option<bool>>;
    async fn is_holder_frozen(&self, chain: ChainId, contract: &ContractAddress,
        holder: &WalletAddress) -> CoreResult<bool>;
    async fn total_supply(&self, chain: ChainId,
        contract: &ContractAddress) -> CoreResult<Decimal>;
}

#[async_trait]
trait IScreening: Send + Sync {
    async fn screen_address(&self, chain: ChainId,
        address: &WalletAddress) -> CoreResult<AddressRiskReport>;
    async fn screen_tx(&self, tx: &ChainTxRef) -> CoreResult<AddressRiskReport>;
}
```

Each facade has a matching adapter crate (`adapter-rest-fiat-broker`,
`adapter-rest-tokenization`, `adapter-rest-screening`, …) holding the
`reqwest` client. The target service's inbound HTTP layer translates the
call onto its internal port(s).

#### Utility ports (in-process, not REST)

- `Clock` — every service takes `Arc<dyn Clock>` instead of calling
  `Utc::now()`. Rationale:
  - **Determinism** — driver ticks branch on `next_retry_at <= now()`, fee
    schedules on `effective_from/to`, KYC tier grants on approval time.
    Tests inject `FakeClock::set_now(…)` and advance time explicitly.
  - **Replay** — a persisted workflow can be re-driven against a historical
    clock to reproduce a production bug exactly.
  - **Single audit point** — one place to swap in NTP-validated time if a
    node's wall clock drifts.

---

### Onboarding

```
KycCase:
  NOT_STARTED ──▶ SUBMITTED ──▶ UNDER_REVIEW ──▶ APPROVED { tier }
                                            └──▶ REJECTED { reason }
```

`NOT_STARTED` is the initial state when a user is provisioned but has not yet
uploaded documents; the gateway flips it to `SUBMITTED` on the first `POST
/kyc`. `APPROVED` provisions custodian account + wallet in the same
transaction. `tier` is set by the provider at approval time; `issuance`
snapshots `mint_limit` from it when a `MintRequest` row is created.

---

### Deposit detection (balance-first model)

The platform uses a **balance-first** model (design decision: Option B). On-chain
USDC deposits credit a platform-held `CashBalance`; mints then debit that balance
synchronously. This severs the direct `deposit → MintRequest` link in favour of
a two-step `deposit → CashBalance credit` then `user action → MintRequest`.

**Single-wallet model (GYL-230):** there is one `platform_custodian_address`
per chain (the platform's signing key address). All users send USDC to this
single address. Ownership of a deposit is determined by `Transfer.from` —
the sender's address — matched against per-user `source_addresses`.

| Concept | Owner | Purpose |
|---------|-------|---------|
| `platform_custodian_address` | Platform (`PrivkeyWallet`) | Single chain address that receives all user USDC deposits. Configured via `PLATFORM_CUSTODIAN_ADDRESS` env var. |
| `User.source_addresses[]` | User | Wallet addresses the user sends USDC from. Registered post-KYC. `deposit-watcher` matches `Transfer.from` against this set. |
| `User.token_recipient_address` | User | Address where minted tokens are delivered. Set when the user registers their chain wallet post-KYC. |
| `User.custodian_deposit_address` | Alpaca | Alpaca's on-chain address for this user's brokerage sub-account. USDC swept here causes Alpaca to credit the sub-account. |

`deposit-watcher` runs one subscriber per supported chain via `IChain`:

```
IChain.events_since(USDC_CONTRACT, "Transfer", cursor)
  │
  ▼
for each Transfer(from, to, amount, tx_hash, log_index):
    if to != platform_custodian_address:
        skip                                        # not our address
    user_id = UserRepo.find_user_by_source_address(from)
    if user_id is None:
        warn("unregistered source address") and skip
    if DepositRequestRepo.by_deposit(tx_hash, log_index) exists:
        skip                                        # idempotency dedup
    INSERT INTO deposit_requests (
        user_id,
        chain     = chain,
        tx_hash   = tx_hash,            -- UNIQUE (dedup on tx_hash + log_index)
        log_index = log_index,
        amount    = amount,
        status    = CONFIRMING,
        ...
    ) ON CONFLICT (tx_hash, log_index) DO NOTHING
```

`DepositDriver` (tick: 5 s) advances `CONFIRMING` rows once `min_confirmations`
(default 12) are observed, then atomically:
1. Appends `LedgerEntry::FiatDeposit` with `external_ref = "chain:DEPOSIT:{tx_hash}:{log_index}"`.
2. Credits `CashBalance.available` for the `(user, chain, USDC)` pair.
3. Transitions `DepositRequest → CREDITED`.

The unique constraint on `(tx_hash, log_index)` is the idempotency boundary:
reorg replays, subscriber restarts, and duplicate event deliveries all collapse
to one row.

**Block-cursor persistence (GYL-134):** the event cursor is persisted in
`WatermarkRepo` under the key `"deposit_watcher_eth"` so progress survives
restarts without re-scanning from genesis. The constant
`DEPOSIT_WATCHER_DRIVER_NAME` (exported from `core::services`) names this key.

**Reorg safety (GYL-134):** each tick fetches the chain head via
`IChain::head_block()` and computes `safe_block = head - min_confirmations`
(default 12). Events in blocks newer than `safe_block` are skipped. The
watermark is unconditionally advanced to `safe_block` at the end of every
tick, even if all events in the window were skipped — this ensures forward
progress during quiet periods.

**`mint_hints` are obsolete under the balance-first model.** `POST /mint` now
creates a `MintRequest` synchronously by debiting `CashBalance` (hold until
fill), so UI breadcrumbs are no longer needed. The `mint_hints` table and
`MintHintGcDriver` are deprecated and will be removed once all clients migrate
to the balance-first `POST /mint` contract.

---

### Issuance (Cash Balance → Bond Token)

The issuance workflow has two entry paths, selected by `MintFundingSource`:

- **`UsdcDeposit`** (default) — user's `CashBalance` is debited (hold) when
  `POST /mint` is called. `MintDriver` sweeps the USDC on-chain to Alpaca
  before placing the buy order.
- **`BrokerCash`** — user has existing USD in their Alpaca brokerage account.
  `POST /invest` is called with an `Idempotency-Key`; `MintDriver` skips the
  USDC deposit states and enters directly at `AWAITING_ORDER_FILL`.

```
MintRequest (UsdcDeposit path):
  ACCEPTED
    → SCREENING_ENTRY            screen wallet (screening)
    → AWAITING_FUNDING           sweep platform_custodian_address → custodian_deposit_address  (tokenization)
    → AWAITING_SWAP              USDC→USD swap placed { swap_ref }    (fiat-broker)
    → AWAITING_SWAP_SETTLEMENT   swap filled, USD settling             (settlement)
    → AWAITING_ORDER_FILL        USD→BOND order placed { order_id }   (securities-broker)
    → AWAITING_ORDER_SETTLEMENT  order filled, bond settling T+1/T+2  (settlement)
    → SCREENING_PRE_MINT         screen wallet again                   (screening)
    → AWAITING_POSITION_LOCK     lock position at custodian            (custodian)
    → AWAITING_MINT              on-chain mint                         (tokenization)
    → MINTED

MintRequest (BrokerCash path — enters at AWAITING_ORDER_FILL):
  ACCEPTED
    → AWAITING_ORDER_FILL        USD→BOND order placed { order_id }   (securities-broker)
    → AWAITING_ORDER_SETTLEMENT  order filled, bond settling T+1/T+2  (settlement)
    → SCREENING_PRE_MINT         screen wallet                         (screening)
    → AWAITING_POSITION_LOCK     lock position at custodian            (custodian)
    → AWAITING_MINT              on-chain mint                         (tokenization)
    → MINTED

  terminals: BLOCKED { reason }, FAILED { reason, step }

Order (buy side):
  PENDING → PLACED { broker_order_id } → FILLED { fill_price, fill_qty } → SETTLED
                                     └─▶ CANCELLED
                                     └─▶ REJECTED { reason }
```

#### AWAITING_FUNDING — USDC sweep to Alpaca (UsdcDeposit path only)

Before deposited USDC can be swapped for USD via Alpaca, the platform must
move it from `platform_custodian_address` to the user's
`custodian_deposit_address` — the Alpaca-controlled on-chain address that,
when funded, credits the user's brokerage sub-account.

The sweep — `IWallet::transfer(platform_custodian_address → user.custodian_deposit_address)`
— is the `AWAITING_FUNDING` state. Implemented in GYL-237; wired via
`DEV_CUSTODIAN_DEPOSIT_ADDRESS` in local dev (Anvil account[2] stands in for
the real Alpaca Crypto Wallet address).

For `BrokerCash` mints there is no sweep — the broker cash is already in the
brokerage sub-account.

`mint_limit` is snapshotted from `user.kyc_tier` at `ACCEPTED` time.
Checked before `AWAITING_POSITION_LOCK` — exceeding it transitions to `FAILED`.

#### Fee accounting by funding source

For `UsdcDeposit`: fee `LedgerEntry` is emitted at `AWAITING_SWAP_SETTLEMENT`
(the USDC→USD swap step).
For `BrokerCash`: fee `LedgerEntry` is emitted at `AWAITING_ORDER_FILL`
(the first moment USD leaves the investor's broker account). `effective_invest
= usd_amount − fee`; order quantity is derived from `effective_invest`.

`step_awaiting_mint` and `step_screening_pre_mint` resolve the chain via
`token.chain` (not `deposit_chain`, which is `None` for BrokerCash).

---

### Redemption (Bond Token → Cash Balance)

Redemption is **token-first**: the user must transfer their bond tokens to the
platform’s address before the sell order is placed. The platform holds those
tokens throughout the workflow and burns them at `AWAITING_BURN`.

```
RedemptionRequest:
  ACCEPTED
    → AWAITING_TOKEN_DEPOSIT     wait for user to transfer bond tokens to platform address  (tokenization / deposit-watcher)
    → SCREENING                  screen sender wallet                  (screening)
    → AWAITING_ORDER_FILL        BOND→USD order placed { order_id }   (securities-broker)
    → AWAITING_ORDER_SETTLEMENT  order filled, bond settling T+1/T+2  (settlement)
    → SCREENING_PRE_TRANSFER     screen wallet again                   (screening)
    → AWAITING_SWAP              USD→USDC swap placed { swap_ref }    (fiat-broker)
    → AWAITING_SWAP_SETTLEMENT   swap filled, USDC settling            (settlement)
    → AWAITING_POSITION_UNLOCK   unlock position at custodian          (custodian)
    → AWAITING_BURN              burn token on-chain (platform holds tokens)  (tokenization)
    → CREDITING_CASH_BALANCE     credit CashBalance.available          (in-process)
    → COMPLETED

  terminals: BLOCKED { reason }, FAILED { reason, step }

Order (sell side): same states as buy-side Order above.
```

**Token-deposit gate:** `AWAITING_TOKEN_DEPOSIT` polls via `IChain` for a
bond token `Transfer` event to the platform’s address matching the
`(user, token, qty)` tuple from the `RedemptionRequest`. The same
`(tx_hash, log_index)` dedup used by `DepositRequest` prevents double-credit
on reorgs or restarts.

**Balance-first terminal step:** `CREDITING_CASH_BALANCE` credits
`CashBalance.available` for the `(user, chain, USDC)` pair and appends a
`LedgerEntry::FiatDeposit`. No on-chain USDC transfer occurs at redemption
time. Users move funds out via `POST /withdraw` (a separate `WithdrawRequest`
workflow) when they choose to.

### Pricing

Computes NAV per token and publishes it on-chain to a `KaleidoscopeNAVFeed`
contract for use as Morpho Blue collateral price feed.

```
publish(cusip)
  1. IPriceOracle.price(cusip) → bond price (USD)
  2. TokenRepo → tokens outstanding
  3. PositionRepo → bonds held
  4. NAV per token = (bonds_held × bond_price) / tokens_outstanding
  5. IChain.call(KaleidoscopeNAVFeed.updateAnswer, int256 × 1e8)
```

### YieldDistribution

**Implementation model: pool / accrual-index** (GYL-289).

Each coupon credited by the broker increments a per-instrument cash pool and
updates a running index (`pool_cash / outstanding_supply`). Holders redeem
their share of the pool at any time based on how much the index has moved
between their entry and exit — no per-holder payment transactions are emitted.

```
run_once(since) — called every 5 min by YieldDriver:
  1. Poll coupons_since(watermark) from ISecuritiesBroker
  2. For each coupon:
     a. Idempotency guard: skip if LedgerRepo already has external_ref
        "yield:INDEX:COUPON:<ext_id>"
     b. Read current pool_state (pool_cash, index) from LedgerRepo
     c. Compute pool_after = pool_cash + coupon.amount
        index_after  = pool_after / total_supply
     d. Append LedgerEntry::IndexCredited { amount, pool_after, index_after }
```

No per-holder transfer occurs at distribution time. `LedgerRepo::pool_state`
reads all `IndexCredited` entries for an instrument and returns the latest
`index_after`, which is the authoritative redemption multiplier.

> **Note:** Earlier design docs described a per-holder FSM
> (`SNAPSHOTTING → SCREENING_HOLDERS → AWAITING_PAYOUT → DISTRIBUTED`)
> with pro-rata USDC transfers to each holder. That model was superseded by
> the accrual-index approach (GYL-289) before implementation. The FSM and
> `YieldEvent` entity do **not** exist in the current codebase.

`YieldDistribution` also calls `nav_accrue` to push an updated NAV-per-token
to the on-chain `KaleidoscopeNAVFeed` oracle, keeping the price feed current
for secondary market pricing. This requires direct access to `IChain` and is
one of the intentional exceptions to the `ITokenization` facade rule (it calls
a chain method that has no place on the tokenization surface).

### Reconciliation

Runs as a separate `reconciliation` service with **four independent levels**.
Each level has its own cadence, source of truth, and discrepancy handler;
each emits structured alerts when internal state diverges from the external
source. Levels are independent — a transaction-level reconcile does not block
a supply-level reconcile, and one level failing does not stop the others.

| Level | Cadence | Source of truth | Compares | On discrepancy |
|-------|---------|-----------------|----------|----------------|
| **Transaction** | Continuous (watermarked polling, 1 min tick) | Broker event stream (fills, coupons, maturities, dividends) | Broker events vs. `LedgerRepo` entries keyed by `external_ref` (e.g. `"alpaca:FILL:<id>"`) | Backfill missing entries; idempotent on `external_ref`. No alert for ordinary catch-up. |
| **Activity feed** | Every 30 s (`LedgerReplicationDriver`) | Custodian activity feed (`ICustodian::ledger_since`) | Activity types not covered by Transaction level (fees, interest, dividends, journals, corporate actions, cash transfers) vs. `LedgerRepo` entries keyed by `external_ref = "alpaca:activity:<id>"` | Mirror missing entries; skip FILL/PTC/CIL/CSD/CSW (already covered by Transaction level). Idempotent on `external_ref`. |
| **Position** | Hourly | `ICustodian` position snapshot | Custodian qty per `InstrumentId` vs. `PositionRepo` | Open an `Incident` row; halt new mints for the affected instrument; page on-call. |
| **Supply** | Every finalized block, per chain | On-chain `IChain.total_supply` + `PositionRepo` | `bonds_held × face_value` ≥ `tokens_outstanding × unit_face` (soft-equals within rounding tolerance) | **Hard-halt** mint/redeem globally; page on-call; require manual release by compliance. |

Per level:
- Watermarks (`last_reconciled_event_id`, `last_reconciled_block`, …) are
  persisted so restarts don't re-scan history.
- Idempotent on re-run — same watermark range produces no duplicate ledger
  entries and no duplicate `Incident` rows (dedup on `incident_key`).
- Alert routing is configurable per level — transaction-level writes to logs,
  position-level pages the data-ops rotation, supply-level pages both
  platform-eng and compliance.

### Freeze (Compliance)

Implemented as an **internal module inside the `tokenization` service** — not
a separate service. Rationale: the action set is narrow (pause contract,
freeze holder, force-redeem) and reuses `tokenization`'s existing
`IChain` + `WalletRouter` + `IAddressScreener` wiring. Operator-scoped
authorization is enforced at the gateway, not by process isolation.

Flow (driven by `FreezeDriver` inside `tokenization`):

1. Screen target address via `IAddressScreener` (for holder freezes).
2. Append `LedgerEntry::FreezeRequested` to `LedgerRepo` with a stable
   `external_ref` — ledger-first, chain-second.
3. `IChain.call(pause | freezeAddress | forceRedeem, …)`.
4. On tx confirmation, append `LedgerEntry::FreezeConfirmed`.

If compliance later requires hard process isolation (separate access control,
independent audit), the module extracts into its own `freeze` service without
core-surface changes — `tokenization`'s inbound `ITokenization` facade simply
drops the freeze methods and a new `IFreeze` facade appears.

### Portfolio

Aggregates fiat balance (via `ICustodian`), positions (via `PositionRepo`),
and token holdings (via `TokenRepo`) into a unified `PortfolioView` with
oracle-priced NAV.
### Withdraw

`WithdrawRequest` is the mechanism for moving USDC out of the platform
`CashBalance` to an external wallet. It is always initiated explicitly by
the investor — redemption no longer triggers an automatic transfer.

```
WithdrawRequest:
  ACCEPTED         { destination_address, amount, fee }
    → SCREENING    screen destination_address              (screening)
    → AWAITING_TRANSFER  IWallet::transfer(platform → destination)  (tokenization)
    → COMPLETED

  terminals: BLOCKED { reason }, FAILED { reason, step }
```

`WithdrawDriver` (tick: 5 s) advances each request. Screening runs
`IAddressScreener` on `destination_address`; a `Block` decision immediately
transitions to `BLOCKED` and appends a ledger entry.

The `AWAITING_TRANSFER` step uses the five-point crash-safe pattern:
RequestId derived as `"{withdraw_id}:transfer"`, ledger appended before
status advance.

**Approval policy:** `POST /withdraw` checks `ApprovalPolicy` for the
`(org, Withdraw, amount)` combination. If `required_approvers > 0` an
`ApprovalRequest` row is created and the workflow pauses at `ACCEPTED`
until the policy is satisfied.

---

### Approval

Multi-party approval for money actions above org-configured thresholds.

```
ApprovalRequest:
  PENDING       { action_type, workflow_id, required_approvers }
    → APPROVED  (all required approvals collected)
    → REJECTED  (any approver rejects — halts the target workflow)
```

**Invariants:**
- The user who initiated the action (`initiated_by`) cannot also be an
  approver — enforced at the gateway before an approval is recorded.
- Each approval or rejection appends a `LedgerEntry::ApprovalGranted` /
  `ApprovalRejected` with an optional `note` / mandatory `reason` field.
- Rejection immediately transitions the target workflow to `FAILED`.

`ApprovalPolicy` rows (per org × action × amount threshold) are managed
by Super Admin via `POST /admin/fee-schedules` equivalents. The gateway
checks `ApprovalPolicy` at the point of action creation and sets
`requires_approval` on the response so the UI can prime the CTA.

---

### InstrumentCatalog

Two-level mapping so the platform owns a single, venue-independent view of
every tradable security.

- **`InstrumentRepo`** — unified `Instrument` records keyed by `InstrumentId`.
  Deduplicated on `Cusip` / `Isin`; a new venue contributing the same CUSIP
  reuses the existing `InstrumentId` rather than creating a parallel record.
- **`VenueInstrumentMap`** — per-venue `(venue, venue_symbol) → InstrumentId`.
  Each venue sync job upserts its own rows; the unified `Instrument` is created
  once and shared across venues.

Resolution paths:

- `Cusip → InstrumentId → [(venue, venue_symbol)]` — used by `securities-broker`
  when routing an order for a given bond across the set of venues that list it.
- `(venue, venue_symbol) → InstrumentId → Cusip` — used by `deposit-watcher`,
  `reconciliation`, and `fills` ingestion to translate venue-native identifiers
  back into unified records.

Sync jobs run per venue on a configurable cadence (daily by default). New
venues plug in by implementing `IInstrumentSource` (venue-side) and registering
with the catalog's sync scheduler; the unified `Instrument` table is untouched
by vendor-specific fields.

**ETF CUSIP resolution (OpenYield):** Alpaca classifies ETFs under
`asset_class: "us_equity"` and does not return a CUSIP for them. GYL-257
introduces `OpenYieldInstrumentSource` (`crates/adapter-openyield`) which
provides real 9-character CUSIPs for bond ETFs and other fixed-income
instruments. The sync driver runs OpenYield **before** Alpaca so that by the
time Alpaca ETF rows are processed, the catalog already holds the correct
`InstrumentId` keyed by CUSIP. The instruments HTTP handler and buy page both
perform CUSIP-only token lookup — instruments without a CUSIP are ineligible
for tokenization. Wire `OPENYIELD_EMAIL` + `OPENYIELD_PASSWORD` to enable; see CLAUDE.md env vars.


---

## Console plane — operations screens

The **Console** app (`Invest`'s peer app, operator-facing) requires a set of
backend query and action surfaces that are entirely separate from the
investor-facing API. All console routes are protected by an operator role claim
in the Keycloak JWT.

### Role-to-route mapping

| Role | Nav areas | Key permissions |
|------|-----------|----------------|
| **Super Admin** | Everything + Fees · Roles · Org Policies | Create/delete fee schedules; manage org policies |
| **Compliance Officer** | Overview · Incidents · Freeze/Pause · Screening · KYC Review · Ledger · Users | Initiate freeze/pause/force-redeem; approve supply-halt releases (2-person) |
| **Ops Engineer** | Overview · Workflows · Reconciliation · Instruments · Users · Ledger | View + retry workflows; view incidents; browse ledger |
| **KYC Reviewer** | KYC Queue · Users (scoped) | Approve/reject KYC cases; set tier |

### Screen-to-endpoint mapping

| Screen | Purpose | Endpoints |
|--------|---------|-----------|
| **Overview** | System health: driver tick status, watermarks, queue depths, live incident banner | `GET /admin/health` |
| **Workflows** | Row per workflow (mint/redeem/deposit/withdraw/kyc/yield). Filter by state/driver/instrument/user. Each row → Workflow detail (shared component with Invest's position lifecycle). | `GET /admin/workflows`, `GET /admin/workflows/:id` |
| **Incidents** | Reconciliation discrepancies, severity-ranked. Supply-level = red banner, 2-person approval to release. Transaction-level = calm info. | `GET /admin/incidents`, `POST /admin/incidents/:id/release` |
| **Freeze/Pause** | Confirm-by-typing UX. Shows ledger write preview + chain call before execution. Appends `FreezeRequested` to ledger before the chain call. | `POST /admin/freeze/address`, `POST /admin/freeze/contract/pause`, `POST /admin/freeze/force-redeem` |
| **Fee editor** | Timeline visualizer of existing `(kind, tier)` schedules. Editor prevents overlap client-side (DB exclusion constraint is the backstop). | `GET/POST/DELETE /admin/fee-schedules` |
| **KYC review queue** | Document-by-document review with tier assignment. | `GET /admin/kyc-queue`, `POST /admin/kyc/:id/approve`, `POST /admin/kyc/:id/reject` |
| **Ledger explorer** | Unified journal scoped by role. Full-text filter on `external_ref`, date range, user, entry type. Export CSV. | `GET /admin/ledger` |

### Workflow detail (shared component)

The workflow detail page (showing the step timeline, external refs, fee
breakdown, and failure info) is a **shared component** between the Invest app
(position detail / mint/redeem status) and the Console Workflows screen. Both
apps call `GET /mint/:id` / `GET /redeem/:id` / `GET /deposit/:id` /
`GET /withdraw/:id`; the same `WorkflowDetail` response shape drives both UIs.


---

## Multi-chain dispatch

Services that touch tokens receive `Arc<WalletRouter>` and `Arc<ChainRouter>`
rather than a single wallet or chain adapter. Each router holds a
`HashMap<ChainId, Arc<dyn Trait>>` and the service selects by `ChainId` at
call time.

```rust
// In Minting / Redemption:
let chain  = self.chains.for_chain(token.chain)?;   // ChainRouter → IChain
let wallet = self.wallets.for_chain(token.chain)?;  // WalletRouter → IWallet
```

Registering a new chain = adding one `IWallet` adapter + one `IChain` adapter
to the services that hold a router (`tokenization`, `pricing`,
`deposit-watcher`, `reconciliation`). Core is untouched.

---

## Persistence

Persistence is cross-cutting — not owned by any single plane.

| Repo | Source of truth | Hot cache |
|------|----------------|-----------|
| `UserRepo` | Postgres | — |
| `OrgRepo` | Postgres | — |
| `OrgMembershipRepo` | Postgres | — |
| `ApprovalPolicyRepo` | Postgres | — |
| `ApprovalRequestRepo` | Postgres | — |
| `CashBalanceRepo` | Postgres | — |
| `DepositRequestRepo` | Postgres | — |
| `WithdrawRequestRepo` | Postgres | — |
| `TaxLotRepo` | Postgres | — |
| `OrderRepo` | Postgres | — |
| `PositionRepo` | Postgres | — |
| `TokenRepo` | Postgres | — |
| `LedgerRepo` | Postgres | — |
| `KycCaseRepo` | Postgres | — |
| `AssetRepo` | Postgres | — |
| `WatermarkRepo` | Postgres | — |
| `InstrumentRepo` | Postgres | Redis (10-min TTL via `CachedInstrumentRepo`) |

`LedgerRepo::append` is contracted idempotent on `external_ref`. Every
external event (broker fill, custodian entry, chain tx) must be mirrored here
so the internal ledger remains continuous across broker or custodian swaps.

---

## Observability — distributed tracing

Every inbound user request is assigned a **trace ID at the gateway** and
propagated through every downstream hop — core's workflow drivers, each
adapter service, database calls, chain RPC calls — so one request can be
followed end-to-end across process boundaries with per-span timings.

### Wire format

**W3C Trace Context** (`traceparent` / `tracestate` headers) on every REST
call between services. The gateway generates a new `traceparent` on requests
that arrive without one; services that receive a `traceparent` extract the
trace/span IDs and attach child spans to the same trace.

```
traceparent: 00-<trace_id:32hex>-<parent_span_id:16hex>-<flags:2hex>
```

### Stack

The `tracing` crate (already a workspace dep) remains the instrumentation
API — services emit spans and events via `#[tracing::instrument]` and
`tracing::info!` as today. In each service `main.rs`, the subscriber is
extended with **`tracing-opentelemetry`**, which bridges `tracing` spans to
the **OpenTelemetry SDK**. The SDK exports batched spans over **OTLP** to a
local **OTel Collector**, which fans out to the chosen backend (Tempo /
Honeycomb / Datadog — backend choice is a collector config, not a code
change).

```
#[instrument] spans ─▶ tracing-opentelemetry ─▶ opentelemetry_sdk ─▶ OTLP ─▶ collector ─▶ backend
```

Core stays dependency-pure: it calls only the `tracing` macros. The OTel
SDK lives in the service binary (`crates/bins/<service>/main.rs`) alongside
the rest of the wiring.

### What is instrumented

| Layer | Span name | Attributes |
|-------|-----------|------------|
| Inbound HTTP | `http.server.{method} {route}` (via `tower-http::trace` + OTel extractor) | `http.status_code`, `http.route`, `user.id` (post-auth) |
| Outbound HTTP (core → adapter services) | `http.client.{method} {path}` | `peer.service`, `request_id`, `workflow_id` |
| Workflow driver tick | `driver.{mint\|redemption\|kyc\|yield}.tick` | `batch_size`, `advanced_count`, `failed_count` |
| Workflow state transition | `workflow.{mint\|redemption}.{from}→{to}` | `workflow_id`, `request_id`, `attempt_count` |
| DB query (sqlx) | `db.query {table}` | `db.statement` (redacted), `db.rows_affected` |
| Chain RPC call (`IChain`) | `chain.{evm\|sol}.{op}` | `chain_id`, `tx_hash` (on mined), `block_number` |
| External vendor call | `vendor.{alpaca\|onfido\|chainalysis}.{op}` | `vendor.request_id`, `vendor.status_code` |

### `trace_id` vs. `request_id`

These are distinct and both persist:

| Field | Scope | Purpose | Persisted? |
|-------|-------|---------|-----------|
| `trace_id` | One user request (HTTP call or driver tick) | Distributed tracing / latency observability | No — ephemeral, lives in collector |
| `request_id` | One workflow step (`"{workflow_id}:{state_name}"`) | Idempotency key for adapter REST calls | Yes — written to each adapter's audit table |

Workflow-driver ticks create a fresh root `trace_id` per `(workflow, step)`
attempt and attach it as a span attribute alongside `request_id`. This
means: a user's original `POST /redeem` trace covers only the synchronous
acceptance hop; each subsequent async step (swap, settlement poll, mint,
etc.) appears as its own trace, correlated by `workflow_id` and
`request_id` attributes — you query by `workflow_id` to see the full
lifecycle across all traces.

### Sampling

- Error paths — **always sampled** (tail-based sampling at the collector
  matches `status_code != ok` and `error` events).
- Happy path — **ratio-sampled** at 1% in production, 100% in staging and
  local dev.
- Slow requests — **always sampled** when latency exceeds a per-operation
  threshold (also a collector-side rule).

### Local dev

`OTEL_EXPORTER_OTLP_ENDPOINT` unset → spans log to stdout via
`tracing-subscriber::fmt` only (unchanged from today). Set the endpoint
to `http://localhost:4317` to ship traces to a local collector + Jaeger
UI spun up via `docker-compose`.

---

## Crate map

```
kaleidoscope/
├── crates/
│   ├── core/                          # Domain + port traits + service logic (zero external deps)
│   ├── inbound-http/                  # Axum HTTP handlers → AppState → services
│   ├── bootstrap/                     # Phase 1 DI root — wires all adapters into a single process
│   │
│   ├── bins/                          # Deployable binaries (Phase 1: two; Phase 2: one per service)
│   │   ├── gateway/                   # Main binary: HTTP + all services in-process
│   │   └── instrument-catalog/        # Externalized catalog service (REST, runs separately)
│   │
│   ├── adapter-rest-instrument-catalog/ # REST-client IInstrumentCatalog (Phase 2 pattern example)
│   │
│   ├── adapter-alpaca/                # Consolidated Alpaca client (shared by Alpaca-backed services)
│   ├── adapter-alpaca-common/         # Shared HTTP client / token cache
│   ├── adapter-alpaca-custodian/      # ICustodian impl
│   ├── adapter-alpaca-fiat/           # IFiatBroker impl
│   ├── adapter-alpaca-securities/     # ISecuritiesBroker + IInstrumentSource impl
│   ├── adapter-alpaca-settlement/     # ISettlement impl
│   │
│   ├── adapter-openyield/             # IInstrumentSource impl — OpenYield bond ETF CUSIPs
│   │
│   ├── adapter-chain-evm/             # IChain impl for EVM chains
│   ├── adapter-wallet-evm/            # IWallet impl — generic EVM
│   ├── adapter-wallet-fordefi/        # IWallet impl — Fordefi MPC
│   ├── adapter-wallet-privkey/        # IWallet impl — raw privkey (dev / Hoodi only)
│   ├── adapter-wallet-sol/            # IWallet impl — Solana
│   │
│   ├── adapter-oracle-chainlink/      # IPriceOracle impl — Chainlink
│   ├── adapter-oracle-pyth/           # IPriceOracle impl — Pyth
│   ├── adapter-sanctions-chainalysis/ # IAddressScreener impl — Chainalysis
│   │
│   ├── adapter-kyc-onfido/            # IKyc impl — Onfido
│   ├── adapter-kyc-manual/            # IKyc impl — manual review
│   │
│   ├── adapter-persist-postgres/      # All *Repo impls (sqlx + migrations)
│   ├── adapter-persist-redis/         # CachedInstrumentRepo (Redis hot cache)
│   │
│   ├── test-fakes/                    # In-memory impls of every port (no I/O)
│   ├── test-contracts/                # Port contract suites (trait drift detection)
│   ├── bdd/                           # Cucumber scenarios by business journey
│   └── e2e/                           # Golden path cross-plane tests
└── xtask/                             # fmt → clippy → test validation runner
```

---

## Dependency rules

1. `core` → no adapter crates. Zero.
2. `adapter-*` → `core` (implements port traits).
3. `bootstrap` → any adapter it wires. No other crate links adapters (only
   `bootstrap` does DI). Phase 2 per-service binaries will each have their
   own `bootstrap`-equivalent that wires only the adapters they own.
4. `inbound-http` → `core` only (receives `Arc<dyn Service>` via `AppState`).
5. `test-fakes` → `core` only; used by unit, contract, BDD, and integration
   tests.

---

## Load-bearing invariants

These must hold across all service implementations:

| # | Rule |
|---|------|
| 1 | No adapter types leak through ports. `ISecuritiesBroker` never exposes `alpaca::Order`. |
| 2 | `LedgerRepo` is source of truth for regulatory reporting. Every external event is mirrored with a stable `external_ref`. |
| 3 | Tokens are minted **only after** `ISettlement::status == Settled`. No minting during the T+1/T+2 window. |
| 4 | Every outbound wallet transfer (including mint destination) is screened via `IAddressScreener`. `Block` halts the flow. |
| 5 | Services return `CoreError`. Adapters translate technical errors at the boundary — `reqwest`/`sqlx`/`solana_client` errors never reach core. |
| 6 | Redemption executes in **strict order**: `receive token deposit → sell → await bond settlement → swap → await swap settlement → unlock position → burn → credit CashBalance`. No step advances until the prior step’s external confirmation is received. The user must transfer bond tokens to the platform before any sell order is placed; burning before token receipt, or before any of sell / settle / swap / unlock, is a compliance violation. |

---

## Key data flows

### Issuance (user mints from cash balance, receives bond token)

```
-- UsdcDeposit path:
deposit-watcher →  core.DepositDriver  →  CashBalance.credit
User: POST /mint   →  core.MintDriver
           │
           ├─ ICashBalance      (hold amount against CashBalance)
           ├─ IScreening        (screen wallet)
           ├─ ITokenization     (sweep platform_custodian_address → custodian_deposit_address)  ← GYL-237
           ├─ IFiatBroker       (USDC → USD)
           ├─ ISettlement       (await swap Settled)
           ├─ ISecuritiesBroker (buy bond)
           ├─ ISettlement       (await bond Settled)
           ├─ IScreening        (screen wallet again)
           ├─ ICustodian        (lock position)
           └─ ITokenization     (mint token → user wallet)

-- BrokerCash path:
User: POST /invest  →  core.MintDriver  (enters at AWAITING_ORDER_FILL)
           │
           ├─ ISecuritiesBroker (buy bond — qty from usd_amount − fee)
           ├─ ISettlement       (await bond Settled)
           ├─ IScreening        (screen wallet)
           ├─ ICustodian        (lock position)
           └─ ITokenization     (mint token → user wallet)
```

### Redemption (user deposits token, USDC credited to cash balance)

```
User  →  POST /redeem  →  core.RedemptionDriver
           │
           ├─ [await] IChain   (detect bond token Transfer to platform address)
           ├─ IScreening        (screen sender wallet)
           ├─ ISecuritiesBroker (sell bond)
           ├─ ISettlement       (await bond Settled)
           ├─ IScreening        (screen wallet again)
           ├─ IFiatBroker       (USD → USDC)
           ├─ ISettlement       (await swap Settled)
           ├─ ICustodian        (unlock position)
           ├─ ITokenization     (burn token on-chain — platform holds tokens)
           └─ ICashBalance      (credit CashBalance.available)

-- User withdraws USDC separately:
User  →  POST /withdraw  →  core.WithdrawDriver
           │
           ├─ IScreening       (screen destination address)
           └─ ITokenization    (transfer USDC → external wallet)
```

### NAV pricing (background job)

```
Scheduler  →  Pricing.publish(cusip)
               │
               ├─ IPriceOracle (bond price)
               ├─ TokenRepo (tokens outstanding)
               ├─ PositionRepo (bonds held)
               └─ IChain (updateAnswer → KaleidoscopeNAVFeed)
                           │
                      Morpho Blue reads this feed for collateral pricing
```

---

## Environment

Each service binary reads its own subset of these. Variables unused by a given
service are ignored.

| Variable | Effect | Read by |
|----------|--------|---------|
| `KALEIDOSCOPE_ADDR` | HTTP bind address (default `0.0.0.0:8080`) | Every service |
| `RUST_LOG` | Tracing filter | Every service |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP collector URL (e.g. `http://localhost:4317`). Unset → spans log to stdout only | Every service |
| `OTEL_SERVICE_NAME` | Service name attribute on emitted spans (defaults to the binary name) | Every service |
| `OTEL_TRACES_SAMPLER` / `OTEL_TRACES_SAMPLER_ARG` | Head-sampling policy (`parentbased_traceidratio` + ratio) | Every service |
| `DATABASE_URL` | Postgres URL; `sqlx::migrate!` runs on boot | Every service that persists state |
| `REDIS_URL` | Redis URL; `InstrumentRepo` wrapped in `CachedInstrumentRepo` (10-min TTL) | `instrument-catalog` |
| `ALPACA_*` | Alpaca API credentials (key, secret, environment) | `fiat-broker`, `securities-broker`, `settlement`, `custodian`, `instrument-catalog` |
| `ONFIDO_*` | Onfido API credentials + webhook secret | `onboarding` |
| `CHAINALYSIS_API_KEY` | Chainalysis API key | `screening` |
| `CHAINLINK_*` / `PYTH_*` | Oracle provider credentials | `pricing` |
| `ETH_RPC_URL`, `SOL_RPC_URL` | Chain RPC endpoints (one per supported chain) | `tokenization`, `pricing`, `deposit-watcher`, `reconciliation` |
| `FORDEFI_*` / `PRIVKEY_SIGNING_KEY` | Wallet provider credentials (MPC in prod; raw key only for Hoodi / dev) | `tokenization` |
