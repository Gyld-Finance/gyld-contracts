# Atomic Settlement — Testnet Deployment Runbook

Deployment runbook and readiness assessment for taking the **self-custodial**
`GyldAtomicSwap` stack to a public testnet. Written against commit `3507f1b`
(398 Forge tests passing).

**Architecture note — read this before anything else.** `GyldAtomicSwap` is
self-custodial: it holds its own inventory (USDC + bond tokens) and settles
platform-signed EIP-712 quotes against that inventory (`contracts/GyldAtomicSwap.sol`,
contract NatSpec lines 20–28). The former `GyldSettlementVault`, `GyldDvpEscrow`, and
`DeployDvpEscrow.s.sol` were **deleted** in GYL-548 (commit `5c1a1f4`). There is no
vault to deploy, and no `SWAP_ROLE` handover to a vault. Any older doc or memory that
mentions a vault describes the dead architecture. Contracts are **BUSL-1.1** licensed
(commit `15bbdfa`).

---

## 1. Current deployment reality

Derived from `broadcast/` at `3507f1b`. **No public-network deployment of
`GyldAtomicSwap` exists anywhere.** The swap stack has only ever been broadcast to
local Anvil.

| Network | Chain ID | What IS deployed | What is NOT deployed | Source broadcast dir |
|---|---|---|---|---|
| Local Anvil | 31337 | Full stack incl. `GyldAtomicSwap` (`DeployAtomicSettlement`, `AtomicSettlementFlow`, `DeployAtomicSettlementE2E`, `DeployDevNet`, `DeployMockUSDC`) | — (ephemeral; gone on Anvil restart) | `broadcast/DeployAtomicSettlement.s.sol/31337` et al. |
| Sepolia | 11155111 | Older token stack only, from `DeployDevNet.s.sol` (May 2026 run): TimelockController, IssuanceManager proxy, TokenFactory, MockSanctionsList, three bond series (CAT / C / KO) — addresses below | **`GyldAtomicSwap` — not deployed** | `broadcast/DeployDevNet.s.sol/11155111` |
| Base **MAINNET** | 8453 | Euler/Morpho listing experiment: `DeployBaseTest.s.sol` + `DeployEulerStep1..6.s.sol` | **`GyldAtomicSwap` — not deployed** | `broadcast/DeployBaseTest.s.sol/8453`, `broadcast/DeployEulerStep*/8453` |

> **Warning — 8453 is Base MAINNET, not a testnet.** The script is named
> `DeployBaseTest.s.sol` and that name has already misled people. Anything broadcast
> to chain 8453 spends real ETH on a production chain. Base **Sepolia** would be
> chain 84532, for which no broadcast exists.

> **Stale broadcast dir:** `broadcast/DeployDvpEscrow.s.sol/31337` still exists even
> though the escrow contract and its deploy script were deleted in GYL-548. It is
> history only — do not treat it as a deployable artifact.

### Sepolia (11155111) recorded addresses

From `broadcast/DeployDevNet.s.sol/11155111/run-latest.json`. The bond-token triples
were created inside `timelock.execute` internal transactions (`additionalContracts`),
attributed here by deploy order (CAT → C → KO, per `DeployDevNet._deployBondTokens`).
**Verify each on-chain (e.g. `cast call <token> "name()(string)"`) before reuse.**

| Contract | Address |
|---|---|
| TimelockController | `0xf803f99b7bcfe4d0db52fde5a76c5fc257d9ef72` |
| IssuanceManager (proxy) | `0x5ba267367f06378816c58d47c5850fc9863ce67f` |
| TokenFactory | `0xb11bdcfe08c69c461f410453bdf80a8cb9cd07ae` |
| MockSanctionsList | `0x7c1798643e0793eab998b777b2cd0b7c2f2870ad` |
| TOKEN_CAT / NAVFEED_CAT / FORWARDER_CAT | `0xc545645b889027f5c2e7c1460566b08673273b07` / `0x0e21b8e3d40d92244a07977905c056ebf5f88dde` / `0xdcbd2c177212aebd18e8f1429457483644c50c00` |
| TOKEN_C / NAVFEED_C / FORWARDER_C | `0xf62dd0722ed16593b0e8a00dd80d0ea43a0e0c1e` / `0x0248fab2aa4a481b6c7c81dddd28ac24e8eacec7` / `0x24a5eb80f6ab34c9563f5667d1bc1ccb3167b9c0` |
| TOKEN_KO / NAVFEED_KO / FORWARDER_KO | `0xb7fc5791910ceddb54bbd53136d2cfc67719a2b4` / `0x5039770267e05a8a38023cf925b3b7ff6a8076d8` / `0x38bc14c8c39c62f712207c950d423957a51550ba` |

- **TODO(ops):** confirm who controls the deployer key of that May 2026 Sepolia run,
  and whether the timelock proposer (GOVERNANCE_MULTISIG or deployer fallback) is
  still operable. If not, redeploy the token stack rather than reuse it.
- **TODO(compliance):** this Sepolia stack wired `MockSanctionsList` into the tokens.
  Decide whether the testnet swap deployment should instead sit on a fresh stack using
  the platform `SanctionsOracleMirror` (GYL-1051), since the sanctions oracle is baked
  into each token at factory-deploy time.

---

## 2. Target testnet recommendation

| Criterion | Sepolia (11155111) | Base Sepolia (84532) |
|---|---|---|
| Existing Gyld token stack | **Yes** — `DeployDevNet` stack above (reusable or cheap to redeploy) | None |
| `foundry.toml` verification config | **Yes** — `[etherscan] sepolia` entry exists | **No entry** — must be added before `--verify` works |
| Real Circle USDC (EIP-2612 permit, domain version "2") | **Yes** — `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (already in `.env.example`), fundable via Circle's faucet | Circle publishes an official USDC on Base Sepolia, but its address is not recorded anywhere in this repo — TODO(ops): confirm from Circle's developer docs if this path is ever chosen |
| Chainalysis sanctions oracle | Mainnet-only product; **not on Sepolia**. Substitute: platform `SanctionsOracleMirror` (the production oracle on every chain per GYL-1051) or `MockSanctionsList` for dev | Same — Chainalysis exists on Base *mainnet* (`0x3A91A31cB3dC49b4db9Ce721F50a9D076c8D739B`, see `.env.example`), **not on Base Sepolia** |
| Matches the Base mainnet Euler/Morpho path | No | Yes — but that path is a DeFi-listing experiment, not the atomic-swap stack |
| `.env.example` orientation | Default `RPC` is a Sepolia endpoint; Morpho Sepolia addresses pre-filled | Only Base *mainnet* variables exist |

**Recommendation: Sepolia (11155111).**

Why: it is the only network where all three hard dependencies already exist — (a) a
deployed (or trivially redeployable) `DeployDevNet` token/NAV stack that
`DeployAtomicSettlement.s.sol` explicitly builds on top of, (b) working `--verify`
config in `foundry.toml`, and (c) real Circle USDC with EIP-2612 permit, so the
optional `permitIn` path in `executeSwap` can be exercised against the real
non-standard USDC permit (domain version "2") instead of a mock. Base Sepolia buys
nothing for the swap itself: the Euler/Morpho alignment argument applies to the
lending-listing workstream, not to atomic settlement, and it would cost a full
token-stack deploy plus new verification config.

Config that must still be added even for Sepolia:

- Populate the atomic-swap env vars in `.env` — `.env.example` currently has **none**
  of `USDC_ADDRESS`, `EVM_ISSUANCE_MANAGER`, `EVM_FACTORY_ADDRESS`, `SERIES_TOKENS`,
  `ALLOWED_TAKERS`, `QUOTE_SIGNER`, `ALLOWLIST_ADMIN`, `TREASURER_ADDRESS`,
  `WITHDRAWAL_WALLET`, `OPS_MULTISIG`, `MAX_QUOTE_DEVIATION_BPS`, `MAX_NAV_AGE_SECS`.
  **TODO(ops):** add a Sepolia atomic-swap block to `.env.example`.
- If Base Sepolia were ever chosen instead, add to `foundry.toml`:
  `base-sepolia = { key = "${BASESCAN_API_KEY}", chain = 84532, url = "https://api-sepolia.basescan.org/api" }`.

---

## 3. Prerequisites checklist

### 3.1 Environment variables the scripts actually read

`DeployAtomicSettlement.s.sol` (`vm.envAddress` / `vm.envUint`, lines 117–127, 228, 234, 246):

| Var | Required? | Default | Testnet status |
|---|---|---|---|
| `USDC_ADDRESS` | **Required** | — | Sepolia: use Circle USDC `0x1c7D...7238` (`USDC` in `.env.example`). Do NOT use `MockUSDC` on a public testnet unless the permit path is out of scope. |
| `EVM_ISSUANCE_MANAGER` | **Required** | — | Sepolia: `0x5ba2...e67f` if reusing the existing stack, else output of a fresh `DeployDevNet` run |
| `TIMELOCK_ADDRESS` | Optional | unset → **deployer keeps DEFAULT_ADMIN** | Set it — see readiness gap 2. Sepolia has `0xf803...ef72` |
| `OPS_MULTISIG` | Optional | deployer | TODO(ops): testnet pauser address |
| `TREASURER_ADDRESS` | Optional | deployer | TODO(ops): testnet stand-in for the Kaleidoscope ops MPC wallet |
| `QUOTE_SIGNER` | Optional | deployer | TODO(quote-service team): address of the quote-signing key — must NOT default to the deployer on testnet (gap 1) |
| `ALLOWLIST_ADMIN` | Optional | deployer | TODO(ops): address of the `EVM_KMS_SWAP_ADMIN_` allowlist key (GYL-1050) — must survive the timelock handover |
| `WITHDRAWAL_WALLET` | Optional | `TREASURER_ADDRESS` | TODO(ops): fixed treasury destination; distinct from the treasurer is cleaner |
| `MAX_QUOTE_DEVIATION_BPS` | Optional | 200 (2%) | Default fine for testnet |
| `MAX_NAV_AGE_SECS` | Optional | 86400 (1 day) | Default fine only if the NAV keeper pushes at least daily — else `executeSwap` fails closed with `StaleNav` |
| `EVM_FACTORY_ADDRESS` | Required iff `SERIES_TOKENS` set | — | Sepolia: `0xb11b...07ae` or fresh |
| `SERIES_TOKENS` | Optional | unset → register later | Comma-separated bond-token addresses |
| `ALLOWED_TAKERS` | Optional | unset → allowlist later | Comma-separated taker addresses — takers that are not on this list cannot call `executeSwap` |

`DeployDevNet.s.sol` (only if redeploying the base stack): `GOVERNANCE_MULTISIG`,
`OPS_MULTISIG`, `SUBSCRIBER_ADDRESS`, `REDEEMER_ADDRESS`, `WHITELIST_ADMIN`,
`NAV_FEED_OWNER` (all default to deployer), `SANCTIONS_LIST` (unset → deploys
`MockSanctionsList`; only chain 1 hard-blocks that), `TIMELOCK_DELAY_SECONDS`
(defaults to **172800 s = 48 h on any non-Anvil chain**, which splits the run into
two phases — set `TIMELOCK_DELAY_SECONDS=0` for a single-pass testnet deploy, as the
May 2026 Sepolia run evidently did).

CLI-level (from `.env.example` — all still placeholders there): `PRIVKEY`
(deployer key), `RPC`, `ETHERSCAN_API_KEY`, `WALLET`.

> **Never commit `.env`; never print it.** It holds real secrets. All examples below
> reference variables by name only.

### 3.2 External dependencies on Sepolia

| Dependency | Exists on Sepolia? | Substitute / action |
|---|---|---|
| USDC with EIP-2612 permit | **Yes** — Circle USDC `0x1c7D...7238`; fund deployer + takers via Circle's faucet | — |
| Chainalysis sanctions oracle | **No** (mainnet-only) | Deploy platform `SanctionsOracleMirror` and pass it as `SANCTIONS_LIST`, or accept `MockSanctionsList` for pure dev. TODO(compliance): decide before deploy — it is baked into tokens at `deployToken` time |
| NAV keeper (pushes `KaleidoscopeNAVFeed.updateAnswer`) | Must be operated by us | TODO(quote-service/keeper team): schedule pushes more frequent than `MAX_NAV_AGE_SECS` or every swap reverts `StaleNav` |
| Quote-signing service (EIP-712) | Must be operated by us | TODO(quote-service team): point the signer at the Sepolia swap's domain (name `GyldAtomicSwap`, version `2`, chainId 11155111, verifyingContract = swap proxy) |
| Sepolia ETH for gas | Faucets | Fund deployer, taker, allowlist-admin, treasurer test keys; check with `cast balance $WALLET --rpc-url $RPC` |
| Etherscan API key | Config exists in `foundry.toml` | `ETHERSCAN_API_KEY` is a placeholder in `.env.example` — TODO(ops): provision a real key |

### 3.3 Preflight

```bash
forge build            # must compile clean at solc 0.8.28
forge test             # 398 tests must pass
cast chain-id --rpc-url $RPC          # expect 11155111
cast balance $WALLET --rpc-url $RPC   # expect enough for ~15–20 txs
```

---

## 4. Ordered deploy sequence

All commands are documentation of what to run — nothing below has been executed as
part of writing this runbook. Every `--broadcast` step is a real spend on Sepolia.

### Step 0 — decide: reuse or redeploy the base stack

Reuse the section-1 Sepolia stack only if TODO(ops) confirms key custody and the
sanctions-oracle decision (section 1). Otherwise redeploy:

```bash
# Fresh base stack (skip if reusing). TIMELOCK_DELAY_SECONDS=0 keeps it single-pass;
# with the 48h default the script stops after Phase 1 and prints Phase 2 instructions.
TIMELOCK_DELAY_SECONDS=0 \
forge script contracts/script/DeployDevNet.s.sol \
  --rpc-url $RPC --broadcast --private-key $PRIVKEY --verify
```

Verify:

```bash
cast call $EVM_ISSUANCE_MANAGER "whitelisted(address)(bool)" $SUBSCRIBER_ADDRESS --rpc-url $RPC
# expected: true
cast call $EVM_FACTORY_ADDRESS "forwarderOf(address)(address)" $TOKEN_CAT --rpc-url $RPC
# expected: non-zero forwarder address (record as FORWARDER_CAT)
```

### Step 1 — push NAV **first** (the fail-closed gotcha)

`executeSwap` reverts `InvalidNav` / `StaleNav` until each registered series' feed has
a fresh positive answer (`AtomicSettlementFlow.s.sol` lines 34–37 document this;
enforcement is `GyldAtomicSwap._checkQuoteBand`). Push before registering/settling:

```bash
# $100.00 at 8 decimals; sender must be the NAV feed owner (NAV_FEED_OWNER key)
cast send $NAVFEED_CAT "updateAnswer(int256)" 10000000000 \
  --rpc-url $RPC --private-key $NAV_FEED_OWNER_KEY
```

Verify:

```bash
cast call $FORWARDER_CAT "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC
# expected: second value 10000000000, fourth value = recent unix timestamp
```

### Step 2 — deploy the swap (`DeployAtomicSettlement.s.sol`)

One broadcast performs, in order: proxy deploy + initialize → whitelist the swap as
an AP on IssuanceManager (skipped with printed instructions if the broadcaster lacks
`WHITELIST_ADMIN_ROLE`) → `registerSeries` per `SERIES_TOKENS` → `setWithdrawalWallet`
→ grant `ALLOWLIST_ADMIN_ROLE` (deployer transiently + `ALLOWLIST_ADMIN` durably,
GYL-1050 — ordering is load-bearing, see script lines 168–177) → allowlist
`ALLOWED_TAKERS` → hand `DEFAULT_ADMIN_ROLE` to `TIMELOCK_ADDRESS` and revoke the
deployer.

```bash
export USDC_ADDRESS=$USDC                 # Circle Sepolia USDC
export EVM_ISSUANCE_MANAGER=<issuance_manager_proxy>
export EVM_FACTORY_ADDRESS=<token_factory>
export SERIES_TOKENS=$TOKEN_CAT,$TOKEN_C,$TOKEN_KO
export ALLOWED_TAKERS=<taker_test_address>
export TIMELOCK_ADDRESS=<timelock>        # omit ONLY for throwaway dev iterations
export OPS_MULTISIG=<pauser>
export TREASURER_ADDRESS=<treasurer>
export QUOTE_SIGNER=<quote_signer_address>
export ALLOWLIST_ADMIN=<kms_swap_admin_address>
export WITHDRAWAL_WALLET=<treasury_destination>

forge script contracts/script/DeployAtomicSettlement.s.sol \
  --rpc-url $RPC --broadcast --private-key $PRIVKEY --verify
# Record the printed EVM_ATOMIC_SWAP=<address> as $SWAP
```

Verify wiring (each is a read-only `cast call`):

```bash
cast call $SWAP "usdc()(address)" --rpc-url $RPC
# expected: $USDC_ADDRESS
cast call $SWAP "quoteEpoch()(uint64)" --rpc-url $RPC
# expected: 0
cast call $SWAP "registeredSeries(address)(bool)" $TOKEN_CAT --rpc-url $RPC
# expected: true
cast call $SWAP "navForwarderOf(address)(address)" $TOKEN_CAT --rpc-url $RPC
# expected: $FORWARDER_CAT
cast call $SWAP "withdrawalWallet()(address)" --rpc-url $RPC
# expected: $WITHDRAWAL_WALLET (0x0 means step 4 of the script did not run — stop)
cast call $SWAP "hasRole(bytes32,address)(bool)" $(cast keccak "QUOTE_SIGNER_ROLE") $QUOTE_SIGNER --rpc-url $RPC
# expected: true
cast call $SWAP "hasRole(bytes32,address)(bool)" $(cast keccak "ALLOWLIST_ADMIN_ROLE") $ALLOWLIST_ADMIN --rpc-url $RPC
# expected: true          (GYL-1050 — must survive the timelock handover)
cast call $SWAP "hasRole(bytes32,address)(bool)" 0x0000000000000000000000000000000000000000000000000000000000000000 $TIMELOCK_ADDRESS --rpc-url $RPC
# expected: true          (DEFAULT_ADMIN_ROLE == bytes32(0))
cast call $SWAP "hasRole(bytes32,address)(bool)" 0x0000000000000000000000000000000000000000000000000000000000000000 $WALLET --rpc-url $RPC
# expected: false         (deployer revoked)
cast call $SWAP "isAllowed(address)(bool)" <taker_test_address> --rpc-url $RPC
# expected: true
cast call $EVM_ISSUANCE_MANAGER "whitelisted(address)(bool)" $SWAP --rpc-url $RPC
# expected: true          (swap is a whitelisted AP / mint recipient)
```

### Step 3 — seed the swap's own inventory (no vault exists — this is new)

The swap is self-custodial: `executeSwap` reverts `InsufficientInventory` /
`InsufficientUsdcLiquidity` unless the outgoing leg is already sitting in the
contract. Two fundings are required:

**(a) Bond tokens** — minted **directly to the swap** via the unchanged
IssuanceManager mint-at-fill path (the swap has no mint authority; it is just a
whitelisted AP recipient). Sender must hold `SUBSCRIBER_ROLE`:

```bash
# 100 tokens (18 decimals) of CAT into the swap
cast send $EVM_ISSUANCE_MANAGER "subscribe(address,address,uint256)" \
  $TOKEN_CAT $SWAP 100000000000000000000 \
  --rpc-url $RPC --private-key $SUBSCRIBER_KEY
```

**(b) USDC for the redeem leg** — a plain ERC-20 transfer to the swap (there is no
deposit function; the contract prices whatever it holds):

```bash
# 10,000 USDC (6 decimals) — sourced from the Circle faucet to the funding wallet
cast send $USDC_ADDRESS "transfer(address,uint256)" $SWAP 10000000000 \
  --rpc-url $RPC --private-key $FUNDING_KEY
```

Verify:

```bash
cast call $TOKEN_CAT "balanceOf(address)(uint256)" $SWAP --rpc-url $RPC
# expected: 100000000000000000000
cast call $USDC_ADDRESS "balanceOf(address)(uint256)" $SWAP --rpc-url $RPC
# expected: 10000000000
```

---

## 5. Post-deploy smoke test (one real buy, one real redeem)

### 5.1 Why `AtomicSettlementFlow.s.sol` cannot run on testnet as-is

`contracts/script/AtomicSettlementFlow.s.sol:63`:

```solidity
require(block.chainid == 31337, "AtomicSettlementFlow: Anvil (chainId 31337) only");
```

(`DeployAtomicSettlementE2E.s.sol:60` carries the same guard.) The guard is not the
only blocker: the flow script (a) deploys its **own fresh mock stack** (MockUSDC,
MockSanctionsList) rather than targeting an existing deployment, and (b) hardcodes
**publicly known Anvil private keys** as taker and quote signer (lines 54–55) — on a
public network anyone can sweep those accounts and forge "platform" quotes. A testnet
port would need: the guard changed, the hardcoded keys replaced by env-provided keys,
and the deploy steps replaced by env-provided addresses. **TODO(quote-service team):**
decide whether to build that `AtomicSettlementFlowTestnet.s.sol` variant or use the
manual `cast` flow below. Do not simply delete the `require`.

### 5.2 Manual smoke test with `cast`

**Sign the quote (off-chain EIP-712).** Ask the contract itself for the digest —
`hashSwapMessage` is the on-chain half of the signer-parity contract — then sign the
raw 32-byte digest:

```bash
# BUY example at NAV $100: taker pays up to 1,000 USDC for 10 CAT.
# price = amountOut per 1e18 tokenIn = 10e18 * 1e18 / 1000e6 = 1e28
QUOTE="(1,$TAKER,$USDC_ADDRESS,1000000000,$TOKEN_CAT,10000000000000000000000000000,$EXPIRY,0)"
# EXPIRY = unix now + 900; final 0 = epoch (must equal cast call $SWAP "quoteEpoch()")

DIGEST=$(cast call $SWAP \
  "hashSwapMessage((uint256,address,address,uint256,address,uint256,uint64,uint64))(bytes32)" \
  "$QUOTE" --rpc-url $RPC)

SIG=$(cast wallet sign --no-hash $DIGEST --private-key $QUOTE_SIGNER_KEY)
# --no-hash: the EIP-712 digest is already the final hash; do not re-hash or
# EIP-191-prefix it.
```

**Digest parity.** Producing the digest via `cast call hashSwapMessage` gives parity
with the contract by construction. An independent off-chain signer (the production
quote service) must instead reproduce the digest itself; the pinned ground truth is in
`contracts/test/GyldAtomicSwap.t.sol` (section header line 1018):
`test_swapMessageTypehash_matchesCanonicalString` (lines 1024–1031) pins
`SWAP_MESSAGE_TYPEHASH` to the canonical type string, and
`test_hashSwapMessage_matchesHandBuiltDigest` (lines 1039–1069) pins the full domain —
name `"GyldAtomicSwap"`, version `"2"`, chainId, verifyingContract. Any off-chain
signer must reproduce exactly that digest; compare its output against
`hashSwapMessage` on Sepolia before signing real quotes.

**Execute the BUY** (sender must be the quote's taker and allowlisted):

```bash
cast send $USDC_ADDRESS "approve(address,uint256)" $SWAP 1000000000 \
  --rpc-url $RPC --private-key $TAKER_KEY
# (alternative: skip approve and pass a real EIP-2612 permit tuple — Circle Sepolia
#  USDC supports it; note USDC's permit domain version is "2")

cast send $SWAP \
  "executeSwap((uint256,address,address,uint256,address,uint256,uint64,uint64),bytes,(uint256,uint256,uint8,bytes32,bytes32),uint256)" \
  "$QUOTE" $SIG "(0,0,0,0x0000000000000000000000000000000000000000000000000000000000000000,0x0000000000000000000000000000000000000000000000000000000000000000)" \
  1000000000 \
  --rpc-url $RPC --private-key $TAKER_KEY
```

Expected after the buy: taker `TOKEN_CAT` balance `+10e18`; swap USDC `+1000e6`; swap
`TOKEN_CAT` `-10e18`; `cast call $SWAP "isQuoteUsed(uint256)(bool)" 1` → `true`;
`totalSupply` of the token unchanged (settlement moves inventory, never mints).
Note `requestedAmountIn` may be less than `maxAmountIn` but at least 1% of it
(`MIN_DRAW_BPS`); the quoteId burns in full either way.

**Execute the REDEEM** (mirror direction, fresh `quoteId`):

```bash
# price = 1000e6 * 1e18 / 10e18 = 1e8 (USDC out per 1e18 token in, at NAV $100)
REDEEM="(2,$TAKER,$TOKEN_CAT,10000000000000000000,$USDC_ADDRESS,100000000,$EXPIRY,0)"
# sign as above; then:
cast send $TOKEN_CAT "approve(address,uint256)" $SWAP 10000000000000000000 \
  --rpc-url $RPC --private-key $TAKER_KEY
cast send $SWAP "executeSwap(...)" "$REDEEM" $SIG2 "(0,0,0,0x00...,0x00...)" 10000000000000000000 \
  --rpc-url $RPC --private-key $TAKER_KEY   # same full signature string as the buy
```

Expected: taker made whole in USDC (`+1000e6`), tokens back in the swap,
`isQuoteUsed(2)` → `true`. Both legs settle within the 2% NAV band or revert
`QuotePriceOutOfBand`; if the NAV push is older than `MAX_NAV_AGE_SECS`, expect
`StaleNav` — push NAV again (step 1) and retry.

Optionally finish with a treasurer withdrawal to prove the evacuation path:
`cast send $SWAP "withdraw(address,uint256)" $USDC_ADDRESS 1000000000 --private-key
$TREASURER_KEY` → funds land at `withdrawalWallet()`, nowhere else.

---

## 6. Readiness gaps

1. **[CRITICAL] Quote-signer key management.** `QUOTE_SIGNER_ROLE` is a hot key that
   prices every settlement; on Anvil it is a public Anvil key and the deploy script
   defaults it to the deployer. There is no KMS-backed signer provisioned for any
   public network. A leaked signer can author in-band quotes drained against real
   inventory until `bumpQuoteEpoch()`/role revoke lands. TODO(quote-service team +
   security): provision a KMS/HSM key, wire its address as `QUOTE_SIGNER`, and
   rehearse rotation (grant new → revoke old → `bumpQuoteEpoch`).
2. **[CRITICAL] Timelock vs EOA admin.** `TIMELOCK_ADDRESS` is optional; unset, the
   deployer EOA keeps `DEFAULT_ADMIN_ROLE` — i.e. unilateral UUPS upgrade authority
   over a contract that **holds funds**. On testnet this is tolerable only for
   throwaway iterations; the dress-rehearsal deploy must hand over to the timelock and
   verify the deployer was revoked (step 2 checks). TODO(ops): confirm the Sepolia
   timelock's proposer key is operable before relying on it — an inert timelock
   bricks unpause, upgrades, and series registry.
3. **[HIGH] Self-custodial inventory risk.** The old vault design is gone: the swap
   contract itself is the honeypot. Operationally this changes three things vs the
   vault era: (a) inventory sizing is now a live ops duty — swaps fail
   `InsufficientInventory`/`InsufficientUsdcLiquidity` when the pot runs dry, so
   someone must monitor balances and re-seed via `subscribe`/USDC transfer;
   (b) the blast radius of an upgrade-key or signer compromise is the full held
   balance, so testnet should rehearse with small, capped inventory; (c) evacuation
   is `TREASURER_ROLE.withdraw()` to the admin-fixed `withdrawalWallet` — that wallet
   and the treasurer key must exist and be tested (section 7). TODO(ops): define
   inventory caps and a re-seed runbook before any real-value deployment.
4. **[HIGH] Unaudited post-audit contract.** `GyldAtomicSwap` (and the GYL-548
   self-custodial rework, GYL-1050 allowlist split, GYL-1051 sanctions mirror)
   post-date the last audit scope. Testnet deployment is fine; nothing here clears it
   for mainnet. TODO(security): schedule an audit covering the current BUSL-1.1
   contract set.
5. **[MEDIUM] Mocks standing in for real contracts.** `MockUSDC` is a bare ERC-20
   with **no EIP-2612 permit** (`contracts/test/MockUSDC.sol`) — it cannot exercise
   the `permitIn` path; use real Circle USDC on Sepolia. `MockSanctionsList` is wired
   into the existing Sepolia tokens instead of the Chainalysis oracle (mainnet-only)
   or the platform `SanctionsOracleMirror`; the fail-closed sanctions behaviour of
   `GyldBondToken._update` is therefore not realistically exercised. TODO(compliance):
   pick the testnet sanctions oracle before the base-stack decision in step 0.
6. **[MEDIUM] Allowlist operations unproven off-Anvil.** `ALLOWLIST_ADMIN_ROLE`
   (GYL-1050) must be a live hot key (`EVM_KMS_SWAP_ADMIN_`) that keeps working after
   the timelock handover, or the gateway allowlist routes revert. No such key exists
   for Sepolia yet. TODO(ops): provision it and test `setAllowed` both grant and
   revoke after handover.
7. **[LOW] Missing verification config for Base Sepolia.** Only relevant if the
   recommendation is overridden: `foundry.toml` has no `[etherscan]` entry for 84532
   (section 2). Also `ETHERSCAN_API_KEY` in `.env.example` is a placeholder even for
   Sepolia. TODO(ops).
8. **[LOW] NAV keeper cadence.** `MAX_NAV_AGE_SECS` defaults to 1 day; without a
   scheduled `updateAnswer` push the whole swap soft-bricks into `StaleNav`.
   TODO(keeper team): stand up the Sepolia push job before the smoke test.

---

## 7. Rollback / incident procedure

There is no "undeploy". Incident response is: stop the hot path, invalidate paper,
evacuate funds, then fix under the timelock.

| Action | Who (role) | Command | Effect |
|---|---|---|---|
| Halt all swaps | `PAUSER_ROLE` — ops multisig (`OPS_MULTISIG`) | `cast send $SWAP "pause()" --private-key $PAUSER_KEY` | `executeSwap` reverts; `withdraw()` deliberately stays live for evacuation |
| Kill every outstanding quote | `DEFAULT_ADMIN_ROLE` — timelock (schedule + execute) | timelock proposal calling `bumpQuoteEpoch()` on `$SWAP` | All quotes signed for the old epoch revert `QuoteEpochStale`; quote service must re-issue |
| Cut off a taker | `ALLOWLIST_ADMIN_ROLE` — KMS allowlist key (hot, survives handover by design) | `cast send $SWAP "setAllowed(address,bool)" <taker> false --private-key $ALLOWLIST_ADMIN_KEY` | Immediate, no timelock delay — this is why GYL-1050 split the role |
| Rotate a compromised quote signer | grant/revoke: timelock; epoch bump: timelock | timelock: `grantRole(QUOTE_SIGNER_ROLE, new)`, `revokeRole(QUOTE_SIGNER_ROLE, old)`, then `bumpQuoteEpoch()` | Old key's quotes dead even if the revoke lags — epoch bump is the fast kill |
| Evacuate inventory | `TREASURER_ROLE` — treasurer key | `cast send $SWAP "withdraw(address,uint256)" <token> <amount> --private-key $TREASURER_KEY` | Funds move **only** to the admin-fixed `withdrawalWallet` — the treasurer cannot redirect; works while paused |
| Resume | `DEFAULT_ADMIN_ROLE` — timelock only | timelock proposal calling `unpause()` | Asymmetric by design: pausing is cheap, resuming is deliberate |

Notes:

- **DEFAULT_ADMIN_ROLE cannot be renounced** (`CannotRenounceAdminRole`) — losing the
  timelock's proposer key is the unrecoverable failure mode; that is gap 2.
- On testnet, whoever holds the role keys per the step-2 env vars holds these levers.
  TODO(ops): record the actual Sepolia role→key assignments in this doc's next
  revision once provisioned; this runbook deliberately names no key custodians.
- Rehearse the full sequence (pause → epoch bump → allowlist revoke → withdraw →
  unpause) once on Sepolia before any mainnet planning; it doubles as the role-wiring
  acceptance test.
