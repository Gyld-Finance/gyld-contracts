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
| `KaleidoscopeNAVFeed` | None (`Ownable2Step`) | Chainlink `AggregatorV3Interface`-compatible NAV oracle, 8 decimals. The backend pushes NAV here. 10 % max deviation per update, 1-hour minimum interval, plus a separate-key emergency override. |
| `NAVFeedForwarder` | None (`Ownable2Step`) | Permanent, stable oracle address that forwards reads to a swappable upstream. DeFi protocols point here — **never** at `KaleidoscopeNAVFeed` directly. |
| `SanctionsOracleMirror` | None | The platform sanctions oracle on **every** production EVM chain, Ethereum mainnet included (GYL-1051). A keeper bot syncs OFAC deltas into its local list; an optional gas-capped, fail-closed `forwardingOracle` can chain to a vendor oracle. |
| `GyldAtomicSwap` | UUPS | Self-custodial atomic USDC⇄bond settlement against platform-signed EIP-712 quotes. **Holds its own inventory** — there is no vault. Taker binding, taker allowlist, single-use quotes, NAV sanity band. |

---

## Role architecture

```
DEFAULT_ADMIN_ROLE   →  TimelockController (48 h minimum in production)
                          ├─ grants / revokes all other roles
                          └─ authorises UUPS upgrades

MINTER_ROLE          →  IssuanceManager (exclusively — never an EOA)
BURNER_ROLE          →  IssuanceManager (exclusively)
PAUSER_ROLE          →  Ops multisig hot wallet (no delay — emergency pause)
DOCUMENT_ROLE        →  Ops multisig (IERC-1643 document set/remove — operational, no delay; GLD-264)

WHITELIST_ADMIN_ROLE →  Compliance ops multisig
SUBSCRIBER_ROLE      →  MPC wallet A  (subscribe / mint path only)
REDEEMER_ROLE        →  MPC wallet B  (redeem / burn path only — must differ from A)
REGISTRAR_ROLE       →  TokenFactory

KaleidoscopeNAVFeed.owner       →  KMS signer (pushes NAV)
KaleidoscopeNAVFeed.emergencyUpdater → Ops Safe; contract-enforced ≠ owner()
NAVFeedForwarder.owner          →  TimelockController (oracle provider swaps)
TokenFactory.owner              →  TimelockController
```

`TokenFactory._wireRoles` self-revokes `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` from
the factory **on each token it deploys**, so it holds no permissions on any token
afterwards.

> **It does not revoke `REGISTRAR_ROLE`.** That role lives on the `IssuanceManager`,
> and the factory keeps it permanently — there is no `revokeRole` for it in the
> contract or in any deploy script, and on any stack deployed by the factory
> `hasRole(REGISTRAR_ROLE, factory) == true`. An earlier version of this README
> claimed the factory "self-revokes both" and holds "no permanent permissions
> post-deploy"; that was false and should not be relied on in a threat model. See
> [`docs/ARCHITECTURE.md` §5.3 and §19.1](docs/ARCHITECTURE.md).

The complete matrix — every role, what it gates, who should hold it, whether it is
renounceable, and what a compromise of each buys — is
[`docs/ARCHITECTURE.md` §6](docs/ARCHITECTURE.md).

---

## Deployment flow (per bond series)

```
1. Deploy SanctionsOracleMirror     (once per chain)
2. Deploy IssuanceManager           (once, shared across all series)
3. Deploy GyldBondToken implementation + TokenFactory
4. Grant REGISTRAR_ROLE on IssuanceManager → TokenFactory
5. Deploy TimelockController (delay >= 48 h) and hand over:
     IssuanceManager DEFAULT_ADMIN_ROLE → timelock  (deployer revoked)
     TokenFactory ownership             → timelock  (2-step; timelock must accept)
6. Via the timelock: TokenFactory.deployToken(name, symbol, isin, maturity,
                                             operator, issuanceManager, navFeedOwner)
     ├─ GyldBondToken proxy      (CREATE2 from keccak256("token" ++ keccak256(isin ++ chainId)))
     ├─ KaleidoscopeNAVFeed      (owner = navFeedOwner / KMS signer)
     ├─ NAVFeedForwarder         (owner = factory.owner() = timelock)
     ├─ wires the token's roles, self-revoking its own
     └─ registers the token in IssuanceManager
7. Push the first NAV, then point Morpho Blue / Euler / Aave at NAVFeedForwarder
```

**Ordering matters:** factory ownership must move to the timelock *before*
`deployToken`, because `_wireRoles` grants `DEFAULT_ADMIN_ROLE` on each token to
`owner()` as it is at that moment. Deploy first and the deployer EOA becomes the
token admin permanently.

Token addresses are deterministic — `TokenFactory.predictTokenAddress()` returns the
proxy address before deployment. The CREATE2 salt is derived from the ISIN **and**
`block.chainid`, and a separate `_deployedIsins` registry rejects any repeat
deployment of the same ISIN regardless of name, symbol or maturity.

**Deploy scripts fail closed (GYL-1135).** Dev chains are an *allowlist* — Anvil
31337 and Ethereum Sepolia 11155111 only. Every other chain, including ones that do
not exist yet, takes the strict path: required env vars, no privileged address equal
to the deployer, a 48 h minimum timelock delay, and in-band post-deploy topology
assertions that abort the deployment on a mismatch. See
[`docs/ARCHITECTURE.md` §13](docs/ARCHITECTURE.md) and `.env.example`.

---

## Compliance model

- **Sanctions:** every `transfer` / `transferFrom` on `GyldBondToken` screens sender,
  receiver **and spender** against the configured on-chain oracle. Fail-closed — if
  the oracle reverts, the transfer reverts. No role bypasses this; the contract uses
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

---

## Quickstart

```sh
forge build                 # compile (via_ir, optimizer_runs = 200)
forge test                  # 535 tests, 20 suites; fuzz runs = 10000
forge test -vvv             # traces for failures
forge coverage

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

`forge test` — 535 tests across 20 suites, all at full `foundry.toml` intensity.

| Test file | Coverage |
|---|---|
| `GyldAtomicSwap.t.sol` | Quote execution both directions, expiry, epoch, replay, signer, taker binding, allowlist, permit, pause, withdrawal |
| `GyldAtomicSwap.spec.t.sol` | The numbered invariant / finding catalogue (I-1…I-24, F-1…F-7) |
| `GyldAtomicSwap.invariants.t.sol` | Stateful: never-mints, single-use quotes, fair-price rounding |
| `GyldAtomicSwap.halmos.t.sol` | Halmos symbolic verification of I-1, I-2, I-3, I-10, I-11 (`check_` prefix; `forge test` skips these) |
| `GyldBondToken.t.sol` | Transfer, sanctions, pause, permit, role management, storage slot-pinning, UUPS upgrade, IERC-1643 document management |
| `GyldBondToken.invariants.t.sol` | Supply invariants under fuzz |
| `IssuanceManager.t.sol` | Subscribe, redeem, whitelist, token registry, role isolation, UUPS |
| `KaleidoscopeNAVFeed.t.sol` | Price updates, deviation guard, interval guard, emergency updater + key separation, and `test_noStalenessRevertPathExists` |
| `NAVFeedForwarder.t.sol` | Oracle forwarding, upstream swap, probe validation, future-dated rejection |
| `SanctionsOracleMirror.t.sol` | Add/remove, role separation, forwarding-oracle probe and gas cap |
| `TokenFactory.t.sol` | Atomic deployment, CREATE2 prediction, role wiring, `REGISTRAR_ROLE` preflight, duplicate-ISIN rejection |
| `Timelock.t.sol` | Delay enforcement, cancellation |
| `AtomicSettlementDeploy.t.sol`, `DeployScripts.t.sol` | Deploy scripts including the fail-closed guards; `DeployMockUSDCTest` covers the dev-chain allowlist on `DeployMockUSDC` — refused on every production chain and on Base Sepolia, still funds the Anvil accounts on a dev chain |

---

## Docs

The doc set is deliberately small — four files under `docs/`, plus `DEPLOYMENTS.md`
at the root.

| Document | Contents |
|---|---|
| [`DEPLOYMENTS.md`](DEPLOYMENTS.md) | **The authoritative on-chain address register.** The only place an address is canonical; if a contract is not listed there, do not send funds to it, approve it or wire it into a config. |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | **The authoritative reference.** Every contract, the complete role and permission matrix, custody and loss ceilings, value accrual, both settlement flows, compliance, oracle design, deployment model, deployed addresses, Morpho / Euler / Aave / ERC-4626 integration parameters, the verification surface, the decision record, known gaps, and a log of documentation claims found false against the code. |
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
- `DEFAULT_ADMIN_ROLE` is non-renounceable on every contract that has it; on
  `GyldAtomicSwap`, `PAUSER_ROLE` and `TREASURER_ROLE` stay renounceable
  deliberately (see `docs/ARCHITECTURE.md` §6.1). `KaleidoscopeNAVFeed` has no
  roles — its `renounceOwnership()` reverts instead, on newly deployed feeds
- CI is structurally unable to broadcast: no secrets, no RPC URL, no key material,
  no fork cheatcodes, `GITHUB_TOKEN` restricted to `contents: read`

Known gaps are tracked honestly in
[`docs/ARCHITECTURE.md` §18](docs/ARCHITECTURE.md) — including the residual
`REGISTRAR_ROLE` above. The two Base mainnet gaps (a stale NAV feed and a stack still
carrying the GYL-1135 incident configuration) are **closed**: that demo deployment was
retired and its address records removed (GLD-148).

---

## License

Core protocol contracts (`GyldAtomicSwap`, `GyldBondToken`, `IssuanceManager`,
`TokenFactory`, `NAVFeedForwarder`, `SanctionsOracleMirror`,
`KaleidoscopeNAVFeed`) are licensed under [Business Source License 1.1](LICENSE)
(`BUSL-1.1`). Source is available for review, testing and non-production use;
production use requires a commercial license from Gyld Finance until the Change
Date (2028-07-09), after which these files convert to `GPL-2.0-or-later`.

Files under `contracts/test/` and `contracts/script/` are **not** uniformly MIT, as
an earlier version of this README stated: 22 are `UNLICENSED` (the test suites and
most deploy scripts) and 7 are `MIT` (the five test doubles plus the two mock deploy
scripts). Per-file breakdown:
[`docs/ARCHITECTURE.md` §4.2](docs/ARCHITECTURE.md).
