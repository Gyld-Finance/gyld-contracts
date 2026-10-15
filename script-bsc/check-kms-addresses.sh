#!/usr/bin/env bash
# GLD-807 step 0 (no transaction; AWS creds, eu-west-2): each KMS_*_KEY_ID must derive its
# KMS_* address, and the KMS governance key signs (EIP-191) the rotation it will receive:
# keccak256(abi.encode(TAG, 97, timelock, keccak256(abi.encode(address[12] targets)))).
#   out=$(script-bsc/check-kms-addresses.sh) || exit 1; eval "$out"   # exports KMS_GOVERNANCE_SIG
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . docs/deploy/bsc-testnet-addresses.env; . script-bsc/kms-roles.bsc-testnet.env; set +a
die() { echo "ERROR: $*" >&2; exit 1; }

targets=""
# Same order as BscKmsRoleRotation.setUp().
for r in GOVERNANCE OPS NAV_FEED_OWNER SUBSCRIBER REDEEMER WHITELIST_ADMIN ISSUANCE_PAUSER \
  QUOTE_SIGNER TREASURER ALLOWLIST_ADMIN WITHDRAWAL_WALLET SANCTIONS_OWNER; do
  want="KMS_$r" id="KMS_${r}_KEY_ID"
  got="$(AWS_KMS_KEY_ID="${!id}" cast wallet address --aws)" || die "$id: cannot read key"
  [ "$(echo "$got" | tr A-F a-f)" = "$(echo "${!want}" | tr A-F a-f)" ] || die "$want: key is $got, env says ${!want}"
  echo "ok  $want ${!want}" >&2
  targets="$targets,${!want}"
done

hash="$(cast keccak "$(cast abi-encode 'f(bytes32,uint256,address,bytes32)' "$(cast keccak GLD-807.kms-governance-proof)" \
  97 "$TIMELOCK_ADDRESS" "$(cast keccak "$(cast abi-encode 'f(address[12])' "[${targets#,}]")")")")"
sig="$(AWS_KMS_KEY_ID="$KMS_GOVERNANCE_KEY_ID" cast wallet sign --aws "$hash")" || die "governance key cannot sign"
cast wallet verify --address "$KMS_GOVERNANCE" "$hash" "$sig" >/dev/null || die "signature does not recover to KMS_GOVERNANCE"
echo "export KMS_GOVERNANCE_SIG=$sig"
