# BSC MAINNET (chain 56) — fresh stack, KMS deployer + Fordefi role vaults

GLD-978. The **same hybrid flow as BSC testnet** (`docs/deploy/bsc-testnet.md#fordefi-vaults-gld-978`):

- an **AWS KMS deployer key** (`STACK_DEPLOYER`) sends every deploy sub-phase with forge
  `--aws --slow --legacy --broadcast` (A1 mirror, A3 DeployDevNet, C1 `executeBatch`, C3
  DeployAtomicSettlement) and holds **no role** afterwards (`verify()` checks it);
- **PROD Fordefi vaults** send only the role sub-phases, as forge dry-run plans replayed by
  `tools/fordefi-replay` (0 proof, A2, B, C2, C4).

`BscFordefiStack` enforces the split on 56: only `--sender STACK_DEPLOYER` may `--broadcast`;
runA2 / runB / runC2 / runC4 revert under `--broadcast` / `--resume`. `STACK_DEPLOYER` must
differ from every role vault and from the PROD Fordefi "Deployer" vault
`0xb242Bf9fa856B70365FB43EE780d110f6B9DDAb3`, which is **only a gas wallet**: it forwards BNB
to the KMS deployer and signs nothing in the stack. `BscKmsStack` (all-KMS) refuses 56.

Production guards apply in full (`DeployGuards`: 56 is not a dev chain), including the
**48 h timelock floor**. Everything 97 hard-codes is an input on 56, and each one fails closed
when unset:

| Input | 97 (unchanged) | 56 |
|---|---|---|
| Cash leg | testnet USDT (18 dp) | `CASH_TOKEN` = USDT `0x55d398326f99059fF775485246999027B3197955` or USDC `0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d`; `decimals() == 18` checked |
| Timelock delay | 300 s | `TIMELOCK_DELAY_SECONDS`, default and floor 172800 (48 h), cap 604800 (7 d) |
| Sanctions | local-list mirror, synthetic probe `0x…0BAD` seeded by run A2 | mirror forwarding to `SANCTIONS_FORWARDING_ORACLE`; `SANCTIONS_PROBE_FLAGGED` must be real and flagged by that oracle, so A2 plans 0 tx |
| Bonds | CAT / C / KO | `BOND_<0..2>_{NAME,SYMBOL,CUSIP,ISIN,MATURITY,COUPON,TAG}`; ISIN checksum, CUSIP = ISIN body, NAME contains COUPON, maturity in the future, ISINs/tags distinct |
| First NAV | `NAV_ANSWER_8DP` for all three | `NAV_ANSWER_8DP_<TAG>` per bond, no default |
| Deployer | `STACK_DEPLOYER` (testnet KMS key) | `STACK_DEPLOYER` (PROD KMS key; never the Fordefi gas vault) |

`verify()` checks each against the same per-chain values, including per bond the token name,
symbol, ISIN and maturity, and the feed and forwarder answer == `NAV_ANSWER_8DP_<TAG>`.

| File | What |
|---|---|
| `script-bsc/fordefi-roles.bsc-mainnet.example.env` | Every 56 input (KMS deployer, vaults, chain config, bonds); copy to `fordefi-roles.bsc-mainnet.env` |
| `tools/fordefi-replay/roles.bsc-mainnet.example.env` | Replay env: `CHAIN_ID=56` (Fordefi `evm_56`, bscscan.com), role-vault map (no deployer) |
| `script-bsc/BscFordefiStack.s.sol` | Sub-phases `runA1` … `runC4`, `verify` |
| `script-bsc/simulate-fordefi-stack.sh` | `CHAIN=56`: the whole hybrid on an Anvil fork of 56 (must end `SIMULATION GREEN`) |

## Open decisions (deploy is blocked until each is signed off)

1. Cash token: USDT or USDC (`CASH_TOKEN`).
2. The three bonds: name, symbol, CUSIP, ISIN, maturity, coupon, tag; and their first NAVs.
3. Chainalysis oracle on BSC: `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` has code on 56 and
   flags known Lazarus addresses, but is not yet confirmed with Chainalysis.
4. The timelock delay (default 48 h, max 7 d).
5. PROD Fordefi vaults and policies (Contract Admin quorum); the PROD KMS deployer key.

## Prerequisites

- **KMS deployer key**: a fresh AWS KMS `ECC_SECG_P256K1` sign key, used for nothing else.
  Record its alias/ARN (`AWS_KMS_KEY_IDS`) and its address (`STACK_DEPLOYER`, from
  `cast wallet address --aws`, confirmed by a second person). Its nonce must be 0.
- **AWS credentials** on the deploy host with `kms:Sign` and `kms:GetPublicKey` on that key
  (nothing else needed); `AWS_REGION` set.
- **BNB**: fund the KMS deployer **~0.03 BNB** by a transfer from the PROD Fordefi **Deployer**
  vault (gas wallet); Contract Admin, NAV Feeder, Whitelister **~0.005 BNB** each (Blocklist
  Updater only if A2 plans a tx, which it must not).
- **Fordefi API users** (temporary, API signer online) for Contract Admin, NAV Feeder and
  Whitelister; run from the allowlisted host.

## Pre-flight checklist

- [ ] `forge build`, `forge test`, `python3 ci/check_chain_guards.py script-bsc` green on the commit to deploy.
- [ ] `CHAIN=56 script-bsc/simulate-fordefi-stack.sh` ends `SIMULATION GREEN` against a fork of today's chain, with the real `CASH_TOKEN`, oracle, probe, bond env and `STACK_DEPLOYER`.
- [ ] Every address in `fordefi-roles.bsc-mainnet.env` read back (KMS key from AWS, vaults from the Fordefi console) by two people; KMS deployer + 11 vaults pairwise distinct (the script enforces it).
- [ ] `cast call $SANCTIONS_FORWARDING_ORACLE 'isSanctioned(address)(bool)' $SANCTIONS_PROBE_FLAGGED --rpc-url $BSC_RPC_URL` → `true` on the day.
- [ ] Each ISIN/CUSIP/maturity/coupon checked against the issuer's prospectus; each NAV signed off.
- [ ] Fresh `DEPLOY_SALT_TAG`; `broadcast/BscFordefiStack.s.sol/56/` empty or archived.
- [ ] BNB funded as above; a second person approves every `PLAN_SHA256` before `--execute`.
- [ ] **The KMS deployer is used for nothing else** from step 1 until `verify()` (no transfers,
      no other scripts): its nonces fix every CREATE address the plans and scripts expect.

## Sequence

| # | Sub-phase | Signer | Txs |
|---|---|---|---|
| – | fund the KMS deployer ~0.03 BNB | Fordefi PROD Deployer vault (gas wallet only) | 1 transfer |
| 0 | `governanceProofMessage()` | Contract Admin `personal_sign` (Fordefi) | 0 |
| 1 | `runA1()` mirror (forwarding to the oracle) | KMS deployer (`--aws`) | 1 |
| 2 | `runA2()` seed probe | Blocklist Updater (Fordefi) | 0 (oracle already flags it) |
| 3 | `runA3()` DeployDevNet (delay 48 h) | KMS deployer (`--aws`) | 14 |
| 4 | `runB()` `scheduleBatch` | Contract Admin (Fordefi, quorum) | 1 |
| – | **wait ≥ 48 h** (the configured delay) after 4 is mined | | |
| 5 | `runC1()` `executeBatch` | KMS deployer (`--aws`) | 1 |
| 6 | `runC2()` NAV × 3 | NAV Feeder (Fordefi) | 3 |
| 7 | `runC3()` DeployAtomicSettlement | KMS deployer (`--aws`) | 11 |
| 8 | `runC4()` whitelist swap | Whitelister (Fordefi) | 1 |

No step mints inventory (GLD-1054): fund the swap after `verify()` through the platform's
`POST /admin/swap/fund-inventory?chain=56` (operator console, Atomic Swap page).

Gas (56 fork rehearsal): 32 tx / 23.64 M — KMS deployer 27 tx / 23.21 M,
NAV Feeder 3 / 0.28 M, Contract Admin 1 / 0.10 M, Whitelister 1 / 0.05 M; ≈ 0.024 BNB at 1 gwei
(≈ 0.0024 BNB at 0.1 gwei), ~98 % on the KMS deployer.
Fork rehearsals need an RPC that serves recent historical state (a pruning public
node such as bsc-dataseed fails part-way with "missing trie node"); pass it as `FORK_RPC_URL`.

```bash
# Run in bash, from lib/gyld-contracts, on the allowlisted host.
set -a; . script-bsc/fordefi-roles.bsc-mainnet.env; . tools/fordefi-replay/roles.env; set +a  # roles.env from roles.bsc-mainnet.example.env
export BSC_RPC_URL=<provider> RPC=$BSC_RPC_URL AWS_REGION=<region> AWS_KMS_KEY_IDS=<KMS deployer alias/ARN>
F="script-bsc/BscFordefiStack.s.sol:BscFordefiStack" D=broadcast/BscFordefiStack.s.sol/56/dry-run
KMS=(--sender "$STACK_DEPLOYER" --rpc-url "$RPC" --aws --slow --legacy)
R="node tools/fordefi-replay/replay.mjs"
kms() { forge script "$F" --sig "$1" "${KMS[@]}" "${@:2}"; }  # dry run; read it, then again with --broadcast
fordefi() {  # dry run (never --broadcast) + plan table and PLAN_SHA256; a stale journal is never shown
  local j="$D/${1%%(*}-latest.json"; rm -f "$j"
  forge script "$F" --sig "$1" --sender "$2" --rpc-url "$RPC" || return
  if [ -f "$j" ]; then $R "$j"; else echo "nothing to send"; fi
}
# After review a second person approves: PLAN_SHA256=<hash> $R $D/<sig>-latest.json --execute

forge script $F --sig 'governanceProofMessage()' --rpc-url $RPC                       # 0
export FORDEFI_GOVERNANCE_SIG=$(node tools/fordefi-replay/sign-message.mjs 0x<the 32 bytes>)

kms 'runA1()'; kms 'runA1()' --broadcast          # 1
fordefi 'runA2()' $FORDEFI_BLOCKLIST_UPDATER     # 2: must print "nothing to send"
kms 'runA3()'; kms 'runA3()' --broadcast          # 3; export EVM_FACTORY_ADDRESS + EVM_ISSUANCE_MANAGER (@@)
fordefi 'runB()'  $FORDEFI_CONTRACT_ADMIN        # 4, then --execute; note the block time
# ... wait >= 48 h. runC1 refuses with the seconds left if early.
kms 'runC1()'; kms 'runC1()' --broadcast          # 5
fordefi 'runC2()' $FORDEFI_NAV_FEEDER            # 6, then --execute
kms 'runC3()'; kms 'runC3()' --broadcast          # 7
fordefi 'runC4()' $FORDEFI_WHITELISTER           # 8, then --execute; export EVM_ATOMIC_SWAP_ADDRESS (@@)
forge script $F --sig 'verify()' --rpc-url $RPC  # must end "ALL n CHECKS PASSED"
```

Run each sub-phase only **after** the previous one is confirmed. A KMS broadcast that stopped
midway finishes with `--resume`; a replay by re-running `--execute`
(`tools/fordefi-replay/README.md`). runA2 and runC1–C4 skip what is on chain; runA1, runA3 and
runB refuse a re-run once done. The replay maps no deployer vault, so a deployer tx can never
reach Fordefi; forge `--aws` holds only the deployer key, so a vault tx can never reach KMS.
During the 48 h window the Contract Admin can `cancel` the batch if anything is wrong.

## Post-deploy

1. `verify()` ends `ALL n CHECKS PASSED` (it includes: the KMS deployer holds no role anywhere).
2. Fund swap inventory through the platform: `POST /admin/swap/fund-inventory?chain=56`.
3. Write the `@@` addresses to `docs/deploy/bsc-mainnet-addresses.env` (addresses only, no secrets).
4. BscScan source verification (`forge verify-contract --chain bsc`, `ETHERSCAN_API_KEY`):
   SanctionsOracleMirror; TimelockController; IssuanceManager impl + ERC1967Proxy;
   GyldBondToken impl; TokenFactory; per bond the token proxy, KaleidoscopeNAVFeed and
   NAVFeedForwarder (created by the factory in runC1); GyldAtomicSwap impl + ERC1967Proxy.
   Cross-check against the created addresses in `broadcast/BscFordefiStack.s.sol/56/run{A1,A3,C1,C3}-latest.json`.
5. Sweep the KMS deployer's leftover BNB back to the PROD Fordefi Deployer vault
   (`cast send --aws --legacy 0xb242Bf9fa856B70365FB43EE780d110f6B9DDAb3 --value <balance - fee>`),
   then disable the KMS key (schedule its deletion once the addresses file is merged).
6. Disable / delete the temporary Fordefi API users; revert any temporary vault policy.
