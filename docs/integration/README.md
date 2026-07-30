# Gyld Third-Party Integration Guide

Gyld is a tokenized fixed-income platform. Each bond token is backed 1:1 by a
security held at a regulated broker; investors can buy, hold, and redeem
tokenized treasury bills, corporate bonds, and bond ETFs.

There are **two** integration surfaces, and they are not alternatives to each
other — they solve different problems. Read the decision guide below before
writing any code.

| Document | Surface | Status |
|----------|---------|--------|
| [`rest-api.md`](rest-api.md) | Gyld Investor REST API (HTTPS/JSON) | Live on the development host |
| [`onchain-atomic-swap.md`](onchain-atomic-swap.md) | `GyldAtomicSwap` EIP-712 settlement contract | **Not deployed to any public network** |
| [`errors.md`](errors.md) | Consolidated error reference for both surfaces | — |

---

## Which surface do I need?

| If you want to… | Use | Why |
|-----------------|-----|-----|
| Onboard an investor, run KYC, hold a fiat/USDC balance on Gyld's books | REST API | Identity, custody, and compliance state live entirely off-chain. There is no on-chain equivalent. |
| Buy a bond with USD held at the broker, or with USDC you deposited to Gyld | REST API (`POST /invest`, `POST /deposit/mint`) | These create a *mint request* — a broker order plus a token mint, driven asynchronously by Gyld. |
| Redeem tokens back to cash through Gyld | REST API (`POST /redeem`) | Redemption sells the underlying at the broker; only Gyld can initiate that. |
| Withdraw USDC to your own wallet | REST API (`POST /withdraw`) | Requires an allowlisted, sanctions-screened withdrawal address. |
| Read prices, yields, instrument metadata, portfolio, market hours | REST API | No on-chain price surface is exposed to third parties. |
| Swap USDC ↔ bond tokens atomically, in one transaction, from your own wallet | `GyldAtomicSwap` | Single-transaction settlement against a Gyld-signed quote, with no custody handoff and no async request object to poll. |

**The short version:** the REST API is the whole platform. `GyldAtomicSwap` is a
narrow, high-performance settlement path for a counterparty that already holds
USDC or bond tokens in its own wallet and wants atomic execution instead of an
asynchronous mint or redemption request. Almost every integrator needs the REST
API; only a wallet-holding trading counterparty needs the contract.

**They share a compliance boundary.** Both require Gyld to have approved you
first: the REST API gates on KYC status, and the contract gates on an on-chain
taker allowlist that Gyld's compliance operators control. Neither is
permissionless.

---

## Onboarding checklist

Work through this in order. Steps 1–4 are prerequisites for everything else.

1. **Get your email pre-approved by Gyld operations.** `POST /register` returns
   `403` for an email that has not been pre-approved. Registration is not open
   self-service.
2. **Register the account** — `POST /register` with `{email, password}`. This is
   the only unauthenticated endpoint in the API. Returns `user_id`.
3. **Obtain a bearer JWT.** ⚠️ **Blocker — the API spec contains no
   login or token endpoint.** See [blocker 1](#blockers) below. You cannot
   complete this step from the published spec alone; ask the API team how a JWT
   is issued.
4. **Mint an API key** — `POST /me/api-keys`, authenticated with the JWT from
   step 3. This is the *only* way to get HMAC credentials, and it accepts the
   JWT scheme only: **an HMAC key cannot mint or rotate itself.** Capture the
   `secret` from the response — it is returned exactly once and never again.
5. **Complete KYC** — `POST /kyc/start` (document upload), then poll
   `GET /kyc/status` until approved. `POST /redeem` and
   `POST /redeem/{id}/confirm` return `403` until KYC is approved.
6. **Fill in the investor profile** — `PATCH /me/profile`. Merge semantics: only
   the fields you send are overwritten.
7. **Register a source wallet address** — `POST /me/source-addresses`. Every
   address is sanctions-screened before it is stored. You need one before you
   can deposit USDC or receive minted tokens.
8. **Set a withdrawal address** — `PUT /me/withdrawal-address`. Also screened.
   Required before `POST /withdraw` will succeed.
9. **Fund the account** — `GET /deposit/address`, send USDC from a registered
   source address, then watch `GET /deposit/pending` until the deposit
   confirms and `GET /cash-balance` reflects it.
10. **Verify your email if you intend to use email one-time-passcodes** —
    `POST /me/resend-verification-email`, then `POST /me/email-otp/enroll`.
    Enrolment returns `422` while the email is unverified.

**For the on-chain surface, additionally:**

11. **Ask Gyld to allowlist your taker address on `GyldAtomicSwap`.** Calls from
    a non-allowlisted address revert with `NotAllowed(address)`. Allowlisting is
    a manual compliance action by a Gyld operator.
12. **Approve `GyldAtomicSwap`** (not any vault — there isn't one) to spend the
    token you intend to pay with, or supply an EIP-2612 permit.

---

## Conventions used across both surfaces

| Convention | Detail |
|------------|--------|
| Monetary amounts (REST) | **Decimal strings**, never JSON numbers — e.g. `"1000.00"`, `"4.25"`. This avoids float rounding. Parse them with a decimal library, not a double. |
| Monetary amounts (on-chain) | Native integer base units. USDC is 6 decimals; `GyldBondToken` is 18 decimals. |
| Identifiers (REST) | UUID strings. Some are typed `string(uuid)` in the spec and some plain `string`; treat all as opaque. |
| Timestamps (REST) | RFC 3339 / ISO 8601 UTC strings. `GET /portfolio/history` additionally accepts bare `YYYY-MM-DD` on its `from`/`to` filters. |
| Timestamps (on-chain) | Unix seconds, `uint64`. |
| Prices per unit | Bonds are quoted **per $1 of face value**. `0.99` means 99% of par. |
| Clean vs. all-in price | Bond market prices are *clean* (excluding accrued interest). The all-in **NAV** you actually transact at is `clean price + accrued interest + coupon pool index`. Yield-to-maturity figures are quoted on the clean price by convention. Do not compare a NAV to a YTM basis. |

---

## Blockers

These must be resolved before this documentation is published externally. Each
is a gap in the source of truth, not a documentation choice.

1. **No login or token endpoint exists in the API spec.** The spec states that
   `bearerAuth` is "a Keycloak-issued token", and three endpoints
   (`/me/api-keys`) accept *only* that scheme — but no operation in the spec
   issues, refreshes, or exchanges a JWT. Combined with the fact that an HMAC
   key cannot mint another key, a third party who has only followed the spec
   cannot bootstrap credentials at all. This is the single hardest blocker.
2. **HMAC signing is not machine-readable.** The `hmacApiKey` security scheme
   declares only the `GYLD-ACCESS-KEY` header, because OpenAPI's `apiKey` type
   is single-header. `GYLD-ACCESS-TIMESTAMP` and `GYLD-ACCESS-SIGN` appear in
   prose only, so any generated client will emit unsigned, rejected requests.
3. **Scopes are not mapped to operations.** `read`, `trade`, and `withdraw` are
   defined, but no operation declares which scope it requires, and no operation
   documents the status code returned when a scope is missing. Integrators
   cannot provision a least-privilege key from the spec.
4. **No error response body is specified anywhere.** All ~100 error responses in
   the spec are description-only with no schema. Clients cannot parse failures
   programmatically.
5. **Lifecycle status values are not enumerated.** Mint, redemption, KYC, and
   withdrawal statuses are typed as bare `string`. The values appear only inside
   prose descriptions, and no field marks which states are terminal — the exact
   information a polling client needs.
6. **Idempotency is declared on three money-moving endpoints and omitted on the
   rest.** See the [idempotency table](rest-api.md#12-idempotency).
7. **`POST /kyc/start` has no request schema at all** — `multipart/form-data`
   with an empty content object. The endpoint cannot be called from the spec.
8. **Five successful responses have no schema**, so the response body is
   undocumented. See the [spec gaps table](rest-api.md#15-known-spec-gaps).
9. **No rate-limit contract.** API keys carry a `rate_tier`, but no endpoint
   documents `429` or any rate-limit headers.
10. **`GyldAtomicSwap` public testnet deployment is in progress (Sepolia).**
    The ERC-8056 / atomic-swap stack is being deployed to **Ethereum Sepolia
    (chainId 11155111)** — the single supported public testnet for integrator
    testing — but no addresses are published yet, so there is still no shared
    network for an integrator to test against today. See the
    [address table](onchain-atomic-swap.md#2-contract-addresses).
11. **The EIP-712 domain version is `"2"`, not `"1"`.** Any integration brief or
    client stub that hardcodes `"1"` will produce a digest that fails signature
    recovery. Confirm the intended value before publication.
