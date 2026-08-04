# Flow of funds: Backed Finance vs. Gyld

**Status:** answer to a question raised 2026-07-30 — *"can we confirm the flow of funds based on what
we see on-chain with Backed Finance's mint/redemption transactions. There's the contract that holds
the pre-minted equity tokens and USDT/USDC. I presume that's a Fordefi wallet. When end clients send
in USDT/USDC, does that money directly go into that contract? Is there an intermediary wallet that
acts as a sweep account?"*

Every claim below is labelled **CONFIRMED** (primary source or direct on-chain read), **INFERRED**
(consistent with evidence, not stated by any source), or **UNKNOWN**. Please don't repeat the
inferred items to a counterparty as fact.

---

## Short answer

Three corrections to the premise, in order of how much they matter:

1. **For Backed, there is no contract holding the inventory.** The pre-minted tokens and the
   stablecoins sit in **issuer-controlled EOAs** — ordinary wallets, not smart contracts. Their
   swap contract holds no balance.
2. **Yes, there is a sweep account, and Backed calls it that.** Their own docs name the client
   deposit addresses "**sweeping addresses**". Client stablecoins land there and consolidate into
   an omnibus wallet.
3. **The Fordefi presumption is right for Backed and wrong for us.** Backed's use of Fordefi is
   confirmed by Fordefi's own published case study. On the Gyld side, our Fordefi adapter is a stub
   that returns `NotImplemented` — nothing is provisioned.

And a framing note worth keeping straight: *"a Fordefi wallet"* and *"a contract"* are different
categories. Fordefi is an MPC signing service; it controls **accounts**. A contract is never a
Fordefi wallet — but the keys holding privileged roles **over** a contract can live in Fordefi.

---

## Part 1 — Backed Finance

### 1.1 There are three distinct flows, and only one is atomic

Source: <https://docs.xstocks.fi/docs/issuance-and-redemption> (`docs.backed.fi` now 301-redirects
here). **CONFIRMED.**

| Flow | Atomic? | Mechanism |
|---|---|---|
| **Market Flow** | **No** | Client pushes stablecoins to a per-product deposit address; issuer buys the underlying via broker; tokens delivered in a **separate, later transaction**. |
| **xChange (atomic RFQ)** | **Yes** | EIP-712 signed authorization settled by a dedicated contract, single tx, settle-or-revert. |
| **xPort (in-kind)** | n/a | Shares ↔ tokens via Alpaca brokerage custody. No cash leg. |

The Market Flow is the dominant path and it is **not** a DvP swap. Quoting their docs directly:

> The direct client sends stablecoins to the product-specific issuance address from a whitelisted
> wallet. The issuer triggers a market buy order through the broker. The broker purchases the
> underlying equity. The corresponding xStock tokens are delivered to the direct client's
> whitelisted wallet.

Client counterparty exposure during that window is ~30 s (≤$200k) to ~2 min (>$200k). Minimum
direct ticket is **$5,000**; wallets must be whitelisted and KYC'd; not offered in the US. Most
retail actually transacts on secondary markets rather than directly with the issuer.

### 1.2 Yes — there is a sweep account, and it's their own terminology

**CONFIRMED (their docs):**

> One unique issuance **sweeping address** per xStock per supported blockchain… Redemption address.
> One designated redemption **sweeping address** per blockchain.

**CONFIRMED (on-chain).** These are plain EOAs, not contracts. Funds consolidate into the
Etherscan-labelled **"Backed: Deployer"** EOA `0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD`
(~$76.7M across 8 chains). Observed behaviour on that address:

- receives stablecoin deposits from many distinct client addresses;
- **pulls** some deposits gaslessly itself via `transferWithAuthorization` — e.g. tx
  `0xc49555e49a420f39d6e8887f0d3c5a946116645675a8c1853378318f7380a626`, 5,807.32 USDG pulled from
  a client address;
- receives xStock tokens for redemption and sends USDC back out;
- makes repeated large USDC transfers onward to an unlabelled EOA
  `0xd72e7933e7244Cf6e77FA1358b55996aDAf8eDC1` (e.g. 89,042.50 USDC in tx
  `0xf451ad0d70ed9a574cd4a6296de1f281cc561c72cde0be29bca1eef94b599eef`).

That last hop is **INFERRED** to be a treasury or off-ramp sweep. Its role is not publicly
documented — see open questions.

### 1.3 Mint and burn transactions carry no payment leg at all

This is the cleanest on-chain confirmation that the Market Flow is asynchronous. **CONFIRMED** by
direct inspection:

| Tx | What's in it |
|---|---|
| `0x1112b8cd95d56b11acd39dfd92bc82b0b46dc0e822dc5e2716604637a47ee3ed` | 200,000 bIB01 minted `0x0` → Backed's own Deployer EOA. **No stablecoin leg.** |
| `0x9f0662257750c9f2700de0b72e85431e1402136b5547f5331fe1869c57d04e65` | Minter Safe mints 20,057.13 bIB01 direct to a client wallet. **No stablecoin leg.** |
| `0xcfa1479048930a91d29a8d30f28fdce7ba4816de1188eabc09e52102c318e163` | Deployer EOA burns 100,000 bIB01. Nothing else in the tx. |

So the inventory model is: **mint in round batches to their own wallet, then distribute by ordinary
ERC-20 transfer** — with occasional direct mint-to-client. Payment reconciliation is entirely
off-chain.

One genuinely atomic example, **CONFIRMED** but with an inference attached: tx
`0x1b85c1fb888f7bb05f947b282442f0046f31ae4d3692b6084ffd08881a49d06b` — inside a CoW Protocol
`settle`, a client's MUX xStock flows to an ERC1967Proxy `0x41Dee1855293e4450CD67459047f372d4d818143`
then on to Backed's Deployer, while USDC flows the other way. That proxy is **INFERRED** to front
the xChange contract; its implementation `0x0488376a...` is **unverified on explorers**, so this
can't be confirmed from source.

### 1.4 Who holds mint authority

**CONFIRMED** on Ethereum mainnet for bIB01 (`0xCA30c93B02514f86d5C86a6e375E3A330B435Fb5`) and
bCSPX (`0x1e2C4fb7eDE391d116E6B41cD0608260e8801D59`) — both share the same key set:

| Role | Address | Type |
|---|---|---|
| minter | `0xdD276f57e40D745E09855BA5711613F5Da0C4A71` | Gnosis Safe, **2-of-3** |
| burner | `0x5F7A4c11bde4f218f0025Ef444c369d838ffa2aD` | **EOA** ("Backed: Deployer") |
| owner | `0x22f2dFE84a2EaCfE5d3cA81d26E610CB94eB1603` | Gnosis Safe |

Note the asymmetry: minting needs 2-of-3 multisig, **burning is a single EOA**. Per contract source
the burner can only burn its own or the contract's balance, which bounds it.

### 1.5 Fordefi — confirmed, from Fordefi's own mouth

**CONFIRMED.** Fordefi published a customer story (2024-07-10): *"Backed Chooses Fordefi To Power
Programmatic Tokenization-as-a-Service Platform."*
<https://www.fordefi.com/customer-stories/backed-chooses-fordefi-to-power-programmatic-tokenization-as-a-service-platform>

> Fordefi's MPC wallet not only handles the signing process but also manages the entire transaction
> lifecycle … to swiftly generate wallets, authorize transactions, and automate **token sweeping**.

That phrase independently corroborates the sweep-account model.

**INFERRED, not confirmed:** that `0x5F7A4c11...` specifically, and the 2-of-3 Safe signers, are
Fordefi MPC keys. Highly consistent — programmatic signing at scale, same address across chains —
but **no public source names those addresses as Fordefi vaults.** Don't state this as fact.

Separately: the **securities** custodians are distinct regulated custodians under a
bankruptcy-remote security-agent structure. Fordefi custodies *keys*, not the underlying equities.

---

## Part 2 — Gyld, for contrast

Our architecture answers the same question **differently in two places**, and it's easy to talk past
each other unless we say which one we mean.

### 2.1 Flow A — the backend deposit rail (this one has a sweep)

Source: `docs/architecture.md:695-825`. Structurally similar to Backed's Market Flow.

- **One `platform_custodian_address` per chain.** Not per-user. `docs/architecture.md:703`:
  *"there is one `platform_custodian_address` per chain (the platform's signing key address). All
  users send USDC to this single address."*
- Deposit ownership is attributed by **`Transfer.from`**, matched against the user's registered
  `source_addresses`. `deposit-watcher` credits an internal `CashBalance`.
- **Then a real sweep** (`docs/architecture.md:812-824`), the `AWAITING_FUNDING` state:
  `IWallet::transfer(platform_custodian_address → user.custodian_deposit_address)`, where the
  destination is an **Alpaca**-controlled address that credits their brokerage sub-account.
- The float window is explicitly surfaced to clients as its own balance line —
  `docs/integration/rest-api.md:843`: `platform_wallet_usdc` = *"USDC at the platform custodian
  wallet, not yet swept to the broker."*

**Worth flagging internally:** `platform_custodian_address` is owned by **`PrivkeyWallet` — a raw
hex private key**, not MPC. `docs/decisions/deferred-integrations.md:46-55`:

> **Fordefi wallet (`adapter-wallet-fordefi`) — Status:** Crate exists, all IWallet methods return
> `CoreError::NotImplemented`. … `PrivkeyWallet` (hex key) is used on Hoodi dev. **When to revisit:**
> Before mainnet launch.

So where Backed has this on MPC today, we have it on a single hex key, with Fordefi named as the
pre-mainnet target (documented policy: 3-of-3 split, 2-of-3 threshold) but **not provisioned**.

### 2.2 Flow B — `GyldAtomicSwap` (no sweep, and the contract *is* the custodian)

This is where we differ most from Backed. `contracts/GyldAtomicSwap.sol:21-28`:

> Self-custodial atomic two-leg settlement … **This contract HOLDS its own inventory** (USDC, USDG,
> bond tokens) … There is no separate vault.

The whole flow is two transfers in one transaction:

| # | from → to | code |
|---|---|---|
| 1 | client → **swap contract** (`tokenIn`) | `:371` `safeTransferFrom(msg.sender, address(this), requestedAmountIn)` |
| 2 | **swap contract** → client (`tokenOut`, from its own balance) | `:383` `safeTransfer(msg.sender, amountOut)` |
| 3 | *(later, separate tx)* swap contract → fixed `withdrawalWallet` | `:578-584` `withdraw()`, `TREASURER_ROLE` |

No intermediate hop, no fee recipient — any spread is baked into the off-chain-signed `price`.
Clients approve exactly one address (the swap proxy), by standing allowance or EIP-2612 permit, and
the contract grants **no** outbound allowances to anything (explicit Hashflow-exploit lesson,
`:31-34`).

**Note the historical irony.** `docs/atomic-settlement.md:345` records that we modelled `executeSwap`
on Backed's `AtomicSwapUpgradeable` (impls `0x202BDae6...` and `0x3AdF98F5...`, their Oct-2025 audit
cited) and *rejected* their approach because **"Backed uses standing treasury allowances"** — adding
a vault instead. Then commit `5c1a1f4` (GYL-548) **deleted the vault**. We've landed on a third
model: neither Backed's treasury-allowance design nor our own documented vault design, but custody
inside the swap contract itself.

### 2.3 What of ours is actually live — verified on-chain 2026-07-30

Be precise here, because the two halves differ. All of the below was verified read-only against
public RPCs (`https://mainnet.base.org`, chainId confirmed 8453).

**Live on Base mainnet (8453):** the *issuance/redemption* stack, holding real state.

| Contract | Address |
|---|---|
| TimelockController | `0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72` |
| IssuanceManager (proxy) | `0x5BA267367f06378816c58d47C5850fC9863Ce67F` |
| TokenFactory | `0x18Ce55785bD24Dd096dAC11111168B1E94A76317` |
| "Test Bond Alpha" (TBA) token | `0xD9e587D18A6aA190eba22dFce06fb84a8cdfEFA3` |
| KaleidoscopeNAVFeed / NAVFeedForwarder | `0xC69e88136D52D0ADb911F03A2E71d374cA668DeC` / `0x09907C78D4eB531495962120464BFd9044390337` |

TBA `totalSupply()` = 2e18. The token uses the **real Chainalysis oracle** on Base
(`0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B`), not a mock. Live Morpho and Euler markets exist
against it. Total value at risk is sub-$2 — a testbed, but a *mainnet* testbed.

A tighter Sepolia (11155111) stack also exists, and — see below — is configured **more safely than
mainnet.**

**Not deployed on any public chain:** `GyldAtomicSwap`, `GyldSettlementVault`, `GyldDvpEscrow`,
`SanctionsOracleMirror`. Local Anvil (31337) only, confirmed by sweeping every 40-hex address in
tracked files across full git history against Base mainnet. Base Sepolia (84532) and Ethereum
mainnet (1) are both empty — deployer nonce 0.

**So:** the *atomic swap* flow of funds has no on-chain history to compare against Backed's. But the
mint/burn flow does, and it is live on mainnet.

---

## Side-by-side

| | **Backed (Market Flow)** | **Backed (xChange)** | **Gyld Flow A** | **Gyld `GyldAtomicSwap`** |
|---|---|---|---|---|
| Client stablecoins land in | issuer EOA ("sweeping address") | pulled from client in-tx | one omnibus platform EOA | **the swap contract** |
| Inventory held by | issuer EOA | issuer EOA (float) | n/a | **the swap contract** |
| Sweep account? | **yes** | no | **yes** (→ Alpaca) | no |
| Atomic DvP? | no (~30 s–2 min) | yes | no | yes |
| Payment/delivery in one tx? | no | yes | no | yes |
| Key custody today | **Fordefi MPC (confirmed)** | Fordefi MPC | **raw hex key** | deployer EOA / TBD |
| Live on a public chain? | yes | yes | dev only | **no** (but the mint/burn stack **is** live on Base mainnet) |

---

## What we cannot answer, and shouldn't guess at

**About Backed — only they can say:**
1. Are `0x5F7A4c11...` and the 2-of-3 Safe signers actually Fordefi MPC vault keys, and what policy
   quorum governs them?
2. What is `0xd72e7933e724...`, the recurring USDC sweep destination — treasury, exchange off-ramp,
   or broker funding account?
3. In the Market Flow, are client stablecoins segregated per client between deposit and sweep, or
   commingled in the omnibus wallet? What happens to **in-flight deposits** on issuer insolvency?
   The security-agent structure covers the securities collateral — not obviously the stablecoin float.
4. Is the xChange contract audited, and why is its implementation unverified on explorers?
5. When do they mint direct-to-client vs deliver from float, and who reconciles mint volume against
   broker fills?

**About our own stack — not determinable from this repo:**
6. Whether any given role holder is a Fordefi wallet, a Safe, or a bare EOA. Every role is an env-var
   constructor argument (`DeployAtomicSettlement.s.sol:120-127`); "Fordefi" and "MPC wallet" appear
   **only in comments** — intent, not enforcement.
7. Whether the production deployment actually has a timelock as `DEFAULT_ADMIN_ROLE`.
   `TIMELOCK_ADDRESS` is *optional* — unset, the deployer silently keeps admin (`:120, 187, 195-197`).
8. The real `withdrawalWallet` address and everything downstream of it.
9. The entire fiat rail — USD↔USDC on-ramp, T+2 broker bridge, Alpaca omnibus. Lives in the
   Kaleidoscope backend, a different repo.
10. Who actually pays the client in the `IssuanceManager` redemption path. It burns and emits an
    event; the USDC leg is asserted to happen off-chain (`IssuanceManager.sol:164-166`). There is
    **no on-chain guarantee that path ever pays out** — it's a trust assumption on the backend.

---

## Live Base mainnet control findings — verified, not theoretical

These came out of checking what's actually deployed, and they are the most actionable output of this
exercise. All four independently re-verified by hand against `https://mainnet.base.org`.

**1. A single EOA can upgrade the live Base mainnet `IssuanceManager`.** `DEFAULT_ADMIN_ROLE` is held
by the deployer EOA `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd`, **not** the timelock:

```
hasRole(DEFAULT_ADMIN_ROLE, deployer) → true
hasRole(DEFAULT_ADMIN_ROLE, timelock) → false
```

`IssuanceManager` is UUPS with `_authorizeUpgrade` gated on `DEFAULT_ADMIN_ROLE`. That EOA also holds
`SUBSCRIBER_ROLE`, `REDEEMER_ROLE`, and `WHITELIST_ADMIN_ROLE` — i.e. mint, burn, and whitelist
authority in one key, plus the ability to replace the implementation. This is the concrete,
on-mainnet instance of what GYL-1135 flagged in the abstract.

**2. The timelock provides no timing protection.** `getMinDelay()` returns **0**, and `EXECUTOR_ROLE`
is held by `address(0)` — meaning execution is open to anyone. It is an ownership indirection, not a
delay. (`GOVERNANCE_MULTISIG` defaults to `msg.sender` — `contracts/script/DeployDevNet.s.sol:77`.)

**3. Sepolia is configured more safely than mainnet.** On Sepolia, `IssuanceManager`'s
`DEFAULT_ADMIN_ROLE` **is** the timelock and the deployer is `false`. On Base mainnet it's the
reverse. Whatever hardening was applied to testnet was not applied to the live chain — the inversion
suggests mainnet predates the fix rather than being a deliberate choice.

**4. 54% of TBA supply sits in an address that appears nowhere in this repo.**
`0xf76289bc29779808c178158783bde1d819143fe5` holds 1.0879999 of the 2.0 TBA supply. It is an EOA
(`cast code` → `0x`) and was found only by scanning `Transfer` logs. `GyldBondToken` has no
forced-transfer or recovery function (`docs/blockchain-status.md:370`), so if that key is lost or
third-party-held, the majority of supply is unrecoverable. Value is trivial; the *procedure gap* is
not — nobody wrote down where the supply went.

**5. The Base NAV feed has been stale for 72 days** — `updatedAt` = 1779180729 (2026-05-19 08:52
UTC), value pinned at $100.00. The Euler `ChainlinkOracle` adapter was deployed with
`maxStaleness = 86400`, so it now hard-reverts:

```
adapter.getQuote(1e18, TBA, USDC)              → PriceOracle_TooStale(6242672, 86400)
lendingVault.accountLiquidity(deployer, false) → PriceOracle_TooStale
```

The Euler position (0.5 TBA collateral / 0.301438 USDC debt) **cannot be priced, borrowed against, or
liquidated** until someone pushes a NAV. Sub-dollar amounts, so this is hygiene — but the identical
pattern would freeze a production lending market, including liquidations. Worth a monitor before it
matters.

---

## Two things this exercise surfaced that need owners

Not part of the original question, but they came out of the trace and are material.

- **`GyldAtomicSwap.withdraw()` has no cap, no rate limit, and no timelock**, and deliberately works
  while paused (`:570-584`). Now that the contract is the custodian of live client inventory,
  `TREASURER_ROLE` compromise is a total forced sweep. The destination is fixed to `withdrawalWallet`
  (the treasurer can't redirect) — but redirecting only needs `DEFAULT_ADMIN_ROLE`, which is
  currently the deployer unless a timelock was wired. Already tracked as HIGH in
  `docs/atomic-settlement-testnet-runbook.md:409` and GYL-1135.

- **`KaleidoscopeNAVFeed.emergencyUpdateAnswer()` bypasses both the ±10% deviation cap and the
  1-hour interval** (`:183-190`), setting NAV to any positive value in one call. Since the swap
  derives its entire price sanity band from that feed (`:431-440`), `_emergencyUpdater` plus
  `QUOTE_SIGNER_ROLE` can mispriced-drain inventory with no on-chain bound. Mitigation is that the
  two keys are meant to be separate — a two-key control, not a timelocked one. Tracked in GYL-1134.

- **No ADR exists for the vault → self-custody decision.** `5c1a1f4` gives mechanical reasons only;
  `docs/atomic-settlement.md:29` promises `docs/decisions/atomic-settlement.md`, which was never
  written. Given custody is now the contract's job, that rationale should exist in writing before an
  audit asks for it.
