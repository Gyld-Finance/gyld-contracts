#!/usr/bin/env bash
# Rehearse the GLD-978 Option 2 deploy on an Anvil fork of BSC testnet (97) in the real order.
# KMS sub-phases broadcast as STACK_DEPLOYER (the KMS deployer, impersonated here; --aws for
# real) and may contain only its txs. Fordefi sub-phases are forge DRY RUNS whose journal
# tools/fordefi-replay sends tx by tx as its `from` (anvil-impersonated via
# REPLAY_TEST_RPC_SIGNER here; a Fordefi vault for real); the replay refuses the deployer, which
# maps to no vault. Vaults and the Contract Admin's proof come from throwaway keys; nothing
# reaches BSC.
#   SANCTIONS_PROBE_FLAGGED=0x... script-bsc/simulate-fordefi-stack.sh
#
# CHAIN=56: the BSC MAINNET hybrid on an Anvil fork of 56 (FORK_RPC_URL, else BSC_RPC_URL, else
# the public dataseed; needs recent historical state). Same split as 97: the deploy sub-phases
# broadcast from a funded fork deployer standing in for the PROD KMS key (STACK_DEPLOYER, default
# a throwaway placeholder), the role sub-phases are dry runs + replay; a role sub-phase under
# --broadcast and the PROD Fordefi gas vault as STACK_DEPLOYER must both be refused. Delay 48 h
# (time travel). Needs SANCTIONS_FORWARDING_ORACLE, a SANCTIONS_PROBE_FLAGGED it flags,
# CASH_TOKEN. BOND_* / NAV_ANSWER_8DP_<TAG> default to the testnet CAT/C/KO set FOR THE
# REHEARSAL ONLY.
#   CHAIN=56 CASH_TOKEN=0x55d3... SANCTIONS_FORWARDING_ORACLE=0x... SANCTIONS_PROBE_FLAGGED=0x... \
#     script-bsc/simulate-fordefi-stack.sh
set -euo pipefail
cd "$(dirname "$0")/.."
CHAIN="${CHAIN:-97}"
[ "$CHAIN" = 97 ] || [ "$CHAIN" = 56 ] || { echo "CHAIN must be 97 or 56" >&2; exit 1; }
: "${SANCTIONS_PROBE_FLAGGED:?set SANCTIONS_PROBE_FLAGGED (an address on the current SDN list)}"
export DEPLOY_SALT_TAG="${DEPLOY_SALT_TAG:-fordefi-sim}" NAV_ANSWER_8DP="${NAV_ANSWER_8DP:-100000000}" SANCTIONS_PROBE_FLAGGED
PORT="${PORT:-8549}" RPC="http://127.0.0.1:$PORT"
SOL=script-bsc/BscFordefiStack.s.sol:BscFordefiStack
WORK="$(mktemp -d)"
export FOUNDRY_BROADCAST="$WORK/broadcast" # the fork is chain 97 too: keep its journals out of broadcast/
J="$FOUNDRY_BROADCAST/BscFordefiStack.s.sol/$CHAIN/dry-run"
die() { echo "ERROR: $*" >&2; exit 1; }

ROLES="CONTRACT_ADMIN FREEZE SWAP_PAUSE NAV_FEEDER SUBSCRIBER BURN_ROLE WHITELISTER SWAP_TREASURER
  QUOTE_SIGNER BLOCKLIST_UPDATER SWAP_DISTRIBUTION"
key() { cast keccak "fordefi-sim:$1"; } # throwaway placeholder keys: simulation only
for r in $ROLES; do
  a="$(cast wallet address --private-key "$(key "$r")")"
  export "FORDEFI_$r=$a" "FORDEFI_${r}_ADDRESS=$a" # forge reads the first, the replay the second
done
if [ "$CHAIN" = 97 ]; then
  export STACK_DEPLOYER="${STACK_DEPLOYER:-$(sed -n 's/^KMS_DEPLOYER=//p' script-bsc/kms-roles.bsc-testnet.env)}"
  DELAY=300 UNIT=tBNB FORK="${FORK_RPC_URL:-https://bsc-testnet-rpc.publicnode.com}"
else
  : "${CASH_TOKEN:?set CASH_TOKEN}" "${SANCTIONS_FORWARDING_ORACLE:?set SANCTIONS_FORWARDING_ORACLE}"
  export STACK_DEPLOYER="${STACK_DEPLOYER:-$(cast wallet address --private-key "$(key KMS_DEPLOYER)")}" CASH_TOKEN SANCTIONS_FORWARDING_ORACLE
  DELAY="${TIMELOCK_DELAY_SECONDS:-172800}" UNIT=BNB FORK="${FORK_RPC_URL:-${BSC_RPC_URL:-https://bsc-dataseed.bnbchain.org}}"
  # Rehearsal-only bond set (the testnet one) unless BOND_* is already set.
  i=0
  while IFS='|' read -r name sym isin mat coupon tag; do
    for f in "NAME=$name" "SYMBOL=$sym" "CUSIP=$sym" "ISIN=$isin" "MATURITY=$mat" "COUPON=$coupon" "TAG=$tag"; do
      v="BOND_${i}_${f%%=*}"; [ -n "${!v:-}" ] || export "$v=${f#*=}"
    done
    t="BOND_${i}_TAG" n="NAV_ANSWER_8DP_${!t}"; [ -n "${!n:-}" ] || export "$n=$NAV_ANSWER_8DP"
    i=$((i + 1))
  done <<'BONDS'
Caterpillar Inc 3.7% 2028|14913UBF6|US14913UBF66|1851811200|3.7%|CAT
Citigroup Inc 3.887% 2028|172967LD1|US172967LD18|1831075200|3.887%|C
Coca-Cola Co 2.25% 2032|191216DP2|US191216DP21|1977609600|2.25%|KO
BONDS
fi
REPLAY=tools/fordefi-replay/replay.mjs
[ -d tools/fordefi-replay/node_modules ] || npm --prefix tools/fordefi-replay install --no-audit --no-fund >/dev/null
export CHAIN_ID="$CHAIN" RPC_URL="$RPC" REPLAY_TEST_RPC_SIGNER=1 # the replay's test signer: refuses anything but a local anvil

forge build script-bsc/BscFordefiStack.s.sol >/dev/null # before forking: a pruning RPC drops old state
anvil --fork-url "$FORK" --chain-id "$CHAIN" --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null; rm -rf "$WORK"' EXIT
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do kill -0 $ANVIL || die "anvil exited"; sleep 0.2; done
for r in $ROLES; do a="FORDEFI_$r"; cast rpc anvil_setBalance "${!a}" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null; done
cast rpc anvil_setBalance "$STACK_DEPLOYER" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
cast rpc anvil_impersonateAccount "$STACK_DEPLOYER" --rpc-url "$RPC" >/dev/null
JK="$FOUNDRY_BROADCAST/BscFordefiStack.s.sol/$CHAIN"

kms() { # <sig>: the KMS sub-phase, broadcast as the deployer (--aws for real); only its txs
  echo "==> KMS $1 (sender STACK_DEPLOYER)"
  forge script $SOL --sig "$1" --sender "$STACK_DEPLOYER" --rpc-url "$RPC" --unlocked --broadcast --slow --legacy \
    --with-gas-price 0.1gwei >"$WORK/$1.log" 2>&1 || { tail -40 "$WORK/$1.log"; die "$1 failed"; }
  while read -r kv; do export "${kv?}"; done < <(sed -n 's/^ *@@ //p' "$WORK/$1.log")
  local f="$JK/${1%%(*}-latest.json" d
  d="$(echo "$STACK_DEPLOYER" | tr A-F a-f)"
  jq -e --arg d "$d" '.receipts | length > 0 and all(.from | ascii_downcase == $d)' "$f" >/dev/null ||
    die "$1: a KMS sub-phase sent from someone other than the deployer"
  jq -r '.receipts[] | "\(.from | ascii_downcase) \(.gasUsed)"' "$f" | while read -r from gas; do echo "$from $((gas))" >>"$WORK/gas"; done
  echo "    $(jq '.receipts | length' "$f") tx, all from the deployer"
}

dry() { # <sig> <sender>: Fordefi sub-phase dry run (no --broadcast); exports the @@ KEY=VALUE lines it prints
  echo "==> dry run $1 (sender $2)"
  rm -f "$J"/"${1%%(*}"-latest.json
  forge script $SOL --sig "$1" --sender "$2" --rpc-url "$RPC" >"$WORK/$1.log" 2>&1 || { tail -40 "$WORK/$1.log"; die "$1 failed"; }
  while read -r kv; do export "${kv?}"; done < <(sed -n 's/^ *@@ //p' "$WORK/$1.log")
}
replay() { # <sig>: the real replay path: plan (table + hash), --execute, then a resume that sends nothing
  local f="$J/${1%%(*}-latest.json" log="$WORK/$1.replay" hash h
  if [ ! -f "$f" ] && [ "$CHAIN" = 56 ] && [ "$1" = 'runA2()' ]; then
    echo "    0 tx: the forwarding oracle already flags the probe"; return
  fi
  [ -f "$f" ] || die "$1 wrote no dry-run journal"
  node "$REPLAY" "$f" >"$log" 2>&1 || { tail -20 "$log"; die "$1: replay plan failed"; }
  hash="$(sed -n 's/^PLAN_SHA256=//p' "$log")"
  PLAN_SHA256="$hash" node "$REPLAY" "$f" --execute >>"$log" 2>&1 || { tail -20 "$log"; die "$1: replay failed"; }
  PLAN_SHA256="$hash" node "$REPLAY" "$f" --execute >"$log.resume" 2>&1 || { tail -20 "$log.resume"; die "$1: resume failed"; }
  ! grep -q ' sent 0x' "$log.resume" || die "$1: resume re-sent a confirmed tx"
  for h in $(jq -r '.txs[].hash' "$f.progress.json"); do
    cast receipt "$h" --rpc-url "$RPC" --json | jq -r '"\(.from | ascii_downcase) \(.gasUsed)"' |
      while read -r from gas; do echo "$from $((gas))" >>"$WORK/gas"; done
  done
  echo "    replay.mjs: $(grep -c ' confirmed in block' "$log") tx confirmed, plan $hash; resume sent nothing"
}

# The Contract Admin vault's personal_sign of the 32 bytes runA1() and runA3() recover.
msg="$(forge script $SOL --sig 'governanceProofMessage()' --rpc-url "$RPC" | grep -oE '0x[0-9a-f]{64}' | head -1)"
export FORDEFI_GOVERNANCE_SIG="$(cast wallet sign --private-key "$(key CONTRACT_ADMIN)" "$msg")"
cast wallet verify --address "$FORDEFI_CONTRACT_ADMIN" "$msg" "$FORDEFI_GOVERNANCE_SIG" >/dev/null || die "proof does not recover"
echo "==> governance proof message $msg signed by the Contract Admin placeholder"
FORDEFI_CONTRACT_ADMIN=0x00000000000000000000000000000000DeaDBeef forge script $SOL --sig 'runA1()' \
  --sender "$STACK_DEPLOYER" --rpc-url "$RPC" >"$WORK/badgov.log" 2>&1 && die "runA1 accepted a Contract Admin the proof does not cover"
grep -q GovernanceProofInvalid "$WORK/badgov.log" || { tail -20 "$WORK/badgov.log"; die "runA1: wrong failure"; }
echo "==> runA1 refuses a Contract Admin the proof does not cover"

if [ "$CHAIN" = 56 ]; then
  STACK_DEPLOYER=0xb242Bf9fa856B70365FB43EE780d110f6B9DDAb3 forge script $SOL --sig 'governanceProofMessage()' \
    --rpc-url "$RPC" >"$WORK/gasvault.log" 2>&1 && die "56 accepted the PROD Fordefi gas vault as STACK_DEPLOYER"
  grep -q "PROD Fordefi Deployer (gas) vault" "$WORK/gasvault.log" || { tail -20 "$WORK/gasvault.log"; die "gas vault: wrong failure"; }
  echo "==> 56 refuses the PROD Fordefi Deployer (gas) vault as STACK_DEPLOYER"
  for s in 'runA2()' 'runC2()' 'runC4()'; do # role sub-phases: never --broadcast on 56, even as the deployer
    forge script $SOL --sig "$s" --sender "$STACK_DEPLOYER" --rpc-url "$RPC" --unlocked --broadcast --legacy \
      >"$WORK/bcast.log" 2>&1 && die "$s broadcast on 56 (role sub-phases must go through the replay)"
    grep -q "role sub-phase - dry-run only" "$WORK/bcast.log" || { tail -20 "$WORK/bcast.log"; die "$s --broadcast: wrong failure"; }
  done
  forge script $SOL --sig 'runB()' --sender "$FORDEFI_CONTRACT_ADMIN" --rpc-url "$RPC" --unlocked --broadcast --legacy \
    >"$WORK/bcast.log" 2>&1 && die "runB broadcast on 56"
  grep -q "only STACK_DEPLOYER (the KMS key) may --broadcast" "$WORK/bcast.log" || { tail -20 "$WORK/bcast.log"; die "runB --broadcast: wrong failure"; }
  echo "==> 56 refuses --broadcast for every role sub-phase (A2, B, C2, C4): those go through the replay"
fi
kms 'runA1()'
if [ "$CHAIN" = 56 ]; then # the 7-day sanity cap on the timelock delay (checked when runA3 builds DeployDevNet's env)
  TIMELOCK_DELAY_SECONDS=604801 forge script $SOL --sig 'runA3()' --sender "$STACK_DEPLOYER" --rpc-url "$RPC" \
    >"$WORK/cap.log" 2>&1 && die "runA3 accepted TIMELOCK_DELAY_SECONDS above 7 days"
  grep -q "TIMELOCK_DELAY_SECONDS above 7 days" "$WORK/cap.log" || { tail -20 "$WORK/cap.log"; die "delay cap: wrong failure"; }
  echo "==> 56 refuses TIMELOCK_DELAY_SECONDS above 7 days"
fi
dry 'runA2()' "$FORDEFI_BLOCKLIST_UPDATER" && replay 'runA2()'
kms 'runA3()'
dry 'runB()' "$FORDEFI_CONTRACT_ADMIN" && replay 'runB()'
forge script $SOL --sig 'runC1()' --sender "$STACK_DEPLOYER" --rpc-url "$RPC" >"$WORK/early.log" 2>&1 &&
  die "runC1 simulated before the $DELAY s delay elapsed"
grep -q "Phase 2 executable in" "$WORK/early.log" || { tail -20 "$WORK/early.log"; die "runC1: wrong early failure"; }
echo "==> runC1 refuses before the $DELAY s delay; waiting $DELAY s (anvil time travel)"
cast rpc evm_increaseTime "$DELAY" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
kms 'runC1()'
dry 'runC2()' "$FORDEFI_NAV_FEEDER" && replay 'runC2()'
kms 'runC3()'
dry 'runC4()' "$FORDEFI_WHITELISTER" && replay 'runC4()'
for s in 'runC1()' 'runC2()' 'runC3()' 'runC4()'; do # re-run: every step is done, so none may plan a tx
  rm -f "$J/${s%%(*}-latest.json"
  forge script $SOL --sig "$s" --sender "$STACK_DEPLOYER" --rpc-url "$RPC" >"$WORK/rerun.log" 2>&1 || { tail -20 "$WORK/rerun.log"; die "$s re-run failed"; }
  [ ! -f "$J/${s%%(*}-latest.json" ] || [ "$(jq '.transactions | length' "$J/${s%%(*}-latest.json")" = 0 ] || die "$s re-run planned transactions"
done
echo "==> runC1..C4 re-run: 0 tx"
forge script $SOL --sig 'verify()' --rpc-url "$RPC" >"$WORK/verify.log" 2>&1 || { tail -40 "$WORK/verify.log"; die "verify failed"; }
grep -E '\[ok\]|CHECKS PASSED' "$WORK/verify.log"

echo "=== tx and gas per signer ($UNIT at 0.1 gwei) ==="
names="$(echo "$(echo "$STACK_DEPLOYER" | tr A-F a-f) KMS_DEPLOYER"; for r in $ROLES; do a="FORDEFI_$r"; echo "$(echo "${!a}" | tr A-F a-f) $r"; done)"
awk -v u="$UNIT" 'NR == FNR { role[$1] = $2; next } { n[$1]++; g[$1] += $2; t += $2; c++ }
     END { for (a in n) printf "%-18s %s %3d tx %9d gas %.6f %s\n", role[a], a, n[a], g[a], g[a] / 1e10, u;
           printf "TOTAL %d tx %d gas %.6f %s\n", c, t, t / 1e10, u }' <(echo "$names") "$WORK/gas"
echo "SIMULATION GREEN"
