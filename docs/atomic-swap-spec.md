# GyldAtomicSwap — Normative Specification

**Subject:** `contracts/GyldAtomicSwap.sol`
**Commit:** `3507f1b` **License:** BUSL-1.1 (`contracts/GyldAtomicSwap.sol:1`)
**Compiler:** `solc =0.8.28`, `via_ir = true`, `optimizer_runs = 200` (`contracts/GyldAtomicSwap.sol:2`, `foundry.toml`)
**EIP-712 domain:** `name = "GyldAtomicSwap"`, `version = "2"` (`contracts/GyldAtomicSwap.sol:271`)

---

## 1. Scope and conformance

### 1.1 Scope

This document specifies the on-chain behaviour of `GyldAtomicSwap`, a **self-custodial**
UUPS-upgradeable contract that settles platform-signed EIP-712 quotes in one transaction.

`GyldAtomicSwap` **holds its own inventory**. `executeSwap` PULLS `tokenIn` from the taker
into `address(this)` and PUSHES `tokenOut` out of `address(this)`'s own balance
(`contracts/GyldAtomicSwap.sol:429`, `contracts/GyldAtomicSwap.sol:436-441`). There is no
settlement vault, no escrow contract, and no standing outbound allowance
(`contracts/GyldAtomicSwap.sol:20-38`).

Every swap has exactly one registered-bond leg and one USDC leg
(`contracts/GyldAtomicSwap.sol:482-484`). Two directions exist:

| Direction | `tokenIn` | `tokenOut` | Inventory effect |
| --- | --- | --- | --- |
| BUY | USDC | registered bond series | bond inventory decreases, USDC pot increases |
| REDEEM | registered bond series | USDC | USDC pot decreases, bond inventory increases |

Out of scope: the off-chain quote service's pricing logic, `NAVFeedForwarder` internals,
`GyldBondToken` sanctions screening, `IssuanceManager` mint-at-fill inventory
replenishment, and the treasury bridge downstream of `withdraw`.

### 1.2 Conformance language

The key words MUST, MUST NOT, SHALL, SHOULD, SHOULD NOT, and MAY are to be interpreted as
described in RFC 2119. Requirements are split by actor. A **conforming deployment**
satisfies all three sets.

#### 1.2.1 Contract requirements (enforced on-chain; verified by the invariants in §6)

- C-1 The contract MUST NOT transfer `tokenOut` unless the recovered EIP-712 signer holds
  `QUOTE_SIGNER_ROLE` (`contracts/GyldAtomicSwap.sol:402-403`).
- C-2 The contract MUST reject any second use of a `quoteId`
  (`contracts/GyldAtomicSwap.sol:510-516`).
- C-3 The contract MUST NOT pull more than `m.maxAmountIn` of `tokenIn`
  (`contracts/GyldAtomicSwap.sol:388-390`).
- C-4 The contract MUST NOT mint or burn either leg; it holds no `MINTER_ROLE`.
- C-5 The contract MUST fail closed on a non-positive, stale, or future-dated NAV
  (`contracts/GyldAtomicSwap.sol:491-496`).
- C-6 The contract MUST NOT permit `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE`, or
  `TREASURER_ROLE` to be renounced (`contracts/GyldAtomicSwap.sol:692-697`).
- C-7 The contract MUST send `withdraw` proceeds only to the admin-fixed
  `withdrawalWallet` (`contracts/GyldAtomicSwap.sol:661-662`).
- C-8 The contract MUST reject any quote whose `expiry` exceeds
  `block.timestamp + maxQuoteTtl` (`contracts/GyldAtomicSwap.sol:396-399`).

#### 1.2.2 Quote-signer requirements (off-chain; NOT enforceable on-chain)

- S-1 The signer MUST allocate `quoteId` from a **single strictly-monotonic counter that
  is global to the proxy address and never reset**, including across `bumpQuoteEpoch`.
  The bitmap is not epoch-scoped (§3.4, finding F-3).
- S-2 The signer MUST set `taker` to the address that will call `executeSwap`; quotes are
  not bearer paper (`contracts/GyldAtomicSwap.sol:383`).
- S-3 The signer MUST set `epoch` to the value currently returned by `quoteEpoch()`
  (`contracts/GyldAtomicSwap.sol:400`).
- S-4 The signer MUST set `expiry` to a short-lived, near-term timestamp. The contract
  enforces the bound on-chain: `expiry <= block.timestamp + maxQuoteTtl` (default
  1 hour, admin-adjustable; finding F-4, remediated).
- S-5 The signer MUST price the quote inside the live NAV band, accounting for the
  contract's floor division, or `executeSwap` reverts `QuotePriceOutOfBand`
  (`contracts/GyldAtomicSwap.sol:501-503`).
- S-6 The signer SHOULD pre-screen the taker against sanctions off-chain; the contract
  performs no sanctions call (`contracts/GyldAtomicSwap.sol:51-55`).
- S-7 The signer MUST NOT sign a `SwapMessage` whose `price` is `0`
  (`contracts/GyldAtomicSwap.sol:385`).

#### 1.2.3 Operator requirements (deployment and operations)

- O-1 `DEFAULT_ADMIN_ROLE` SHOULD be a `TimelockController` in production
  (`contracts/GyldAtomicSwap.sol:58-61`).
- O-2 The operator MUST call `setWithdrawalWallet` post-deploy; `withdraw` reverts
  `ZeroAddress` until then (`contracts/GyldAtomicSwap.sol:242-244`,
  `contracts/GyldAtomicSwap.sol:662`).
- O-3 The operator MUST grant `ALLOWLIST_ADMIN_ROLE` to the hot KYC key; `initialize`
  grants it to nobody (`contracts/GyldAtomicSwap.sol:278-281`). Handled by
  `contracts/script/DeployAtomicSettlement.s.sol:168-177`.
- O-4 The operator MUST register only 18-decimal bond series and MUST initialize with a
  6-decimal cash token. Both are now enforced on-chain (finding F-1, remediated):
  `registerSeries` probes `decimals() == 18` on the token and `initialize` probes
  `decimals() == 6` on the cash token, reverting `InvalidTokenDecimals`
  (`contracts/GyldAtomicSwap.sol:543-546`, `contracts/GyldAtomicSwap.sol:264-267`).
- O-5 The operator MUST drain a series' inventory before `deregisterSeries`
  (`contracts/GyldAtomicSwap.sol:563`).
- O-6 On quote-signer key compromise the operator SHOULD `pause()` first (single hot
  multisig, `contracts/GyldAtomicSwap.sol:673-675`), then `revokeRole` +
  `bumpQuoteEpoch` through the timelock.
- O-7 The operator MUST NOT rely on `withdraw` being paused; it is deliberately live
  while paused (`contracts/GyldAtomicSwap.sol:651-656`).

---

## 2. Constants

| Name | Value | Reference |
| --- | --- | --- |
| `QUOTE_SIGNER_ROLE` | `keccak256("QUOTE_SIGNER_ROLE")` — hash in §7 | `contracts/GyldAtomicSwap.sol:88` |
| `TREASURER_ROLE` | `keccak256("TREASURER_ROLE")` — hash in §7 | `contracts/GyldAtomicSwap.sol:89` |
| `PAUSER_ROLE` | `keccak256("PAUSER_ROLE")` — hash in §7 | `contracts/GyldAtomicSwap.sol:90` |
| `ALLOWLIST_ADMIN_ROLE` | `keccak256("ALLOWLIST_ADMIN_ROLE")` — hash in §7 | `contracts/GyldAtomicSwap.sol:91` |
| `DEFAULT_ADMIN_ROLE` | `bytes32(0)` (inherited) | OZ `AccessControlUpgradeable` |
| `SWAP_MESSAGE_TYPEHASH` | `0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b` | `contracts/GyldAtomicSwap.sol:124` |
| `MIN_DRAW_BPS` | `100` (1%) | `contracts/GyldAtomicSwap.sol:129` |
| `BPS_DENOMINATOR` | `10_000` | `contracts/GyldAtomicSwap.sol:130` |
| `DEFAULT_MAX_QUOTE_TTL` | `1 hours` (3 600 s) — `maxQuoteTtl` seed (F-4) | `contracts/GyldAtomicSwap.sol:137` |
| `_STORAGE_LOCATION` | `0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300` | `contracts/GyldAtomicSwap.sol:158` |

---

## 3. State space

### 3.1 ERC-7201 namespaced storage

Namespace: `erc7201:gyld.GyldAtomicSwap` (`contracts/GyldAtomicSwap.sol:141`).
Base slot `B = _STORAGE_LOCATION = 0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300`,
independently re-derived with `cast index-erc7201 gyld.GyldAtomicSwap` — **MATCH**.

All fields live in `GyldAtomicSwapStorage` (`contracts/GyldAtomicSwap.sol:142-155`); the
contract declares no other non-constant storage, so `forge inspect GyldAtomicSwap storage`
is empty by design. Fields are **append-only** — an upgrade MUST only ever add fields
after `maxQuoteTtl`, never insert or reorder (I-19).

| Slot | Offset (bytes) | Size | Field | Type | Semantics |
| --- | --- | --- | --- | --- | --- |
| `B + 0` | 0 | 8 | `quoteEpoch` | `uint64` | Quote-signer generation; mass invalidation |
| `B + 0` | 8 | 2 | `maxQuoteDeviationBps` | `uint16` | NAV band half-width, bps; `0 <= x <= 10_000` |
| `B + 0` | 10 | 4 | `maxNavAgeSecs` | `uint32` | Max NAV feed age; invariant `!= 0` |
| `B + 0` | 14..31 | 18 | — | — | Free (18 bytes available for future packing) |
| `B + 1` | 0 | 20 | `withdrawalWallet` | `address` | Fixed `withdraw` destination; `0` until set |
| `B + 2` | 0 | 20 | `usdc` | `address` | Cash-leg discriminator; immutable after `initialize` |
| `B + 3` | — | 32 | `usedQuoteWords` | `mapping(uint256 => uint256)` | BitInvalidator; bucket = `keccak256(abi.encode(quoteId >> 8, B+3))` |
| `B + 4` | — | 32 | `seriesList` | `address[]` | Length at `B+4`; data at `keccak256(B+4) + i` |
| `B + 5` | — | 32 | `registeredSeries` | `mapping(address => bool)` | Bond token enabled |
| `B + 6` | — | 32 | `navForwarderOf` | `mapping(address => address)` | Bond token → forwarder |
| `B + 7` | — | 32 | `allowed` | `mapping(address => bool)` | `executeSwap` taker allowlist |
| `B + 8` | 0 | 8 | `maxQuoteTtl` | `uint64` | Quote-expiry TTL cap (F-4); seeded `1 hours` at `initialize`. Bytes 8..31 free |

`withdrawalWallet` does **not** pack into `B + 0`: 8 + 2 + 4 = 14 bytes are used and an
`address` needs 20, exceeding the 32-byte slot, so Solidity starts a new slot.

Inherited storage lives in its own ERC-7201 namespaces (`openzeppelin.storage.AccessControl`,
`...Pausable`, `...ReentrancyGuard`, `...EIP712`, `...Initializable`) and cannot collide.

### 3.2 Roles

| Role | Granted at `initialize` | Renounceable | Capabilities |
| --- | --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | yes, `defaultAdmin` | **no** (`:692-697`) | upgrades, unpause, series registry, band params, `maxQuoteTtl`, `withdrawalWallet`, `bumpQuoteEpoch`, all role admin |
| `PAUSER_ROLE` | yes, `pauser` | **no** (`:694`, F-7) | `pause()` only |
| `QUOTE_SIGNER_ROLE` | yes, `quoteSigner` | yes | passive — checked via `hasRole` against the recovered signer |
| `TREASURER_ROLE` | yes, `treasurer` | **no** (`:695`, F-7) | `withdraw()` to the fixed wallet, live while paused |
| `ALLOWLIST_ADMIN_ROLE` | **no** | yes | `setAllowed()` only |

`QUOTE_SIGNER_ROLE` **is** the signer registry: multiple holders are supported and
rotation is `grantRole`/`revokeRole` (`contracts/GyldAtomicSwap.sol:43-44`,
`contracts/GyldAtomicSwap.sol:403`).

### 3.3 Derived / non-storage state

- `paused` — OZ `PausableUpgradeable` namespace. Gates `executeSwap` only.
- `_status` — OZ `ReentrancyGuardUpgradeable`. Shared by `executeSwap` and `withdraw`
  (`contracts/GyldAtomicSwap.sol:380`, `contracts/GyldAtomicSwap.sol:659`).
- `IERC20(x).balanceOf(address(this))` — the inventory itself. It is **not** mirrored in
  storage; `executeSwap` reads it live (`contracts/GyldAtomicSwap.sol:436`).

### 3.4 Quote lifecycle state machine

A quote's state is a function of `(bitmap bit for quoteId, block.timestamp, quoteEpoch)`.
Only the bitmap bit is persisted; `EXPIRED` and `EPOCH-STALE` are **transient predicates**,
not stored per-quote.

```
                     ┌──────────────────────────────────────────┐
   (off-chain)       │                                          │
  UNSEEN ──sign──▶ SIGNED ──executeSwap(valid, any size)──▶ CONSUMED  (terminal)
                     │
                     ├── block.timestamp > expiry ─────────▶ EXPIRED     (terminal, bit unset)
                     │
                     └── epoch != quoteEpoch ──────────────▶ EPOCH-STALE (terminal in practice)
```

**There is no `PARTIALLY-DRAWN` state.** `_consumeQuote` sets the bit unconditionally on
the first successful draw, whatever its size (`contracts/GyldAtomicSwap.sol:405`,
`contracts/GyldAtomicSwap.sol:515`), and any later attempt reverts `QuoteAlreadyUsed`
(`contracts/GyldAtomicSwap.sol:513`). Normatively:

- A `quoteId` MAY be drawn **at most once**, for any single amount in
  `[minAllowed, maxAmountIn]` where `minAllowed = maxAmountIn * 100 / 10_000`.
- The residual `maxAmountIn - requestedAmountIn` is **permanently forfeited**. It is not
  recoverable, not carried forward, and not drawable by a second call.
- `maxAmountIn` therefore bounds the signer's exposure **per quote**, not a running
  balance. The correct mental model is *single-shot capped sizing*, not multi-draw.

Terminal-state notes:

- `CONSUMED` is absolutely terminal: `bumpQuoteEpoch` does **not** clear `usedQuoteWords`
  (`contracts/GyldAtomicSwap.sol:521-524`), and there is no un-consume path. Hence S-1.
- `EXPIRED` leaves the bit unset, so the `quoteId` is still nominally drawable — but never
  will be, because `block.timestamp` only increases (`contracts/GyldAtomicSwap.sol:392`).
- `EPOCH-STALE` is escapable in principle (`m.epoch != $.quoteEpoch` is an inequality, and
  `quoteEpoch` only increments) but not in practice. Note this rejects **future** epochs
  too, not only past ones.
- A reverted `executeSwap` for **any** reason leaves the quote in `SIGNED`: consumption is
  a state write inside the same transaction and rolls back with it (I-9).

---

## 4. `executeSwap` transition table

```solidity
function executeSwap(
    SwapMessage calldata m,
    bytes calldata signature,
    PermitData calldata permitIn,
    uint256 requestedAmountIn
) external nonReentrant whenNotPaused
```

Steps in **exact code-evaluation order** (`contracts/GyldAtomicSwap.sol:375-444`).
Any revert rolls back every prior postcondition in the table.

| # | Line | Precondition (must hold) | Revert if violated | Postcondition / effect |
| --- | --- | --- | --- | --- |
| 0a | `:380` | not already inside `executeSwap`/`withdraw` | `ReentrancyGuardReentrantCall()` | guard set to ENTERED |
| 0b | `:380` | `!paused()` | `EnforcedPause()` | — |
| 1 | `:383` | `m.taker == msg.sender` | `NotTaker(m.taker, msg.sender)` | taker binding proven |
| 2 | `:384` | `$.allowed[msg.sender]` | `NotAllowed(msg.sender)` | allowlist proven |
| 3 | `:385` | `m.price != 0` | `ZeroAmount()` | price non-degenerate |
| 4 | `:387` | — | — | `minAmountIn := m.maxAmountIn * 100 / 10_000` (floor) |
| 5 | `:388-390` | `requestedAmountIn != 0 && requestedAmountIn >= minAmountIn && requestedAmountIn <= m.maxAmountIn` | `RequestedAmountOutOfRange(requested, minAllowed, maxAllowed)` | draw size in range |
| 6 | `:392` | `block.timestamp <= m.expiry` | `QuoteExpired(m.expiry)` | quote fresh (expiry inclusive) |
| 6b | `:396-399` | `m.expiry <= block.timestamp + $.maxQuoteTtl` | `QuoteExpiryTooFar(m.expiry, maxAllowed)` | quote near-term (TTL inclusive, F-4) |
| 7 | `:400` | `m.epoch == $.quoteEpoch` | `QuoteEpochStale(m.epoch, $.quoteEpoch)` | generation current |
| 8 | `:402-403` | `ECDSA.recover(hashSwapMessage(m), signature)` succeeds **and** holds `QUOTE_SIGNER_ROLE` | `ECDSAInvalidSignature()` / `ECDSAInvalidSignatureLength(len)` / `ECDSAInvalidSignatureS(s)` / `InvalidQuoteSigner(recovered)` | message authenticity proven |
| 9 | `:405` | bit `m.quoteId & 0xff` of word `m.quoteId >> 8` is clear | `QuoteAlreadyUsed(m.quoteId)` | **STATE WRITE**: bit set; `isQuoteUsed(m.quoteId) == true` |
| 10 | `:409` | — | — | `amountOut := requestedAmountIn * m.price / 1e18` (floor) |
| 11 | `:410` | `amountOut != 0` | `ZeroAmount()` | outgoing leg non-degenerate |
| 12 | `:482-484` | exactly one of `(registeredSeries[tokenOut] && tokenIn == usdc)`, `(registeredSeries[tokenIn] && tokenOut == usdc)` | `NotOneBondLeg(tokenIn, tokenOut)` | direction classified |
| 13 | `:491-492` | forwarder's `latestRoundData().answer > 0` | `InvalidNav(bondToken, nav)` | NAV usable |
| 14 | `:495-496` | `updatedAt <= block.timestamp <= updatedAt + $.maxNavAgeSecs` | `StaleNav(bondToken, updatedAt)` | feed fresh and not future-dated (F-6) |
| 15 | `:499-503` | `navValue - band <= usdcAmount <= navValue + band` (inclusive, see §5.4) | `QuotePriceOutOfBand(usdcAmount, navValue)` | quote inside sanity band |
| 16 | `:419-425` | `permitIn.value == 0` OR the `permit` call is attempted | **never reverts** (`try/catch`) | allowance possibly increased |
| 17 | `:429` | `IERC20(m.tokenIn)` allowance & balance of `msg.sender` cover `requestedAmountIn` | token's own revert, wrapped by `SafeERC20` | **TRANSFER IN**: `requestedAmountIn` of `tokenIn` moved taker → `address(this)` |
| 18 | `:436-440` | `amountOut <= IERC20(m.tokenOut).balanceOf(address(this))` | `InsufficientUsdcLiquidity(amountOut, available)` if `tokenOut == usdc`, else `InsufficientInventory(tokenOut, amountOut, available)` | solvency proven |
| 19 | `:441` | — | token's own revert | **TRANSFER OUT**: `amountOut` of `tokenOut` moved `address(this)` → taker |
| 20 | `:443` | — | — | `SwapExecuted(quoteId, taker, tokenIn, requestedAmountIn, tokenOut, amountOut)` |
| 21 | end | — | — | reentrancy guard released |

### 4.1 Why signature recovery precedes quote consumption

Recovery (step 8, `:402-403`) is evaluated **strictly before** `_consumeQuote` (step 9,
`:405`). This ordering is load-bearing:

1. **Griefing resistance.** If consumption came first, any allowlisted address could
   fabricate a `SwapMessage` with an arbitrary `quoteId` and a garbage signature and burn
   that id, denying service to a legitimately signed quote. Authenticity MUST gate the
   only irreversible state write.
2. **Consumption still precedes all value movement.** Step 9 sits before the NAV read
   (step 12-15) and before both transfers (steps 17, 19). Within a successful
   transaction the id is already burned when control leaves for any token callback, so a
   token hook cannot re-draw the same quote even if `nonReentrant` were absent. The
   guard (step 0a) is the belt to that braces.
3. **Cheap checks first.** Steps 1-7 are calldata comparisons and one warm `SLOAD`; they
   short-circuit before the ~3k-gas `ecrecover`. Notably steps 1-2 (taker binding,
   allowlist) precede recovery, so an unauthorized caller learns nothing about whether a
   signature is valid.

### 4.2 Inventory measurement point

`available` is read **after** the pull-in (step 17 before step 18,
`contracts/GyldAtomicSwap.sol:436`). This is sound in both directions only because
`tokenIn != tokenOut` is already guaranteed: step 12 requires exactly one leg to be a
registered series and the other to be `usdc`, and a registered series is never `usdc`
itself (if it were, `buy == redeem == true` and step 12 reverts). Therefore the pulled-in
leg never inflates `available` for the pushed-out leg
(`contracts/GyldAtomicSwap.sol:431-435`).

### 4.3 Permit handling

`permitIn` is applied only when `permitIn.value != 0` and is wrapped in `try/catch`
(`contracts/GyldAtomicSwap.sol:419-425`). Normative consequences:

- A failed `permit` MUST NOT abort the swap. A front-runner who lands the identical permit
  first consumes the nonce; the in-swap `permit` then reverts, is swallowed, and the
  allowance the front-runner already set covers step 17.
- A `tokenIn` with no `permit` function at all (real USDC uses non-standard version `"2"`;
  `MockUSDC` has none) is equally safe — the call reverts and is swallowed.
- Authorization is therefore **never** derived from the permit succeeding. Step 17's
  `safeTransferFrom` is the sole allowance check.

---

## 5. EIP-712 (normative)

### 5.1 Domain

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
```

| Field | Value |
| --- | --- |
| `name` | `"GyldAtomicSwap"` (`contracts/GyldAtomicSwap.sol:271`) |
| `version` | `"2"` — bumped for the capped-allowance wire change (`contracts/GyldAtomicSwap.sol:271`) |
| `chainId` | `block.chainid` at signing time |
| `verifyingContract` | the **ERC-1967 proxy** address, not the implementation |
| `salt` | absent |

There is no `EIP712Domain` `salt`, so `abi.encode` of exactly four fields is used.

Precomputed component hashes:

```
domainTypehash = keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
               = 0x8b73c3c69bb8fe3d512ecc4cf759cc79239f7b179b0ffacaa9a75d522b39400f
nameHash       = keccak256("GyldAtomicSwap") = 0x6c18a34b523dc11cf247af8cfe942be13cd236262f18f45640378d80571f36f9
versionHash    = keccak256("2")              = 0xad7c5bef027816a800da1736444fb58a807ef4c9603b7848673f7e3a68eb14a5
```

`domainSeparator = keccak256(abi.encode(domainTypehash, nameHash, versionHash, chainId, verifyingContract))`

### 5.2 Type string and typehash verification

Canonical type string (single member struct, no nested structs, alphabetically-irrelevant
— field order is declaration order):

```
SwapMessage(uint256 quoteId,address taker,address tokenIn,uint256 maxAmountIn,address tokenOut,uint256 price,uint64 expiry,uint64 epoch)
```

Derived from the struct declaration at `contracts/GyldAtomicSwap.sol:100-112` and hashed:

```
$ cast keccak "SwapMessage(uint256 quoteId,address taker,address tokenIn,uint256 maxAmountIn,address tokenOut,uint256 price,uint64 expiry,uint64 epoch)"
0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b
```

Literal at `contracts/GyldAtomicSwap.sol:124`:
`0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b`

**Result: MATCH.** (Machine-checked by
`GyldAtomicSwapTest.test_swapMessageTypehash_matchesCanonicalString`.)

### 5.3 Struct hash and digest

```
structHash = keccak256(abi.encode(
    SWAP_MESSAGE_TYPEHASH,
    m.quoteId,      // uint256, left-padded to 32B
    m.taker,        // address, left-padded to 32B
    m.tokenIn,
    m.maxAmountIn,
    m.tokenOut,
    m.price,
    m.expiry,       // uint64  → left-padded to 32B (NOT truncated)
    m.epoch         // uint64  → left-padded to 32B
))
digest = keccak256(0x1901 || domainSeparator || structHash)
```

Reference implementation: `hashSwapMessage` (`contracts/GyldAtomicSwap.sol:449-465`).
Signers MUST produce a 65-byte `r || s || v` signature over `digest`, with **low-`s`**
(`s <= n/2`); OZ's `ECDSA.recover` rejects the high-`s` malleable counterpart with
`ECDSAInvalidSignatureS`.

### 5.4 `price` → `amountOut` arithmetic

`price` is fixed-point: **`amountOut` base units per `1e18` base units of `tokenIn`**
(`contracts/GyldAtomicSwap.sol:109`).

```
amountOut = floor(requestedAmountIn * price / 1e18)        // :409
```

**Rounding note.** The division truncates toward zero, i.e. **always in the contract's
favour** — the taker never receives the fractional remainder
(`contracts/GyldAtomicSwap.sol:407-408`). A taker-favourable rounding direction would let
a taker extract dust across many draws. Consequences:

- If truncation drives `amountOut` to `0`, step 11 reverts `ZeroAmount` rather than moving
  `tokenIn` for nothing (`contracts/GyldAtomicSwap.sol:410`).
- `requestedAmountIn * price` is checked arithmetic (`solc >= 0.8`), so an overflowing
  product reverts with `Panic(0x11)` rather than wrapping. A signer therefore MUST keep
  `maxAmountIn * price < 2^256`.
- The NAV band (§5.5) is evaluated against the **already-floored** `amountOut`, which for
  a BUY slightly lowers `navValue` and so biases the band check conservatively.

Worked decimal cases (bond 18dp, USDC 6dp, NAV $100.00 = `100e8`):

| Direction | `price` | `requestedAmountIn` | exact product / `1e18` | `amountOut` | dust retained |
| --- | --- | --- | --- | --- | --- |
| BUY | `1e28` | `1_000_000_000` (1 000.000000 USDC) | `10000000000000000000` | `10e18` (10.0 bond) | 0 |
| BUY | `1e28` | `333_333_333` (333.333333 USDC) | `3333333330000000000` | `3.33333333e18` | 0 |
| REDEEM | `100e6` | `10e18` (10.0 bond) | `1000000000` | `1_000e6` (1 000.000000 USDC) | 0 |
| REDEEM | `100e6` | `1_234_567_890_123_456_789` | `123456789.0123456789` | `123456789` (123.456789 USDC) | `0.0123456789` base units |
| REDEEM | `100e6` | `9_999_999_999` | `0.9999999999` | `0` → **reverts `ZeroAmount`** | n/a |

### 5.5 NAV band arithmetic

`_checkQuoteBand` (`contracts/GyldAtomicSwap.sol:475-504`):

```
navValue = floor(tokenAmount * uint256(nav) / 1e20)        // :499   1e18 * 1e8 / 1e20 = 1e6
band     = floor(navValue * maxQuoteDeviationBps / 10_000) // :500
require(usdcAmount <= navValue + band && usdcAmount + band >= navValue)   // :501-503
```

where for a BUY `tokenAmount = amountOut`, `usdcAmount = requestedAmountIn`, and for a
REDEEM `tokenAmount = requestedAmountIn`, `usdcAmount = amountOut`. Both band edges are
**inclusive**. The `1e20` divisor hard-codes 18dp token / 8dp NAV / 6dp USDC — since the
F-1 remediation the ladder is enforced on-chain by the `registerSeries` and `initialize`
decimals probes (`contracts/GyldAtomicSwap.sol:543-546`,
`contracts/GyldAtomicSwap.sol:264-267`).

The feed is a **guard rail, not the execution price**: the signed `price` is what executes
(`contracts/GyldAtomicSwap.sol:39-42`, `contracts/GyldAtomicSwap.sol:413-414`).

### 5.6 Test vector 1 — BUY

| Field | Value |
| --- | --- |
| `quoteId` | `1` |
| `taker` | `0x1111111111111111111111111111111111111111` |
| `tokenIn` (USDC) | `0x2222222222222222222222222222222222222222` |
| `maxAmountIn` | `1000000000` (1 000.000000 USDC) |
| `tokenOut` (bond) | `0x3333333333333333333333333333333333333333` |
| `price` | `10000000000000000000000000000` (`1e28`) |
| `expiry` | `1750000900` |
| `epoch` | `0` |

`abi.encode(...)` preimage (288 bytes = typehash + 8 words):

```
87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b
0000000000000000000000000000000000000000000000000000000000000001
0000000000000000000000001111111111111111111111111111111111111111
0000000000000000000000002222222222222222222222222222222222222222
000000000000000000000000000000000000000000000000000000003b9aca00
0000000000000000000000003333333333333333333333333333333333333333
0000000000000000000000000000000000000000204fce5e3e25026110000000
00000000000000000000000000000000000000000000000000000000684ee504
0000000000000000000000000000000000000000000000000000000000000000
```

```
structHash = 0xd2e737d0941c835fc896c70c66fca52d93a48de326c54d02d3f88a290d14837b
```

With `chainId = 11155111` (Sepolia) and
`verifyingContract = 0x4444444444444444444444444444444444444444`:

```
domainSeparator = 0x304880d5d505807dde95e80b427a4bc881bd5fd4b959e6c9db7e64a78de9477c
digest          = 0x852a19245c94dad26a71f09b771d40d99907121f525677d7358f41bf18254422
```

Full-draw arithmetic: `amountOut = 1000000000 * 1e28 / 1e18 = 10e18` (10.0 bond).
At NAV `100e8`: `navValue = 10e18 * 100e8 / 1e20 = 1_000e6`; with
`maxQuoteDeviationBps = 200`, `band = 20e6`, and `usdcAmount = 1_000e6` sits exactly on NAV.
Minimum legal draw: `1000000000 * 100 / 10000 = 10_000_000` (10.000000 USDC).

### 5.7 Test vector 2 — REDEEM, non-zero epoch, second bitmap word

| Field | Value |
| --- | --- |
| `quoteId` | `257` (`= 0x101` → bitmap word `1`, bit `1`) |
| `taker` | `0x1111111111111111111111111111111111111111` |
| `tokenIn` (bond) | `0x3333333333333333333333333333333333333333` |
| `maxAmountIn` | `10000000000000000000` (`10e18`, 10.0 bond) |
| `tokenOut` (USDC) | `0x2222222222222222222222222222222222222222` |
| `price` | `100000000` (`100e6`) |
| `expiry` | `1750000900` |
| `epoch` | `3` |

```
87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b
0000000000000000000000000000000000000000000000000000000000000101
0000000000000000000000001111111111111111111111111111111111111111
0000000000000000000000003333333333333333333333333333333333333333
0000000000000000000000000000000000000000000000008ac7230489e80000
0000000000000000000000002222222222222222222222222222222222222222
0000000000000000000000000000000000000000000000000000000005f5e100
00000000000000000000000000000000000000000000000000000000684ee504
0000000000000000000000000000000000000000000000000000000000000003
```

```
structHash = 0xd80d5543af9c13a18803944f04f58bb289d9c69744fd314cf9ff7f05999abfd2
```

Same domain as §5.6:

```
domainSeparator = 0x304880d5d505807dde95e80b427a4bc881bd5fd4b959e6c9db7e64a78de9477c
digest          = 0x525dd14923d57b1c74b3f8cc8d13b26beaef3aa907e4c285eccc23c00f72e799
```

Full-draw arithmetic: `amountOut = 10e18 * 100e6 / 1e18 = 1_000e6` (1 000.000000 USDC).
This quote executes only while `quoteEpoch() == 3`. Minimum legal draw:
`10e18 * 100 / 10000 = 1e17` (0.1 bond).

Both vectors are pinned in `contracts/test/GyldAtomicSwap.spec.t.sol` by three tests that
together give end-to-end parity:

1. `test_specVectors_structHashes_matchPublishedLiterals` — rebuilds both struct hashes
   from the **contract's own** `SWAP_MESSAGE_TYPEHASH()` and asserts the published
   literals. Struct hashes are chain- and address-independent, so this is the assertion a
   third-party signer can reproduce verbatim.
2. `test_specVectors_digests_matchPublishedLiterals` — asserts the published
   `domainSeparator` and both digests follow from those struct hashes under
   `chainId = 11155111`, `verifyingContract = 0x4444…4444`.
3. `test_hashSwapMessage_matchesSpecFormula_forBothVectorShapes` — asserts the **live
   proxy's** `hashSwapMessage` equals the same §5.1 + §5.3 formula instantiated with the
   deployment's real `chainId` and proxy address, for both vectors' field shapes. This is
   what ties (1) and (2) to the contract; the vectors themselves cannot be produced by a
   live proxy because `verifyingContract` is fixed to a literal.

---

## 6. Invariants

"Machine-checked" means a currently-passing Forge test asserts it. `[t]` =
`contracts/test/GyldAtomicSwap.t.sol`, `[i]` =
`contracts/test/GyldAtomicSwap.invariants.t.sol`, `[s]` =
`contracts/test/GyldAtomicSwap.spec.t.sol` (added by this spec).

### I-1 Inventory solvency

`executeSwap` MUST NOT transfer out more `tokenOut` than `address(this)` already holds:
for every successful call, `amountOut <= balanceOf(this)` measured after the pull-in
(`contracts/GyldAtomicSwap.sol:436-441`).

- Machine-checked: **yes** — `[t] test_executeSwap_insufficientInventory_reverts`,
  `[t] test_executeSwap_insufficientUsdcLiquidity_reverts` (negative direction);
  `[s] testFuzz_executeSwap_neverPaysOutMoreThanInventory` (positive direction, fuzzed);
  `[s] testFuzz_executeSwap_overInventoryDraw_alwaysReverts` (fuzzed, all draws that
  exceed on-hand inventory).

### I-2 No `quoteId` double-spend

For any `quoteId`, at most one `executeSwap` call in the contract's entire lifetime may
succeed with that id (`contracts/GyldAtomicSwap.sol:510-516`).

- Machine-checked: **yes** — `[t] test_executeSwap_replayedQuoteId_reverts`,
  `[i] testFuzz_quoteId_replay_alwaysReverts`.

### I-2a Bitmap non-aliasing

Consuming `quoteId q` MUST NOT mark any `q' != q` as used. Formally
`(q >> 8, q & 0xff)` is injective (`contracts/GyldAtomicSwap.sol:330`,
`contracts/GyldAtomicSwap.sol:511-515`).

- Machine-checked: **yes** — `[s] test_bitmap_wordBoundary_noAliasing` (ids 255/256/257
  consumed, neighbours and `type(uint256).max` asserted clear),
  `[s] testFuzz_isQuoteUsed_neverAliases`.

### I-3 Draw never exceeds `maxAmountIn`

The total `tokenIn` pulled against a given `quoteId` MUST be
`<= m.maxAmountIn`, and each individual draw MUST also satisfy
`requestedAmountIn >= floor(maxAmountIn * 100 / 10_000)` and `> 0`
(`contracts/GyldAtomicSwap.sol:387-390`). Combined with I-2 (single draw), the signer's
worst-case exposure per quote is exactly `maxAmountIn` in and
`floor(maxAmountIn * price / 1e18)` out.

- Machine-checked: **yes** — `[t] test_executeSwap_requestedAmountInAboveMaxAmountIn_reverts`,
  `[t] test_executeSwap_requestedAmountInBelowDustFloor_reverts`,
  `[t] test_executeSwap_zeroRequestedAmountIn_reverts`;
  `[s] test_executeSwap_exactlyMinDrawFloor_succeeds` (inclusive lower edge);
  `[s] testFuzz_executeSwap_outOfRangeDraw_alwaysReverts` (fuzzed on both sides of the
  range, and asserts no `quoteId` is burned).

### I-4 `quoteEpoch` monotonicity

`quoteEpoch` MUST be non-decreasing and MUST only ever change by `+1` via
`bumpQuoteEpoch` (`contracts/GyldAtomicSwap.sol:521-524`). A quote executes iff
`m.epoch == quoteEpoch` exactly — **both** past and future epochs are rejected
(`contracts/GyldAtomicSwap.sol:400`).

- Machine-checked: **yes** — `[t] test_bumpQuoteEpoch_incrementsAndEmits`,
  `[t] test_executeSwap_staleEpoch_reverts`,
  `[t] test_executeSwap_newEpochQuote_succeedsAfterBump`;
  `[s] test_bumpQuoteEpoch_strictlyMonotonic` (multi-bump),
  `[s] test_executeSwap_futureEpochQuote_reverts`.

### I-5 Epoch bump does not free `quoteId`s

`bumpQuoteEpoch` MUST NOT clear `usedQuoteWords` — a consumed id stays consumed forever
(`contracts/GyldAtomicSwap.sol:521-524` writes only `quoteEpoch`).

- Machine-checked: **yes** — `[s] test_consumedQuoteId_survivesEpochBump`.

### I-6 Allowlist enforcement

`executeSwap` MUST revert unless `allowed[msg.sender]` is `true`, regardless of signature
validity (`contracts/GyldAtomicSwap.sol:384`). Only `ALLOWLIST_ADMIN_ROLE` may change it
(`contracts/GyldAtomicSwap.sol:624`).

- Machine-checked: **yes** — `[t] test_executeSwap_nonAllowlistedTaker_reverts`,
  `[t] test_setAllowed_onlyAllowlistAdmin_reverts`,
  `[t] test_setAllowed_defaultAdminCannotCall_reverts`,
  `[t] test_setAllowed_emitsAndReAllows`.

### I-7 Taker binding

`executeSwap` MUST revert unless `m.taker == msg.sender`; quotes are not bearer
instruments (`contracts/GyldAtomicSwap.sol:383`).

- Machine-checked: **yes** — `[t] test_executeSwap_wrongTaker_reverts` (which allowlists
  the outsider first, isolating the binding from I-6).

### I-8 Protected-role non-renounceability

`renounceRole` MUST always revert for `DEFAULT_ADMIN_ROLE` (`CannotRenounceAdminRole`),
`PAUSER_ROLE` (`CannotRenouncePauserRole`), and `TREASURER_ROLE`
(`CannotRenounceTreasurerRole`) (`contracts/GyldAtomicSwap.sol:692-697`); the other two
roles (`QUOTE_SIGNER_ROLE`, `ALLOWLIST_ADMIN_ROLE`) MUST remain renounceable. The F-7
extension covers the incident-response pair: a sole holder self-renouncing would remove
the fast halt (`pause`) and the paused-state evacuation path (`withdraw`) until the
timelock re-grants — the delay those roles exist to bypass.

- Machine-checked: **yes** — `[t] test_renounceRole_defaultAdmin_reverts`,
  `[t] test_renounceRole_pauser_reverts`, `[t] test_renounceRole_treasurer_reverts`,
  `[t] test_renounceRole_quoteSigner_succeeds`,
  `[t] test_renounceRole_allowlistAdmin_succeeds`;
  `[s] test_renounceRole_defaultAdmin_revertsForEveryHolder` (two concurrent admins),
  `[s] test_renounceRole_incidentResponseRoles_revert`.

### I-9 Atomic consumption

If `executeSwap` reverts for any reason at any step, `isQuoteUsed(m.quoteId)` MUST be
unchanged — the quote remains executable (`contracts/GyldAtomicSwap.sol:405` is an
ordinary state write inside the reverting transaction).

- Machine-checked: **yes** — `[s] test_failedSwap_doesNotConsumeQuoteId`.

### I-10 Conservation / never-mints

`executeSwap` MUST NOT change the total supply of either leg, and the sum of all
participants' balances MUST be preserved. The contract holds no mint or burn authority.

- Machine-checked: **yes** — `[i] invariant_bond_totalSupply_never_changes`,
  `[i] invariant_no_phantom_token_balances`,
  `[i] testFuzz_executeSwap_buy_tokenTotalSupply_unchanged`,
  `[i] testFuzz_executeSwap_redeem_tokenTotalSupply_unchanged`,
  `[i] testFuzz_executeSwap_buy_conservesBothPools`;
  `[s] testFuzz_executeSwap_redeem_conservesBothPools` (REDEEM pool conservation,
  previously untested).

### I-11 Price fidelity

The taker MUST receive exactly `floor(requestedAmountIn * price / 1e18)` — never more,
never less (`contracts/GyldAtomicSwap.sol:409`).

- Machine-checked: **yes** — `[i] testFuzz_executeSwap_buy_amountOut_matchesPriceRoundedDown`.

### I-12 Signature authority

`tokenOut` MUST NOT leave the contract unless the recovered signer holds
`QUOTE_SIGNER_ROLE` at execution time, and the recovered signer MUST be over the exact
`hashSwapMessage(m)` digest (`contracts/GyldAtomicSwap.sol:402-403`).

- Machine-checked: **yes** — `[t] test_executeSwap_wrongSigner_reverts`,
  `[t] test_executeSwap_nonSignerRoleKey_reverts`,
  `[t] test_executeSwap_tamperedMessage_reverts`,
  `[t] test_executeSwap_highSMalleableSignature_reverts`,
  `[t] test_executeSwap_zeroLengthSignature_reverts`,
  `[t] test_executeSwap_wrongLengthSignature_reverts`;
  `[s] test_executeSwap_revokedSigner_reverts` (role revoked after signing).

### I-13 Cross-chain / cross-proxy replay resistance

The digest MUST bind `chainId` and `verifyingContract`; the same `SwapMessage` bytes MUST
produce a different digest on a different chain or a different proxy
(`contracts/GyldAtomicSwap.sol:450`, OZ `EIP712Upgradeable`).

- Machine-checked: **yes** — `[t] test_hashSwapMessage_matchesHandBuiltDigest` (domain
  parity); `[s] test_hashSwapMessage_bindsChainId`,
  `[s] test_hashSwapMessage_bindsVerifyingContract`.

### I-14 Exactly one bond leg

`executeSwap` MUST revert `NotOneBondLeg` unless exactly one leg is a registered series
and the other is `usdc`; in particular `tokenIn == tokenOut` MUST always revert
(`contracts/GyldAtomicSwap.sol:482-484`).

- Machine-checked: **yes** — `[t] test_executeSwap_unregisteredSeries_reverts`;
  `[s] test_executeSwap_sameTokenBothLegs_reverts`,
  `[s] test_executeSwap_neitherLegUsdc_reverts`.

### I-15 NAV fail-closed

A non-positive NAV, a feed older than `maxNavAgeSecs`, or a future-dated `updatedAt`
MUST block execution (`contracts/GyldAtomicSwap.sol:491-496`), and `maxNavAgeSecs` MUST
never be `0` (`contracts/GyldAtomicSwap.sol:260`, `contracts/GyldAtomicSwap.sol:597`).
The future-dated case (F-6) would otherwise satisfy the age check forever.

- Machine-checked: **yes** — `[t] test_executeSwap_invalidNav_reverts`,
  `[t] test_executeSwap_staleNav_reverts`, `[t] test_executeSwap_futureDatedNav_reverts`,
  `[t] test_setMaxNavAgeSecs_zero_reverts`;
  `[s] test_executeSwap_negativeNav_reverts`,
  `[s] test_executeSwap_futureDatedNav_reverts`,
  `[s] test_executeSwap_navExactlyAtMaxAge_succeeds` (inclusive edge).

### I-16 Withdrawal destination is admin-fixed

`withdraw` MUST send to `withdrawalWallet` and nowhere else; the `TREASURER_ROLE` holder
MUST NOT be able to specify a destination, and `withdraw` MUST fail closed while
`withdrawalWallet == address(0)` (`contracts/GyldAtomicSwap.sol:659-665`). `withdraw` MUST
remain callable while paused.

- Machine-checked: **yes** — `[t] test_withdraw_byTreasurer_toWithdrawalWallet_succeeds`,
  `[t] test_withdraw_walletNotSet_reverts`, `[t] test_withdraw_nonTreasurer_reverts`,
  `[t] test_withdraw_zeroAmount_reverts`, `[t] test_withdraw_worksWhilePaused`,
  `[t] test_setWithdrawalWallet_updatesAndEmits`.

### I-17 Reentrancy exclusion

`executeSwap` and `withdraw` MUST be mutually exclusive and non-reentrant; a token
callback MUST NOT re-enter either (`contracts/GyldAtomicSwap.sol:380`,
`contracts/GyldAtomicSwap.sol:659`).

- Machine-checked: **yes** — `[t] test_executeSwap_reentrancy_reverts`;
  `[s] test_withdraw_cannotReenterExecuteSwap`.

### I-18 Pause asymmetry

`PAUSER_ROLE` MUST be able to `pause()` and MUST NOT be able to `unpause()`; only
`DEFAULT_ADMIN_ROLE` may `unpause()` (`contracts/GyldAtomicSwap.sol:673-680`).

- Machine-checked: **yes** — `[t] test_pause_asymmetric_onlyAdminUnpauses`,
  `[t] test_executeSwap_whenPaused_reverts`.

### I-19 Storage location stability

The ERC-7201 base slot MUST equal
`keccak256(abi.encode(uint256(keccak256("gyld.GyldAtomicSwap")) - 1)) & ~bytes32(0xff)`,
and the field packing in §3.1 MUST hold — an upgrade that reorders or resizes fields
silently corrupts live state (`contracts/GyldAtomicSwap.sol:157-158`). New fields MUST be
appended after `maxQuoteTtl` (`B + 8`).

- Machine-checked: **yes** — `[s] test_storageLayout_erc7201SlotAndPacking` (re-derives
  the slot in Solidity, then `vm.load`s `B+0`/`B+1`/`B+2`/`B+8` and asserts every offset).
  The packing table in §3.1 was confirmed empirically by this test, not merely inferred.

### I-20 Upgrade authority

`_authorizeUpgrade` MUST be gated on `DEFAULT_ADMIN_ROLE`
(`contracts/GyldAtomicSwap.sol:701`), and the implementation's own initializers MUST be
disabled (`contracts/GyldAtomicSwap.sol:223-226`).

- Machine-checked: **yes** — `[s] test_upgradeToAndCall_onlyAdmin` (also asserts
  namespaced state survives the upgrade), `[s] test_implementation_initializersDisabled`.

### I-21 Series deregistration safety

`deregisterSeries` MUST revert `SeriesNotEmpty` while the contract holds any balance of
the series, so priceable inventory is never orphaned
(`contracts/GyldAtomicSwap.sol:563`), and a deregistered series MUST no longer be
tradable.

- Machine-checked: **yes** — `[t] test_deregisterSeries_nonEmpty_reverts`,
  `[t] test_deregisterSeries_unregistered_reverts`;
  `[s] test_deregisterSeries_thenReregister_restoresTradability`.

### I-22 Permit is never load-bearing for authorization

A failed or absent `permit` MUST NOT brick the swap, and a successful `permit` MUST NOT
substitute for the `safeTransferFrom` allowance check
(`contracts/GyldAtomicSwap.sol:419-429`).

- Machine-checked: **yes** — `[t] test_executeSwap_permitFrontRun_doesNotBrick`;
  `[s] test_executeSwap_permitOnTokenWithoutPermit_doesNotBrick`,
  `[s] test_executeSwap_permitBelowDraw_stillEnforcesAllowance`.

### I-23 Quote expiry is TTL-bounded

`executeSwap` MUST revert `QuoteExpiryTooFar` when
`m.expiry > block.timestamp + maxQuoteTtl` — the bound is inclusive, so
`expiry == block.timestamp + maxQuoteTtl` MUST execute
(`contracts/GyldAtomicSwap.sol:396-399`). `maxQuoteTtl` MUST be seeded to
`DEFAULT_MAX_QUOTE_TTL` (1 hour) at `initialize` and MUST only change via the
`DEFAULT_ADMIN_ROLE`-gated `setMaxQuoteTtl` (`contracts/GyldAtomicSwap.sol:277`,
`contracts/GyldAtomicSwap.sol:608-611`). A signer therefore cannot issue an immortal
quote (F-4).

- Machine-checked: **yes** — `[t] test_initialize_seedsDefaultMaxQuoteTtl`,
  `[t] test_executeSwap_expiryBeyondMaxQuoteTtl_reverts`,
  `[t] test_executeSwap_expiryExactlyMaxQuoteTtl_succeeds`,
  `[t] test_setMaxQuoteTtl_onlyAdmin_reverts`, `[t] test_setMaxQuoteTtl_updatesAndEmits`;
  `[s] test_executeSwap_quoteExpiryTtlBound_inclusiveEdge`,
  `[s] test_setMaxQuoteTtl_adminOnly_takesEffectImmediately`.

### I-24 `seriesList` is an observable mirror of `registeredSeries`

`seriesList` MUST stay a duplicate-free mirror of `registeredSeries`, observable via
`seriesCount()`/`seriesAt(i)` (`contracts/GyldAtomicSwap.sol:339-349`), and
`deregisterSeries`'s swap-and-pop MUST move the last element into the removed slot
(`contracts/GyldAtomicSwap.sol:564-574`). Registration order is not stable across
deregistrations (F-5).

- Machine-checked: **yes** — `[t] test_seriesList_registerMultiple_appendsInOrder`,
  `[t] test_seriesList_deregisterMidArray_swapsLastIntoGap`,
  `[t] test_seriesList_deregisterLastElement_popsTail`;
  `[s] test_seriesList_swapAndPop_midArrayAndLastElement`.

### I-25 The 18dp/6dp decimal ladder is enforced on-chain

`registerSeries` MUST revert `InvalidTokenDecimals` unless the bond token reports
`decimals() == 18`, and `initialize` MUST revert `InvalidTokenDecimals` unless the cash
token reports `decimals() == 6` — both probe-before-store, exactly like the forwarder's
8dp probe (`contracts/GyldAtomicSwap.sol:540-546`,
`contracts/GyldAtomicSwap.sol:264-267`). Without this the hard-coded `/1e20` ladder in
`_checkQuoteBand` silently mis-scales (F-1).

- Machine-checked: **yes** — `[t] test_registerSeries_wrongDecimalsToken_reverts`,
  `[t] test_registerSeries_tokenWithoutDecimals_reverts`,
  `[t] test_initialize_wrongDecimalsUsdc_reverts`;
  `[s] test_registerSeries_non18dpToken_reverts`,
  `[s] test_initialize_non6dpCashToken_reverts`.

---

## 7. Authorization matrix

Role hashes (`cast keccak`):

```
DEFAULT_ADMIN_ROLE   0x0000000000000000000000000000000000000000000000000000000000000000
QUOTE_SIGNER_ROLE    0x5ad4c58af6038875a8389a5a539d5aa4662d7168cd0c214c7c203da21c0a0d4f
TREASURER_ROLE       0x3496e2e73c4d42b75d702e60d9e48102720b8691234415963a5a857b86425d07
PAUSER_ROLE          0x65d7a28e3265b37a6474929f336521b332c1681b933f6cb9f3376673440d862a
ALLOWLIST_ADMIN_ROLE 0xe9ea3f660aa5a8eccd1bf9d16e6cdf3c1cf9a2b284b830f15bda4493942cb68f
```

> Integrators SHOULD read the public constants at `contracts/GyldAtomicSwap.sol:88-91`
> rather than hardcoding these hashes.

| Function | Line | Required authority | Effect | Paused? |
| --- | --- | --- | --- | --- |
| `executeSwap` | `:375` | allowlisted `msg.sender` **and** `msg.sender == m.taker` **and** a `QUOTE_SIGNER_ROLE` signature | consumes `quoteId`; moves both legs | **blocked** |
| `hashSwapMessage` | `:449` | none (view) | — | n/a |
| `quoteEpoch` / `usdc` / `withdrawalWallet` / `maxQuoteDeviationBps` / `maxNavAgeSecs` / `maxQuoteTtl` / `registeredSeries` / `navForwarderOf` / `isAllowed` / `isQuoteUsed` / `seriesCount` / `seriesAt` | `:287-349` | none (view) | — | n/a |
| `initialize` | `:246` | one-shot `initializer`; caller becomes nothing | grants the 4 seed roles, sets `usdc`/band/age/ttl | n/a |
| `bumpQuoteEpoch` | `:521` | `DEFAULT_ADMIN_ROLE` | `quoteEpoch += 1`; invalidates all outstanding quotes | live |
| `registerSeries` | `:537` | `DEFAULT_ADMIN_ROLE` | enables a series + its forwarder (forwarder 8dp + token 18dp probe-before-store) | live |
| `deregisterSeries` | `:560` | `DEFAULT_ADMIN_ROLE` | removes a zero-balance series | live |
| `setMaxQuoteDeviationBps` | `:587` | `DEFAULT_ADMIN_ROLE` | widens/narrows the NAV band | live |
| `setMaxNavAgeSecs` | `:596` | `DEFAULT_ADMIN_ROLE` | sets feed freshness bound | live |
| `setMaxQuoteTtl` | `:608` | `DEFAULT_ADMIN_ROLE` | sets the quote-expiry TTL cap (F-4) | live |
| `setWithdrawalWallet` | `:638` | `DEFAULT_ADMIN_ROLE` | sets the sole `withdraw` destination | live |
| `setAllowed` | `:624` | **`ALLOWLIST_ADMIN_ROLE`** (explicitly *not* `DEFAULT_ADMIN_ROLE`) | toggles a taker's `executeSwap` access | live |
| `withdraw` | `:659` | `TREASURER_ROLE` | moves any ERC-20 to `withdrawalWallet` | **live (intentional)** |
| `pause` | `:673` | `PAUSER_ROLE` | halts `executeSwap` | n/a |
| `unpause` | `:678` | `DEFAULT_ADMIN_ROLE` | resumes `executeSwap` | n/a |
| `grantRole` / `revokeRole` | inherited | `DEFAULT_ADMIN_ROLE` (admin of every role) | role registry mutation, incl. signer rotation | live |
| `renounceRole` | `:692` | `msg.sender == callerConfirmation`; **reverts for `DEFAULT_ADMIN_ROLE`, `PAUSER_ROLE`, `TREASURER_ROLE`** | self-removal | live |
| `upgradeToAndCall` | `:701` | `DEFAULT_ADMIN_ROLE` | replaces the implementation | live |

`ALLOWLIST_ADMIN_ROLE` is deliberately split off `DEFAULT_ADMIN_ROLE` (GYL-1050,
`contracts/GyldAtomicSwap.sol:62-67`, `contracts/GyldAtomicSwap.sol:614-621`): in
production `DEFAULT_ADMIN_ROLE` is a 48-hour `TimelockController`, and per-taker
allowlisting must remain a synchronous operational action. It is a hot key that grants
access to *swap* — never to funds and never to upgrades. Its `DEFAULT_ADMIN_ROLE` admin
can revoke it at any time.

---

## 8. Revert catalogue

Selectors from `cast sig`. Custom errors declared at `contracts/GyldAtomicSwap.sol:168-199`.

| Selector | Error | Trigger | Line |
| --- | --- | --- | --- |
| `0xd92e233d` | `ZeroAddress()` | any zero constructor arg in `initialize`; `registerSeries` zero token/forwarder; `setAllowed(0, _)`; `setWithdrawalWallet(0)`; `withdraw` while `withdrawalWallet == 0` | `:258`, `:538`, `:625`, `:639`, `:662` |
| `0x1f2a2005` | `ZeroAmount()` | `m.price == 0`; `amountOut` floors to `0`; `withdraw(_, 0)` | `:385`, `:410`, `:660` |
| `0xb3aa481d` | `RequestedAmountOutOfRange(uint256 requested,uint256 minAllowed,uint256 maxAllowed)` | `requestedAmountIn` is `0`, below the 1% dust floor, or above `maxAmountIn` | `:388-390` |
| `0x1f99570c` | `QuoteExpired(uint64 expiry)` | `block.timestamp > m.expiry` | `:392` |
| `0x573fc08b` | `QuoteExpiryTooFar(uint64 expiry,uint64 maxAllowed)` | `m.expiry > block.timestamp + maxQuoteTtl` — quote too far in the future (F-4) | `:396-399` |
| `0xbab0dc16` | `QuoteEpochStale(uint64 quoteEpoch,uint64 currentEpoch)` | `m.epoch != $.quoteEpoch` (past **or** future) | `:400` |
| `0xbb083ea1` | `QuoteAlreadyUsed(uint256 quoteId)` | bitmap bit already set | `:513` |
| `0x9f6905a9` | `InvalidQuoteSigner(address recovered)` | recovered signer lacks `QUOTE_SIGNER_ROLE` | `:403` |
| `0x6f720739` | `NotTaker(address taker,address caller)` | `m.taker != msg.sender` | `:383` |
| `0xfa5cd00f` | `NotAllowed(address taker)` | `!allowed[msg.sender]` | `:384` |
| `0x450b8820` | `CannotRenounceAdminRole()` | `renounceRole(DEFAULT_ADMIN_ROLE, _)` | `:693` |
| `0x29aaa1be` | `CannotRenouncePauserRole()` | `renounceRole(PAUSER_ROLE, _)` (F-7) | `:694` |
| `0x6b0b4098` | `CannotRenounceTreasurerRole()` | `renounceRole(TREASURER_ROLE, _)` (F-7) | `:695` |
| `0x1799816c` | `UnregisteredSeries(address token)` | `deregisterSeries` on an unregistered token | `:562` |
| `0xe9f7d5b4` | `NotOneBondLeg(address tokenIn,address tokenOut)` | not exactly one registered-series leg against `usdc` (includes `tokenIn == tokenOut`) | `:484` |
| `0x09b1bbd1` | `QuotePriceOutOfBand(uint256 quotedUsdcAmount,uint256 navUsdcAmount)` | quoted USDC outside `navValue ± band` | `:502` |
| `0x7277247e` | `InvalidNav(address token,int256 nav)` | forwarder answer `<= 0` | `:492` |
| `0x5344476d` | `StaleNav(address token,uint256 updatedAt)` | `block.timestamp > updatedAt + maxNavAgeSecs`, **or** `updatedAt > block.timestamp` (future-dated, F-6) | `:495-496` |
| `0x76fae829` | `InsufficientInventory(address token,uint256 requested,uint256 available)` | `tokenOut != usdc` and inventory short | `:439` |
| `0xb937c365` | `InsufficientUsdcLiquidity(uint256 requested,uint256 available)` | `tokenOut == usdc` and the pot is short | `:438` |
| `0x25110ab2` | `InvalidDeviationBps(uint16 bps)` | band `> 10_000` in `initialize` or `setMaxQuoteDeviationBps` | `:259`, `:588` |
| `0x2b07eafa` | `InvalidNavAge(uint32 secs)` | age `== 0` in `initialize` or `setMaxNavAgeSecs` | `:260`, `:597` |
| `0x572625ba` | `NotValidForwarder(address forwarder)` | forwarder staticcall fails or `decimals() != 8` | `:541` |
| `0x3a2d1e17` | `InvalidTokenDecimals(address token,uint8 decimals)` | bond token `decimals() != 18` in `registerSeries`, or cash token `decimals() != 6` in `initialize` (F-1); `decimals == 0` signals no usable `decimals()` | `:265-267`, `:544-546` |
| `0xef2afe8d` | `SeriesNotEmpty(address token)` | `deregisterSeries` with non-zero held balance | `:563` |

### 8.1 Inherited reverts

| Selector | Error | Trigger |
| --- | --- | --- |
| `0xe2517d3f` | `AccessControlUnauthorizedAccount(address,bytes32)` | any `onlyRole` gate |
| `0x6697b232` | `AccessControlBadConfirmation()` | `renounceRole` with `callerConfirmation != msg.sender` |
| `0xd93c0665` | `EnforcedPause()` | `executeSwap` while paused |
| `0x8dfc202b` | `ExpectedPause()` | `unpause()` while not paused |
| `0x3ee5aeb5` | `ReentrancyGuardReentrantCall()` | re-entering `executeSwap`/`withdraw` |
| `0xf645eedf` | `ECDSAInvalidSignature()` | `ecrecover` yields `address(0)` |
| `0xfce698f7` | `ECDSAInvalidSignatureLength(uint256)` | `signature.length != 65` |
| `0xd78bce0c` | `ECDSAInvalidSignatureS(bytes32)` | high-`s` malleable signature |
| `0xf92ee8a9` | `InvalidInitialization()` | second `initialize`, or `initialize` on the implementation |
| `0x1425ea42` | `FailedCall()` / `SafeERC20FailedOperation(address)` `0x5274afe7` | token transfer returned false / reverted |
| `Panic(0x11)` | arithmetic overflow | `requestedAmountIn * price` or `tokenAmount * nav` overflows |

---

## 9. Threat model and trust assumptions

### 9.1 Trusted (assumed honest / correct)

| Component | Trust granted | Blast radius if compromised |
| --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | total | arbitrary upgrade → total loss of held inventory |
| `TREASURER_ROLE` | can move all inventory to `withdrawalWallet` | full drain **to the fixed wallet only**; cannot redirect |
| `withdrawalWallet` (cold) | receives all net flow | funds lost if the key is lost |
| `QUOTE_SIGNER_ROLE` keys | can price any swap within the NAV band | see §9.3 |
| `ALLOWLIST_ADMIN_ROLE` | can allow/deny takers | unauthorized takers gain *access*, still bounded by signed quotes and the band |
| `PAUSER_ROLE` | can halt `executeSwap` | griefing DoS only (`withdraw` unaffected) |
| Registered `NAVFeedForwarder`s | supply the sanity-band reference | a corrupt feed widens/narrows the band; the signed price still executes |
| Registered series tokens | admin-vetted ERC-20s | a malicious series could re-enter (blocked by `nonReentrant`) or lie about balances |

### 9.2 Self-custodial inventory risk (NEW in this architecture)

The contract **is** the custodian. This is the single largest change from the previous
vault design and the largest concentration of value.

- **Exposure ceiling.** The contract's loss ceiling is exactly
  `sum over held tokens of balanceOf(this)`. Nothing more: the contract has no mint
  authority, holds no outbound allowances on other contracts, and is not a spender
  anywhere (`contracts/GyldAtomicSwap.sol:30-38`).
- **What bounds it.**
  1. `executeSwap` can only move inventory against a `QUOTE_SIGNER_ROLE` signature that
     is also inside the NAV band — a rogue taker alone cannot extract anything.
  2. `withdraw` can only move inventory to the admin-fixed `withdrawalWallet`
     (`contracts/GyldAtomicSwap.sol:661-662`); the treasurer has no destination
     parameter, so treasurer-key compromise is a *forced sweep to treasury*, not theft.
  3. `pause()` halts all inflow/outflow through `executeSwap` immediately on a single hot
     multisig signature.
  4. The residual `maxAmountIn - requestedAmountIn` cannot be redrawn (§3.4), so per-quote
     outflow is bounded, not open-ended.
- **What does NOT bound it.** A `DEFAULT_ADMIN_ROLE` compromise is unbounded: an arbitrary
  UUPS implementation can transfer everything. This is why O-1 requires a timelock — the
  timelock delay is the *only* control between an admin-key compromise and total loss.
- **Operational mitigation (out of contract scope).** Keep on-hand inventory at the
  minimum needed for expected fill flow and sweep the surplus via `withdraw` on a
  schedule. The contract does not enforce an inventory cap; there is no
  `maxInventory` parameter.

### 9.3 Hot quote-signer key

The quote signer is an online KMS key. Compromise lets the attacker sign arbitrary
`SwapMessage`s.

- **Still bounded by:** the taker binding (`m.taker` must be an address the attacker
  controls **and** that address must be allowlisted, `:383-384`), the NAV band
  (`:501-503`, so the attacker cannot price at 1 wei), single-use `quoteId`s, `expiry`
  (TTL-capped since F-4, `:396-399`), and available inventory.
- **Realistic worst case:** the attacker allowlists nothing (they lack that role) but may
  already control an allowlisted taker. They then drain up to the band edge repeatedly —
  `maxQuoteDeviationBps` of value per round trip, unbounded in the number of round trips
  until noticed. **The band limits per-swap slippage, not cumulative extraction.**
- **Revocation path and its latency.** `revokeRole(QUOTE_SIGNER_ROLE, key)` and
  `bumpQuoteEpoch` are both `DEFAULT_ADMIN_ROLE` — i.e. timelocked in production. The
  fast path is `pause()` (`PAUSER_ROLE`, ops multisig). Hence O-6: **pause first**.
- Rotation is grant/revoke plus `bumpQuoteEpoch` to kill quotes signed by the old key that
  are still in flight (`contracts/GyldAtomicSwap.sol:43-44`,
  `contracts/GyldAtomicSwap.sol:518-520`).

### 9.4 Price manipulation via the `price` field

`price` is signed data, not derived on-chain, so it is the primary economic attack
surface.

- A taker cannot alter `price`: doing so changes the digest and yields
  `InvalidQuoteSigner` (`[t] test_executeSwap_tamperedMessage_reverts`).
- A malicious signer's pricing freedom is exactly `± maxQuoteDeviationBps` around the feed
  NAV (`contracts/GyldAtomicSwap.sol:501-503`). Setting the band to `0` forces exact-NAV
  quotes and, given floor division, effectively soft-pauses `executeSwap`
  (`contracts/GyldAtomicSwap.sol:583-585`).
- Feed manipulation is a *precondition* for widening that freedom. The forwarder is
  admin-registered and probed for 8 decimals and the bond token for 18
  (`contracts/GyldAtomicSwap.sol:540-546`), but
  a compromised feed publisher can move `navValue` and drag the band with it. NAV
  integrity is `NAVFeedForwarder`'s responsibility — **out of scope here**.
- Rounding is always in the contract's favour (§5.4), so no dust-extraction loop exists
  for the taker. The `MIN_DRAW_BPS` floor additionally stops a taker from griefing the
  signer's `quoteId` budget with near-zero draws
  (`contracts/GyldAtomicSwap.sol:126-129`).
- `maxAmountIn`/`price` are *not* a slippage protection for the taker: the taker chooses
  `requestedAmountIn` after seeing the price, so the taker's protection is simply refusing
  to submit.

### 9.5 Permit front-running

The classic EIP-2612 griefing vector: an observer replays the permit from the mempool,
consuming the nonce, so the victim's in-swap `permit` reverts and bricks the swap.
Mitigated by the `try/catch` at `contracts/GyldAtomicSwap.sol:419-425` — the failure is
swallowed and the front-runner's own permit has already set the allowance that step 17
needs. Machine-checked by `[t] test_executeSwap_permitFrontRun_doesNotBrick`.

Corollary risk accepted: `permitIn` is entirely unauthenticated relative to the quote (it
is not covered by the EIP-712 signature). A third party can therefore submit a *different*
valid permit for the taker. This grants no capability — the allowance still belongs to the
taker and only `safeTransferFrom(msg.sender, ...)` consumes it, and `msg.sender` must be
the bound taker.

### 9.6 Upgrade authority

UUPS with `_authorizeUpgrade` gated on `DEFAULT_ADMIN_ROLE`
(`contracts/GyldAtomicSwap.sol:701`); the implementation's initializers are disabled in
its constructor (`contracts/GyldAtomicSwap.sol:223-226`). `DEFAULT_ADMIN_ROLE`,
`PAUSER_ROLE`, and `TREASURER_ROLE` are
non-renounceable to prevent accidentally bricking upgrades, unpause, signer rotation, and
the incident-response pair (`contracts/GyldAtomicSwap.sol:684-691`). Storage is ERC-7201
namespaced (§3.1), so an
upgrade MUST preserve the field order and packing in §3.1 (I-19). **Upgrade authority is
the top of the risk stack: it dominates every other control in this document.**

### 9.7 Cross-chain and cross-deployment replay

The EIP-712 domain binds `chainId` and `verifyingContract` (§5.1), so a quote signed for
one chain or one proxy cannot be replayed on another even if the proxy is deployed at the
same address (I-13). OZ's `EIP712Upgradeable` recomputes the separator when
`block.chainid` differs from the cached value, so a post-fork chain is also distinct.
Note that `quoteId` uniqueness (S-1) is *per proxy*, since the bitmap is per-proxy storage.

### 9.8 Explicitly out of scope

- Sanctions/OFAC screening. Deliberately absent from this contract: every swap has exactly
  one `GyldBondToken` leg and that token's `_update` screens `from`, `to`, **and** this
  contract as spender, fail-closed via the Chainalysis oracle
  (`contracts/GyldAtomicSwap.sol:51-55`). A swap between two non-bond tokens is impossible
  (I-14), so no swap escapes screening.
- `NAVFeedForwarder` / `KaleidoscopeNAVFeed` correctness and liveness.
- `IssuanceManager` inventory replenishment and the AP whitelist.
- The off-chain quote service: pricing model, `quoteId` allocation, KMS custody, rate
  limiting, and taker KYC.
- Treasury operations downstream of `withdrawalWallet`.
- L1 reorg / censorship handling. `expiry` is the only liveness bound.
- Gas-griefing by malicious registered series (return-bomb, unbounded-loop transfer
  hooks). Series registration is admin-gated and assumed vetted.
- ERC-20s with transfer fees, rebasing, or non-standard return values. The contract uses
  `SafeERC20` but performs no fee-on-transfer accounting: it pushes `amountOut` and pulls
  `requestedAmountIn` at face value.

---

## 10. Findings and remediations

All seven findings below are **REMEDIATED** in the current `contracts/GyldAtomicSwap.sol`.
Each entry records the original finding (line references are to the pre-fix code) followed
by the remediation actually applied and where. Behavioural conformance changes are folded
back into §1.2 (C-5/C-6/C-8, S-4, O-4), §3.1, §3.2, §4, §6 (I-8/I-15/I-19/I-23/I-24/I-25),
§7, and §8.

### F-1 — NAV band silently mis-scales for non-18dp series or non-6dp cash token — **Medium — REMEDIATED**

`_checkQuoteBand` hard-codes the decimal ladder: `navValue = tokenAmount * nav / 1e20`
assumes bond `18dp`, NAV `8dp`, USDC `6dp` (`contracts/GyldAtomicSwap.sol:414`,
`contracts/GyldAtomicSwap.sol:436`). Only the *forwarder's* decimals are validated
(`contracts/GyldAtomicSwap.sol:475-476`). Neither `registerSeries` nor `initialize` checks
`IERC20Metadata(token).decimals() == 18` or `IERC20Metadata(usdc_).decimals() == 6`.

Registering, say, a 6-decimal series makes `navValue` smaller by `1e12`, so `navValue + band`
is far below any realistic `usdcAmount` and every quote reverts `QuotePriceOutOfBand`
(fail-closed, merely bricking). The dangerous direction is a **higher**-decimal token or a
higher-decimal cash token, which inflates `navValue` and makes the band vacuous — the sole
economic guard rail on a compromised quote signer (§9.3) silently disappears with no error.

Severity is Medium rather than High because it requires a `DEFAULT_ADMIN_ROLE`
(timelocked) misconfiguration; the impact is a silent loss of a security control rather
than an immediately exploitable bug.

**Proposed fix:** extend the existing probe-before-store idiom at
`contracts/GyldAtomicSwap.sol:475-476` to also staticcall `decimals()` on `token` and
require `18`, and add the same probe for `usdc_` in `initialize` requiring `6`. Failing
that, store per-series `decimals` and compute the divisor dynamically.

**Remediation — implemented as proposed.** `registerSeries` now staticcall-probes the bond
token for `decimals() == 18` after the forwarder probe, and `initialize` staticcall-probes
the cash token for `decimals() == 6`; both revert the new `InvalidTokenDecimals(token,
decimals)` (`contracts/GyldAtomicSwap.sol:543-546`,
`contracts/GyldAtomicSwap.sol:264-267`, error at `:198`). O-4 is now enforced on-chain
(I-25).

### F-2 — `SwapMessage` doc comment implies multi-draw; code is strictly single-draw — **Low (documentation) — REMEDIATED**

`contracts/GyldAtomicSwap.sol:97-98` says `maxAmountIn`/`price` "bound a *range* of draws,
not one exact amount", and `contracts/GyldAtomicSwap.sol:103` calls `maxAmountIn` a
"ceiling on tokenIn the taker may draw against this quote". Read naturally, both suggest a
running allowance across multiple draws. The code permits exactly one draw and forfeits
the residual (`contracts/GyldAtomicSwap.sol:347`, `contracts/GyldAtomicSwap.sol:450`); the
`@dev` block at `contracts/GyldAtomicSwap.sol:311-313` states the real semantics but the
struct-level comment a reader hits first does not. An integrator building a partial-fill UI
on the struct comment would ship broken retry logic.

**Proposed fix:** reword `:97-98` to "bound a range of *draw sizes*, exactly one of which
may be taken — the unused remainder is forfeited", and `:103` to "ceiling on the taker's
single draw of tokenIn".

**Remediation — implemented as proposed.** Struct doc and `maxAmountIn` field comment
reworded verbatim per the proposal (`contracts/GyldAtomicSwap.sol:97-99`,
`contracts/GyldAtomicSwap.sol:107`).

### F-3 — `quoteId` bitmap is not epoch-scoped; `quoteId` reuse across epochs bricks quotes — **Low — REMEDIATED**

`usedQuoteWords` is keyed only by `quoteId` (`contracts/GyldAtomicSwap.sol:137`,
`contracts/GyldAtomicSwap.sol:448`) and `bumpQuoteEpoch` writes only `quoteEpoch`
(`contracts/GyldAtomicSwap.sol:459`). A consumed id is therefore consumed for the lifetime
of the proxy, across every epoch. If the quote service ever restarts its counter — a
service redeploy, a per-epoch reset, or a database restore — previously-consumed ids
resurface and legitimate quotes revert `QuoteAlreadyUsed`. This is fail-closed (no value
at risk) but is a silent availability regression that would present as intermittent
user-facing failures.

This is a requirement on the signer (S-1) that the contract cannot enforce, and it is not
currently stated in the contract's own documentation.

**Proposed fix:** no contract change required. Document the constraint at
`contracts/GyldAtomicSwap.sol:100` ("single-use, globally and permanently, across all
epochs") and enforce a monotonic global counter in the quote service. Pinned by
`[s] test_consumedQuoteId_survivesEpochBump` (I-5).

**Remediation — implemented as proposed (documentation only).** The `quoteId` field now
carries the constraint in a dedicated comment block ("Single-use, globally and
permanently, across ALL epochs — the usage bitmap below is NOT epoch-scoped ...")
(`contracts/GyldAtomicSwap.sol:101-104`). No code change; I-5 remains the pin.

### F-4 — `expiry` has no upper bound; immortal quotes are signable — **Low — REMEDIATED**

`contracts/GyldAtomicSwap.sol:341` only checks `block.timestamp > m.expiry`. A buggy or
compromised signer can issue `expiry = type(uint64).max`, producing a quote that never
expires. Such a quote outlives the freshness assumption the NAV band implicitly relies on
and can only be revoked by `bumpQuoteEpoch` — a `DEFAULT_ADMIN_ROLE` action, hence
timelocked in production (§9.3). Combined with the taker binding it is not directly
exploitable by a third party, but it removes `expiry` as a containment control precisely
in the scenario where containment matters.

**Proposed fix:** add an admin-set `maxQuoteTtl` and require
`m.expiry <= block.timestamp + maxQuoteTtl` alongside the existing check at
`contracts/GyldAtomicSwap.sol:341`.

**Remediation — implemented as proposed.** New `uint64 maxQuoteTtl` storage field appended
at `B + 8` (ERC-7201 append-only, §3.1), seeded to `DEFAULT_MAX_QUOTE_TTL = 1 hours` in
`initialize` (`contracts/GyldAtomicSwap.sol:277`); `executeSwap` reverts the new
`QuoteExpiryTooFar(expiry, maxAllowed)` when `m.expiry > block.timestamp + maxQuoteTtl`
(`contracts/GyldAtomicSwap.sol:396-399`); admin setter `setMaxQuoteTtl` emits
`MaxQuoteTtlUpdated` (`contracts/GyldAtomicSwap.sol:608-611`). See C-8, S-4, I-23.

### F-5 — `seriesList` is write-mostly and unobservable — **Informational — REMEDIATED**

`seriesList` (`contracts/GyldAtomicSwap.sol:138`) has no getter and is read only by
`deregisterSeries`'s O(n) swap-and-pop (`contracts/GyldAtomicSwap.sol:494-504`). Its
correctness — that the array stays a duplicate-free mirror of `registeredSeries` — is
therefore neither observable off-chain nor machine-checkable. The swap-and-pop is currently
untested for the "target is the last element" and "target is mid-array" cases.

**Proposed fix:** add `seriesCount()` and `seriesAt(uint256)` view functions, then pin the
swap-and-pop behaviour in tests. (Cannot be tested from outside today, which is why I-21's
coverage stops at the observable `registeredSeries`/`navForwarderOf` effects.)

**Remediation — implemented as proposed.** `seriesCount()` and `seriesAt(uint256)` added
(`contracts/GyldAtomicSwap.sol:339-349`); the mid-array and last-element swap-and-pop
cases are now pinned in both suites (I-24).

### F-6 — Future-dated NAV timestamps bypass the staleness guard — **Informational — REMEDIATED**

`contracts/GyldAtomicSwap.sol:433` computes `block.timestamp > updatedAt + maxNavAgeSecs`.
An `updatedAt` in the future makes the right-hand side larger than `block.timestamp`, so
the check passes unconditionally — a misconfigured or malicious forwarder reporting a
future timestamp is treated as maximally fresh, and a stuck-but-future-dated feed would
never trip `StaleNav`. Impact is limited because the forwarder is admin-registered and the
band still constrains pricing.

**Proposed fix:** also reject `updatedAt > block.timestamp` at
`contracts/GyldAtomicSwap.sol:433`.

**Remediation — implemented as proposed, reusing `StaleNav` (the spec recommended no new
error).** `_checkQuoteBand` now reverts `StaleNav(bondToken, updatedAt)` when
`updatedAt > block.timestamp`, ahead of the age check
(`contracts/GyldAtomicSwap.sol:493-496`). Folded into C-5/I-15.

### F-7 — `PAUSER_ROLE` and `TREASURER_ROLE` are renounceable, unlike `DEFAULT_ADMIN_ROLE` — **Informational — REMEDIATED**

The `renounceRole` override guards only `DEFAULT_ADMIN_ROLE`
(`contracts/GyldAtomicSwap.sol:607-610`). If the sole `PAUSER_ROLE` holder renounces —
accidentally or maliciously — the fast incident-response halt is unavailable until the
timelock re-grants it, which in production is the same 48-hour delay that `pause()` exists
to bypass (§9.3, O-6). The same argument applies to `TREASURER_ROLE` and the ability to
evacuate funds while paused. The contract's own rationale for admin non-renounceability
("losing it permanently bricks ...", `contracts/GyldAtomicSwap.sol:603-606`) applies with
reduced but non-zero force here.

**Proposed fix:** either extend the `renounceRole` guard to any role whose member count
would drop to zero, or accept and document the risk with an operational requirement that
`PAUSER_ROLE` and `TREASURER_ROLE` always have at least two holders.

**Remediation — implemented as an unconditional guard, matching the existing
`CannotRenounceAdminRole` pattern (diverges from both proposed options: simpler than
member-count tracking, stricter than accept-and-document).** `renounceRole` now reverts
`CannotRenouncePauserRole()` / `CannotRenounceTreasurerRole()` for those roles
(`contracts/GyldAtomicSwap.sol:692-697`, errors at `:181-182`). `QUOTE_SIGNER_ROLE` and
`ALLOWLIST_ADMIN_ROLE` remain renounceable. Folded into C-6/I-8.

---

## 11. Verification record

| Check | Method | Result |
| --- | --- | --- |
| `SWAP_MESSAGE_TYPEHASH` | `cast keccak` on the derived canonical type string vs `contracts/GyldAtomicSwap.sol:124` | **MATCH** |
| ERC-7201 base slot | `cast index-erc7201 gyld.GyldAtomicSwap` vs `contracts/GyldAtomicSwap.sol:158` | **MATCH** |
| Error selectors | `cast sig` for all 25 custom errors (§8) | recorded |
| Test vector 1 struct hash / digest | `cast abi-encode` + `cast keccak`, cross-checked on-chain in `[s]` | **MATCH** |
| Test vector 2 struct hash / digest | `cast abi-encode` + `cast keccak`, cross-checked on-chain in `[s]` | **MATCH** |
| Build | `forge build` | pass |
| Suite (baseline, before this spec) | `forge test` | 398 passed, 0 failed |
| Suite (after adding `GyldAtomicSwap.spec.t.sol`) | `forge test` | **427 passed, 0 failed** (+29) |
| Suite (after the F-1..F-7 remediation) | `forge test` | **494 passed, 0 failed** (+21 remediation tests over the then-current 473) |

**Remediation round (F-1..F-7).** `contracts/GyldAtomicSwap.sol` was modified as described
per finding in §10: decimals probes in `registerSeries`/`initialize` (F-1), comment
rewording (F-2/F-3), `maxQuoteTtl` + `QuoteExpiryTooFar` + `setMaxQuoteTtl` (F-4),
`seriesCount`/`seriesAt` (F-5), the future-dated `StaleNav` check (F-6), and the
`PAUSER_ROLE`/`TREASURER_ROLE` renounce guards (F-7). Storage remains ERC-7201
append-only (`maxQuoteTtl` at `B + 8`, pinned by
`[s] test_storageLayout_erc7201SlotAndPacking`); the EIP-712 wire format is untouched.
`contracts/test/GyldAtomicSwap.invariants.t.sol` was **not modified**. New tests: 14 in
`contracts/test/GyldAtomicSwap.t.sol` and 7 in `contracts/test/GyldAtomicSwap.spec.t.sol`
(§6 machine-checked lists); one pre-existing spec test
(`test_executeSwap_neitherLegUsdc_reverts`) now registers a real 18-decimal mock instead
of an EOA because `registerSeries` probes `decimals()` on-chain (F-1).

Coverage already complete before this spec, and therefore **not duplicated** in the new
file: I-2 (replay), I-6 (allowlist), I-7 (taker binding), I-10/I-11 (conservation and
price fidelity on the BUY leg), I-16 (withdrawal destination), I-18 (pause asymmetry), and
the typehash/domain regression pair. Gaps that the new file closes: I-2a, I-5, I-9, I-13,
I-19, I-20, plus the boundary and edge cases enumerated per invariant in §6.
