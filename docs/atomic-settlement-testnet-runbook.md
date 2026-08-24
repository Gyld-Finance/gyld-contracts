# Atomic Settlement — Testnet Deployment Runbook

Deployment runbook and readiness assessment for taking the **self-custodial**
`GyldAtomicSwap` stack to a public testnet. Updated for the GYL-1135 deploy
hardening (536 Forge tests passing); section 8 is the fresh-deploy checklist.

**Guard note — read this with section 8.** GYL-1135 made the deploy scripts fail
closed on production chains, but **Sepolia (11155111) is on the dev allowlist**
(`DeployGuards.isDevChain`), so on the chain this runbook targets the production
guards — required env vars, `!= deployer` assertions, the 48h minimum delay, the
post-deploy handover assertions — are all **no-ops**. A Sepolia deploy therefore
reproduces the fail-open behaviour by design, and every safety property must be
checked by hand. That is what section 8 is for: it verifies with independent
`cast` calls rather than trusting the script's own in-band assertions.

**Architecture note — read this before anything else.** `GyldAtomicSwap` is
self-custodial: it holds its own inventory (USDC + bond tokens) and settles
platform-signed EIP-712 quotes against that inventory (`contracts/GyldAtomicSwap.sol`,
contract NatSpec lines 20–28). There is no vault to deploy and no `SWAP_ROLE`
handover — nothing in this runbook deploys or configures a settlement vault.
Contracts are **BUSL-1.1** licensed.

---

## 1. What already exists on Sepolia, and why this runbook ignores it

Earlier `GyldAtomicSwap` and token-stack instances were broadcast to Ethereum Sepolia
(11155111) and are recorded in **[`DEPLOYMENTS.md`](../DEPLOYMENTS.md), the
authoritative address register** — read it before running anything in section 4;
`broadcast/` is history, not an address book. Outside Sepolia the swap stack has only
ever been broadcast to local Anvil.

> **They are demonstrations, built from commits that predate current source, and they
> are not tracked as such.** How they differ from `main` is deliberately not
> enumerated — in `DEPLOYMENTS.md`, here, or anywhere else. Nothing is live on
> mainnet; production will be a fresh deployment; current source is the reference.
>
> **This runbook is therefore written as a fresh deploy throughout, and nothing in it
> upgrades or reconfigures an existing instance.** Do not upgrade one into service:
> an upgrade changes the ABI, and values seeded by an older initializer survive it, so
> the upgraded proxy can silently keep a laxer limit than a fresh deployment would get.
>
> One consequence to be deliberate about: re-running `DeployAtomicSettlement.s.sol`
> against Sepolia does not touch an existing proxy either — it produces a **second,
> unrelated swap**, with its own `verifyingContract`, and leaves the earlier one
> untouched. That is the intended outcome here; just record the new addresses in
> `DEPLOYMENTS.md` and point the quote signer at the new domain.

| Network | Chain ID | What has been broadcast there | Source broadcast dir |
|---|---|---|---|
| Local Anvil | 31337 | Full stack incl. `GyldAtomicSwap` (`DeployAtomicSettlement`, `AtomicSettlementFlow`, `DeployAtomicSettlementE2E`, `DeployDevNet`, `DeployMockUSDC`) — ephemeral; gone on Anvil restart | `broadcast/DeployAtomicSettlement.s.sol/31337` et al. |
| Sepolia | 11155111 | A `GyldAtomicSwap` proxy + implementation, and an older `DeployDevNet.s.sol` token stack (TimelockController, IssuanceManager proxy, TokenFactory, MockSanctionsList, three bond series). Addresses, source commits and per-row do-not-reuse status: `DEPLOYMENTS.md` | `broadcast/DeployDevNet.s.sol/11155111`; swap addresses per `DEPLOYMENTS.md` |

> **Warning — confirm the chain id before you broadcast.** A script's name is not
> evidence of which chain it targets — "test" in a filename proves nothing. Run
> `cast chain-id --rpc-url $RPC` and confirm the answer is the testnet you intend
> before any `--broadcast` — anything sent to a production chain spends real funds
> and cannot be undone. Note also that only the chain ids on
> `DeployGuards.isDevChain` are treated as dev; every other chain id is treated as
> production by the scripts.

### Sepolia (11155111) recorded addresses

**They are not repeated here.** `DEPLOYMENTS.md` is the authoritative register:
the gen-1 devnet stack (TimelockController, IssuanceManager proxy, TokenFactory,
MockSanctionsList, and the CAT / C / KO series with their NAV feeds and
forwarders) is listed there with source commit, privileged roles, verification
status and — the part a runbook cannot restate safely — a per-row **status**,
including which rows are marked do-not-reuse. Read those status columns before
you copy any address into `.env`; a second copy of the table in this document
would drift out of step with them.

> **Do not wire a new deployment to the gen-1 `MockSanctionsList`
> (`0x7C1798643e0793EAB998B777b2CD0B7c2F2870Ad`).** `DEPLOYMENTS.md` records it
> **do-not-reuse — ungated sanctions oracle**: in that deployed instance
> `addToSanctionsList` / `removeFromSanctionsList` are plain `external` with no
> owner and no access control, so **anyone on the internet can sanction or
> unsanction any address**. Because token screening is fail-closed, that is a
> permissionless transfer-freeze on every holder of every series wired to it —
> and the existing Sepolia series already are. The owner-gated
> `MockSanctionsList` in this repo's current source is a *different* contract
> from the one at that address; do not reason from the source you can read.
> Deploy a fresh sanctions oracle (platform `SanctionsOracleMirror`, GYL-1051, or
> a freshly deployed owner-gated mock for pure dev) and pass it as
> `SANCTIONS_LIST`. The oracle is baked into each token at `deployToken` time and
> cannot be repointed afterwards, so this decision is unrecoverable once tokens
> exist — see the TODO(compliance) below and readiness gap 5.

- **TODO(compliance):** decide the sanctions oracle for the fresh testnet stack —
  platform `SanctionsOracleMirror` (GYL-1051) or a freshly deployed owner-gated
  `MockSanctionsList` for pure dev — **before** step 0. It is baked into each token at
  `deployToken` time and cannot be repointed afterwards.

---

## 2. Target testnet recommendation

| Criterion | Sepolia (11155111) |
|---|---|
| Cost of a fresh token stack | Low — one `DeployDevNet` run; faucet ETH only |
| `foundry.toml` verification config | **Yes** — `[etherscan] sepolia` entry exists |
| Real Circle USDC (EIP-2612 permit, domain version "2") | **Yes** — `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` (already in `.env.example`), fundable via Circle's faucet |
| Chainalysis sanctions oracle | Mainnet-only product; **not on Sepolia**. Substitute: platform `SanctionsOracleMirror` (the production oracle on every chain per GYL-1051) or `MockSanctionsList` for dev |
| `.env.example` orientation | Default `RPC` is a Sepolia endpoint |

**Recommendation: Sepolia (11155111).**

Why: it is the only network where all three hard dependencies are cheap to satisfy —
(a) a `DeployDevNet` token/NAV stack, which `DeployAtomicSettlement.s.sol` explicitly
builds on top of, deploys in one run on faucet ETH, (b) working `--verify` config
already exists in `foundry.toml`, and (c) real Circle USDC with EIP-2612 permit, so
the optional `permitIn` path in `executeSwap` can be exercised against the real
non-standard USDC permit (domain version "2") instead of a mock. Any other testnet
would additionally cost new verification config and a USDC substitute.

Config that must still be added even for Sepolia:

- Populate the atomic-swap env vars in `.env`. `.env.example` now carries a Sepolia
  atomic-swap block covering all of them — `USDC_ADDRESS`, `EVM_ISSUANCE_MANAGER`,
  `EVM_FACTORY_ADDRESS`, `SERIES_TOKENS`, `ALLOWED_TAKERS`, `QUOTE_SIGNER`,
  `ALLOWLIST_ADMIN`, `TREASURER_ADDRESS`, `WITHDRAWAL_WALLET`, `OPS_MULTISIG`,
  `MAX_QUOTE_DEVIATION_BPS`, `MAX_NAV_AGE_SECS` — but apart from `USDC_ADDRESS` (real
  Circle Sepolia USDC) and the two numeric defaults, the values are **placeholders**
  (`0x_QUOTE_SERVICE_KMS_KEY` and friends). Copy the block into `.env` and fill in real
  addresses — the example file tells you which variables the script reads, not what to
  point them at.

---

## 3. Prerequisites checklist

### 3.1 Environment variables the scripts actually read

`DeployAtomicSettlement.s.sol` (read via `DeployGuards.envAddressRequired` /
`envAddressProdRequired` and `vm.envAddress` / `vm.envUint`):

| Var | Required? | Default | Testnet status |
|---|---|---|---|
| `USDC_ADDRESS` | **Required** | — | Sepolia: use Circle USDC `0x1c7D...7238` (`USDC` in `.env.example`). Do NOT use `MockUSDC` on a public testnet unless the permit path is out of scope. |
| `EVM_ISSUANCE_MANAGER` | **Required** | — | Output of the step-0 `DeployDevNet` run |
| `TIMELOCK_ADDRESS` | **Required on production**; optional on Sepolia/Anvil, where unset → **deployer keeps DEFAULT_ADMIN** | unset (dev only) | Set it to the timelock the step-0 run deploys — see readiness gap 2. On Sepolia nothing forces this; verify with step 8.3 |
| `OPS_MULTISIG` | **Required on production**; dev → deployer | deployer (dev only) | TODO(ops): testnet pauser address |
| `TREASURER_ADDRESS` | **Required on production**; dev → deployer | deployer (dev only) | TODO(ops): testnet stand-in for the Kaleidoscope ops MPC wallet |
| `QUOTE_SIGNER` | **Required on production**; dev → deployer | deployer (dev only) | TODO(quote-service team): address of the quote-signing key — must NOT default to the deployer on testnet (gap 1); on Sepolia the `!= deployer` guard does not fire, so set it explicitly |
| `ALLOWLIST_ADMIN` | **Required on production**; dev → deployer | deployer (dev only) | TODO(ops): address of the `EVM_KMS_SWAP_ADMIN_` allowlist key (GYL-1050) — must survive the timelock handover |
| `WITHDRAWAL_WALLET` | **Required on production**; dev → `TREASURER_ADDRESS` | `TREASURER_ADDRESS` (dev only) | TODO(ops): fixed treasury destination; distinct from the treasurer is cleaner |
| `MAX_QUOTE_DEVIATION_BPS` | Optional | 200 (2%) | Default fine for testnet |
| `MAX_NAV_AGE_SECS` | Optional | 86400 (1 day) | Default fine only if the NAV keeper pushes at least daily — else `executeSwap` fails closed with `StaleNav` |
| `EVM_FACTORY_ADDRESS` | Required iff `SERIES_TOKENS` set | — | Output of the step-0 `DeployDevNet` run |
| `SERIES_TOKENS` | Optional | unset → register later | Comma-separated bond-token addresses |
| `ALLOWED_TAKERS` | Optional | unset → allowlist later | Comma-separated taker addresses — takers that are not on this list cannot call `executeSwap` |

`DeployDevNet.s.sol` (only if redeploying the base stack): `GOVERNANCE_MULTISIG`,
`OPS_MULTISIG`, `SUBSCRIBER_ADDRESS`, `REDEEMER_ADDRESS`, `WHITELIST_ADMIN`,
`NAV_FEED_OWNER` — all **required on any production chain** and each asserted
`!= deployer` there; on Anvil/Sepolia they still fall back to the deployer.
`SANCTIONS_LIST` is required on production, must be a deployed **contract**, and is
rejected if its bytecode matches this repo's `MockSanctionsList`; on a dev chain,
unset still deploys the mock. `TIMELOCK_DELAY_SECONDS` defaults to **0 on Anvil and
48 h on any other chain**, and on production `< 48 h` now **reverts before any gas is
spent** (`requireProdMinDelay`) — `TIMELOCK_DELAY_SECONDS=0` is exactly how a
deployment ends up with a timelock that gates nothing. On Sepolia it is still
accepted, which is what keeps a single-pass
testnet deploy possible; it also means the delay you get is the delay you asked for
and nothing checks it for you (step 8.3).

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
forge test             # 536 tests must pass
python3 ci/check_chain_guards.py      # every deploy script carries an allowlist guard
cast chain-id --rpc-url $RPC          # expect 11155111
cast balance $WALLET --rpc-url $RPC   # expect enough for ~15–20 txs
```

---

## 4. Ordered deploy sequence

All commands are documentation of what to run — nothing below has been executed as
part of writing this runbook. Every `--broadcast` step is a real spend on Sepolia.

### Step 0 — deploy a fresh base stack

Always fresh. The Sepolia instances in `DEPLOYMENTS.md` are demonstrations built from
older source and are not reused or upgraded (section 1); settle the sanctions-oracle
TODO(compliance) first, because that choice is baked into every token here and cannot
be repointed afterwards.

```bash
# TIMELOCK_DELAY_SECONDS=0 keeps it single-pass;
# with the 48h default the script stops after Phase 1 and prints Phase 2 instructions.
# NOTE: 0 is accepted ONLY because Sepolia is a dev chain. On any production chain
# requireProdMinDelay rejects anything below 48h before a single tx is sent.
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

### Step 3 — seed the swap's own inventory (no vault exists)

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

`contracts/script/AtomicSettlementFlow.s.sol:70`:

```solidity
require(block.chainid == 31337, "AtomicSettlementFlow: Anvil (chainId 31337) only");
```

(`DeployAtomicSettlementE2E.s.sol:60` carries the same guard.) The guard is not the
only blocker: the flow script (a) deploys its **own fresh mock stack** (MockUSDC,
MockSanctionsList) rather than targeting an existing deployment, and (b) derives
**publicly known Anvil accounts** as taker and quote signer via `vm.deriveKey` on the
public Anvil mnemonic (lines 59–62; no key literal appears in the repo, but the
addresses are the same well-known ones) — on a public network anyone can sweep those
accounts and forge "platform" quotes. A testnet
port would need: the guard changed, the derived keys replaced by env-provided keys,
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
`contracts/test/GyldAtomicSwap.t.sol` (section header line 1253):
`test_swapMessageTypehash_matchesCanonicalString` (line 1259) pins
`SWAP_MESSAGE_TYPEHASH` to the canonical type string, and
`test_hashSwapMessage_matchesHandBuiltDigest` (line 1274) pins the full domain —
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
   verify the deployer was revoked (step 2 checks). TODO(ops): prove the proposer key
   of the step-0 timelock is operable before relying on it — an inert timelock bricks
   unpause, upgrades, and series registry.
3. **[HIGH] Self-custodial inventory risk.** The swap contract itself is the
   honeypot. Three operational consequences: (a) inventory sizing is a live ops
   duty — swaps fail `InsufficientInventory`/`InsufficientUsdcLiquidity` when the
   pot runs dry, so someone must monitor balances and re-seed via
   `subscribe`/USDC transfer;
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
   the `permitIn` path; use real Circle USDC on Sepolia. Chainalysis publishes no
   oracle on Sepolia, so the sanctions dependency has to be stood in for — with the
   platform `SanctionsOracleMirror` or an owner-gated `MockSanctionsList` — and the
   fail-closed behaviour of `GyldBondToken._update` is therefore not exercised against
   a real oracle. TODO(compliance): pick the testnet sanctions oracle before step 0;
   it is baked into every token at `deployToken` time.
6. **[MEDIUM] Allowlist operations unproven off-Anvil.** `ALLOWLIST_ADMIN_ROLE`
   (GYL-1050) must be a live hot key (`EVM_KMS_SWAP_ADMIN_`) that keeps working after
   the timelock handover, or the gateway allowlist routes revert. No such key exists
   for Sepolia yet. TODO(ops): provision it and test `setAllowed` both grant and
   revoke after handover.
7. **[LOW] Verification key not provisioned.** `ETHERSCAN_API_KEY` in `.env.example`
   is a placeholder even for Sepolia, so `--verify` cannot work until a real key is
   supplied. Any chain other than Sepolia would additionally need its own
   `[etherscan]` entry in `foundry.toml`. TODO(ops).
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

---

## 8. Fresh-deploy checklist (independent `cast` verification)

**Why this section exists (GYL-1135).** A deploy can land with a zero-delay timelock
and a bare EOA holding every privileged role, and go unnoticed indefinitely if nothing
ever checks. The deploy scripts now assert their own outcome in-band
(`DeployGuards.assertRoleHandover` / `assertTimelockSane`), but those assertions are
**part of the thing being verified** — and on Sepolia they are skipped entirely,
because Sepolia is on the dev allowlist. This checklist re-verifies every safety
property from outside the script, against the deployed chain state, using read-only
`cast` calls.

Run it **after every fresh deploy, on every chain.** Every command is read-only; none
spends gas. Each line states the expected output — anything else stops the deploy.

Set once:

```bash
export RPC=<rpc_url>
export SWAP=<atomic_swap_proxy>          # printed as EVM_ATOMIC_SWAP
export TIMELOCK=<timelock>
export DEPLOYER=$WALLET                  # the address that broadcast the deploy
export ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
export NAVFEED=<nav_feed_of_a_registered_series>      # from THIS deploy, not a legacy feed
export FORWARDER=<nav_forwarder_of_that_series>       # ditto
```

### 8.1 Right chain, right code

```bash
cast chain-id --rpc-url $RPC
# expected: exactly the chain you intended, and a testnet — if it is a production
# chain id, stop.

for c in $SWAP $TIMELOCK $EVM_ISSUANCE_MANAGER $EVM_FACTORY_ADDRESS; do
  cast code $c --rpc-url $RPC | head -c 12; echo "  <- $c";
done
# expected: every one starts 0x6080… (non-empty). An empty 0x means the address is
# wrong or the deploy did not land — every later check would pass vacuously.
```

### 8.2 No privileged role is still held by the deployer

This is the check that catches a deployer that quietly kept privileged roles.

```bash
for role in $ADMIN_ROLE $(cast keccak "QUOTE_SIGNER_ROLE") $(cast keccak "TREASURER_ROLE") \
            $(cast keccak "PAUSER_ROLE") $(cast keccak "ALLOWLIST_ADMIN_ROLE"); do
  echo -n "$role deployer=";
  cast call $SWAP "hasRole(bytes32,address)(bool)" $role $DEPLOYER --rpc-url $RPC;
done
# expected: false for EVERY line, ALLOWLIST_ADMIN_ROLE included.
# The deploy grants the deployer ALLOWLIST_ADMIN_ROLE transiently to seed
# ALLOWED_TAKERS and revokes it at the end (GYL-1050); a `true` here means that
# revoke did not run and the deployer keeps a permanent post-handover capability.
```

### 8.3 The timelock is a real gate, not a rubber stamp

A handover to a timelock the deployer solely controls is cosmetic — the deployer can
`schedule()` + `execute()` in one block and is still unilateral. Check the delay
**and** the roles on the timelock itself.

```bash
cast call $SWAP "hasRole(bytes32,address)(bool)" $ADMIN_ROLE $TIMELOCK --rpc-url $RPC
# expected: true    (DEFAULT_ADMIN_ROLE actually moved to the timelock)

cast call $TIMELOCK "getMinDelay()(uint256)" --rpc-url $RPC
# expected: >= 172800 (48h). 0 means the timelock gates nothing at all.

for role in $(cast keccak "PROPOSER_ROLE") $(cast keccak "CANCELLER_ROLE") \
            $(cast keccak "EXECUTOR_ROLE") $ADMIN_ROLE; do
  echo -n "$role deployer=";
  cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $role $DEPLOYER --rpc-url $RPC;
done
# expected: false for every one. A deployer holding PROPOSER on a timelock it also
# executes against is a cosmetic handover: it gates nothing.

cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $(cast keccak "EXECUTOR_ROLE") \
  0x0000000000000000000000000000000000000000 --rpc-url $RPC
# expected: false — an open executor (address(0)) lets ANYONE execute a scheduled
# proposal. A deploy script that passes `executors[0] = address(0)` produces exactly
# this.

cast call $TIMELOCK "hasRole(bytes32,address)(bool)" $(cast keccak "PROPOSER_ROLE") \
  $GOVERNANCE_MULTISIG --rpc-url $RPC
# expected: true — and confirm the multisig's signers are actually reachable.
# An inert timelock bricks unpause, upgrades and the series registry (gap 2).
```

### 8.4 Privileged addresses are distinct and are the intended ones

The fail-open defaults collapsed every role onto one key. Verify the roles are split
in fact, not merely configured.

```bash
cast call $SWAP "hasRole(bytes32,address)(bool)" $(cast keccak "QUOTE_SIGNER_ROLE") $QUOTE_SIGNER --rpc-url $RPC
cast call $SWAP "hasRole(bytes32,address)(bool)" $(cast keccak "TREASURER_ROLE") $TREASURER_ADDRESS --rpc-url $RPC
cast call $SWAP "hasRole(bytes32,address)(bool)" $(cast keccak "PAUSER_ROLE") $OPS_MULTISIG --rpc-url $RPC
cast call $SWAP "hasRole(bytes32,address)(bool)" $(cast keccak "ALLOWLIST_ADMIN_ROLE") $ALLOWLIST_ADMIN --rpc-url $RPC
# expected: true for each — the intended holder really holds it.

printf "%s\n" $DEPLOYER $QUOTE_SIGNER $TREASURER_ADDRESS $OPS_MULTISIG $ALLOWLIST_ADMIN \
  $WITHDRAWAL_WALLET $GOVERNANCE_MULTISIG | tr 'A-Z' 'a-z' | sort | uniq -d
# expected: NO output. Any address printed twice is a quorum that collapsed to one key.

cast call $SWAP "withdrawalWallet()(address)" --rpc-url $RPC
# expected: $WITHDRAWAL_WALLET, and NOT the deployer or the treasurer key.
# 0x0 means the setWithdrawalWallet step never ran — stop.
```

### 8.5 No dev-only artefact reached a real chain

```bash
cast call $EVM_FACTORY_ADDRESS "sanctionsList()(address)" --rpc-url $RPC
# expected: the intended SanctionsOracleMirror / Chainalysis address. Compare the
# code hash against the MockSanctionsList you deploy locally — the oracle is baked
# into every token at deployToken time and cannot be repointed afterwards:
cast codehash <that_address> --rpc-url $RPC

cast call $EVM_ISSUANCE_MANAGER "whitelisted(address)(bool)" \
  0x70997970C51812dc3A010C7d01b50e0d17dc79C8 --rpc-url $RPC
# expected: false. That is Anvil account[1]; its private key is in the Anvil banner.
# A `true` means a dev-only AP whitelist entry reached a real chain.

cast call $USDC_ADDRESS "decimals()(uint8)" --rpc-url $RPC
cast codehash $USDC_ADDRESS --rpc-url $RPC
# expected: the real Circle USDC, not MockUSDC (which has a permissionless mint()
# and no EIP-2612 permit). On Sepolia: 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238.
```

### 8.6 The NAV path is fresh and bounded

```bash
cast call $SWAP "maxNavAgeSecs()(uint32)" --rpc-url $RPC
# expected: <= 259200 (72h = MAX_NAV_AGE_CEILING) and matched to the keeper's real
# push cadence. The ceiling is enforced on-chain, so a larger value cannot exist —
# if this reads high, the keeper cadence is the thing that is wrong.

cast call $NAVFEED "stalenessSeconds()(uint256)" --rpc-url $RPC
# expected: a small number, and below maxNavAgeSecs above. This is the monitoring
# entrypoint to alert on: a feed can sit stale for months while downstream consumers
# keep quoting the last pinned answer silently, with nothing surfacing the fault.
# KaleidoscopeNAVFeed is NOT upgradeable, so this selector cannot be retrofitted: a
# feed built from source that predates it does not answer this call at all —
# ARCHITECTURE.md section 4.1. That is one more reason this checklist targets a fresh
# deploy. Against any such feed, derive age from updatedAt instead:
#   cast call $NAVFEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC
# and compare its 4th value against `cast block latest --field timestamp`.

cast call $FORWARDER "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC
# expected: positive answer; 4th value a recent unix timestamp.
```

### 8.7 Record the result

Append the checklist output, the deployed addresses and the role→key assignments to
this document's next revision (see gap 2's TODO). An unrecorded deploy is how a
misconfiguration stays unexamined for months.
