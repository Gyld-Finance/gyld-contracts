# On-Chain Integration — `GyldAtomicSwap`

`GyldAtomicSwap` settles a two-leg token swap atomically, in one transaction,
against a **platform-signed EIP-712 quote**. It is the on-chain alternative to
the REST API's asynchronous mint and redemption requests: you hold the tokens in
your own wallet, Gyld signs a quote off-chain, and you execute it yourself.

| | |
|---|---|
| Source | [`contracts/GyldAtomicSwap.sol`](../../contracts/GyldAtomicSwap.sol) |
| Licence | **BUSL-1.1** (Business Source License 1.1) — see [§12](#12-licence) |
| Solidity | `=0.8.28` (exact pin) |
| Upgradeability | UUPS proxy — **integrate against the proxy address**, never the implementation |
| Deployment | ⚠️ **Sepolia (11155111) deployment in progress — no addresses published yet.** See [§2](#2-contract-addresses) |

---

## 1. Architecture — self-custodial, no vault

**Read this section before anything else.** The single most common integration
error is approving the wrong contract.

`GyldAtomicSwap` **holds its own inventory** — USDC and bond tokens. There is no
settlement vault and no escrow contract. Earlier designs had one; they were
removed. Any document, diagram, or client stub that mentions a
`GyldSettlementVault` or a `GyldDvpEscrow` is **stale** — those contracts no
longer exist in this repository.

What `executeSwap` actually does:

1. **Pulls** `requestedAmountIn` of `tokenIn` from **you** into the swap contract
   (`safeTransferFrom(msg.sender, address(this), …)`).
2. **Pushes** the derived `amountOut` of `tokenOut` from the swap contract's
   **own balance** to you (`safeTransfer(msg.sender, …)`).

```
        approve / permit
 taker ──────────────────► GyldAtomicSwap
   │                            │
   │  leg 1: pull tokenIn  ────►│  (contract's own inventory)
   │◄──── leg 2: push tokenOut  │
```

Consequences you must design around:

| Consequence | Detail |
|-------------|--------|
| **Approve `GyldAtomicSwap` only.** | It is the sole address you ever grant an allowance or sign a permit to. Approving anything else does not work. |
| **The outgoing leg must already be in inventory.** | The contract holds no mint authority and grants no standing outbound allowance. If it is short, your call reverts with `InsufficientInventory` or `InsufficientUsdcLiquidity` — a **liveness** condition, not a mistake on your part. Retry later or request a smaller draw. |
| **Exactly one leg is a registered bond token; the other is USDC.** | Bond↔bond and USDC↔USDC are rejected with `NotOneBondLeg`. |
| **The signed quote is the execution price.** | The NAV oracle is only a sanity *guard rail*, not the price. |
| **The contract is pausable.** | While paused, `executeSwap` reverts `EnforcedPause()`. Pausing is cheap for Gyld ops and resuming is governance-gated, so a pause may persist. |

### Compliance is enforced at the token, not here

`GyldAtomicSwap` makes no sanctions calls. Instead, every swap has exactly one
`GyldBondToken` leg, and that token screens the sender, the recipient, **and the
swap contract as spender** on every transfer, failing closed. A blocked address
therefore reverts inside the token leg, not with a swap-specific error. Gyld's
quote service also pre-screens off-chain so you do not waste gas.

### Decimals

| Token | Decimals |
|-------|----------|
| USDC | **6** |
| `GyldBondToken` | **18** |
| NAV feed | **8** |

Mixing these up is the second most common integration error. See
[§4](#4-capped-allowance-pricing--the-part-that-surprises-people).

---

## 2. Contract addresses

> ## ⚠️ TBD — Sepolia deployment in progress; no addresses published yet
>
> The atomic-swap stack is being deployed to **Ethereum Sepolia
> (chainId 11155111)**. Until that deployment lands there is no address for a
> third party to integrate against, and **no addresses are published in this
> document** — the table below will be updated when they exist.

**Sepolia (chainId 11155111) is the single supported public testnet for
integrator testing.** When the deployment lands, its addresses will be
published in the table below, and Sepolia is the only shared network Gyld
supports for testing your integration. Hoodi (chain 560048) is a
backend-internal environment — not an integrator surface — and Anvil (chain
31337) is local development only. There is no mainnet deployment.

| Network | Chain ID | Contract | Address | Status |
|---------|----------|----------|---------|--------|
| Local Anvil | 31337 | `GyldAtomicSwap` (proxy) | — | Local development only; ephemeral, regenerated per run. Not shareable. |
| Local Anvil | 31337 | `GyldBondToken` series | — | Local development only. |
| Local Anvil | 31337 | `NAVFeedForwarder` | — | Local development only. |
| Local Anvil | 31337 | USDC (mock) | — | **Mock** USDC. Note the real USDC permit differs — see [§8](#8-optional-eip-2612-permit). |
| Ethereum Sepolia | 11155111 | `GyldAtomicSwap` (proxy) | — | ⏳ **Pending — deployment in progress.** The supported public testnet for integrator testing; the proxy address will be published here. Sepolia already carries the token/NAV stack the swap settles against. |
| Ethereum Hoodi | 560048 | `GyldAtomicSwap` | — | Backend-internal testing only — **not an integrator surface**. |
| Base | 8453 | `GyldAtomicSwap` | — | **Not deployed.** Chain 8453 is Base **mainnet** and carries token and lending-integration contracts only — **not** the atomic-swap stack. |
| Any other public network | — | `GyldAtomicSwap` | — | **Not deployed.** |

**What this means for you:** you cannot integrate against a shared network
today. Build against a local deployment for development, and treat everything
in this document as an interface contract to be re-verified when the Sepolia
deployment lands. Because the contract is a **UUPS proxy**, always resolve the
proxy address from Gyld at integration time rather than hardcoding it — and
re-check the `SWAP_MESSAGE_TYPEHASH` and EIP-712 domain after any upgrade.

---

## 3. The `SwapMessage`

```solidity
struct SwapMessage {
    uint256 quoteId;      // single-use
    address taker;        // must equal msg.sender at execution
    address tokenIn;      // the leg you pay
    uint256 maxAmountIn;  // CEILING on tokenIn you may draw
    address tokenOut;     // the leg you receive
    uint256 price;        // fixed-point amountOut per 1e18 tokenIn
    uint64  expiry;       // unix seconds
    uint64  epoch;        // quote-signer generation
}
```

| Field | Meaning and constraints |
|-------|------------------------|
| `quoteId` | **Single-use.** Consumed by a bitmap (one bit per id). Reuse reverts `QuoteAlreadyUsed`. Burned in full regardless of how much you draw. |
| `taker` | **Must equal `msg.sender`.** Quotes are not bearer instruments — you cannot buy, sell, or relay someone else's quote. Reverts `NotTaker`. |
| `tokenIn` / `tokenOut` | Exactly one must be a registered bond series; the other must be USDC. Otherwise `NotOneBondLeg`. |
| `maxAmountIn` | A **ceiling**, not an exact amount. See [§4](#4-capped-allowance-pricing--the-part-that-surprises-people). |
| `price` | Fixed-point rate, `1e18`-scaled. **Must be non-zero** or `ZeroAmount`. |
| `expiry` | Unix seconds. `block.timestamp > expiry` reverts `QuoteExpired`. |
| `epoch` | Must equal the live `quoteEpoch()` or `QuoteEpochStale`. Gyld bumps the epoch to mass-invalidate **every** outstanding quote at once (signer rotation, incident response). |

### EIP-712 domain

| Field | Value |
|-------|-------|
| `name` | `"GyldAtomicSwap"` |
| `version` | **`"2"`** |
| `chainId` | The chain you are executing on |
| `verifyingContract` | The `GyldAtomicSwap` **proxy** address |

> ⚠️ **The version is `"2"`, not `"1"`.** The contract initialises its domain with
> `__EIP712_init("GyldAtomicSwap", "2")` — version 2 marks the capped-allowance
> message shape described below. Any client that hardcodes `"1"` computes a
> different domain separator, producing a digest that recovers the wrong signer
> and reverts `InvalidQuoteSigner`. If you have seen `"1"` in an integration
> brief, it is wrong; confirm the intended value with the contracts team.

There is **no `salt`** in the domain.

### Type hash

```
SWAP_MESSAGE_TYPEHASH = 0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b
```

Verify it yourself — the canonical type string must match byte for byte,
including field order and the absence of spaces after commas:

```bash
cast keccak "SwapMessage(uint256 quoteId,address taker,address tokenIn,uint256 maxAmountIn,address tokenOut,uint256 price,uint64 expiry,uint64 epoch)"
# 0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b
```

The contract also exposes the digest directly, which is the authoritative way to
check your client's EIP-712 encoding:

```bash
cast call $SWAP "hashSwapMessage((uint256,address,address,uint256,address,uint256,uint64,uint64))(bytes32)" \
  "($QUOTE_ID,$TAKER,$TOKEN_IN,$MAX_AMOUNT_IN,$TOKEN_OUT,$PRICE,$EXPIRY,$EPOCH)"
```

Compare that against your locally computed digest before you ever send a
transaction. It turns a failed swap into a one-line assertion.

---

## 4. Capped-allowance pricing — the part that surprises people

**This is the least obvious part of the API. Read it twice.**

A quote does **not** authorise one exact trade size. It authorises a *range*, and
**you** choose the size at execution time:

- `maxAmountIn` is the **ceiling** on `tokenIn`.
- `requestedAmountIn` is a **separate `executeSwap` argument — not part of the
  signed message.** You pick it.
- The output is derived from the fixed rate:

```
amountOut = requestedAmountIn * price / 1e18      // rounds DOWN
```

`price` is therefore "`amountOut` base units per `1e18` base units of
`tokenIn`". Rounding is **down, in the contract's favour** — deliberately, so a
taker cannot extract dust across many small draws.

### The allowed range

```
minAllowed = maxAmountIn * MIN_DRAW_BPS / BPS_DENOMINATOR   // = maxAmountIn * 1%
0 < minAllowed <= requestedAmountIn <= maxAmountIn
```

| Constant | Value |
|----------|-------|
| `MIN_DRAW_BPS` | `100` — i.e. **1%** |
| `BPS_DENOMINATOR` | `10_000` |

There is a **1% dust floor**: you may not draw less than 1% of `maxAmountIn`.
This stops a taker from griefing the quote signer's single-use id budget with
near-zero draws. Violations revert
`RequestedAmountOutOfRange(requested, minAllowed, maxAllowed)` — which helpfully
tells you both bounds.

### ⚠️ One quote, one draw

**The `quoteId` is burned in full, no matter how small your draw.** This is
*single-shot capped sizing*, **not** a multi-draw allowance. Drawing 10% of
`maxAmountIn` does **not** leave 90% available — the quote is spent. If you need
several fills, request several quotes.

### Worked example — buying a bond with USDC

Bond NAV is $100.00 per token. You want a quote good for up to 1,000 USDC.

| Quantity | Value | Reasoning |
|----------|-------|-----------|
| `tokenIn` | USDC (6 dp) | |
| `tokenOut` | bond token (18 dp) | |
| `maxAmountIn` | `1000000000` | 1,000 USDC × 1e6 |
| `price` | `1e28` | 10 tokens (`10e18`) per 1,000 USDC (`1000e6`): `10e18 * 1e18 / 1000e6 = 1e28` |
| `minAllowed` | `10000000` | 1% of 1,000 USDC = 10 USDC |

Drawing the full amount:

```
requestedAmountIn = 1_000_000_000                      (1,000 USDC)
amountOut         = 1_000_000_000 * 1e28 / 1e18
                  = 10_000_000_000_000_000_000          (10.0 tokens)
```

Drawing a quarter:

```
requestedAmountIn = 250_000_000                        (250 USDC)
amountOut         = 2_500_000_000_000_000_000           (2.5 tokens)
```

Drawing 5 USDC → **reverts** `RequestedAmountOutOfRange(5000000, 10000000, 1000000000)`.

### Worked example — redeeming a bond for USDC

Same NAV, quote good for up to 10 tokens.

| Quantity | Value |
|----------|-------|
| `tokenIn` | bond token (18 dp) |
| `tokenOut` | USDC (6 dp) |
| `maxAmountIn` | `10000000000000000000` (10 tokens) |
| `price` | `1e8` — `1000e6 * 1e18 / 10e18 = 1e8` |
| `minAllowed` | `100000000000000000` (0.1 tokens) |

```
requestedAmountIn = 10e18  →  amountOut = 1_000_000_000   (1,000 USDC)
requestedAmountIn =  1e18  →  amountOut =   100_000_000   (  100 USDC)
```

### Deriving `price` yourself

```
price = desiredAmountOut * 1e18 / correspondingAmountIn
```

Gyld's quote service computes this; you only need it to **verify** a quote before
signing off on it. Because `amountOut` truncates, always assert
`requestedAmountIn * price / 1e18 > 0` and that the result matches your
expectation before sending.

---

## 5. Obtaining a quote

Everything so far describes what a quote *is*. This section covers how you
**get** one — and what to check when it arrives.

Quotes are issued **off-chain by Gyld's quote service**. You request a market;
the service prices it inside the live NAV band, signs a `SwapMessage` with a
key holding `QUOTE_SIGNER_ROLE`, and returns the message plus its 65-byte
EIP-712 signature. You never sign the quote itself — the only signature on it
is Gyld's. Your job on receipt is to **validate**, then execute.

> ## ⚠️ TBD — pending backend publication
>
> The quote service's **endpoint URL, request/response schema, and
> authentication mechanics are not yet published.** Do not code against an
> assumed URL or payload shape. This section specifies what a quote is and what
> you must validate on receipt; the transport contract will be added here once
> the backend team publishes it.

### Validate the `SwapMessage` on receipt

The wire fields are defined in [§3](#3-the-swapmessage) and the pricing
arithmetic in [§4](#4-capped-allowance-pricing--the-part-that-surprises-people).
Check every field when the quote arrives:

| Field | What to verify |
|-------|----------------|
| `taker` | **Equals the wallet you will submit from.** Quotes are not bearer paper — `executeSwap` reverts `NotTaker` unless `m.taker == msg.sender`, so a quote issued to any other address is useless to you. |
| `tokenIn` / `tokenOut` | The pair you asked for — exactly one registered bond series, the other USDC. |
| `maxAmountIn` | A **ceiling**, not a committed size. Your executable range is `[maxAmountIn / 100, maxAmountIn]` — there is a 1% dust floor below which the draw reverts. |
| `price` | Fixed-point `amountOut` per `1e18 tokenIn`, **non-zero**. The output **floors**: `amountOut = requestedAmountIn * price / 1e18`, rounding down **in the maker's favour** — Gyld keeps the fractional remainder. Recompute the output for your intended draw and confirm it matches the rate you were quoted. |
| `expiry` | Unix seconds. Quotes are issued **short-lived** by policy, and the contract imposes no upper bound — so verify `block.timestamp <= expiry` yourself, immediately before broadcasting, not just on receipt. An expired quote reverts `QuoteExpired`. |
| `epoch` | Must equal the live `quoteEpoch()` — see [below](#detecting-invalidation-before-you-broadcast). |

Sanctions screening is not your job: the quote service pre-screens takers
off-chain before issuing, and the bond token re-screens on-chain at execution
([§1](#compliance-is-enforced-at-the-token-not-here)). A taker sanctioned
*after* issuance reverts inside the token leg — one more reason quotes are
short-lived.

### `quoteId` semantics — one counter, never reset

Quote ids come from a **single, strictly-monotonic counter scoped to the proxy
address**. Two properties you can rely on:

- **The counter never resets — including across epochs.** `bumpQuoteEpoch`
  invalidates every *outstanding* quote, but it does **not** free their ids: a
  consumed `quoteId` stays consumed forever, and `isQuoteUsed(id)` keeps
  returning `true` no matter how many epoch bumps follow.
- **Ids are unique for the life of the proxy.** You will never be issued the
  same `quoteId` twice, so `isQuoteUsed(quoteId)` is a reliable pre-flight
  check: if it returns `true`, do not submit — the call reverts
  `QuoteAlreadyUsed`.

### One quote, one draw — partial draws must be deliberate

A quote is **single-shot**. The first successful `executeSwap` burns the
`quoteId` **in full**, whatever size you draw: drawing 10% of `maxAmountIn`
permanently forfeits the remaining 90% — it is not carried forward and cannot
be drawn later (see
[§4](#4-capped-allowance-pricing--the-part-that-surprises-people)). Choose
`requestedAmountIn` deliberately; if you want several fills, request several
quotes up front.

### Detecting invalidation before you broadcast

A quote that was valid on arrival can be dead seconds later. Three cheap view
calls tell you — run them **immediately before broadcasting**, not when the
quote arrives:

| Read | What it catches |
|------|-----------------|
| `quoteEpoch()` | **Epoch bump.** If it no longer equals `m.epoch`, Gyld rotated the signer generation and **every** outstanding quote is dead (`QuoteEpochStale`). Subscribe to the `QuoteEpochBumped` event if you hold quotes for longer than a few seconds. |
| `isAllowed(yourAddress)` | **Allowlist revocation.** Compliance can revoke you at any moment; a revoked taker reverts `NotAllowed` no matter how valid the signature is. |
| `isQuoteUsed(quoteId)` | **Consumption.** The id is already burned (`QuoteAlreadyUsed`). |

### Validate-before-execute checklist

```ts
// Pseudocode, viem-shaped — run on receipt, and again before broadcasting.

// 1. Taker binding — the quote is addressed to ONE wallet; not bearer paper.
assert(quote.taker === myAddress);                             // else NotTaker

// 2. Expiry — quotes are short-lived; check the clock NOW, not the arrival time.
assert(BigInt(Math.floor(Date.now() / 1000)) <= quote.expiry); // else QuoteExpired

// 3. Epoch — must equal the live generation; a bump kills ALL outstanding quotes.
assert(quote.epoch === await swap.read.quoteEpoch());          // else QuoteEpochStale

// 4. Allowlist — Gyld compliance can revoke you at any moment.
assert(await swap.read.isAllowed([myAddress]));                // else NotAllowed

// 5. quoteId — consumed ids stay consumed, even across epoch bumps.
assert(!(await swap.read.isQuoteUsed([quote.quoteId])));       // else QuoteAlreadyUsed

// 6. Draw range — [1% of maxAmountIn, maxAmountIn]; single-shot, residual forfeited.
const minDraw = quote.maxAmountIn * 100n / 10_000n;            // MIN_DRAW_BPS / BPS_DENOMINATOR
assert(requestedAmountIn >= minDraw && requestedAmountIn <= quote.maxAmountIn);

// 7. Price — recompute the FLOORED output for your exact draw (rounding favours the maker).
const amountOut = requestedAmountIn * quote.price / 10n ** 18n;
assert(amountOut > 0n && amountOut === expectedOut);           // your off-chain expectation

// 8. Digest parity — your EIP-712 encoding must equal the contract's (see §7).
assert(await swap.read.hashSwapMessage([quote]) === hashTypedData({
  domain, types, primaryType: 'SwapMessage', message: quote,
}));
```

Every check above is a view call or local arithmetic — the whole checklist
costs no gas, and each line pre-empts a named revert in
[§6](#6-preconditions) / [`errors.md`](errors.md).

---

## 6. Preconditions

`executeSwap` performs all checks before any transfer (checks-effects-
interactions). Verify these off-chain first — every one is a cheap read.

| # | Precondition | Check | Failure |
|---|--------------|-------|---------|
| 1 | The contract is not paused | `paused()` | `EnforcedPause()` |
| 2 | `msg.sender == m.taker` | your own wallet | `NotTaker(taker, caller)` |
| 3 | **You are on the taker allowlist** | `isAllowed(yourAddress)` | `NotAllowed(taker)` |
| 4 | `m.price != 0` | quote | `ZeroAmount()` |
| 5 | `requestedAmountIn` within `[1% of maxAmountIn, maxAmountIn]` | arithmetic | `RequestedAmountOutOfRange(...)` |
| 6 | `block.timestamp <= m.expiry` | clock | `QuoteExpired(expiry)` |
| 7 | `m.epoch == quoteEpoch()` | `quoteEpoch()` | `QuoteEpochStale(quoteEpoch, currentEpoch)` |
| 8 | Signature recovers to a holder of `QUOTE_SIGNER_ROLE` | `hashSwapMessage` parity | `InvalidQuoteSigner(recovered)` |
| 9 | `quoteId` unused | `isQuoteUsed(quoteId)` | `QuoteAlreadyUsed(quoteId)` |
| 10 | `amountOut != 0` after truncation | arithmetic | `ZeroAmount()` |
| 11 | Exactly one leg is a registered series, other is USDC | `registeredSeries(t)`, `usdc()` | `NotOneBondLeg(tokenIn, tokenOut)` |
| 12 | NAV is positive and fresh | `navForwarderOf(bond)` → `latestRoundData()`, `maxNavAgeSecs()` | `InvalidNav`, `StaleNav` |
| 13 | Quoted USDC within the NAV band | `maxQuoteDeviationBps()` | `QuotePriceOutOfBand(quoted, nav)` |
| 14 | Allowance or permit covers `requestedAmountIn` | `allowance()` | `SafeERC20FailedOperation(token)` |
| 15 | Contract holds enough `tokenOut` | `balanceOf(swap)` | `InsufficientInventory` / `InsufficientUsdcLiquidity` |

### ⚠️ You must be allowlisted

`executeSwap` requires the taker to be on an on-chain allowlist maintained by
Gyld's compliance operators. **A correctly signed, unexpired, perfectly formed
quote still reverts `NotAllowed(address)` if your address is not allowlisted.**
Request allowlisting as part of onboarding, and check `isAllowed(you)` before
your first call — it is the cheapest possible failure to rule out.

### The NAV band, in one paragraph

The signed quote **is** the price. The oracle only bounds it. The contract reads
the series' NAV feed, converts your quote's USDC leg into NAV terms, and requires
the two to agree within `maxQuoteDeviationBps()`. A non-positive NAV, or a feed
older than `maxNavAgeSecs()`, **fails closed**. So a stale oracle blocks
otherwise valid swaps — treat `StaleNav` and `InvalidNav` as transient
infrastructure conditions to retry, not as bad input.

The scaling is `tokenAmount(18dp) * nav(8dp) / 1e20 → USDC(6dp)`.

### Read-only helpers

| Function | Returns |
|----------|---------|
| `quoteEpoch()` | `uint64` — current signer generation |
| `usdc()` | `address` — the cash-leg token |
| `isAllowed(address)` | `bool` — **check this first** |
| `isQuoteUsed(uint256)` | `bool` — has this `quoteId` been consumed |
| `registeredSeries(address)` | `bool` |
| `navForwarderOf(address)` | `address` — NAV feed for a series |
| `maxQuoteDeviationBps()` | `uint16` |
| `maxNavAgeSecs()` | `uint32` |
| `hashSwapMessage(SwapMessage)` | `bytes32` — the exact digest to sign |
| `paused()` | `bool` |
| `SWAP_MESSAGE_TYPEHASH` | `bytes32` |
| `MIN_DRAW_BPS` / `BPS_DENOMINATOR` | `uint256` |

---

## 7. Signing and execution

In production **Gyld signs; you execute.** The signing snippets below exist so
you can (a) verify a quote you were handed, and (b) run end-to-end tests against
a local deployment. Never expect to hold a quote-signer key.

### 7.1 viem

```ts
import {
  createWalletClient, createPublicClient, http, parseUnits, type Address,
} from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const SWAP: Address = '0x...'; // proxy address — obtain from Gyld
const chainId = 31337;

// ── EIP-712 definition ─────────────────────────────────────────────────────
const domain = {
  name: 'GyldAtomicSwap',
  version: '2',                 // ⚠️ "2", not "1"
  chainId,
  verifyingContract: SWAP,
} as const;

const types = {
  SwapMessage: [
    { name: 'quoteId',     type: 'uint256' },
    { name: 'taker',       type: 'address' },
    { name: 'tokenIn',     type: 'address' },
    { name: 'maxAmountIn', type: 'uint256' },
    { name: 'tokenOut',    type: 'address' },
    { name: 'price',       type: 'uint256' },
    { name: 'expiry',      type: 'uint64'  },
    { name: 'epoch',       type: 'uint64'  },
  ],
} as const;

// ── The quote (buy: 1,000 USDC ceiling at $100.00/token) ────────────────────
const message = {
  quoteId:     1n,
  taker:       taker.address,
  tokenIn:     USDC,
  maxAmountIn: parseUnits('1000', 6),   // 1_000_000_000
  tokenOut:    BOND,
  price:       10n ** 28n,              // 10e18 tokens per 1000e6 USDC
  expiry:      BigInt(Math.floor(Date.now() / 1000) + 900),
  epoch:       0n,                      // MUST equal quoteEpoch()
} as const;

// ── Signing (Gyld's quote signer does this) ─────────────────────────────────
const signer = privateKeyToAccount(QUOTE_SIGNER_PK);
const signature = await signer.signTypedData({
  domain, types, primaryType: 'SwapMessage', message,
});

// ── Parity check: your digest must equal the contract's ─────────────────────
const publicClient = createPublicClient({ transport: http(RPC_URL) });
const onchainDigest = await publicClient.readContract({
  address: SWAP,
  abi: [{
    name: 'hashSwapMessage', type: 'function', stateMutability: 'view',
    inputs: [{ type: 'tuple', name: 'm', components: types.SwapMessage }],
    outputs: [{ type: 'bytes32' }],
  }],
  functionName: 'hashSwapMessage',
  args: [message],
});
// assert(onchainDigest === hashTypedData({ domain, types, primaryType: 'SwapMessage', message }))

// ── Execution (YOU do this) ────────────────────────────────────────────────
const executeSwapAbi = [{
  name: 'executeSwap', type: 'function', stateMutability: 'nonpayable',
  inputs: [
    { name: 'm', type: 'tuple', components: types.SwapMessage },
    { name: 'signature', type: 'bytes' },
    { name: 'permitIn', type: 'tuple', components: [
        { name: 'value',    type: 'uint256' },
        { name: 'deadline', type: 'uint256' },
        { name: 'v',        type: 'uint8'   },
        { name: 'r',        type: 'bytes32' },
        { name: 's',        type: 'bytes32' },
    ]},
    { name: 'requestedAmountIn', type: 'uint256' },
  ],
  outputs: [],
}] as const;

// Taker-chosen draw: 250 of the 1,000 USDC ceiling.
const requestedAmountIn = parseUnits('250', 6);

// Preflight: cheap reads that rule out the common reverts.
// isAllowed(taker) === true, quoteEpoch() === message.epoch,
// isQuoteUsed(quoteId) === false, paused() === false

const wallet = createWalletClient({ account: taker, transport: http(RPC_URL) });

// Path A — plain ERC-20 approval (approve GyldAtomicSwap, nothing else).
await wallet.writeContract({
  address: USDC,
  abi: [{ name: 'approve', type: 'function', stateMutability: 'nonpayable',
          inputs: [{ type: 'address' }, { type: 'uint256' }],
          outputs: [{ type: 'bool' }] }],
  functionName: 'approve',
  args: [SWAP, requestedAmountIn],
});

const NO_PERMIT = {
  value: 0n, deadline: 0n, v: 0,
  r: '0x' + '00'.repeat(32) as `0x${string}`,
  s: '0x' + '00'.repeat(32) as `0x${string}`,
} as const;

const hash = await wallet.writeContract({
  address: SWAP, abi: executeSwapAbi, functionName: 'executeSwap',
  args: [message, signature, NO_PERMIT, requestedAmountIn],
});
```

### 7.2 ethers v6

```ts
import { Contract, JsonRpcProvider, Wallet, ZeroHash, parseUnits } from 'ethers';

const provider = new JsonRpcProvider(RPC_URL);
const taker = new Wallet(TAKER_PK, provider);

const domain = {
  name: 'GyldAtomicSwap',
  version: '2',                       // ⚠️ "2", not "1"
  chainId: 31337,
  verifyingContract: SWAP,
};

const types = {
  SwapMessage: [
    { name: 'quoteId',     type: 'uint256' },
    { name: 'taker',       type: 'address' },
    { name: 'tokenIn',     type: 'address' },
    { name: 'maxAmountIn', type: 'uint256' },
    { name: 'tokenOut',    type: 'address' },
    { name: 'price',       type: 'uint256' },
    { name: 'expiry',      type: 'uint64'  },
    { name: 'epoch',       type: 'uint64'  },
  ],
};

const message = {
  quoteId:     1n,
  taker:       await taker.getAddress(),
  tokenIn:     USDC,
  maxAmountIn: parseUnits('1000', 6),
  tokenOut:    BOND,
  price:       10n ** 28n,
  expiry:      BigInt(Math.floor(Date.now() / 1000) + 900),
  epoch:       0n,
};

// Signing — Gyld's quote signer. signTypedData omits the EIP712Domain type itself.
const quoteSigner = new Wallet(QUOTE_SIGNER_PK, provider);
const signature = await quoteSigner.signTypedData(domain, types, message);

const SWAP_ABI = [
  'function executeSwap((uint256,address,address,uint256,address,uint256,uint64,uint64) m, bytes signature, (uint256,uint256,uint8,bytes32,bytes32) permitIn, uint256 requestedAmountIn)',
  'function hashSwapMessage((uint256,address,address,uint256,address,uint256,uint64,uint64) m) view returns (bytes32)',
  'function quoteEpoch() view returns (uint64)',
  'function isAllowed(address) view returns (bool)',
  'function isQuoteUsed(uint256) view returns (bool)',
  'function paused() view returns (bool)',
];

const swap = new Contract(SWAP, SWAP_ABI, taker);

// Preflight — fail fast and cheaply.
if (!(await swap.isAllowed(message.taker))) throw new Error('taker not allowlisted');
if ((await swap.quoteEpoch()) !== message.epoch) throw new Error('quote epoch stale');
if (await swap.isQuoteUsed(message.quoteId)) throw new Error('quoteId already used');
if (await swap.paused()) throw new Error('contract paused');

// Digest parity — catches every EIP-712 encoding mistake in one line.
const { TypedDataEncoder } = await import('ethers');
const local = TypedDataEncoder.hash(domain, types, message);
if (local !== (await swap.hashSwapMessage(message)))
  throw new Error('EIP-712 digest mismatch — check domain version ("2") and field order');

const requestedAmountIn = parseUnits('250', 6);   // your chosen draw

const usdc = new Contract(
  USDC, ['function approve(address,uint256) returns (bool)'], taker);
await (await usdc.approve(SWAP, requestedAmountIn)).wait();

const NO_PERMIT = [0n, 0n, 0, ZeroHash, ZeroHash];

const tx = await swap.executeSwap(
  [message.quoteId, message.taker, message.tokenIn, message.maxAmountIn,
   message.tokenOut, message.price, message.expiry, message.epoch],
  signature,
  NO_PERMIT,
  requestedAmountIn,
);
await tx.wait();
```

### 7.3 `cast` (Foundry)

```bash
SWAP=0x...            # proxy address
USDC=0x...
BOND=0x...
TAKER=0x...

# 0) Preflight
cast call $SWAP "isAllowed(address)(bool)"   $TAKER
cast call $SWAP "quoteEpoch()(uint64)"
cast call $SWAP "isQuoteUsed(uint256)(bool)" 1
cast call $SWAP "paused()(bool)"

# 1) Quote fields
QUOTE_ID=1
MAX_AMOUNT_IN=1000000000                       # 1,000 USDC (6 dp)
PRICE=10000000000000000000000000000            # 1e28
EXPIRY=$(( $(date +%s) + 900 ))
EPOCH=$(cast call $SWAP "quoteEpoch()(uint64)")
MSG="($QUOTE_ID,$TAKER,$USDC,$MAX_AMOUNT_IN,$BOND,$PRICE,$EXPIRY,$EPOCH)"

# 2) Digest parity: contract-computed vs. locally computed
cast call $SWAP \
  "hashSwapMessage((uint256,address,address,uint256,address,uint256,uint64,uint64))(bytes32)" \
  "$MSG"

# 3) Approve the SWAP contract (never a vault — there is none)
REQUESTED=250000000                            # 250 USDC — your chosen draw
cast send $USDC "approve(address,uint256)" $SWAP $REQUESTED \
  --private-key $TAKER_PK

# 4) Execute. SIG is the 65-byte signature from Gyld's quote service.
#    PermitData is zeroed: value == 0 skips the permit entirely.
ZERO32=0x0000000000000000000000000000000000000000000000000000000000000000
cast send $SWAP \
  "executeSwap((uint256,address,address,uint256,address,uint256,uint64,uint64),bytes,(uint256,uint256,uint8,bytes32,bytes32),uint256)" \
  "$MSG" "$SIG" "(0,0,0,$ZERO32,$ZERO32)" $REQUESTED \
  --private-key $TAKER_PK

# Dry-run first — same args, no state change, decoded revert reason:
#   cast call $SWAP "executeSwap(...)" "$MSG" "$SIG" "(0,0,0,$ZERO32,$ZERO32)" $REQUESTED --from $TAKER
```

Verified selectors, should you need them for raw calldata:

| Function | Selector |
|----------|----------|
| `executeSwap(...)` | `0xab68e24c` |
| `hashSwapMessage(...)` | `0x16f1acd6` |
| `isAllowed(address)` | `0xbabcc539` |
| `isQuoteUsed(uint256)` | `0x8cb65b32` |
| `quoteEpoch()` | `0x9e0d684e` |

---

## 8. Optional EIP-2612 permit

`PermitData` lets you skip a separate `approve` transaction.

```solidity
struct PermitData { uint256 value; uint256 deadline; uint8 v; bytes32 r; bytes32 s; }
```

| Rule | Detail |
|------|--------|
| **`value == 0` skips the permit entirely.** | Pass an all-zero struct when you have already approved. |
| Sized by **you**, to `requestedAmountIn` | The permit is not part of the signed quote. |
| Spender is the swap contract | `permit(msg.sender, address(this), value, deadline, v, r, s)`. |
| Applied inside `try/catch` | A front-run `permit()` cannot brick your swap — a permit that reverts is ignored, and the subsequent `safeTransferFrom` enforces the allowance regardless. |

⚠️ **Two real-world caveats:**

1. **Real USDC's permit is non-standard.** Its EIP-712 domain uses version
   **`"2"`**, not the usual `"1"`. Sign USDC permits against USDC's *own*
   `DOMAIN_SEPARATOR` — read it from the token rather than reconstructing it. (Do
   not confuse this with the swap contract's own domain version, which is
   coincidentally also `"2"`.)
2. **The mock USDC used on the local development chain has no permit at all.**
   Hence the feature is optional. Pass a zeroed struct and use `approve` there.

Because the permit is swallowed on failure, a silently-failed permit surfaces
later as `SafeERC20FailedOperation(token)` at the transfer step — not as a permit
error. If you see that, check your permit signature and nonce.

---

## 9. Events

| Event | Signature |
|-------|-----------|
| `SwapExecuted` | `(uint256 indexed quoteId, address indexed taker, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)` |
| `QuoteEpochBumped` | `(uint64 indexed newEpoch)` — **every outstanding quote just became invalid** |
| `SeriesRegistered` | `(address indexed token, address indexed navForwarder)` |
| `SeriesDeregistered` | `(address indexed token)` |
| `AllowedSet` | `(address indexed account, bool allowed)` — taker allowlist changed |
| `MaxQuoteDeviationUpdated` | `(uint16 newBps)` |
| `MaxNavAgeUpdated` | `(uint32 newSecs)` |
| `WithdrawalWalletUpdated` | `(address indexed previous, address indexed next)` |
| `Withdrawn` | `(address indexed token, address indexed to, uint256 amount)` |

`SwapExecuted` reports `amountIn` as your **actual draw**, not `maxAmountIn` —
reconcile against that. Subscribe to `QuoteEpochBumped` and `AllowedSet`: the
first invalidates every quote you are holding, the second can revoke your access.

---

## 10. Roles (informational)

You will not hold any of these. They are listed so you understand what can change
underneath you and how quickly.

| Role | Held by | Can change |
|------|---------|-----------|
| `DEFAULT_ADMIN_ROLE` | Governance timelock in production | Upgrades, unpause, series registry, NAV band, NAV age, withdrawal wallet, epoch bumps, role grants |
| `ALLOWLIST_ADMIN_ROLE` | Compliance operations key | **The taker allowlist, and nothing else.** Deliberately split from admin so allowlisting is a same-day operational action rather than a governance proposal. It grants access to swap — never to funds or upgrades. |
| `QUOTE_SIGNER_ROLE` | Quote-service signing key(s) | Passive: the role *is* the signer registry. Multiple holders are supported; rotation is grant/revoke plus an epoch bump. |
| `TREASURER_ROLE` | Operations wallet | `withdraw()` inventory — **only** to the admin-fixed withdrawal wallet, never an arbitrary address. Stays live while paused so funds can be evacuated during an incident. |
| `PAUSER_ROLE` | Operations multisig | `pause()` only. Resuming requires the admin — pausing is intentionally cheap and unpausing deliberate. |

Practical implications: your allowlist status can be revoked at any moment by a
hot key; all outstanding quotes can be invalidated in one transaction; and the
contract can be paused quickly but may take longer to resume. Build retry and
alerting around all three.

Role identifiers, if you want to watch `RoleGranted`/`RoleRevoked`:

| Role | `bytes32` |
|------|-----------|
| `QUOTE_SIGNER_ROLE` | `0x5ad4c58af6038875a8389a5a539d5aa4662d7168cd0c214c7c203da21c0a0d4f` |
| `TREASURER_ROLE` | `0x3496e2e73c4d42b75d702e60d9e48102720b8691234415963a5a857b86425d07` |
| `PAUSER_ROLE` | `0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a` |
| `ALLOWLIST_ADMIN_ROLE` | `0xe9ea3f660aa5a8eccd1bf9d16e6cdf3c1cf9a2b284b830f15bda4493942cb68f` |
| `DEFAULT_ADMIN_ROLE` | `0x0000000000000000000000000000000000000000000000000000000000000000` |

---

## 11. Errors

Every custom error, with its computed 4-byte selector and the remedy, is in
[`errors.md` §2](errors.md#2-solidity-custom-errors--gyldatomicswap).

---

## 12. Licence

The contracts in this repository — including `GyldAtomicSwap.sol` — are licensed
under the **Business Source License 1.1 (`BUSL-1.1`)**. They are **not** MIT.

| Parameter | Value |
|-----------|-------|
| Licensor | Gyld Finance |
| Licensed Work | `gyld-contracts` |
| Additional Use Grant | **None** |
| Change Date | 2028-07-09 |
| Change License | `GPL-2.0-or-later` |

**What this means in practice:** the source is available to read, review, and
test, but BUSL-1.1 with **no Additional Use Grant** does **not** permit
production use. On the Change Date the licensed work converts to
`GPL-2.0-or-later`.

⚠️ **Do not deploy, fork, or embed these contracts in a production system on the
basis of this document.** If you need production rights before the Change Date,
contact Gyld about alternative licensing arrangements.

Note that the test and deployment-script directories (`contracts/test/`,
`contracts/script/`) are separately licensed as `MIT`; the contracts themselves
are not.

⚠️ Some existing internal documentation tables still describe these contracts as
"Platform (MIT)". That is inconsistent with the `SPDX-License-Identifier:
BUSL-1.1` header on every contract file and with the repository `LICENSE`. The
`BUSL-1.1` header is authoritative; the "MIT" labels need correcting.
