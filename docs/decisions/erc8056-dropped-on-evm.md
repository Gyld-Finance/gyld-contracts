# Decision: ERC-8056 (Scaled UI Amount) — dropped on EVM

**Status:** Adopted  
**Date:** 2026-08-03  
**Applies to:** `contracts/GyldBondToken.sol` (extension removed), `docs/**`  
**Linear:** GYL-1201 (supersedes the GYL-956 display-multiplier addendum to the
token-design ADR, now folded into
[`../ARCHITECTURE.md`](../ARCHITECTURE.md) §8 and §17.3; resolves roadmap
decision D-5)

Gyld will **not** implement ERC-8056 (Scaled UI Amount) on any EVM chain. The
extension has been removed from `GyldBondToken`, the demo tooling and runbooks
have been deleted, and value display returns to the model that was already
authoritative for everything transactional: **value accrues in the NAV,
published on-chain via `KaleidoscopeNAVFeed`** (and its `NAVFeedForwarder`).
This is the same model used by USYC, Spiko, Midas, OpenEden and Superstate.

This record exists so the question is not re-litigated. Every claim below was
verified before the decision, and the verification method is stated inline.

---

## 1. It is a stock-splits standard; we issue bonds

The EIP's own Motivation section is entirely about corporate actions — stock
splits, reverse splits, dividend-driven share adjustments. The multiplier
exists so that a 10:1 split can be *displayed* without touching raw balances.

Bonds do not split. They accrue coupon and NAV appreciation continuously and
then mature. Using a splits standard as a continuous NAV mirror is off-label
use of a Draft spec, and it created a **second NAV channel** on the token that
had to be kept manually in lock-step with `KaleidoscopeNAVFeed` (the roadmap's
E-F3 finding). Two channels for one number is a reconciliation liability, not
a feature.

## 2. No EVM wallet implements it, and the architecture makes that unlikely to change

- **Zero hits for `uiMultiplier`** across the public repositories of MetaMask,
  Rabby, Trust Wallet, OKX Wallet, and Block Wallet.
- **On Solana the equivalent works because of a chokepoint we do not have.**
  The scaled-UI-amount multiplier lives in the token program itself, so the
  RPC returns a scaled `uiAmount` and every wallet inherits the scaling for
  free. Verified directly: a raw balance of 155,056.98 returned
  `uiAmount` 1,550,569.82 at a 10× multiplier — no wallet code involved.
- **Ethereum's JSON-RPC has no token-aware method at all.** There is no
  `uiAmount` to inherit; every wallet does its own `balanceOf` + `decimals`
  reads. Scaling is therefore opt-in per wallet, per token, with no chokepoint
  that could ever make adoption automatic.

## 3. Observed on our own deployment

On the BSC testnet demo token, **MetaMask displayed 1,000.00 where BscScan
displayed 1,040.00** — same wallet, same contract, same block (multiplier
1.04×). An Anvil rehearsal (verification notes, 2026-07-31, since deleted with
the rest of the demo tooling) showed the identical divergence at 1.05×, and the
(now-deleted) BNB runbook predicted it: MetaMask renders the raw `balanceOf`,
full stop.

That is the standard producing the exact harm it exists to prevent: two
different numbers for one balance, both apparently authoritative. A display
standard that only explorers honour makes display *less* consistent, not more.

## 4. Nobody in our category uses it

Of **22 tokenized-fund/bond issuers verified on-chain**:

| Value-display model | Count | Examples |
|---|---|---|
| Repricing / ERC-4626 (NAV in an oracle or share price) | **10** | USYC, Spiko, Midas, OpenEden, Superstate, sDAI, sUSDS, sUSDe, stUSD, Ondo |
| Rebasing | 5 | — |
| Mint-extra-units (dividend as new tokens) | 2 | BUIDL, BENJI |
| **ERC-8056** | **1** | Robinhood Chain — who own both the chain **and** the app their users see, i.e. they *are* the chokepoint |

**Not one bond or treasury issuer uses a display multiplier.** Two data points
sharpen this:

- **Superstate co-authored the EIP and does not use it** on their own $600M+
  funds — USTB reverts on `supportsInterface` and exposes no `uiMultiplier`.
- **Backed uses the scaled-amount mechanism on Solana** (where it is free, per
  §2) **but rebasing on Ethereum for the same token** — the same conclusion
  reached independently.

## 5. Other risks that stacked against it

- **Draft status.** The interface has been restructured repeatedly; our own
  conformance pass (roadmap §5, findings E-C1…E-F3) found the first
  implementation non-conformant against a moving target. Selector pinning
  turns every upstream edit into a red test suite.
- **TOCTOU hazard in the conversion helpers.** `toUIAmount`/`fromUIAmount`
  read the multiplier at call time; a scheduled change activating between a
  read and a dependent action silently changes the conversion.
- **Indexers cannot distinguish scaled transfers.** The extension reuses the
  ordinary `Transfer` event, so a log consumer cannot tell whether a UI-aware
  or raw amount was intended without extra state reads at the event's block.

## 6. What replaces it: nothing new

Accrual already lives in `KaleidoscopeNAVFeed`. The atomic swap's NAV band,
the Morpho Blue market, and the Euler integration all read it (via
`NAVFeedForwarder`). Wallet/portfolio value is `balanceOf × NAV` — the read
integrators were always told to do. No integrator has asked for ERC-8056 by
name (roadmap D-5).

**Consequence: the NAV feed becomes more load-bearing.** It is now the *only*
on-chain value-display channel, not one of two. This raises the priority of
the known stale-feed and NAV-keeper gaps tracked in **GYL-1134** — the feed
never reverts on staleness, and Morpho does no age check of its own. When this
decision was taken the concrete case was a live feed that had gone unpushed
since 2026-05-19; that stack has since been retired (see the note in §7), but
neither gap in the contracts was closed by its removal. Dropping ERC-8056 does
not create that problem, but it removes any excuse for deferring it.

## 7. Orphaned testnet artifacts — record for the trail

Two throwaway tokens were deployed with the extension during evaluation.
**Do not reuse these proxies** for any future series; deploy fresh.

| Network | Token | Address |
|---|---|---|
| Ethereum Sepolia (11155111) | `GTB8056` (ISIN `TEST8056A00001`) | `0xE1C0a83Ab03e4498Fad1f833fA484E2cfc68dE7b` |
| BSC testnet (97) | `GBSCD` | `0x7D7B5bE30bfe7A1941c60247b4D5A28ab266305a` |

> **Note, 2026-08-20.** When this decision was taken (2026-08-03) a mainnet token
> stack existed on a further chain. It **predated the extension** and never
> carried it, so no mainnet cleanup was required then or now. That stack was
> retired in `1e9ffa8` and is no longer tracked anywhere in this repository;
> [`DEPLOYMENTS.md`](../../DEPLOYMENTS.md) is the authoritative register of what
> is deployed today, and it is the only place to read an address from.

## 8. Consequences for developers

- Do not add `uiMultiplier`, `balanceOfUI()`, `totalSupplyUI()`,
  `toUIAmount()`, `fromUIAmount()`, or a `UI_MULTIPLIER_ROLE` to
  `GyldBondToken`. The plain-ERC-20 prohibition in
  [`../ARCHITECTURE.md`](../ARCHITECTURE.md) §8.1 applies again without the
  GYL-956 carve-out.
- Displayed value is `balanceOf × NAV` from `NAVFeedForwarder`. Anything that
  needs a scaled number reads the feed; nothing reads it from the token.
- Any future request for wallet-native display scaling starts from this
  record: the blocker is EVM wallet architecture (§2), not our contract, so
  re-implementing the token side changes nothing a user sees.
- If a genuinely adopted display standard emerges on EVM (i.e. MetaMask ships
  it), reopen against this record with wallet-adoption evidence — that is the
  single fact that would change the outcome.

---

## Summary

| Question | Answer |
|---|---|
| Does any Gyld EVM token implement ERC-8056? | **No.** Extension removed (GYL-1201). The two orphaned testnet proxies above still carry old bytecode; do not reuse them. |
| Where does displayed value come from? | `balanceOf × NAV`, NAV from `KaleidoscopeNAVFeed` via `NAVFeedForwarder` — same as everything transactional. |
| Why not ship it anyway, it's display-only? | No EVM wallet reads it, so it *creates* display divergence (MetaMask 1,000.00 vs BscScan 1,040.00) instead of curing it. |
| Who does use it? | One issuer (Robinhood Chain), who controls both the chain and the wallet. No bond or treasury issuer. |
| What must get more attention as a result? | The NAV feed's stale-feed and keeper gaps — GYL-1134. |
