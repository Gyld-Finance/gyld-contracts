# gyld-contracts

On-chain smart contracts for the Gyld tokenized bond platform. One ERC-20 token per bond series, backed 1:1 by securities held in custody off-chain. The [Kaleidoscope](https://github.com/Gyld-Finance/kaleidoscope) backend orchestrates mint and redemption workflows; these contracts enforce compliance and finality on-chain.

**Primary chain: Ethereum mainnet.** Solidity `0.8.28`, compiled with Foundry.

---

## Architecture

```
                    ┌──────────── DeFi integrations ─────────────┐
                    │                                             │
                    │   Morpho Blue       Aave V3       ERC4626   │
                    │       │               │             │       │
                    │       └───────────────┴──────────── ┤       │
                    │                       │             │       │
                    │             NAVFeedForwarder   GyldBondToken │
                    │             (stable addr)      (ERC-20 asset)│
                    └───────────────────────┬─────────────────────┘
                                            │
                              KaleidoscopeNAVFeed
                              (NAV oracle, push model)
                                            │
                    ┌───────── Platform layer ────────────────────┐
                    │                                             │
                    │   TokenFactory          IssuanceManager     │
                    │   (deploy + wire)       (mint gate)         │
                    │        │                     │              │
                    │   GyldBondToken proxy    whitelist (APs)    │
                    │   (per bond series)           │              │
                    │        │           SanctionsOracleMirror    │
                    │        └───────────────(on-chain sanctions) │
                    └─────────────────────────────────────────────┘
                                            │
                    ┌──────── Kaleidoscope backend ───────────────┐
                    │  KYC · Broker · Settlement · NAV updates    │
                    └─────────────────────────────────────────────┘
```

---

## Contracts

| Contract | Purpose |
|---|---|
| `GyldBondToken` | ERC-20 per bond series. UUPS-upgradeable. On-chain sanctions check against the configured platform oracle on every transfer. Pausable by ops multisig. |
| `IssuanceManager` | Single mint/burn gate for all bond series. Only whitelisted Authorised Participants (APs) may receive minted tokens or be recorded as redemption beneficiaries. |
| `TokenFactory` | Deploys a `(GyldBondToken proxy, KaleidoscopeNAVFeed, NAVFeedForwarder)` triple atomically and wires all roles in one transaction. |
| `KaleidoscopeNAVFeed` | Chainlink `AggregatorV3Interface`-compatible NAV oracle. The Kaleidoscope backend pushes daily NAV prices here. 10% max deviation guard, 1-hour min update interval. |
| `NAVFeedForwarder` | Permanent, stable oracle address that forwards price reads to an upgradeable upstream oracle. DeFi protocols (Morpho, Aave) point at this — never at `KaleidoscopeNAVFeed` directly. |
| `SanctionsOracleMirror` | The platform sanctions oracle on **every** production EVM chain, including Ethereum mainnet (GYL-1051). A keeper bot syncs OFAC deltas every 4 hours into its local list; an optional gas-capped, fail-closed `forwardingOracle` can chain to a vendor oracle. |

---

## Role Architecture

```
DEFAULT_ADMIN_ROLE  →  TimelockController (48 h delay in production)
                         ├─ grants / revokes all other roles
                         └─ authorises UUPS upgrades (GyldBondToken)

MINTER_ROLE         →  IssuanceManager (exclusively)
BURNER_ROLE         →  IssuanceManager (exclusively)
PAUSER_ROLE         →  Ops multisig hot wallet (no delay — emergency pause)

WHITELIST_ADMIN_ROLE → Compliance ops multisig
SUBSCRIBER_ROLE     →  MPC wallet A  (subscribe / mint path only)
REDEEMER_ROLE       →  MPC wallet B  (redeem / burn path only)
REGISTRAR_ROLE      →  TokenFactory  (self-revokes post-deployment)

KaleidoscopeNAVFeed.owner  →  KMS signer  (pushes daily NAV)
NAVFeedForwarder.owner     →  TimelockController  (oracle provider swaps)
```

TokenFactory holds `DEFAULT_ADMIN_ROLE` and `REGISTRAR_ROLE` only during deployment and self-revokes both before returning. It holds no permanent permissions post-deploy.

---

## Deployment Flow (per bond series)

```
1. Deploy IssuanceManager (once, shared across all series)
2. Deploy TokenFactory    (once, shared across all series)
3. Grant REGISTRAR_ROLE on IssuanceManager → TokenFactory
4. Call TokenFactory.deployToken(name, symbol, isin, maturity, operator, issuanceManager, navFeedOwner)
   └─ deploys GyldBondToken proxy  (deterministic CREATE2 address from ISIN + chainId)
   └─ deploys KaleidoscopeNAVFeed  (backend pushes NAV here)
   └─ deploys NAVFeedForwarder     (DeFi integrations point here permanently)
   └─ wires all roles atomically
   └─ registers token in IssuanceManager
5. Point Morpho Blue / Aave V3 oracle at NAVFeedForwarder address
```

Token addresses are deterministic: `TokenFactory.predictTokenAddress()` returns the proxy address before deployment. The ISIN is used as the CREATE2 salt — duplicate ISINs are rejected on-chain.

---

## Compliance Model

- **Sanctions check:** Every `transfer` and `transferFrom` on `GyldBondToken` calls the configured on-chain sanctions oracle (the platform `SanctionsOracleMirror`). Fail-closed — if the oracle reverts, the transfer reverts. Mint and burn skip the oracle; the Kaleidoscope backend screens APs off-chain before calling `subscribe` / `redeem`.
- **Pause:** `PAUSER_ROLE` (ops multisig) can halt all token movement immediately. Pause stops mint, burn, transfer, approve, and permit.
- **AP whitelist:** Only whitelisted addresses may receive primary issuance or be the recorded beneficiary of a redemption. Secondary ERC-20 transfers have no whitelist restriction.
- **No internal blocklist:** The token carries no blocked-address mapping; sanctions decisions are delegated entirely to the configured on-chain oracle — the platform-operated `SanctionsOracleMirror`, which mirrors approved OFAC/SDN data and never adds addresses at platform discretion. To rotate oracle contracts, call `GyldBondToken.setSanctionsList()` (timelock-gated).

---

## Quickstart

```sh
# Build
forge build

# Test (10 000 fuzz runs per suite)
forge test

# Deploy to local devnet
forge script contracts/script/DeployDevNet.s.sol --broadcast

# Deploy Timelock (production prerequisite)
forge script contracts/script/DeployTimelock.s.sol --broadcast --rpc-url $RPC_URL
```

Prerequisites: [Foundry](https://getfoundry.sh) installed, `ETHERSCAN_API_KEY` set for verification.

---

## Tests

| Test file | Coverage |
|---|---|
| `GyldBondToken.t.sol` | Transfer, sanctions, pause, permit, role management |
| `GyldBondToken.invariants.t.sol` | Supply invariants under fuzz |
| `IssuanceManager.t.sol` | Subscribe, redeem, whitelist, token registry |
| `KaleidoscopeNAVFeed.t.sol` | Price updates, deviation guard, interval guard, staleness |
| `NAVFeedForwarder.t.sol` | Oracle forwarding, upstream swap, probe validation |
| `SanctionsOracleMirror.t.sol` | Add/remove sanctions, role separation |
| `TokenFactory.t.sol` | Atomic deployment, CREATE2 address prediction, role wiring |
| `Timelock.t.sol` | Delay enforcement, cancellation |

---

## Docs

| Document | Contents |
|---|---|
| `docs/architecture.md` | Full system architecture |
| `docs/contracts.md` | Deployed addresses (Hoodi testnet + mainnet) |
| `docs/erc4626-compatibility.md` | ERC4626 wrapper compatibility analysis, vault share mechanics |
| `docs/morpho-integration.md` | Morpho Blue market setup and oracle wiring |
| `docs/euler-integration.md` | Euler V2 lending integration |
| `docs/aave-v3-listing.md` | Aave V3 listing checklist |
| `docs/decisions/` | Design decision records (sanctions oracle, token design, deferred integrations) |

---

## Security

- All contracts compiled with `via_ir = true`, `optimizer_runs = 200`
- OpenZeppelin contracts-upgradeable v5 (ERC-7201 namespaced storage)
- UUPS upgrade path requires TimelockController in production (48-hour recommended delay)

---

## License

Core protocol contracts (`GyldAtomicSwap`, `GyldBondToken`, `IssuanceManager`,
`TokenFactory`, `NAVFeedForwarder`, `SanctionsOracleMirror`,
`KaleidoscopeNAVFeed`) are licensed under [Business Source
License 1.1](LICENSE) (`BUSL-1.1`). Source is available for review, testing,
and non-production use; production use requires a commercial license from
Gyld Finance until the Change Date (2028-07-09), after which these files
convert to `GPL-2.0-or-later`. Test and deployment-script files under
`contracts/test/` and `contracts/script/` remain `MIT`.
