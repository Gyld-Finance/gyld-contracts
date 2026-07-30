# Gyld Investor REST API

Everything in this document is derived from the published OpenAPI 3.1.0
specification: **Gyld Investor API v0.1.0**.

| | |
|---|---|
| Machine-readable spec | `https://dev-app.gyld.cloud/openapi.json` |
| Rendered reference | `https://dev-app.gyld.cloud/docs` |
| Base URL (development) | `https://dev-app.gyld.cloud/api/v1` |
| Paths / operations | 45 paths, 46 operations |
| Scope | Investor-facing endpoints only. Admin and compliance endpoints are deliberately excluded from the spec. |

The spec also declares a pre-production host and a `http://localhost:8080/api/v1`
local-development server. Ask the API team which host your integration should
target; this document uses the development host throughout.

> Where the spec is silent, this document says so explicitly rather than
> guessing. Any statement marked **not specified in the spec (confirm with the
> API team)** is a real gap, not an omission here.

---

## 1. Authentication

The spec defines two security schemes and **no global security requirement** —
authentication is declared per operation.

| Scheme | Type | Transport | Notes |
|--------|------|-----------|-------|
| `bearerAuth` | `http` / `bearer` | `Authorization: Bearer <token>` | Described in the spec as "a Keycloak-issued token". |
| `hmacApiKey` | `apiKey` in header | `GYLD-ACCESS-KEY` | Only the key-ID header is modelled. Signing requires two further headers — see [§1.2](#12-hmac-request-signing). |

### 1.1 Which scheme does each operation accept?

| Operation group | Accepted schemes |
|-----------------|------------------|
| `POST /register` | **None** — the only unauthenticated operation in the API. |
| `GET /me/api-keys`, `POST /me/api-keys`, `DELETE /me/api-keys/{key_id}` | **`bearerAuth` only.** |
| All other 42 operations | `bearerAuth` **or** `hmacApiKey` (either satisfies the requirement). |

Two consequences follow directly, and both matter for integration design:

1. **An HMAC key cannot mint, list, or revoke a key — not even itself.** Key
   lifecycle management is reachable only with a bearer JWT. Any key rotation
   procedure you build must retain a path to a valid JWT.
2. ⚠️ **There is no login, token, refresh, or token-exchange endpoint anywhere in
   the spec.** No operation issues a JWT. Since `POST /register` returns only a
   `user_id`, and key creation demands a JWT, the credential bootstrap cannot be
   completed from the spec alone. **This is a blocker — the mechanism by which a
   third party obtains a bearer token is not specified in the spec (confirm with
   the API team).**

The practical model, as far as the spec defines it:

```
POST /register  (unauthenticated)
        │
        ▼
   [ obtain bearer JWT ]  ◄── NOT SPECIFIED IN THE SPEC — blocker
        │
        ▼
POST /me/api-keys  (bearerAuth only) ──► { id, secret }   secret shown ONCE
        │
        ▼
all subsequent calls  (hmacApiKey or bearerAuth)
```

### 1.2 HMAC request signing

Three headers are required on every HMAC-authenticated request. Only the first
is declared in the security scheme; the other two are documented in the spec's
prose description.

| Header | Value |
|--------|-------|
| `GYLD-ACCESS-KEY` | The API key ID returned by `POST /me/api-keys` (the `id` field). |
| `GYLD-ACCESS-TIMESTAMP` | Unix time in **seconds**. Must be within **±30 s** of server time. |
| `GYLD-ACCESS-SIGN` | **Base64**-encoded **HMAC-SHA256** over the canonical string below, keyed by the API key secret. |

The canonical signing string is the plain concatenation — **no delimiters, no
newlines**:

```
{timestamp}{METHOD}{host}{path_and_query}{body}
```

| Component | Meaning |
|-----------|---------|
| `timestamp` | Byte-identical to the `GYLD-ACCESS-TIMESTAMP` header you send. |
| `METHOD` | Uppercase HTTP verb — `GET`, `POST`, `PUT`, `PATCH`, `DELETE`. |
| `host` | Request host, e.g. `dev-app.gyld.cloud`. |
| `path_and_query` | Path **including the `/api/v1` prefix**, plus the query string with its leading `?` when one is present. |
| `body` | The raw request body exactly as transmitted, or the empty string for bodies-less requests. |

Signing must be done over the *exact* bytes you send. Serialise the body once,
sign that string, and transmit that same string — re-serialising between signing
and sending is the most common cause of signature rejection.

> **Precise canonicalisation of `host` and `path_and_query`** (port handling,
> trailing slashes, query-parameter ordering, URL-encoding normalisation) is
> **not specified in the spec (confirm with the API team)**. The spec points to
> an internal design document for the canonical contract and a reference client.

The spec also notes that the rendered documentation's "Try it" button **cannot**
produce a working HMAC call, because it can only capture the single key header.
Use a signing client.

#### Worked example

Signing a `GET /api/v1/portfolio` at timestamp `1750000000`:

```
canonical = "1750000000GETdev-app.gyld.cloud/api/v1/portfolio"
sign      = base64( HMAC_SHA256( key = <secret>, msg = canonical ) )
```

Signing a `POST /api/v1/withdraw` with body `{"amount":"100.00","chain":"ethereum"}`:

```
canonical = "1750000000POSTdev-app.gyld.cloud/api/v1/withdraw{\"amount\":\"100.00\",\"chain\":\"ethereum\"}"
```

#### Reference implementation

```python
import base64, hashlib, hmac, json, time, requests

HOST   = "dev-app.gyld.cloud"
PREFIX = "/api/v1"

def signed_headers(key_id: str, secret: str, method: str,
                   path_and_query: str, body: str = "") -> dict:
    ts = str(int(time.time()))
    canonical = f"{ts}{method.upper()}{HOST}{path_and_query}{body}"
    sign = base64.b64encode(
        hmac.new(secret.encode(), canonical.encode(), hashlib.sha256).digest()
    ).decode()
    return {
        "GYLD-ACCESS-KEY": key_id,
        "GYLD-ACCESS-TIMESTAMP": ts,
        "GYLD-ACCESS-SIGN": sign,
    }

# GET, no body
pq = f"{PREFIX}/portfolio"
r = requests.get(f"https://{HOST}{pq}",
                 headers=signed_headers(KEY_ID, SECRET, "GET", pq))

# POST — serialise ONCE, sign that exact string, send that exact string
pq   = f"{PREFIX}/withdraw"
body = json.dumps({"amount": "100.00", "chain": "ethereum"},
                  separators=(",", ":"))
h    = signed_headers(KEY_ID, SECRET, "POST", pq, body)
h["Content-Type"] = "application/json"
r = requests.post(f"https://{HOST}{pq}", headers=h, data=body)
```

Because the timestamp window is ±30 s, **synchronise your clock with NTP**. A
drifting clock presents as intermittent, unexplained auth failures.

### 1.3 API key management

All three operations require a bearer JWT.

**`POST /me/api-keys`** → `201`, body `ApiKeyResponse`

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `label` | string | yes | Human-readable name. |
| `scopes` | array of `read` \| `trade` \| `withdraw` | no | Default when omitted is **not specified in the spec (confirm with the API team)**. |
| `ip_allowlist` | array of string | no | Format (single IP, CIDR, or either) is **not specified in the spec**. |
| `expires_at` | string(date-time) \| null | no | |

**`ApiKeyResponse`**

| Field | Type | Notes |
|-------|------|-------|
| `id` | string | Use as `GYLD-ACCESS-KEY`. |
| `secret` | string \| null | **Present only in the create response.** Never returned again — persist it immediately or lose it. |
| `label`, `scopes`, `ip_allowlist`, `rate_tier` | | `rate_tier` semantics and values are **not specified in the spec**. |
| `created_at`, `expires_at`, `last_used_at`, `revoked` | | |

**`GET /me/api-keys`** → `200`. Lists all non-revoked keys; never returns
secrets. ⚠️ The response has **no schema in the spec** — assume a list of
`ApiKeyResponse` with `secret` absent, but confirm with the API team.

**`DELETE /me/api-keys/{key_id}`** → `204`, or `404` if not found. Idempotent.
The key must belong to the authenticated user.

### 1.4 Scopes

| Scope | Spec description |
|-------|------------------|
| `read` | Portfolio / instruments |
| `trade` | Invest / redeem |
| `withdraw` | Withdrawals |

⚠️ **No operation in the spec declares which scope it requires**, and no
operation documents the status returned when a scope is insufficient. The
mapping above is the spec's one-line prose summary and is not authoritative at
the endpoint level. **Per-operation scope requirements and the
insufficient-scope status code are not specified in the spec (confirm with the
API team).**

---

## 2. Onboarding and KYC

### Step 1 — Register

`POST /register` — unauthenticated.

Request `RegisterRequest`: `{ "email": string, "password": string }` (both
required; password policy not specified in the spec).
Response `201` `RegisterResponse`: `{ "user_id": string }`.

| Status | Meaning |
|--------|---------|
| `201` | Registered. |
| `403` | Email not pre-approved by Gyld operations, or the account is deactivated. **Registration is not open self-service** — arrange pre-approval first. |
| `409` | Email already registered. |
| `500` | Internal server error. |

### Step 2 — Obtain a bearer token

⚠️ **Not possible from the spec.** See [§1.1](#11-which-scheme-does-each-operation-accept).

### Step 3 — Submit KYC

`POST /kyc/start` — `multipart/form-data`, described as "KYC documents and case
kind". → `201` `KycStatusResponse` `{ case_id, status }`; `422` on validation
error.

⚠️ **The multipart body has no schema whatsoever in the spec** — field names,
which document types are accepted, file-size and MIME constraints, and the
"case kind" values are all **not specified in the spec (confirm with the API
team)**. This endpoint cannot be called from the spec alone.

### Step 4 — Poll KYC status

`GET /kyc/status` → `200` `KycStatusDetailResponse`. Optional fields are omitted
when null.

| Field | Type | Notes |
|-------|------|-------|
| `status` | string (required) | ⚠️ The set of values, and which are terminal, are **not specified in the spec**. |
| `caseId`, `tier`, `reason`, `message` | string \| null | |

Downstream gate: `POST /redeem` and `POST /redeem/{id}/confirm` return `403`
"KYC not approved" until approval lands.

### Step 5 — Documents

- `GET /kyc/documents` → `200` (⚠️ **no response schema in the spec**), `404` if
  no KYC case exists.
- `GET /kyc/documents/{doc_id}` → `200` `application/octet-stream` (raw file
  bytes); `403` if the document belongs to a different case; `404` if not found.

### Step 6 — Profile

`PATCH /me/profile`, body `InvestorProfileRequest` → `204`; `422` on validation
error. **Merge semantics: only fields present in the body overwrite stored
values.** All fields are optional. Note this schema uses `camelCase`, unlike the
`snake_case` used elsewhere in the API.

Selected fields (the schema has 32; see the spec for the full list):

| Field | Notes |
|-------|-------|
| `entityKind` | `"individual"` \| `"entity"` |
| `entityType` | `"llc"` \| `"corporation"` \| `"trust"` \| `"fund"` \| `"limited_partnership"` |
| `entityName`, `formationCountry` | Entity flow only; `formationCountry` is ISO-3166-1 alpha-3. |
| `firstName`, `surname`, `dateOfBirth` | `dateOfBirth` is `YYYY-MM-DD`. |
| `citizenshipIso`, `residencyIso`, `countryOfBirth`, `countryOfTaxResidence` | ISO-3166-1 alpha-3, e.g. `"USA"`. |
| `streetAddress` | Array (of address lines). |
| `city`, `stateProvince`, `postalCode`, `residencyCity`, `phone` | |
| `taxId`, `taxIdType` | `taxIdType` e.g. `"usa_ssn"`, `"usa_itin"`. |
| `annualIncomeMin`/`Max`, `totalNetWorthMin`/`Max` | Decimal strings, e.g. `"50000"`. |
| `fundingSource` | Array, e.g. `["employment_income", "investments"]`. Full value set not specified in the spec. |
| `isPoliticallyExposed`, `immediateFamilyMemberExposed`, `isControlPerson`, `isAffiliatedExchangeOrFinra` | Boolean disclosures. |
| `customerAgreementSignedAt`, `accountAgreementSignedAt`, `agreementsIpAddress` | RFC 3339 timestamps / IP string. |

### Step 7 — Profile reads and account hygiene

| Operation | Result |
|-----------|--------|
| `GET /me` | `200` — investor profile and account details. ⚠️ **No response schema in the spec.** |
| `POST /me/resend-verification-email` | `204`. Idempotent; safe to call repeatedly. |
| `POST /me/email-otp/enroll` | `204`. Requires a **verified** email — returns `422` with body `{"error": "email_not_verified"}` otherwise. This is the only concrete error body shape anywhere in the spec. Idempotent. |
| `GET /org/members` | `200` `OrgMembersResponse` — `{ members: [{ user_id, email, first_name, surname, role, joined_at }], total }`. The `role` value set is not specified in the spec. |

### Step 8 — Address allowlisting

Two distinct allowlists, with different purposes. Both are sanctions-screened
before persistence.

| Operation | Purpose | Body | Result |
|-----------|---------|------|--------|
| `POST /me/source-addresses` | Register a wallet you send **from** and receive minted tokens **at**. | `AddSourceAddressRequest` `{ address, chain_id }` (both required) | `204`; `422` if blocked by sanctions |
| `DELETE /me/source-addresses/{address}` | Remove a source address. | — | `204` |
| `PUT /me/withdrawal-address` | Set the single address withdrawals are paid **to**. | `SetWithdrawalAddressRequest` `{ address, chain_id }` (both required) | `204`; `422` if blocked by sanctions |

**Why both matter:**

- A **source address** is required as `wallet_address` on `POST /invest` and
  `POST /deposit/mint`, and is how redemption transfers are attributed back to
  your account. You may register several per chain.
- A **withdrawal address** is a single value set by `PUT` (replace semantics, not
  append), and `POST /withdraw` validates against it.

Screening outcomes differ between the two decisions the screener can return:
a **Block** decision returns `422`; a **Review** decision **still accepts** the
address. The spec documents this explicitly for `PUT /me/withdrawal-address`.
⚠️ Whether a `Review` decision on a source address behaves the same way, and
whether a screening `Review` later blocks transfers, is **not specified in the
spec (confirm with the API team)**.

⚠️ `chain_id` format (numeric EVM chain ID as a string, or a slug like
`"ethereum"`) is **not specified in the spec**. Elsewhere the API uses slugs —
`DepositResponse.chain`, `PostWithdrawRequest.chain`, and
`HistoryEntry.chain_id` are all documented with values like `"ethereum"` /
`"solana"` — so a slug is the likely form, but confirm it.

---

## 3. Funding

### 3.1 Get a deposit address

`GET /deposit/address` → `200` `DepositResponse` `{ chain, deposit_address }`.

Send USDC from a registered source address to `deposit_address`. Gyld watches the
chain for the `Transfer` event and credits your cash balance.

⚠️ The spec's schema description shows a request of `{ chain: "ethereum" }`, but
the operation declares **no parameters and no request body**. How the chain is
selected on this `GET` is **not specified in the spec (confirm with the API
team)**.

### 3.2 Track the deposit

`GET /deposit/pending` → `200`. Returns unconfirmed USDC deposits. Entries appear
from the moment the transfer is detected and disappear once the block reaches
the required confirmation count.

⚠️ **The response has no schema in the spec.** The `PendingDepositItem` schema is
defined but never referenced by any operation. Its fields are `id` (uuid),
`amount_usd` (decimal string in human units — `"500.000000"` = 500 USDC),
`deposit_address`, `tx_hash`, `log_index` (int32), `detected_at` (date-time).
Assume the response is `{ ... }` wrapping a list of these, but confirm the
envelope with the API team. The required confirmation count is not specified in
the spec.

### 3.3 Read balances

`GET /cash-balance` → `200` `CashBalanceResponse` `{ balances: [CashBalanceEntry] }`.

| `CashBalanceEntry` field | Notes |
|--------------------------|-------|
| `chain` | Chain slug. |
| `currency` | `"usdc"` or `"usd"`. |
| `available` | Decimal string — spendable. |
| `held` | Decimal string — reserved against in-flight requests. |

One entry per `(chain, currency)` pair **for which a row exists**. An investor
who has never deposited or redeemed receives an **empty `balances` array** —
handle that, rather than assuming a zero row is present.

The two currencies mean different things and are not interchangeable:

| Currency | Origin | Spendable on | Withdrawable on-chain |
|----------|--------|--------------|-----------------------|
| `usdc` | On-chain deposits | `POST /deposit/mint` | Yes, via `POST /withdraw` |
| `usd` | Redemption proceeds; broker cash | `POST /invest` | **No** — convert to USDC first, see [§6](#6-currency-conversion) |

### 3.4 Convert a confirmed USDC deposit into a bond token

`POST /deposit/mint` → `201` `ExternalDepositMintResponse` `{ mint_request_id }`.

This is the **USDC-amount, market-priced** buy path: you name the instrument and
the USDC you have already deposited, and Gyld sizes the mint against it at
market. Contrast `POST /invest`, which is a `qty × limit_price` limit order
against broker USD.

| `ExternalDepositMintRequest` field | Required | Notes |
|-----------------------------------|----------|-------|
| `cusip_or_isin` | yes | CUSIP (9 alphanumeric) or ISIN (12 alphanumeric). |
| `usdc_amount` | yes | Decimal string, e.g. `"2000"` = 2,000 USDC. Must already be credited to your cash balance. |
| `wallet_address` | yes | Destination for the minted tokens. **Must be one of your registered source addresses**, so later redemption transfers can be attributed to you. |

| Status | Meaning |
|--------|---------|
| `201` | Mint request created. Poll it — see [§7](#7-mint-request-lifecycle). |
| `422` | Validation error or insufficient USDC. |
| `501` | **The feature is disabled.** This route is behind a server-side feature flag that is **off by default**; while unset it returns `501` and writes nothing. Confirm with the API team that it is enabled for your environment before building against it. |

---

## 4. Instrument discovery and quoting

### 4.1 List

`GET /instruments` → `200` `InstrumentListResponse`.

| Query param | Type | Default / notes |
|-------------|------|-----------------|
| `limit` | integer \| null | Default 50, clamped 1–250. |
| `offset` | integer \| null | Default 0. |
| `sort` | string \| null | `symbol` \| `maturity` \| `coupon` \| `kind`. Default `maturity`. |
| `order` | string \| null | `asc` \| `desc`. Default `asc`. |
| `kind` | string \| null | Kind key, e.g. `treasury`, `corporate_bond`, `bond_etf`. Comma-separated list accepted. |
| `tokenized` | boolean \| null | `true` = only instruments with a deployed on-chain token. Null applies no filter. |
| `tradable` | boolean \| null | **Defaults to `true`** (tradable only). Pass `false` to *include* non-tradable instruments. |

`InstrumentListResponse` = `{ instruments: [InstrumentResponse], limit, offset, total }`
(`limit`/`offset`/`total` are optional int64).

### 4.2 Search

`GET /instruments/search` → `200` `InstrumentListResponse`.

| Query param | Required | Notes |
|-------------|----------|-------|
| `q` | **yes** | Free-text, matched against symbol, name, CUSIP, and ISIN. |
| `limit` | no | Default 50, capped at 200. |
| `kinds` | no | Comma-separated kind keys. **Filtering is applied before the result cap**, so restricting kinds prevents equity/ETF tickers from crowding out a bond's CUSIP-derived symbol. Omitted searches the whole catalog. |

Search covers the entire catalog, not just tradable rows.

### 4.3 Instrument detail

`GET /instruments/{id}` (UUID) → `200` `InstrumentResponse`; `404` if not found.

| Field | Notes |
|-------|-------|
| `id`, `display_name`, `display_symbol`, `kind`, `currency` | Required. `kind` value set is not specified in the spec beyond the examples above. |
| `cusip`, `isin` | Nullable. |
| `tokenized` | **Required boolean.** True when a `GyldBondToken` contract exists. **Only tokenized instruments can complete the full deposit → mint flow.** |
| `token_address` | EVM address of the deployed token, if tokenized. |
| `token_id` | UUID of the token record — **this is the identifier `POST /redeem` and `GET /redeem/quote` take**, not `id`. |
| `tradable` | Required boolean. |
| `halted_for_new_mints` | **Required boolean — check it before quoting.** True when reconciliation has halted new mints for this instrument. |
| `fractionable`, `min_qty`, `tick_size` | Required. Order-sizing constraints. |
| `maturity_date`, `issue_date` | `YYYY-MM-DD`; null for ETFs and equities. |
| `coupon_rate` | Percentage string, e.g. `"4.25"`. Null for ETFs and zero-coupon. |
| `coupon_frequency` | Payments per year: 1 annual, 2 semi-annual, 4 quarterly, 12 monthly. Null where not captured. |
| `accrued_interest_pct` | Accrued interest as a percentage of face, as of today's settlement date. |
| `bid_usd`, `ask_usd` | Raw **clean** best bid/ask per $1 face. Present for Treasury and CorporateBond; absent for ETFs/equities. |
| `nav_bid_usd`, `nav_ask_usd`, `nav_mid_usd` | Clean price + accrued per unit. **The coupon pool index is *not* included here** — use `GET /invest/quote` for the full mint-time NAV. |
| `current_price_usd` | Null until the price oracle is live. |

### 4.4 Live quote

`GET /instruments/{id}/quote` → `200` `QuoteResponse`; `404` if not found.

| Field | Notes |
|-------|-------|
| `price` | **Required.** Mid price — per $1 face for bonds, per share for ETFs/equities. |
| `as_of` | **Required.** RFC 3339 sample time. Treat quotes as short-lived. |
| `bid`, `ask`, `bid_size`, `ask_size` | Clean prices per $1 face and available size in face-value USD. Absent for ETFs/equities. |
| `accrued_per_unit`, `pool_index` | NAV components. |
| `nav_price`, `nav_bid`, `nav_ask` | All-in NAV = clean + accrued + pool coupon index, per $1 face. Present for tokenized fixed income; absent for ETFs. |
| `ytm_bps` | Yield to maturity in basis points at the clean **ask**, **falling back to the clean mid when there is no ask leg**. `"491"` = 4.91%. Absent for non-maturing instruments or when NAV is unavailable. |
| `ytm_bid_bps`, `ytm_ask_bps` | Side yields with **no mid fallback** — absent whenever that side of the book is missing. Prefer these when you need a genuine side yield; `ytm_bps` can silently report a mid yield. |

### 4.5 Yield calculator

`GET /instruments/{id}/ytm?price=<decimal>` → `200` `YtmResponse`
`{ ytm_bps }`; `422` on an invalid price. Stateless, no side effects.

`price` is the all-in price per $1 face to value the bond at — e.g. `0.99` for
99% of par — typically the NAV limit you intend to submit.

⚠️ **Basis mismatch, by design.** This endpoint is **NAV-limit-based**, whereas
`QuoteResponse.ytm_bps` is computed on the **clean** price. The two figures are
**not directly comparable** — do not present them as the same measure.

### 4.6 Investment quote

`GET /invest/quote` → `200` `InvestQuoteResponse`. No side effects.

| Query param | Required | Notes |
|-------------|----------|-------|
| `cusip_or_isin` | yes | CUSIP (9 chars) or ISIN (12 chars). |
| `fiat_in` | yes | USD to invest, decimal string, e.g. `"1000.00"`. |

| Response field | Notes |
|----------------|-------|
| `cusip`, `fiat_in`, `qty_out` | `qty_out` is the face-value quantity the amount buys. |
| `ask_price` | Broker's quoted **clean** ask per unit (US bonds quote clean). |
| `accrued_per_unit` | Accrued interest per unit of face. Zero for non-coupon instruments. |
| `pool_index` | Cumulative coupon pool index per token. |
| `nav_per_unit` | **`= ask_price + accrued_per_unit + pool_index`.** This is the number to pass as `limit_price` on `POST /invest`. |
| `estimated_fees` | |
| `aum_fee_bps` | **Annual** management fee in basis points (`"37"` = 0.37%/yr), charged continuously on NAV — **not on this trade**. Already reflected in `nav_per_unit`. **Absent, not `"0"`, when no fee is configured** — "no fee" and "a 0 bps fee" are deliberately different statements. |
| `ytm_bps` | Yield at the clean ask, excluding accrued. Absent for non-maturing instruments. |

| Status | Meaning |
|--------|---------|
| `200` | Quote returned. |
| `422` | Validation error. |
| `503` | **Market closed.** |

---

## 5. Investing

### 5.1 Buy with broker USD

`POST /invest` — creates a broker-cash mint request. **Bonds only** (Treasury,
CorporateBond); **ETFs are not supported here.**

**Required header:** `idempotency-key` — a client-supplied UUID that makes the
call safe to retry. This is the only header parameter declared on any operation,
and it is mandatory.

| `InvestRequest` field | Required | Notes |
|----------------------|----------|-------|
| `cusip_or_isin` | yes | CUSIP (9) or ISIN (12). |
| `qty` | yes | **Face-value dollars** to purchase — `"2000"` means $2,000 of face value, not 2,000 tokens. |
| `limit_price` | yes | Limit price per $1 face. In this flow it is the **NAV per unit** (clean + accrued + coupon pool index), so `qty × limit_price` fully accounts for per-token value. Take it from `InvestQuoteResponse.nav_per_unit`. |
| `wallet_address` | yes | Destination for minted tokens; must be a registered source address. |

| Status | Meaning |
|--------|---------|
| `202` | Accepted. Body `InvestResponse` `{ mint_request_id }`. |
| `200` | **Idempotent replay** — duplicate `idempotency-key`; returns the *existing* `mint_request_id`. Distinguish `200` from `202` to know whether you created new work. |
| `422` | Insufficient funds. |
| `503` | **Market closed** (outside NYSE hours). Retry after the `Retry-After` header. |

This path gates against **broker USD** (`PortfolioResponse.broker_cash_usd`), not
on-platform USDC. If your funds are USDC, either use `POST /deposit/mint` or
convert first — see [§6](#6-currency-conversion).

### 5.2 Which buy path?

| | `POST /invest` | `POST /deposit/mint` |
|---|---|---|
| Funded by | Broker USD | Credited on-chain USDC |
| Sizing | `qty` (face value) × `limit_price` | `usdc_amount` |
| Pricing | **Limit** | **Market** |
| Idempotency header | **Required** | Not declared |
| Success status | `202` (or `200` on replay) | `201` |
| Feature-flagged | No | **Yes — `501` when disabled** |

---

## 6. Currency conversion

Two mirror-image endpoints bridge on-chain USDC and broker USD. Both are
asynchronous: they debit immediately, return a `pending` conversion id, and are
settled by a background worker.

Both **require** the `idempotency-key` header.

| | `POST /invest/convert-to-cash` | `POST /invest/convert-to-usdc` |
|---|---|---|
| Direction | USDC → broker USD | broker USD → on-chain USDC |
| Body | `ConvertToCashRequest` `{ usdc_amount }` e.g. `"500.00"` | `ConvertToUsdcRequest` `{ usd_amount }` e.g. `"500"` |
| Success | `202` `{ conversion_id, status }` — `status` is **always `"pending"`** | `202` `{ conversion_id, status }` — always `"pending"` |
| Failure | `422` validation error or insufficient USDC | `422` validation error or insufficient USD |
| Poll | `GET /invest/conversions/{id}` → `ConversionStatusResponse` | `GET /invest/usdc-conversions/{id}` → `UsdcConversionStatusResponse` |
| Poll response | `{ conversion_id, status, usdc_amount, reason? }` | `{ conversion_id, status, usd_amount, reason? }` |
| Poll `404` | Not found | Not found |

**Status values (the only fully enumerated lifecycle in the spec):**

| Status | Terminal | Notes |
|--------|----------|-------|
| `pending` | No | Keep polling. |
| `completed` | **Yes** | Funds credited. |
| `failed` | **Yes** | `reason` is populated **only** in this state. |

**Why `convert-to-usdc` exists:** redemption proceeds land as `usd`, which is
spendable at the broker but **not withdrawable on-chain**. Converting to USDC is
the required step before `POST /withdraw`.

---

## 7. Mint request lifecycle

Every buy — from either path — produces a **mint request**, an asynchronous
object driven through a state machine by Gyld.

| Operation | Result |
|-----------|--------|
| `GET /mint/requests` | `200` — list. ⚠️ **No response schema in the spec.** |
| `GET /mint/requests/{id}` | `200` `MintRequestResponse`; `404`. |
| `POST /mint/requests/{id}/cancel` | `204` \| `404` \| `409` |
| `POST /mint/requests/{id}/retry` | `200` `MintRequestResponse` \| `404` \| `409` |

### `MintRequestResponse`

| Field | Notes |
|-------|-------|
| `id`, `created_at`, `updated_at`, `amount_usd` | Required. |
| `status` | **Required.** Machine-readable `snake_case` key, e.g. `"awaiting_order_fill"`. |
| `current_stage` | Required. Human-readable label — for display, not logic. |
| `history` | Required array of `{ stage, at? }`, ordered, may be empty. `at` is null for stages predating per-stage tracking. |
| `fee`, `deposit_tx`, `mint_tx` | Nullable. |
| `failure` | `MintFailureDetail` `{ step?, message? }` or null. Non-null only when `status == "failed"`. |
| `block_reason` | Non-null only when `status == "blocked"`. |

### Statuses referenced in the spec

⚠️ **`status` is typed as a bare `string`; there is no enum.** The values below
are the ones the spec's prose mentions, and the list may be incomplete.
The wire format is `snake_case` (the prose uses PascalCase).

| Status | Wire form (inferred) | Terminal | Cancellable | Retryable |
|--------|---------------------|----------|-------------|-----------|
| Accepted | `accepted` | No | Yes | No |
| ScreeningEntry | `screening_entry` | No | Yes | No |
| AwaitingOrderFill | `awaiting_order_fill` | No | Only while the order rests **unfilled** | No |
| Minted | `minted` | **Yes** | No | No |
| Failed | `failed` | Yes (until retried) | No | Yes, if nothing irreversible happened |
| Blocked | `blocked` | Yes | No | **No** — compliance review |
| Cancelled | `cancelled` | **Yes** | No | No |

**Do not hardcode this table.** Instead, use the server-computed booleans the API
gives you (see [§11](#11-polling-and-terminal-states)) and treat unknown status
strings as non-terminal.

### Cancellation

`POST /mint/requests/{id}/cancel` is permitted while the request is in
`Accepted`/`ScreeningEntry` (before the buy order is placed), or in
`AwaitingOrderFill` **while the order is resting unfilled** at the broker.

`204` **records intent, it does not guarantee cancellation.** The background
driver's next tick makes the authoritative decision from its own fresh read of
the broker order, and decides whether to tear down and land `Cancelled`. After
`204`, keep polling until the status actually changes.

Once any fill has landed, or tokens have been minted, cancellation is
impossible. The endpoint checks this eagerly and returns `409` rather than
recording intent the driver would ignore.

`409` covers **three distinguishable causes**, each with distinct message text:

1. The request is in a state that cannot be cancelled at all (already terminal).
2. Value has already moved (tokens minted / order filled).
3. A cancellation was already requested.

⚠️ Since no error body schema is specified, these can only be told apart by
free-text message. **A machine-readable discriminator is not specified in the
spec (confirm with the API team).**

### Retry

`POST /mint/requests/{id}/retry` is allowed **only** from `Failed`, and only
before anything irreversible happened: no tokens minted, no mint transaction,
and any linked buy order never filled. The request resets to `Accepted` with
failure bookkeeping cleared, and a resting unfilled order is best-effort
cancelled first so the retry places a fresh one.

Two traps:

- **A stale NAV quote will fail again.** A broker-cash mint whose quote has aged
  past 300 s fails at order placement by design. Retrying does not re-price it —
  submit a **fresh `POST /invest`** at a current price instead. Mints are
  fail-and-resubmit; they never re-price in place.
- **`Blocked` mints are rejected here** (`409`) — that is compliance territory.

---

## 8. Redemption

### 8.1 Quote

`GET /redeem/quote` → `200` `RedeemQuoteResponse`; `422` on validation error.

| Query param | Required | Notes |
|-------------|----------|-------|
| `token_id` | yes | The token UUID (`InstrumentResponse.token_id` / `PositionView.token_id`). |
| `qty` | yes | |
| `price_usd` | no | Optional price-per-unit hint; see `RedeemRequest.price_usd`. |

| Response field | Notes |
|----------------|-------|
| `token_id`, `qty` | |
| `clean_price` | Clean bid/market price per unit used in the NAV calculation. |
| `accrued_per_unit`, `pool_index` | NAV components. |
| `nav_per_unit` | `= clean_price + accrued_per_unit + pool_index`. |
| `estimated_fee` | **Estimated.** The final fee is confirmed at execution. |
| `fiat_out` | Net USDC payout after fees. |
| `expected_settlement_days` | int32. |
| `aum_fee_bps` | Annual management fee, disclosure only — see [§4.6](#46-investment-quote). Absent, not `"0"`, when unconfigured. |
| `ytm_bps` | Yield at the clean **bid**, excluding accrued. Absent for non-maturing instruments. |

### 8.2 Create

`POST /redeem` → `201` `RedeemResponse`.

| `RedeemRequest` field | Required | Notes |
|----------------------|----------|-------|
| `token_id` | yes | |
| `qty` | yes | |
| `wallet_address` | conditional | **Required when you have more than one registered source address on the token's chain**; optional and inferred for the single-address case. |
| `price_usd` | no | Price-per-unit hint, used when the broker price API is unavailable in development/sandbox. **Ignored in production** when the broker returns a live quote. |

`RedeemResponse` = `{ redemption_id, status, fee }` — `status` is always
`"accepted"` on success; `fee` is in USD, snapshotted at acceptance.

| Status | Meaning |
|--------|---------|
| `201` | Accepted. |
| `403` | **KYC not approved.** |
| `422` | Validation error. |

⚠️ **No `idempotency-key` header is declared on this endpoint**, even though it
moves value. See [§12](#12-idempotency).

### 8.3 Confirm — required to proceed

`POST /redeem/{id}/confirm` → `200` `RedemptionStatusResponse`.

A new redemption sits in `PendingConfirmation` and **does not progress until you
confirm it.** Confirmation is also how you retry a `Failed` redemption:
re-confirming clears the failure and retries with the new limit price. On success
the request moves to `Accepted` and the driver picks it up.

Body (declared inline; identical in shape to the unreferenced
`ConfirmRedeemRequest` schema):

| Field | Required | Notes |
|-------|----------|-------|
| `limit_price_usd` | **yes** | Minimum sell price in USD, decimal string. **Required by design** — an omitted price would silently fall back to a market-order sell and fail the whole redemption later if the broker has no live quote. |

| Status | Meaning |
|--------|---------|
| `200` | Confirmed. |
| `403` | KYC not approved. |
| `404` | Not found. |
| `422` | Missing or invalid `limit_price_usd`. |

**Redemptions re-price on confirm; mints do not.** This asymmetry is
intentional — see `HistoryEntry.price_adjustable`.

### 8.4 Cancel

`POST /redeem/{id}/cancel` → `204` \| `404` \| `409`.

Allowed in `PendingConfirmation`/`Accepted` (before selling starts) —
transitioning straight to `AwaitingTokenReturn` — and also in `Screening` while
the sell order rests unfilled at the broker. As with mints, `204` in the
`Screening` case **records intent only**; the driver's next tick decides
authoritatively from its own read of the order.

Once any fill has landed, cancellation is impossible and the endpoint returns
`409` eagerly. `409` covers three causes with distinct message text: wrong state
(already past `Screening`), the sell order already has a fill (too late — the
redemption proceeds to settlement), or a cancellation was already requested.

### 8.5 Status

`GET /redeem/{id}` → `200` `RedemptionStatusResponse`; `404`.

| Field | Notes |
|-------|-------|
| `id`, `created_at`, `quantity` | Required. |
| `status` | **Required.** `snake_case` machine-readable key. |
| `current_stage` | Required human-readable label. |
| `history` | Required array of `{ stage, at? }`; contains at least a `submitted` entry. |
| `failure` | Non-null only when `status == "failed"`. |
| `fill_price`, `burn_tx`, `payout_tx` | Nullable. |

### Redemption statuses referenced in the spec

⚠️ Again, `status` is a bare `string` with no enum. Values mentioned in prose:

| Status | Terminal | Notes |
|--------|----------|-------|
| `PendingConfirmation` | No | **Requires `POST /redeem/{id}/confirm` to advance.** Cancellable. |
| `Accepted` | No | Driver will start selling. Cancellable. |
| `Screening` | No | Cancellable **only while the sell order is unfilled**. |
| `AwaitingTokenReturn` | No | Reached after a successful cancel, or as part of settlement. |
| `Failed` | Yes, until re-confirmed | Retry via `confirm` with a new limit price. |

⚠️ The spec does **not** name the successful terminal state of a redemption (the
analogue of a mint's `minted`). **Not specified in the spec (confirm with the API
team).**

---

## 9. Withdrawal

`POST /withdraw` → `201` `WithdrawRequestResponse`.

Validates the withdrawal address and balance, debits your cash balance, and
creates the request in `Accepted`.

| `PostWithdrawRequest` field | Required |
|----------------------------|----------|
| `amount` | yes |
| `chain` | yes |

| Status | Meaning |
|--------|---------|
| `201` | Created. |
| `422` | Insufficient funds or validation error. |

**Preconditions — all three, in order:**

1. A withdrawal address is set via `PUT /me/withdrawal-address` and was **not**
   blocked by sanctions screening.
2. Sufficient **`usdc`** available balance on that chain (`GET /cash-balance`).
   `usd` balances are **not** withdrawable — convert with
   `POST /invest/convert-to-usdc` first.
3. The destination is the stored withdrawal address. ⚠️ The request body has no
   destination field — **funds go to the stored address, and there is no way to
   override it per request.** This is the whole point of the allowlist.

`GET /withdraw/{id}` → `200` `WithdrawRequestResponse`; `404`. The caller must be
the owner.

| `WithdrawRequestResponse` field | Notes |
|--------------------------------|-------|
| `id` (uuid), `user_id` (uuid), `amount`, `chain`, `created_at` | Required. |
| `destination` | Required — the resolved payout address. **Verify it matches what you set.** |
| `status` | Required. ⚠️ Value set and terminal states **not specified in the spec**; only the initial `Accepted` is mentioned. |
| `fee`, `transfer_tx` | Nullable. `transfer_tx` appearing is the practical signal that funds have left. |

⚠️ **No `idempotency-key` header is declared on this endpoint.** See
[§12](#12-idempotency).

---

## 10. Portfolio and history

### 10.1 Holdings

`GET /portfolio` → `200` `PortfolioResponse`.

| Field | Notes |
|-------|-------|
| `nav_total` | Total portfolio NAV. |
| `positions` | `[PositionView]` — the main holdings view. |
| `token_holdings` | `[{ token_id, wallet_address, amount }]`. |
| `usdc_balances` | `[{ chain, available }]`. |
| `fiat_balance` | On-platform USDC. |
| `broker_cash_usd` | **USD at the omnibus custodian attributable to you. This is what `POST /invest` gates against** — distinct from `fiat_balance`. |
| `platform_wallet_usdc` | USDC at the platform custodian wallet, not yet swept to the broker. Available to back a new mint request. |
| `active_mints` | `[{ id, token_id, amount_usd, status, created_at }]`. |
| `active_redemptions`, `recent_redemptions` | `[ActiveRedemptionView]`. |

**Four different cash figures appear here** — `fiat_balance`,
`broker_cash_usd`, `platform_wallet_usdc`, and `GET /cash-balance`. They are not
duplicates. Use `broker_cash_usd` to decide whether `POST /invest` can succeed,
and `GET /cash-balance` (`currency: "usdc"`) for withdrawal capacity.

`PositionView`:

| Field | Notes |
|-------|-------|
| `instrument_id`, `token_id`, `token_address` | `token_id` is the identifier **redeem operations take**. |
| `display_name`, `display_symbol`, `cusip` | |
| `quantity` | Tokens credited to you and available for redemption. |
| `wallet_address` | Wallet holding the tokens. |
| `cost_basis` | USDC invested, weighted to remaining quantity. `null` when no completed mints exist. |
| `market_value`, `priced_at`, `unrealized_pnl` | `unrealized_pnl = market_value − cost_basis`; `null` when either is unavailable. |
| `coupon_rate`, `maturity_date` | **Omitted, never `"0"`/placeholder**, for ETFs, zero-coupon bills, and unresolvable instruments — absence is meaningful. |

`ActiveRedemptionView`:

| Field | Notes |
|-------|-------|
| `id`, `status`, `amount`, `created_at`, `updated_at` | Required. |
| `cancellable` | **Server-computed** — true while `POST /redeem/{id}/cancel` would succeed. Drive your UI off this, not off a status string. |
| `cancel_requested_at` | Set once cancellation was requested while `Screening`. Render "cancelling…" and keep polling. |
| `token_id` | For `GET /redeem/quote`. `null` on legacy rows that predate the field. |
| `display_symbol`, `failure` | Nullable. |

### 10.2 History

`GET /portfolio/history` → `200` `HistoryResponse`
`{ entries, total, offset, limit? }`.

| Query param | Notes |
|-------------|-------|
| `from`, `to` | Inclusive calendar bounds. Accepts bare `YYYY-MM-DD` **or** an RFC 3339 datetime. Any time component is **discarded**: `from` expands to `00:00:00Z`, `to` to `23:59:59.999Z` — so a `to` date includes everything later that same day. |
| `type` | One of `mint`, `redemption`, `bond_purchase`, `bond_sale`, `coupon`, `fee`, `transfer`, `swap`, `pool_activity`, `token_return`, `nav_update`, `other`. |
| `limit` | **When omitted, the endpoint returns *every* matching row** — deliberately unbounded for non-paging clients. When set, clamped to 1–250. |
| `offset` | Default 0. **Ignored when `limit` is omitted.** |
| `view` | Pass `view=investor` to collapse each mint/redemption workflow into a single row (hiding internal lifecycle steps) and to surface on-chain atomic swaps. When absent, every ledger row is returned. |

`total` is always the **filtered count across all pages**, never the page
length. `limit` is echoed as `null` when the request omitted it.

⚠️ Note `type` accepts `swap` but the `entry_type` field's own documented value
list omits `swap`. **This inconsistency is unresolved in the spec (confirm with
the API team).**

`GET /portfolio/history/{id}` → `200` `HistoryEntry`; `404` not found; `422`
malformed id.

`HistoryEntry` has 30 fields. The ones that matter most:

| Field | Notes |
|-------|-------|
| `id` | Ledger entry id. **Synthetic operation rows use `"mint:{uuid}"` / `"redemption:{uuid}"`** so they can never collide with a real ledger id. Do not assume `id` is a bare UUID. |
| `entry_type`, `description` | Machine-readable type and human-readable text. |
| `occurred_at`, `recorded_at` | When it happened externally vs. when Gyld recorded it. These differ. |
| `amount`, `currency`, `qty`, `price_per_token` | Decimal strings; nullable. |
| `fee_amount`, `fee_currency` | Fee **merged in** from the linked fee row. `null` when no fee is linked — the fee then stands as its own `entry_type: "fee"` row. |
| `request_id`, `request_kind` | `request_kind` is `"mint"` \| `"redemption"`. `request_id` is the key for the detail endpoints and the action endpoints. |
| `status` | Present only for rows representing a live or attention-needing operation. **`null` for pure ledger rows** — those are historical facts, implicitly done. |
| `cancellable`, `retryable`, `confirmable`, `cancel_requested`, `price_adjustable` | Server-computed action flags — see [§11](#11-polling-and-terminal-states). |
| `tx_hash`, `chain_id` | On-chain reference. `chain_id` is `null` whenever `tx_hash` is `null`. |
| `nav_limit_price`, `limit_price`, `accrued_at_event`, `index_at_event`, `market_at_event` | NAV decomposition: `nav_limit_price ≈ limit_price + accrued_at_event + index_at_event`, where `limit_price` is the **clean** price sent to the broker. `nav_limit_price` is carried at full stored precision, never rounded, so the conversion can be verified to the last decimal. |
| `fill_price`, `fill_qty`, `limit_qty` | Broker fill data; `null` for non-bond and legacy rows. |
| `external_ref` | Stable cross-system key for audit traceability. |

---

## 11. Polling and terminal states

Every money-moving operation in this API is **asynchronous**. You create a
request object, then poll it.

| Flow | Create | Poll | Signal of completion |
|------|--------|------|----------------------|
| Deposit | send USDC on-chain | `GET /deposit/pending` → `GET /cash-balance` | Entry leaves `pending`; balance appears |
| Buy (broker USD) | `POST /invest` | `GET /mint/requests/{id}` | `status == "minted"`, `mint_tx` set |
| Buy (USDC) | `POST /deposit/mint` | `GET /mint/requests/{id}` | as above |
| USDC → USD | `POST /invest/convert-to-cash` | `GET /invest/conversions/{id}` | `status ∈ {completed, failed}` |
| USD → USDC | `POST /invest/convert-to-usdc` | `GET /invest/usdc-conversions/{id}` | `status ∈ {completed, failed}` |
| Redeem | `POST /redeem` → `POST /redeem/{id}/confirm` | `GET /redeem/{id}` | `payout_tx` set (⚠️ terminal status name not specified in the spec) |
| Withdraw | `POST /withdraw` | `GET /withdraw/{id}` | `transfer_tx` set (⚠️ terminal status set not specified) |

### The right way to drive a client

⚠️ **Only the conversion endpoints have a fully enumerated status set**
(`pending` / `completed` / `failed`). Mint, redemption, KYC, and withdrawal
statuses are bare `string`s whose values appear only in prose, and **no field
marks a status as terminal.**

So do not branch on status strings. Branch on the **server-computed booleans**,
which exist precisely so clients don't have to model the state machine:

| Flag | Source | Meaning |
|------|--------|---------|
| `cancellable` | `HistoryEntry`, `ActiveRedemptionView` | The cancel endpoint would succeed right now. |
| `retryable` | `HistoryEntry` | Retry is permitted — set only when the "nothing irreversible" safety gate passes. |
| `confirmable` | `HistoryEntry` | This redemption is in `PendingConfirmation` and needs confirming. |
| `cancel_requested` | `HistoryEntry` | Intent recorded, driver has not yet honoured or ignored it. Render "cancelling…". |
| `price_adjustable` | `HistoryEntry` | The confirm/retry action accepts a new limit price (redemptions only). |

**These flags are advisory and race with the driver.** The spec is explicit: the
action endpoints re-check authoritatively, and *"a fill landing between render
and click yields `409`"*. Treat `409` as a normal, expected outcome — refresh and
re-read, do not surface it as an error.

Recommended polling discipline (⚠️ **no polling interval, rate limit, or
long-polling mechanism is specified in the spec** — confirm with the API team):

1. Poll with exponential backoff, not a tight loop.
2. Treat any unrecognised `status` value as **non-terminal** and keep polling —
   the value set is not closed.
3. Stop on an explicit terminal signal, or on your own timeout.
4. Never infer success from the absence of a failure field.

---

## 12. Idempotency

`idempotency-key` is a **required** header on exactly three operations, and is
**not declared on any other** — including several that move money.

| Money-moving POST | `idempotency-key` | Replay behaviour |
|-------------------|-------------------|------------------|
| `POST /invest` | **Required** | `200` returns the existing `mint_request_id`; `202` means newly created |
| `POST /invest/convert-to-cash` | **Required** | Not specified in the spec |
| `POST /invest/convert-to-usdc` | **Required** | Not specified in the spec |
| `POST /redeem` | ⚠️ **Not declared** | Not specified in the spec |
| `POST /withdraw` | ⚠️ **Not declared** | Not specified in the spec |
| `POST /deposit/mint` | ⚠️ **Not declared** | Not specified in the spec |
| `POST /redeem/{id}/confirm` | ⚠️ **Not declared** | Not specified in the spec |
| `POST /mint/requests/{id}/retry` | ⚠️ **Not declared** | Not specified in the spec |
| `POST /register` | ⚠️ **Not declared** | `409` on duplicate email is effectively idempotent |

⚠️ **This is a blocker for any at-least-once client.** Until the API team
confirms otherwise, assume that a retried `POST /redeem`, `POST /withdraw`, or
`POST /deposit/mint` may **duplicate** the operation. Mitigations:

- Never blind-retry these on a network timeout. Reconcile first: list the
  relevant request objects and check whether your intent already landed.
- Persist your own client-side request key *before* the call, so a crash can be
  reconciled after the fact.
- Only `POST /me/api-keys` … `DELETE`, `POST /me/resend-verification-email`, and
  `POST /me/email-otp/enroll` are documented as idempotent.

Where the key **is** required, the spec says "client-supplied UUID". Reuse of the
same key with a *different* body is **not specified in the spec** — do not rely
on any particular behaviour.

---

## 13. Market clock

`GET /market/clock` → `200` `MarketClockResponse`.

| Field | Notes |
|-------|-------|
| `is_open` | Boolean. |
| `next_open` | RFC 3339 UTC timestamp of the next scheduled open. |
| `next_close` | RFC 3339 UTC timestamp of the next scheduled close. |

Two operations return `503` when the market is closed: `GET /invest/quote` and
`POST /invest` (which additionally sets `Retry-After`). Check the clock before
attempting a buy, and schedule retries against `next_open` rather than polling
blindly.

⚠️ Which calendar this reflects (`POST /invest`'s `503` cites NYSE hours) and
whether half-days and holidays are covered is **not fully specified in the spec**.

---

## 14. Complete operation reference

Auth key: **B** = `bearerAuth`, **H** = `hmacApiKey`, **—** = none.

| Method | Path | Auth | Success | Errors |
|--------|------|------|---------|--------|
| POST | `/register` | **—** | 201 | 403, 409, 500 |
| POST | `/kyc/start` | B, H | 201 | 401, 422 |
| GET | `/kyc/status` | B, H | 200 | 401 |
| GET | `/kyc/documents` | B, H | 200 | 401, 404 |
| GET | `/kyc/documents/{doc_id}` | B, H | 200 | 401, 403, 404 |
| GET | `/me` | B, H | 200 | 401 |
| PATCH | `/me/profile` | B, H | 204 | 401, 422 |
| POST | `/me/resend-verification-email` | B, H | 204 | 401 |
| POST | `/me/email-otp/enroll` | B, H | 204 | 401, 422 |
| GET | `/me/api-keys` | **B only** | 200 | 401 |
| POST | `/me/api-keys` | **B only** | 201 | 401, 422 |
| DELETE | `/me/api-keys/{key_id}` | **B only** | 204 | 401, 404 |
| POST | `/me/source-addresses` | B, H | 204 | 401, 422 |
| DELETE | `/me/source-addresses/{address}` | B, H | 204 | 401 |
| PUT | `/me/withdrawal-address` | B, H | 204 | 401, 422 |
| GET | `/org/members` | B, H | 200 | 401 |
| GET | `/deposit/address` | B, H | 200 | 401 |
| GET | `/deposit/pending` | B, H | 200 | 401 |
| POST | `/deposit/mint` | B, H | 201 | 401, 422, **501** |
| GET | `/cash-balance` | B, H | 200 | 401 |
| GET | `/instruments` | B, H | 200 | 401 |
| GET | `/instruments/search` | B, H | 200 | 401 |
| GET | `/instruments/{id}` | B, H | 200 | 401, 404 |
| GET | `/instruments/{id}/quote` | B, H | 200 | 401, 404 |
| GET | `/instruments/{id}/ytm` | B, H | 200 | 401, 422 |
| GET | `/invest/quote` | B, H | 200 | 401, 422, **503** |
| POST | `/invest` | B, H | **202** / 200 replay | 401, 422, **503** |
| POST | `/invest/convert-to-cash` | B, H | 202 | 401, 422 |
| GET | `/invest/conversions/{id}` | B, H | 200 | 401, 404 |
| POST | `/invest/convert-to-usdc` | B, H | 202 | 401, 422 |
| GET | `/invest/usdc-conversions/{id}` | B, H | 200 | 401, 404 |
| GET | `/mint/requests` | B, H | 200 | 401 |
| GET | `/mint/requests/{id}` | B, H | 200 | 401, 404 |
| POST | `/mint/requests/{id}/cancel` | B, H | 204 | 401, 404, 409 |
| POST | `/mint/requests/{id}/retry` | B, H | 200 | 401, 404, 409 |
| GET | `/redeem/quote` | B, H | 200 | 401, 422 |
| POST | `/redeem` | B, H | 201 | 401, **403**, 422 |
| GET | `/redeem/{id}` | B, H | 200 | 401, 404 |
| POST | `/redeem/{id}/confirm` | B, H | 200 | 401, **403**, 404, 422 |
| POST | `/redeem/{id}/cancel` | B, H | 204 | 401, 404, 409 |
| POST | `/withdraw` | B, H | 201 | 401, 422 |
| GET | `/withdraw/{id}` | B, H | 200 | 401, 404 |
| GET | `/portfolio` | B, H | 200 | 401 |
| GET | `/portfolio/history` | B, H | 200 | 401 |
| GET | `/portfolio/history/{id}` | B, H | 200 | 401, 404, 422 |
| GET | `/market/clock` | B, H | 200 | 401 |

Full status-code semantics are in [`errors.md`](errors.md).

---

## 15. Known spec gaps

Everything below is a gap in the specification itself. Each needs an answer from
the API team before a third party can integrate reliably.

| # | Gap | Impact |
|---|-----|--------|
| 1 | **No login / token / refresh endpoint.** `bearerAuth` is required to create API keys, but nothing issues a JWT. | **Blocking.** Credentials cannot be bootstrapped. |
| 2 | `hmacApiKey` declares only `GYLD-ACCESS-KEY`; `-TIMESTAMP` and `-SIGN` are prose-only. | Generated clients send unsigned requests. |
| 3 | No per-operation scope requirements; no insufficient-scope status code. | Cannot provision least-privilege keys. |
| 4 | **No error response body schema on any of the ~100 error responses.** | Failures cannot be parsed programmatically; `409` sub-causes are distinguishable only by free text. |
| 5 | Mint / redemption / KYC / withdrawal `status` are bare `string`s; no enum, no terminal-state marker. | Polling clients must guess. Redemption's success state is unnamed. |
| 6 | `POST /kyc/start` — `multipart/form-data` with **no schema at all**. | Endpoint is uncallable from the spec. |
| 7 | Five `200` responses have **no schema**: `GET /deposit/pending`, `/kyc/documents`, `/me`, `/me/api-keys`, `/mint/requests`. | Response bodies undocumented. |
| 8 | `ConfirmRedeemRequest` and `PendingDepositItem` are defined but referenced by no operation. | Suggests drift between spec and implementation. |
| 9 | `idempotency-key` required on 3 endpoints, absent on `POST /redeem`, `/withdraw`, `/deposit/mint`, `/redeem/{id}/confirm`, `/mint/requests/{id}/retry`. | Unsafe retries on money movement. |
| 10 | **No `429` documented anywhere**, and no rate-limit headers, despite `ApiKeyResponse.rate_tier`. | Clients cannot back off correctly. |
| 11 | `GET /deposit/address` returns a `chain` but takes no parameter to select one. | Multi-chain behaviour unclear. |
| 12 | `chain_id` format on the address endpoints (numeric vs. slug) is unstated. | Requests may be rejected. |
| 13 | `GET /portfolio/history?type=swap` is accepted, but `swap` is missing from the documented `entry_type` values. | Inconsistent enumeration. |
| 14 | `POST /deposit/mint` is feature-flagged **off by default** (`501`). | May be unavailable in your environment. |
| 15 | `CreateApiKeyBody` — default `scopes` when omitted, `ip_allowlist` format, and `rate_tier` semantics unstated. | Cannot provision keys predictably. |
| 16 | HMAC canonicalisation edge cases (port, trailing slash, query ordering, encoding) point to an internal document. | Signature mismatches. |
| 17 | No pagination on `GET /mint/requests`, `/deposit/pending`, `/kyc/documents`, `/me/api-keys`, `/org/members`. | Unbounded responses at scale. |
| 18 | `license` is `UNLICENSED`; no terms of use, versioning, or deprecation policy. | No contract stability guarantee. `v0.1.0` implies breaking change is likely. |
