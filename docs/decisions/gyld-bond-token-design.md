# Decision: GyldBondToken — compliance model and upgradeability

**Status:** Adopted  
**Date:** 2026-05-06  
**Applies to:** `contracts/GyldBondToken.sol`, `contracts/IssuanceManager.sol`, `contracts/TokenFactory.sol`

---

## 1. Compliance: Chainalysis only — no internal blacklist

### What we do

`GyldBondToken` reads **exclusively** from the Chainalysis on-chain sanctions oracle
(`ISanctionsList.isSanctioned(address)`). Every secondary transfer checks the sender,
receiver, and spender against this oracle. If any party is sanctioned the transfer reverts.

```
_requireAccess(sender)   → reverts if Chainalysis marks them sanctioned
_requireAccess(receiver) → reverts if Chainalysis marks them sanctioned
_requireAccess(spender)  → reverts if Chainalysis marks them sanctioned (transferFrom)
```

Fail-closed: if the oracle itself reverts (e.g. oracle contract is down), the transfer
also reverts. We do not fail open.

### What we deliberately do NOT have

There is **no internal blacklist** — no platform-managed mapping of blocked addresses
separate from the Chainalysis feed. We will not add one.

### Why

1. **Chainalysis is sufficient.** The oracle covers OFAC/SDN, UN, and EU consolidated
   lists in real time. Any address that requires blocking for regulatory purposes will
   appear there.

2. **No dual-list complexity.** An internal blacklist requires its own governance
   (who can add, who can remove, with what delay, auditable how?). That operational
   overhead adds risk without adding meaningful protection beyond what Chainalysis
   already provides.

3. **Regulatory clarity.** Blocking decisions are made by the oracle, not the
   platform. If an address is not sanctioned by OFAC/SDN/UN it can transact.
   This is simpler to explain to regulators, auditors, and counterparties than
   "we have our own internal list plus the oracle."

4. **Freeze is sufficient for Phase 1.** Sanctioned addresses are frozen in place
   by the oracle — all transfers to/from them revert automatically. No on-chain
   recovery function exists. If legal action requires physical token movement, the
   platform escalates off-chain. This keeps the contract surface minimal.

### Spender check — enforced at the blockchain layer

Standard ERC-20 only checks the sender and receiver on `transferFrom`. We also check
the **spender** (`msg.sender` — the address holding the allowance). This is implemented
directly in `GyldBondToken.sol` and enforced on-chain at every call:

```solidity
function transferFrom(address from, address to, uint256 amount) public override {
    _requireAccess(from);         // sender must not be sanctioned
    _requireAccess(to);           // receiver must not be sanctioned
    _requireAccess(_msgSender()); // spender must not be sanctioned ← blockchain-enforced
    _spendAllowance(from, _msgSender(), amount);
    _transfer(from, to, amount);
}
```

**Why this matters:** without the spender check, a sanctioned address could obtain an
allowance from a clean wallet and drain it freely — bypassing the entire sanctions
system through the approval mechanism. With the spender check, no sanctioned address
can initiate a token movement regardless of how the allowance was granted.

**This is not an application-layer or database check.** It runs inside the smart contract
on Ethereum. No backend code, API call, or admin action is required — the blockchain
itself rejects the transaction.

### Owner / admin auto-approval — explicitly not implemented

**The admin address does not bypass sanctions.** `GyldBondToken` uses OZ `AccessControl`,
not `Ownable`, so there is no `owner` at all. `_requireAccess` has zero role-based
exemptions — it is called identically for every address:

```solidity
function _requireAccess(address account) internal view {
    ISanctionsList sl = _getStorage().sanctionsList;
    if (address(sl) != address(0)) {
        require(!sl.isSanctioned(account), "GyldBondToken: account sanctioned");
    }
}
```

`DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`, `BURNER_ROLE`, `PAUSER_ROLE` — if any holder of
these roles is flagged by Chainalysis, their secondary transfers revert like anyone else's.

**Two intentional narrow exceptions (sanctions oracle only):**

| Path | Oracle called? | Reason |
|------|---------------|--------|
| `mint()` / `burn()` | No | `IssuanceManager` pre-screens APs off-chain before calling. Primary issuance, not secondary transfer. Note: `whenNotPaused` IS enforced on mint/burn — pause halts all token movement including primary issuance. |

**Off-chain (Rust) layer:** `Minting::execute` screens the user's destination wallet
via `IAddressScreener::screen_address` before creating an order. The platform operator
address is not screened in this path — consistent with the contract design where
mint/burn skip the oracle.

### Consequences for developers

- Do not add an internal blacklist mapping to `GyldBondToken`. If you see a
  `mapping(address => bool) blocked` or similar, remove it.
- Do not add an admin function that bypasses the Chainalysis oracle.
- Do not add a role-based carve-out to `_requireAccess`. All secondary transfers must
  go through the oracle regardless of the caller's role.
- The oracle address is set at `initialize()` and can be updated by
  `DEFAULT_ADMIN_ROLE` via `setSanctionsList()`. In dev/Anvil use `MockSanctionsList`.

---

## 2. Upgradeability: GyldBondToken is intentionally UUPS-upgradeable

### What we do

`GyldBondToken` is deployed behind an `ERC1967Proxy` (UUPS pattern). The implementation
can be swapped by `DEFAULT_ADMIN_ROLE` (a `TimelockController` in production).

### Why we keep it upgradeable

1. **Critical bug patches post-issuance.** A fixed-term bond may be live for 6–24 months.
   If a security vulnerability is discovered mid-life, we must be able to patch it
   without migrating all holders to a new token address. Immutable contracts cannot be
   patched.

2. **Stable token addresses.** Exchanges, custodians, DeFi protocols, and legal
   documentation all reference the token address. A migration to a new address
   requires re-listing, legal amendments, and AP re-onboarding — operationally
   infeasible for a regulated bond product.

3. **ERC-7201 namespaced storage prevents collision.** All state lives at a fixed,
   namespace-derived storage slot. New implementation versions can safely add storage
   without shifting existing slots. This eliminates the main risk of upgradeable tokens.

4. **Timelock on upgrades.** `DEFAULT_ADMIN_ROLE` must be a `TimelockController`
   (deployed via `DeployTimelock.s.sol`). Any upgrade proposal is visible on-chain for
   the delay period (minimum 48h for all operations) before it can
   execute. This gives token holders time to react.

### What this is NOT

- Not an owner backdoor. Upgrades go through the timelock, not a single hot key.
- Not storage-unsafe. ERC-7201 namespacing is specifically designed for this.
- Not a reason to deploy upgrades casually. Upgrades are for security patches only.
  Any logic change must be reviewed and announced via the timelock.

### Consequences for developers

- Do not remove `UUPSUpgradeable` from `GyldBondToken`.
- Do not change state variable layout in a way that shifts existing ERC-7201 storage slots.
  Always add new fields inside the `GyldBondTokenStorage` struct, never outside it.
- `_authorizeUpgrade` is gated by `DEFAULT_ADMIN_ROLE`. In production this must be
  the `TimelockController` address, not a plain EOA or multisig.

---

## 3. Token model: plain ERC-20 — no shares, no multiplier, no rebasing

### What we do

`GyldBondToken` is a standard OpenZeppelin ERC-20. Balances are fixed integer amounts.
They change only via `mint()` (subscription) and `burn()` (redemption). Nothing else
changes a holder's balance.

```
balanceOf(account) = standard OZ ERC20 balance
                   = only changes on mint / burn
```

Value accrual (coupons, NAV appreciation, price changes) is reflected **exclusively**
in the paired `KaleidoscopeNAVFeed` oracle. The token balance says "you own 100 units."
The NAV feed says "each unit is worth $X today."

### What we deliberately do NOT have

- No `shares` internal accounting
- No `multiplier` or NAV accrual inside the token
- No `burnShares()` / `redeemShares()` / `transferShares()` / `sharesOf()`
- No `MULTIPLIER_UPDATER_ROLE`
- No rebasing — the number of tokens in a wallet never changes from NAV movement

### Why

1. **Off-chain settlement model.** Mint and burn are triggered by the backend after
   confirmed off-chain settlement (USDC received / bond purchased). The backend always
   knows the exact token amount. There is no on-chain accumulation that needs a
   separate share-based accounting layer.

2. **No dust residual in practice.** `burnShares` exists to solve a rounding residual
   problem that arises when converting token amounts to shares and back. With a plain
   ERC-20 there is no conversion — `burn(address, amount)` deducts exactly `amount`.
   No residual, no cleanup transaction needed.

3. **Simpler audit surface.** Share/multiplier math is bespoke and expensive to audit.
   Standard OZ ERC-20 mint/burn is the most-reviewed code in the ecosystem. Removing
   the multiplier cuts ~150 lines of custom math from the audit scope.

4. **NAV lives in the oracle, not the token.** `KaleidoscopeNAVFeed` + `NAVFeedForwarder`
   publish NAV-per-token on-chain in Chainlink `AggregatorV3Interface` format. DeFi
   protocols (Morpho Blue, Aave), wallets, and price aggregators read the oracle. The
   token contract itself stays simple.

### Consequences for developers

- Do not add a `shares` mapping or `multiplier` field to `GyldBondToken`.
- Do not add `burnShares()`, `transferShares()`, or `sharesOf()` to the token or its interface.
- Do not add a `MULTIPLIER_UPDATER_ROLE`.
- NAV updates go to `KaleidoscopeNAVFeed.updateAnswer()` — never into the token contract.
- The backend always burns by token amount (`burn_token(contract, from, amount)`) via
  `IChain`. There is no `burn_shares` port method and there should never be one.

---

## 4. NAV oracle — KaleidoscopeNAVFeed circuit breakers and updater model

### What we do

Every bond series deployed by `TokenFactory` gets a paired `KaleidoscopeNAVFeed`
contract. This contract publishes the NAV-per-token (Net Asset Value) on-chain in
Chainlink `AggregatorV3Interface` format so that DeFi protocols, wallets, and price
aggregators can read the current value of the bond token without trusting any
off-chain API.

```
NAV per token = (bonds held × bond price in USD) / tokens outstanding

Example: platform holds 1,000 TLT at $95.42
         10,000 GYLD-TLT tokens outstanding
         NAV per token = $9.542  →  on-chain as 954_200_000  (8 decimals)
```

### Why NAV lives here and not in the token

Token balances are fixed integers. They change only via `mint()` and `burn()`.
Value accrual (coupon, price appreciation) is reflected exclusively in the NAV feed.
This keeps `GyldBondToken` a plain ERC-20 — no rebasing, no multiplier, no bespoke
math. See Section 3 for the full rationale.

### Three circuit breakers — all enforced on-chain

Every call to `updateAnswer()` is gated by three hard limits. These are constants
in `KaleidoscopeNAVFeed.sol` and cannot be changed without deploying a new contract.

#### 1. MAX_PRICE_DEVIATION_BPS = 1000 (10% maximum move per update)

```solidity
int256 diff = answer > last ? answer - last : last - answer;
require(diff * 10_000 <= last * int256(MAX_PRICE_DEVIATION_BPS), "price deviation too large");
```

A single `updateAnswer()` call cannot move the price more than 10% from the
previous value. A fat-fingered update (e.g. $95.42 entered as $954.20) reverts.
A compromised updater key cannot crash NAV by more than 10% in one transaction.

Bond prices do not move 10% in a single day under normal market conditions —
TLT moved ~4% on its worst day in the 2022 bond crash. 10% is wide enough for
any legitimate daily NAV update and tight enough to catch errors and attacks.

The cap applies only after the first update. The initial price anchor has no
previous value to compare against and is accepted as-is.

#### 2. MIN_UPDATE_INTERVAL = 1 hour (minimum gap between updates)

```solidity
require(block.timestamp >= _updatedAt + MIN_UPDATE_INTERVAL, "update too soon");
```

Even if the updater key is compromised, the attacker can push at most one 10%
move per hour. Combined with the deviation cap, this gives the operations team
time to detect the attack, pause the token, and rotate the key before significant
damage accumulates.

The intended update cadence for a bond product is once per day (after market close).
The 1-hour minimum is a security floor, not the operational target.

#### 3. MAX_STALENESS = 36 hours (reads revert if price is too old)

```solidity
require(block.timestamp - _updatedAt <= MAX_STALENESS, "price stale");
```

If no update has been pushed for 36 hours, every call to `latestRoundData()` and
`latestAnswer()` reverts. DeFi protocols (Morpho Blue, Aave) call these before
accepting collateral deposits or computing loan health. A stale feed causes them
to stop accepting the token as collateral — which is the correct behaviour. Silently
returning a 2-day-old bond price is worse than reverting.

36 hours covers weekends and US market holidays: a NAV pushed Friday at market
close remains fresh through Saturday and most of Sunday. Missing Monday morning
triggers staleness and forces an update before DeFi activity resumes.

### Chainlink interface — what DeFi protocols call

`KaleidoscopeNAVFeed` implements two Chainlink interfaces:

| Function | Interface version | Who calls it |
|---|---|---|
| `latestRoundData()` | AggregatorV3Interface (V3) | Morpho Blue, most modern protocols |
| `latestAnswer()` | AggregatorInterface (V2) | Aave V3 (uses the older call) |

Both check staleness via `_requireFresh()` before returning. Both return the same
current price — there is no difference in the value returned.

Historical rounds are **not stored**. `getRoundData(roundId)` only accepts the
current round ID and reverts for any other value. DeFi protocols do not need
historical NAV. If a future use case requires it (e.g. time-weighted NAV for
a structured product), the feed must be upgraded to a version that stores a
round history mapping.

### Updater key model and upgrade path

The address that may call `updateAnswer()` is set at deploy time as `navFeedOwner`
via `TokenFactory.deployToken()`. Ownership uses `Ownable2Step` — transferring
to a new address requires the new address to call `acceptOwnership()` first,
preventing accidental lockout.

Three phases of increasing security:

| Phase | Updater setup | Security property |
|---|---|---|
| **Phase 1 (now)** | Single AWS KMS key | Key never leaves HSM; circuit breakers limit blast radius |
| **Phase 2 (pre-mainnet)** | Fordefi MPC wallet | Private key split 3-of-3, threshold 2-of-3; no single machine can sign; fully automated daily push |
| **Phase 3 (scale)** | Multi-source aggregator contract | Independent data sources each submit NAV; median forwarded when M-of-N agree |

The contract needs **no changes** for Phase 1 → Phase 2. Call
`transferOwnership(fordefiAddress)` from the current owner; Fordefi calls
`acceptOwnership()`. From `KaleidoscopeNAVFeed`'s perspective it is still
a single address calling `updateAnswer()` — MPC threshold happens at the
signing layer, invisible to the contract.

### Why `MAX_PRICE_DEVIATION_BPS` has no emergency override

During the pre-mainnet security audit (GYL-309, finding M-3), the question was raised:
what happens if a legitimate NAV move exceeds 10% in a single update? The proposed fix
was a `forceUpdateAnswer()` function callable by the owner or a separate "emergency updater"
(ops Gnosis Safe) that would bypass the deviation cap while keeping the 1-hour interval.

We implemented it, then reverted it. The reasons:

**1. The trigger condition doesn't exist for the assets we tokenize.**

`KaleidoscopeNAVFeed` is used for T-bills, Treasury ETFs (e.g. TLT), and
investment-grade corporates. Historical single-day price moves for these instruments:

| Asset class | Typical daily move | Worst single day (recent history) |
|---|---|---|
| T-Bills (3m–1y) | 0.01% – 0.1% | ~0.5% (2022 rate shock) |
| TLT (20yr Treasury ETF) | 0.3% – 1.5% | ~4.7% (COVID crash, March 2020) |
| IG corporate bonds | 0.2% – 2% | ~5% (extreme stress) |

A single-hour move of >10% in any of these instruments would require a US sovereign
default or an event of similar severity — once-in-a-century, not a routine edge case.
The 10% cap has never been a realistic operational constraint for this asset class.

**2. Chained updates cover any realistic large-move scenario.**

The 1-hour interval + 10% per-update cap lets you cover substantial moves through
sequential calls:

| Target total move | Chained updates required | Wall-clock time |
|---|---|---|
| 15% | 2 updates (10%, then 4.5% of new price) | 2 hours |
| 25% | 3 updates | 3 hours |
| 40% | 4 updates | 4 hours |

For investment-grade bonds, any move >10% is a multi-day event unfolding over
hours, not minutes. A 2–3 hour correction window is operationally fine.

**3. The bypass eliminates the cap's core security property.**

`KaleidoscopeNAVFeed` is **not UUPS-upgradeable** — unlike `GyldBondToken`, it has no
proxy and no upgrade path. Before the bypass existed, the 10% cap was a hard
cryptographic rate limit that applied to the owner too. A compromised KMS signer could
do at most one 10% move per hour, giving the operations team time to detect the
anomaly, pause `GyldBondToken`, and rotate the key.

Once `forceUpdateAnswer()` is callable by the owner, a compromised key can push NAV
to 1 wei in a single transaction. Every Morpho Blue borrower with bond token collateral
is instantly liquidated. The bypass turns a contained attack (10% damage per hour,
alertable) into an immediate total loss event.

**4. An "emergency updater" adds a second privilege escalation path.**

The proposed emergency bypass included an optional ops Gnosis Safe address
(`_emergencyUpdater`) that could also call `forceUpdateAnswer()`. This introduces a
second key whose compromise has the same catastrophic effect as point 3. Adding
privilege paths to solve a problem that doesn't occur in practice is net-negative
security.

**5. Gradual price discovery protects Morpho Blue users.**

If a bond genuinely drops 15% over 24 hours, chained updates publish it as three
steps spaced 1+ hour apart. Borrowers see each step in `latestRoundData()`, can add
collateral or repay, and get liquidated only if they choose not to. An emergency
single-transaction 15% crash gives no reaction time — all underwater positions
liquidate simultaneously, worsening slippage for everyone. The rate limit is a
feature for borrowers during genuine market stress, not just a protection against
malicious updates.

**Comparison with RedStone TSSO (the initial inspiration):**

RedStone uses an emergency cold-key bypass because they serve crypto-native assets
that move 30–50% in minutes. Their bypass solves a real problem for that asset class.
Kaleidoscope's asset class (sovereign and IG debt) does not share that volatility
profile. Adopting a pattern designed for crypto price feeds would add attack surface
without solving any operational problem we actually face.

**The right action if a future asset requires it:**

If Kaleidoscope ever tokenizes high-yield bonds or distressed debt (where 10%+ daily
moves occur), deploy a separate `NAVFeedHY` contract with a wider `MAX_PRICE_DEVIATION_BPS`
constant set at deploy time. Do not add a runtime bypass to the existing contract.
Wider constants for higher-volatility instruments are a design choice; a bypass is
an attack surface.

### What we deliberately do NOT do

- NAV is not stored inside `GyldBondToken`. Do not add a `multiplier` or
  `navPerToken` field to the token contract.
- `navFeedOwner` must not be a plain hot wallet (EOA with private key in memory)
  in production. It must be KMS-backed (Phase 1) or MPC-backed (Phase 2+).
- Do not remove or increase the circuit breaker constants
  (`MAX_PRICE_DEVIATION_BPS`, `MIN_UPDATE_INTERVAL`, `MAX_STALENESS`). They
  are the on-chain guarantee that DeFi integrators and APs rely on.
- Do not add a `forceUpdateAnswer()` or any bypass of `MAX_PRICE_DEVIATION_BPS`.
  The cap is a hard rate limit — its value comes precisely from being unconditional.
  See "Why there is no emergency override" above.
- Do not disable `_requireFresh()` or allow reads to succeed on a stale price.
  Returning a stale price to Morpho Blue would cause it to accept undercollateralised
  loans — a direct financial loss to lenders.

### Consequences for developers

- Every bond series gets its own `KaleidoscopeNAVFeed` deployed atomically by
  `TokenFactory`. Do not share one feed across multiple bond series.
- The backend must push a NAV update after every market close. If it misses 36
  hours, the DeFi integration stops working until a fresh update is pushed.
- When migrating the updater to Fordefi (Phase 2): use `transferOwnership()` +
  `acceptOwnership()` — never call `renounceOwnership()`.
- `NAVFeedForwarder` (the stable oracle proxy) points at this feed. DeFi protocols
  should integrate against the forwarder address, not the feed address directly.
  See Section 5 for the forwarder design.

---

## 5. Delegated transfer (gasless / ERC-2771) — deferred to Phase 2

### What we do

`GyldBondToken` does **not** implement ERC-2771 or any gasless / meta-transaction
mechanism. All transfers are submitted on-chain by the caller, who pays ETH gas
directly. This is intentional for Phase 1.

### What ERC-2771 is

ERC-2771 lets a user sign an off-chain EIP-712 message authorising a token action.
A relayer submits that signed message on-chain and pays the gas. The token contract
reads the real user address from the calldata (appended by the trusted forwarder)
via `_msgSender()`, so the Chainalysis sanctions check still runs against the user —
not the relayer address.

### Why we are not implementing it now

Phase 1 users are institutional Authorised Participants. They hold ETH, submit their
own transactions, and have no expectation of gasless UX. Adding ERC-2771 for Phase 1
would add token complexity and require operating relay infrastructure (who submits
transactions, who pays gas, how are relay failures handled, how is the relay audit
log produced) for a problem that does not yet exist.

### Why this does not affect current users or DeFi integrations

- **Institutional APs:** no change. They interact with the token via standard ERC-20
  `transfer()` / `transferFrom()`. Not having ERC-2771 is invisible to them.

- **DeFi protocols (Morpho Blue, Aave, Uniswap, etc.):** no change. DeFi protocols
  use standard ERC-20 calls. ERC-2771 is additive — it does not modify `transfer`,
  `transferFrom`, `balanceOf`, `approve`, or any function a DeFi protocol calls.
  If ERC-2771 is added in a future upgrade, DeFi integrations continue working
  identically: the `_msgSender()` override only activates when `msg.sender` is the
  trusted forwarder; any call from Morpho or Aave falls through to `msg.sender` as
  normal.

### When to add it (Phase 2)

When retail access opens — users who hold only USDC or fiat and have no ETH for gas.
At that point:

1. Deploy `MinimalForwarder` (already in OZ v4.9, available in our lib).
2. Upgrade `GyldBondToken` via UUPS to inherit `ERC2771ContextUpgradeable` and
   override `_msgSender()` / `_msgData()`. Storage is ERC-7201 namespaced so
   the upgrade is safe.
3. Deploy or integrate a relay service (self-hosted for full audit trail, or
   Gelato / Biconomy for faster integration).

The token change is ~15 lines. The operational commitment (relay infrastructure,
gas sponsorship model, failure handling) is the real work and belongs in Phase 2
scoping.

### Consequences for developers

- Do not add `ERC2771ContextUpgradeable` to `GyldBondToken` before retail access is
  scoped and the relay infrastructure is designed.
- Do not add a `delegatedTransfer()` bespoke function — if gasless is ever needed,
  use the ERC-2771 standard, not a custom meta-transaction pattern.
- The trusted forwarder address must be set at deploy time and locked. A compromised
  or incorrect forwarder can spoof any `_msgSender()`, including admin addresses.

---

## 6. IssuanceManager redemption — pooled balance, off-chain ledger, no per-AP on-chain accounting

### What we do

When an AP redeems bond tokens, the flow is:

```
1. AP calls token.transfer(issuanceManager, amount)  — plain ERC-20 transfer
2. Backend detects the Transfer event on-chain (indexed by tx hash)
3. Backend records the deposit in LedgerRepo with external_ref = tx_hash
4. Backend calls issuanceManager.redeem(token, beneficiary, amount)
5. IssuanceManager checks: token registered? beneficiary whitelisted? amount > 0?
6. IssuanceManager calls token.burn(address(this), amount)  — burns from its own balance
7. Backend sends USDC to the AP off-chain
```

`IssuanceManager` is both the **token receiver** and the **burn executor** — it holds
`BURNER_ROLE` on every registered `GyldBondToken`. There is no separate "burner wallet".
The platform MPC wallet (ISSUER_ROLE) triggers the redemption by calling `redeem()`, but
it does not touch tokens directly.

### The pooled balance model

After multiple APs deposit in the same window the contract balance is undifferentiated:

```
Alice deposits  100 → IssuanceManager balance: 100
Bob deposits    200 → IssuanceManager balance: 300
Carol deposits   50 → IssuanceManager balance: 350
```

The contract holds 350 tokens with no internal record of who sent what. When
`redeem(token, alice, 100)` executes, it burns 100 from the pool — not specifically from
Alice's "slot". The `beneficiary` parameter serves two purposes:

1. **On-chain whitelist gate** — `beneficiary` must be a whitelisted AP; the contract
   rejects any address not on the whitelist regardless of what the backend passes.
2. **Audit trail** — `Redeemed(token, beneficiary, amount)` is emitted so on-chain
   event indexers can reconstruct the full redemption history per AP.

It does **not** verify that `beneficiary` deposited exactly `amount`. That guarantee
lives in the backend.

### Why there is no `pendingRedemption[beneficiary][token]` on-chain ledger

A per-AP on-chain deposit ledger (as sometimes suggested by automated audit tools)
would require APs to call a `deposit(token, amount)` function rather than doing a plain
ERC-20 `transfer`. This is a UX breaking change — institutional APs and custodians
interact via standard ERC-20 transfers. Requiring a separate deposit call adds latency,
gas, and integration friction for every redemption.

The per-AP accounting belongs in the backend's `LedgerRepo`, where it already exists.

### How the backend prevents double-burns (replay protection)

Every on-chain Transfer event has a unique tx hash. The backend records it as
`external_ref` in `LedgerRepo` before calling `redeem`:

```
First webhook:  LedgerRepo.has(tx=0xabc123)? → No  → write entry → call redeem()
Retry webhook:  LedgerRepo.has(tx=0xabc123)? → Yes → exit early, do not call redeem()
```

The tx hash uniqueness on Ethereum is the ultimate source of truth. A deposit event
cannot have two different tx hashes — Ethereum guarantees uniqueness. The
`external_ref` idempotency key makes the backend replay-safe without any on-chain
contract change.

### What the whitelist check actually guarantees

The on-chain check is:

```solidity
require(_getStorage().whitelisted[beneficiary], "IssuanceManager: beneficiary not whitelisted");
```

This guarantees: **only known, vetted APs can appear as beneficiaries in a burn event.**
Even if the ISSUER_ROLE key were compromised, an attacker cannot name an arbitrary
address — only whitelisted APs. USDC is sent off-chain after `Redeemed` is emitted,
so naming a non-whitelisted beneficiary produces no financial payout anyway; the
whitelist check closes that path entirely.

### What this does NOT protect against

A compromised ISSUER_ROLE key can call `redeem(token, anyWhitelistedAP, poolBalance)`
and drain the full IssuanceManager balance in one transaction, provided a whitelisted
AP is named as beneficiary. Mitigations:

- **ISSUER_ROLE is a Fordefi MPC wallet** — private key never exists on any single
  machine; threshold 2-of-3 signing required.
- **PAUSER_ROLE multisig can halt all secondary transfers immediately** on suspicion
  of key compromise, giving time for key rotation.
- **Balance monitoring** — backend alerts fire if IssuanceManager token balance drops
  faster than the rate of legitimate redemption orders in LedgerRepo.

The threat model accepts that ISSUER_ROLE is trusted. If that trust boundary is
unacceptable, the mitigation is moving to the `deposit()` + `pendingRedemption`
pattern — but that changes the AP-facing UX and is not warranted for the current
institutional AP model.

### Consequences for developers

- Do not add a `pendingRedemption` or `deposited` mapping to `IssuanceManager`. The
  accounting lives in `LedgerRepo`, not on-chain.
- Do not change the AP deposit mechanic from plain ERC-20 `transfer` to a
  `deposit()` function call without explicit product + compliance sign-off.
- Every `redeem()` call in the backend must check `LedgerRepo` for the tx hash before
  calling — this is the idempotency gate. Missing this check is a backend bug, not
  a contract gap.
- `beneficiary` must always correspond to the AP whose Transfer event triggered this
  redemption. The contract does not enforce this mapping — the backend must.
- Automated audit tools may flag the pool model as a missing on-chain enforcement.
  This is **intentional design**. Refer them to this document.

---

## Summary

| Question | Answer |
|---|---|
| **Token model** | |
| Does the token have shares / multiplier / rebasing? | **No. Never.** Plain OZ ERC-20. Balances change only via mint/burn. |
| Where does NAV / value accrual live? | `KaleidoscopeNAVFeed` oracle only — never inside the token. |
| Are `burnShares`, `transferShares`, `sharesOf` in the contract? | **No.** Deliberately absent — no share system, no dust residual problem. |
| Is there a `MULTIPLIER_UPDATER_ROLE`? | **No.** Removed with the multiplier system. |
| **Permit** | |
| Is EIP-2612 permit implemented? | **Yes.** Via `ERC20PermitUpgradeable`. |
| Can permit be used when paused? | **No.** `whenNotPaused` blocks new permit submissions during a pause. |
| **Compliance** | |
| Internal blacklist? | **No. Never.** Only Chainalysis oracle. |
| What happens if Chainalysis oracle is down? | Transfer reverts (fail-closed). |
| Does the admin/owner address bypass sanctions? | **No.** No `owner` exists; `_requireAccess` has zero role-based exemptions. |
| Do `mint()` / `burn()` check the oracle? | No — IssuanceManager pre-screens APs off-chain. |
| Do `mint()` / `burn()` respect `whenNotPaused`? | **Yes.** Pause halts all token movement including primary issuance. A compromised ISSUER_ROLE cannot mint/burn through a pause. |
| Is there an on-chain token recovery function? | No — sanctioned addresses are frozen by the oracle; platform escalates off-chain if legal action requires token movement. |
| **Upgradeability** | |
| Is GyldBondToken upgradeable? | **Yes. Intentionally.** UUPS via ERC1967Proxy. |
| Who can upgrade? | `DEFAULT_ADMIN_ROLE` — must be a TimelockController in prod. |
| Is there a delay on upgrades? | Yes — enforced by TimelockController (48h on all operations). |
| **Redemption architecture** | |
| Who receives AP tokens during redemption? | `IssuanceManager` contract — it is both the token receiver and the burn executor. No separate burner wallet. |
| Does `redeem()` track which AP deposited which amount on-chain? | **No.** The balance is pooled. Per-AP accounting lives in `LedgerRepo` (backend). |
| How is double-burn / replay prevented? | `LedgerRepo` idempotency — every deposit tx hash is stored as `external_ref`; backend exits early if it has already processed that hash. |
| Is the `beneficiary` parameter enforced on-chain? | Partially — must be a whitelisted AP (on-chain). The amount is not linked to that AP's specific deposit (backend responsibility). |
| Should a `pendingRedemption` mapping be added to IssuanceManager? | **No.** Would require APs to call `deposit()` instead of plain ERC-20 transfer — a UX breaking change not warranted for institutional APs. |
