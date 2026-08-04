# Atomic Swap — Formalisation, Testnet & Third-Party Integration Roadmap

**Created:** 2026-07-30
**Baseline:** `main` @ `3507f1b`, clean tree, **427 forge tests passing** (398 before this pass)
**Scope:** get the self-custodial `GyldAtomicSwap` from "green locally" to "a third party integrates against it on a public network".

> Every claim in §0 and §2 was verified against contract source or `broadcast/` JSON on 2026-07-30, at commit `3507f1b`. Any review that disagrees should start with `git fetch --all --prune` and state its commit.

---

## 0. Verified state

### Architecture (do not describe it any other way)

`GyldAtomicSwap` is **self-custodial**. `GyldSettlementVault.sol`, `GyldDvpEscrow.sol` and `DeployDvpEscrow.s.sol` were deleted in GYL-548 (`5c1a1f4`). The contract holds its own inventory: `executeSwap` pulls `tokenIn` from the taker and pushes `tokenOut` from its own balance.

| Property | Value | Source |
|----------|-------|--------|
| Quote shape | `{quoteId, taker, tokenIn, maxAmountIn, tokenOut, price, expiry, epoch}` — capped allowance, taker-chosen draw | `GyldAtomicSwap.sol:99-108` |
| Draw arithmetic | `amountOut = requestedAmountIn * price / 1e18`, `requestedAmountIn` passed at call time and **not** part of the signed message | `:105`, `:321-328` |
| Dust floor | `MIN_DRAW_BPS = 100` (1% of `maxAmountIn`) | `:125`, enforced `:336-337` |
| Draw semantics | **Single-shot.** The bitmap bit is set unconditionally, so residual `maxAmountIn - requestedAmountIn` is permanently forfeited. There is no partial-fill state | `:347`, `:452` |
| EIP-712 domain | name `"GyldAtomicSwap"`, version **`"2"`** | `:239` |
| Typehash | `0x87423ed2…52f0b` — re-derived with `cast keccak`, **MATCH** | `:120` |
| Roles | `DEFAULT_ADMIN_ROLE`, `QUOTE_SIGNER_ROLE`, `PAUSER_ROLE`, `TREASURER_ROLE`, `ALLOWLIST_ADMIN_ROLE` (split off admin in GYL-1050) | — |
| Licence | **BUSL-1.1** on all 7 core contracts | contract headers |

### Deployment reality

| Network | chainId | Atomic swap? | Notes |
|---------|---------|--------------|-------|
| Local Anvil | 31337 | ✅ only here | `AtomicSettlementFlow.s.sol:63` and `DeployAtomicSettlementE2E.s.sol:60` both hard-require `chainid == 31337` |
| Sepolia | 11155111 | ❌ | Older token stack only (`DeployDevNet`); wired to `MockSanctionsList` |
| Base **mainnet** | 8453 | ❌ | Token + Euler contracts. **8453 is mainnet** — `DeployBaseTest.s.sol` is a misleading name that has already caused confusion |
| Any public testnet | — | ❌ **nothing** | — |

---

## 1. Deliverables produced in this pass

| Artifact | Lines | Status |
|----------|-------|--------|
| `docs/atomic-swap-spec.md` | 1135 | Normative spec — state machine, 20+ invariants, EIP-712 vectors, auth matrix, revert catalogue, threat model |
| `contracts/test/GyldAtomicSwap.spec.t.sol` | — | 29 new tests closing genuine coverage gaps (398 → 427) |
| `docs/integration/{README,rest-api,onchain-atomic-swap,errors}.md` | 2193 | Third-party integration docs, both surfaces |
| `docs/atomic-settlement-testnet-runbook.md` | 469 | Deploy sequence + readiness gaps |
| ERC-8056 conformance work | — | **Dropped** (GYL-1201, 2026-08-03) — see [`decisions/erc8056-dropped-on-evm.md`](decisions/erc8056-dropped-on-evm.md) and §5 |

Existing test files were not modified. `contracts/GyldAtomicSwap.sol` is unmodified (`git diff` empty).

---

## 2. Consolidated findings register

### 2.1 Contract findings (from formalisation)

| ID | Finding | Severity |
|----|---------|----------|
| **C-F1** | `_checkQuoteBand` divides by `1e20` (`:436`), hard-coding 18dp bond / 8dp NAV / 6dp USDC — but `registerSeries` probes **only** the forwarder's `decimals() == 8` (`:475-476`). The token's 18dp is asserted in NatSpec and never verified. A higher-decimal series inflates `navValue` and makes the band **vacuously true**, silently removing the only economic guard on a compromised quote signer. Fix: extend probe-before-store to `token.decimals() == 18` and `usdc.decimals() == 6` | **Medium** |
| C-F2 | `:97-98`/`:103` describe `maxAmountIn` as bounding "a range of draws", implying a running allowance. Code is strictly single-draw — would mislead a partial-fill integrator | Low (docs) |
| C-F3 | The used-quote bitmap is not epoch-scoped (`:137`, `:459`), so `quoteId`s must be globally unique for the proxy's lifetime. A quote-service counter reset produces intermittent `QuoteAlreadyUsed` failures — and would bite hardest right after an incident-response `bumpQuoteEpoch` | Low (off-chain + doc) |
| C-F4 | `expiry` has no upper bound (`:341`). An immortal quote is signable, revocable only via timelocked `bumpQuoteEpoch`. Fix: admin-set `maxQuoteTtl` | Low |
| C-F5 | `seriesList` (`:138`) has no getter; its swap-and-pop (`:494-504`) is unobservable and untestable | Info |
| C-F6 | `:433` accepts a future-dated `updatedAt`, so a future-timestamped stuck feed never trips `StaleNav` | Info |
| C-F7 | Only `DEFAULT_ADMIN_ROLE` is non-renounceable (`:607-610`). A sole `PAUSER_ROLE` holder can renounce, removing the fast incident halt until a 48h timelock re-grant | Info |

**Threat-model headline:** the loss ceiling is now `sum(balanceOf(this))` — bounded by signature + NAV band + fixed-destination `withdraw` + `pause()`, but **unbounded under `DEFAULT_ADMIN_ROLE` compromise**. The timelock is the only real control there. Note also that the band limits *per-swap* slippage, not *cumulative* extraction by a compromised signer.

### 2.2 API findings (blocking external publication)

Verified against the live spec: OpenAPI 3.1.0, **45 paths / 46 operations**, schemes `bearerAuth` + `hmacApiKey`, **no global `security` block**.

| ID | Finding | Severity |
|----|---------|----------|
| **A-1** | **No login / token / refresh endpoint exists anywhere in the spec.** The `/me/api-keys` operations accept `bearerAuth` only, so an HMAC key cannot mint or rotate itself. The chain is JWT → mint key → HMAC, and step one is undocumented. A partner cannot bootstrap credentials at all | **Blocker** |
| **A-2** | HMAC `-TIMESTAMP`/`-SIGN` are described in prose only — generated clients send unsigned requests. Canonicalisation of `{host}`, the `/api/v1` prefix, method casing and empty bodies is unspecified | **Blocker** |
| **A-3** | `POST /kyc/start` has **no request schema at all** — uncallable | **Blocker** |
| **A-4** | No quote-service endpoint is published, so `executeSwap` is unreachable for an external caller even once contracts exist | **Blocker** (on-chain) |
| A-5 | No error body schema on ~100 error responses; `409` sub-causes distinguishable only by free text | High |
| A-6 | Mint/redemption/KYC/withdrawal `status` are bare strings — no enum, no terminal marker; redemption's success state is unnamed | High |
| A-7 | `idempotency-key` required on 3 endpoints, absent on `/redeem`, `/withdraw`, `/deposit/mint` — **retries may double-book real money** | High |
| A-8 | Scopes `read`/`trade`/`withdraw` exist as `ScopeDto` but no operation declares which it needs; no insufficient-scope status | Medium |
| A-9 | No `429` or rate-limit contract despite a `rate_tier` field | Medium |

A-1 through A-4 are owned by the API team, not this repo. The docs mark each gap inline as "not specified in the spec (confirm with the API team)" rather than guessing, so they are safe to circulate **internally** now — but a partner following them today stalls on step one.

### 2.3 Repo-hygiene / documentation divergences

| ID | Finding | Severity |
|----|---------|----------|
| **H-1** | `docs/blockchain-status.md` still claims `MAX_STALENESS` = **36 hours** with reverting reads and "**no emergency override — this is intentional**". Code: `MAX_STALENESS = 96 hours` used only by the monitoring-only `isFresh()`; `latestRoundData()`/`latestAnswer()` **never revert on staleness**; and `emergencyUpdateAnswer()` exists, bypassing both the deviation cap and the update interval. The doc's weekend-freeze analysis describes behaviour the bytecode does not have, and inverts who bears the risk | **High** |
| H-2 | `origin/fix/GYL-961` (unmerged) partially addresses H-1 by enforcing emergency-updater ≠ owner, on both the setter and `transferOwnership`. It does **not** add a cap or rate limit to `emergencyUpdateAnswer`, nor fix the docs | — |
| **H-3** | Cross-chain address collisions where the same address is a **different contract type**. Same deployer (`0xceae7f…fead`) + same nonce sequence, divergent scripts: `0x7c1798…70ad` is `MockSanctionsList` on Sepolia but a **live `GyldBondToken` on Base mainnet**; `0x18ce55…6317` is `GyldBondToken` on Sepolia but `TokenFactory` on Base mainnet | **High** (operational) |
| H-4 | That same EOA deployed both the throwaway testnet stack and the live mainnet stack. What roles it still holds on Base mainnet needs an on-chain check | High (key hygiene) |
| H-5 | `docs/contracts.md:10-14` labels five contracts "Platform (MIT)"; all seven headers say **BUSL-1.1** (`15bbdfa`). Licence statements must be correct before anything is published externally | Medium |
| H-6 | `broadcast/DeployDvpEscrow.s.sol/31337` persists for a script deleted in GYL-548 | Low |

---

## 3. Blocking decisions

| ID | Decision | Owner | Why it blocks |
|----|----------|-------|---------------|
| **D-1** | **Target testnet: Sepolia or Base Sepolia (84532)?** Recommendation: **Sepolia** — the only network with all three hard dependencies already in place (existing token/NAV stack, a working `[etherscan] sepolia` entry, and real Circle USDC with EIP-2612 permit so `permitIn` can be exercised). Base Sepolia has no etherscan config | Contracts | Changes every deploy command, env var and published address |
| **D-2** | **Admin authority on testnet: EOA or TimelockController?** | Contracts + Security | Self-custody makes this materially worse than before: `DEFAULT_ADMIN_ROLE` compromise is an **unbounded** loss, and `TIMELOCK_ADDRESS` is currently optional |
| **D-3** | **Quote signer: dev key or KMS from day one?** | Backend + DevOps | `QUOTE_SIGNER_ROLE` defaults to the deployer; a leaked signer drains inventory within the NAV band |
| **D-4** | **Is the NAV feed's no-revert-on-staleness + emergency-override design intended?** (H-1) | Contracts + Security | Code and docs describe designs with opposite risk profiles. Gates the audit pack — an auditor handed the current doc scopes against a design that isn't there |
| **D-5** | ~~**ERC-8056: full conformance, blockers only, or drop the conformance claim?**~~ **RESOLVED 2026-08-03: dropped entirely** (GYL-1201) — [`decisions/erc8056-dropped-on-evm.md`](decisions/erc8056-dropped-on-evm.md) | Product + Contracts | ~~It is a **Draft** ERC and no integrator has asked for it by name. See §5~~ Resolved; see §5 |
| **D-6** | **Who is the first design partner, and which surface do they need?** | Product | Determines whether A-1…A-3 (REST) or A-4 (quote service) is the priority |

---

## 4. Phased plan

### Phase 0 — Decisions (blocking)
D-1 through D-6 recorded in `docs/decisions/` with rationale. D-1 is a same-day call and unblocks the longest chain.

### Phase 1 — Contract hardening
| Step | Deliverable |
|------|-------------|
| 1.1 | ✅ Normative spec + 29 new tests (427 passing) |
| 1.2 | Fix **C-F1** — extend probe-before-store to the bond token's and USDC's decimals |
| 1.3 | Triage C-F2…C-F7; fix or accept-with-rationale in writing |
| 1.4 | Resolve H-1 per D-4; merge or supersede `origin/fix/GYL-961` |
| 1.5 | Audit-readiness pack: frozen commit, spec, invariant results, known-findings list |

### Phase 2 — Testnet (per D-1)
| Step | Deliverable |
|------|-------------|
| 2.1 | ✅ Runbook |
| 2.2 | Resolve per-network dependencies: real USDC, sanctions oracle substitute (`SanctionsOracleMirror` — Chainalysis is mainnet-only), NAV feed |
| 2.3 | Add missing verification config for the chosen network |
| 2.4 | Deploy: token/NAV stack → swap → role wiring **including the allowlist** → **inventory seeding** (self-custodial: no vault to draw on) |
| 2.5 | Lift the `chainid == 31337` guards for a testnet smoke path |
| 2.6 | Smoke test: one real buy + one real redeem with a signed quote, digest parity confirmed |
| 2.7 | Address registry doc (chainId adjacent to every address — see H-3) + explorer verification |

### Phase 3 — Quote service & keys
Quote endpoint returning a signed `SwapMessage` with `epoch` read live from `quoteEpoch()`; digest parity in CI; signer key in KMS per D-3; **globally-unique `quoteId` allocation** (C-F3); off-chain taker pre-screening; rehearsed rotation via grant/revoke + `bumpQuoteEpoch`.

### Phase 4 — Third-party integration
Docs are written; publication is gated on A-1…A-4 and on Phase 2 addresses. Then: partner sandbox (test key, funded testnet taker, worked example), and a design-partner dry run.

### Phase 5 — Audit & mainnet (gate)
Frozen commit → external audit → remediation → mainnet with Timelock admin + KMS signer. **No mainnet date should be quoted before audit scope is agreed.**

---

## 5. ERC-8056 — RESOLVED: dropped (GYL-1201, 2026-08-03)

**This track is closed.** The team decided on 2026-08-03 not to use ERC-8056 on
EVM at all — full rationale, evidence, and the orphaned testnet token addresses
in [`decisions/erc8056-dropped-on-evm.md`](decisions/erc8056-dropped-on-evm.md).
The extension has been removed from `GyldBondToken`; value display returns to
`balanceOf × NAV` via `KaleidoscopeNAVFeed`, which was always authoritative for
everything transactional.

For the record: the conformance findings E-C1…E-F3 that previously filled this
section were subsequently fixed (the merged GYL-956 implementation was
conformant — see the superseded addendum in
[`decisions/gyld-bond-token-design.md`](decisions/gyld-bond-token-design.md) §3
and the Anvil verification in
[`anvil-verification-erc8056-2026-07-31.md`](anvil-verification-erc8056-2026-07-31.md)),
so the drop is a product decision, not a remediation failure. The findings text
is preserved in this file's git history.

**Consequence for this roadmap:** the NAV feed is now the *only* on-chain value
channel, which raises the priority of the stale-feed / NAV-keeper gaps (H-1,
D-4, GYL-1134).

---

## 6. Work split — what can start now

| Track | Unblocked today? | Blocked until |
|-------|------------------|---------------|
| Fix C-F1 + triage C-F2…C-F7 | ✅ | — |
| Resolve H-1/H-5/H-6 doc divergences | ✅ | D-4 for H-1's direction |
| Audit H-3/H-4 configs + on-chain role check | ✅ | — |
| ~~ERC-8056 fixes (§5)~~ Closed — dropped per D-5 (GYL-1201) | — | — |
| Answer A-1…A-4 (API team) | ✅ | — |
| Testnet deploy | ❌ | D-1, D-2, Phase 1 |
| Quote service hardening | ❌ | D-3 |
| Publishing docs externally | ❌ | A-1…A-4 + Phase 2 addresses |

Four of the seven open tracks are unblocked (the ERC-8056 track is closed).
That is the work to hand out now.

---

## 7. Open questions

1. **D-1…D-6** — six decisions, owners needed.
2. What roles does `0xceae7f…fead` still hold on Base mainnet? (H-4) Needs an on-chain check; not a guess.
3. What is `_emergencyUpdater` set to on the live Base mainnet NAV feed? (H-1) If it is a hot EOA rather than a distinct Safe, that is an active risk, not a doc issue.
4. Given H-1, did any Morpho/Euler/Aave risk parameter get set assuming a staleness revert that does not exist?
5. Who owns publishing to `dev-app.gyld.cloud/docs`? It is served from the API repo, not this one.
6. Is there a date driving this, or is the audit gate the only hard constraint?
