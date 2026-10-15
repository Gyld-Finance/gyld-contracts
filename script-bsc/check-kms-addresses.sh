#!/usr/bin/env bash
# GLD-807 step 0 (no transaction; AWS creds, eu-west-2): every KMS_*_KEY_ID in
# kms-roles.bsc-testnet.env must derive exactly its KMS_* address. Fails on the first mismatch.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . script-bsc/kms-roles.bsc-testnet.env; set +a
export AWS_REGION="${AWS_REGION:-eu-west-2}"
die() { echo "ERROR: $*" >&2; exit 1; }
for id in $(grep -o '^KMS_[A-Z_]*_KEY_ID' script-bsc/kms-roles.bsc-testnet.env); do
  want="${id%_KEY_ID}"
  got="$(AWS_KMS_KEY_ID="${!id}" cast wallet address --aws)" || die "$id: cannot read key"
  [ "$(echo "$got" | tr A-F a-f)" = "$(echo "${!want}" | tr A-F a-f)" ] || die "$want: key is $got, env says ${!want}"
  echo "ok  $want ${!want}"
done
