# Gyld Contracts — Architecture and Design

**Single authoritative reference** for the on-chain smart-contract system: what
each contract is for, how they interact, who holds which key, what fails closed
and what does not.

Verified against the Solidity on `main` @ `0678230` (524 tests,
20 suites, all passing). Every claim here was checked against the source at the
time of writing.

| | |
|---|---|
| Language | Solidity `=0.8.28` (exact pin; `foundry.toml` also pins `solc = "0.8.28"`) |
| Build | Foundry, `via_ir = true`, `optimizer_runs = 200` |
| Libraries | OpenZeppelin `contracts` + `contracts-upgradeable` **v5.3.0** |
| Chains exercised | Ethereum Sepolia (11155111), local Anvil (31337) — demonstrations only. **Nothing is deployed on mainnet**; see [§14](#14-deployed-addresses) |
| Licence | 8 BUSL-1.1 files (the 7 core contracts + `IERC1643`) → GPL-2.0-or-later on 2028-07-09; see [§4.2](#42-licensing) |

---

## Table of contents

1. [What this system is](#1-what-this-system-is)
2. [Scope boundary — contracts vs. Kaleidoscope backend](#2-scope-boundary--contracts-vs-kaleidoscope-backend)
3. [System overview](#3-system-overview)
4. [Contract inventory](#4-contract-inventory)
5. [Contract reference](#5-contract-reference)
6. [Role and permission matrix](#6-role-and-permission-matrix)
7. [Custody model and loss ceilings](#7-custody-model-and-loss-ceilings)
8. [Value accrual — NAV, not balances](#8-value-accrual--nav-not-balances)
9. [Settlement flows](#9-settlement-flows)
10. [Compliance model](#10-compliance-model)
11. [Oracle design](#11-oracle-design)
12. [Storage, upgradeability, ERC-7201](#12-storage-upgradeability-erc-7201)
13. [Deployment model](#13-deployment-model)
14. [Deployed addresses](#14-deployed-addresses)
15. [DeFi integrations](#15-defi-integrations)
16. [Verification surface](#16-verification-surface)
17. [Decision record](#17-decision-record)
18. [Known gaps and open decisions](#18-known-gaps-and-open-decisions)

---

## 1. What this system is

Gyld issues **tokenised fixed-income products** — treasuries, corporate bonds,
bond ETFs — as ERC-20 tokens on EVM chains. One token contract per bond series.
Each token is backed **1:1 by real securities held in off-chain custody** at an
external broker (Alpaca on day one).

The contracts do four things and deliberately nothing else:

1. **Represent ownership.** One `GyldBondToken` per series. `balanceOf` is a
   count of bond units, nothing more. Balances change only on mint and burn.
2. **Gate primary issuance.** `IssuanceManager` is the single mint/burn
   authority across all series, and will only mint to — or record a redemption
   beneficiary that is — a whitelisted Authorised Participant (AP).
3. **Publish value.** `KaleidoscopeNAVFeed` publishes NAV-per-token in the
   Chainlink `AggregatorV3Interface` shape; `NAVFeedForwarder` gives DeFi
   protocols a permanent address to point at. Value accrual lives here, never
   in balances.
4. **Enforce sanctions on secondary transfers.** Every `transfer` /
   `transferFrom` screens sender, receiver and spender against an on-chain
   sanctions oracle, fail-closed.

`GyldAtomicSwap` sits alongside as the **instant-settlement** path: one
transaction, USDC in / bond out (or the reverse), priced by a platform-signed
EIP-712 quote and bounded by the NAV feed.

`TokenFactory` deploys the token/feed/forwarder triple for a new series and
wires every role in one transaction.

### What the contracts deliberately do not do

- **No on-chain cash leg for primary issuance.** `IssuanceManager.redeem` burns
  tokens and emits an event; USDC settlement happens off-chain. There is no
  on-chain guarantee of payout. See [§9.2](#92-deferred-path--issuancemanager).
- **No forced transfer, no clawback, no recovery.** A sanctioned address is
  frozen in place by the oracle. Nothing can move its tokens.
- **No internal blocklist.** Sanctions decisions come from a mirrored
  OFAC/SDN/UN/EU dataset, not platform discretion.
- **No rebasing, no share accounting, no display multiplier.** Plain ERC-20.
- **No historical NAV rounds.** `getRoundData` accepts only the current round.
- **No gasless / ERC-2771 relaying.** Deferred; see [§17](#17-decision-record).

---

## 2. Scope boundary — contracts vs. Kaleidoscope backend

This repository is the on-chain half of a larger platform. The other half is
[Kaleidoscope](https://github.com/Gyld-Finance/kaleidoscope), a Rust service
that owns KYC, broker orders, custody, settlement tracking, the double-entry
ledger, and the NAV computation. **Its internals belong in that repository and
are not documented here.**

What a contract reader must know about the off-chain side, and no more:

| Fact | Why a contract reader needs it |
|---|---|
| **Client funds arrive as USDC** to a single platform-controlled deposit address per chain, are credited to an off-chain cash balance, then swept to the broker and swapped USD→bond. | Explains why `subscribe` is called *after* settlement, and why mint amounts are exact integers with no on-chain rounding. |
| **Tokens are minted only after the broker reports `Settled`** (T+1/T+2). | This is a backend invariant, **not enforced on-chain**. `IssuanceManager` mints whenever `SUBSCRIBER_ROLE` says so. |
| **NAV is computed off-chain** as `(bonds_held × bond_price_usd) / tokens_outstanding`, scaled to 8 decimals, and **pushed** by a KMS-held key. | The feed is a push oracle with no pull path. If the keeper stops, the feed goes silent and does **not** revert. See [§11](#11-oracle-design). |
| **The AP whitelist is populated manually after KYC approval.** Backend approval does *not* automatically write to the chain. | `addToWhitelist` / `addToWhitelistBatch` are explicit ops actions by `WHITELIST_ADMIN_ROLE`. A KYC-approved user who was never whitelisted cannot be minted to. Removal does not touch existing positions — it only blocks future `subscribe`/`redeem` naming. |
| **Redemption is token-first.** The AP transfers tokens to the `IssuanceManager` address; that ERC-20 `Transfer` event *is* the commitment signal the backend watches. | Explains why `IssuanceManager` holds a pooled, undifferentiated token balance and burns from `address(this)`. |
| **The quote service holds `QUOTE_SIGNER_ROLE`** and signs EIP-712 `SwapMessage`s off-chain, pre-screening takers to save gas. | The chain never computes a price. The signed quote *is* the price; the NAV feed only bounds it. |
| **Sanctions data is mirrored by a keeper bot** polling the OFAC/SDN feed roughly every 4 hours and writing deltas. | The mirror's freshness is an ops property, not a contract property. |
| **Double-burn protection is off-chain.** The backend keys every redemption on the deposit tx hash (`external_ref`) and exits early on a repeat. | The contract has no replay guard on `redeem`. Missing this check is a backend bug that the chain cannot catch. |

Everything else about Kaleidoscope — service decomposition, workflow state
machines, driver tick intervals, Postgres schema, the `ICustodian` /
`IFiatBroker` / `ISecuritiesBroker` port traits, Alpaca adapters, tracing setup
— is out of scope here by design. An earlier `docs/architecture.md` in this repo
documented that backend at length; roughly 90 % of its 1,412 lines described
Rust crates that do not exist in this tree, and it has been removed.

---

## 3. System overview

```
        ┌──────────────────────── DeFi consumers ────────────────────────┐
        │                                                                │
        │   Morpho Blue          Euler V2            Aave V3             │
        │   (via Morpho-         (direct             (direct             │
        │   ChainlinkOracleV2)   AggregatorV3)       latestAnswer)       │
        │        │                    │                   │              │
        │        └────────────────────┴───────────────────┘              │
        │                             │                                  │
        │                     NAVFeedForwarder                           │
        │                     permanent address, Ownable2Step            │
        └─────────────────────────────┬──────────────────────────────────┘
                                      │ setUpstreamOracle()  ← timelock
                                      ▼
                            KaleidoscopeNAVFeed
                            push oracle, Ownable2Step, NOT upgradeable
                                      ▲
                                      │ updateAnswer(int256)   ← KMS signer
                                      │   (the only write path — no bypass)
                              Kaleidoscope backend

        ┌──────────────────────── Token layer ───────────────────────────┐
        │                                                                │
        │   TokenFactory ──deployToken()──┬─▶ GyldBondToken proxy (UUPS) │
        │   Ownable2Step,                 ├─▶ KaleidoscopeNAVFeed        │
        │   owner = Timelock              └─▶ NAVFeedForwarder           │
        │        │                                    ▲                  │
        │        │ registerToken()                    │ _requireAccess   │
        │        ▼                                    │                  │
        │   IssuanceManager (UUPS) ──mint/burn────────┤                  │
        │        ▲                                    │                  │
        │        │ subscribe / redeem        SanctionsOracleMirror       │
        │        │                           AccessControl, immutable    │
        │   SUBSCRIBER / REDEEMER keys                ▲                  │
        │                                             │                  │
        │   GyldAtomicSwap (UUPS) ── holds own ───────┘                  │
        │        ▲                  inventory                            │
        │        │ executeSwap(SwapMessage, sig, permit, requestedIn)    │
        │   taker (allowlisted AP)                                       │
        └────────────────────────────────────────────────────────────────┘
                                      │
                       TimelockController — 48 h on production
                       DEFAULT_ADMIN_ROLE / owner of everything above
```

Two independent settlement paths reach the same token:

- **Deferred** — `IssuanceManager.subscribe` / `redeem`. No on-chain cash leg.
- **Atomic** — `GyldAtomicSwap.executeSwap`. Both legs move in one transaction,
  out of the swap's own inventory. Inventory is replenished through the deferred
  path: the swap is itself a whitelisted AP, so
  `IssuanceManager.subscribe(token, swap, n)` mints straight into it.

---

## 4. Contract inventory

### 4.1 The core contracts

| Contract | File | Upgrade path | Admin model | Purpose |
|---|---|---|---|---|
| `GyldBondToken` | `contracts/GyldBondToken.sol` | **UUPS** (ERC1967Proxy) | `AccessControl` | ERC-20 per bond series. Fixed balances. Sanctions screen on every secondary transfer. Pausable. EIP-2612 permit. ERC-1643 document register (prospectus / supplements), `DOCUMENT_ROLE`-gated. |
| `IssuanceManager` | `contracts/IssuanceManager.sol` | **UUPS** (ERC1967Proxy) | `AccessControl` | Single mint/burn gate for every series. AP whitelist. Token registry. |
| `TokenFactory` | `contracts/TokenFactory.sol` | None (immutable) | `Ownable2Step` | Deploys the `(token proxy, NAV feed, forwarder)` triple per series and wires roles atomically. |
| `KaleidoscopeNAVFeed` | `contracts/KaleidoscopeNAVFeed.sol` | None (immutable) | `Ownable2Step` | Push NAV oracle in `AggregatorV3Interface` shape. Deviation cap and interval gate, both unconditional — `updateAnswer` is the only write path. |
| `NAVFeedForwarder` | `contracts/NAVFeedForwarder.sol` | None (immutable) | `Ownable2Step` | Permanent DeFi-facing oracle address. Pure delegation to a swappable upstream. |
| `SanctionsOracleMirror` | `contracts/SanctionsOracleMirror.sol` | None (immutable) | `AccessControl` | Platform sanctions oracle on **every** production EVM chain. Local list plus an optional gas-capped, fail-closed forward to a vendor oracle. |
| `GyldAtomicSwap` | `contracts/GyldAtomicSwap.sol` | **UUPS** (ERC1967Proxy) | `AccessControl` | Self-custodial atomic USDC⇄bond settlement against signed EIP-712 quotes. Holds its own inventory. |
| `IERC1643` | `contracts/interfaces/IERC1643.sol` | n/a — interface, no bytecode | n/a | The document-management interface `GyldBondToken` implements. Its `Document` struct is the value type of the token's `documents` mapping, so member order is the physical storage layout on every deployed proxy. |

Seven contracts plus that one interface file — the whole of `contracts/` outside
`test/` and `script/`. Note the deliberate split. The three contracts that **hold or
move value on the hot path** (`GyldBondToken`, `IssuanceManager`, `GyldAtomicSwap`) are
upgradeable, because a bond may be live for 6–24 months and a stable address is
a hard requirement for exchanges, custodians and legal documentation — migrating
holders to a new address would need re-listing, legal amendments and AP
re-onboarding. The four that are **pure infrastructure or price plumbing** are
immutable, so their behaviour cannot be changed under live integrators at all.

The consequence of immutability is real and load-bearing: `stalenessSeconds()`
was added to `KaleidoscopeNAVFeed` under GYL-1135 and **cannot be retrofitted**
to already-deployed feeds. Alerting on existing
feeds must derive age from `latestRoundData().updatedAt` or from the
`AnswerUpdated` event, which exists on every version.

### 4.2 Licensing

The seven core contracts and the `IERC1643` interface — **eight** files, by SPDX
scan — are **BUSL-1.1** — Licensor Gyld Finance, Licensed Work
`gyld-contracts` (c) 2026, Additional Use Grant **None**, Change Date
**2028-07-09**, Change Licence **GPL-2.0-or-later**. Source is available for
review, testing and non-production use; production use requires a commercial
licence from Gyld Finance until the Change Date.

Everything under `contracts/test/` and `contracts/script/` is **not** uniformly
MIT, contrary to what the README and two earlier docs claimed:

| Licence | Count | Which files |
|---|---|---|
| `UNLICENSED` | 22 | Every `*.t.sol` suite, `ScriptRevertAsserts.sol`, `DeployDevNet`, `DeployTimelock`, `DeployNAVFeed`, `DeployAtomicSettlement`, `DeployAtomicSettlementE2E`, `AtomicSettlementFlow`, `script/lib/DeployGuards.sol` |
| `MIT` | 7 | The five test doubles (`MockSanctionsList`, `MockUSDC`, `MockUSDCPermit`, `MockNavForwarder`, `MockReentrantToken`) plus `DeployMockSanctionsList.s.sol` and `DeployMockUSDC.s.sol` |

### 4.3 Test doubles (never deployed on production)

| Contract | Purpose | Production guard |
|---|---|---|
| `MockSanctionsList` | Writable stand-in for the sanctions oracle so the dev gateway's `mock_sanction_address` endpoint can flip an address. Writes are gated on an `owner` set at construction — the deploying key, and no other address. | `DeployMockSanctionsList.s.sol` calls `DeployGuards.requireProdSafe`, so it only runs on 31337 / 11155111. Separately, `DeployDevNet` compares the configured `SANCTIONS_LIST`'s **`EXTCODEHASH`** against the mock's runtime bytecode and refuses a match on production (`requireProdNotMock`). |
| `MockUSDC` | 6-decimal ERC-20 with **no** `permit`. | `DeployMockUSDC.s.sol` calls `requireProdSafe`. |
| `MockUSDCPermit` | 6-decimal ERC-20 **with** EIP-2612, for the permit path. Real USDC's permit is non-standard (domain version `"2"`), which is why the swap's permit leg is optional and wrapped in `try/catch`. | Test-only; no script deploys it. |
| `MockNavForwarder` | Settable 8-decimal NAV forwarder. The real feed's 1 h interval and ±10 % band are too rigid to drive the band / `InvalidNav` / `StaleNav` tests. | Test-only. |
| `MockReentrantToken` | Token whose transfer hook re-enters the swap, for the reentrancy-exclusion tests (`I-17`). | Test-only. |

---

## 5. Contract reference

### 5.1 `GyldBondToken`

Standard OpenZeppelin ERC-20 per bond series. **One token = one unit of bond
ownership.** 18 decimals.

```
balanceOf(account) = exactly what was minted to it, minus what was burned
totalSupply()      = sum of all balances, exact, no rounding
```

Inheritance: `Initializable`, `ERC20Upgradeable`, `ERC20PermitUpgradeable`,
`AccessControlUpgradeable`, `PausableUpgradeable`, `UUPSUpgradeable`, `IERC1643`.

**Immutable metadata**, set at `initialize` and never writable afterwards:

| Field | Getter | Example |
|---|---|---|
| ISIN | `isin() → string` | `"US912797KR72"` |
| Maturity | `maturityTimestamp() → uint256` | `1788739200` (2028-09-06); `0` = open-ended |
| Sanctions oracle | `sanctionsList() → ISanctionsList` | the `SanctionsOracleMirror` address |

`initialize(name, symbol, isin, maturityTimestamp, defaultAdmin, pauser, sanctionsList)`
rejects a zero `defaultAdmin`, `pauser` or `sanctionsList`, and
**probe-before-store**: it `staticcall`s `isSanctioned(address(0))` on the
candidate oracle and reverts `NotValidSanctionsList` unless the call succeeds
and returns exactly 32 bytes. This rejects EOAs, wrong contracts and partial
stubs.

#### Where the sanctions check actually lives

This is the detail most often mis-stated. There are **two** call sites, not the
three inline calls that an earlier ADR's code snippet showed:

```solidity
// _update is the single funnel for ALL balance changes in OZ v5.
function _update(address from, address to, uint256 value) internal override {
    if (from != address(0) && to != address(0)) {   // skips mint (from==0) and burn (to==0)
        _requireAccess(from);
        _requireAccess(to);
    }
    super._update(from, to, value);
}

// transferFrom adds the SPENDER, which _update cannot see.
function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
    _requireAccess(_msgSender());
    _spendAllowance(from, _msgSender(), amount);
    _transfer(from, to, amount);
    return true;
}
```

`_requireAccess` reverts with **custom errors** — `AccountSanctioned(address)`
when the oracle says the account is sanctioned, `SanctionsListNotSet()` when the
oracle address is unset — not a string `require`, which is what two older docs
claimed:

```solidity
function _requireAccess(address account) internal view {
    ISanctionsList sl = _getStorage().sanctionsList;
    if (address(sl) == address(0)) revert SanctionsListNotSet();
    if (sl.isSanctioned(account)) revert AccountSanctioned(account);
}
```

**Fail-closed on every arm.** `sl.isSanctioned(account)` is a plain external
call, so if the oracle reverts or is not a contract, the whole transfer reverts.
The unset-list case is handled by an explicit branch rather than left implicit.

That branch is not expected to fire: `initialize` and `setSanctionsList` both
reject zero, so `sanctionsList` is non-zero on any live token. It is checked
anyway because the earlier form guarded it with a short-circuit —
`if (address(sl) != address(0) && sl.isSanctioned(account))` — which *skipped
screening entirely* when the slot was zero. That made a mandatory compliance
control depend on an invariant maintained by hand in two separate functions; a
third writer forgetting its zero-check would have silently disabled screening
instead of failing. Unreachable-but-loud is the correct posture here, and the
cost is negative — the inverted branch is marginally cheaper (audit §4.1).

**`approve` / `permit` do not screen the spender.** Granting an allowance to a
sanctioned address succeeds — no tokens move at approval time. Enforcement fires
on the subsequent `transferFrom`, where the sanctioned spender is caught. This is
intentional and documented inline in the source.

#### Pause semantics

`whenNotPaused` is applied to `transfer`, `transferFrom`, `approve`, `permit`,
`mint` **and** `burn`. A pause therefore halts *all* token movement, including
primary issuance — a compromised `SUBSCRIBER_ROLE` or `REDEEMER_ROLE` key cannot
mint or burn through a pause. Pause is **symmetric** on this contract: the same
`PAUSER_ROLE` both pauses and unpauses. (Contrast `GyldAtomicSwap`, where it is
deliberately asymmetric.)

#### Role management

| Role | Capability |
|---|---|
| `DEFAULT_ADMIN_ROLE` | Grant/revoke every role; `setSanctionsList`; authorise UUPS upgrades (`_authorizeUpgrade`) |
| `MINTER_ROLE` | `mint(to, amount)` — rejects zero address, zero amount |
| `BURNER_ROLE` | `burn(from, amount)` — rejects zero address, zero amount |
| `PAUSER_ROLE` | `pause()` / `unpause()` |
| `DOCUMENT_ROLE` | `setDocument(name, uri, docHash)` / `removeDocument(name)` — the ERC-1643 document register (GLD-264) |

`renounceRole` is overridden to revert `CannotRenounceAdminRole` for
`DEFAULT_ADMIN_ROLE` — losing it would permanently brick UUPS upgrades and all
role management for the lifetime of the bond. Intentional removal must go through
`revokeRole`, an explicit two-party action.

`setSanctionsList(newSanctionsList)` is `DEFAULT_ADMIN_ROLE`-gated, applies the
same 32-byte staticcall probe, and **rejects `address(0)`**. Disabling the oracle
is not permitted: a token with no oracle is a worse compliance outcome than a
frozen token. The emergency path when an oracle is compromised is to deploy a
replacement and point at it — replace, never remove. If the slot ever reached
zero regardless, `_requireAccess` reverts `SanctionsListNotSet` rather than
waving transfers through, so this rejection is defence in depth rather than the
sole guarantee.

There is **no `ReentrancyGuard`** on this contract, and that is deliberate. The
only external call on the transfer path is the read-only sanctions oracle inside
`_requireAccess`, which runs *before* `_update` writes any state — CEI is
correct. `mint`/`burn` are role-gated with no external calls. OZ v5 removed
`_afterTokenTransfer`, so there is no post-state callback anywhere in the
lifecycle. Adding `nonReentrant` to `transfer` would also break composability
with DeFi protocols that call `transfer` inside their own `nonReentrant` flows.

**Storage:** ERC-7201 namespace `gyld.GyldBondToken`, base slot
`0x0fe35ba304a016e79d78a184eb899c1e21310138e0bfe9a54648a2dfe0da0d00`
(independently recomputed — see [§12](#12-storage-upgradeability-erc-7201)).

---

### 5.2 `IssuanceManager`

Single gate for primary issuance and redemption of **every** Gyld bond series. A
singleton, not one per token. Holds `MINTER_ROLE` and `BURNER_ROLE` on each
registered `GyldBondToken`.

Inheritance: `Initializable`, `AccessControlUpgradeable`,
`ReentrancyGuardUpgradeable`, `UUPSUpgradeable`.

`initialize(defaultAdmin, subscriber, redeemer)` grants `DEFAULT_ADMIN_ROLE`,
`SUBSCRIBER_ROLE` and `REDEEMER_ROLE`. Note what it does **not** grant:
`WHITELIST_ADMIN_ROLE` and `REGISTRAR_ROLE` are unset after initialisation and
must be assigned explicitly afterwards by whoever holds `DEFAULT_ADMIN_ROLE` at
that moment — in practice the deployer EOA, before the timelock handover.

#### `subscribe(token, recipient, amount)` — mint

`nonReentrant`, `onlyRole(SUBSCRIBER_ROLE)`. Three checks, then the mint:

```
registeredTokens[token]     else revert UnregisteredToken(token)
whitelisted[recipient]      else revert NotWhitelisted(recipient)
amount != 0                 else revert ZeroAmount()
→ IGyldBondToken(token).mint(recipient, amount)
→ emit Subscribed(token, recipient, amount)
```

The sanctions oracle is **not** consulted — mint is primary issuance, not a
secondary transfer, and the backend pre-screens the AP off-chain. `whenNotPaused`
on the token still applies, so a paused token blocks `subscribe`.

#### `redeem(token, beneficiary, amount)` — burn

`nonReentrant`, `onlyRole(REDEEMER_ROLE)`. Same three checks, then
`token.burn(address(this), amount)` and `emit Redeemed(...)`.

**The balance is pooled and undifferentiated.** After Alice sends 100, Bob 200
and Carol 50, the contract holds 350 with no on-chain record of who sent what.
`redeem(token, alice, 100)` burns 100 from the pool, not from "Alice's slot".
The `beneficiary` parameter serves exactly two purposes:

1. **On-chain whitelist gate** — must be a whitelisted AP, regardless of what the
   backend passes.
2. **Audit trail** — `Redeemed(token, beneficiary, amount)` lets an event indexer
   reconstruct per-AP redemption history.

It does **not** verify that `beneficiary` deposited exactly `amount`. That
guarantee lives in the backend's ledger.

There is deliberately no `pendingRedemption[beneficiary][token]` mapping. Adding
one would require APs to call a `deposit(token, amount)` function instead of a
plain ERC-20 `transfer` — a UX-breaking change for institutional APs and
custodians that interact through standard ERC-20 only. Automated audit tools
routinely flag the pool model as missing on-chain enforcement; it is intentional.

Tokens sitting in the contract during the custody window are **inert**: there is
no `withdraw()`, `transfer()` or `rescue()` function, so they cannot be extracted
at all — only burned via `redeem`.

#### Whitelist and registry

| Function | Role | Behaviour |
|---|---|---|
| `addToWhitelist(account)` | `WHITELIST_ADMIN_ROLE` | Idempotent; rejects `address(0)`. Re-emits the event on a repeat. |
| `removeFromWhitelist(account)` | `WHITELIST_ADMIN_ROLE` | Idempotent; rejects `address(0)`. |
| `addToWhitelistBatch(accounts[])` | `WHITELIST_ADMIN_ROLE` | Preferred for activating a KYC cohort. Reverts **atomically** if any entry is `address(0)`. |
| `registerToken(token)` | `REGISTRAR_ROLE` | Raw `staticcall` to `MINTER_ROLE()`; reverts `NotValidTokenContract` unless it succeeds *and* returns 32 bytes. Raw staticcall rather than `try/catch` because Solidity's `try/catch` does not catch the ABI-decode failure an EOA produces by returning empty data. |
| `deregisterToken(token)` | `REGISTRAR_ROLE` | Blocks further `subscribe`/`redeem` for a matured series. Does not touch balances. |

`renounceRole` blocks `DEFAULT_ADMIN_ROLE` renouncement, same idiom as the token.

**Storage:** ERC-7201 namespace `gyld.IssuanceManager`, base slot
`0xc8552dd465c7174389604c2ad1f48bf21d46f65ee8d42bbd0456923afc111000`.

---

### 5.3 `TokenFactory`

Deployment adapter. `Ownable2Step` + `ReentrancyGuard`, **not upgradeable**.
`deployToken` is `onlyOwner`, so on production a new bond series requires a
timelocked governance action.

Three immutable / near-immutable pieces of state:

```solidity
address public immutable bondTokenLogic;   // the GyldBondToken implementation
address public immutable sanctionsList;    // baked into every token this factory deploys
mapping(address => address) public navFeedOf;    // token → its KaleidoscopeNAVFeed
mapping(address => address) public forwarderOf;  // token → its NAVFeedForwarder
mapping(bytes32 => bool)    private _deployedIsins;
```

> **`bondTokenLogic` is `immutable`, so a `GyldBondToken` upgrade reaches existing
> proxies only.** The address is fixed at construction and baked into the CREATE2
> init code of every proxy the factory deploys (`TokenFactory.sol:37`, `:260`).
> Upgrading the implementation lifts the series that already exist; the factory keeps
> minting **new** series against the **old** logic until a new factory is deployed and
> the `REGISTRAR_ROLE` / ownership wiring is repointed at it. Any implementation
> upgrade is therefore a two-part rollout. This is live today: `GyldBondToken` gained
> IERC-1643 documents in `c1f240f`, so upgrading live proxies without shipping a new
> factory would leave newly-deployed series with no document register.

The constructor takes `owner_` **explicitly** rather than using
`Ownable(msg.sender)`. This matters: the bootstrap contracts are deployed through
the canonical CREATE2 proxy at `0x4e59b44847b379578588920cA78FbF26c0B4956C`, so
`msg.sender` would be *that proxy*, permanently bricking `transferOwnership` and
with it the handover to the TimelockController. The constructor also
probe-before-stores the sanctions oracle with the same 32-byte
`isSanctioned(address(0))` staticcall.

#### `deployToken` — exact order of operations

```
deployToken(name, symbol, isin, maturityTimestamp, operator, issuanceManager, navFeedOwner)
  ├─ reject operator == 0 || operator == address(this)          → ZeroAddress
  ├─ reject issuanceManager == 0, navFeedOwner == 0             → ZeroAddress
  ├─ reject bytes(isin).length == 0                             → EmptyIsin
  ├─ reject _deployedIsins[_bondSalt(isin)]                     → IsinAlreadyDeployed(isin)
  ├─ PREFLIGHT: factory must hold REGISTRAR_ROLE on issuanceManager
  │                                                             → MissingRegistrarRole
  ├─ CREATE2 the ERC1967Proxy (assembly), salt = _tokenSalt(_bondSalt(isin))
  │     initialize(name, symbol, isin, maturity, address(this), address(this), sanctionsList)
  │     └─ factory is BOTH defaultAdmin and pauser at this instant
  │     reject address(0) result                                → ProxyDeployFailed
  ├─ _wireRoles(token, issuanceManager, operator):
  │     grant  MINTER_ROLE         → issuanceManager
  │     grant  BURNER_ROLE         → issuanceManager
  │     grant  PAUSER_ROLE         → operator
  │     grant  DOCUMENT_ROLE       → operator         (rides with PAUSER: both operational)
  │     grant  DEFAULT_ADMIN_ROLE  → owner()          (the Timelock in production)
  │     revoke PAUSER_ROLE         from address(this)
  │     revoke DEFAULT_ADMIN_ROLE  from address(this)
  ├─ new KaleidoscopeNAVFeed(navFeedOwner, "<symbol> / USD NAV")
  ├─ new NAVFeedForwarder(navFeed, owner())    ← forwarder owner is the FACTORY OWNER,
  │                                              not navFeedOwner
  ├─ record _deployedIsins / navFeedOf / forwarderOf
  ├─ emit TokenDeployed(token, navFeed, forwarder, issuanceManager)   ← four params
  └─ IssuanceManager(issuanceManager).registerToken(token)
```

Two properties worth stating explicitly:

- **The factory self-revokes only what it holds *on the token*.** `_wireRoles`
  drops `PAUSER_ROLE` and `DEFAULT_ADMIN_ROLE` from the factory on each token it
  creates. It does **not** touch `REGISTRAR_ROLE` on the `IssuanceManager` —
  there is no `revokeRole` for it anywhere in this contract or in
  `DeployDevNet.s.sol`. The factory keeps `REGISTRAR_ROLE` **permanently**. See
  [§6.3](#63-what-a-single-key-compromise-buys) for what that means.
- **The forwarder's owner is `factory.owner()`**, i.e. the TimelockController —
  not the NAV feed's KMS signer. The KMS signer writes prices to the *feed* and
  has no control over which upstream the *forwarder* points at. Repointing the
  price feed that every integrated lending market reads is deliberately a
  governance action.

#### Address determinism

```solidity
bondSalt  = keccak256(abi.encodePacked(isin, block.chainid))
tokenSalt = keccak256(abi.encodePacked("token", bondSalt))
```

`predictTokenAddress(name, symbol, isin, maturityTimestamp)` returns the proxy
address before deployment. It shares the `_tokenInitCode` and `_tokenSalt`
helpers with `deployToken`, so prediction and deployment cannot drift. The
`operator` argument does not affect the address and is not a parameter.

Including `block.chainid` in the salt stops the same ISIN producing the same
address on two chains.

**Why the ISIN registry exists (GYL-300).** The salt is ISIN-only, but the full
CREATE2 address also depends on the initcode, which includes `name`, `symbol` and
`maturityTimestamp`. The same ISIN deployed with a different name would therefore
land at a *different* address — two on-chain tokens for one real-world bond, with
no CREATE2 collision to stop it. The old guard checked
`navFeedOf[predictedAddress] == address(0)`, which only caught exact-duplicate
calls. `_deployedIsins` keyed on `_bondSalt(isin)` catches every same-ISIN
deployment regardless of the other parameters, and does so *before* any CREATE2
is attempted — so the failure surfaces as `IsinAlreadyDeployed` rather than an
opaque EVM revert after a 48 h timelock delay.

The `MissingRegistrarRole` preflight exists for the same reason: without it, the
call would spend gas on three deployments and only fail at the final
`registerToken`.

---

### 5.4 `KaleidoscopeNAVFeed`

Push oracle, one per bond series, `Ownable2Step`, **not upgradeable, no proxy**.
Implements `AggregatorV3Interface` plus the older `latestAnswer()` that Aave V3
calls. `decimals() == 8`, `version() == 3`.

```
NAV per token = (bonds_held × bond_price_usd) / tokens_outstanding

e.g. 1,000 TLT at $95.42 backing 10,000 tokens
     → $9.542/token → answer = 954_200_000   (8 decimals)
```

#### Constants

| Constant | Value | What it actually does |
|---|---|---|
| `MAX_STALENESS` | **96 hours** | Threshold for the `isFresh()` **monitoring view only**. No read function reverts on staleness. Sized so `isFresh() == false` means "a push was missed", not "the market is closed": a normal weekend is ~65 h, a 3-day holiday weekend ~87 h, and 96 h clears both. |
| `MIN_UPDATE_INTERVAL` | 1 hour | `updateAnswer` reverts `UpdateTooSoon` if called sooner. A security floor, not the operational cadence (which is once per market day). |
| `MAX_PRICE_DEVIATION_BPS` | 1000 (**10 %**) | `updateAnswer` reverts `PriceDeviationTooLarge` if the new answer moves more than 10 % from the last. Applies only *after* the first push — the initial anchor has nothing to compare against and is accepted as-is. |
| `BPS_DENOMINATOR` | 10_000 | Basis-point denominator. |

The deviation check is written to avoid division:

```solidity
int256 diff = answer > last ? answer - last : last - answer;
if (diff * int256(BPS_DENOMINATOR) > last * int256(MAX_PRICE_DEVIATION_BPS))
    revert PriceDeviationTooLarge(answer, last);
```

#### Write paths

| Function | Caller | Bypasses | Event |
|---|---|---|---|
| `updateAnswer(int256)` | `owner()` — the KMS signer | nothing | `AnswerUpdated` |

**There is exactly one write path, and it has no privileged bypass.** Every guard
— `answer > 0`, `MIN_UPDATE_INTERVAL`, `MAX_PRICE_DEVIATION_BPS` — is
unconditional. A correction larger than 10 % is reached by *chaining* calls: the
deviation band is measured against the **last stored** answer, and `last` moves
with every push, so successive calls compound. See
[§11.5](#115-correcting-a-wrong-nav--the-incident-procedure) for the procedure and
[D-19](#171-adopted-and-current) for why the bypass that used to live here was
removed.

`renounceOwnership()` is disabled outright (GLD-165) and is the one carve-out that
remains. The feed is not upgradeable and its reads never revert on staleness, so an
owner-less feed would serve its last answer forever with no recovery path: no
`updateAnswer`, no proxy to upgrade, no loud failure. Note this is **not
retrofittable** — feeds deployed before this guard do not have it and still depend
on the runbook rule.

#### Read paths — and why none of them revert on staleness

| Function | Reverts when |
|---|---|
| `latestRoundData()` | **only** `NoPriceSet`, before the first push |
| `latestAnswer()` | **only** `NoPriceSet` |
| `getRoundData(rid)` | `HistoricalRoundsNotStored` for any `rid != _roundId`; `NoPriceSet` before the first push |
| `isFresh()` | never — returns `false` if stale **or never set** |
| `stalenessSeconds()` | never — returns `type(uint256).max` if never set |

There is **no `PriceStale` error and no `_requireFresh()` function**, and there
never has been. A declared-but-never-thrown `PriceStale` was deleted under
GYL-1135 so the source does not imply a revert path that is not there.

Historical rounds are not stored. DeFi protocols use `latestRoundData()`
exclusively; `getRoundData` exists solely to satisfy the interface. A future
time-weighted-NAV requirement needs a new feed that stores a round history.

The full reasoning for non-reverting reads is in [§11](#11-oracle-design).

`stalenessSeconds()` returns a magnitude rather than a bool so an alerting rule
can choose its own threshold (page at ~26 h, escalate at 96 h) instead of being
pinned to `MAX_STALENESS`, and so a dashboard can chart the gap. The sentinel for
"never set" is `type(uint256).max` rather than `0` so a never-initialised feed
can never be mistaken for a just-updated one.

---

### 5.5 `NAVFeedForwarder`

A permanent, stable oracle address that forwards every read to a swappable
upstream. `Ownable2Step`, immutable, no local price state, no caching, no
transformation.

**The problem it solves:** Morpho Blue bakes the oracle address into immutable
market parameters at `createMarket()` time. Pointing Morpho straight at
`KaleidoscopeNAVFeed` would make every oracle upgrade (platform push → RedStone →
Chainlink NAVLink) a full market redeployment plus liquidity migration. The
forwarder is the permanent address; one `setUpstreamOracle()` call flips the
pointer and every integration follows instantly.

Delegated surface: `decimals()`, `description()`, `version()`,
`getRoundData(uint80)`, `latestRoundData()`, `latestAnswer()`.

Note that `latestAnswer()` is **not** part of `AggregatorV3Interface` — it is an
additional function this contract (and `KaleidoscopeNAVFeed`) implement for Aave
V3's older `AggregatorInterface`. An earlier doc asserted the reverse.

#### Three upstream probes, on both the constructor and `setUpstreamOracle`

| Probe | Rejects | Error |
|---|---|---|
| `decimals()` staticcall, must return 32 bytes with value **8** | EOAs, wrong contracts, any non-8-decimal feed | `InvalidOracle` |
| `version()` staticcall, must return 32 bytes | Partial stubs that implement only `decimals()` (finding M-05) | `InvalidOracle` |
| `latestRoundData()` staticcall — if it succeeds and returns ≥160 bytes, `updatedAt` must **not** be in the future | A feed lying about time | `UpstreamFutureDated(updatedAt, blockTimestamp)` |

`setUpstreamOracle` additionally rejects `address(0)` (`UpstreamCannotBeZero`)
and `address(this)` (`InvalidOracle`).

**Why the future-dated probe matters (GYL-1135).** Every honest consumer defends
against a dead feed with `block.timestamp - updatedAt <= maxAge`. A future-dated
`updatedAt` satisfies that check *unconditionally*, for as long as it stays ahead
of the clock. One pointer swap would therefore silently disarm every integrator's
staleness defence at once, with no event that reads as anomalous. Stale is loud
and fails closed; synthetic-fresh is silent and fails open — strictly worse.
`GyldAtomicSwap._checkQuoteBand` rejects future `updatedAt` at read time
(finding F-6); this is the same invariant enforced one layer earlier, at
configuration time, where it is cheap and where an operator sees it.

The probe is deliberately **tolerant of a reverting `latestRoundData()`**: a
freshly deployed `KaleidoscopeNAVFeed` reverts `NoPriceSet` until its first push,
and pointing the forwarder at one before that push is a legitimate deploy order.
Garbage or short returndata is likewise tolerated here — `decimals()` and
`version()` are what establish "this is an oracle at all". This probe answers only
"is it lying about time?".

It is a **point-in-time** probe, not a guarantee. An upstream can start returning
future timestamps after installation. Consumer-side age checks remain mandatory.

#### Intended upgrade path

| Phase | Upstream | When |
|---|---|---|
| 1 | `KaleidoscopeNAVFeed` (platform push) | Launch — current |
| 2 | RedStone Classic feed | Weeks after launch |
| 3 | Chainlink NAVLink feed | Institutional grade |

---

### 5.6 `SanctionsOracleMirror`

The platform sanctions oracle on **every** production EVM chain, Ethereum
mainnet included (GYL-1051). Plain `AccessControl`, immutable, no proxy, no
pause. A vendor oracle is consumed *through* it rather than instead of it.

#### Read interface

```solidity
function isSanctioned(address addr) public view returns (bool) {
    if (_sanctioned[addr]) return true;            // local list first
    ISanctionsList fwd = forwardingOracle;
    if (address(fwd) == address(0)) return false;   // forwarding disabled
    (bool ok, bytes memory data) = address(fwd).staticcall{gas: FORWARDING_GAS}(
        abi.encodeWithSelector(ISanctionsList.isSanctioned.selector, addr)
    );
    if (!ok || data.length != 32) revert InvalidForwardingOracle(address(fwd));
    return abi.decode(data, (bool));               // canonical bool: non-1 word reverts
}
```

Three properties:

- **Composite, OR-combined.** `true` if either the local list or the forwarding
  oracle flags the address. A local *removal* does not override a forwarding-oracle
  flag — the forwarding oracle is a secondary source of truth, not something local
  state can veto.
- **Gas-capped.** `FORWARDING_GAS = 40_000`, sized for a cold SLOAD plus event
  plus overhead with headroom. Keeps a misbehaving or compromised upstream from
  burning the caller's entire gas budget and bricking every secondary transfer.
- **Fail-closed.** A revert, a non-contract, or malformed returndata all revert
  `InvalidForwardingOracle`, which propagates up through
  `GyldBondToken._requireAccess` and reverts the transfer.
  Note the deliberate asymmetry with `GyldBondToken.sanctionsList`: the mirror's
  `forwardingOracle` is **optional**, so `address(0)` is an accepted configuration
  meaning "forwarding disabled" and the read short-circuits to the local list. The
  token's `sanctionsList` is **mandatory** — zero is rejected by both `initialize`
  and `setSanctionsList`, and `_requireAccess` reverts `SanctionsListNotSet` if it
  is somehow reached. Absence is a configured state here and a fault there.

`name()` returns **`"Gyld sanctions oracle"`**, not `"Chainalysis sanctions
oracle"`. There is also **no `isSanctionedVerbose(address)`** function.
Interface compatibility with the Chainalysis oracle is limited to
`isSanctioned(address)` and the two `SanctionedAddressesAdded` /
`SanctionedAddressesRemoved` event shapes — which is all `GyldBondToken` and
standard tooling actually use.

#### Write interface

| Function | Role | Notes |
|---|---|---|
| `addToSanctionsList(address[])` | `SANCTIONS_UPDATER_ROLE` | Rejects `address(0)` anywhere in the batch (whole batch reverts). Emits `SanctionedAddressesAdded`. |
| `removeFromSanctionsList(address[])` | `SANCTIONS_UPDATER_ROLE` | Same zero-address guard. Emits `SanctionedAddressesRemoved`. |
| `setForwardingOracle(address)` | `DEFAULT_ADMIN_ROLE` | `address(0)` disables forwarding — **and drops every address inherited from it**. Only do this once the local list is fully seeded and reconciled. Should go through the timelock; treat as governance-weight. |

`setForwardingOracle` rejects `address(this)` (`SelfReferenceOracle`) and applies
the **same gas cap and canonical-bool decode as the runtime path**, so a
probe-passing oracle cannot revert or return garbage at call time.

`renounceRole` blocks `DEFAULT_ADMIN_ROLE`, same house idiom.

#### The role split, and its actual limit

The design intent is that the keeper writes data and governance controls the
system, so a compromised keeper key can only write to the list — it cannot grant
itself admin or change who holds the updater role. The compliance multisig can
revoke a compromised bot key and grant a fresh one in one transaction.

The often-repeated claim that "the admin cannot write to the sanctions list" is
**only true one call deep.** `DEFAULT_ADMIN_ROLE` is the admin of
`SANCTIONS_UPDATER_ROLE` and can grant it to itself, then write. The separation
is a *procedural* control that makes unauthorised writes visible in the role-grant
event log — not a cryptographic one.

#### Why this is not an internal blocklist

The platform-wide rule is that there is no platform-managed blocked-address
mapping. The mirror does not violate it because:

- **The data source is OFAC/SDN** — the same dataset that powers the vendor
  oracle. The keeper reads that feed; the platform mirrors, it does not decide.
- **No platform discretion.** Only formally designated addresses (OFAC, UN, EU
  consolidated) enter the list. No compliance officer should call
  `addToSanctionsList` directly for a non-sanctions reason.
- **Deterministic delta.** The keeper computes
  `to_add = ofac_current ∖ mirror_current`, `to_remove = mirror_current ∖ ofac_current`,
  and submits the diff. There is no human review step that could inject a
  subjective block.

Each chain gets **its own** mirror instance. Cross-chain state sharing would put
bridge failure modes into the compliance path.

---

### 5.7 `GyldAtomicSwap`

Self-custodial atomic two-leg settlement against platform-signed EIP-712 quotes.
UUPS singleton — one instance across all series, like `IssuanceManager`.

Inheritance: `Initializable`, `AccessControlUpgradeable`, `PausableUpgradeable`,
`ReentrancyGuardUpgradeable`, `EIP712Upgradeable`, `UUPSUpgradeable`.

**The contract holds its own inventory.** `executeSwap` PULLS `tokenIn` into
`address(this)` and PUSHES `tokenOut` out of `address(this)`'s own balance. There
is no settlement vault and no escrow contract; both were removed in GYL-548. It
never grants a standing outbound allowance — `approve` appears nowhere in the
source. Users approve (or permit) **only** this contract.

Inventory is replenished exclusively through the existing mint-at-fill path: the
swap is a whitelisted AP, so `IssuanceManager.subscribe(token, swap, n)` mints
directly into it. The swap itself has **no mint authority**. Net flow leaves via
`withdraw()` to a fixed, admin-set `withdrawalWallet`.

#### The signed quote

```solidity
struct SwapMessage {
    uint256 quoteId;      // single-use, GLOBALLY and PERMANENTLY across all epochs
    address taker;        // must equal msg.sender at execution
    address tokenIn;      // leg the user pays
    uint256 maxAmountIn;  // CEILING on the taker's single draw
    address tokenOut;     // leg the user receives, from this contract's inventory
    uint256 price;        // fixed-point: amountOut per 1e18 tokenIn
    uint64  expiry;       // unix seconds
    uint64  epoch;        // quote-signer generation
}

struct PermitData { uint256 value; uint256 deadline; uint8 v; bytes32 r; bytes32 s; }
// value == 0 skips the permit entirely
```

| Constant | Value |
|---|---|
| EIP-712 domain | `("GyldAtomicSwap", "2")` + `chainId` + the **proxy** address |
| `SWAP_MESSAGE_TYPEHASH` | `0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b` |
| `MIN_DRAW_BPS` | 100 → a **1 % dust floor** on `requestedAmountIn` relative to `maxAmountIn` |
| `BPS_DENOMINATOR` | 10_000 |
| `DEFAULT_MAX_QUOTE_TTL` | **90 seconds** — the *fallback* for `maxQuoteTtl`, **not** a seed. `initialize` deliberately leaves the slot unset; `_effectiveMaxQuoteTtl` returns this constant whenever the slot reads zero, which is what keeps a proxy upgraded across the field's addition working (see below) |
| `MAX_QUOTE_TTL_CEILING` | **10 minutes** — structural upper bound on `maxQuoteTtl`. It is deliberately far above the 90-second default: the ceiling is the headroom an admin can reach through a timelocked `setMaxQuoteTtl` during an incident, and because it is a `constant`, widening it later would need a new implementation and a proxy upgrade |
| `MAX_NAV_AGE_CEILING` | **72 hours** — structural upper bound on `maxNavAgeSecs` |

The typehash was verified by recomputation:
`keccak256("SwapMessage(uint256 quoteId,address taker,address tokenIn,uint256 maxAmountIn,address tokenOut,uint256 price,uint64 expiry,uint64 epoch)")`
matches the constant exactly.

**Capped allowance, single draw.** `maxAmountIn` is a ceiling; the taker chooses
`requestedAmountIn` at call time (it is *not* part of the signed message), and
`amountOut = requestedAmountIn * price / 1e18` rounds **down, in the contract's
favour** — a taker-favourable rounding direction would let a taker extract dust
across many small draws. The first draw burns the `quoteId` **in full** regardless
of size; the unused remainder of `maxAmountIn` is forfeited. This is
single-shot-capped sizing, not multi-draw. Multi-draw remaining-balance tracking
(`filled[quoteId] += requestedAmountIn`) remains an unbuilt V2 item — it would
swap a 256-quotes-per-slot bitmap for a per-quote counter and reopen "which fill's
NAV and expiry apply to fill #2".

**The signed price is the price.** The NAV feed is a sanity *band*, never the
execution price. The chain never computes a price of its own.

#### `executeSwap` — exact verification order

`external nonReentrant whenNotPaused`. Every check precedes every external call
(CEI); `_consumeQuote` is the only state write before the transfers.

```
 1. m.taker == msg.sender                        → NotTaker
 2. allowed[msg.sender]                          → NotAllowed
 3. m.price != 0                                 → ZeroAmount
 4. minAmountIn = m.maxAmountIn * 100 / 10_000
    0 < requestedAmountIn, >= minAmountIn, <= m.maxAmountIn
                                                 → RequestedAmountOutOfRange
 5. block.timestamp <= m.expiry                  → QuoteExpired
 6. m.expiry <= block.timestamp + maxQuoteTtl    → QuoteExpiryTooFar     (F-4)
 7. m.epoch == quoteEpoch                        → QuoteEpochStale
 8. ECDSA.recover(hashSwapMessage(m), signature) holds QUOTE_SIGNER_ROLE
                                                 → InvalidQuoteSigner
 9. _consumeQuote(quoteId)  ← THE STATE WRITE    → QuoteAlreadyUsed
10. amountOut = requestedAmountIn * m.price / 1e18; amountOut != 0
                                                 → ZeroAmount
11. _checkQuoteBand(...)                         → NotOneBondLeg / InvalidNav /
                                                    StaleNav / QuotePriceOutOfBand
12. optional permit, in try/catch (never load-bearing)
13. LEG 1: safeTransferFrom(msg.sender → address(this), requestedAmountIn)
14. available = tokenOut.balanceOf(address(this)); amountOut <= available
                                                 → InsufficientUsdcLiquidity (if tokenOut == usdc)
                                                    else InsufficientInventory
15. LEG 2: safeTransfer(address(this) → msg.sender, amountOut)
16. emit SwapExecuted(quoteId, taker, tokenIn, requestedAmountIn, tokenOut, amountOut)
```

Measuring `available` **after** the pull-in is sound because exactly one leg is
USDC, so `tokenIn != tokenOut` always — enforced by step 11's leg classification.

Because `_consumeQuote` is an ordinary state write inside the transaction, a swap
that reverts *later* (say at step 14) leaves the `quoteId` **unconsumed** and
re-executable once the blocking condition clears (invariant I-9).

#### The NAV band

```solidity
buy    = registeredSeries[tokenOut] && tokenIn  == usdc;
redeem = registeredSeries[tokenIn]  && tokenOut == usdc;
if (buy == redeem) revert NotOneBondLeg(tokenIn, tokenOut);   // covers tokenIn == tokenOut

(, int256 nav,, uint256 updatedAt,) = INavForwarder(navForwarderOf[bondToken]).latestRoundData();
if (nav <= 0)                                  revert InvalidNav(bondToken, nav);
if (updatedAt > block.timestamp)               revert StaleNav(bondToken, updatedAt);   // F-6
if (block.timestamp > updatedAt + maxNavAgeSecs) revert StaleNav(bondToken, updatedAt);

navValue = tokenAmount * uint256(nav) / 1e20;       // 18dp bond × 8dp NAV / 1e20 = 6dp USDC
band     = navValue * maxQuoteDeviationBps / 10_000;
if (usdcAmount > navValue + band || usdcAmount + band < navValue)
    revert QuotePriceOutOfBand(usdcAmount, navValue);
```

Both bounds are **inclusive**. Worked example at NAV $100.00 with a 2 % band
(`maxQuoteDeviationBps = 200`) for 10 tokens:

- `tokenAmount = 10e18`, feed answer `nav = 100 × 1e8 = 1e10`
- `navValue = 10e18 × 1e10 / 1e20 = 1_000_000_000` micro-USDC = **$1,000.00**
- `band = 1e9 × 200 / 10_000 = 20_000_000` micro-USDC = **$20.00**
- accepted iff `980_000_000 ≤ usdcAmount ≤ 1_020_000_000`, i.e. $98.00–$102.00
  per token. `1_020_000_001` reverts `QuotePriceOutOfBand(1020000001, 1000000000)`.

`updatedAt == block.timestamp` is the inclusive fresh edge.

**The `/1e20` ladder assumes 18 dp bond, 8 dp NAV, 6 dp USDC and mis-scales
silently for anything else.** All three are therefore probed on-chain (finding
F-1), not left as an operational convention:

| Probe | Where | Requires | Error |
|---|---|---|---|
| `usdc.decimals()` | `initialize` | exactly **6** | `InvalidTokenDecimals` |
| `navForwarder.decimals()` | `registerSeries` | exactly **8** | `NotValidForwarder` |
| `token.decimals()` | `registerSeries` | exactly **18** | `InvalidTokenDecimals` |

A failed staticcall or wrong returndata length reports `decimals == 0`, the "no
usable `decimals()`" signal.

#### The NAV staleness ceiling — the single most load-bearing constant here

`KaleidoscopeNAVFeed` deliberately never reverts on a stale answer (Chainlink read
semantics). **This consumer-side `StaleNav` check is therefore the only staleness
defence anywhere in the swap path.**

`maxNavAgeSecs` is admin-settable but structurally bounded:

```
0 < maxNavAgeSecs <= MAX_NAV_AGE_CEILING (72 hours)
```

enforced in **both** `initialize` and `setMaxNavAgeSecs`. The deployed default is
`86400` (24 h). Without the ceiling, `setMaxNavAgeSecs` rejected only zero, and
`uint32` tops out at ~136 years — so a single `DEFAULT_ADMIN_ROLE` call could turn
the guard into a no-op while every getter still reported it as configured. 72 h
matches Euler's structural `MAX_STALENESS_UPPER_BOUND` and keeps 3-day-holiday
tolerance reachable.

`MAX_NAV_AGE_CEILING` is a `constant`, so it occupies no storage slot and does not
affect the ERC-7201 layout.

Note the asymmetry in which parameters may be set permissively.
`maxQuoteDeviationBps = 0` is a *safe* extreme — a soft-pause — so its
**restrictive** end needs no guard. The permissive extreme of `maxNavAgeSecs` is
"accept an arbitrarily old price", which is why it carries a hard ceiling.

`maxQuoteTtl = 0` is a different case and is **not** a soft-pause: zero is the
*unset* sentinel and falls back to `DEFAULT_MAX_QUOTE_TTL`. Treating it as
literal zero seconds would contradict the `block.timestamp > m.expiry` check
immediately above it in `executeSwap` and reject **every** quote a real service
can issue — which is exactly what an un-migrated proxy upgrade would have caused
under the earlier seed-based design. Soft-pausing via the TTL was never usable
anyway: setting it requires the 48 h timelock, whereas `pause()` is a hot key
(`PAUSER_ROLE`, ops multisig) and lands in one block.

> `MAX_NAV_AGE_CEILING` is no longer the only such ceiling. Since `8c41817` all
> three admin-tunable bounds are structurally capped: `MAX_NAV_AGE_CEILING` (**72 h**,
> `InvalidNavAge`), `MAX_QUOTE_DEVIATION_BPS_CEILING` (**1000 bps = 10 %**,
> `InvalidDeviationBps`, enforced in both `initialize` and
> `setMaxQuoteDeviationBps`) and `MAX_QUOTE_TTL_CEILING` (**10 min**,
> `InvalidQuoteTtl`, enforced in `setMaxQuoteTtl`; zero stays legal and still means
> *unset* → fall back to `DEFAULT_MAX_QUOTE_TTL`). Before that, the deviation band
> was bounded only by `BPS_DENOMINATOR` — a ±100 % band, which admits any price from
> zero to 2× NAV — and `setMaxQuoteTtl` validated nothing at all; both permissive
> ends were reachable by a single `DEFAULT_ADMIN_ROLE` call, which is why GYL-1135
> closed them.

#### Quote invalidation

`_consumeQuote` is a 1inch-style BitInvalidator: one bit per `quoteId`, 256 quotes
per storage slot, indexed as word `quoteId >> 8`, bit `quoteId & 0xff`.
`isQuoteUsed(quoteId)` exposes it.

`bumpQuoteEpoch()` (`DEFAULT_ADMIN_ROLE`) increments `quoteEpoch` by exactly one
and kills every outstanding quote in one transaction — the signer-rotation and
incident-response lever. Rotation is: grant the new `QUOTE_SIGNER_ROLE`, bump,
revoke the old.

**The usage bitmap is NOT epoch-scoped.** `bumpQuoteEpoch` writes only
`quoteEpoch`; it does not clear `usedQuoteWords`. A consumed id stays consumed
across every future epoch, so the quote service must allocate ids from a single
monotonic counter that never resets, even after a mass invalidation (invariant
I-5, finding F-3). Getting this wrong would silently make re-issued quotes
un-executable.

`hasRole(QUOTE_SIGNER_ROLE, signer)` is evaluated at **execution** time, not
signing time — revoking a signer invalidates every in-flight quote from that key
immediately (I-12).

Because the EIP-712 domain includes `chainId` and the proxy address, the same
message bytes hash differently on another chain or another proxy, so a signature
cannot be replayed across either (I-13).

#### Series registry

`registerSeries(token, navForwarder)` (`DEFAULT_ADMIN_ROLE`) probes both
decimals, pushes `token` onto `seriesList` if new, and sets
`registeredSeries` / `navForwarderOf`. Re-registering an active series just
updates its forwarder — which is also the escape hatch if a forwarder is bricked.

`deregisterSeries(token)` reverts `SeriesNotEmpty` while the contract still holds
any balance of the series: silently orphaning inventory that can no longer be
priced or served is unsafe. It swap-and-pops `seriesList` and deletes both
mappings. The list is **not** externally observable, and **order is not stable
across deregistrations** (invariant I-24).

> **A paused bond token blocks deregistration too.** The only way to reach
> `balanceOf(swap) == 0` is `withdraw`, and `withdraw` is precisely what a paused
> bond token blocks (see *Treasury withdrawal* below). So a token pause silently
> gates this second, unrelated admin operation: the retirement of a matured series
> fails with a bare `SeriesNotEmpty(token)` that names the balance, not the pause
> that is actually preventing you from clearing it — and via the timelock, 48 h
> after the proposal. The runbook's unpause → withdraw → re-pause sequence is
> therefore a **precondition for deregistration**, not just an evacuation remedy.
> Check `token.paused()` before proposing.

#### Treasury withdrawal

```solidity
function withdraw(address token, uint256 amount) external nonReentrant onlyRole(TREASURER_ROLE) {
    if (amount == 0) revert ZeroAmount();
    address to = _getStorage().withdrawalWallet;
    if (to == address(0)) revert ZeroAddress();       // fail-closed until admin sets it
    IERC20(token).safeTransfer(to, amount);
    emit Withdrawn(token, to, amount);
}
```

Three deliberate properties:

- **The treasurer can never redirect.** Funds only ever go to the admin-fixed
  `withdrawalWallet`. `setWithdrawalWallet` is `DEFAULT_ADMIN_ROLE` — the timelock
  in production. This is the core safety property of the withdrawal path.
- **`withdrawalWallet` starts at `address(0)`** and is deliberately *not* set in
  `initialize`. `withdraw` reverts until the admin sets it.
- **Not `whenNotPaused`.** The treasury drain must work during an incident pause
  so inventory can be evacuated. It shares the `nonReentrant` guard with
  `executeSwap`, so a malicious inventory token cannot use the withdrawal transfer
  hook to enter `executeSwap` (I-17).
- **That exemption covers this contract's pause only — and a paused bond token
  still gates its own leg.** There are two independent pause switches. `withdraw`
  ignores the swap's. It cannot ignore the token's: moving a `GyldBondToken` calls
  its `transfer`, which is `whenNotPaused`, so the revert is `EnforcedPause` raised
  by that modifier on `GyldBondToken.transfer` itself — not in the swap, and not in
  the token's `_update` (which carries only the sanctions check; the pause gate never
  reaches it). Easy to misattribute from a bare `cast` error. USDC has no pause and
  evacuates normally with both switches pulled. This also gates `deregisterSeries`,
  which needs `balanceOf(swap) == 0` and so cannot succeed until the token is
  unpaused long enough to withdraw — see *Series registration* above.

  This is a **design requirement, not a gap**. A pause that inventory can be moved
  through is not a pause; the token's pause is the stronger statement and is meant
  to win, and `GyldAtomicSwap` holds no privileged position on the token — giving it
  one to make evacuation smoother would hand the swap a transfer path that bypasses
  the token's own halt. The operational answer is sequencing, not a bypass: unpause
  the token (`PAUSER_ROLE` on the token — no admin, no timelock), withdraw, re-pause,
  with the swap left paused throughout. Written out step by step in the runbook's
  **"Evacuating a paused bond token"**, and pinned by three tests in
  `GyldAtomicSwap.t.sol` (audit §4.5).

The `withdrawalWallet` is intentionally **not** required to be on the taker
allowlist: it is a cold treasury address that never calls `executeSwap`, and
coupling the two would add no security while risking a bricked `withdraw` during
incident response.

#### Pause — asymmetric on purpose

| | Caller |
|---|---|
| `pause()` | `PAUSER_ROLE` (ops multisig) |
| `unpause()` | `DEFAULT_ADMIN_ROLE` (the timelock) |

Cheap to halt, deliberate to resume. This contract sits on the hot path with a hot
signing key, which is why it deviates from `GyldBondToken`'s symmetric pause.

#### Non-renounceable roles

`renounceRole` reverts for exactly **one** role:

| Role | Error | Why |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | `CannotRenounceAdminRole` | Losing it bricks upgrades, unpause, series registration, withdrawal-wallet control and all role management including signer rotation. There is no second holder by construction, so this one is genuinely unrecoverable. |

Every other role — `PAUSER_ROLE`, `TREASURER_ROLE`, `QUOTE_SIGNER_ROLE`,
`ALLOWLIST_ADMIN_ROLE` — stays renounceable. Signer rotation and ops-key retirement
are legitimate self-service actions, and so is shedding a role you believe is
compromised.

**F-7 proposed extending the block to `PAUSER_ROLE` and `TREASURER_ROLE`, and was
rejected.** Recording why, because the argument looks persuasive until you check it:

- **Nothing is stranded.** `DEFAULT_ADMIN_ROLE` administers every role — no
  `_setRoleAdmin` call exists anywhere in the contract and `getRoleAdmin`/`grantRole`
  are unoverridden — so a renounce costs one `grantRole`, not a permanent loss.
- **There is no accidental path.** OZ's `renounceRole(role, callerConfirmation)`
  requires `callerConfirmation == msg.sender`, so you cannot renounce someone else's
  role or fat-finger an address into a self-renounce. Both roles are held by M-of-N
  wallets in the deployed topology, so an "accident" would need a signing quorum to
  approve a transaction whose only effect is surrendering their own role.
- **A malicious renounce is pure self-harm.** A compromised `PAUSER` renouncing
  removes the defenders' halt but gains the attacker nothing — they had no use for
  `pause()`. A compromised `TREASURER` renouncing surrenders its own `withdraw()`,
  which can only ever send to the admin-fixed `withdrawalWallet` and was never a
  theft primitive.
- **It removed the case that matters.** A holder who *knows* their key is compromised
  could no longer shed the role immediately, and had to wait on a timelocked
  `revokeRole` instead. The guard traded one exposure window for a worse one.

Pinned by `test_renounceRole_onlyAdminRoleIsBlocked` so it is not reintroduced.

#### Permit is never load-bearing

The optional EIP-2612 permit is applied in `try/catch` and its failure is
swallowed. A front-run `permit()` that pre-consumes the nonce cannot brick the
swap, because `safeTransferFrom` enforces the allowance regardless. A `tokenIn`
with no `permit()` at all works fine via a plain approval (I-22). Real USDC's
permit uses a non-standard domain version `"2"`, which is the practical reason the
leg is optional.

Residual-allowance note: `permitIn.value` may exceed `requestedAmountIn`, leaving
leftover allowance to the swap. That is safe — it is only spendable through a
taker-initiated `executeSwap` — but the quote service should issue exact-value
permits.

**Storage:** ERC-7201 namespace `gyld.GyldAtomicSwap`, base slot
`0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300`. Layout and
packing are pinned by test (I-19); see [§12](#12-storage-upgradeability-erc-7201).

---

## 6. Role and permission matrix

### 6.1 The complete matrix

Every role on every contract, what it gates, and who should hold it in
production. This is the table to read first if you are auditing the system.

| Contract | Role / owner | Gates exactly | Production holder | Renounceable |
|---|---|---|---|---|
| `GyldBondToken` | `DEFAULT_ADMIN_ROLE` | Grant/revoke all roles; `setSanctionsList`; **UUPS upgrade** | **TimelockController** (48 h) | **No** |
| `GyldBondToken` | `MINTER_ROLE` | `mint(to, amount)` | `IssuanceManager` **only** | Yes |
| `GyldBondToken` | `BURNER_ROLE` | `burn(from, amount)` | `IssuanceManager` **only** | Yes |
| `GyldBondToken` | `PAUSER_ROLE` | `pause()` **and** `unpause()` | Ops multisig (hot, no delay) | Yes |
| `GyldBondToken` | `DOCUMENT_ROLE` | `setDocument`, `removeDocument` (IERC-1643) | Ops multisig (hot, no delay — operational, GLD-264) | Yes |
| `IssuanceManager` | `DEFAULT_ADMIN_ROLE` | Grant/revoke all roles; **UUPS upgrade** | **TimelockController** (48 h) | **No** |
| `IssuanceManager` | `SUBSCRIBER_ROLE` | `subscribe()` — the mint path | MPC / Fordefi wallet A | Yes |
| `IssuanceManager` | `REDEEMER_ROLE` | `redeem()` — the burn path | MPC / Fordefi wallet B, **distinct from A** | Yes |
| `IssuanceManager` | `WHITELIST_ADMIN_ROLE` | `addToWhitelist`, `removeFromWhitelist`, `addToWhitelistBatch` | Compliance ops Gnosis Safe | Yes |
| `IssuanceManager` | `REGISTRAR_ROLE` | `registerToken`, `deregisterToken` | `TokenFactory` — **held permanently, never revoked** | Yes |
| `TokenFactory` | `owner` (`Ownable2Step`) | `deployToken`; is also the address that receives `DEFAULT_ADMIN_ROLE` on every token and `owner` of every forwarder | **TimelockController** (48 h) | **No** — `renounceOwnership()` reverts `CannotRenounceOwnership` (GLD-166). Not retrofitted to factories deployed before it. |
| `KaleidoscopeNAVFeed` | `owner` (`Ownable2Step`) | `updateAnswer` — **the only write path**, and it bypasses nothing | AWS KMS signer (Phase 1) → Fordefi MPC (Phase 2) | **No** — `renounceOwnership()` reverts `CannotRenounceOwnership` (GLD-165). Not retrofitted to feeds deployed before it. |
| `NAVFeedForwarder` | `owner` (`Ownable2Step`) | `setUpstreamOracle` | **TimelockController** — an EOA here is one key that can repoint every integrated market's price feed | **No** — `renounceOwnership()` reverts `CannotRenounceOwnership` (GLD-166). Not retrofitted to forwarders already deployed.
| `SanctionsOracleMirror` | `DEFAULT_ADMIN_ROLE` | Grant/revoke roles; `setForwardingOracle` | Compliance ops Gnosis Safe | **No** |
| `SanctionsOracleMirror` | `SANCTIONS_UPDATER_ROLE` | `addToSanctionsList`, `removeFromSanctionsList` | Keeper-bot hot wallet | Yes |
| `GyldAtomicSwap` | `DEFAULT_ADMIN_ROLE` | **UUPS upgrade**; `unpause`; `registerSeries` / `deregisterSeries`; `setMaxQuoteDeviationBps`; `setMaxNavAgeSecs`; `setMaxQuoteTtl`; `setWithdrawalWallet`; `bumpQuoteEpoch`; role grants | **TimelockController** (48 h) | **No** |
| `GyldAtomicSwap` | `ALLOWLIST_ADMIN_ROLE` | `setAllowed()` — the taker allowlist, **and nothing else** | KMS compliance/ops hot key (`EVM_KMS_SWAP_ADMIN_*`) | Yes |
| `GyldAtomicSwap` | `QUOTE_SIGNER_ROLE` | Passive — checked via `hasRole` against the recovered EIP-712 signer. The role registry **is** the signer set. | Quote-service KMS key(s) | Yes |
| `GyldAtomicSwap` | `TREASURER_ROLE` | `withdraw()` — only ever to the admin-fixed `withdrawalWallet`. **Live while paused.** | Ops MPC wallet | Yes |
| `GyldAtomicSwap` | `PAUSER_ROLE` | `pause()` **only** — resuming needs the admin | Ops multisig | Yes |
| `TimelockController` | `PROPOSER_ROLE` | Schedule operations | Governance Gnosis Safe | — |
| `TimelockController` | `EXECUTOR_ROLE` | Execute after the delay | `address(0)` = **anyone**, once the delay has elapsed | — |
| `TimelockController` | `DEFAULT_ADMIN_ROLE` | Timelock self-administration | `address(0)` at construction → self-administered from birth; **no separate admin that could bypass the delay** | — |

### 6.2 Design principles visible in the matrix

- **Nothing except `IssuanceManager` can mint or burn.** `MINTER_ROLE` and
  `BURNER_ROLE` go to one contract, never to an EOA, never to the operator, never
  to the swap.
- **The mint and burn quorums are split.** `SUBSCRIBER_ROLE` and `REDEEMER_ROLE`
  are separate keys, and `DeployGuards.requireDistinct` refuses a production
  deploy where they are the same address.
- **Pause is a hot key everywhere; unpause is not always.** The token's pause is
  symmetric (ops can resume); the swap's is asymmetric (only the timelock can
  resume). The swap runs off a hot signing key, so re-arming it is deliberately
  slow.
- **One same-day hot key is carved out of the timelock on purpose.**
  `ALLOWLIST_ADMIN_ROLE` was split off `DEFAULT_ADMIN_ROLE` in GYL-1050 precisely
  so that per-taker allowlisting does not need a 48 h governance proposal per
  user. It grants access to *swap*, never to funds or upgrades — that is what makes
  the carve-out acceptable.
- **The NAV feed has no privileged bypass at all.** `updateAnswer` is the single
  write path and its interval and deviation guards are unconditional, so the feed
  owner's ceiling is genuinely 10 %/hour with no second key that lifts it
  ([D-19](#171-adopted-and-current)).
- **Among *roles*, only `DEFAULT_ADMIN_ROLE` is non-renounceable.** (Separately,
  `KaleidoscopeNAVFeed.renounceOwnership()` reverts — GLD-165 — but that is
  ownership, not a role.) `PAUSER_ROLE` and
  `TREASURER_ROLE` stay renounceable deliberately — the admin re-grants either in one
  transaction, so a renounce strands nothing, and a holder who knows their key is
  compromised must be able to shed the role without waiting on the timelock. See
  §Non-renounceable roles for why F-7 was rejected.

### 6.3 What a single key compromise buys

| Compromised | Immediate capability | Ceiling / mitigation |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` on the swap (i.e. the **timelock**) | Upgrade the implementation, redirect `withdrawalWallet`, widen the band, drain everything | **Unbounded** up to `sum(balanceOf(swap))`. Mitigated only by the 48 h delay and by governance being a multisig. See [§7](#7-custody-model-and-loss-ceilings). |
| `DEFAULT_ADMIN_ROLE` on a token | Upgrade the token implementation; grant itself `MINTER_ROLE` | Unbounded. 48 h delay is the only brake. |
| `SUBSCRIBER_ROLE` | Mint arbitrary amounts of any registered token — but **only to a whitelisted AP** | Blast radius limited to KYC-approved addresses. Token pause stops it. Supply reconciliation should catch it. |
| `REDEEMER_ROLE` | Burn the whole pooled `IssuanceManager` balance naming any whitelisted AP | Cannot redirect the off-chain USDC payment (a separate backend service keys off the `Redeemed` event's beneficiary). Cannot name a non-whitelisted address, so no payout results. Token pause stops it. |
| `WHITELIST_ADMIN_ROLE` | Add an attacker-controlled address to the AP whitelist — which then makes it a legal mint target or redemption beneficiary | Needs `SUBSCRIBER_ROLE`/`REDEEMER_ROLE` as well to extract value. Whitelist events are cheap to monitor. |
| `PAUSER_ROLE` (token) | Halt all token movement, including liquidations on Morpho and Euler | Denial of service, not theft. Note this **freezes DeFi liquidations** — undercollateralised positions cannot be closed until unpause. |
| `QUOTE_SIGNER_ROLE` | Sign quotes at any price | Bounded by `maxQuoteDeviationBps` (deployed 2 %) against the on-chain NAV, **per trade**. The feed is written by a *different* key and is itself capped at ±10 % per hour, so one stolen key cannot both move the reference and exploit the band. Contained by `bumpQuoteEpoch`. |
| `ALLOWLIST_ADMIN_ROLE` | Allowlist an attacker address as a swap taker | Still needs a valid signed quote from `QUOTE_SIGNER_ROLE`, still bounded by the NAV band. No access to funds or upgrades. |
| `TREASURER_ROLE` | Move all swap inventory out | **Only to the admin-fixed `withdrawalWallet`.** Cannot redirect. This is why the role is safe to keep live while paused — the swap's pause, that is; a paused bond token still blocks its own leg, by design — see §5.7 › *Treasury withdrawal*. |
| `KaleidoscopeNAVFeed.owner` (KMS) | Move NAV **±10 % per hour, and nothing faster** | Hard ceiling — the feed has no bypass function and no second privileged address, so this is the whole of what the key buys. A 25 % total move takes 3 hours of chained updates, which is enough time to detect it, pause the token and rotate the key. Every push emits `AnswerUpdated`. |
| `SANCTIONS_UPDATER_ROLE` (keeper) | Sanction arbitrary addresses (griefing) or un-sanction a designated one (evasion) | Cannot grant itself admin. Compliance multisig revokes and re-grants in one transaction. |
| `TokenFactory` (holds `REGISTRAR_ROLE` forever) | If the factory were ever upgraded — it cannot be, it is immutable — or if its `owner` (the timelock) were compromised, `deployToken` could register a token | The factory has no `registerToken` passthrough, so the only reachable effect is registering a token it deploys itself. The residual `REGISTRAR_ROLE` is a **documentation defect, not an exploitable one** — but do not build a threat model that assumes the factory holds no permissions post-deploy. |

---

## 7. Custody model and loss ceilings

### 7.1 The swap is self-custodial

`GyldAtomicSwap` **holds its own inventory** — USDC and bond tokens sit in the
swap's own balance. This is a deliberate change made in GYL-548, which deleted
`GyldSettlementVault` and the deferred DvP escrow that preceded it.

```
BUY:    taker USDC ──safeTransferFrom──▶ swap
        swap bond ───safeTransfer─────▶ taker      (from swap's own balance)

REDEEM: taker bond ──safeTransferFrom──▶ swap
        swap USDC ───safeTransfer─────▶ taker      (from swap's own balance)

REPLENISH: IssuanceManager.subscribe(token, swap, n)   ← swap is a whitelisted AP
DRAIN:     swap.withdraw(token, amount) → withdrawalWallet   ← TREASURER_ROLE only
```

Buys and redemptions **net** on the swap's balance sheet: bond tokens taken in on
a redeem re-enter inventory and serve the next buyer. Only net flow needs bridging
to the broker.

### 7.2 The loss ceiling, stated plainly

**The maximum on-chain loss from a full compromise of the swap is
`sum(balanceOf(swap))` across every token it holds** — all USDC plus all bond
inventory, at once.

Under `DEFAULT_ADMIN_ROLE` compromise this is **unbounded**: the admin can upgrade
the implementation to anything, or simply call `setWithdrawalWallet` and then have
the treasurer drain to it. No band, cap, allowlist or pause constrains an admin
that can replace the code. The only brakes are the 48 h timelock delay and the
fact that governance is a multisig.

Under `TREASURER_ROLE` compromise alone the ceiling is the same magnitude but the
funds are **not stealable**: they can only be pushed to the admin-fixed
`withdrawalWallet`. That is the whole reason the role can stay live while paused.

Under `QUOTE_SIGNER_ROLE` compromise the loss per trade is bounded by
`maxQuoteDeviationBps` (2 % deployed) of NAV value, and the NAV reference itself is
written by a different key under a ±10 %/hour cap.

This is a genuinely different risk profile from the removed vault design, where LP
capital sat behind share accounting and a `SWAP_ROLE`-gated `onSwap` was the only
fund-out path. The self-custodial model is simpler — fewer contracts, no LP share
math, no receivable accounting, no first-depositor inflation surface — and the
price of that simplicity is that the swap's balance is directly exposed to its own
admin.

### 7.3 What limits the exposure in practice

- **Keep inventory small.** The swap should hold only working inventory, with net
  flow swept to the treasury wallet regularly. The loss ceiling is a *balance*, so
  it is an operational choice.
- **Nothing else holds value.** `IssuanceManager` holds pooled tokens during the
  redemption window, but they are inert — no `withdraw`, `transfer` or `rescue`
  function exists, so the only thing that can happen to them is a burn.
  `TokenFactory`, both oracles and the sanctions mirror hold nothing.
- **No standing allowances anywhere.** `approve` appears nowhere in the swap. The
  only inbound `transferFrom` pulls from `msg.sender`. Users approve exactly one
  contract, ideally exact-value via permit. This is the Hashflow-2023 lesson: every
  approval target must be small, verified and in audit scope.
- **The swap never mints.** It is a whitelisted AP with no mint authority, pinned
  by a stateful invariant asserting bond `totalSupply` never changes across
  BUY/REDEEM sequences (I-10).

---

## 8. Value accrual — NAV, not balances

### 8.1 The model

`GyldBondToken` is a plain OpenZeppelin ERC-20. Balances are fixed integer counts
of bond units and change **only** via `mint` and `burn`. Coupons, NAV
appreciation and price changes are reflected **exclusively** in the paired
`KaleidoscopeNAVFeed`.

```
The token balance says:  "you own 100 units."
The NAV feed says:       "each unit is worth $X today."
Portfolio value is:      balanceOf × NAV        ← every integrator computes this
```

When a coupon arrives from the broker, the backend records it in its ledger and
pushes an updated NAV. **The token balance does not change.**

What is deliberately absent:

- No `shares` internal accounting
- No `burnShares()` / `redeemShares()` / `transferShares()` / `sharesOf()`
- No multiplier or NAV accrual that affects real `balanceOf` / `totalSupply`
- No display-only multiplier either (see [§8.3](#83-erc-8056-was-evaluated-and-dropped))
- No `MULTIPLIER_UPDATER_ROLE` or `UI_MULTIPLIER_ROLE`
- No rebasing — the number of tokens in a wallet never moves from NAV movement

### 8.2 Why

1. **Off-chain settlement means the exact amount is always known.** Mint and burn
   are triggered by the backend after confirmed settlement; there is no on-chain
   accumulation needing a share layer.
2. **No dust residual.** `burnShares` exists to solve a rounding residual when
   converting amounts to shares and back. With a plain ERC-20 there is no
   conversion — `burn(address, amount)` deducts exactly `amount`. No residual, no
   cleanup transaction.
3. **Smaller audit surface.** Share/multiplier math is bespoke and expensive to
   audit. Standard OZ mint/burn is the most-reviewed code in the ecosystem; dropping
   the multiplier removed roughly 150 lines of custom math from scope.
4. **NAV in the oracle is what DeFi already reads.** `AggregatorV3Interface` is the
   format Morpho, Euler and Aave consume natively. The token stays simple.

### 8.3 ERC-8056 was evaluated and dropped

A display-only scaled-UI-amount extension (ERC-8056) was added under GYL-956 and
**removed under GYL-1201** (2026-08-03). The full rationale, with the verification
method for each claim, is the standing decision record at
[`decisions/erc8056-dropped-on-evm.md`](decisions/erc8056-dropped-on-evm.md).
It is kept as a separate dated ADR specifically so the question is not
re-litigated. The short version:

- It is a **stock-splits standard**. Bonds do not split; they accrue and mature.
  Using it as a continuous NAV mirror created a **second NAV channel** on the token
  that had to be kept manually in lock-step with the feed — a reconciliation
  liability, not a feature.
- **No EVM wallet implements it**, and the architecture makes that unlikely to
  change. On Solana the multiplier lives in the token program, so the RPC returns a
  scaled `uiAmount` and every wallet inherits it free. Ethereum JSON-RPC has no
  token-aware method at all, so scaling is opt-in per wallet per token with no
  chokepoint.
- **Observed on our own deployment:** MetaMask displayed 1,000.00 where BscScan
  displayed 1,040.00 — same wallet, same contract, same block, multiplier 1.04×.
  A display standard only explorers honour makes display *less* consistent.
- Of **22 tokenised-fund/bond issuers verified on-chain**, exactly **one** uses
  ERC-8056 (Robinhood Chain, who own both the chain and the app their users see —
  i.e. they *are* the chokepoint). **Not one bond or treasury issuer** uses a
  display multiplier. Superstate co-authored the EIP and does not use it on their
  own $600 M+ funds. Backed uses the scaled-amount mechanism on Solana but rebasing
  on Ethereum for the same token.

**The consequence is that the NAV feed is now more load-bearing, not less.** It is
the *only* on-chain value-display channel rather than one of two, which raises the
priority of the stale-feed and keeper gaps in [§18](#18-known-gaps-and-open-decisions).

Two throwaway testnet proxies still carry the old extension bytecode and must
never be reused for a new series — they are recorded, with their addresses and
do-not-reuse status, in [`DEPLOYMENTS.md`](../DEPLOYMENTS.md); see also
[§14](#14-deployed-addresses).

### 8.4 Peer comparison

| Value-display model | Count (of 22 verified) | Examples |
|---|---|---|
| **Repricing / ERC-4626 — NAV in an oracle or share price** | **10** | USYC, Spiko, Midas, OpenEden, Superstate, sDAI, sUSDS, sUSDe, stUSD, Ondo |
| Rebasing | 5 | — |
| Mint-extra-units (dividend as new tokens) | 2 | BUIDL, BENJI |
| ERC-8056 display multiplier | 1 | Robinhood Chain |

Gyld sits in the first row. That is the model used by every comparable tokenised
treasury or bond issuer.

---

## 9. Settlement flows

Two paths reach the same token, with very different guarantees.

| | Atomic (`GyldAtomicSwap`) | Deferred (`IssuanceManager`) |
|---|---|---|
| Legs | Both, in one transaction | Token leg only |
| Cash | On-chain USDC, from swap inventory | **Off-chain**, after the burn |
| Price | Platform-signed EIP-712 quote, NAV-banded | Not on-chain at all |
| Who calls | The taker (an allowlisted AP) | Platform keys (`SUBSCRIBER` / `REDEEMER`) |
| Failure mode | Atomic revert — nothing moves | Tokens burned, payout is a promise |
| Supply effect | **None** — only pre-minted inventory moves | Mint / burn |

### 9.1 Atomic path — `GyldAtomicSwap.executeSwap`

Direction is implicit and the function is direction-agnostic: **BUY** when
`tokenIn` is USDC and `tokenOut` a registered series; **REDEEM** when reversed.
Exactly one leg must be a registered bond series and the other must be USDC.

```
BUY, worked end to end
──────────────────────
 off-chain  taker requests a quote; quote service checks KYC/sanctions, allocates
            quoteId from a monotonic counter, signs
              {quoteId, taker, tokenIn=USDC, maxAmountIn=1000e6,
               tokenOut=BOND, price, expiry=now+60s, epoch}
            with a QUOTE_SIGNER_ROLE key over the ("GyldAtomicSwap","2") domain

 on-chain   taker calls executeSwap(m, sig, permitIn, requestedAmountIn = 200e6)
              ├─ taker binding: m.taker == msg.sender          (not bearer paper)
              ├─ allowlist:     allowed[msg.sender]
              ├─ draw range:    10e6 (1% floor) <= 200e6 <= 1000e6
              ├─ expiry, TTL bound, epoch
              ├─ signature recovers to a QUOTE_SIGNER_ROLE holder
              ├─ quoteId bit consumed — BEFORE any transfer
              ├─ amountOut = 200e6 * price / 1e18, floored
              ├─ NAV band + freshness on the series forwarder
              ├─ optional permit (try/catch)
              ├─ pull 200e6 USDC from taker
              └─ push amountOut BOND from own inventory
```

**The security mechanisms, and what each defeats:**

| Mechanism | Defeats |
|---|---|
| **Taker binding** (`m.taker == msg.sender`) | Quote theft and MEV-bot execution of someone else's quote. Quotes are not bearer paper (the 0x mandatory-taker pattern). |
| **Taker allowlist** (`allowed[msg.sender]`, `ALLOWLIST_ADMIN_ROLE`) | An un-onboarded address executing at all, even with a validly signed quote. |
| **Single-use `quoteId`** (BitInvalidator, consumed *before* any transfer) | Replay, including replay on a different leg inside the expiry window. 256 quotes per storage slot. |
| **Quote expiry** | Sitting on a favourable price while NAV moves. The TTL policy itself (~60 s class) is off-chain; the chain checks the timestamp. |
| **TTL bound** (`expiry <= now + maxQuoteTtl`, default **90 s**) | A long-dated quote from a buggy or compromised signer. Such a quote is an **American option**: the taker holds a frozen price and picks the moment within its life when that price is most favourable to them, so the leak costs close to the full `maxQuoteDeviationBps` width rather than a fraction of it. Note this guard does **not** protect the NAV band — `_checkQuoteBand` re-reads the feed live on every execution — and it is **not** the only containment faster than the timelock: `pause()` (`PAUSER_ROLE`) and `setAllowed(taker,false)` (`ALLOWLIST_ADMIN_ROLE`) both act in one block on hot keys, and quotes are taker-bound. What the TTL bounds is the window before anyone *notices* (F-4). |
| **`quoteEpoch` mass-kill** (`bumpQuoteEpoch`, admin) | Signer-key compromise: one transaction invalidates every outstanding quote (the 1inch epoch pattern). |
| **NAV band** (`maxQuoteDeviationBps`) | A fully compromised quote signer. Even a valid signature moves price at most ±2 % off on-chain NAV per trade, and the feed is written by a *different* key under a ±10 %/hour cap — one stolen key cannot both move the reference and exploit the band. `setMaxQuoteDeviationBps(0)` is a documented on-chain soft-pause. |
| **`StaleNav`, ceilinged at 72 h** | Pricing against a NAV nobody refreshed. The only staleness defence in the path, since the feed never reverts. |
| **`InvalidNav` fail-closed** | A `<= 0` feed answer silently wrapping through a bare `uint256` cast into a ~2²⁵⁶ valuation. |
| **Future-dated NAV rejection** (F-6) | An `updatedAt` ahead of the clock satisfying the age check forever. |
| **Decimal probes** (F-1) | The `/1e20` ladder mis-scaling silently on a non-18dp series or non-6dp cash token. |
| **Push, not allowance** | The Hashflow-June-2023 class: the swap grants **zero** outbound allowances, ever. Outbound funds move only by push; the only inbound `transferFrom` pulls from `msg.sender`. |
| **Asymmetric pause** | A hot-key incident. `PAUSER_ROLE` halts cheaply; only the timelock resumes. `withdraw` stays live so inventory can be evacuated — past *this* contract's pause; a paused bond token still gates its own leg by design — see §5.7 › *Treasury withdrawal*. |
| **CEI + shared reentrancy guard** | `_consumeQuote` is the only state write and precedes all external calls. `executeSwap` and `withdraw` share one guard, so a malicious inventory token's transfer hook cannot re-enter (I-17). |
| **Probe-before-store** | Fat-finger config: `registerSeries` probes forwarder `decimals()==8` and token `decimals()==18`; `initialize` probes USDC `decimals()==6`. |
| **Permit griefing tolerance** | A front-run `permit()` cannot brick the swap — `try/catch` swallows it and `safeTransferFrom` enforces the allowance regardless. |

**Sanctions on the swap path.** There is no oracle call in `GyldAtomicSwap` at all,
by design. Every swap has exactly one `GyldBondToken` leg, and the token screens
it. Note the precise mechanism, because it is routinely mis-stated: `_update`
screens `from` and `to`; the *spender* check lives in
`GyldBondToken.transferFrom`, where `msg.sender` is the swap. So on the pull-in leg
the swap is screened as spender and as `to`; on the push-out leg it is screened as
`from` and the taker as `to`. A sanctioned counterparty reverts the entire atomic
transaction, unwinding leg 1 too.

### 9.2 Deferred path — `IssuanceManager`

```
SUBSCRIBE (mint)
  1. Backend confirms USDC received from a whitelisted AP source, sweeps to the
     broker, buys the bond, waits for T+1/T+2 settlement.
  2. SUBSCRIBER_ROLE calls subscribe(token, recipient, amount).
  3. Contract checks: registered token, whitelisted recipient, amount > 0.
  4. token.mint(recipient, amount)         ← IssuanceManager holds MINTER_ROLE
  5. emit Subscribed(token, recipient, amount)

REDEEM (burn)
  1. AP calls token.transfer(issuanceManager, amount)  — a PLAIN ERC-20 transfer.
     That Transfer event IS the on-chain commitment signal.
  2. Backend detects it, records external_ref = tx_hash, confirms whitelist status.
  3. REDEEMER_ROLE calls redeem(token, beneficiary, amount).
  4. Contract checks: registered token, whitelisted beneficiary, amount > 0.
  5. token.burn(address(this), amount)     ← burns from its OWN pooled balance
  6. emit Redeemed(token, beneficiary, amount)
  7. Backend sends USDC/USD to the customer OFF-CHAIN.
```

**Step 7 has no on-chain guarantee.** This is the single most important property of
this path and it must be stated without softening: the tokens are destroyed in step
5 and the payout is a promise recorded in an event. Atomicity is not attempted
because no value moves on-chain at redemption time.

What the on-chain check *does* guarantee: only a known, vetted AP can appear as a
beneficiary in a burn event. Even a compromised `REDEEMER_ROLE` key cannot name an
arbitrary address — only a whitelisted one — and since USDC is sent off-chain after
`Redeemed` is emitted, naming a non-whitelisted beneficiary produces no payout
anyway. The whitelist check closes that path entirely.

What it does **not** guarantee: that `beneficiary` deposited exactly `amount`, or
that `beneficiary` is the AP whose `Transfer` triggered this redemption. Both live
in the backend. The threat model accepts that `REDEEMER_ROLE` is trusted; its
mitigations are MPC key custody (2-of-3 threshold, key never on one machine), the
token pause as a halt lever, and balance monitoring that alerts when the
`IssuanceManager` balance drops faster than the rate of legitimate redemption
orders.

**Replay protection is entirely off-chain.** Every on-chain `Transfer` has a unique
tx hash; the backend writes it as `external_ref` before calling `redeem` and exits
early if it is already present. The contract has no idempotency guard. Missing that
check is a backend bug the chain cannot catch.

### 9.3 How the two paths interact

The atomic path's inventory comes from the deferred path. The swap is whitelisted
as an AP so `subscribe(token, swap, n)` mints inventory straight into it — through
the unchanged mint-at-fill pipeline, with no new mint authority anywhere. USDC for
the redeem leg is funded by plain transfer to the swap.

This reverses the vault-era topology, where the swap was deliberately *not*
whitelisted because it held no inventory. Now it holds inventory, so it must be a
whitelisted mint recipient. `DeployAtomicSettlement.s.sol` step 2 performs exactly
that one touch on the existing contracts, and prints a run-book instruction if the
broadcaster lacks `WHITELIST_ADMIN_ROLE` (which it will on production, where the
role is the ops Safe).

---

## 10. Compliance model

### 10.1 Two independent gates

| Gate | Applies to | Enforced by | Bypassable? |
|---|---|---|---|
| **Sanctions screening** | Secondary transfers (`transfer`, `transferFrom`) | `GyldBondToken` → configured on-chain oracle | **No.** Zero role-based exemptions. |
| **AP whitelist** | Primary issuance and redemption beneficiaries | `IssuanceManager` | Only by `WHITELIST_ADMIN_ROLE` adding the address. |

Secondary ERC-20 transfers carry **no whitelist restriction** — anyone not
sanctioned can hold and transfer. Mint and burn skip the sanctions oracle. The two
gates are orthogonal on purpose: the whitelist governs who can create and destroy
supply, the oracle governs who can move it.

### 10.2 Fail-closed, and what that means operationally

The oracle call in `_requireAccess` is an ordinary external call. If the oracle
reverts, is not a contract, runs out of the forwarding gas budget, or returns
malformed data, **the transfer reverts**. If the oracle address is unset, the
transfer reverts `SanctionsListNotSet`. There is no fail-open branch and no
try/catch — as of audit §4.1 that is literally true rather than incidentally
true, the last short-circuit having been removed.

The operational consequences are worth being explicit about:

- **An oracle outage halts all secondary transfers** on every token pointing at it.
  That includes DeFi collateral deposits, withdrawals **and liquidations**.
- **The recovery path is `setSanctionsList(newOracle)`**, gated by
  `DEFAULT_ADMIN_ROLE` — the timelock — so recovery takes 48 h on production. The
  oracle can be *replaced* but never *removed*: `address(0)` is rejected, because a
  token with no oracle is a worse compliance outcome than a frozen token. An unset
  list is not an escape hatch either — it reverts `SanctionsListNotSet`, which is a
  frozen token by another name.
- **A `SanctionsOracleMirror` with a broken `forwardingOracle` is recoverable
  faster**, via `setForwardingOracle(address(0))` from the compliance
  `DEFAULT_ADMIN_ROLE` — but that also drops every address inherited from the
  forwarding oracle, so it should only be done once the local list is seeded.

### 10.3 No admin bypass — structurally

`GyldBondToken` uses `AccessControl`, not `Ownable`, so **there is no `owner` at
all**. `_requireAccess` has zero role-based exemptions and is called identically
for every address. If a holder of `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE`,
`BURNER_ROLE` or `PAUSER_ROLE` is flagged, their secondary transfers revert like
anyone else's.

The one narrow exception is `mint` / `burn`, which skip the oracle because they are
primary issuance rather than secondary transfer and the backend pre-screens the AP.
Note that `whenNotPaused` **is** enforced on both, so pause halts primary issuance
too.

### 10.4 No forced transfer, no recovery — and what follows

A sanctioned address is **frozen in place**. Every transfer to or from it reverts
automatically. There is no `forceTransfer`, no `recoverTokens`, no clawback and no
admin function that can move another holder's balance.

Operationally this means:

- **A sanctioned holder's tokens are permanently immobile** unless and until they
  are de-designated and the mirror is updated. The platform cannot seize them.
- **If legal action requires physical token movement, it must be escalated
  off-chain.** There is no on-chain remedy, by design — the contract surface stays
  minimal and there is no privileged path an attacker could target.
- **`GyldBondToken` has no per-holder freeze mechanism either.** Sanctions writes
  go to the `SanctionsOracleMirror` via the keeper, not through the token. The
  dev-only equivalents (`MockSanctionsList.addToSanctionsList` /
  `removeFromSanctionsList`, owner-gated to the deploying key) exist so the dev
  gateway can simulate a designation.

### 10.5 The known compliance gap: ERC-4626 wrappers

Any third party — or Gyld — can build an ERC-4626 vault over `GyldBondToken` with
no changes to any existing contract. Vault shares are a **separate ERC-20 that
carries none of the token's compliance mechanics**.

```
Vault share token (plain ERC-20)   ← freely tradeable, no sanctions check, no pause
ERC-4626 vault                     ← holds GyldBondToken, issues/burns shares
GyldBondToken                      ← underlying asset, unchanged
```

| Action | Sanctions check fires? |
|---|---|
| `vault.deposit(...)` → `gyldToken.transferFrom(user, vault, amount)` | **Yes** — on user, vault, and the vault as spender |
| `vault.redeem(...)` → `gyldToken.transfer(receiver, amount)` | **Yes** — on vault and receiver |
| Buying or selling **vault shares** on a DEX or OTC | **No** — no `GyldBondToken` transfer occurs |

**Therefore: a sanctioned address can buy vault shares on a secondary market and
hold economic exposure to the bond without ever triggering the oracle.** The check
only fires at deposit and redemption, not on share-to-share transfers. Whether
that is acceptable is a compliance decision, not a technical one. The system
behaves as designed; this is a documented consequence of choosing a plain ERC-20
underlying rather than a permissioned-transfer standard.

Two upstream properties a vault builder must document for their users:

- **Pause:** if `GyldBondToken` is paused, vault deposits and withdrawals freeze
  until unpause. Same behaviour as USDC or any pausable ERC-20.
- **Sanctions:** depositors and redeemers must not be designated. Share trading
  between two non-designated parties is unaffected.

Nothing needs to be built on the Gyld side. A vault builder needs an OZ
`ERC4626.sol` with `asset()` returning the token proxy, plus that documentation.
`NAVFeedForwarder` is already deployed and can price vault-share collateral
independently of the vault's own `totalAssets()`.

---

## 11. Oracle design

### 11.1 Push model, two contracts

```
Kaleidoscope backend (KMS signer)
    │ updateAnswer(navPerToken)        ← ±10% per update, >= 1h apart
    │                                    the ONLY write path; no bypass exists
    ▼
KaleidoscopeNAVFeed          AggregatorV3Interface + latestAnswer()
    │                        immutable, Ownable2Step, 8 decimals
    ▼  (upstream pointer, swappable by the timelock)
NAVFeedForwarder             permanent address given to DeFi protocols
    ▼
Morpho Blue · Euler V2 · Aave V3 · anything Chainlink-compatible
```

**Why two contracts.** Morpho Blue bakes the oracle address into immutable market
parameters at `createMarket()`. Pointing Morpho at the feed directly would make
every oracle upgrade a full market redeployment plus liquidity migration. The
forwarder is the permanent address; one `setUpstreamOracle()` flips the pointer and
all integrations follow.

There is **no pull path**. Nothing on-chain can request a fresh NAV. If the keeper
stops pushing, the feed keeps serving the last answer indefinitely.

### 11.2 The three write-side guards

All three are **unconditional**. `updateAnswer` is the feed's only write path and
there is no privileged address, role or function that can skip any of them — see
[D-19](#171-adopted-and-current).

| Guard | Value | Enforced on |
|---|---|---|
| `MAX_PRICE_DEVIATION_BPS` | 1000 = **10 %** per update | `updateAnswer`, only after the first push |
| `MIN_UPDATE_INTERVAL` | **1 hour** between pushes | `updateAnswer` |
| `answer > 0` | — | `updateAnswer` |

`MAX_STALENESS` is **not** a write-side guard and **not** a circuit breaker. It
gates only the `isFresh()` view. Changing it would change no on-chain guarantee.

Why 10 % is the right width for this asset class:

| Asset class | Typical daily move | Worst single day (recent history) |
|---|---|---|
| T-Bills (3 m – 1 y) | 0.01 % – 0.1 % | ~0.5 % (2022 rate shock) |
| TLT (20 y Treasury ETF) | 0.3 % – 1.5 % | ~4.7 % (COVID crash, March 2020) |
| IG corporate bonds | 0.2 % – 2 % | ~5 % (extreme stress) |

A >10 % single-hour move in any of these would require a US sovereign default or
similar. Legitimate large moves are published as chained updates: 15 % in 2 updates
over 2 hours, 25 % in 3, 40 % in 4. For investment-grade bonds any move >10 % is a
multi-day event unfolding over hours, so a 2–3 hour correction window is
operationally fine.

The rate limit is also a **feature for borrowers**, not only a defence against
malicious updates: gradual price discovery lets Morpho borrowers see each step, add
collateral or repay, and get liquidated only if they choose not to. A single-transaction
15 % crash would liquidate every underwater position simultaneously and worsen
slippage for everyone.

If Gyld ever tokenises high-yield or distressed debt where 10 %+ daily moves do
occur, the right action is a **separate feed contract with a wider constant set at
deploy time** — not a runtime bypass on this one. Wider constants for a
higher-volatility instrument are a design choice; a bypass is attack surface.

### 11.3 Reads never revert on staleness — the deliberate choice

```
Friday 16:00   push NAV = $95.42
Saturday       markets closed, nothing pushed
Sunday 23:00   latestRoundData() → ($95.42, updatedAt = Friday 16:00)
               isFresh() == true          (55 h < 96 h)
               stalenessSeconds() == 198_000
Wednesday      latestRoundData() → ($95.42, updatedAt = Friday 16:00)
               isFresh() == false         (> 96 h)
               stalenessSeconds() == 450_000
               ← still no revert. Ever.
```

Reads always succeed and always carry the true `updatedAt`. **Every consumer is
responsible for its own age check.** This is the Chainlink aggregator contract, and
it is deliberate.

**This is not theoretical.** When a feed stops being pushed, the integrations
diverge exactly along the "does the consumer age-check?" line:

| Consumer | Own staleness check | Behaviour on a stale feed |
|---|---|---|
| Euler V2 | Yes — `PriceOracle_TooStale`, `maxStaleness = 86400` | **Freezes the market. Correct.** |
| Morpho Blue | **None** | Keeps quoting the last pushed answer indefinitely. |
| `GyldAtomicSwap` | Yes — `StaleNav`, bounded `maxNavAgeSecs` | Fails closed on `executeSwap` |

Morpho's behaviour is a real, open exposure. **No change to the feed fixes it.**

#### The tradeoff, stated honestly

| | Feed does not revert (**what ships**) | Feed reverts when stale |
|---|---|---|
| Weekend / holiday | Consumers that age-check freeze; consumers that do not run on the last price | Everything freezes uniformly |
| Risk during a freeze | **Bad debt on non-checking consumers if price gaps at reopen** | Position drift; no liquidations possible |
| Who bears it | **Morpho lenders**, and any integrator that skips the age check | Borrowers who cannot be liquidated → lenders again, via unrecoverable bad debt |
| Liquidations during the gap | Still possible (correctly on Euler; on a stale price on Morpho) | **Impossible — including for positions already unhealthy before the gap** |
| Recovery | Automatic on next push | Automatic on next push |

#### Why not just make reads revert

1. **It breaks the consumers that behave correctly.** Euler age-checks and freezes
   exactly as designed. A reverting feed would hand it a raw revert instead of a
   price plus a timestamp — same freeze, less information, and a failure mode its
   error handling does not model.
2. **It destroys diagnosability.** `updatedAt` is what tells you that a feed died,
   and for how long. A revert carries no timestamp.
3. **It freezes liquidations, unfixably.** This is the decisive one. On Morpho a
   reverting oracle blocks *liquidations* as well as borrows. Positions already
   underwater before the outage cannot be closed, and bad debt grows for the whole
   duration with no operator action available. Failing closed is right for **opening**
   new risk; it is wrong for **unwinding** existing risk.
4. **It is not the Chainlink contract.** Chainlink's own aggregators do not revert on
   stale answers. Integrators and their audit checklists are built around "check
   `updatedAt` yourself". Diverging surprises the careful ones and does not help the
   careless ones.

This is pinned by
`contracts/test/KaleidoscopeNAVFeed.t.sol::test_noStalenessRevertPathExists`, which
warps 1000 days and asserts `latestRoundData()`, `latestAnswer()` and
`getRoundData()` all still succeed. **If a future requirement genuinely needs
reverting reads, deploy a separate wrapper — do not change these semantics under
live integrators.**

Replacement rule for the old, wrong guidance: *do not add a staleness revert to the
read path; do not ship a consumer that reads this feed without its own `updatedAt`
age check.*

### 11.4 Where the staleness defence actually lives

1. **Consumer-side age checks.** `GyldAtomicSwap._checkQuoteBand` reverts
   `StaleNav` when `block.timestamp > updatedAt + maxNavAgeSecs` (default 24 h) and
   also when `updatedAt` is in the future. `maxNavAgeSecs` is bounded above by
   `MAX_NAV_AGE_CEILING = 72 hours` in both `initialize` and `setMaxNavAgeSecs`.
   Euler's `ChainlinkOracle` adapter carries its own `maxStaleness = 86400`.
2. **The forwarder's future-dated probe.** `setUpstreamOracle` and the constructor
   reject an upstream reporting a future `updatedAt`, closing the silent fail-open
   that would otherwise disarm every integrator at once.
3. **Ops — and no contract change substitutes for this.** The NAV keeper must push
   after every market close and alerting must page when it does not. A stalled feed
   is a keeper/alerting failure, not a contract failure: every contract behaves as
   written. `isFresh()` and `stalenessSeconds()` exist to be *polled*;
   they protect nobody if nothing polls them. A missed daily push is visible within
   ~26 h, which is far earlier than the 96 h `MAX_STALENESS` threshold — page on the
   magnitude, not on the bool.

**A missed push is an ops incident requiring alerting, not a self-limiting
condition.** The feed keeps serving the last price forever.

**What is deliberately *not* checked — and the condition under which that expires.**
`_checkQuoteBand` does not test `answeredInRound < roundId`, the classic Chainlink
stale-round guard ([D-18](#171-adopted-and-current), audit §4.10). Chainlink deprecated
the field; modern OCR aggregators return it equal to `roundId`, as does
`KaleidoscopeNAVFeed` by construction, so on any feed we would point at today the guard
is structurally unable to fire and would be dead code on the hot path.

That reasoning is **conditional on the upstream**, not permanent. The only place an
upstream is adopted is `NAVFeedForwarder.setUpstreamOracle`, and the forwarder's own
roadmap (Phase 2 RedStone, Phase 3 Chainlink NAVLink) leads to exactly the third-party
feeds where the assumption could stop holding. Adopting an upstream whose
`answeredInRound` can genuinely lag `roundId` re-opens D-18 and requires a contract
change — `setUpstreamOracle` cannot detect this and does not try. **Re-check D-18 as
part of any upstream migration**, before the timelock proposal, not after.

### 11.5 Correcting a wrong NAV — the incident procedure

A wrong answer is on the feed. There is no bypass and there will not be one
([D-19](#171-adopted-and-current)). The procedure is:

1. **`pause()` the bond token.** `PAUSER_ROLE`, held by the ops multisig, instant,
   **no timelock, no admin**. This freezes every transfer of the series, which per
   [§6.3](#63-what-a-single-key-compromise-buys) also freezes DeFi liquidations —
   nobody is liquidated against the wrong price while it is being walked back.
2. **Chain `updateAnswer` back to the true NAV.** One call per hour, each at most
   10 % from the *then*-current stored answer.
3. **`unpause()`** once the feed reads correctly. The token's pause is **symmetric**
   ([§5.1 › Pause semantics](#pause-semantics)) — the same `PAUSER_ROLE` resumes, so
   step 3 does not wait on governance. (The *swap's* pause is asymmetric; this
   procedure does not use it.)

**Why chaining always terminates, and fast.** The deviation band is relative to the
**last stored** price, and `last` advances with each accepted push, so the reachable
set compounds. Concretely: NAV was `9_500_000_000` ($95.00), a fat-finger pushed
`8_560_000_000` ($85.60) — inside the band, so it was accepted. Recovering needs
+10.98 %, more than one step allows. Two steps do it:

```
push 9_416_000_000   ← exactly +10.000 % of 8_560_000_000; the guard is `>`,
                       so the boundary is INCLUSIVE and this is accepted
wait 1 hour
push 9_500_000_000   ← +0.89 % of 9_416_000_000
```

Two calls, two hours. This generalises: any answer that *passed* the band is within
10 % of the price it displaced, so the round trip is at most
`ln(1/0.9) = 0.1054` of log-distance against a per-step reach of
`ln(1.1) = 0.0953` — **n = 2 for every in-band fat-finger, without exception.** A
genuine large market move needs more steps (15 % in 2, 25 % in 3, 40 % in 4) but the
same mechanism.

**The honest cost.** `pause()` is a blunt instrument. It halts **all** transfers for
**all** holders — not just liquidations — for the couple of hours the walk-back
takes. Secondary trading, redemptions and atomic swaps stop with it. That is a real
cost, and it is the cost this design deliberately accepts in exchange for the feed
having no unbounded instant-price primitive at all. Pausing also adds **no new
privilege**: `PAUSER_ROLE` already exists for exactly this class of incident.

---

## 12. Storage, upgradeability, ERC-7201

### 12.1 Namespaced storage

The three upgradeable contracts use ERC-7201 namespaced storage: all state lives at
a fixed, namespace-derived base slot, so a new implementation can add fields without
shifting existing ones. This eliminates the main risk of upgradeable tokens.

| Contract | Namespace | Base slot |
|---|---|---|
| `GyldBondToken` | `gyld.GyldBondToken` | `0x0fe35ba304a016e79d78a184eb899c1e21310138e0bfe9a54648a2dfe0da0d00` |
| `IssuanceManager` | `gyld.IssuanceManager` | `0xc8552dd465c7174389604c2ad1f48bf21d46f65ee8d42bbd0456923afc111000` |
| `GyldAtomicSwap` | `gyld.GyldAtomicSwap` | `0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300` |

Derivation: `keccak256(abi.encode(uint256(keccak256(ns)) - 1)) & ~bytes32(uint256(0xff))`.
All three were **independently recomputed** for this document and match the source
constants exactly.

The swap's layout is additionally pinned by test (invariant I-19):

```
B+0   quoteEpoch (uint64, offset 0) | maxQuoteDeviationBps (uint16, offset 8)
                                    | maxNavAgeSecs (uint32, offset 10)     ← packed
B+1   withdrawalWallet (address)
B+2   usdc (address)
B+3   usedQuoteWords   (mapping)
B+4   seriesList       (address[])
B+5   registeredSeries (mapping)
B+6   navForwarderOf   (mapping)
B+7   allowed          (mapping)
B+8   maxQuoteTtl (uint64)      ← APPEND-ONLY tail, added by finding F-4
```

An upgrade that reorders or resizes any of these fails the test. New fields go at
the tail, never inserted above. `MAX_NAV_AGE_CEILING`, `DEFAULT_MAX_QUOTE_TTL`,
`MIN_DRAW_BPS` and `BPS_DENOMINATOR` are `constant`, so they consume no slot and do
not affect the layout at all.

### 12.2 Which contracts are upgradeable, and why

Upgradeable (UUPS behind `ERC1967Proxy`, `_authorizeUpgrade` gated by
`DEFAULT_ADMIN_ROLE`): `GyldBondToken`, `IssuanceManager`, `GyldAtomicSwap`.

Reasons to keep `GyldBondToken` upgradeable:

1. **Critical bug patches post-issuance.** A fixed-term bond may be live 6–24
   months. A vulnerability found mid-life must be patchable without migrating every
   holder to a new address.
2. **Stable token addresses.** Exchanges, custodians, DeFi protocols and legal
   documentation all reference the address. Migration means re-listing, legal
   amendments and AP re-onboarding — operationally infeasible for a regulated bond.
3. **ERC-7201 makes it storage-safe.** Namespacing is designed exactly for this.
4. **Timelock on upgrades.** `DEFAULT_ADMIN_ROLE` must be a `TimelockController`, so
   any upgrade proposal is visible on-chain for the delay before it can execute.

What it is **not**: an owner backdoor (upgrades go through the timelock, not a hot
key), storage-unsafe, or licence to deploy casually. Upgrades are for security
patches; any logic change must be reviewed and announced via the timelock.

Immutable, deliberately: `TokenFactory`, `KaleidoscopeNAVFeed`, `NAVFeedForwarder`,
`SanctionsOracleMirror`. Their behaviour cannot change under live integrators. The
cost is that additions like `stalenessSeconds()` reach only future deployments.

### 12.3 Rules for anyone touching these contracts

- Never remove `UUPSUpgradeable` from an upgradeable contract.
- Add new fields **inside** the storage struct, at the tail, never outside it and
  never inserted above an existing field.
- Never add a `shares` mapping, a `multiplier` field, a `navPerToken` field or a
  `MULTIPLIER_UPDATER_ROLE` / `UI_MULTIPLIER_ROLE` to `GyldBondToken`.
- Never add an internal blocklist mapping, and never add a role-based carve-out to
  `_requireAccess`.
- Never re-declare a cross-contract interface inside an implementation file. One
  declaration in `contracts/interfaces/`, imported by caller and implementer, and the
  implementer must `is` it — otherwise the compiler checks nothing (D-20).
- Never reintroduce a zero-address short-circuit in `_requireAccess`. An unset
  `sanctionsList` must revert, never skip screening (audit §4.1). Any new writer of
  that slot must reject zero, and must not be the only thing that does.
- Never add **any** bypass of the NAV feed's deviation cap or interval gate —
  owner-callable or separate-key. A separate-key one shipped once and was removed;
  its premise was arithmetically false and its key separation did not hold. See
  [D-19](#171-adopted-and-current) and [§17.3](#173-superseded--recorded-so-it-is-not-re-litigated)
  before proposing it again. Wider constants on a *new* feed contract are the
  supported answer for a higher-volatility instrument.
- Never add a staleness revert to a read path.
- Never add `pendingRedemption` / `deposited` accounting to `IssuanceManager`
  without explicit product and compliance sign-off — it changes the AP-facing UX.
- Never change the AP deposit mechanic from a plain ERC-20 `transfer` to a
  `deposit()` call for the same reason.

---

## 13. Deployment model

### 13.1 The incident that motivated all of it

A production stack was once deployed with `delay = 0`,
`executors[0] = address(0)` and `initialize(deployer, deployer, deployer)`. The
deployer EOA ended up holding **every privileged role**, behind a timelock that
imposed no delay at all. The handover read as done; nothing had actually moved.

Two design defects made it possible:

1. **Denylist chain guards.** Every "mainnet protection" check in the scripts was
   `require(block.chainid != 1, ...)`. Every production L2 — Arbitrum, Optimism,
   Polygon and every L2 that does not exist yet — sails straight through it.
2. **Silent fallbacks.** Privileged addresses fell back to the deployer EOA, and the
   timelock handover was skipped with at most a `console.log` when its env var was
   unset.

A third, related defect: the same deployer + nonce produced **colliding addresses
across chains**. `0x7c1798...70ad` is a `GyldBondToken` on one chain and a
`MockSanctionsList` on Sepolia.

`contracts/script/lib/DeployGuards.sol` (GYL-1135) fixes all three.

### 13.2 `isDevChain()` — an allowlist, not a denylist

```solidity
function isDevChain() internal view returns (bool) {
    return block.chainid == 31337        // Anvil
        || block.chainid == 11155111;    // Ethereum Sepolia
}
```

**Only those two chains** are development chains. Everything else — Arbitrum,
Ethereum mainnet, and every chain that does not exist yet — is production and takes
the strict path. A new chain now **fails closed**.

This is enforced in CI by the `chain-guard` job (`ci/check_chain_guards.py`), a
comment-aware scan of `contracts/script/` for any `block.chainid !=` comparison.
Guards must be allowlists.

### 13.3 The guard surface

| Helper | Behaviour |
|---|---|
| `broadcaster()` | Returns `tx.origin`, not `msg.sender`. Under `forge script` they are identical; under `forge test` `msg.sender` is the calling test contract while `vm.startBroadcast()` executes as the default sender. `tx.origin` is correct in **both**, which is what makes these scripts runnable from a test at all. |
| `requireProdSafe(what)` | Reverts with a named, chain-id-carrying message unless on a dev chain. Used by `DeployMockSanctionsList` and `DeployMockUSDC`. |
| `envAddressRequired(key)` | Reverts if unset, unparseable, or zero. |
| `envAddressProdRequired(key, devFallback)` | Falls back to `devFallback` **only** on a dev chain; on production an unset or zero value reverts. |
| `envUintProdRequired(key, devFallback)` | Same, for uints. |
| `requireProdMinDelay(delay)` | On production, rejects `delay < 48 hours`. `TIMELOCK_DELAY_SECONDS=0` is exactly how the incident happened. |
| `requireNotDeployer(who, deployer, key)` | On production, a privileged address must not be the broadcaster. This is the exact shape of the incident. |
| `requireDistinct(a, b, keyA, keyB)` | On production, two roles that exist to split a quorum must be different addresses — e.g. `SUBSCRIBER_ADDRESS` vs `REDEEMER_ADDRESS`. |
| `requireProdContract(target, label)` | On production, `target.code.length != 0`. Catches a sanctions "oracle" or forwarder owner that is silently a wallet. |
| `requireProdNotMock(target, mockRuntimeCode, label)` | Compares `target.codehash` against `keccak256(type(SomeMock).runtimeCode)` **from the same compilation**, so the expected hash cannot drift from the artefact it protects against. This is what stops a writable `MockSanctionsList` passing as the production `SANCTIONS_LIST` — `requireProdContract` alone only sees `code.length != 0`, which a mock trivially satisfies. It is deliberately not a general "is this a mock" oracle: any third-party writable oracle still passes, so it is a second line of defence behind the mock's own access control and its dev-only deploy guard. |
| `assertRoleHandover(target, role, holder, mustNotHold, label)` | Asserts the intended holder **has** the role and the deployer **does not**. |
| `assertTimelockSane(timelock, deployer)` | On production: `getMinDelay() >= 48 h`, **and** the deployer holds none of `PROPOSER_ROLE`, `CANCELLER_ROLE`, `DEFAULT_ADMIN_ROLE` on the timelock itself. Without that second half a handover can look perfect while the deployer remains sole proposer of a zero-delay timelock — i.e. still unilateral. |
| `saltFor(name)` | `keccak256("gyld.v1" ++ name ++ block.chainid)`. The `chainId` term is what stops the same logical contract landing on the same address on two chains. |
| `predictCreate2(salt, initCodeHash)` | CREATE2 address for the canonical proxy at `0x4e59b44847b379578588920cA78FbF26c0B4956C`. |
| `requireVacant(salt, initCode, name)` / `vacantSalt(name, initCode)` | Pre-flight check that the predicted address is empty, so a dry run names the clash instead of the broadcast reverting mid-deploy. `vacantSalt` combines both so a deployment reads `new Foo{salt: DeployGuards.vacantSalt("Script:Foo", initCode)}(...)` and cannot drift from the address it just pre-checked. |
| `ANVIL_ACCOUNT_1` | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` — its private key is in the Anvil banner, so it must never be granted anything on production. `DeployDevNet` refuses to whitelist it there. |

### 13.4 Post-deploy assertions run in-band

Every hardened script runs its topology assertions **inside** the broadcast, before
`vm.stopBroadcast()`. A mismatch therefore aborts the deployment rather than
leaving a half-configured stack on chain. `DeployAtomicSettlement._assertFinalTopology`
is the fullest example: it checks that `PAUSER_ROLE`, `TREASURER_ROLE`,
`QUOTE_SIGNER_ROLE` and `ALLOWLIST_ADMIN_ROLE` landed where intended, that
`withdrawalWallet` matches, that `DEFAULT_ADMIN_ROLE` actually moved to the
timelock and off the deployer, that the timelock is sane, and — on production only
— that the deployer kept **none** of the four operational roles.

### 13.5 Scripts

| Script | Purpose | Guard status |
|---|---|---|
| `DeployDevNet.s.sol` | Full token stack: timelock, `IssuanceManager` impl + proxy, sanctions oracle (mirror on prod / mock on dev), `TokenFactory`, role wiring, timelock handover, and on dev three demo bond series | **Hardened.** In-band topology assertions; refuses Anvil account[1]; bytecode-compares `SANCTIONS_LIST` against the mock |
| `DeployTimelock.s.sol` | `TimelockController` + factory ownership transfer + `IssuanceManager` `DEFAULT_ADMIN` handover | **Hardened.** `DEFAULT_DELAY = 48 h`; proposers `[multisig]`, executors `[address(0)]` (anyone after the delay), admin `address(0)` (self-administered from birth, no bypass path) |
| `DeployNAVFeed.s.sol` | Standalone feed + forwarder | **Hardened.** `FORWARDER_OWNER` must be a contract on production |
| `DeployAtomicSettlement.s.sol` | Swap impl + proxy, AP whitelist, `registerSeries`, withdrawal wallet, allowlist grants, timelock handover | **Hardened.** Full in-band assertions. Ordering of the `ALLOWLIST_ADMIN_ROLE` grant is load-bearing — it must precede both `setAllowed` and the `DEFAULT_ADMIN` revoke, or recovery needs a 48 h proposal |
| `DeployMockSanctionsList.s.sol` | Dev sanctions stub | **Hardened** — `requireProdSafe` |
| `DeployMockUSDC.s.sol` | Dev USDC | **Hardened** — `requireProdSafe` |
| `DeployAtomicSettlementE2E.s.sol` | Self-contained Anvil fixtures for the Rust e2e run | Bare `require(block.chainid == 31337)` — an allowlist, but not via the library |
| `AtomicSettlementFlow.s.sol` | Repeatable live-Anvil settlement flow | Does not reference `DeployGuards` |

**2 of the 8 broadcasting scripts do not reference `DeployGuards`**:
`AtomicSettlementFlow` and `DeployAtomicSettlementE2E`. Both pin a single chain with
a bare equality `require`, which is an allowlist and therefore not the bug class the
incident came from — but they do not get the env-var,
not-the-deployer, min-delay or post-deploy-assertion coverage. Extending the
refactor to them is tracked in [§18](#18-known-gaps-and-open-decisions).

### 13.6 Per-series deployment sequence

```
1. Deploy SanctionsOracleMirror(admin = complianceSafe, updater = keeperBot,
                                forwardingOracle = vendorOracle or 0)
2. Deploy IssuanceManager impl + ERC1967Proxy
     initialize(deployer, subscriber, redeemer)
3. Deploy GyldBondToken implementation
4. Deploy TokenFactory(bondTokenLogic, sanctionsList, owner_)
5. Grant WHITELIST_ADMIN_ROLE and REGISTRAR_ROLE on IssuanceManager
     REGISTRAR_ROLE → TokenFactory       (kept permanently — see §5.3)
6. Whitelist the AP addresses
7. Deploy TimelockController(delay >= 48h, [governanceSafe], [address(0)], address(0))
8. Hand DEFAULT_ADMIN_ROLE on IssuanceManager to the timelock; revoke the deployer
9. transferOwnership(TokenFactory → timelock); timelock must acceptOwnership()
     (2-step: schedule + execute through the timelock after the delay)
10. Per series, via a timelocked call:
      factory.deployToken(name, symbol, isin, maturity, opsMultisig,
                          issuanceManager, navFeedOwner)
      → GyldBondToken proxy   (CREATE2, deterministic, predictable in advance)
      → KaleidoscopeNAVFeed   (owner = navFeedOwner / KMS signer)
      → NAVFeedForwarder      (owner = factory.owner() = timelock)
      → all roles wired, factory self-revokes on the token, token registered
11. Push the first NAV: navFeed.updateAnswer(price8dp)
12. Point DeFi markets at the FORWARDER address, never at the feed
13. Atomic settlement, if in use:
      deploy GyldAtomicSwap impl + proxy
      IssuanceManager.addToWhitelist(swapProxy)      ← the swap becomes an AP
      swap.registerSeries(token, factory.forwarderOf(token))   per series
      swap.setWithdrawalWallet(treasurySafe)
      grant ALLOWLIST_ADMIN_ROLE, then setAllowed(ap, true) per taker
      hand DEFAULT_ADMIN_ROLE to the timelock, revoke the deployer
```

**Ordering constraints that will bite if violated:**

- The factory must hold `REGISTRAR_ROLE` **before** `deployToken` — the preflight
  reverts `MissingRegistrarRole` rather than wasting three deployments.
- Factory ownership must move to the timelock **before** `deployToken`, because
  `_wireRoles` grants `DEFAULT_ADMIN_ROLE` on each token to `owner()` **as it is at
  that moment**. Deploy first and the deployer EOA becomes the token admin.
- A NAV must be pushed **before** registering a series with the swap or a DeFi
  market — `executeSwap` fails closed on a non-positive or stale NAV, and
  `AaveOracle` rejects a non-positive `latestAnswer()`. (Note: on a fresh feed
  `latestAnswer()` **reverts `NoPriceSet`**; it does not return 0.)
- `ALLOWLIST_ADMIN_ROLE` must be granted before the deployer's `DEFAULT_ADMIN_ROLE`
  is revoked, or granting it later needs a timelock proposal.

---

## 14. Deployed addresses

**This document holds no addresses.** [`DEPLOYMENTS.md`](../DEPLOYMENTS.md) at the
repository root is the authoritative register — every Sepolia and BSC-testnet
address, its source commit, its privileged roles, its explorer-verification state
and its do-not-reuse status, each row checked against the chain with `cast`. This
document is verified against the Solidity; that one is verified against the chain.
Take addresses only from there.

Keeping a second copy here is precisely how the two drifted, and the drift was not
cosmetic. The register flags the Sepolia `MockSanctionsList` as an **ungated
sanctions oracle**: `addToSanctionsList` / `removeFromSanctionsList` are plain
`external` with no owner and no access control, so any address on the internet can
sanction any holder — and because screening is fail-closed
([§10.2](#102-fail-closed-and-what-that-means-operationally)), that is a
permissionless transfer-freeze on every holder of the **four** live series wired to
it, two of which carry supply. The copy that used to sit in this section carried no
such warning. One register, or the warning goes missing from the other.

What belongs here is what the register's rows mean for the design, not the rows:

- **The cross-chain address collision that motivated chain-salted CREATE2.** One
  deployed Sepolia `MockSanctionsList` shares its twenty bytes with a
  `GyldBondToken` on a different chain — same deployer, same nonce, different chain.
  Addresses are not chain-scoped, so an address copied between chains names a
  different contract, and a config that copies one is pointing at a stranger. This is
  the reason the factory salts CREATE2 with the chain id; see
  [§5.3 Address determinism](#address-determinism).

- **Earlier testnet instances are not this source, and are not tracked as such.**
  The Sepolia instances were built from commits that predate the GYL-1134/1135
  hardening, so their behaviour differs from this document in ways that are not
  enumerated here — deliberately. They are demonstrations, not release candidates:
  the deployer EOA holds every role, there is no timelock handover, and the one
  timelock in the register has `minDelay = 0` with an open executor. Nothing is live
  on mainnet. **This document describes current source, which is what any new
  deployment gets.** Deploy fresh; do not reason from a testnet instance, and do not
  upgrade one into service.

- **The atomic path has been exercised end-to-end on a public chain.** On
  2026-07-31 the Sepolia instance was seeded with inventory via `subscribe` and a
  platform-signed BUY quote settled against it, burning its `quoteId`. That is the
  flow in [§9.1](#91-atomic-path--gyldatomicswapexecuteswap), run for real rather
  than only in Foundry.

- **The ERC-8056 evaluation artefacts are orphans, on two chains.** The Sepolia and
  BSC-testnet demo proxies carry the bytecode of the display extension that was
  dropped ([§8.3](#83-erc-8056-was-evaluated-and-dropped)), built from a commit that
  is not on `main` and never will be. Both are marked do-not-reuse in the register.
  Deploy fresh for any new series; never upgrade one of these into service.

---

## 15. DeFi integrations

This section is deliberately short. The Morpho, Euler and Aave *workstreams* are
retired; Aave never got past research ([§17.2](#172-deferred)). What survives here
is only what still constrains a **live contract**: how each protocol consumes the
oracle, and what the forwarder's shape forces on the integrator.

### 15.1 The rule: every protocol points at the forwarder

**Point every protocol at `NAVFeedForwarder`, never at `KaleidoscopeNAVFeed`
directly.** That is the entire reason the forwarder exists: it is the one address
that survives an oracle-provider migration. Every lending integration named below
consumes the forwarder, and an integration wired straight to a feed has to be
re-listed — by the protocol's governance, not by us — the day the feed is replaced.

### 15.2 Oracle shape — and the one wrapper the forwarder's shape forces

`NAVFeedForwarder` implements `AggregatorV3Interface` (8-decimal USD NAV), plus the
older `latestAnswer()` for Aave. What each protocol does with that differs, and it
is the difference that costs integration time:

| Protocol | Consumes the forwarder | Adapter we deploy |
|---|---|---|
| Morpho Blue | Needs `price()` returning **1e36-scaled** output — a different shape | **`MorphoChainlinkOracleV2` wrapper, required** |
| Euler V2 | `ChainlinkOracle` adapter takes `AggregatorV3Interface` directly | None |
| Aave V3 | `AaveOracle.setAssetSources([token], [forwarder])`, standard 8-decimal `latestAnswer()` | None |

The Morpho wrapper is the one genuinely reusable integration fact here, because the
scaling is not obvious and gets silently wrong answers when it is wrong:

```
NAVFeedForwarder (AggregatorV3Interface, 8-decimal USD NAV)
  └─ MorphoChainlinkOracleV2
       ├─ baseFeed1:      NAVFeedForwarder      (bond/USD)
       ├─ baseDecimals:   18                    (bond token decimals)
       ├─ quoteFeed1:     Chainlink USDC/USD
       ├─ quoteDecimals:  6                     (USDC token decimals)
       └─ price() → ~100 × 10^24                (Morpho's 1e36 format)
```

`price = (bond/USD) / (USDC/USD) × 10^(36 + quoteDecimals − baseDecimals)`
`= 100 / 1 × 10^(36 + 6 − 18) = 100 × 10^24`

Easy to get wrong, and each of these is a hard revert or a wrong price rather than a
loud failure:

- `baseVaultConversionSample = 1` — required when no vault is used; `0` reverts
- `quoteVaultConversionSample = 1` — same
- all vault and `feed2` fields = `address(0)`

```bash
cast call $MORPHO_ORACLE "price()(uint256)" --rpc-url $RPC_URL
# expect ~100000000000000000000000000  (100 × 10^24) against a $100 NAV
```

`MorphoChainlinkOracleV2` is **Morpho's published adapter, not a Gyld contract.**
The forwarder stays the stable oracle address; the adapter only reformats it.

### 15.3 Staleness — Euler age-checks, Morpho does not

The feed never reverts on staleness by design, so every consumer owns its own age
check, and they do not all have one. Euler's `ChainlinkOracle` adapter carries
`maxStaleness = 86400` (24 h) and freezes the market correctly when pushes stop;
Morpho Blue has no staleness check at all and keeps quoting the last pushed answer
indefinitely; `AaveOracle` likewise just calls `latestAnswer()`. Morpho's behaviour
is a real, open exposure that **no change to the feed fixes**. The full comparison,
the tradeoff table and the reasoning for not making reads revert are in
[§11.3](#113-reads-never-revert-on-staleness--the-deliberate-choice); where the
defence actually lives is [§11.4](#114-where-the-staleness-defence-actually-lives).

### 15.4 ERC-4626 wrappers

`GyldBondToken` is a standard ERC-20, so any ERC-4626 vault can use it as `asset()`
with **no changes to any Gyld contract**. The mechanics, the compliance consequence,
and the two upstream properties a vault builder must document are in
[§10.5](#105-the-known-compliance-gap-erc-4626-wrappers).

### 15.5 Cross-cutting notes

- **Pause freezes DeFi positions, liquidations included.** When `GyldBondToken` is
  paused, every Morpho and Euler interaction reverts — including liquidations, so an
  undercollateralised position cannot be closed until unpause. The ops multisig must
  weigh that before triggering a pause; it is the same tension as
  [§18](#18-known-gaps-and-open-decisions) gap 10. It is also the tension the NAV
  walk-back procedure ([§11.5](#115-correcting-a-wrong-nav--the-incident-procedure))
  deliberately accepts: freezing liquidations is the point, and freezing everyone
  else's transfers alongside them is the price.
- **Protocol addresses are screened as spenders.** Morpho's and Euler's contract
  addresses go through the sanctions oracle on every collateral deposit and
  withdrawal — as `to`, as `from`, and as the `transferFrom` spender. A protocol
  address that ever appears on the mirrored list stops being usable as a venue for
  the token, with no contract change involved.
- **Market parameters are immutable once set.** On Morpho, `createMarket()` fixes
  oracle, IRM and LLTV forever; a new market is the only way to change any of them.
  Euler's IRM is likewise immutable after deployment. Getting the oracle wrapper
  wrong is therefore not a configuration mistake you correct — it is a market you
  abandon.

---

## 16. Verification surface

### 16.1 Test suites

`forge test` — **524 tests, 20 suites, 0 failures**, at full `foundry.toml`
intensity (fuzz `runs = 10000`; invariant `runs = 1000, depth = 50`,
`fail_on_revert = true`).

| Suite | Tests | Covers |
|---|---|---|
| `GyldAtomicSwapTest` | 85 | Happy-path BUY/REDEEM via permit and plain allowance; expiry; epoch; replay; wrong signer; tampered message; wrong taker; allowlist; pause asymmetry; paused-bond-token evacuation boundary; permit front-run; withdrawal-wallet family; zero amounts |
| `KaleidoscopeNAVFeedTest` | 58 | `updateAnswer`, deviation cap, interval gate, round IDs, `Ownable2Step`, non-renounceable ownership, chained-update recovery from an in-band fat-finger, **`test_noStalenessRevertPathExists`** |
| `TokenFactoryTest` | 62 | Deploy, role wiring, mint, burn, pause, sanctions compliance, CREATE2 prediction, `REGISTRAR_ROLE` preflight, duplicate-ISIN rejection |
| `IssuanceManagerTest` | 51 | Subscribe, redeem, whitelist (single + batch), registry, `SUBSCRIBER`/`REDEEMER` role isolation, UUPS, renounce guard |
| `SanctionsOracleMirrorTest` | 50 | Constructor, add/remove, events, access control, forwarding-oracle probe and gas cap, fuzz round-trip |
| `GyldAtomicSwapSpecTest` | 48 | The numbered invariant / finding catalogue below |
| `GyldBondTokenTest` | 46 | Core token functions; ERC-1643 document set/remove and `DOCUMENT_ROLE` gating; fail-closed screening on an unset sanctions list |
| `NAVFeedForwarderTest` | 39 | Delegation, upstream swap, probe matrix, future-dated rejection, access control |
| `TimelockTest` | 15 | 48 h delay enforcement, cancellation, `IssuanceManager` admin wiring |
| `GyldBondTokenUnitTest` | 15 | Sanctions transfer paths, `setSanctionsList`, pause |
| `MockSanctionsListTest` | 14 | Dev-stub behaviour, owner-only writes |
| `GyldBondTokenFuzzTest` | 11 | Mint/burn round-trip, transfer conservation, sanctions, pause, NAV model |
| `AtomicSettlementDeployTest` | 6 | `DeployAtomicSettlement` end-to-end incl. topology assertions, and `StaleNav` against the real NAV-feed wiring |
| `SwapFuzzTest` | 5 | Fair-price rounding, single-use replay, draw range |
| `GyldBondTokenInvariantsTest` | 5 | `totalSupply == Σ balances`; per-actor balance bounds |
| `DeployMockSanctionsListTest` | 4 | Dev-only guard |
| `DeployMockUSDCTest` | 4 | Dev-only guard, Anvil pre-mint |
| `DeployGuardsTest` | 3 | Allowlist classification, prod-required env vars |
| `GyldAtomicSwapInvariantsTest` | 2 | Stateful: bond `totalSupply` never changes across BUY/REDEEM (**never-mints**); quote single-use |
| `DeployScriptsTest` | 1 | Script revert assertions |

There is also a **Halmos symbolic-verification suite**
(`contracts/test/GyldAtomicSwap.halmos.t.sol`) covering I-1, I-2, I-3, I-10 and
I-11. Its functions use the `check_` prefix so `forge test` ignores them (it only
runs `test*`) while Halmos runs them.

### 16.2 The `GyldAtomicSwap` invariant catalogue

Test names reference these identifiers. The catalogue is reconstructed from the
test suite, so every reference resolves to something checkable.

| ID | Invariant | Where pinned |
|---|---|---|
| **I-1** | Inventory solvency — for any legal draw the pushed-out amount is covered by pre-existing inventory, and the swap's balance decreases by exactly that amount | `testFuzz_executeSwap_neverPaysOutMoreThanInventory`; Halmos |
| **I-2** | Replay resistance — a consumed `quoteId` can never execute again | `test_executeSwap_replayedQuoteId_reverts`; Halmos |
| **I-2a** | Bitmap non-aliasing — consuming an id must not mark neighbours, and must not alias across the 256-id word boundary (255 → word 0 bit 255; 256 → word 1 bit 0) | `test_bitmap_wordBoundary_noAliasing` |
| **I-3** | Draw range — the 1 % dust floor is **inclusive**: `requestedAmountIn == minAllowed` succeeds | `test_executeSwap_exactlyMinDrawFloor_succeeds`; Halmos |
| **I-4** | `quoteEpoch` is strictly monotonic and moves only by +1 per bump | `test_bumpQuoteEpoch_strictlyMonotonic` |
| **I-5** | An epoch bump does **not** free `quoteId`s — the usage bitmap is not epoch-scoped, so a consumed id stays consumed forever (finding F-3: the quote service must never reuse an id, even after a mass invalidation) | `test_consumedQuoteId_survivesEpochBump` |
| **I-8** | `DEFAULT_ADMIN_ROLE` is non-renounceable for **every** holder, not just the first | `test_renounceRole_defaultAdmin_revertsForEveryHolder` |
| **I-9** | Atomic consumption — a swap that reverts *later* (e.g. at the inventory check) leaves the `quoteId` unconsumed and re-executable | `test_failedSwap_doesNotConsumeQuoteId` |
| **I-10** | Conservation / never-mints — bond `totalSupply` never changes across any BUY/REDEEM sequence; only pre-minted inventory moves | `invariant_bond_totalSupply_never_changes`; `testFuzz_executeSwap_redeem_conservesBothPools`; Halmos |
| **I-11** | Price fidelity — `amountOut == requestedAmountIn * price / 1e18`, rounded down | `testFuzz_..._amountOut_matchesPriceRoundedDown`; Halmos |
| **I-12** | Signature authority is evaluated at **execution** time — revoking `QUOTE_SIGNER_ROLE` invalidates every in-flight quote from that key | `test_executeSwap_revokedSigner_reverts` |
| **I-13** | Cross-chain / cross-proxy replay resistance — the same message bytes hash differently on a different `chainId`, even at an identical proxy address | `test_hashSwapMessage_bindsChainId` |
| **I-14** | Exactly one bond leg — `tokenIn == tokenOut` can never classify as a swap (`buy == redeem` → `NotOneBondLeg`). This is what makes the post-pull-in inventory measurement sound | `test_executeSwap_sameTokenBothLegs_reverts` |
| **I-15** | NAV fail-closed — a `<= 0` answer reverts `InvalidNav`; a stale answer reverts `StaleNav`; the guard is structurally bounded by `MAX_NAV_AGE_CEILING` | `test_executeSwap_negativeNav_reverts` and the GYL-1135 ceiling tests |
| **I-16** | Withdrawal target — `withdraw` can only ever send to the admin-fixed `withdrawalWallet` | `test_withdraw_*` family |
| **I-17** | Reentrancy exclusion covers `withdraw` too — it shares the guard with `executeSwap`, so a malicious inventory token cannot use the withdrawal transfer hook to enter | `test_withdraw_cannotReenterExecuteSwap` |
| **I-18** | Pause asymmetry — `PAUSER_ROLE` halts, only `DEFAULT_ADMIN_ROLE` resumes | `test_pause_asymmetric_onlyAdminUnpauses` |
| **I-19** | ERC-7201 storage location and packing — base slot matches the derivation; `quoteEpoch`/`maxQuoteDeviationBps`/`maxNavAgeSecs` pack into B+0 at offsets 0/8/10; `withdrawalWallet` and `usdc` at B+1/B+2; `maxQuoteTtl` at the append-only tail B+8 | `test_storageLayout_erc7201SlotAndPacking` |
| **I-20** | Upgrade authority — `upgradeToAndCall` is admin-only | `test_upgradeToAndCall_onlyAdmin` |
| **I-21** | Series deregistration then re-registration restores tradability | `test_deregisterSeries_thenReregister_restoresTradability` |
| **I-22** | Permit is never load-bearing for authorization — a `tokenIn` with no `permit()` at all still settles via a plain approval | `test_executeSwap_permitOnTokenWithoutPermit_doesNotBrick` |
| **I-23** | Quote expiry is TTL-bounded: `block.timestamp <= expiry <= block.timestamp + maxQuoteTtl`, upper edge **inclusive** | `test_executeSwap_quoteExpiryTtlBound_inclusiveEdge` |
| **I-24** | `seriesList` is a duplicate-free mirror of `registeredSeries`, and deregister swap-and-pops (last element moves into the removed slot) | **Not covered.** `seriesList` is not externally observable and is read by no other contract logic, so the swap-and-pop loop (`registerSeries`/`deregisterSeries`) has no external assertion point. Pre-existing gap on `main`. |

Remediated findings:

| ID | Finding | Remediation |
|---|---|---|
| **F-1** (was O-4) | The `/1e20` decimal ladder was an operational convention only | `initialize` probes USDC `decimals() == 6`; `registerSeries` probes forwarder `== 8` and bond token `== 18` |
| **F-3** | The usage bitmap is not epoch-scoped, so id reuse after a bump would silently break | Documented invariant I-5 + test; the quote service must use one monotonic counter |
| **F-4** | A signer could issue long-dated quotes, exercisable as a free option until noticed | `maxQuoteTtl` (fallback **90 s**, ceiling 10 min) + `QuoteExpiryTooFar`; `setMaxQuoteTtl` for adjustment. Read via `_effectiveMaxQuoteTtl` so an unset slot means "use the default", **not** "reject everything" — see the upgrade-safety tests |
| **F-6** | A future-dated `updatedAt` satisfies `now > updatedAt + maxAge` forever | Explicit `updatedAt > block.timestamp` → `StaleNav`; plus the forwarder's configuration-time probe |
| **F-7** | A sole `PAUSER`/`TREASURER` holder could renounce, removing the halt and the paused-state evacuation path | **Rejected, not implemented.** The guard was inert (the admin administers both roles and re-grants in one tx; `renounceRole` is self-only; both roles are M-of-N in production) and mildly harmful — it blocked a holder with a known-compromised key from shedding it immediately. See §Non-renounceable roles. |

### 16.3 Constants independently verified for this document

| Constant | Verified value |
|---|---|
| `GyldBondToken` ERC-7201 slot | `0x0fe35ba304a016e79d78a184eb899c1e21310138e0bfe9a54648a2dfe0da0d00` ✓ |
| `IssuanceManager` ERC-7201 slot | `0xc8552dd465c7174389604c2ad1f48bf21d46f65ee8d42bbd0456923afc111000` ✓ |
| `GyldAtomicSwap` ERC-7201 slot | `0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300` ✓ |
| `SWAP_MESSAGE_TYPEHASH` | `0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b` ✓ |

`GyldAtomicSwapSpecTest` additionally pins normative EIP-712 vectors — domain
separator `0x304880d5...`, v1 and v2 struct hashes and digests — reproducible from
the contract's own `hashSwapMessage`.

### 16.4 Build hygiene

`forge build --force` is warning-*bearing* but not warning-*free*: two cosmetic
state-mutability warnings in test code, ~45 `forge lint` notes, and a tree that is
not `forge fmt`-clean. [`ci.md`](ci.md) is authoritative for the file:line detail
and for why none of it is enforced in CI yet — it is deliberately not duplicated
here.

### 16.5 CI

Two jobs, described in full in [`ci.md`](ci.md): `test` (full-intensity
`forge build` + `forge test`) and `chain-guard` (`ci/check_chain_guards.py`, a
comment-aware scan that fails on **(a)** any denylist `block.chainid !=`
comparison and **(b)** any script under `contracts/script/` carrying no chain
guard at all). The workflow is
structurally unable to broadcast — no secrets, no RPC URL, no key material, no fork
cheatcodes, `GITHUB_TOKEN` restricted to `contents: read`.

---

## 17. Decision record

### 17.1 Adopted and current

| # | Decision | Rationale summary |
|---|---|---|
| D-1 | **Plain ERC-20; no shares, no multiplier, no rebasing** | Off-chain settlement always knows the exact amount; no dust residual; smaller audit surface; NAV belongs in the oracle. [§8](#8-value-accrual--nav-not-balances) |
| D-2 | **`GyldBondToken` and `IssuanceManager` are UUPS-upgradeable** | Fixed-term bonds live 6–24 months and need patchability without migrating holders; stable addresses are a hard external requirement; ERC-7201 makes it storage-safe; the timelock makes it visible. [§12.2](#122-which-contracts-are-upgradeable-and-why) |
| D-3 | **No internal blocklist; sanctions delegated to an on-chain oracle** | Single dataset (OFAC/SDN/UN/EU), no dual-list governance, regulatory clarity, minimal contract surface. [§10](#10-compliance-model) |
| D-4 | **Spender is screened on `transferFrom`** | Without it a sanctioned address could obtain an allowance from a clean wallet and drain it freely, bypassing the whole system through the approval mechanism. |
| D-5 | **No forced transfer, no recovery function** | Freeze-in-place is sufficient for Phase 1; a privileged token-movement path is attack surface. Legal escalation is off-chain. [§10.4](#104-no-forced-transfer-no-recovery--and-what-follows) |
| D-6 | **NAV feed reads never revert on staleness** | Reverting breaks correct consumers, destroys `updatedAt` diagnosability, and unfixably freezes Morpho *liquidations*. Chainlink semantics. Re-affirmed under GYL-1135 and pinned by test. [§11.3](#113-reads-never-revert-on-staleness--the-deliberate-choice) |
| D-8 | **Two-contract oracle (feed + forwarder)** | Morpho bakes the oracle address into immutable market params; the forwarder is the permanent address so provider migration needs no market redeployment. [§11.1](#111-push-model-two-contracts) |
| D-9 | **`SanctionsOracleMirror` is the production oracle on every chain, mainnet included** (GYL-1051) | Reverses its original "deployment gap adapter" framing. A vendor oracle is consumed *through* the mirror's optional forwarding path, not instead of it. |
| D-10 | **Pooled `IssuanceManager` balance; no per-AP on-chain ledger** | A `deposit()` function would break the plain-ERC-20-transfer UX institutional APs and custodians rely on. Per-AP accounting lives in the backend ledger. [§9.2](#92-deferred-path--issuancemanager) |
| D-11 | **`GyldAtomicSwap` is self-custodial; the vault was removed** (GYL-548) | Fewer contracts, no LP share math, no receivable accounting, no first-depositor inflation surface. The price is direct balance exposure to its own admin. [§7](#7-custody-model-and-loss-ceilings) |
| D-12 | **Capped-allowance quote, single draw** | Lets the desk sign "up to $1,000 at this price" and the taker choose the size in one call, while keeping the quote strictly single-use. Multi-draw was explicitly deferred. [§5.7](#57-gyldatomicswap) |
| D-13 | **`ALLOWLIST_ADMIN_ROLE` split off `DEFAULT_ADMIN_ROLE`** (GYL-1050) | Per-taker allowlisting must stay a same-day operational action after the timelock handover. It grants access to swap, never to funds or upgrades. |
| D-14 | **Asymmetric pause on the swap; symmetric on the token** | The swap runs off a hot signing key, so re-arming it is deliberately slow. |
| D-15 | **Chain-allowlist deploy guards, fail-closed** (GYL-1135) | Denylist guards let every L2 through; that is how a zero-delay timelock and a bare-EOA admin reached a production chain. [§13](#13-deployment-model) |
| D-16 | **`maxNavAgeSecs` structurally ceilinged at 72 h** (GYL-1135) | It is the only staleness defence in the swap path, so an admin must not be able to widen it into a no-op. 72 h matches Euler's `MAX_STALENESS_UPPER_BOUND`. |
| D-18 | **`answeredInRound` is deliberately not checked in `_checkQuoteBand`** (audit §4.10) | Chainlink **deprecated** the field — modern OCR aggregators return it equal to `roundId`, as does `KaleidoscopeNAVFeed` by construction, so the classic `answeredInRound < roundId` guard is structurally unable to fire on any feed we would point at. Adding it would be dead code on the hot path. Staleness is enforced on `updatedAt` against the 72 h-ceilinged `maxNavAgeSecs` plus a future-dating guard (F-6). Revisit only if an upstream is adopted whose `answeredInRound` can genuinely lag `roundId`. [§5.7](#57-gyldatomicswap) |
| D-17 | **ERC-8056 dropped on EVM** (GYL-1201) | Splits standard used as a NAV mirror; no EVM wallet implements it; observed display divergence on our own deployment; nobody in our category uses it. Standing record: [`decisions/erc8056-dropped-on-evm.md`](decisions/erc8056-dropped-on-evm.md). [§8.3](#83-erc-8056-was-evaluated-and-dropped) |
| D-21 | **`TokenFactory` holds `REGISTRAR_ROLE` on the `IssuanceManager` permanently, and that is required** (audit §18 item 1) | `deployToken` calls `registerToken` on *every* deployment, not just the first, so revoking the role would brick every subsequent deploy. Token-level roles are a different case and *are* shed — `_wireRoles` self-revokes `PAUSER_ROLE` and `DEFAULT_ADMIN_ROLE`, which are needed only while that one token is wired. What bounds the retained role: the factory is immutable (no proxy, no upgrade path) and contains no call to `deregisterToken`, the only other function it gates; its one `registerToken` call site targets a token CREATE2-deployed three lines earlier in the same transaction. The `IssuanceManager` admin (the timelock) can revoke it at any time, at the cost of disabling further deploys. Both halves pinned by `test_deployToken_factoryRetainsRegistrarRole_andNeedsIt` and `test_deployToken_factoryShedsAllTokenRoles`. |
| D-20 | **Every cross-contract interface has exactly one declaration, in `contracts/interfaces/`, and implementers declare it** (audit §4.8) | Interfaces used to be restated per file — `ISanctionsList` twice, and three overlapping oracle shapes. Solidity types are per-declaration, so identical copies are unrelated types the compiler cannot cross-check, and implementers that merely *happened* to expose the right functions declared nothing. Renaming `SanctionsOracleMirror.isSanctioned` compiled cleanly across every production contract; only a test caught it. One shared declaration plus `is` on the implementer turns that into a build failure in the contract itself. |
| D-19 | **No privileged bypass on the NAV write guards** — `emergencyUpdateAnswer` and `setEmergencyUpdater` removed | The premise for the bypass (D-7, now [superseded](#173-superseded--recorded-so-it-is-not-re-litigated)) was **arithmetically false**: the deviation band is relative to the *last stored* price, and `last` moves with each push, so chaining reaches **any** in-band fat-finger in **n = 2** calls. The bypass therefore bought ~2 hours of latency and cost an unbounded instant-price primitive that a compromised KMS key could reach in one extra transaction. The replacement procedure — `pause()` the token, chain `updateAnswer`, `unpause()` — adds no new privilege. [§11.5](#115-correcting-a-wrong-nav--the-incident-procedure) |

### 17.2 Deferred

| Decision | Status | Revisit when |
|---|---|---|
| **ERC-2771 / gasless meta-transactions** | Not implemented. Phase-1 users are institutional APs who hold ETH and submit their own transactions. Adding it means operating relay infrastructure — who submits, who pays gas, how failures are handled, how the relay audit log is produced — for a problem that does not exist yet. | **Retail access.** Then: deploy a `MinimalForwarder`, upgrade the token via UUPS to inherit `ERC2771ContextUpgradeable` and override `_msgSender()`/`_msgData()` (~15 lines; ERC-7201 makes the upgrade safe), and deploy or integrate a relay service. The operational commitment is the real work. Additive and invisible to DeFi: the `_msgSender()` override only activates when `msg.sender` is the trusted forwarder. **Never** build a bespoke `delegatedTransfer()`; use the standard. The forwarder address must be set at deploy time and locked — a compromised or wrong forwarder can spoof any `_msgSender()`, admin addresses included. |
| **On-chain rate limiter in `executeSwap`** | V1.1 candidate, following Ondo's `InstantMintTimeBasedRateLimiter`. If a minimum size is added alongside a cap, keep `min < cap remainder` — that was Ondo's Medium finding. | Before meaningful notional flows through the swap. |
| **Multi-draw quotes (remaining-balance tracking)** | Explicitly out of scope for the capped-allowance design. Needs `filled[quoteId] += requestedAmountIn` instead of one bitmap bit, which swaps 256-quotes-per-slot for a per-quote counter, reopens "which fill's NAV and expiry apply to fill #2", and needs its own reentrancy analysis. | Only if the AP/LP flow genuinely needs draw-over-time rather than single-shot-capped sizing. Confirm which before estimating. |
| **Multi-source NAV aggregator** (Phase 3) | Independent data sources each submit; median forwarded when M-of-N agree. | At scale. Phases 1→2 (KMS → Fordefi MPC) need **no contract change at all** — `transferOwnership` + `acceptOwnership`; from the feed's perspective it is still one address calling `updateAnswer`, with the MPC threshold happening invisibly at the signing layer. `renounceOwnership()` reverts (GLD-165) — retire a feed by transferring it to a custodian you still control, never by renouncing. |
| **Solana** | No Solana contracts in this repo. Token standard, custodian and compliance tooling are all EVM-native for v1. | After the EVM flow is battle-tested and a Solana custodian or issuer relationship exists. |
| **Aave V3 listing** | Researched, not started; the research write-up was retired with the rest of the DeFi-listing workstream in this pass. Listing is a governance and business-development process, not a deployment script — permissioned, weeks-long, and with no bypass. The technical side is one call, `AaveOracle.setAssetSources([token], [forwarder])`, with no wrapper ([§15.2](#152-oracle-shape--and-the-one-wrapper-the-forwarders-shape-forces)). | A fork test (`AaveV3Integration.t.sol`) is written and green, and the staleness question in [§18](#18-known-gaps-and-open-decisions) gaps 5 and 7 has an answer. |
| **ERC-7540 queued-exit vault** | Was the V2 shape for LP exits under the removed vault design. Moot while the swap is self-custodial with no LPs. | Only if LP-funded liquidity returns. |

### 17.3 Superseded — recorded so it is not re-litigated

| Was | Now | Why it changed |
|---|---|---|
| `MAX_STALENESS = 36 hours`, reads revert when exceeded | **96 hours, advisory only**; no read has ever reverted | Never implemented. Both halves were false against the deployed bytecode from the day it was written. The reverting design was then re-rejected on its merits (D-6). |
| **D-7:** `emergencyUpdateAnswer(int256)` ships, gated on a separate `emergencyUpdater` key, bypassing **both** the interval and deviation caps | **The entire path is deleted.** `updateAnswer` is the feed's only write function and all three of its guards are unconditional (D-19) | **D-7's premise was arithmetically wrong, and that is the reason — not a change of appetite.** It claimed a fat-finger *within* the 10 % band strands the correct price out of reach because chained hourly updates "cannot fix that at all". False: the band is measured against the **last stored** price, and `last` advances with each accepted push, so the reachable set compounds. Worked example, pinned by a passing test — wrong `8_560_000_000`, correct `9_500_000_000`: push `9_416_000_000` (exactly +10 %, and the guard is `>`, so the boundary is **inclusive**), wait 1 h, push `9_500_000_000`. Two calls, two hours. This is general: any answer that passed the band sits within 10 % of what it displaced, so the return trip is at most `ln(1/0.9) = 0.1054` of log-distance against a per-step reach of `ln(1.1) = 0.0953` — **n = 2 for every in-band error**. So the bypass bought roughly two hours of latency. What it cost: an **unbounded, instant, rate-limit-free** price primitive. And the key separation that was supposed to make that safe never held. The feed's owner is the **KMS signer, not the timelock** (`TokenFactory.deployToken` sets the feed owner to `navFeedOwner`; only the forwarder gets the timelock), and `setEmergencyUpdater` was `onlyOwner` with a single check, `newUpdater != owner()`. A compromised KMS key simply appointed a second address it also controlled — one extra transaction — and then had the bypass. The setter's own NatSpec asserted "a compromised KMS key must not be able to call `emergencyUpdateAnswer`"; that goal was never achieved. Live exposure was nonetheless **zero**: `_emergencyUpdater` was `address(0)` in every deploy script and no script ever called `setEmergencyUpdater`. **Do not re-propose this, in owner-callable or separate-key form.** The correct response to a bad NAV is [§11.5](#115-correcting-a-wrong-nav--the-incident-procedure). |
| ERC-8056 display multiplier permitted as a narrow display-only carve-out (GYL-956) | Removed; the prohibition on any multiplier is absolute again (GYL-1201) | See D-17. |
| `SanctionsOracleMirror` is a "deployment gap adapter" for chains where Chainalysis never deployed, to be retired when a vendor oracle appears | It is the primary oracle **everywhere**, mainnet included, and is not retired (GYL-1051) | The founding premise inverted. Its access-control design, keeper model and not-a-blacklist argument all carry over unchanged; only the which-chain-uses-which-oracle question reversed. |
| `GyldSettlementVault` + deferred DvP escrow; v1 `SwapMessage` (`amountIn`/`amountOut`); EIP-712 domain version `"1"` | Self-custodial swap; capped-allowance `SwapMessage` (`maxAmountIn`/`price`); domain version `"2"` | GYL-548 removed the vault; GYL-1201-era work landed the capped-allowance wire format. **Do not implement against the v1 shape.** |
| `ReentrancyGuardUpgradeable` inherited by `GyldBondToken` | Removed | Inherited but never used — a leftover from the `recoverTokens` removal. No function needs it; CEI is correct on the transfer path, mint/burn have no external calls, and OZ v5 removed `_afterTokenTransfer`. Adding `nonReentrant` to `transfer` would also break composability with protocols that call it inside their own `nonReentrant` flows. Resolved audit pre-finding. |
| Fireblocks ERC20F / DenyList contracts under `contracts/erc20f/` | **The directory does not exist in this tree.** All tokens use `GyldBondToken` + the platform sanctions oracle | GYL-250. |
| Guard `navFeedOf[predicted] == address(0)` against duplicate ISINs | `mapping(bytes32 => bool) _deployedIsins` keyed on `_bondSalt(isin)` | The old guard only caught exact-duplicate calls; a same-ISIN call with a different name bypassed it and would deploy a second token for one real bond (GYL-300). |
| `TokenFactory` `DEFAULT_ADMIN_ROLE` needs a manual cleanup step | `_wireRoles` self-revokes it (and `PAUSER_ROLE`) on every token | GYL-262. Note this does **not** extend to `REGISTRAR_ROLE` on the `IssuanceManager`, which the factory keeps permanently. |

### 17.4 Prior-art lineage

The design choices in `GyldAtomicSwap` trace to specific, verified sources. Links
were confirmed resolving 2026-06-11; the Backed deployment was re-verified
2026-07-31.

| Design choice | Source |
|---|---|
| `executeSwap(SwapMessage, signature, permit)` shape: signed quote + single-use `quoteId` + two-leg transfer + optional EIP-2612 permit | Backed Finance `AtomicSwapUpgradeable` — verified on-chain source, impls `0x202BDae6EA5CB576c916cF2D2A83d5a21ea2624D` and `0x3AdF98F5eF70E08af964f33D109Ac032b3d31b24` behind proxy `0x837E5a6E45F5F16C7306B591994DBD2AdF09A932`. Their contract is a **pure conduit holding no balance** — the only transfer site is `safeTransferFrom(from, to, amount)`, `address(this)` appears solely as the permit spender, and the proxy holds 0 USDC / 0 ETH. Both legs settle against the deployer EOA, which is also `owner()`. Allowances are asymmetric: issuer→proxy bounded (~194,120 USDC), taker→proxy `uint256.max`. We keep taker binding, epoch mass-cancel and the NAV band as real differentiators; we hold inventory in the swap itself, which is neither their design nor our original one. |
| Mandatory `taker` binding; quote-struct field choices | 0x v4 `OtcOrdersFeature` / `NativeOrdersFeature` |
| Pool-held inventory filled against signed quotes; **every approval target must be small, verified, and in audit scope** | Hashflow Router/Pool + CertiK's post-mortem of the June-2023 $640 K exploit (arbitrary `transferFrom` in an unaudited peripheral holding approvals) |
| BitInvalidator bitmap (256 ids/slot) + epoch mass-cancel | 1inch `BitInvalidatorLib`, `SeriesEpochManager` |
| Decimal-scaling layer; asymmetric pause split; rate-limit caps (off-chain V1, on-chain V1.1 candidate) | Ondo OUSG `ousgInstantManager` + `InstantMintTimeBasedRateLimiter`; Code4rena report (H-01: a buffer-minimum revert broke redemptions — which is why no such revert exists here) |
| Instant-vs-queued redemption split; NAV-feed-driven valuation | OpenEden TBILL `OpenEdenVaultV5` |
| Singleton + UUPS + ERC-7201 + timelock admin + non-renounceable admin + probe-before-store; tokens-to-`IssuanceManager` as a burn commitment | House style: `IssuanceManager`, `GyldBondToken`, `NAVFeedForwarder`, and the existing two-step redemption |
| Repricing / NAV-in-oracle value display | USYC, Spiko, Midas, OpenEden, Superstate — see [§8.4](#84-peer-comparison) |

**Taker binding is a real differentiator, and the evidence for that is empirical.**
Backed Finance's production swap — the direct structural twin of this design — does
**not** enforce `msg.sender == taker`, and we deliberately do. Their Team Omega
audit (finding A1, medium) recommended exactly `msg.sender ==
incomingTransfer.from` and the report marks it "[resolved]", but the live proxy
`0x837E5a6E45F5F16C7306B591994DBD2AdF09A932` does not implement it: its
`executeSwap` checks expiry, quote reuse, signature and an address allowlist, and
never reads `msg.sender`. Proved by replaying a real signed swap from `0x…dEaD` —
not a counterparty, not allowlisted — at the prior block: it succeeded. **Do not
trust an audit's "[resolved]" label as evidence about a deployment.**

---

## 18. Known gaps and open decisions

Carried forward honestly. Ordered by severity.

### High

1. ~~**`TokenFactory` holds `REGISTRAR_ROLE` on the `IssuanceManager` permanently.**~~
   **Resolved — it was a documentation defect, not a privilege defect.** The role is
   held for the life of the stack and *must* be: `deployToken` calls `registerToken`
   on every deployment, so revoking it bricks every subsequent deploy. The finding was
   that `TokenFactory`'s own header claimed the factory "holds no permanent permissions
   after deployment" — the last place still asserting the opposite, after README and
   this document had been corrected. That header now states the real shape and what
   bounds it, and both halves (role retained, token-level roles shed) are pinned by
   test. See **D-21**.
2. **The NAV feed is the sole on-chain value-display channel.** It is load-bearing
   for display as well as for pricing.
3. **The atomic swap's loss ceiling is unbounded under `DEFAULT_ADMIN_ROLE`
   compromise** — `sum(balanceOf(swap))`, with the 48 h timelock as the only brake.
   Mitigation is operational: keep inventory small and sweep net flow.

### Medium

4. **2 of 8 broadcasting scripts do not use `DeployGuards`** — `AtomicSettlementFlow`
   and `DeployAtomicSettlementE2E`. Both pin a single chain with a bare equality
   `require`, so they are not the denylist bug class, but they lack env-var,
   not-the-deployer, min-delay and post-deploy-assertion coverage. The strict form of
   the CI job — *every* `vm.startBroadcast` script must call `DeployGuards` — would
   start red on exactly those two, so it was not adopted. **A weaker variant was**:
   `ci/check_chain_guards.py` check (b) requires every script to carry *some*
   allowlist guard and accepts a positive `block.chainid == <id>` pin as one, on the
   grounds that a positive pin is a fail-closed allowlist of exactly one chain. It
   ships green (`OK: every one of 9 file(s) … carries an allowlist chain guard`) and
   closes the checker's structural blind spot — a *missing* guard, which is how the
   ungated `DeployMockUSDC.s.sol` survived the first pass. What remains open is
   narrower than the original gap: the two scripts are chain-pinned but still get no
   env-var, min-delay or post-deploy-assertion coverage from the library. See
   [`ci.md`](ci.md).
5. **No `AaveV3Integration.t.sol` fork test.** It is the cheapest way to answer the
   Aave questions — fork a chain where Aave V3 is live, impersonate `POOL_ADMIN`,
   wire the forwarder, then supply → borrow → repay → withdraw and a mocked price
   drop into liquidation — and it would run in CI at zero cost. Three specific
   unknowns need it: whether a
   contract liquidator passes the sanctions screen, whether the aToken layer stays clear
   of the underlying's checks, and the exact 8-decimal price assertion.
6. **No deploy-script fork test for the atomic settlement run-book** — all steps
   against a fork, then one BUY and one REDEEM end-to-end. `AtomicSettlementDeployTest`
   covers the deploy script but not a forked-mainnet sequence.
7. **`AaveOracle` has no staleness check** — it just calls `latestAnswer()`. Consider
   a CAPO wrapper or explicit staleness-revert logic before any Aave listing.
8. **The sanctions keeper bot does not exist in any repo yet.** The mirror's write
    path is designed and tested; the 4-hourly OFAC delta job that feeds it is unbuilt.
    Until it runs, the mirror's local list is whatever was seeded plus whatever the
    forwarding oracle contributes.
9. **`SANCTIONS_UPDATER_ROLE` separation is procedural, not cryptographic.**
    `DEFAULT_ADMIN_ROLE` can grant itself the updater role and write. The control is that
    doing so is visible in the role-grant event log — worth an alerting rule.
10. **An oracle outage halts secondary transfers including DeFi liquidations**, and
    recovery via `setSanctionsList` takes 48 h on production. There is no faster path by
    design.
11. **Zero-amount guards are inconsistent across the codebase.** Worth a sweep for
    ops-alert hygiene: functions that succeed vacuously and emit events are noise in
    monitoring.

### Low / accepted

12. **A sanctioned address can hold economic exposure via an ERC-4626 wrapper's
    shares** without ever triggering the oracle. Accepted consequence of a plain ERC-20
    underlying; a compliance decision, not a technical one. [§10.5](#105-the-known-compliance-gap-erc-4626-wrappers)
13. **The probe idiom accepts any contract returning exactly 32 bytes** for the probed
    selector — a returning fallback passes. Inherent to the pattern, shared by every
    probe in the codebase.
14. **Residual permit allowance** — `permitIn.value` may exceed `requestedAmountIn`.
    Safe (only spendable via a taker-initiated `executeSwap`) but the quote service should
    issue exact-value permits.
15. **`forge fmt --check` and `forge build --deny-warnings` are not enforced.** The tree
    is not fmt-clean and there are two live solc warnings plus ~40 lint notes. Both jobs
    would start red and be ignored; fix first, then enforce. [`ci.md`](ci.md)
16. **No gas snapshots.** No baseline exists, most hot paths are fuzz tests with
    nondeterministic gas, and `via_ir` makes diffs churn on unrelated edits. A flaky
    snapshot job teaches people to ignore CI.
17. **Source files cite section numbers that belong to the absent
    `docs/atomic-swap-spec.md`, not to this document.** `grep -r atomic-swap-spec
    contracts/` returns **zero** hits — no file names the missing spec any more. What
    survives is worse, because it looks resolvable and is not: comments now cite
    *`docs/ARCHITECTURE.md`* (or a bare "spec") using the old spec's numbering, and
    those numbers land on unrelated sections here.

    | Citation | Points at | Actually lives in |
    |---|---|---|
    | `GyldAtomicSwap.halmos.t.sol:45` — "docs/ARCHITECTURE.md §8: I-1, I-2, I-3, I-10, I-11" | [§8 Value accrual](#8-value-accrual--nav-not-balances) | [§16.2](#162-the-gyldatomicswap-invariant-catalogue) |
    | `GyldAtomicSwap.spec.t.sol:1359` — "Pins spec §3.1" (ERC-7201 slot and packing) | — | [§12.1](#121-namespaced-storage), invariant I-19 in [§16.2](#162-the-gyldatomicswap-invariant-catalogue) |
    | `GyldAtomicSwap.spec.t.sol:225` — "the spec's §5.3 struct-hash formula" (and `:243` "§5.1", `:659` "§4.2") | — | [§5.7 The signed quote](#the-signed-quote) |
    | `GyldAtomicSwap.spec.t.sol:1687` — "spec §7" (TTL setter is admin-gated) | — | [§5.7 Quote invalidation](#quote-invalidation) |
    | `GyldAtomicSwap.sol:132` — `docs/ARCHITECTURE.md "Proposed amendment"` (the `MIN_DRAW_BPS` dust floor) | a string that appears **nowhere** in `docs/` | [§5.7 The signed quote](#the-signed-quote) — the 1 % floor, and invariant I-3 |

    The invariant catalogue itself is reconstructed in
    [§16.2](#162-the-gyldatomicswap-invariant-catalogue). The fix is a one-pass
    renumber of those comments against this document's headings — cheap, and it is
    the only thing standing between a reader and the invariant they were pointed at.
18. **A relayer path for `permit()`** — implemented in the token but no relayer exposed.
    Pending a product decision.

---

## Where else to look

| | |
|---|---|
| [`ci.md`](ci.md) | What CI runs, why full fuzz intensity on every push, what was considered and rejected, how to reproduce a failure locally. Referenced directly by `.github/workflows/ci.yml`. |
| [`decisions/erc8056-dropped-on-evm.md`](decisions/erc8056-dropped-on-evm.md) | The standing ADR for the value-display decision, kept dated and separate so it is not re-litigated. Summarised in [§8.3](#83-erc-8056-was-evaluated-and-dropped). |
| `.env.example` | Every deploy variable, which are `[PROD-REQUIRED]`, and what each one going wrong actually caused. |
| `contracts/test/GyldAtomicSwap.spec.t.sol` | The executable form of the invariant catalogue in [§16.2](#162-the-gyldatomicswap-invariant-catalogue). |
| `contracts/script/lib/DeployGuards.sol` | The guard library, with the incident narrative in its own doc comments. |
