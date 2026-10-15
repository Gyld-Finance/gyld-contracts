#!/usr/bin/env bash
# Rehearse the GLD-807 rotation on an Anvil fork of BSC testnet (97): signers are impersonated,
# nothing is sent to BSC. The KMS check is real (AWS creds, eu-west-2).
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . docs/deploy/bsc-testnet-addresses.env; . script-bsc/kms-roles.bsc-testnet.env; set +a
PORT="${PORT:-8547}" RPC="http://127.0.0.1:$PORT"
SOL=script-bsc/BscKmsRoleRotation.s.sol:BscKmsRoleRotation
WORK="$(mktemp -d)"
export FOUNDRY_BROADCAST="$WORK" # the fork is chain 97 too: keep its journal out of broadcast/
SENDERS="$GOVERNANCE_MULTISIG $NAV_FEED_OWNER $KMS_NAV_FEED_OWNER"
die() { echo "ERROR: $*" >&2; exit 1; }

forge build script-bsc/BscKmsRoleRotation.s.sol >/dev/null # before forking: a pruning RPC drops old state
anvil --fork-url "${FORK_RPC_URL:-https://bsc-testnet-rpc.publicnode.com}" --chain-id 97 --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null; rm -rf "$WORK"' EXIT
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do kill -0 $ANVIL || die "anvil exited"; sleep 0.2; done
for a in $SENDERS; do
  cast rpc anvil_setBalance "$a" 0xde0b6b3a7640000 --rpc-url "$RPC" >/dev/null
  cast rpc anvil_impersonateAccount "$a" --rpc-url "$RPC" >/dev/null
done
out="$(script-bsc/check-kms-addresses.sh)" || die "KMS check failed"
eval "$out"
QUOTE_EPOCH_BEFORE="$(cast call "$EVM_ATOMIC_SWAP_ADDRESS" 'quoteEpoch()(uint64)' --rpc-url "$RPC")"
export QUOTE_EPOCH_BEFORE

run() {
  echo "==> $1"
  forge script $SOL --sig "$1" --sender "$2" --rpc-url "$RPC" --unlocked --broadcast --legacy \
    --with-gas-price 0.1gwei >"$WORK/log" 2>&1 || { tail -30 "$WORK/log"; die "$1 failed"; }
}
abc() {
  run 'rotateRoles()' "$GOVERNANCE_MULTISIG"
  run 'transferNavOwnership()' "$NAV_FEED_OWNER"
  run 'acceptNavOwnership()' "$KMS_NAV_FEED_OWNER"
}

nonces() { for a in $SENDERS; do cast nonce "$a" --rpc-url "$RPC"; done | paste -sd+ - | bc; }
b0="$(cast block-number --rpc-url "$RPC")" n0="$(nonces)"
abc
b1="$(cast block-number --rpc-url "$RPC")" n1="$(nonces)"
abc # idempotent: must send nothing
[ "$(nonces)" = "$n1" ] || die "re-run sent transactions"
run 'verify()' "$GOVERNANCE_MULTISIG"

gas=0
for ((b = b0 + 1; b <= b1; b++)); do gas=$((gas + $(cast block "$b" -f gasUsed --rpc-url "$RPC"))); done
echo "SIMULATION GREEN: $((n1 - n0)) tx, $gas gas"
