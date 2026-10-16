#!/usr/bin/env bash
# Rehearse the GLD-807 fresh KMS deploy on an Anvil fork of <chain> (script-evm/chains/<chain>.env):
# signers are impersonated, nothing reaches the chain. Step 0 (KMS address check) is real: AWS
# creds, eu-west-2.
#   NAV_ANSWER_8DP=100000000 SANCTIONS_PROBE_FLAGGED=0x... script-evm/simulate-kms-stack.sh <chain>
set -euo pipefail
cd "$(dirname "$0")/.."
CHAIN_ENV="script-evm/chains/${1:?usage: simulate-kms-stack.sh <chain> (a script-evm/chains/<chain>.env)}.env"
[ -f "$CHAIN_ENV" ] || { echo "ERROR: no $CHAIN_ENV" >&2; exit 1; }
: "${NAV_ANSWER_8DP:?set NAV_ANSWER_8DP (8dp, inside the feed range 1e7..2e8)}"
: "${SANCTIONS_PROBE_FLAGGED:?set SANCTIONS_PROBE_FLAGGED (an address on the current SDN list)}"
set -a; . "$CHAIN_ENV"; . script-evm/kms-roles.env; set +a
export DEPLOY_SALT_TAG="${DEPLOY_SALT_TAG:-kms1}" NAV_ANSWER_8DP SANCTIONS_PROBE_FLAGGED
PORT="${PORT:-8548}" RPC="http://127.0.0.1:$PORT"
SOL=script-evm/KmsStack.s.sol:KmsStack
WORK="$(mktemp -d)"
export FOUNDRY_BROADCAST="$WORK/broadcast" # the fork keeps CHAIN_ID: keep its journal out of broadcast/
J="$FOUNDRY_BROADCAST/KmsStack.s.sol/$CHAIN_ID"
die() { echo "ERROR: $*" >&2; exit 1; }

out="$(script-evm/check-kms-addresses.sh 2>/dev/null)" || die "step 0: KMS check failed"
eval "$out"
echo "==> step 0 ok: 14 KMS keys derive their addresses; governance proof signed by KMS"
forge build script-evm/KmsStack.s.sol >/dev/null # before forking: a pruning RPC drops old state
anvil --fork-url "${FORK_RPC_URL:-$RPC_URL}" --chain-id "$CHAIN_ID" --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null; rm -rf "$WORK"' EXIT
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do kill -0 $ANVIL || die "anvil exited"; sleep 0.2; done
for a in $KMS_DEPLOYER $KMS_SANCTIONS_OWNER $KMS_GOVERNANCE $KMS_NAV_FEED_OWNER $KMS_WHITELIST_ADMIN $KMS_SUBSCRIBER; do
  cast rpc anvil_setBalance "$a" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
  cast rpc anvil_impersonateAccount "$a" --rpc-url "$RPC" >/dev/null
done

run() { # <sig> <sender>: broadcast to the fork, then export the @@ KEY=VALUE lines it prints
  echo "==> $1 (sender $2)"
  forge script $SOL --sig "$1" --sender "$2" --rpc-url "$RPC" --unlocked --broadcast --slow $GAS_OPTS \
    >"$WORK/$1.log" 2>&1 || { tail -40 "$WORK/$1.log"; die "$1 failed"; }
  while read -r kv; do export "${kv?}"; done < <(sed -n 's/^ *@@ //p' "$WORK/$1.log")
}
KMS_GOVERNANCE=0x00000000000000000000000000000000DeaDBeef forge script $SOL --sig 'runA()' --sender "$KMS_DEPLOYER" --rpc-url "$RPC" \
  >"$WORK/badgov.log" 2>&1 && die "runA accepted a KMS_GOVERNANCE the proof does not cover"
grep -q GovernanceProofInvalid "$WORK/badgov.log" || { tail -20 "$WORK/badgov.log"; die "runA: wrong failure"; }
echo "==> runA refuses a governance address the KMS proof does not cover"
run 'runA()' "$KMS_DEPLOYER"
run 'runB()' "$KMS_GOVERNANCE"
if forge script $SOL --sig 'runC()' --sender "$KMS_DEPLOYER" --rpc-url "$RPC" >"$WORK/early.log" 2>&1; then
  die "runC simulated before the $TIMELOCK_DELAY_SECONDS s delay elapsed"
fi
grep -q "Phase 2 executable in" "$WORK/early.log" || { tail -20 "$WORK/early.log"; die "runC: wrong early failure"; }
cast rpc evm_increaseTime "$TIMELOCK_DELAY_SECONDS" --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null

# A run C that stopped right after the swap proxy: replay its dry-run journal up to the proxy
# CREATE2, then run C must refuse (naming the missing step) and whitelist/mint nothing.
forge script $SOL --sig 'runC()' --sender "$KMS_DEPLOYER" --rpc-url "$RPC" >"$WORK/dry.log" 2>&1 ||
  { tail -20 "$WORK/dry.log"; die "runC dry run failed"; }
SNAP="$(cast rpc evm_snapshot --rpc-url "$RPC" | tr -d '"')"
jq -c '.transactions | (map(.contractName) | index("ERC1967Proxy")) as $k | .[:$k + 1][] | .transaction
       | {from, to, data: .input, gas, value}' "$J"/dry-run/runC*-latest.json |
  while read -r tx; do cast rpc eth_sendTransaction "$tx" --rpc-url "$RPC" >/dev/null; done
forge script $SOL --sig 'runC()' --sender "$KMS_DEPLOYER" --rpc-url "$RPC" --unlocked --broadcast --slow $GAS_OPTS \
  >"$WORK/half.log" 2>&1 && die "runC accepted a half-deployed swap"
grep -o "swap deploy stopped midway - missing [^.]*" "$WORK/half.log" | head -1 | sed 's/^/==> runC refuses: /' |
  grep . || { tail -20 "$WORK/half.log"; die "runC: wrong failure on a half-deployed swap"; }
[ "$(cast nonce "$KMS_WHITELIST_ADMIN" --rpc-url "$RPC")$(cast nonce "$KMS_SUBSCRIBER" --rpc-url "$RPC")" = 00 ] ||
  die "runC whitelisted or minted into a half-deployed swap"
cast rpc evm_revert "$SNAP" --rpc-url "$RPC" >/dev/null

run 'runC()' "$KMS_DEPLOYER"
SIGNERS="$KMS_DEPLOYER $KMS_GOVERNANCE $KMS_NAV_FEED_OWNER $KMS_WHITELIST_ADMIN $KMS_SUBSCRIBER"
nonces() { for a in $SIGNERS; do cast nonce "$a" --rpc-url "$RPC"; done | paste -sd+ - | bc; }
n0="$(nonces)"
mkdir "$WORK/keep" && mv "$J"/runC*-latest.json "$WORK/keep/" # the gas tally reads the first run C
run 'runC()' "$KMS_DEPLOYER" # re-run: every step is done, so it must send nothing
[ "$(nonces)" = "$n0" ] || die "runC re-run sent transactions"
rm -f "$J"/runC*-latest.json && mv "$WORK/keep"/* "$J/"
echo "==> runC re-run: 0 tx"
forge script $SOL --sig 'verify()' --rpc-url "$RPC" >"$WORK/verify.log" 2>&1 || { tail -40 "$WORK/verify.log"; die "verify failed"; }
grep -E '\[ok\]|CHECKS PASSED' "$WORK/verify.log"

echo "=== tx, gas and fee per signer ($NATIVE_SYMBOL at the fork's gas price; excludes any L1 data fee) ==="
jq -r '.receipts[] | "\(.from) \(.gasUsed) \(.effectiveGasPrice)"' "$J"/*-latest.json |
  while read -r from gas price; do echo "$(echo "$from" | tr A-F a-f) $((gas)) $((price))"; done |
  awk -v sym="$NATIVE_SYMBOL" '{ n[$1]++; g[$1] += $2; f[$1] += $2 * $3 / 1e18; t += $2; tf += $2 * $3 / 1e18; c++ }
       END { for (a in n) printf "%s %3d tx %9d gas %.6f %s\n", a, n[a], g[a], f[a], sym;
             printf "TOTAL %d tx %d gas %.6f %s\n", c, t, tf, sym }'
echo "SIMULATION GREEN"
