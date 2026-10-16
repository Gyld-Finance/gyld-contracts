#!/usr/bin/env bash
# GLD-807 step 0 (no transaction; AWS creds, eu-west-2): every KMS_*_KEY_ID must derive its
# KMS_* address, and the KMS governance key signs (EIP-191) what run A will bind it to:
# keccak256(abi.encode(TAG, CHAIN_ID, keccak256(abi.encode(address[14] roles)), keccak256(DEPLOY_SALT_TAG))).
# runA() recovers the signature and refuses to deploy unless it is KMS_GOVERNANCE's.
#   set -a; . script-evm/chains/<chain>.env; set +a
#   out=$(script-evm/check-kms-addresses.sh) || exit 1; eval "$out"   # exports KMS_GOVERNANCE_SIG
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CHAIN_ID:?source script-evm/chains/<chain>.env first}"
set -a; . script-evm/kms-roles.env; set +a
export AWS_REGION="${AWS_REGION:-eu-west-2}"
die() { echo "ERROR: $*" >&2; exit 1; }

roles=""
# Same order as KmsStack._addresses().
for r in DEPLOYER GOVERNANCE OPS NAV_FEED_OWNER SUBSCRIBER REDEEMER WHITELIST_ADMIN ISSUANCE_PAUSER \
  QUOTE_SIGNER TREASURER ALLOWLIST_ADMIN WITHDRAWAL_WALLET SANCTIONS_OWNER USER_WITHDRAWAL; do
  want="KMS_$r" id="KMS_${r}_KEY_ID"
  got="$(AWS_KMS_KEY_ID="${!id}" cast wallet address --aws)" || die "$id: cannot read key"
  [ "$(echo "$got" | tr A-F a-f)" = "$(echo "${!want}" | tr A-F a-f)" ] || die "$want: key is $got, env says ${!want}"
  echo "ok  $want ${!want}" >&2
  roles="$roles,${!want}"
done

hash="$(cast keccak "$(cast abi-encode 'f(bytes32,uint256,bytes32,bytes32)' "$(cast keccak GLD-807.kms-governance-proof)" \
  "$CHAIN_ID" "$(cast keccak "$(cast abi-encode 'f(address[14])' "[${roles#,}]")")" "$(cast keccak "${DEPLOY_SALT_TAG:-}")")")"
sig="$(AWS_KMS_KEY_ID="$KMS_GOVERNANCE_KEY_ID" cast wallet sign --aws "$hash")" || die "governance key cannot sign"
cast wallet verify --address "$KMS_GOVERNANCE" "$hash" "$sig" >/dev/null || die "signature does not recover to KMS_GOVERNANCE"
echo "export KMS_GOVERNANCE_SIG=$sig"
