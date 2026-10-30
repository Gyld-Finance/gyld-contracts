# BSC testnet (chain 97) — fresh stack on AWS KMS

GLD-807. Every role is its own AWS KMS key (account 159903201072, eu-west-2; the same 14
keys serve every testnet). 97 is **not** a dev chain: `DeployGuards` runs every production
guard there (`requireNotDeployer`, `requireDistinct`, `requireProdContract`,
`requireProdNotMock`, `requireSanctionsOracleAnswers`, `assertTimelockSane`) with one
exception — the timelock floor is **5 minutes** instead of 48 h
(`DeployGuards.minTimelockDelay()`). No mocks: the sanctions oracle is the production
`SanctionsOracleMirror`, the cash leg is the real BSC testnet USDT
`0x337610d27c682E347C9cD60BD4b3b107C9d34dDd` (18 dp; the swap stores `cashDecimals() == 18`).

| File | What |
|---|---|
| `script-bsc/kms-roles.bsc-testnet.env` | The 14 KMS addresses + key ids (public) |
| `script-bsc/check-kms-addresses.sh` | Step 0: each key id derives its address |
| `script-bsc/BscKmsStack.s.sol` | `runA` / `runB` / `runC` / `verify` |
| `script-bsc/simulate-kms-stack.sh` | Full rehearsal on an Anvil fork (impersonated signers) |
| `docs/deploy/bsc-testnet-addresses.v1.env` | The retired GLD-713 stack (raw derived keys) |

## Roles

| KMS key | On-chain role | tBNB to fund |
|---|---|---|
| `KMS_DEPLOYER` | Broadcasts the deploy scripts; holds **no** role afterwards | 0.05 |
| `KMS_GOVERNANCE` | Timelock sole proposer + canceller; mirror admin | 0.02 |
| `KMS_NAV_FEED_OWNER` | Owner of the three NAV feeds (`updateAnswer`) | 0.02 |
| `KMS_SUBSCRIBER` | IssuanceManager SUBSCRIBER (mint) | 0.02 |
| `KMS_REDEEMER` | IssuanceManager REDEEMER (burn) | 0.01 |
| `KMS_WHITELIST_ADMIN` | IssuanceManager WHITELIST_ADMIN | 0.01 |
| `KMS_ISSUANCE_PAUSER` | IssuanceManager ISSUANCE_PAUSER | 0.005 |
| `KMS_OPS` | Token + swap PAUSER, token DOCUMENT, NAV-feed `emergencyUpdater` | 0.01 |
| `KMS_QUOTE_SIGNER` | Swap QUOTE_SIGNER (off-chain signatures only) | 0 |
| `KMS_TREASURER` | Swap TREASURER | 0.02 |
| `KMS_ALLOWLIST_ADMIN` | Swap ALLOWLIST_ADMIN | 0.01 |
| `KMS_WITHDRAWAL_WALLET` | Swap `withdrawalWallet` | 0.02 |
| `KMS_SANCTIONS_OWNER` | Mirror SANCTIONS_UPDATER (seeds the SDN list) | 0.005 |
| `KMS_USER_WITHDRAWAL` | None on-chain (gateway wallet) | 0.02 |

The deploy itself costs ~0.0024 tBNB at 0.1 gwei (rehearsal: deployer 26 tx / 16.1 M gas,
governance 2 tx / 7.2 M gas, NAV owner 3, subscriber 3, whitelist admin 1, sanctions
owner 1); the floats above are ~10× for later operations.

## Inputs

```bash
cd lib/gyld-contracts
set -a; . script-bsc/kms-roles.bsc-testnet.env; set +a
export AWS_REGION=eu-west-2 RPC=https://bsc-testnet-rpc.publicnode.com
export DEPLOY_SALT_TAG=kms1          # fresh CREATE2 addresses; v1 used the same bytecode
export NAV_ANSWER_8DP=100000000       # $1.00 — must sit inside the feeds' $0.10–$2.00 range
export SANCTIONS_PROBE_FLAGGED=0x098B716B8Aaf21512996dC57EB0615e2383E2f96  # re-check: on the CURRENT SDN list
F="script-bsc/BscKmsStack.s.sol:BscKmsStack"
OPTS="--rpc-url $RPC --aws --slow --legacy --with-gas-price 0.1gwei"   # no --broadcast: dry run
```

The probe must be flagged **today** — check it against Chainalysis on Ethereum
(`cast call 0x40C57923924B5c5c5455c48D93317139ADDaC8fb 'isSanctioned(address)(bool)' $SANCTIONS_PROBE_FLAGGED --rpc-url <eth rpc>` → `true`).
The feeds are created with `minAnswer..maxAnswer = 1e7..2e8` ($0.10–$2.00); only the
timelock (`rangeGovernor`) can move it later, within $0.10–$5.00.

## Run it

Rehearse first: `script-bsc/simulate-kms-stack.sh` (must end `SIMULATION GREEN`). Each
on-chain step below is shown as its **dry run** (no `--broadcast`); read the output, then
run the same command again with `--broadcast` appended. `AWS_KMS_KEY_IDS` lists the keys
that sign in that step.

```bash
# Step 0 — no transaction: every key id derives its address, and the governance key signs
# chain 97 + all 14 addresses + DEPLOY_SALT_TAG. runA refuses to deploy without that proof.
out=$(script-bsc/check-kms-addresses.sh) || exit 1; eval "$out"   # exports KMS_GOVERNANCE_SIG

# Run A — deployer + sanctions owner: mirror, SDN seed, DeployDevNet (delay 300 s)
A="forge script $F --sig runA() --sender $KMS_DEPLOYER $OPTS"
AWS_KMS_KEY_IDS=$KMS_DEPLOYER_KEY_ID,$KMS_SANCTIONS_OWNER_KEY_ID $A               # dry run
AWS_KMS_KEY_IDS=$KMS_DEPLOYER_KEY_ID,$KMS_SANCTIONS_OWNER_KEY_ID $A --broadcast   # send
export EVM_FACTORY_ADDRESS=<@@ line> EVM_ISSUANCE_MANAGER=<@@ line>

# Run B — governance schedules one batch: factory acceptOwnership + CAT / C / KO deployToken
B="forge script $F --sig runB() --sender $KMS_GOVERNANCE $OPTS"
AWS_KMS_KEY_IDS=$KMS_GOVERNANCE_KEY_ID $B               # dry run
AWS_KMS_KEY_IDS=$KMS_GOVERNANCE_KEY_ID $B --broadcast   # send

# Wait >= 300 s (run C fails fast with the remaining seconds if run early).
# Run C — governance executes, NAV owner pushes NAV, deployer DeployAtomicSettlement (USDT,
# no takers, admin -> timelock), whitelist admin whitelists the swap. No inventory is
# minted here: fund it through the platform's fund-inventory route (GLD-1054).
C="forge script $F --sig runC() --sender $KMS_DEPLOYER $OPTS"
KEYS=$KMS_DEPLOYER_KEY_ID,$KMS_GOVERNANCE_KEY_ID,$KMS_NAV_FEED_OWNER_KEY_ID,$KMS_WHITELIST_ADMIN_KEY_ID
AWS_KMS_KEY_IDS=$KEYS $C               # dry run
AWS_KMS_KEY_IDS=$KEYS $C --broadcast   # send
export EVM_ATOMIC_SWAP_ADDRESS=<@@ line>

# Verify — read-only; reverts on the first drift
forge script $F --sig 'verify()' --rpc-url $RPC
```

Interrupted mid-broadcast? Re-running run C finishes it — each step is skipped once on
chain, and a finished C sends nothing — unless the swap deploy stopped midway: then run C
stops with the missing step and whitelists nothing; finish it with `--resume`. For
A or B, finish with the same command plus `--resume`.

`verify` asserts: timelock `minDelay == 300`, governance sole proposer/canceller, executors
open, deployer holds no role on the timelock, IssuanceManager, mirror, swap or tokens;
factory owned by the timelock with nothing pending; `sanctionsList` is the mirror, which
flags the probe and not the deployer; swap cash = USDT at 18 dp; every role on its KMS key;
three series registered with NAV in range, feed owner = KMS NAV owner; swap whitelisted.

After the real deploy, write the `@@` addresses to `docs/deploy/bsc-testnet-addresses.env`.

## Fordefi vaults (GLD-978)

The same stack with every role on its own Fordefi vault **at deploy** ("Option 2"):
`script-bsc/BscFordefiStack.s.sol`, vaults in `script-bsc/fordefi-roles.bsc-testnet.env`,
rehearsal `script-bsc/simulate-fordefi-stack.sh` (must end `SIMULATION GREEN`). The **KMS
deployer** (`STACK_DEPLOYER` = `KMS_DEPLOYER`) signs every deploy exactly as in the KMS flow and
holds no role afterwards; Fordefi signs only what a role vault must (and nothing anyone may
send: the timelock's `executeBatch` goes from the deployer). Layout differences from KMS:
`FORDEFI_SWAP_PAUSE` = swap PAUSER **and** ISSUANCE_PAUSER; `FORDEFI_WHITELISTER` =
WHITELIST_ADMIN **and** swap ALLOWLIST_ADMIN; `FORDEFI_FREEZE` = token PAUSER + DOCUMENT, NAV
`emergencyUpdater`; no user-withdrawal role. All other addresses pairwise distinct.

Each sub-phase has one signer kind; run them in order, each confirmed before the next starts:

| # | Sub-phase | Signer | Txs | Fordefi approvals |
|---|---|---|---|---|
| 0 | `governanceProofMessage()` | Contract Admin `personal_sign` | 0 | 1 (3-of-4) |
| 1 | `runA1()` mirror | KMS deployer | 1 | – |
| 2 | `runA2()` seed SDN probe | Blocklist Updater | 1 | 1 |
| 3 | `runA3()` DeployDevNet | KMS deployer | 14 | – |
| 4 | `runB()` `scheduleBatch` | Contract Admin | 1 | 1 (3-of-4) |
| – | wait ≥ 300 s after 4 is mined | | | |
| 5 | `runC1()` `executeBatch` | KMS deployer | 1 | – |
| 6 | `runC2()` NAV × 3 | NAV Feeder | 3 | auto-approve |
| 7 | `runC3()` DeployAtomicSettlement | KMS deployer | 11 | – |
| 8 | `runC4()` whitelist swap | Whitelister | 1 | 1 |

No step mints inventory (GLD-1054): a mint outside the platform never reaches its ledger and
supply reconciliation halts every series. Fund the swap afterwards through the platform's
`POST /admin/swap/fund-inventory?chain=<chain>` (the operator console's Atomic Swap page).

```bash
set -a; . script-bsc/kms-roles.bsc-testnet.env; . script-bsc/fordefi-roles.bsc-testnet.env
. tools/fordefi-replay/roles.env; set +a                               # vaults, then API creds
export AWS_REGION=eu-west-2 AWS_KMS_KEY_IDS=$KMS_DEPLOYER_KEY_ID RPC=https://bsc-testnet-rpc.publicnode.com
export DEPLOY_SALT_TAG=<fresh tag> NAV_ANSWER_8DP=100000000
export SANCTIONS_PROBE_FLAGGED=0x0000000000000000000000000000000000000BAD   # synthetic: Fordefi refuses real SDN addresses in calldata
# Run this block in bash (`bash`), not zsh.
F="script-bsc/BscFordefiStack.s.sol:BscFordefiStack" D=broadcast/BscFordefiStack.s.sol/97/dry-run
KMS=(--sender "$STACK_DEPLOYER" --rpc-url "$RPC" --aws --slow --legacy --with-gas-price 0.1gwei)
R="node tools/fordefi-replay/replay.mjs"
kms() { forge script "$F" --sig "$1" "${KMS[@]}" "${@:2}"; }  # dry run; read it, then again with --broadcast
fordefi() {  # a stale journal must never be shown as the plan to approve
  local j="$D/${1%%(*}-latest.json"; rm -f "$j"
  forge script "$F" --sig "$1" --sender "$2" --rpc-url "$RPC" || return
  if [ -f "$j" ]; then $R "$j"; else echo "nothing to send"; fi
}
# fordefi = dry run (never --broadcast) + plan table and PLAN_SHA256; a second person approves the
# hash, then: PLAN_SHA256=<hash> $R $D/<sig>-latest.json --execute   (sends through Fordefi)

# 0 — the 32 bytes binding chain 97, every address (deployer included), the layout tag and
# DEPLOY_SALT_TAG; Contract Admin personal_signs the RAW bytes. runA1/runA3 revert without it.
forge script $F --sig 'governanceProofMessage()' --rpc-url $RPC
export FORDEFI_GOVERNANCE_SIG=$(node tools/fordefi-replay/sign-message.mjs 0x<the 32 bytes>)

kms 'runA1()'; kms 'runA1()' --broadcast                    # 1
fordefi 'runA2()' $FORDEFI_BLOCKLIST_UPDATER                # 2, then --execute runA2
kms 'runA3()'; kms 'runA3()' --broadcast                    # 3; export EVM_FACTORY_ADDRESS + EVM_ISSUANCE_MANAGER (@@)
fordefi 'runB()' $FORDEFI_CONTRACT_ADMIN                    # 4, then --execute runB; wait >= 300 s
kms 'runC1()'; kms 'runC1()' --broadcast                    # 5 (refuses with the seconds left if early)
fordefi 'runC2()' $FORDEFI_NAV_FEEDER                       # 6, then --execute runC2
kms 'runC3()'; kms 'runC3()' --broadcast                    # 7
fordefi 'runC4()' $FORDEFI_WHITELISTER                      # 8, then --execute runC4; export EVM_ATOMIC_SWAP_ADDRESS (@@)
forge script $F --sig 'verify()' --rpc-url $RPC
```

runA2 and runC1–runC4 skip what is on chain, so re-dry-running a finished one plans 0 tx;
runA1, runA3 and runB refuse a re-run once done (occupied CREATE2 address, batch already
scheduled) — a safe revert, not a failure. A KMS
broadcast that stopped midway finishes with `--resume`, a replay by re-running `--execute`.
The replay refuses any `from` that is not a mapped vault, so a deployer tx can never reach
Fordefi; forge `--aws` holds only the deployer key, so a vault tx can never reach KMS. All-Fordefi
instead (no KMS): set `STACK_DEPLOYER` and `FORDEFI_DEPLOYER_ADDRESS` to a Fordefi Deployer vault
and run the KMS sub-phases as `fordefi` too.

Fordefi: Contract Admin stays 3-of-4 (steps 0 and 4: line approvers up first); NAV Feeder
auto-approves; Blocklist Updater, Whitelister and Subscriber approve per their vault policy.
No Fordefi Deployer vault or temporary allow rule is needed.

Rehearsal: 36 tx / 24.0 M gas — KMS deployer 27 (23.2 M), Contract Admin 1, NAV Feeder 3,
Subscriber 3, Whitelister 1, Blocklist Updater 1. Fund the deployer and those five vaults as in
the KMS table.
