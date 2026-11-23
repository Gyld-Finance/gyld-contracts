# UAT on Ethereum Sepolia (11155111): KMS deployer + Fordefi role vaults

UAT moves off Hoodi (560048) onto a fresh Sepolia stack built with the GLD-978 hybrid
([`bsc-testnet.md`](bsc-testnet.md#fordefi-vaults-gld-978)): the **KMS deployer** sends
every deploy and holds no role afterwards, and each privileged role is its own **Fordefi
vault** whose transactions go through `tools/fordefi-replay`. Script:
`script-bsc/SepoliaFordefiStack.s.sol` (BscFordefiStack with Sepolia config). Nothing
under `contracts/` changes.

DEV already has its own Sepolia stack (`kaleidoscope/scripts/deploy/sepolia-verified-addresses.env`).
UAT is a second, separate stack on the same chain, with its own `DEPLOY_SALT_TAG`. UAT has its
own database (RDS), so the same bond ISIN on DEV and UAT does not clash.

## What differs from BSC testnet

| | BSC testnet (97) | Sepolia UAT |
|---|---|---|
| Cash leg | real USDT, 18 dp | a fresh **MockUSDC**, 6 dp, `mint()` open to anyone (run A0) |
| Timelock | 300 s | `TIMELOCK_DELAY_SECONDS`, default and floor 300 s, cap 7 d |
| Series | CAT / C / KO | **one** starter series from `BOND_0_*`. Add more through the admin panel |
| Sanctions | mirror, no upstream oracle, synthetic probe | the same (Chainalysis has no Sepolia oracle) |
| Guards | production path | Sepolia is a **dev chain** in `DeployGuards`, so the script adds a 300 s floor, removes Anvil account[1] (a public key) from the whitelist in run C4, and `verify()` checks every role holder |
| Fordefi chain | custom chain `evm_97` | built in: `evm_11155111` |
| Explorer | testnet.bscscan.com | sepolia.etherscan.io (Etherscan V2, free key) |

## Prep (once)

1. **Fordefi:** enable Ethereum Sepolia for the vaults that sign during the deploy: Contract Admin,
   Blocklist Updater, NAV Feeder and Whitelister. A vault's EVM address is the same on every
   chain, so `script-bsc/fordefi-roles.sepolia-uat.env` reuses the BSC testnet addresses.
2. **Fordefi policies for Sepolia:** Contract Admin 3-of-4, NAV Feeder auto-approve, Blocklist
   Updater and Whitelister per their vault policy. The BSC policies may be tied to the custom
   `evm_97` chain.
3. **Gas (Sepolia ETH):** KMS deployer `0x70B2…4Fb2` needs about 0.2 ETH (27 tx, 18.8 M gas in
   the rehearsal: 0.19 ETH at 10 gwei; Sepolia gas prices vary). Each of the four signing vaults
   needs about 0.01 ETH.
4. **API Signer** online. API tokens and signing keys in `tools/fordefi-replay/roles.env`
   (copied from `roles.sepolia-uat.example.env`, git-ignored).
5. **AWS:** a session that can sign with the KMS deployer key (`KMS_DEPLOYER_KEY_ID` in
   `script-bsc/kms-roles.bsc-testnet.env`, eu-west-2).

## Rehearsal (must end `SIMULATION GREEN`)

```bash
CHAIN=11155111 SANCTIONS_PROBE_FLAGGED=0x0000000000000000000000000000000000000BAD \
  script-bsc/simulate-fordefi-stack.sh
```

## Deploy

| # | Sub-phase | Signer | Txs | Fordefi approvals |
|---|---|---|---|---|
| 0 | `governanceProofMessage()` | Contract Admin `personal_sign` | 0 | 1 (3-of-4) |
| 1 | `runA0()` MockUSDC | KMS deployer | 1 | – |
| 2 | `runA1()` mirror | KMS deployer | 1 | – |
| 3 | `runA2()` seed probe | Blocklist Updater | 1 | 1 |
| 4 | `runA3()` DeployDevNet | KMS deployer | 15 | – |
| 5 | `runB()` `scheduleBatch` | Contract Admin | 1 | 1 (3-of-4) |
| – | wait ≥ 300 s after 5 is mined | | | |
| 6 | `runC1()` `executeBatch` | KMS deployer | 1 | – |
| 7 | `runC2()` first NAV | NAV Feeder | 1 | auto-approve |
| 8 | `runC3()` DeployAtomicSettlement | KMS deployer | 9 | – |
| 9 | `runC4()` whitelist swap, drop Anvil account[1] | Whitelister | 2 | 1 (one per tx) |

```bash
# Run this block in bash, not zsh.
set -a; . script-bsc/fordefi-roles.sepolia-uat.env; . tools/fordefi-replay/roles.env; set +a
export KMS_DEPLOYER_KEY_ID=$(sed -n 's/^KMS_DEPLOYER_KEY_ID=//p' script-bsc/kms-roles.bsc-testnet.env)
export AWS_REGION=eu-west-2 AWS_KMS_KEY_IDS=$KMS_DEPLOYER_KEY_ID RPC=$SEPOLIA_RPC_URL
export NAV_ANSWER_8DP_CAT=<the bond's NAV, 8 dp>
F="script-bsc/SepoliaFordefiStack.s.sol:SepoliaFordefiStack" D=broadcast/SepoliaFordefiStack.s.sol/11155111/dry-run
KMS=(--sender "$STACK_DEPLOYER" --rpc-url "$RPC" --aws --slow)
R="node tools/fordefi-replay/replay.mjs"
kms() { forge script "$F" --sig "$1" "${KMS[@]}" "${@:2}"; }  # dry run; read it, then again with --broadcast
fordefi() {  # a stale journal must never be shown as the plan to approve
  local j="$D/${1%%(*}-latest.json"; rm -f "$j"
  forge script "$F" --sig "$1" --sender "$2" --rpc-url "$RPC" || return
  if [ -f "$j" ]; then $R "$j"; else echo "nothing to send"; fi
}
# A second person approves each PLAN_SHA256, then: PLAN_SHA256=<hash> $R $D/<sig>-latest.json --execute

forge script $F --sig 'governanceProofMessage()' --rpc-url $RPC          # 0: binds chain 11155111
export FORDEFI_GOVERNANCE_SIG=$(node tools/fordefi-replay/sign-message.mjs 0x<the 32 bytes>)

kms 'runA0()'; kms 'runA0()' --broadcast                    # 1; export CASH_TOKEN (@@)
kms 'runA1()'; kms 'runA1()' --broadcast                    # 2
fordefi 'runA2()' $FORDEFI_BLOCKLIST_UPDATER                # 3, then --execute
kms 'runA3()'; kms 'runA3()' --broadcast                    # 4; export EVM_FACTORY_ADDRESS + EVM_ISSUANCE_MANAGER (@@)
fordefi 'runB()' $FORDEFI_CONTRACT_ADMIN                    # 5, then --execute; wait >= 300 s
kms 'runC1()'; kms 'runC1()' --broadcast                    # 6
fordefi 'runC2()' $FORDEFI_NAV_FEEDER                       # 7, then --execute
kms 'runC3()'; kms 'runC3()' --broadcast                    # 8
fordefi 'runC4()' $FORDEFI_WHITELISTER                      # 9, then --execute; export EVM_ATOMIC_SWAP_ADDRESS (@@)
forge script $F --sig 'verify()' --rpc-url $RPC             # must print ALL 20 CHECKS PASSED
```

Re-runs, `--resume` and refusals behave exactly as on BSC testnet. No step mints swap inventory
(GLD-1054): fund it through the platform's `POST /admin/swap/fund-inventory?chain=<chain>`.

## After the deploy

1. Verify sources on Etherscan: `forge verify-contract <addr> <path:Contract> --chain sepolia --watch`.
2. Record the addresses in `docs/deploy/sepolia-uat-addresses.env` and in `DEPLOYMENTS.md`.
3. **Backend (kaleidoscope), a separate change:** move UAT from Hoodi to Sepolia. That covers the
   `kaleidoscope/uat/*` secrets (evm-chain-id, RPC, contract addresses), the CI build mapping
   `main => 560048`, `ops/faucet/uat.env` (chain, RPC, explorer, the new MockUSDC), the
   explorer links and the sanctions endpoint.
