# Consolidated Error Reference

Errors for both integration surfaces in one place: HTTP statuses for the
[REST API](rest-api.md), and Solidity custom errors with computed 4-byte
selectors for [`GyldAtomicSwap`](onchain-atomic-swap.md).

---

## 1. REST API — HTTP statuses

### 1.1 ⚠️ No error body is specified

**None of the ~100 error responses in the OpenAPI specification declares a
response schema.** Every one is description-only. There is therefore **no
documented error envelope** — no error code field, no message field, no request
id.

The single exception is `POST /me/email-otp/enroll`, whose `422` is documented as
returning `{"error": "email_not_verified"}`. Whether that `{"error": "..."}`
shape generalises to other endpoints is **not specified in the spec (confirm with
the API team)**.

**Build defensively:** branch on the **HTTP status code**, treat the body as
opaque diagnostic text, log it verbatim, and never parse it for control flow.

### 1.2 Status codes in use

Counts are occurrences across the 46 operations.

| Status | Uses | Meaning | Retry? |
|--------|------|---------|--------|
| `200` | 29 | Success. On `POST /invest` specifically, `200` means **idempotent replay** — the returned `mint_request_id` already existed. | — |
| `201` | 6 | Created (`/register`, `/kyc/start`, `/me/api-keys`, `/deposit/mint`, `/redeem`, `/withdraw`). | — |
| `202` | 3 | **Accepted, work is asynchronous** (`/invest`, both conversions). You must poll. | — |
| `204` | 9 | Success, no body. Also used to mean *"intent recorded"* on the cancel endpoints — **not** *"cancelled"*. | — |
| `401` | 45 | Unauthorized. On **every** operation except `POST /register`. | Only after fixing credentials |
| `403` | 4 | Forbidden — **four distinct causes**, see below. | No |
| `404` | 15 | Not found, or not owned by you. | No |
| `409` | 4 | Conflict — state has moved. **Expected during normal operation.** | Re-read, then decide |
| `422` | 17 | Unprocessable — validation, insufficient funds, or a sanctions block. | Only after changing input |
| `500` | 1 | Internal server error (`POST /register` only). | Yes, with backoff |
| `501` | 1 | **Not implemented — feature flag off** (`POST /deposit/mint`). | No |
| `503` | 2 | **Market closed** (`GET /invest/quote`, `POST /invest`). | Yes, after `Retry-After` / `next_open` |
| `429` | **0** | ⚠️ **Never documented**, despite API keys carrying a `rate_tier`. Rate-limit behaviour and headers are **not specified in the spec**. | Assume it can happen; back off |

### 1.3 `401 Unauthorized`

Declared on 45 of 46 operations. Causes to check, in order:

1. No credentials sent.
2. **HMAC:** clock skew — the `GYLD-ACCESS-TIMESTAMP` must be within **±30 s** of
   server time. Synchronise with NTP; drift presents as intermittent failures.
3. **HMAC:** signature mismatch. The canonical string is
   `{timestamp}{METHOD}{host}{path_and_query}{body}` with **no delimiters**.
   The usual cause is re-serialising the body between signing and sending, or
   omitting the `/api/v1` prefix from `path_and_query`.
4. **HMAC:** wrong header names — `GYLD-ACCESS-KEY`, `GYLD-ACCESS-TIMESTAMP`,
   `GYLD-ACCESS-SIGN`.
5. Key revoked or expired; or the caller IP is outside the key's `ip_allowlist`.
6. **Bearer:** token expired. ⚠️ There is **no refresh endpoint in the spec**.
7. Using an HMAC key against `/me/api-keys` — those three operations accept
   `bearerAuth` **only**.

⚠️ The status returned for an **insufficient scope** (as opposed to absent
credentials) is **not specified in the spec**. It may be `401` or `403`. Handle
both.

### 1.4 `403 Forbidden` — four distinct causes

| Endpoint | Cause | Remedy |
|----------|-------|--------|
| `POST /register` | Email not pre-approved by Gyld operations, or account deactivated | Arrange pre-approval. Registration is not open self-service. |
| `POST /redeem` | KYC not approved | Poll `GET /kyc/status` until approved |
| `POST /redeem/{id}/confirm` | KYC not approved | As above |
| `GET /kyc/documents/{doc_id}` | Document belongs to a different case | Use only ids from `GET /kyc/documents` |

### 1.5 `409 Conflict` — expect it

Four operations return `409`. All four are **races you cannot fully avoid**,
because the server re-checks authoritatively against live broker state:

| Endpoint | Documented causes |
|----------|-------------------|
| `POST /register` | Email already registered |
| `POST /mint/requests/{id}/cancel` | (a) state cannot be cancelled at all; (b) value already moved — tokens minted or order filled; (c) cancellation already requested |
| `POST /mint/requests/{id}/retry` | Not `Failed`, or failed after an irreversible step |
| `POST /redeem/{id}/cancel` | (a) already past `Screening`; (b) sell order already has a fill; (c) cancellation already requested |

The spec is explicit that a fill landing between rendering a Cancel button and
clicking it **yields `409`**. Treat it as a normal outcome: re-read the request
object and re-render, do not surface it as an error.

⚠️ Each `409` has "distinct message text" per cause, but with **no error body
schema** the three sub-causes are distinguishable only by free-text matching — a
fragile approach. **A machine-readable discriminator is not specified in the spec
(confirm with the API team).**

### 1.6 `422 Unprocessable Entity` — five different meanings

`422` is the most overloaded status in the API. What it means depends entirely on
the endpoint:

| Meaning | Endpoints |
|---------|-----------|
| **Insufficient funds** | `POST /invest` (USD), `POST /deposit/mint` (USDC), `POST /withdraw`, `POST /invest/convert-to-cash` (USDC), `POST /invest/convert-to-usdc` (USD) |
| **Blocked by sanctions screening** | `POST /me/source-addresses`, `PUT /me/withdrawal-address`. A **Block** decision returns `422`; a **Review** decision still *accepts* the address. |
| **Email not verified** | `POST /me/email-otp/enroll` — body `{"error": "email_not_verified"}` |
| **Missing/invalid required field** | `POST /redeem/{id}/confirm` (`limit_price_usd` is mandatory), `GET /instruments/{id}/ytm` (`price`) |
| **General validation** | `POST /kyc/start`, `PATCH /me/profile`, `POST /me/api-keys`, `GET /invest/quote`, `GET /redeem/quote`, `POST /redeem`, `GET /portfolio/history/{id}` (malformed id) |

Never blind-retry a `422`. Distinguish *insufficient funds* (retry after funding)
from *validation* (fix the request) from *sanctions* (escalate — do not retry).

### 1.7 `501 Not Implemented`

Only `POST /deposit/mint`. The endpoint sits behind a server-side feature flag
that is **off by default**; while unset it returns `501` and **writes nothing**,
so no partial state is created. Confirm with the API team that the flag is enabled
for your environment before building against this path.

### 1.8 `503 Service Unavailable` — market closed

| Endpoint | Notes |
|----------|-------|
| `GET /invest/quote` | Market closed |
| `POST /invest` | Market closed (outside NYSE hours) — **retry after the `Retry-After` header** |

Do not poll blindly. Read `GET /market/clock` and schedule against `next_open`.

### 1.9 Failures that are *not* HTTP errors

The most important REST failures return `2xx` and surface later in the request
object. A `202` from `POST /invest` means *accepted*, not *succeeded*.

| Failure | Where it appears |
|---------|------------------|
| Mint failed | `MintRequestResponse.status == "failed"`, with `failure: { step, message }` |
| Mint blocked by compliance | `status == "blocked"`, with `block_reason`. **Not retryable** — `POST /mint/requests/{id}/retry` returns `409`. |
| Redemption failed | `RedemptionStatusResponse.failure` non-null. Retry via `POST /redeem/{id}/confirm` with a new limit price. |
| Conversion failed | `status == "failed"`, `reason` populated |
| Stale-quote mint failure | Fails at order placement when the quote has aged past 300 s. Retry will **fail again by design** — submit a fresh `POST /invest` at a current price. |

⚠️ Because lifecycle `status` fields are bare `string`s with no enum and **no
terminal-state marker**, treat any unrecognised status as non-terminal and keep
polling. See [rest-api.md §11](rest-api.md#11-polling-and-terminal-states).

---

## 2. Solidity custom errors — `GyldAtomicSwap`

Selectors are the first 4 bytes of `keccak256` of the canonical signature,
computed from the compiled ABI and verified with `cast sig`. Recompute any of
them with:

```bash
cast sig "QuoteExpired(uint64)"        # 0x1f99570c
cast 4byte 0x1f99570c                  # reverse lookup
```

### 2.1 Errors declared by `GyldAtomicSwap`

Sorted by how likely you are to hit them as a caller.

| Selector | Error | Cause | Remedy |
|----------|-------|-------|--------|
| `0xfa5cd00f` | `NotAllowed(address taker)` | **You are not on the taker allowlist.** | Ask Gyld compliance to allowlist your address. Check `isAllowed(you)` before calling. A perfectly valid quote still reverts here. |
| `0x6f720739` | `NotTaker(address taker, address caller)` | `msg.sender != m.taker`. Quotes are not bearer instruments. | Execute from the exact address in the quote. You cannot relay, resell, or use someone else's quote. |
| `0xb3aa481d` | `RequestedAmountOutOfRange(uint256 requested, uint256 minAllowed, uint256 maxAllowed)` | `requestedAmountIn` is zero, below the **1% dust floor** of `maxAmountIn`, or above `maxAmountIn`. | The error returns both bounds — clamp into `[minAllowed, maxAllowed]`. |
| `0x1f99570c` | `QuoteExpired(uint64 expiry)` | `block.timestamp > m.expiry`. | Request a fresh quote. Reduce the latency between quote issuance and submission; account for the pending-transaction window. |
| `0xbab0dc16` | `QuoteEpochStale(uint64 quoteEpoch, uint64 currentEpoch)` | Gyld bumped the epoch, mass-invalidating **every** outstanding quote (signer rotation or incident response). | Discard all held quotes and request new ones. Watch `QuoteEpochBumped`. |
| `0xbb083ea1` | `QuoteAlreadyUsed(uint256 quoteId)` | `quoteId` already consumed. **A quote is burned in full regardless of how little you drew** — this is single-shot capped sizing, not a multi-draw allowance. | Request a new quote. Check `isQuoteUsed(quoteId)` first. |
| `0x9f6905a9` | `InvalidQuoteSigner(address recovered)` | The recovered signer does not hold `QUOTE_SIGNER_ROLE`. | Almost always a **client-side EIP-712 bug**: domain `version` must be **`"2"`** (not `"1"`), `name` `"GyldAtomicSwap"`, correct `chainId` and `verifyingContract` (the **proxy**), and the exact field order. Compare your digest against `hashSwapMessage(m)`. Alternatively the signing key was rotated — get a fresh quote. |
| `0x76fae829` | `InsufficientInventory(address token, uint256 requested, uint256 available)` | The contract does not hold enough of the **bond** `tokenOut`. | **Liveness, not your error.** Retry later or draw a smaller `requestedAmountIn`. `available` tells you the ceiling. |
| `0xb937c365` | `InsufficientUsdcLiquidity(uint256 requested, uint256 available)` | Same, for the **USDC** leg (redemption direction). | As above. |
| `0x09b1bbd1` | `QuotePriceOutOfBand(uint256 quotedUsdcAmount, uint256 navUsdcAmount)` | The quote's USDC leg deviates from oracle NAV by more than `maxQuoteDeviationBps()`. | Get a fresh quote. Note the band may be set to `0`, which forces exact-NAV matching and acts as a soft pause. |
| `0x5344476d` | `StaleNav(address token, uint256 updatedAt)` | The NAV feed is older than `maxNavAgeSecs()`. **Fails closed by design.** | **Transient infrastructure condition** — retry with backoff. Not a bad-input error. |
| `0x7277247e` | `InvalidNav(address token, int256 nav)` | Feed reported a non-positive NAV. Fails closed. | As above; escalate if persistent. |
| `0xe9f7d5b4` | `NotOneBondLeg(address tokenIn, address tokenOut)` | Not exactly one registered bond series against USDC — e.g. bond↔bond, USDC↔USDC, or an unregistered/deregistered series. | Verify `registeredSeries(bondToken)` and that the other leg is exactly `usdc()`. |
| `0x1f2a2005` | `ZeroAmount()` | `m.price == 0`, or `amountOut` truncated to zero, or `withdraw(amount = 0)`. | Assert `requestedAmountIn * price / 1e18 > 0` before sending. Truncation bites hardest on small draws across a 6↔18 decimal boundary. |
| `0x1799816c` | `UnregisteredSeries(address token)` | Admin path — deregistering a series that is not registered. | Not reachable by a swap caller. |
| `0xd92e233d` | `ZeroAddress()` | A zero address in an admin call, or `withdraw()` before the withdrawal wallet is set (fail-closed). | Not reachable by a swap caller. |
| `0x572625ba` | `NotValidForwarder(address forwarder)` | Admin path — `registerSeries` probe rejected a forwarder that is not a contract or does not report 8 decimals. | Admin-only. |
| `0xef2afe8d` | `SeriesNotEmpty(address token)` | Admin path — deregistering a series while inventory remains. | Admin-only. |
| `0x25110ab2` | `InvalidDeviationBps(uint16 bps)` | Admin path — band above `10_000`. | Admin-only. |
| `0x2b07eafa` | `InvalidNavAge(uint32 secs)` | Admin path — zero NAV age. | Admin-only. |
| `0x450b8820` | `CannotRenounceAdminRole()` | `renounceRole(DEFAULT_ADMIN_ROLE, …)` is blocked — losing it would permanently brick upgrades, unpause, and role management. | Admin-only; use `revokeRole` as an explicit two-party action. |

### 2.2 Inherited errors you can hit

These come from OpenZeppelin base contracts. A caller of `executeSwap` can
realistically hit the first five.

| Selector | Error | Cause | Remedy |
|----------|-------|-------|--------|
| `0xd93c0665` | `EnforcedPause()` | The contract is **paused**. | Wait. Pausing is cheap for ops and resuming is governance-gated, so a pause can persist. |
| `0x5274afe7` | `SafeERC20FailedOperation(address token)` | A token transfer or `transferFrom` failed: **insufficient allowance**, insufficient balance, or a **compliance block inside `GyldBondToken`** (its transfer hook screens sender, recipient, and the swap contract as spender, failing closed). | Check `allowance(you, swap) >= requestedAmountIn` and your balance. If both are fine, the address is likely sanctions-blocked — escalate; do not retry. A silently-failed permit also surfaces here, since the permit is swallowed by `try/catch`. |
| `0xe2517d3f` | `AccessControlUnauthorizedAccount(address account, bytes32 neededRole)` | You called an admin-, treasurer-, or pauser-only function. | Not for integrators. |
| `0xf645eedf` | `ECDSAInvalidSignature()` | Malformed signature bytes. | Re-fetch the quote; verify you passed the raw 65-byte signature. |
| `0xfce698f7` | `ECDSAInvalidSignatureLength(uint256 length)` | Signature is not 65 bytes. | Concatenate as `r ‖ s ‖ v`; do not hex-encode twice or include a `0x` prefix in raw bytes. |
| `0xd78bce0c` | `ECDSAInvalidSignatureS(bytes32 s)` | Non-canonical (high) `s` value — malleability guard. | Normalise `s` to the lower half of the curve order. Standard libraries do this; hand-rolled signers often do not. |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` | Re-entering `executeSwap` or `withdraw`. | Do not call back into the contract from a token hook. |
| `0x6697b232` | `AccessControlBadConfirmation()` | `renounceRole` called with a confirmation address that is not the caller. | Admin-only. |
| `0x8dfc202b` | `ExpectedPause()` | `unpause()` while not paused. | Admin-only. |

### 2.3 Errors not reachable through normal integration

Present in the ABI, but only reachable via proxy/initialisation paths:
`InvalidInitialization()` `0xf92ee8a9`, `NotInitializing()` `0xd7e6bcf8`,
`ERC1967InvalidImplementation(address)` `0x4c9c8ce3`,
`ERC1967NonPayable()` `0xb398979f`, `UUPSUnauthorizedCallContext()` `0xe07c8dba`,
`UUPSUnsupportedProxiableUUID(bytes32)` `0xaa1d49a4`,
`AddressEmptyCode(address)` `0x9996b315`, `FailedCall()` `0xd6bda275`.

Seeing one of these in production almost certainly means you are calling the
**implementation** address instead of the **proxy**.

---

## 3. Triage quick reference

| Symptom | Most likely cause |
|---------|-------------------|
| REST `401` on every call, HMAC | Clock skew (±30 s), or `/api/v1` missing from the signed `path_and_query` |
| REST `401` intermittently | Clock drift — run NTP |
| REST `401` only on `/me/api-keys` | Those three operations accept **bearer only** |
| Cannot get any credentials at all | ⚠️ **No login/token endpoint exists in the spec** — blocked; contact the API team |
| REST `409` on cancel | A fill landed first. Normal — re-read and re-render |
| REST `202`/`201` then nothing happens | It is asynchronous. Poll the request object |
| REST `501` | `POST /deposit/mint` feature flag is off |
| REST `503` | Market closed — check `GET /market/clock` |
| Withdrawal `422` with funds present | Your balance is `usd`, not `usdc`. Convert with `POST /invest/convert-to-usdc` first |
| On-chain `InvalidQuoteSigner` | EIP-712 domain `version` must be **`"2"`**, not `"1"` — compare against `hashSwapMessage(m)` |
| On-chain `NotAllowed` | Not allowlisted. Check `isAllowed(you)` |
| On-chain `SafeERC20FailedOperation` | Approved the wrong contract — **approve `GyldAtomicSwap` itself; there is no vault** |
| On-chain `QuoteAlreadyUsed` after a partial draw | Expected. One quote, one draw — the id burns in full |
| On-chain `StaleNav` | Transient oracle staleness; retry with backoff |
| On-chain error not in this document | You are probably calling the implementation, not the proxy |
