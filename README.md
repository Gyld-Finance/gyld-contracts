# gyld-contracts

On-chain smart contracts for the Gyld tokenized bond platform. One ERC-20 token per bond series, backed 1:1 by securities held in custody off-chain. The [Kaleidoscope](https://github.com/Gyld-Finance/kaleidoscope) backend orchestrates mint and redemption workflows; these contracts enforce compliance and finality on-chain.

Solidity `0.8.28`, compiled with Foundry, on OpenZeppelin v5.3.0.

> **Full architecture and design: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).**
> That document is the single authoritative reference — every contract, the complete
> role matrix, both settlement flows, the custody and oracle models, the deployment
> guards, the DeFi integration parameters, and the known gaps. This README is a
> summary only; where the two disagree, `ARCHITECTURE.md` is verified against the
> Solidity and wins.

---

## Contracts

| Contract | Upgrade | Purpose |
|---|---|---|
| `GyldBondToken` | UUPS | ERC-20 per bond series. Fixed balances — value accrues in the NAV feed, never in balances. On-chain sanctions check on every secondary transfer, fail-closed. Pausable. EIP-2612 permit. IERC-1643 document management (prospectus / supplements), gated by `DOCUMENT_ROLE`. |
| `IssuanceManager` | UUPS | Single mint/burn gate for all bond series. Only whitelisted Authorised Participants (APs) may receive minted tokens or be recorded as redemption beneficiaries. |
| `TokenFactory` | None (`Ownable2Step`) | Deploys a `(GyldBondToken proxy, KaleidoscopeNAVFeed, NAVFeedForwarder)` triple atomically and wires the token's roles in one transaction. |
| `KaleidoscopeNAVFeed` | None (`Ownable2Step`) | Chainlink `AggregatorV3Interface`-compatible NAV oracle, 8 decimals. The backend pushes NAV here. 10 % max deviation per update, 1-hour minimum interval. Both guards are unconditional — `updateAnswer` is the only write path and nothing bypasses it. |
| `NAVFeedForwarder` | None (`Ownable2Step`) | Permanent, stable oracle address that forwards reads to a swappable upstream. DeFi protocols point here — **never** at `KaleidoscopeNAVFeed` directly. |
| `SanctionsOracleMirror` | None | The platform sanctions oracle on **every** production EVM chain, Ethereum mainnet included (GYL-1051). A keeper bot syncs OFAC deltas into its local list; an optional gas-capped, fail-closed `forwardingOracle` can chain to a vendor oracle. |
| `GyldAtomicSwap` | UUPS | Self-custodial atomic USDC⇄bond settlement against platform-signed EIP-712 quotes. **Holds its own inventory** — there is no vault, and it grants no standing outbound allowance. Taker binding, taker allowlist, single-use quotes, NAV sanity band. Net inventory leaves only via `withdraw()`, and only to the admin-fixed `withdrawalWallet`. |
| `IERC1643` | n/a — interface, no bytecode | `contracts/interfaces/IERC1643.sol`. Vendored (OpenZeppelin v5 ships no ERC-1643) and implemented by `GyldBondToken`. Its `Document` struct is the value type of the token's `documents` mapping, so member order **is** the physical storage layout on every deployed proxy. |

---

## Role architecture

`DEFAULT_ADMIN_ROLE` exists on all four `AccessControl` contracts and grants /
revokes every other role on its own contract. On the three UUPS contracts it also
authorises the upgrade; on the immutable `SanctionsOracleMirror` there is nothing to
upgrade and it gates `setForwardingOracle` instead. In production it is a
`TimelockController` (48 h minimum).

```
GyldBondToken
  MINTER_ROLE          →  IssuanceManager (exclusively — never an EOA)
  BURNER_ROLE          →  IssuanceManager (exclusively)
  PAUSER_ROLE          →  Ops multisig hot wallet — pause() AND unpause()
  DOCUMENT_ROLE        →  Ops multisig (IERC-1643 set/remove — operational, no delay)

IssuanceManager
  WHITELIST_ADMIN_ROLE →  Compliance ops multisig
  SUBSCRIBER_ROLE      →  MPC wallet A  (subscribe / mint path only)
  REDEEMER_ROLE        →  MPC wallet B  (redeem / burn path only)
  REGISTRAR_ROLE       →  TokenFactory

GyldAtomicSwap
  QUOTE_SIGNER_ROLE    →  Quote-service KMS key(s). Passive — the role registry IS
                          the signer set, checked via hasRole against the recovered
                          EIP-712 signer, so a revoke kills every in-flight quote
  ALLOWLIST_ADMIN_ROLE →  KYC/compliance hot key; setAllowed() and nothing else
  TREASURER_ROLE       →  Ops MPC wallet; withdraw() to the fixed withdrawalWallet.
                          Deliberately live while the SWAP is paused (incident
                          evacuation). A paused bond token still gates its own
                          leg — by design; unpause it first, see the runbook
  PAUSER_ROLE          →  Ops multisig; pause() ONLY — resuming needs the admin

SanctionsOracleMirror
  SANCTIONS_UPDATER_ROLE →  Keeper bot (add / remove sanctioned addresses)

KaleidoscopeNAVFeed.owner       →  KMS signer (pushes NAV). The ONLY write path;
                                    no bypass exists, so this key's ceiling is
                                    genuinely 10%/hour. See ARCHITECTURE D-19
NAVFeedForwarder.owner          →  TimelockController (oracle provider swaps)
TokenFactory.owner              →  TimelockController
```

`SUBSCRIBER_ROLE` and `REDEEMER_ROLE` should be distinct keys, and the production
deploy path enforces it (`DeployGuards.requireDistinct`) — but `IssuanceManager`
itself does not: `initialize` only rejects `address(0)`. Granting both to one
address post-deploy is possible and would not revert.

`TokenFactory._wireRoles` self-revokes `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` from
the factory **on each token it deploys**, so it holds no permissions on any token
afterwards.

> **It does not revoke `REGISTRAR_ROLE`.** That role lives on the `IssuanceManager`,
> and the factory keeps it permanently — there is no `revokeRole` for it in the
> contract or in any deploy script, and on any stack deployed by the factory
> `hasRole(REGISTRAR_ROLE, factory) == true`. Do not build a threat model that
> assumes the factory holds no permissions post-deploy. See
> [`docs/ARCHITECTURE.md` §5.3](docs/ARCHITECTURE.md#53-tokenfactory) and
> [§18](docs/ARCHITECTURE.md#18-known-gaps-and-open-decisions).

The complete matrix — every role, what it gates, who should hold it, whether it is
renounceable, and what a compromise of each buys — is
[`docs/ARCHITECTURE.md` §6](docs/ARCHITECTURE.md#6-role-and-permission-matrix).

---

## Deployment flow (per bond series)

The full 13-step sequence — every constructor argument, every role grant, and the
atomic-settlement tail — is
[`docs/ARCHITECTURE.md` §13.6](docs/ARCHITECTURE.md#136-per-series-deployment-sequence),
and is maintained there only. In outline: deploy `SanctionsOracleMirror` (once per
chain), then the shared `IssuanceManager`, then the `GyldBondToken` implementation
and `TokenFactory`; grant the factory `REGISTRAR_ROLE`; deploy a
`TimelockController` (delay >= 48 h) and hand it both the `IssuanceManager` admin
role and factory ownership. Then, per series, a single timelocked
`TokenFactory.deployToken(...)` deploys the
`(GyldBondToken proxy, KaleidoscopeNAVFeed, NAVFeedForwarder)` triple atomically,
wires the token's roles while self-revoking its own, and registers the token with
the `IssuanceManager`. Finally push the first NAV and point DeFi markets at the
**forwarder** address — never at `KaleidoscopeNAVFeed` directly.

**Four ordering constraints bite if violated:**

- The factory must hold `REGISTRAR_ROLE` on the `IssuanceManager` **before**
  `deployToken`. The preflight reverts `MissingRegistrarRole` before any of the
  three deployments.
- Factory ownership must move to the timelock **before** `deployToken`, because
  `_wireRoles` grants `DEFAULT_ADMIN_ROLE` on each token to `owner()` *as it is at
  that moment*. Deploy first and the deployer EOA becomes the token admin
  permanently.
- A NAV must be pushed **before** the series is registered with the swap or with
  any DeFi market. `executeSwap` fails closed on a non-positive or stale NAV, and
  on a fresh feed `latestAnswer()` reverts `NoPriceSet` — it does not return 0.
- `ALLOWLIST_ADMIN_ROLE` must be granted **before** the deployer's
  `DEFAULT_ADMIN_ROLE` is revoked, or granting it later needs a timelock proposal.

Token addresses are deterministic — `TokenFactory.predictTokenAddress()` returns the
proxy address before deployment. The CREATE2 salt is derived from the ISIN **and**
`block.chainid`, and a separate `_deployedIsins` registry rejects any repeat
deployment of the same ISIN regardless of name, symbol or maturity.

**Deploy scripts fail closed (GYL-1135).** Dev chains are an *allowlist* — Anvil
31337 and Ethereum Sepolia 11155111 only. Every other chain, including ones that do
not exist yet, takes the strict path: required env vars, no privileged address equal
to the deployer, a 48 h minimum timelock delay, and in-band post-deploy topology
assertions that abort the deployment on a mismatch. See
[`docs/ARCHITECTURE.md` §13](docs/ARCHITECTURE.md#13-deployment-model) and
`.env.example`.

---

## Compliance model

- **Sanctions:** every `transfer` / `transferFrom` on `GyldBondToken` screens sender,
  receiver **and spender** against the configured on-chain oracle. Fail-closed — if
  the oracle reverts, or its address is unset, the transfer reverts. No role bypasses this; the contract uses
  `AccessControl`, so there is no `owner` at all. Mint and burn skip the oracle
  (`IssuanceManager` pre-screens APs off-chain) but still respect `whenNotPaused`.
- **Pause:** `PAUSER_ROLE` halts mint, burn, transfer, transferFrom, approve and
  permit. Note that a pause also freezes DeFi liquidations.
- **AP whitelist:** only whitelisted addresses may receive primary issuance or be a
  recorded redemption beneficiary. Secondary ERC-20 transfers carry no whitelist
  restriction.
- **No internal blocklist.** Sanctions decisions are delegated entirely to the
  oracle — the platform-operated `SanctionsOracleMirror`, which mirrors approved
  OFAC/SDN data and never adds addresses at platform discretion. Rotate oracle
  contracts with `setSanctionsList()` (timelock-gated); `address(0)` is rejected, so
  the oracle can be replaced but never removed.
- **No forced transfer and no recovery function.** A sanctioned address is frozen in
  place; nothing can move its tokens. Legal escalation is off-chain.
- **`GyldAtomicSwap` makes no sanctions call of its own.** It does not need one:
  every swap has exactly one `GyldBondToken` leg, so the token's own screen fires on
  the taker and on the swap contract as spender. The taker allowlist
  (`ALLOWLIST_ADMIN_ROLE`) is a separate, additive gate, not a substitute.

---

## Quickstart

```sh
forge build                 # compile (via_ir, optimizer_runs = 200)
forge test                  # 524 tests, 20 suites; fuzz runs = 10000
forge test -vvv             # traces for failures
forge coverage --ir-minimum # plain `forge coverage` is stack-too-deep: it disables
                            # via_ir, which this source needs

# The two CI guards, both runnable offline (see docs/ci.md)
python3 ci/check_storage_layout.py   # ERC-7201 layout unchanged on the 3 upgradeables
python3 ci/check_chain_guards.py     # every script under contracts/script/ has an
                                     # allowlist (not denylist) chain guard

# Local devnet (Anvil)
anvil &
forge script contracts/script/DeployDevNet.s.sol \
  --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil_key>

# Timelock (production prerequisite)
forge script contracts/script/DeployTimelock.s.sol --broadcast --rpc-url $RPC_URL
```

Prerequisites: [Foundry](https://getfoundry.sh) (pinned to `v1.5.1`),
`ETHERSCAN_API_KEY` for verification, and `forge install` for the `lib/` submodules.

---

## Tests

`forge test` — 524 tests across 20 suites, all at full `foundry.toml` intensity.

| Test file | Coverage |
|---|---|
| `GyldAtomicSwap.t.sol` | Quote execution both directions, expiry, epoch, replay, signer, taker binding, allowlist, permit, pause, withdrawal |
| `GyldAtomicSwap.spec.t.sol` | The executable form of the numbered invariant / finding catalogue. [`docs/ARCHITECTURE.md` §16.2](docs/ARCHITECTURE.md#162-the-gyldatomicswap-invariant-catalogue) is the catalogue itself, and records per id which are pinned here and which are gaps |
| `GyldAtomicSwap.invariants.t.sol` | Stateful: never-mints, single-use quotes, fair-price rounding |
| `GyldAtomicSwap.halmos.t.sol` | Halmos symbolic verification of I-1, I-2, I-3, I-10, I-11 (`check_` prefix; `forge test` skips these) |
| `GyldBondToken.t.sol` | Transfer, sanctions, pause, permit, role management, storage slot-pinning, UUPS upgrade, IERC-1643 document management |
| `GyldBondToken.invariants.t.sol` | Supply invariants under fuzz |
| `IssuanceManager.t.sol` | Subscribe, redeem, whitelist, token registry, role isolation, UUPS |
| `KaleidoscopeNAVFeed.t.sol` | Price updates, deviation guard, interval guard, non-renounceable ownership, chained-update recovery from an in-band fat-finger, and `test_noStalenessRevertPathExists` |
| `NAVFeedForwarder.t.sol` | Oracle forwarding, upstream swap, probe validation, future-dated rejection |
| `SanctionsOracleMirror.t.sol` | Add/remove, role separation, forwarding-oracle probe and gas cap |
| `TokenFactory.t.sol` | Atomic deployment, CREATE2 prediction, role wiring, `REGISTRAR_ROLE` preflight, duplicate-ISIN rejection |
| `Timelock.t.sol` | Delay enforcement, cancellation |
| `AtomicSettlementDeploy.t.sol`, `DeployScripts.t.sol` | Deploy scripts including the fail-closed guards; `DeployMockUSDCTest` covers the dev-chain allowlist on `DeployMockUSDC` — refused on every production chain and on any testnet outside the dev-chain allowlist, still funds the Anvil accounts on a dev chain |

---

## Docs

The doc set is deliberately small — four files under `docs/`, plus `DEPLOYMENTS.md`
at the root.

| Document | Contents |
|---|---|
| [`DEPLOYMENTS.md`](DEPLOYMENTS.md) | **The authoritative on-chain address register.** The only place an address is canonical; if a contract is not listed there, do not send funds to it, approve it or wire it into a config. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | **The authoritative reference.** Every contract, the complete role and permission matrix, custody and loss ceilings, value accrual, both settlement flows, compliance, oracle design, deployment model, DeFi integration rules (oracle shape, staleness behaviour, ERC-4626), the verification surface, the decision record, and known gaps. |
| [`docs/ci.md`](docs/ci.md) | What CI runs and why, what was considered and rejected, how to reproduce a failure locally. Referenced directly by `.github/workflows/ci.yml`. |
| [`docs/atomic-settlement-testnet-runbook.md`](docs/atomic-settlement-testnet-runbook.md) | Deployment runbook and readiness assessment for taking the `GyldAtomicSwap` stack to a public testnet, including the fresh-deploy checklist. |
| [`docs/decisions/erc8056-dropped-on-evm.md`](docs/decisions/erc8056-dropped-on-evm.md) | Standing ADR: why ERC-8056 (Scaled UI Amount) was dropped on EVM. Kept dated and separate so the decision is not re-litigated. |

---

## Security

- Compiled with `via_ir = true`, `optimizer_runs = 200`, `solc` pinned to `0.8.28`
  in both the source pragmas and `foundry.toml`
- OpenZeppelin contracts-upgradeable **v5.3.0**, ERC-7201 namespaced storage on all
  three upgradeable contracts (slots recomputed and pinned by test)
- UUPS upgrades require a `TimelockController` in production (48 h minimum)
- `DEFAULT_ADMIN_ROLE` is non-renounceable on all four `AccessControl` contracts
  (`renounceRole` reverts `CannotRenounceAdminRole`). Every *other* role stays
  renounceable, deliberately — the admin administers them all, so a renounce costs
  one re-grant, and a holder who knows their key is compromised can shed it without
  waiting on a timelock. The three `Ownable2Step` contracts — `TokenFactory`,
  `NAVFeedForwarder`, `KaleidoscopeNAVFeed` — have no roles at all; each one's
  `renounceOwnership()` reverts `CannotRenounceOwnership`. Rotation is
  `transferOwnership` + `acceptOwnership`. See
  [`docs/ARCHITECTURE.md` §6.1](docs/ARCHITECTURE.md#61-the-complete-matrix)
- CI is structurally unable to broadcast: no secrets, no RPC URL, no key material,
  no fork cheatcodes, `GITHUB_TOKEN` restricted to `contents: read`

Known gaps are tracked honestly in
[`docs/ARCHITECTURE.md` §18](docs/ARCHITECTURE.md#18-known-gaps-and-open-decisions)
— including the residual `REGISTRAR_ROLE` above.

---

## License

The seven core contracts (`GyldAtomicSwap`, `GyldBondToken`, `IssuanceManager`,
`TokenFactory`, `NAVFeedForwarder`, `SanctionsOracleMirror`,
`KaleidoscopeNAVFeed`) and the `IERC1643` interface — eight files by SPDX scan —
are licensed under [Business Source License 1.1](LICENSE)
(`BUSL-1.1`). Source is available for review, testing and non-production use;
production use requires a commercial license from Gyld Finance until the Change
Date (2028-07-09), after which these files convert to `GPL-2.0-or-later`.

Files under `contracts/test/` and `contracts/script/` are **not** uniformly MIT:
22 are `UNLICENSED` (the test suites and most deploy scripts) and 7 are `MIT` (the
five test doubles plus the two mock deploy scripts). Per-file breakdown:
[`docs/ARCHITECTURE.md` §4.2](docs/ARCHITECTURE.md#42-licensing).
