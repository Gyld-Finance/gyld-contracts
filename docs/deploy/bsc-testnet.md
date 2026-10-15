# BSC testnet (chain 97) — full-stack deploy in the production topology

GLD-713. BSC testnet is a **dev chain** (`DeployGuards.isDevChain()` is true for 31337,
11155111 and 97 only), so the scripts would accept a zero timelock delay, a mock
sanctions oracle and the deployer holding every role. **This deploy deliberately uses
none of the role fallbacks**: every privileged role gets its own key, as it must on BSC
mainnet (56, production path), so the testnet stack rehearses mainnet. Only the
timelock delay (0) and the mocks (sanctions list, cash token) stay testnet-grade.

The cash leg is our own **Gyld Test USD (gUSD), 18 decimals**, because BNB-chain
stablecoins are 18dp and there is no Circle USDC on BSC testnet.
`GyldAtomicSwap.initialize` probes and stores it (`cashDecimals() == 18`).

```bash
# once: put the funded MetaMask key in a private file (see "Providing the key")
DRY_RUN=1 script-bsc/deploy-bsc-testnet.sh     # whole flow simulated, nothing sent
script-bsc/deploy-bsc-testnet.sh               # broadcast; asks you to type "broadcast"
```

| File | What |
|---|---|
| `script-bsc/deploy-bsc-testnet.sh` | Driver: preflight, keys, steps, logs, address file |
| `script-bsc/BscTestnetStack.s.sol` | The on-chain work. Runs `DeployDevNet`, `DeployMockStablecoin` and `DeployAtomicSettlement` **unchanged** (instantiates them and calls `run()`), plus the steps those scripts leave to other key holders on mainnet |
| `~/.gyld/bsc-testnet-pk` | **You create it**: the funded key, chmod 600 |
| `~/.gyld/bsc-testnet-derived-keys.env` | Written by the script: every derived role key + address, chmod 600, never committed |
| `docs/deploy/bsc-testnet-addresses.env` | Written by the script: every address, **no secrets** — commit it |
| `~/.gyld/bsc-testnet/logs/` | Full forge output per step (no secrets) |

## Roles & keys plan

The funded MetaMask key is **deployer + gas funder only**. Every other role is a
throwaway key derived from it, deterministically:

```
pk(role) = keccak256(abi.encodePacked(BSC_TESTNET_PK, "gyld.bsc97." + role)) mod (n − 1) + 1
```

`script-bsc/deploy-bsc-testnet.sh plan` prints role → address; `keys` (and `deploy`)
writes the keys to `~/.gyld/bsc-testnet-derived-keys.env` for later steps or a gateway.
`verify` asserts all 14 holders are pairwise distinct and that the deployer holds nothing
except the gUSD minter.

| Role (label) | Address var | On-chain power | Why its own key | tBNB float |
|---|---|---|---|---|
| **deployer** — the funded key | `DEPLOYER_ADDRESS` | Broadcasts the three deploy scripts, funds every key below. It is the setup admin only transiently: the role is revoked inside the same broadcast. It is also the **gUSD minter**, because `DeployMockStablecoin` hard-wires the broadcaster (a test faucet with no mainnet analogue) | GYL-1135: on mainnet no role may be the deployer (`requireNotDeployer`) | — |
| governance | `GOVERNANCE_MULTISIG` | Timelock PROPOSER + CANCELLER. Through the timelock: DEFAULT_ADMIN on IssuanceManager, the swap and every bond token; owner of the TokenFactory and every NAVFeedForwarder; `rangeGovernor` of every NAV feed | If it were the deployer, the deployer would stay a proposer and DeployDevNet would self-complete Phase 2. Here Phase 2 runs as on mainnet | 0.005 |
| ops | `OPS_MULTISIG` | Bond-token PAUSER + DOCUMENT, swap PAUSER, NAV-feed `emergencyUpdater` (submits emergency corrections) | Must differ from the NAV owner (FIND-003 2-of-2: feed constructor, `NavFeedOwnerIsOperator`) and from the factory owner (`FactoryOwnerHoldsFeedRole`) | 0.001 |
| nav-feed-owner | `NAV_FEED_OWNER` | Owner of the three KaleidoscopeNAVFeeds: `updateAnswer`, co-signs emergency corrections, `setStalenessThreshold` | Must differ from ops (FIND-003) and from the timelock / `rangeGovernor` | 0.003 |
| subscriber | `SUBSCRIBER_ADDRESS` | IssuanceManager SUBSCRIBER_ROLE (`subscribe` = mint). DeployDevNet also whitelists it as an AP | Must differ from the redeemer (mint/burn quorum) and from the issuance pauser (FIND-001) | 0.002 |
| redeemer | `REDEEMER_ADDRESS` | IssuanceManager REDEEMER_ROLE (`redeem` = burn) | Must differ from the subscriber | 0.001 |
| whitelist-admin | `WHITELIST_ADMIN` | IssuanceManager WHITELIST_ADMIN_ROLE (the AP whitelist; whitelists the swap here) | The deployer's transient copy is revoked in-band | 0.001 |
| issuance-pauser | `ISSUANCE_PAUSER` | IssuanceManager ISSUANCE_PAUSER_ROLE (`pauseIssuance`; only the timelock can unpause) | Must differ from the subscriber (FIND-001: the brake on a stolen mint key) | 0.001 |
| quote-signer | `QUOTE_SIGNER` | Swap QUOTE_SIGNER_ROLE: signs EIP-712 quotes **off-chain** and never sends a transaction | — | 0 |
| treasurer | `TREASURER_ADDRESS` | Swap TREASURER_ROLE: `withdraw` net flow to the withdrawal wallet (still works while paused) | The gateway needs it distinct from the distribution wallet | 0.001 |
| allowlist-admin | `ALLOWLIST_ADMIN` | Swap ALLOWLIST_ADMIN_ROLE (`setAllowed` takers). Survives the timelock hand-over (GYL-1050) | The deployer's transient copy is revoked in-band | 0.001 |
| distribution | `WITHDRAWAL_WALLET` = `SWAP_DISTRIBUTION_WALLET` | Swap `withdrawalWallet`: the fixed `withdraw` destination and the hop-2 source of transfer-first issuance | The gateway requires it distinct from every other custody wallet | 0.001 |
| sanctions-admin | `MOCK_SANCTIONS_OWNER` | MockSanctionsList owner (add/remove), standing in for the SanctionsOracleMirror keeper | Otherwise DeployDevNet would make the deployer the owner. This deploy pre-deploys the mock and passes `SANCTIONS_LIST`, which is the mainnet code path | 0.001 |
| taker | `SMOKE_TAKER` | Test AP: allowlisted on the swap, holds 1,000 gUSD. Not a protocol role | — | 0.002 |

Contracts that hold roles:

- **TimelockController** (delay **0**, EXECUTOR open, administers itself) is DEFAULT_ADMIN
  everywhere.
- **IssuanceManager** holds MINTER + BURNER on every bond token.
- **TokenFactory** holds REGISTRAR on the IssuanceManager.

DeployDevNet also whitelists Anvil account[1] (`0x7099…79C8`, a public key) as an AP on
dev chains. This is harmless here; mainnet refuses it.

### Moving a role to the gateway / AWS KMS

None of these steps redeploys anything. "timelock" means: the governance key calls
`schedule(target, 0, data, 0x0, salt, 0)` and then `execute(target, 0, data, 0x0, salt)`.
They can run back to back because the delay is 0; on mainnet there are 48 h between them.

| Role | Gateway signer (dev → KMS) | How to rotate it |
|---|---|---|
| quote-signer | `SWAP_QUOTE_SIGNER_KEY` → `SWAP_QUOTE_SIGNER_KMS_KEY_ID` | timelock: `swap.grantRole(QUOTE_SIGNER_ROLE, kms)`, `revokeRole(QUOTE_SIGNER_ROLE, old)`, `bumpQuoteEpoch()`. There is no `setQuoteSigner`: the role *is* the signer registry |
| nav-feed-owner | `EVM_KMS_NAV_KEY_ID` | Per feed (×3): the current owner calls `transferOwnership(kms)`, then the KMS key calls `acceptOwnership()` (Ownable2Step, no timelock). The new owner must not be ops or the timelock |
| subscriber / redeemer | `EVM_KMS_SUBSCRIBER_KEY_ID` / `EVM_KMS_REDEEMER_KEY_ID` | timelock: `issuanceMgr.grantRole` / `revokeRole(SUBSCRIBER_ROLE` or `REDEEMER_ROLE, …)` |
| distribution | `EVM_KMS_SWAP_DISTRIBUTION_KEY_ID`; `SWAP_DISTRIBUTION_WALLET` must equal it | timelock: `swap.setWithdrawalWallet(kms)` |
| allowlist-admin | `EVM_KMS_SWAP_ADMIN_KEY_ID` | timelock: `swap.grantRole` / `revokeRole(ALLOWLIST_ADMIN_ROLE, …)` |
| whitelist-admin | `EVM_KMS_WHITELIST_KEY_ID` | timelock: `issuanceMgr.grantRole` / `revokeRole(WHITELIST_ADMIN_ROLE, …)` |
| treasurer | platform signer (`EVM_KMS_KEY_ID`; Fordefi on mainnet) | timelock: `swap.grantRole` / `revokeRole(TREASURER_ROLE, …)` |
| ops | Gnosis Safe / Fordefi | timelock: grant/revoke PAUSER (+ DOCUMENT) on each token and on the swap. A NAV feed's `emergencyUpdater` is **immutable**, so changing the guardian means new feeds plus `forwarder.setUpstreamOracle` through the timelock |
| governance | Gnosis Safe | The timelock administers itself: timelock `grantRole(PROPOSER_ROLE` and `CANCELLER_ROLE, safe)`, then revoke the derived key. `updateDelay(172800)` goes the same way |
| sanctions-admin | — | Cannot be rotated: the mock's owner is fixed at construction. Mainnet uses a SanctionsOracleMirror with a keeper role |

Example (quote signer → KMS):

```bash
set -a; . ~/.gyld/bsc-testnet-derived-keys.env; . docs/deploy/bsc-testnet-addresses.env; set +a
RPC=https://bsc-testnet-rpc.publicnode.com
DATA=$(cast calldata "grantRole(bytes32,address)" $(cast keccak QUOTE_SIGNER_ROLE) $KMS_QUOTE_SIGNER_ADDRESS)
SALT=$(cast format-bytes32-string kms-quote-signer); NONE=0x$(printf '%064d' 0)   # predecessor
cast send $TIMELOCK_ADDRESS "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $EVM_ATOMIC_SWAP_ADDRESS 0 $DATA $NONE $SALT 0 --private-key $GOVERNANCE_PK --rpc-url $RPC --legacy
cast send $TIMELOCK_ADDRESS "execute(address,uint256,bytes,bytes32,bytes32)" \
  $EVM_ATOMIC_SWAP_ADDRESS 0 $DATA $NONE $SALT --private-key $GOVERNANCE_PK --rpc-url $RPC --legacy
# then the same for revokeRole(old signer) and bumpQuoteEpoch()
```

### Rotating every role to AWS KMS (GLD-807)

`script-bsc/BscKmsRoleRotation.s.sol` does the table above in one go; targets are in
`script-bsc/kms-roles.bsc-testnet.env`. Rehearse first: `script-bsc/simulate-kms-rotation.sh`
(Anvil fork, AWS creds). Fund the KMS NAV owner (~0.02 tBNB) before Phase C. Run each phase
once without `--broadcast` (dry run), then with it.

```bash
set -a; . docs/deploy/bsc-testnet-addresses.env; . script-bsc/kms-roles.bsc-testnet.env; set +a
RPC=https://bsc-testnet-rpc.publicnode.com; SOL=script-bsc/BscKmsRoleRotation.s.sol:BscKmsRoleRotation
TX="--rpc-url $RPC --legacy --with-gas-price 0.1gwei --slow"   # append --broadcast after the dry run
# 0 - keys derive the KMS_* addresses; KMS governance signs this rotation (exports KMS_GOVERNANCE_SIG)
out=$(script-bsc/check-kms-addresses.sh) || exit 1; eval "$out"
export QUOTE_EPOCH_BEFORE=$(cast call $EVM_ATOMIC_SWAP_ADDRESS 'quoteEpoch()(uint256)' --rpc-url $RPC)
# A - old governance: one timelock batch (roles, withdrawal wallet, quote epoch, then PROPOSER + CANCELLER)
( . ~/.gyld/bsc-testnet-derived-keys.env
  forge script $SOL --sig 'rotateRoles()' --sender $GOVERNANCE_MULTISIG --private-key "$GOVERNANCE_PK" $TX )
# B - old NAV owner: transferOwnership(KMS NAV owner) on the 3 feeds
( . ~/.gyld/bsc-testnet-derived-keys.env
  forge script $SOL --sig 'transferNavOwnership()' --sender $NAV_FEED_OWNER --private-key "$NAV_FEED_OWNER_PK" $TX )
# C - KMS NAV owner: acceptOwnership() on the 3 feeds
AWS_KMS_KEY_ID=$KMS_NAV_FEED_OWNER_KEY_ID forge script $SOL --sig 'acceptNavOwnership()' --sender $KMS_NAV_FEED_OWNER --aws $TX
# V - read-only
forge script $SOL --sig 'verify()' --rpc-url $RPC
```

Not rotatable:
- each NAV feed's `emergencyUpdater` (immutable; stays the old ops key).
- the gUSD `minter` (immutable; the deployer).
- the `MockSanctionsList` owner (no setter; `KMS_SANCTIONS_OWNER` is for the next deploy).

**Rollback:** only KMS governance can undo Phase A, through the same timelock `grantRole` /
`revokeRole` calls; feeds go back by the same two-step `transferOwnership` / `acceptOwnership`.

## Providing the key

Use a **temporary** MetaMask account holding only testnet BNB. Do not use one that holds
anything on a real chain.

```bash
mkdir -p ~/.gyld && chmod 700 ~/.gyld
# MetaMask → ⋮ → Account details → Show private key → copy. Then (macOS):
(umask 077; pbpaste > ~/.gyld/bsc-testnet-pk) && pbcopy </dev/null   # also clears the clipboard
stat -f %Lp ~/.gyld/bsc-testnet-pk                                   # 600
```

- **Format.** The file holds the bare 64-hex key. A `0x` prefix and a trailing newline
  are tolerated.
- **Permissions.** The script refuses the file unless its mode is 600 or 400. Use
  `BSC_TESTNET_PK_FILE=<path>` to keep it elsewhere.
- **Where the key goes.** It only ever reaches forge through the environment
  (`BSC_TESTNET_PK`): never a command line, never a log. The only file the script
  writes key material to is the chmod-600 derived-keys file.
- **Avoid** `export BSC_TESTNET_PK=…` at a prompt: it lands in your shell history.

Fund the deployer's address (`script-bsc/deploy-bsc-testnet.sh plan` prints it) from the
BNB Chain faucet, https://www.bnbchain.org/en/testnet-faucet (about 0.3 tBNB/day per
address).

## Steps

`script-bsc/deploy-bsc-testnet.sh [plan|keys|deploy|nav|smoke|verify|all]`. The default
is `all` = deploy + smoke + verify.

1. **Preflight.** Checks the tools, the key file's mode and format, and that the RPC
   (default `https://bsc-testnet-rpc.publicnode.com`, override with `RPC_URL`) is
   chain 97. Then it derives and prints the role plan. The deployer must hold at least
   `MIN_DEPLOYER_TBNB` (default 0.05). Before broadcasting, the script asks you to
   type `broadcast`; `CONFIRM=1` skips the prompt.
2. **Keys.** Writes `~/.gyld/bsc-testnet-derived-keys.env` (chmod 600). It refuses to
   overwrite a file derived from a different deployer.
3. **Deploy.** One forge broadcast, `--slow --legacy`, 0.1 gwei:
   1. Top up each role key to its tBNB float.
   2. Deploy `MockSanctionsList` (chain-salted CREATE2, owner = sanctions-admin).
   3. Run `DeployDevNet` with `TIMELOCK_DELAY_SECONDS=0`, `SANCTIONS_LIST` = the mock
      and every role env var pinned. Because governance is not the deployer, it stops
      after **Phase 1**, exactly as on mainnet: the factory hand-off is pending and no
      series exists yet.
   4. Run `DeployMockStablecoin`: 18dp gUSD, no initial mint.
   5. **Governance Phase 2** through the timelock: `factory.acceptOwnership`, then
      `deployToken` for CAT, C and KO, with the same parameters and ISIN guards as
      DeployDevNet.
   6. The NAV owner pushes **$1.00 = 1e8** to each feed (inside the FIND-003
      $0.10–$2.00 range). This must happen *before* the swap registers the series,
      or `registerSeries` reverts `NavFeedNotPriced` (FIND-002).
   7. Run `DeployAtomicSettlement` with `USDC_ADDRESS` = gUSD, `SERIES_TOKENS` = the
      3 tokens, the dedicated `QUOTE_SIGNER`, `ALLOWLIST_ADMIN`, `TREASURER_ADDRESS`,
      `WITHDRAWAL_WALLET` and `OPS_MULTISIG`, and `TIMELOCK_ADDRESS`. It registers the
      series, then hands DEFAULT_ADMIN to the timelock. It *skips* the AP whitelisting
      because the deployer lacks WHITELIST_ADMIN_ROLE, which is the mainnet shape.
   8. The whitelist admin calls `addToWhitelist(swap)`. The subscriber calls
      `subscribe` for 1,000 of each series into the swap. The deployer mints
      10,000 gUSD to the swap and 1,000 to the taker. The allowlist admin calls
      `setAllowed(taker)`.

   The simulation prints every address before anything is sent. It is saved and
   installed as `docs/deploy/bsc-testnet-addresses.env` once the broadcast succeeds.
4. **Smoke.** The quote signer signs EIP-712 quotes for a BUY (10 gUSD → 10 CAT) and a
   REDEEM (10 CAT → 10 gUSD), each valid 85 s (cap 90 s). The taker approves and calls
   `executeSwap` for each. The script asserts the balances and that the quote ids are
   consumed.
5. **Verify** (read-only) runs 70 on-chain assertions:
   - every role holder in the plan above, including the timelock's own roles;
   - the deployer holds nothing except the gUSD minter role;
   - `cashDecimals() == 18`;
   - each feed's range is 1e7..2e8 and its absolute bounds are 1e7..5e8;
   - each forwarder's owner and upstream, and each series registration.

   It then rewrites the address file from what the chain returns.

## Estimated tBNB

Measured end-to-end on an Anvil fork of BSC testnet on 2026-10-13: 62 transactions at
0.1 gwei. BSC testnet's current gas price is 0.1 gwei, with ~0.45 s blocks.

| | Gas | tBNB |
|---|---|---|
| Deployer (3 deploy scripts, sanctions mock, mints, funding txs) | 16.8 M | 0.00168 |
| Governance (Phase 2: accept + 3 × `deployToken` via the timelock) | 7.4 M | 0.00074 |
| Subscriber, NAV owner, whitelist and allowlist admins | 0.77 M | 0.00008 |
| Smoke (taker, 4 txs) | 0.46 M | 0.00005 |
| **Total gas burned** | **25.5 M** | **0.00255** |
| Role-key floats (stay on those keys for later operations) | | 0.0200 |
| **Deployer outflow** | | **≈ 0.0217** |

The preflight floor is 0.05 tBNB, about 2.3× the need, so one faucet drip covers it.
Forge's own pre-broadcast estimate is higher, 0.0036 tBNB of gas, because it sizes gas
limits ×1.3. Re-running `smoke` costs ≈ 0.00005 and `nav` ≈ 0.00003, both paid from
the role floats.

## Dry run and rehearsal

- **`DRY_RUN=1 script-bsc/deploy-bsc-testnet.sh`** runs forge **without
  `--broadcast`**. The whole deploy + smoke + verify executes in **one** simulation
  against a fork of the live chain, with your real key, balance and nonce. Nothing is
  sent.
  - The CREATE2 addresses it prints are the ones a real run will get. gUSD's depends
    on the deployer's nonce.
  - `DRY_RUN=1` with `smoke` or `nav` simulates just that step.
- **Full rehearsal on an Anvil fork** (real transactions, local only):

  ```bash
  anvil --fork-url https://bsc-testnet-rpc.publicnode.com --port 8598 --silent &
  RPC_URL=http://127.0.0.1:8598 CONFIRM=1 script-bsc/deploy-bsc-testnet.sh all
  kill %1
  ```

  - With a local RPC, the script writes keys, addresses and forge's broadcast journal
    to `*.fork.env` / `~/.gyld/bsc-testnet/`. The real files are never touched, and a
    later real `RESUME=1` cannot pick up fork transactions.
  - Before each step the script mines one block. An idle automining fork's `latest`
    timestamp goes stale, and forge simulates against it, which would expire the 85 s
    smoke quotes.

## Re-running safely

- **Simulation first, always.** Every step simulates its full sequence before sending
  anything. A failing guard costs no gas: an occupied CREATE2 address, a role clash, a
  stale NAV.
- **`deploy` refuses when the address file points at a live swap.** A second stack is
  not possible anyway:
  - **With the same key**, every chain-salted CREATE2 address collides.
  - **With any key**, the implementations (GyldBondToken, IssuanceManager,
    GyldAtomicSwap) are salted by name and chain only. **One DeployDevNet per compiled
    bytecode per chain:** a fresh stack on 97 needs a source change, which changes the
    bytecode. Someone else deploying this exact commit to 97 first would block the
    run, but only in simulation.
- **Interrupted broadcast** (RPC timeout part-way, or a key that ran dry): run
  `RESUME=1 script-bsc/deploy-bsc-testnet.sh deploy`.
  - Forge `--resume` sends only the missing transactions from
    `broadcast/BscTestnetStack.s.sol/97/deploy-latest.json`, then the script installs
    the address manifest it saved from the simulation. Do not delete that directory
    between the two runs.
  - Forge re-executes `deploy()` just to collect signers. `RESUME=1` makes it only
    register the 14 keys, because a real re-run would trip the CREATE2 guards on the
    half-landed stack.
  - Rehearsed: a fork deploy cut off after 29 of 58 transactions, then resumed to
    58/58, followed by smoke OK and verify 70/70.
- **Gas funding is top-up.** A re-run sends only the difference to each float.
- **`nav`** re-pushes each feed's *current* answer (no price move) once at least 1 h
  has passed since the last push (`MIN_UPDATE_INTERVAL`). Swaps refuse a NAV older
  than 24 h (`StaleNav`), and there is no keeper on testnet, so run `nav` at least
  daily before using the stack. `smoke` checks this up front and tells you.
- **`smoke`** takes its quote ids from the block timestamp, so it can be re-run any
  number of times. The taker ends where it started.
- **`verify`** is read-only and safe at any time.
- **`keys`** is deterministic and idempotent.

## What differs from BSC mainnet (56)

| | This testnet stack | Mainnet (production path) |
|---|---|---|
| Timelock delay | 0 (`schedule` + `execute` back to back) | ≥ 48 h, enforced by `requireProdMinDelay` / `assertTimelockSane` |
| Role holders | Throwaway keys derived from one MetaMask key | Governance, ops and whitelist admin: Gnosis Safes. Subscriber, redeemer, treasurer and distribution: Fordefi MPC. NAV owner, quote signer and allowlist admin: AWS KMS. None may be the deployer |
| Role-split guards | `requireDistinct` / `requireNotDeployer` are no-ops on 97. This stack satisfies them anyway (verify asserts pairwise distinctness) | Enforced in-band, and the deploy aborts on a violation |
| Sanctions oracle | `MockSanctionsList`, owned by sanctions-admin | `SanctionsOracleMirror` + a live-SDN probe (`SANCTIONS_PROBE_FLAGGED`, FIND-006/008); a mock is refused by bytecode |
| Cash token | gUSD: 18dp, test minter = deployer | A real 18dp BNB-chain stablecoin. `DeployMockStablecoin` fails closed off dev chains |
| Anvil account[1] | Whitelisted AP (DeployDevNet, dev chains only) | Refused |
| Swap notional cap | Contract default: $1 M per NAV round per series | Policy: $10 M per series, set via `setMaxNavRoundNotionalFor` through the timelock |
| NAV keep-alive | Manual `nav` step | Gateway `NavPublishDriver` on the KMS NAV key |
| Source verification | Optional (`VERIFY_CONTRACTS=1`) | Required |

## Verifying contracts on BscScan

`VERIFY_CONTRACTS=1` adds `--verify` to the deploy broadcast. You need the normal
`ETHERSCAN_API_KEY`: Etherscan V2 covers chain 97 and there is no separate BscScan key.
If verification fails (rate limit, flaky RPC), verify afterwards. Foundry resolves the
`bsc-testnet` `[etherscan]` entry from the chain id:

```bash
forge verify-contract --chain 97 --watch \
  <gUSD address> contracts/test/GyldTestUSD.sol:GyldTestUSD \
  --constructor-args $(cast abi-encode "constructor(uint8,address)" 18 $DEPLOYER_ADDRESS)

forge verify-contract --chain 97 --watch <address> <path>:<ContractName> \
  --constructor-args <abi-encoded args>
```

Use `--chain 97` or `--chain bsc-testnet`, hyphenated. `bsc_testnet` is rejected as a
chain name; it is only the RPC alias in `foundry.toml`.

## Gateway env (DEV on 97)

`docs/deploy/bsc-testnet-addresses.env` uses the gateway's own names:

- `EVM_CHAIN_ID=97`
- `EVM_FACTORY_ADDRESS`, `EVM_ISSUANCE_MANAGER`, `EVM_ATOMIC_SWAP_ADDRESS`
- `USDC_CONTRACT_ADDRESS` (gUSD)
- `CHAINALYSIS_SANCTIONS_CONTRACT` / `MOCK_SANCTIONS_ADDRESS`
- `SWAP_DISTRIBUTION_WALLET`

The matching dev keys are in the derived-keys file, for example `QUOTE_SIGNER_PK` →
`SWAP_QUOTE_SIGNER_KEY` and `DISTRIBUTION_PK` → `PRIVKEY_SWAP_DISTRIBUTION_SIGNING_KEY`.

Two caveats before pointing a gateway here:

- **Cash decimals.** Its cash-amount handling must use the token's **18** decimals,
  not a hard-coded 6.
- **Mock sanctions owner.** `mock_sanction_address` signs with the gateway's platform
  key, but the mock is owned by sanctions-admin. Use `SANCTIONS_ADMIN_PK` directly
  (`cast send $MOCK_SANCTIONS_ADDRESS "setSanctioned(address,bool)" …`).
