#!/usr/bin/env bash
# Rehearse the GLD-807 fresh KMS deploy on an Anvil fork of BSC testnet (97): signers are
# impersonated, nothing reaches BSC. Step 0 (KMS address check) is real: AWS creds, eu-west-2.
#   NAV_ANSWER_8DP=100000000 SANCTIONS_PROBE_FLAGGED=0x... script-bsc/simulate-kms-stack.sh
set -euo pipefail
cd "$(dirname "$0")/.."
: "${NAV_ANSWER_8DP:?set NAV_ANSWER_8DP (8dp, inside the feed range 1e7..2e8)}"
: "${SANCTIONS_PROBE_FLAGGED:?set SANCTIONS_PROBE_FLAGGED (an address on the current SDN list)}"
set -a; . script-bsc/kms-roles.bsc-testnet.env; set +a
export DEPLOY_SALT_TAG="${DEPLOY_SALT_TAG:-kms1}" NAV_ANSWER_8DP SANCTIONS_PROBE_FLAGGED
PORT="${PORT:-8548}" RPC="http://127.0.0.1:$PORT"
SOL=script-bsc/BscKmsStack.s.sol:BscKmsStack
WORK="$(mktemp -d)"
export FOUNDRY_BROADCAST="$WORK/broadcast" # the fork is chain 97 too: keep its journal out of broadcast/
die() { echo "ERROR: $*" >&2; exit 1; }

out="$(script-bsc/check-kms-addresses.sh 2>/dev/null)" || die "step 0: KMS check failed"
eval "$out"
echo "==> step 0 ok: 14 KMS keys derive their addresses; governance proof signed by KMS"
forge build script-bsc/BscKmsStack.s.sol >/dev/null # before forking: a pruning RPC drops old state
anvil --fork-url "${FORK_RPC_URL:-https://bsc-testnet-rpc.publicnode.com}" --chain-id 97 --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null; rm -rf "$WORK"' EXIT
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do kill -0 $ANVIL || die "anvil exited"; sleep 0.2; done
for a in $KMS_DEPLOYER $KMS_SANCTIONS_OWNER $KMS_GOVERNANCE $KMS_NAV_FEED_OWNER $KMS_WHITELIST_ADMIN $KMS_SUBSCRIBER; do
  cast rpc anvil_setBalance "$a" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
  cast rpc anvil_impersonateAccount "$a" --rpc-url "$RPC" >/dev/null
done

run() { # <sig> <sender>: broadcast to the fork, then export the @@ KEY=VALUE lines it prints
  echo "==> $1 (sender $2)"
  forge script $SOL --sig "$1" --sender "$2" --rpc-url "$RPC" --unlocked --broadcast --slow --legacy \
    --with-gas-price 0.1gwei >"$WORK/$1.log" 2>&1 || { tail -40 "$WORK/$1.log"; die "$1 failed"; }
  while read -r kv; do export "${kv?}"; done < <(sed -n 's/^ *@@ //p' "$WORK/$1.log")
}
KMS_GOVERNANCE=0x00000000000000000000000000000000DeaDBeef forge script $SOL --sig 'runA()' --sender "$KMS_DEPLOYER" --rpc-url "$RPC" \
  >"$WORK/badgov.log" 2>&1 && die "runA accepted a KMS_GOVERNANCE the proof does not cover"
grep -q GovernanceProofInvalid "$WORK/badgov.log" || { tail -20 "$WORK/badgov.log"; die "runA: wrong failure"; }
echo "==> runA refuses a governance address the KMS proof does not cover"
run 'runA()' "$KMS_DEPLOYER"
run 'runB()' "$KMS_GOVERNANCE"
if forge script $SOL --sig 'runC()' --sender "$KMS_DEPLOYER" --rpc-url "$RPC" >"$WORK/early.log" 2>&1; then
  die "runC simulated before the 300 s delay elapsed"
fi
grep -q "Phase 2 executable in" "$WORK/early.log" || { tail -20 "$WORK/early.log"; die "runC: wrong early failure"; }
cast rpc evm_increaseTime 300 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
run 'runC()' "$KMS_DEPLOYER"
SIGNERS="$KMS_DEPLOYER $KMS_GOVERNANCE $KMS_NAV_FEED_OWNER $KMS_WHITELIST_ADMIN $KMS_SUBSCRIBER"
nonces() { for a in $SIGNERS; do cast nonce "$a" --rpc-url "$RPC"; done | paste -sd+ - | bc; }
n0="$(nonces)"
J="$FOUNDRY_BROADCAST/BscKmsStack.s.sol/97"
mkdir "$WORK/keep" && mv "$J"/runC*-latest.json "$WORK/keep/" # the gas tally reads the first run C
run 'runC()' "$KMS_DEPLOYER" # re-run: every step is done, so it must send nothing
[ "$(nonces)" = "$n0" ] || die "runC re-run sent transactions"
rm -f "$J"/runC*-latest.json && mv "$WORK/keep"/* "$J/"
echo "==> runC re-run: 0 tx"
forge script $SOL --sig 'verify()' --rpc-url "$RPC" >"$WORK/verify.log" 2>&1 || { tail -40 "$WORK/verify.log"; die "verify failed"; }
grep -E '\[ok\]|CHECKS PASSED' "$WORK/verify.log"

echo "=== tx and gas per signer (tBNB at 0.1 gwei) ==="
jq -r '.receipts[] | "\(.from) \(.gasUsed)"' "$FOUNDRY_BROADCAST"/BscKmsStack.s.sol/97/*-latest.json |
  while read -r from gas; do echo "$(echo "$from" | tr A-F a-f) $((gas))"; done |
  awk '{ n[$1]++; g[$1] += $2; t += $2; c++ }
       END { for (a in n) printf "%s %3d tx %9d gas %.6f tBNB\n", a, n[a], g[a], g[a] / 1e10;
             printf "TOTAL %d tx %d gas %.6f tBNB\n", c, t, t / 1e10 }'
echo "SIMULATION GREEN"
