# Smart Contracts

Foundry manages compilation and testing. The token stack is platform-written on top of
OpenZeppelin upgradeable contracts with a read-only, platform-operated sanctions oracle.

## Contract inventory

| Contract | File | Origin | Upgrade | Purpose |
|----------|------|--------|---------|---------|
| `GyldBondToken` | `contracts/GyldBondToken.sol` | Platform (BUSL-1.1) | UUPS | Standard ERC-20 per bond series; fixed balances; value reflected in NAV feed only; reads the configured platform sanctions oracle |
| `IssuanceManager` | `contracts/IssuanceManager.sol` | Platform (BUSL-1.1) | UUPS | AP whitelist; mint (subscribe) and burn (redeem) gate |
| `TokenFactory` | `contracts/TokenFactory.sol` | Platform (BUSL-1.1) | None (Ownable2Step) | Deploys GyldBondToken proxy + KaleidoscopeNAVFeed per bond series; wires roles atomically |
| `KaleidoscopeNAVFeed` | `contracts/KaleidoscopeNAVFeed.sol` | Platform (BUSL-1.1) | None | Push oracle — publishes bond NAV in AggregatorV3Interface format |
| `NAVFeedForwarder` | `contracts/NAVFeedForwarder.sol` | Platform (BUSL-1.1) | None | Permanent DeFi-facing oracle; delegates to swappable upstream |
| `SanctionsOracleMirror` | `contracts/SanctionsOracleMirror.sol` | Platform (BUSL-1.1) | None | Production sanctions oracle on **every** EVM chain including Ethereum mainnet (GYL-1051); keeper-fed local list plus an optional gas-capped, fail-closed `forwardingOracle`; Chainalysis-compatible interface |
| `GyldAtomicSwap` | `contracts/GyldAtomicSwap.sol` | Platform (BUSL-1.1) | UUPS | Self-custodial atomic USDC⇄bond settlement against platform-signed EIP-712 quotes; holds its own inventory (no vault); taker allowlist, single-use quotes, NAV sanity band |
| `MockSanctionsList` | `contracts/test/MockSanctionsList.sol` | Platform test (MIT) | None | Dev/test stub for the on-chain sanctions oracle |

> **Licence:** the seven core contracts above are **BUSL-1.1** — Licensor Gyld
> Finance, Change Date 2028-07-09, converting to `GPL-2.0-or-later`; see the
> repository `LICENSE`. Files under `contracts/test/` and `contracts/script/`
> (including `MockSanctionsList` and the deploy scripts) remain **MIT**.

---

## Architecture

```
TokenFactory (Ownable2Step — owner = TimelockController 48h)
    │  deployToken(name, symbol, isin, maturityTimestamp, operator, issuanceMgr, navFeedOwner)
    │
    ├─ ERC1967Proxy ──▶ GyldBondToken impl   (UUPS, ERC-7201 storage)
    │     │  initialize(name, symbol, isin, maturity, factory, factory, sanctionsList)
    │     │
    │     ├─ MINTER_ROLE + BURNER_ROLE → IssuanceManager
    │     ├─ PAUSER_ROLE               → operator
    │     └─ DEFAULT_ADMIN_ROLE        → factory.owner() = TimelockController
    │
    └─ KaleidoscopeNAVFeed (Ownable — owner = navFeedOwner / KMS signer)

IssuanceManager (ERC1967Proxy ──▶ impl, UUPS, ERC-7201 storage)
    │  initialize(defaultAdmin, issuer)
    │  defaultAdmin should be a TimelockController
    │
    ├─ SUBSCRIBER_ROLE      → platform MPC / Fordefi wallet (mint path)
    ├─ REDEEMER_ROLE        → platform MPC / Fordefi wallet (burn path)
    ├─ WHITELIST_ADMIN_ROLE → ops multisig
    └─ REGISTRAR_ROLE       → TokenFactory (granted by factory at deployToken time)

KaleidoscopeNAVFeed  ←── owner calls updateAnswer(int256)
    └─▶ NAVFeedForwarder ──▶ setUpstreamOracle()
              └─▶ DeFi protocols (Morpho, Aave, etc.)

SanctionsOracleMirror (platform sanctions oracle on each production EVM chain,
                       including Ethereum mainnet)
    ├─ SANCTIONS_UPDATER_ROLE → keeper bot (polls approved sanctions feeds, writes deltas)
    ├─ DEFAULT_ADMIN_ROLE     → compliance ops multisig
    ├─ forwardingOracle (optional) ─▶ vendor oracle, e.g. Chainalysis mainnet
    │                                  0x40C57923924B5c5c5455c48D93317139ADDaC8fb
    │                                  gas-capped staticcall; fail-closed; address(0) disables
    └─▶ GyldBondToken._requireAccess()  ← Chainalysis-compatible interface; fail-closed behaviour
```

---

## GyldBondToken

Standard ERC-20 per bond series. **Token balances are fixed units of bond ownership —
one token represents one unit of the underlying bond.**

Value accrual (coupons, NAV appreciation) is reflected exclusively in the paired
`KaleidoscopeNAVFeed` oracle. Token balances only change through `mint` (subscription)
and `burn` (redemption). There is no on-chain rebasing or multiplier mechanism.

### Balance model

```
balanceOf(account) = exactly what was minted to account minus what was burned
totalSupply()      = sum of all balances (exact, no rounding)
```

When a coupon arrives from the broker, the backend records it in `LedgerRepo` and
pushes an updated NAV price to the `KaleidoscopeNAVFeed`. The token balance is
unchanged. DeFi protocols compute portfolio value as `balanceOf × NAV price`.

### Roles

| Role | Holder | Capability |
|------|--------|-----------|
| `DEFAULT_ADMIN_ROLE` | TimelockController (prod) | Grant/revoke all roles; authorize UUPS upgrades |
| `MINTER_ROLE` | IssuanceManager only | `mint(address to, uint256 amount)` |
| `BURNER_ROLE` | IssuanceManager only | `burn(address from, uint256 amount)` |
| `PAUSER_ROLE` | Ops multisig | `pause()` / `unpause()` |

### Compliance

All secondary transfers (`transfer`, `transferFrom`) check sender, receiver, **and spender**
(transferFrom) against the configured on-chain sanctions oracle — the platform-operated
`SanctionsOracleMirror` on every production chain (see
`docs/decisions/sanctions-oracle-mirror.md` in the root repo).

The check is **fail-closed** — if the oracle call itself reverts (e.g., oracle down),
the transfer reverts. No role or owner bypasses this check for secondary transfers.

Mint and burn skip the oracle check. IssuanceManager pre-screens APs off-chain before calling.

Sanctioned addresses are frozen in place by the oracle — all transfers to/from them revert automatically. No on-chain recovery function exists; platform escalates off-chain if legal action requires token movement.

### Bond metadata (on-chain, immutable after initialize)

| Field | Getter | Example |
|-------|--------|---------|
| `isin()` | `string` | `"US912797KR72"` |
| `maturityTimestamp()` | `uint256` | `1788739200` (2028-09-06) |

### Storage layout

ERC-7201 namespace `gyld.GyldBondToken`  
Slot: `0x0fe35ba304a016e79d78a184eb899c1e21310138e0bfe9a54648a2dfe0da0d00`

### Upgradeability

`_authorizeUpgrade` is gated by `DEFAULT_ADMIN_ROLE`. In production DEFAULT_ADMIN is
a `TimelockController`, so upgrades enforce the 48h delay.

---

## IssuanceManager

Single gate for primary issuance and redemption of all Gyld bond series.

### Mint (subscribe) flow

```
1. Backend confirms USDC received from whitelisted AP source.
2. Backend calls subscribe(token, recipient, amount)
3. IssuanceManager checks: registeredTokens[token] && whitelisted[recipient] && amount > 0
4. Calls token.mint(recipient, amount)  [has MINTER_ROLE]
5. Emits Subscribed(token, recipient, amount)
```

### Redeem flow

```
1. AP transfers bond tokens to IssuanceManager address.
2. Backend confirms receipt + whitelisted identity.
3. Backend calls redeem(token, beneficiary, amount)
4. IssuanceManager checks: registeredTokens[token] && whitelisted[beneficiary]
5. Calls token.burn(address(this), amount)  [has BURNER_ROLE]
6. Emits Redeemed(token, beneficiary, amount)
7. Backend sends USDC/USD to customer off-chain.
```

### Whitelist population — KYC bridge

Addresses enter the whitelist only after KYC approval. The `WHITELIST_ADMIN_ROLE`
holder (ops multisig) calls `addToWhitelist(wallet)` once the user's
`token_recipient_address` is known and their `KycCase` is in the `APPROVED` state.
This is a manual operational step — KYC approval in the backend database does **not**
automatically update the on-chain whitelist.

See the **KYC approval → on-chain whitelist** section in `docs/architecture.md`
for the full trigger conditions, timing, and removal procedure.

### Roles

| Role | Holder | Capability |
|------|--------|-----------|
| `DEFAULT_ADMIN_ROLE` | TimelockController (prod) | Grant/revoke roles; authorize UUPS upgrades |
| `SUBSCRIBER_ROLE` | Platform MPC / Fordefi wallet (mint) | `subscribe()` |
| `REDEEMER_ROLE` | Platform MPC / Fordefi wallet (burn) | `redeem()` |
| `WHITELIST_ADMIN_ROLE` | Ops multisig (prod); deployer EOA (dev/Hoodi) | `addToWhitelist()`, `removeFromWhitelist()`, `addToWhitelistBatch()` |
| `REGISTRAR_ROLE` | TokenFactory | `registerToken()`, `deregisterToken()` |

`WHITELIST_ADMIN_ROLE` is **not** granted during `initialize()` — it must be
assigned explicitly after deployment by whoever holds `DEFAULT_ADMIN_ROLE` at
that point (the deployer EOA, before ownership is handed to the TimelockController).
`DeployDevNet.s.sol` grants it to the deployer EOA (or `WHITELIST_ADMIN` env var)
for local dev / Hoodi convenience.

`addToWhitelistBatch(addresses[])` is the preferred path when activating a
cohort of KYC-approved users at once (e.g. after a batch KYC review session).
Use `addToWhitelist(address)` for single activations. Both revert atomically
if any address in the call is `address(0)`.

### Storage layout

ERC-7201 namespace `gyld.IssuanceManager`  
Slot: `0xc8552dd465c7174389604c2ad1f48bf21d46f65ee8d42bbd0456923afc111000`

---

## TokenFactory

Deployment adapter. Deploys a `(GyldBondToken proxy, KaleidoscopeNAVFeed)` pair
per bond instrument and wires roles atomically in a single transaction.

### deployToken flow

```
deployToken(name, symbol, isin, maturityTimestamp, operator, issuanceMgr, navFeedOwner)
    │
    ├─ Deploy GyldBondToken proxy (CREATE2, salt = keccak256("token" ++ keccak256(isin ++ chainId)))
    │       calls initialize(name, symbol, isin, maturityTimestamp, factory, factory, sanctionsList)
    │
    ├─ Grant MINTER_ROLE + BURNER_ROLE    → issuanceMgr
    ├─ Grant PAUSER_ROLE → operator
    ├─ Grant DEFAULT_ADMIN_ROLE          → factory.owner() (TimelockController in prod)
    ├─ Revoke PAUSER_ROLE from factory
    ├─ Revoke DEFAULT_ADMIN_ROLE from factory  (factory self-revokes; holds no permanent power)
    │
    ├─ Deploy KaleidoscopeNAVFeed (owner = navFeedOwner, desc = "<symbol> / USD NAV")
    │
    ├─ IssuanceManager.registerToken(token)    [factory holds REGISTRAR_ROLE]
    │
    └─ emit TokenDeployed(token, navFeed, issuanceMgr)
```

### Address determinism

Token addresses are deterministic before deployment:

```solidity
bondSalt   = keccak256(abi.encodePacked(isin, block.chainid))
tokenSalt  = keccak256(abi.encodePacked("token", bondSalt))
```

Use `factory.predictTokenAddress(name, symbol, isin, maturityTimestamp)` to compute the token
address before calling `deployToken`.

### Governance

The factory `owner` should be a `TimelockController` (48h minimum delay in production).
`deployToken` is `onlyOwner` — new bond series require a timelocked governance vote.

### Role cleanup — automatic

`_wireRoles` self-revokes `DEFAULT_ADMIN_ROLE` and `PAUSER_ROLE` from the factory at the
end of every `deployToken` call. After deployment the factory holds **no permissions** on
any token it has created. No manual cleanup is required.

---

## KaleidoscopeNAVFeed

Platform push oracle. Owner (KMS signer) calls `updateAnswer(int256)` once per market day.
Implements `AggregatorV3Interface` for DeFi protocol compatibility.

**Formula:** `NAV per token = (bonds_held × bond_price_usd) / tokens_outstanding` — 8 decimals.

**Safety constraints:**

| Constant | Value | Purpose |
|----------|-------|---------|
| `MAX_STALENESS` | 96 hours | Monitoring threshold for `isFresh()`. Reads do NOT revert on staleness — returns last known NAV (Chainlink/Ondo model). Covers 3-day US holiday weekends. |
| `MIN_UPDATE_INTERVAL` | 1 hour | Prevents rapid price oscillation from a compromised KMS key |
| `MAX_PRICE_DEVIATION_BPS` | 1000 (10%) | Single-update deviation cap after first push |

**Emergency price correction:**

If a wrong price is pushed within the 10 % band, `MIN_UPDATE_INTERVAL` and
`MAX_PRICE_DEVIATION_BPS` together can make the correction unreachable in one step
(the correct value is > 10 % from the wrong baseline). `emergencyUpdateAnswer` bypasses
both guards for exactly this scenario.

| Function | Caller | Bypasses |
|----------|--------|---------|
| `updateAnswer(int256)` | owner (KMS signer) | — |
| `emergencyUpdateAnswer(int256)` | `emergencyUpdater` (Gnosis Safe multisig) | `MIN_UPDATE_INTERVAL` + `MAX_PRICE_DEVIATION_BPS` |

**Key separation is mandatory.** The `emergencyUpdater` must be a different key from the
KMS owner. `MAX_PRICE_DEVIATION_BPS` exists specifically to limit damage from a compromised
KMS key — if both functions shared the same key that protection would be removed.
Set via `setEmergencyUpdater(address)` (onlyOwner). Pass `address(0)` to disable the path.

`emergencyUpdateAnswer` emits `EmergencyAnswerUpdated` (not `AnswerUpdated`) so monitoring
rules can alert on any use. Every use should trigger an immediate ops review.

---

## NAVFeedForwarder

Permanent DeFi-facing oracle address. Delegates all reads to a swappable upstream oracle.
Owner calls `setUpstreamOracle(address)` to upgrade the data source without redeploying DeFi markets.

**Upgrade path:**

| Phase | Upstream | When |
|-------|----------|------|
| 1 | `KaleidoscopeNAVFeed` (platform push) | Launch |
| 2 | RedStone Classic feed | Weeks after launch |
| 3 | Chainlink NAVLink feed | Institutional grade |

---

## GyldAtomicSwap

Self-custodial atomic settlement of USDC ⇄ bond-token swaps against
platform-signed EIP-712 quotes. **The contract holds its own inventory** —
`executeSwap` pulls `tokenIn` from the taker and pushes `tokenOut` out of its
own balance. There is no settlement vault and no escrow contract; earlier
vault/DvP designs were removed.

The normative spec is [`docs/atomic-swap-spec.md`](atomic-swap-spec.md); the
third-party integrator guide is
[`docs/integration/onchain-atomic-swap.md`](integration/onchain-atomic-swap.md).
Deploy script: `contracts/script/DeployAtomicSettlement.s.sol` (env vars in
`.env.example`).

### Quote model

- Quotes are signed off-chain by a `QUOTE_SIGNER_ROLE` key (the role registry
  *is* the signer set) over a capped-allowance `SwapMessage`:
  `{quoteId, taker, tokenIn, maxAmountIn, tokenOut, price, expiry, epoch}`.
- EIP-712 domain: `("GyldAtomicSwap", "2")` + chainId + **proxy** address.
- `maxAmountIn` is a ceiling; the taker picks `requestedAmountIn` at execution
  (1% dust floor), and `amountOut = requestedAmountIn * price / 1e18` floors in
  the contract's favour. First use burns the `quoteId` in full — single-shot,
  no partial-balance carry-over.
- The signed price is what executes; the series' NAV feed is only a sanity band
  (`maxQuoteDeviationBps`), fail-closed on a stale or non-positive NAV.

### Roles

| Role | Holder | Capability |
|------|--------|-----------|
| `DEFAULT_ADMIN_ROLE` | TimelockController (prod) | Upgrades, unpause, series registry, band/age params, withdrawal wallet, epoch bumps, role grants. Cannot be renounced |
| `ALLOWLIST_ADMIN_ROLE` | Compliance ops hot key | `setAllowed()` — the taker allowlist, **only**. Deliberately split from admin (GYL-1050) so allowlisting stays a same-day operational action after the timelock handover |
| `QUOTE_SIGNER_ROLE` | Quote-service KMS key(s) | Passive — checked via `hasRole` against the recovered EIP-712 signer |
| `TREASURER_ROLE` | Ops MPC wallet | `withdraw()` inventory — only to the admin-fixed withdrawal wallet; deliberately live while paused |
| `PAUSER_ROLE` | Ops multisig | `pause()` only; resuming requires the admin |

### Deployments

| Network | Chain ID | Address | Status |
|---------|----------|---------|--------|
| Ethereum Sepolia | 11155111 | — | ⏳ **Pending — deployment in progress.** The single supported public testnet for integrator testing |
| Local Anvil | 31337 | — | Local development only (ephemeral) |

### Storage layout

ERC-7201 namespace `gyld.GyldAtomicSwap`  
Slot: `0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300`

---

## Deployment scripts

| Script | Purpose |
|--------|---------|
| `script/DeployDevNet.s.sol` | Full stack to Anvil or Hoodi — deploys impl contracts, proxies, MockSanctionsList, 3 dev bond tokens |
| `script/DeployTimelock.s.sol` | Deploys TimelockController, transfers factory ownership + IssuanceManager DEFAULT_ADMIN |
| `script/DeployNAVFeed.s.sol` | Standalone NAVFeed + Forwarder deployment |
| `script/DeployMockUSDC.s.sol` | Mock USDC for local dev |

### DeployDevNet example

```bash
anvil &
forge script contracts/script/DeployDevNet.s.sol \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key ANVIL_TEST_KEY_REDACTED
```

Outputs `EVM_FACTORY_ADDRESS`, `EVM_ISSUANCE_MANAGER`, `TOKEN_CAT`, `TOKEN_C`, `TOKEN_KO`.

---

## Test suite

```
contracts/test/
├── IssuanceManager.t.sol           — 30 tests  (subscribe, redeem, whitelist, registry, role isolation, UUPS)
├── TokenFactory.t.sol              — 48 tests  (deploy, roles, mint, burn, pause, sanctions compliance, CREATE2 predict; includes GyldBondTokenUnitTest suite)
├── KaleidoscopeNAVFeed.t.sol       — 36 tests  (updateAnswer, deviation, staleness, round ID)
├── NAVFeedForwarder.t.sol          — 22 tests  (delegation, upgrade scenario, access control)
├── Timelock.t.sol                  — 15 tests  (48h delay enforcement, cancel, IssuanceManager admin wiring)
├── GyldBondToken.invariants.t.sol  — 14 tests  (3 invariants + 11 fuzz tests — plain ERC20 supply accounting + sanctions)
└── SanctionsOracleMirror.t.sol    — 25 tests  (constructor, add/remove, events, access control, role management, fuzz round-trip)
```

Foundry commands:

```sh
forge build               # compile
forge test                # run all tests
forge test -v             # with event logs
forge test --match-contract IssuanceManager   # single suite
forge coverage            # coverage report
```

`foundry.toml` remappings:

```toml
remappings = [
    "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
    "@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/",
    "forge-std/=lib/forge-std/src/",
]
```
