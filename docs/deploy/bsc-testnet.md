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
OPTS="--rpc-url $RPC --aws --slow --legacy --with-gas-price 0.1gwei"
```

The probe must be flagged **today** — check it against Chainalysis on Ethereum
(`cast call 0x40C57923924B5c5c5455c48D93317139ADDaC8fb 'isSanctioned(address)(bool)' $SANCTIONS_PROBE_FLAGGED --rpc-url <eth rpc>` → `true`).
The feeds are created with `minAnswer..maxAnswer = 1e7..2e8` ($0.10–$2.00); only the
timelock (`rangeGovernor`) can move it later, within $0.10–$5.00.

## Run it

Rehearse first: `script-bsc/simulate-kms-stack.sh` (must end `SIMULATION GREEN`). Then run
each step **without** `--broadcast` (a dry run), read it, and repeat it with `--broadcast`.
`AWS_KMS_KEY_IDS` lists the keys that sign in that step. A step interrupted mid-broadcast is
finished with the same command plus `--resume`.

```bash
# Step 0 — no transaction: every key id derives its address
script-bsc/check-kms-addresses.sh

# Run A — deployer + sanctions owner: mirror, SDN seed, DeployDevNet (delay 300 s)
AWS_KMS_KEY_IDS=$KMS_DEPLOYER_KEY_ID,$KMS_SANCTIONS_OWNER_KEY_ID \
  forge script $F --sig 'runA()' --sender $KMS_DEPLOYER $OPTS --broadcast
export EVM_FACTORY_ADDRESS=<@@ line> EVM_ISSUANCE_MANAGER=<@@ line>

# Run B — governance schedules one batch: factory acceptOwnership + CAT / C / KO deployToken
AWS_KMS_KEY_IDS=$KMS_GOVERNANCE_KEY_ID \
  forge script $F --sig 'runB()' --sender $KMS_GOVERNANCE $OPTS --broadcast

# Wait >= 300 s. Run C fails fast with the remaining seconds if run early.
# Run C — governance executes, NAV owner pushes NAV, deployer DeployAtomicSettlement (USDT,
# no takers, admin -> timelock), whitelist admin whitelists the swap, subscriber mints
# 1,000 tokens of inventory per series into it.
AWS_KMS_KEY_IDS=$KMS_DEPLOYER_KEY_ID,$KMS_GOVERNANCE_KEY_ID,$KMS_NAV_FEED_OWNER_KEY_ID,$KMS_WHITELIST_ADMIN_KEY_ID,$KMS_SUBSCRIBER_KEY_ID \
  forge script $F --sig 'runC()' --sender $KMS_DEPLOYER $OPTS --broadcast
export EVM_ATOMIC_SWAP_ADDRESS=<@@ line>

# Verify — read-only; reverts on the first drift
forge script $F --sig 'verify()' --rpc-url $RPC
```

`verify` asserts: timelock `minDelay == 300`, governance sole proposer/canceller, executors
open, deployer holds no role on the timelock, IssuanceManager, mirror, swap or tokens;
factory owned by the timelock with nothing pending; `sanctionsList` is the mirror, which
flags the probe and not the deployer; swap cash = USDT at 18 dp; every role on its KMS key;
three series registered with NAV in range, feed owner = KMS NAV owner, 1,000 tokens of
inventory each; swap whitelisted.

After the real deploy, write the `@@` addresses to `docs/deploy/bsc-testnet-addresses.env`.
