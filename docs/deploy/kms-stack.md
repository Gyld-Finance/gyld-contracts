# Fresh stack on AWS KMS — rehearsal testnets

GLD-807, GLD-850. One set of chain-agnostic scripts deploys the stack on a rehearsal
testnet; the chain is picked by its env file in `script-evm/chains/`:

| `<chain>` | Chain id | Cash leg (`CASH_TOKEN`) | Gas | Explorer |
|---|---|---|---|---|
| `katana-testnet` | 737373 (Bokuto) | Team MockUSDC `0x3df20DEB5AE3312541b184B0Df4222A1EbB9de6D`, 6 dp, public mint | EIP-1559 + L1 data fee | bokuto.katanascan.com |

The swap is the audited `GyldAtomicSwap` unchanged: `initialize` refuses a cash token that
does not report 6 decimals, so a chain is only added here when its stablecoin is 6 dp. BSC
testnet (97, 18 dp USDT) is therefore not a profile on this branch, and 97 is not a
rehearsal testnet in `DeployGuards` (it keeps the 48 h floor).

Every role is its own AWS KMS key (account 159903201072, eu-west-2; the same 14 keys serve
every testnet). The chain is not a dev chain: `DeployGuards` runs every production guard
(`requireNotDeployer`, `requireDistinct`, `requireProdContract`, `requireProdNotMock`,
`requireSanctionsOracleAnswers`, `assertTimelockSane`) with one exception — the timelock
floor is **5 minutes** instead of 48 h (`DeployGuards.isRehearsalTestnet()`). The sanctions
oracle is the production `SanctionsOracleMirror`.

The raw-key Katana deploy from GLD-738 (Bokuto as a dev chain, `script-katana/`, now
removed) is superseded by this one; its addresses are kept in
`docs/deploy/katana-testnet-addresses.v1.env` (unused).

| File | What |
|---|---|
| `script-evm/chains/<chain>.env` | `CHAIN_ID`, `RPC_URL`, `CASH_TOKEN`, `CASH_DECIMALS`, `TIMELOCK_DELAY_SECONDS`, `GAS_OPTS`, `NATIVE_SYMBOL`, `EXPLORER` |
| `script-evm/kms-roles.env` | The 14 KMS addresses + key ids (public) |
| `script-evm/check-kms-addresses.sh` | Step 0: each key id derives its address |
| `script-evm/KmsStack.s.sol` | `runA` / `runB` / `runC` / `verify` |
| `script-evm/simulate-kms-stack.sh <chain>` | Full rehearsal on an Anvil fork (impersonated signers) |
| `docs/deploy/<chain>-addresses.env` | The deployed stack (no secrets) |

## Roles and funding

| KMS key | On-chain role | ETH (katana-testnet) |
|---|---|---|
| `KMS_DEPLOYER` | Broadcasts the deploy scripts; holds **no** role afterwards | 0.01 |
| `KMS_GOVERNANCE` | Timelock sole proposer + canceller; mirror admin | 0.005 |
| `KMS_NAV_FEED_OWNER` | Owner of the three NAV feeds (`updateAnswer`) | 0.005 |
| `KMS_SUBSCRIBER` | IssuanceManager SUBSCRIBER (mint) | 0.005 |
| `KMS_REDEEMER` | IssuanceManager REDEEMER (burn) | 0.002 |
| `KMS_WHITELIST_ADMIN` | IssuanceManager WHITELIST_ADMIN | 0.002 |
| `KMS_ISSUANCE_PAUSER` | IssuanceManager ISSUANCE_PAUSER | 0.001 |
| `KMS_OPS` | Token + swap PAUSER, token DOCUMENT, NAV-feed `emergencyUpdater` | 0.002 |
| `KMS_QUOTE_SIGNER` | Swap QUOTE_SIGNER (off-chain signatures only) | 0 |
| `KMS_TREASURER` | Swap TREASURER | 0.005 |
| `KMS_ALLOWLIST_ADMIN` | Swap ALLOWLIST_ADMIN | 0.002 |
| `KMS_WITHDRAWAL_WALLET` | Swap `withdrawalWallet` | 0.005 |
| `KMS_SANCTIONS_OWNER` | Mirror SANCTIONS_UPDATER (seeds the SDN list) | 0.001 |
| `KMS_USER_WITHDRAWAL` | None on-chain (gateway wallet) | 0.005 |

A full run is ~30 transactions (rehearsal: deployer 26 tx / 16.1 M gas, governance 2 tx /
7.2 M gas, NAV owner 3, subscriber 3, whitelist admin 1, sanctions owner 1); the floats
above are ~10× for later operations. On Katana every transaction also pays an L1 data fee,
which the rehearsal's tally does not include: fund with margin and never pass a fixed
`--gas-limit`.

## Inputs

```bash
cd lib/gyld-contracts
CHAIN=katana-testnet
set -a; . script-evm/chains/$CHAIN.env; . script-evm/kms-roles.env; set +a
export AWS_REGION=eu-west-2
export DEPLOY_SALT_TAG=kms1          # fresh CREATE2 addresses; v1 used the same bytecode
export NAV_ANSWER_8DP=100000000       # $1.00 — must sit inside the feeds' $0.30–$2.00 range
export SANCTIONS_PROBE_FLAGGED=0x098B716B8Aaf21512996dC57EB0615e2383E2f96  # re-check: on the CURRENT SDN list
F="script-evm/KmsStack.s.sol:KmsStack"
OPTS="--rpc-url $RPC_URL --aws --slow $GAS_OPTS"   # no --broadcast: dry run
```

Every `KmsStack` run refuses a chain whose id is not `CHAIN_ID`, and `verify` checks the
timelock delay, cash token and the token's own `decimals()` against the chain file.

The probe must be flagged **today** — check it against Chainalysis on Ethereum
(`cast call 0x40C57923924B5c5c5455c48D93317139ADDaC8fb 'isSanctioned(address)(bool)' $SANCTIONS_PROBE_FLAGGED --rpc-url <eth rpc>` → `true`).
The feeds are created with `minAnswer..maxAnswer = 3e7..2e8` ($0.30–$2.00, audit FIND-003);
only the timelock (`rangeGovernor`) can move it later, within $0.10–$5.00.

## Run it

Rehearse first: `script-evm/simulate-kms-stack.sh $CHAIN` (must end `SIMULATION GREEN`).
Each on-chain step below is shown as its **dry run** (no `--broadcast`); read the output,
then run the same command again with `--broadcast` appended. `AWS_KMS_KEY_IDS` lists the
keys that sign in that step.

```bash
# Step 0 — no transaction: every key id derives its address, and the governance key signs
# CHAIN_ID + all 14 addresses + DEPLOY_SALT_TAG. runA refuses to deploy without that proof.
out=$(script-evm/check-kms-addresses.sh) || exit 1; eval "$out"   # exports KMS_GOVERNANCE_SIG

# Run A — deployer + sanctions owner: mirror, SDN seed, DeployDevNet (TIMELOCK_DELAY_SECONDS)
A="forge script $F --sig runA() --sender $KMS_DEPLOYER $OPTS"
AWS_KMS_KEY_IDS=$KMS_DEPLOYER_KEY_ID,$KMS_SANCTIONS_OWNER_KEY_ID $A               # dry run
AWS_KMS_KEY_IDS=$KMS_DEPLOYER_KEY_ID,$KMS_SANCTIONS_OWNER_KEY_ID $A --broadcast   # send
export EVM_FACTORY_ADDRESS=<@@ line> EVM_ISSUANCE_MANAGER=<@@ line>

# Run B — governance schedules one batch: factory acceptOwnership + CAT / C / KO deployToken
B="forge script $F --sig runB() --sender $KMS_GOVERNANCE $OPTS"
AWS_KMS_KEY_IDS=$KMS_GOVERNANCE_KEY_ID $B               # dry run
AWS_KMS_KEY_IDS=$KMS_GOVERNANCE_KEY_ID $B --broadcast   # send

# Wait >= TIMELOCK_DELAY_SECONDS (run C fails fast with the remaining seconds if run early).
# Run C — governance executes, NAV owner pushes NAV, deployer DeployAtomicSettlement
# (CASH_TOKEN, no takers, admin -> timelock), whitelist admin whitelists the swap,
# subscriber mints 1,000 tokens of inventory per series into it.
C="forge script $F --sig runC() --sender $KMS_DEPLOYER $OPTS"
KEYS=$KMS_DEPLOYER_KEY_ID,$KMS_GOVERNANCE_KEY_ID,$KMS_NAV_FEED_OWNER_KEY_ID,$KMS_WHITELIST_ADMIN_KEY_ID,$KMS_SUBSCRIBER_KEY_ID
AWS_KMS_KEY_IDS=$KEYS $C               # dry run
AWS_KMS_KEY_IDS=$KEYS $C --broadcast   # send
export EVM_ATOMIC_SWAP_ADDRESS=<@@ line>

# Verify — read-only; reverts on the first drift
forge script $F --sig 'verify()' --rpc-url $RPC_URL
```

Interrupted mid-broadcast? Re-running run C finishes it — each step is skipped once on
chain, and a finished C sends nothing — unless the swap deploy stopped midway: then run C
stops with the missing step and whitelists/mints nothing; finish it with `--resume`. For
A or B, finish with the same command plus `--resume`.

`verify` asserts: timelock `minDelay == TIMELOCK_DELAY_SECONDS`, governance sole
proposer/canceller, executors open, deployer holds no role on the timelock,
IssuanceManager, mirror, swap or tokens; factory owned by the timelock with nothing
pending; `sanctionsList` is the mirror, which flags the probe and not the deployer; swap
cash = `CASH_TOKEN`, whose `decimals()` is `CASH_DECIMALS`; every role on its KMS key; three series registered
with NAV in range, feed owner = KMS NAV owner, 1,000 tokens of inventory each; swap
whitelisted.

After the real deploy, write the `@@` addresses to `docs/deploy/$CHAIN-addresses.env`.
