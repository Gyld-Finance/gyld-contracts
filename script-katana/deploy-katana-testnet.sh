#!/usr/bin/env bash
# script-katana/deploy-katana-testnet.sh - full-stack KATANA TESTNET "Bokuto" (chain 737373)
# deployment in the PRODUCTION role topology, Halborn-audited bytecode unchanged, with the
# repo's 6-decimal MockUSDC as the cash leg (GLD-738).
# Runbook + roles & keys plan: docs/deploy/katana-testnet.md
#
#   script-katana/deploy-katana-testnet.sh [plan|keys|deploy|nav|smoke|verify|all]   (default: all)
#
#   plan    derive the role keys and print role -> address + the ETH plan (no tx, no files)
#   keys    write the derived role keys to $KEYS_FILE (chmod 600); no tx
#   deploy  fund role keys -> MockSanctionsList -> DeployDevNet -> MockUSDC (6dp) ->
#           governance Phase 2 through the timelock -> NAV $1.00 -> DeployAtomicSettlement ->
#           AP whitelist / inventory / cash / taker allowlist -> $ADDRESSES_FILE
#   nav     re-push every feed's current NAV (keep-alive: swaps refuse a NAV older than 24 h)
#   smoke   BUY + REDEEM 10 CAT through the swap, EIP-712 quote signed by the quote signer
#   verify  read every role holder and parameter back on-chain (read-only); rewrites
#           $ADDRESSES_FILE from what the chain says
#   all     deploy + smoke + verify
#
# THE FUNDED KEY (deployer + gas funder - nothing else) is read from $KATANA_TESTNET_PK_FILE
# (default ~/.gyld/katana-testnet-pk: the bare hex key, chmod 600) or from KATANA_TESTNET_PK
# if already exported. It reaches forge through the environment only: never argv, never a log.
#
# Gas: Katana is EIP-1559 with an L1 data fee, so there is no --legacy and no fixed gas
# price - forge estimates both. Nothing here uses eth_getLogs (the public RPC 504s on
# wide ranges).
#
# Environment (all optional):
#   RPC_URL            https://rpc-bokuto.katanarpc.com  (e.g. http://127.0.0.1:8599 = Anvil fork)
#   DRY_RUN=1          no --broadcast: deploy/all simulate deploy+smoke+verify in ONE forge run
#   CONFIRM=1          skip the interactive confirmation (required when stdin is not a TTY)
#   MIN_DEPLOYER_ETH   0.02  (preflight floor on the deployer's balance)
#   KEYS_FILE          ~/.gyld/katana-testnet-derived-keys.env  (...derived-keys.fork.env on a local RPC)
#   ADDRESSES_FILE     docs/deploy/katana-testnet-addresses.env (STATE_DIR/...fork.env on a local RPC)
#   STATE_DIR          ~/.gyld/katana-testnet  (logs + pending address manifest; no secrets)
#   RESUME=1           deploy: resume an interrupted broadcast (forge --resume)
#   VERIFY_CONTRACTS=1 deploy: also verify sources on katanascan (needs ETHERSCAN_API_KEY)

set +x # never trace: the funded key is in this shell's environment
set -euo pipefail
umask 077

die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_SOL="script-katana/KatanaTestnetStack.s.sol"
STACK_TC="KatanaTestnetStack"
EXPECTED_CHAIN_ID=737373
VERIFY_CHAIN="katana-bokuto" # the [etherscan] key in foundry.toml (Etherscan V2)

STEP="${1:-all}"
case "$STEP" in
  plan | keys | deploy | nav | smoke | verify | all) ;;
  -h | --help | help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) die "unknown step '$STEP' (plan|keys|deploy|nav|smoke|verify|all)" ;;
esac

RPC_URL="${RPC_URL:-https://rpc-bokuto.katanarpc.com}"
MIN_DEPLOYER_ETH="${MIN_DEPLOYER_ETH:-0.02}"
DRY_RUN="${DRY_RUN:-0}"
RESUME="${RESUME:-0}"
STATE_DIR="${STATE_DIR:-$HOME/.gyld/katana-testnet}"
LOG_DIR="$STATE_DIR/logs"

local_rpc_re='^https?://(127\.0\.0\.1|localhost|0\.0\.0\.0)([:/]|$)'
if [[ "$RPC_URL" =~ $local_rpc_re ]]; then
  LOCAL_RPC=1 # an Anvil fork: never touch the real keys file or the committed address file
  KEYS_FILE="${KEYS_FILE:-$HOME/.gyld/katana-testnet-derived-keys.fork.env}"
  ADDRESSES_FILE="${ADDRESSES_FILE:-$STATE_DIR/katana-testnet-addresses.fork.env}"
  # A fork is chain 737373 too: keep its forge broadcast journal out of broadcast/.../737373/, or a
  # later real `RESUME=1 deploy` would try to resume the fork's transactions.
  export FOUNDRY_BROADCAST="${FOUNDRY_BROADCAST:-$STATE_DIR/broadcast-fork}"
else
  LOCAL_RPC=0
  KEYS_FILE="${KEYS_FILE:-$HOME/.gyld/katana-testnet-derived-keys.env}"
  ADDRESSES_FILE="${ADDRESSES_FILE:-$REPO_ROOT/docs/deploy/katana-testnet-addresses.env}"
fi

DEPLOYER=""
ROLE_ADDRS=""
FUND_TOTAL_WEI=0
LAST_LOG=""
CONFIRMED=0

# ── helpers ────────────────────────────────────────────────────────────────────

# scheme://host only - an RPC URL may carry an API key in its path or userinfo.
rpc_host() { printf '%s' "$RPC_URL" | sed -E 's#^(https?://)([^@/]*@)?([^/?]+).*#\1\3#'; }

# KEY=VALUE lines from a forge log, for one machine-readable prefix ("@@" or "@@ROLE").
extract() { sed -n -E "s/^ *$1 ([A-Z0-9_]+)=([0-9A-Za-z]+)\$/\1=\2/p" "$2"; }

file_get() {
  if [ -f "$ADDRESSES_FILE" ]; then sed -n "s/^$1=//p" "$ADDRESSES_FILE" | tail -n 1; fi
}

lower() { printf '%s' "$1" | tr 'A-F' 'a-f'; }

tilde() { case "$1" in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

has_code() {
  local n
  n="$(cast codesize "$1" --rpc-url "$RPC_URL" 2>/dev/null || echo 0)"
  [ "${n:-0}" -gt 0 ]
}

eth_of() { cast from-wei "$(cast balance "$1" --rpc-url "$RPC_URL")"; }

ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 >= b + 0) }'; }

sum_balances() {
  local total=0 a
  for a in $ROLE_ADDRS; do
    total="$(awk -v t="$total" -v b="$(eth_of "$a")" 'BEGIN { printf "%.9f", t + b }')"
  done
  printf '%s' "$total"
}

load_key() {
  local raw f perms
  if [ -n "${KATANA_TESTNET_PK:-}" ]; then
    raw="$KATANA_TESTNET_PK"
  else
    f="${KATANA_TESTNET_PK_FILE:-$HOME/.gyld/katana-testnet-pk}"
    [ -f "$f" ] || die "no funded key: put the bare hex key in $f (chmod 600) or set KATANA_TESTNET_PK_FILE"
    perms="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f")"
    case "$perms" in
      600 | 400) ;;
      *) die "$f is mode $perms - other users could read the key. Run: chmod 600 '$f'" ;;
    esac
    raw="$(cat "$f")"
  fi
  # Builtin printf + stdin-reading filters: the key never appears in a process argv.
  raw="$(printf '%s' "$raw" | tr -d ' \t\r\n')"
  raw="${raw#0x}"
  raw="${raw#0X}"
  printf '%s' "$raw" | grep -Eq '^[0-9a-fA-F]{64}$' \
    || die "the funded key is not 32 bytes of hex (expected MetaMask 'Export private key' output)"
  export KATANA_TESTNET_PK="0x$raw"
}

# forge_stack <sig> <broadcast|simulate> - runs one KatanaTestnetStack entry point, logs the
# full output to $LOG_DIR (no secrets reach it) and echoes the script's own console lines.
forge_stack() {
  local sig="$1" mode="$2" log rc=0
  mkdir -p "$LOG_DIR"
  log="$LOG_DIR/$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%s' "$sig" | tr -d '()').log"
  # No --legacy / --with-gas-price: EIP-1559 + L1 data fee, forge estimates both.
  set -- script "$STACK_SOL" --tc "$STACK_TC" --sig "$sig" --rpc-url "$RPC_URL"
  if [ -n "$DEPLOYER" ]; then set -- "$@" --sender "$DEPLOYER"; fi
  if [ "$mode" = broadcast ]; then
    set -- "$@" --broadcast --slow
    if [ "$RESUME" = 1 ]; then set -- "$@" --resume; fi
    if [ "${VERIFY_CONTRACTS:-0}" = 1 ]; then set -- "$@" --verify --chain "$VERIFY_CHAIN"; fi
  fi
  # An Anvil fork automines: when idle its `latest` timestamp goes stale, forge simulates
  # against that, and a 85 s quote is already expired once mined. Mine a block first so
  # `latest` is "now", as it always is on the live chain (~1 s blocks).
  if [ "$LOCAL_RPC" = 1 ]; then cast rpc evm_mine --rpc-url "$RPC_URL" >/dev/null 2>&1 || true; fi
  (cd "$REPO_ROOT" && forge "$@") >"$log" 2>&1 || rc=$?
  LAST_LOG="$log"
  awk '/^== Logs ==/ { on = 1; next } /^## Setting up/ { on = 0 } on && !/^ *@@/' "$log"
  grep -E 'Estimated total gas used|Estimated amount required|ONCHAIN EXECUTION COMPLETE|SIMULATION COMPLETE' "$log" || true
  if [ "$rc" -ne 0 ]; then
    printf '\n--- forge exited %s; last lines of %s ---\n' "$rc" "$log" >&2
    tail -n 40 "$log" >&2
  fi
  return "$rc"
}

confirm() {
  if [ "$DRY_RUN" = 1 ] || [ "$CONFIRMED" = 1 ] || [ "${CONFIRM:-0}" = 1 ]; then
    CONFIRMED=1
    return 0
  fi
  [ -t 0 ] || die "stdin is not a terminal - set CONFIRM=1 to broadcast non-interactively"
  printf '\nAbout to BROADCAST step "%s" to chain %s via %s, deployer %s.\n' \
    "$STEP" "$EXPECTED_CHAIN_ID" "$(rpc_host)" "$DEPLOYER"
  printf 'Type "broadcast" to continue: '
  local answer
  read -r answer
  [ "$answer" = broadcast ] || die "aborted - nothing was sent"
  CONFIRMED=1
}

# ── steps ─────────────────────────────────────────────────────────────────────

preflight() {
  local cid
  for t in forge cast awk sed grep; do
    command -v "$t" >/dev/null 2>&1 || die "$t not found on PATH (Foundry: https://getfoundry.sh)"
  done
  load_key
  mkdir -p "$STATE_DIR" "$LOG_DIR"
  chmod 700 "$STATE_DIR"
  cid="$(cast chain-id --rpc-url "$RPC_URL" 2>/dev/null)" || die "RPC $(rpc_host) is unreachable"
  [ "$cid" = "$EXPECTED_CHAIN_ID" ] || die "RPC $(rpc_host) is chain $cid, not Katana Bokuto testnet ($EXPECTED_CHAIN_ID)"

  local where
  where="$(rpc_host)"
  if [ "$LOCAL_RPC" = 1 ]; then where="$where (LOCAL FORK - keys/addresses go to *.fork.env)"; fi
  info "Role plan - chain $cid via $where"
  forge_stack "plan()" simulate || die "could not derive the role plan (first run compiles: ~1-2 min)"
  DEPLOYER="$(extract '@@ROLE' "$LAST_LOG" | sed -n 's/^DEPLOYER_ADDRESS=//p')"
  FUND_TOTAL_WEI="$(extract '@@ROLE' "$LAST_LOG" | sed -n 's/^FUND_TOTAL_WEI=//p')"
  ROLE_ADDRS="$(extract '@@ROLE' "$LAST_LOG" | grep -v '^FUND_TOTAL_WEI=' | cut -d= -f2 | tr '\n' ' ')"
  [ -n "$DEPLOYER" ] || die "could not derive the deployer address"
  printf '    keys file: %s\n    addresses: %s\n' "$KEYS_FILE" "$ADDRESSES_FILE"
}

# Prints the deployer balance; returns 1 when it is below MIN_DEPLOYER_ETH.
check_balance() {
  local bal
  bal="$(eth_of "$DEPLOYER")"
  printf '    deployer balance %s ETH (floor MIN_DEPLOYER_ETH=%s; role gas floats total %s)\n' \
    "$bal" "$MIN_DEPLOYER_ETH" "$(cast from-wei "$FUND_TOTAL_WEI")"
  ge "$bal" "$MIN_DEPLOYER_ETH"
}

require_balance() {
  check_balance || die "deployer $DEPLOYER is below MIN_DEPLOYER_ETH=$MIN_DEPLOYER_ETH ETH - fund it (bridge Sepolia ETH at https://bridge.katana.network, or the Bokuto faucet; see docs/deploy/katana-testnet.md)"
}

write_keys() {
  local dir tmp existing
  dir="$(dirname "$KEYS_FILE")"
  mkdir -p "$dir"
  chmod 700 "$dir"
  if [ -f "$KEYS_FILE" ]; then
    existing="$(sed -n 's/^DEPLOYER_ADDRESS=//p' "$KEYS_FILE")"
    [ "$(lower "$existing")" = "$(lower "$DEPLOYER")" ] \
      || die "$KEYS_FILE holds keys derived from deployer $existing, not $DEPLOYER - set KEYS_FILE elsewhere"
  fi
  tmp="$(mktemp "$dir/.katana-testnet-keys.XXXXXX")"
  {
    printf '# Katana Bokuto testnet (chain 737373) role keys DERIVED from the funded deployer key (GLD-738).\n'
    printf '# THROWAWAY testnet keys: chmod 600, never commit, never fund on a real chain.\n'
    printf '# pk(role) = keccak256(abi.encodePacked(KATANA_TESTNET_PK, "gyld.katana737373.<role>")) mod (n-1) + 1\n'
    printf '# Regenerate (deterministic): script-katana/deploy-katana-testnet.sh keys\n'
  } >"$tmp"
  # The one place a key is printed: forge stdout -> sed -> this chmod-600 file. Nothing else.
  if ! (cd "$REPO_ROOT" && forge script "$STACK_SOL" --tc "$STACK_TC" --sig 'exportKeys()' \
    --rpc-url "$RPC_URL" 2>"$LOG_DIR/exportKeys.err") | sed -n 's/^ *@@KEY //p' >>"$tmp"; then
    rm -f "$tmp"
    die "key export failed - see $LOG_DIR/exportKeys.err"
  fi
  grep -q '^GOVERNANCE_PK=0x' "$tmp" || { rm -f "$tmp"; die "key export produced no keys"; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$KEYS_FILE"
  printf '    derived role keys -> %s (chmod 600)\n' "$KEYS_FILE"
}

# install_addresses <manifest> <provenance> - header + KEY=VALUE lines -> $ADDRESSES_FILE
install_addresses() {
  local tmp
  grep -q '^EVM_ATOMIC_SWAP_ADDRESS=0x' "$1" || die "no address manifest in $1"
  tmp="$(mktemp "$STATE_DIR/.addresses.XXXXXX")"
  {
    printf '# Katana Bokuto testnet (chainId 737373) - GLD-738 full stack in the production role topology.\n'
    printf '# Written by script-katana/deploy-katana-testnet.sh (%s, %s UTC).\n' "$2" "$(date -u '+%Y-%m-%d %H:%M')"
    printf '# ADDRESSES ONLY - no secrets. Role keys: %s (chmod 600, never committed).\n' "$(tilde "$KEYS_FILE")"
    cat "$1"
  } >"$tmp"
  mkdir -p "$(dirname "$ADDRESSES_FILE")"
  chmod 644 "$tmp"
  mv -f "$tmp" "$ADDRESSES_FILE"
  printf '    addresses -> %s\n' "$ADDRESSES_FILE"
}

load_stack_env() {
  [ -f "$ADDRESSES_FILE" ] || die "no $ADDRESSES_FILE - run the deploy step first (or set ADDRESSES_FILE)"
  EVM_FACTORY_ADDRESS="$(file_get EVM_FACTORY_ADDRESS)"
  EVM_ATOMIC_SWAP_ADDRESS="$(file_get EVM_ATOMIC_SWAP_ADDRESS)"
  [ -n "$EVM_FACTORY_ADDRESS" ] && [ -n "$EVM_ATOMIC_SWAP_ADDRESS" ] \
    || die "$ADDRESSES_FILE lacks EVM_FACTORY_ADDRESS / EVM_ATOMIC_SWAP_ADDRESS"
  export EVM_FACTORY_ADDRESS EVM_ATOMIC_SWAP_ADDRESS
}

BAL_ALL_BEFORE=""
BAL_DEPLOYER_BEFORE=""

snapshot_before() {
  BAL_DEPLOYER_BEFORE="$(eth_of "$DEPLOYER")"
  BAL_ALL_BEFORE="$(sum_balances)"
}

report_spend() {
  [ -n "$BAL_ALL_BEFORE" ] || return 0
  local dep_after all_after
  dep_after="$(eth_of "$DEPLOYER")"
  all_after="$(sum_balances)"
  info "ETH accounting (EIP-1559, forge-estimated fees incl. L1 data fee)"
  awk -v d0="$BAL_DEPLOYER_BEFORE" -v d1="$dep_after" -v a0="$BAL_ALL_BEFORE" -v a1="$all_after" 'BEGIN {
    printf "    deployer paid           %.8f ETH (gas + role floats)\n", d0 - d1
    printf "    gas burned, all keys    %.8f ETH\n", a0 - a1
    printf "    left on role keys       %.8f ETH (top-up floats for later operations)\n", (d0 - d1) - (a0 - a1)
  }'
}

do_deploy() {
  local swap rc=0 pending="$STATE_DIR/addresses.pending.env"
  swap="$(file_get EVM_ATOMIC_SWAP_ADDRESS)"
  if [ -n "$swap" ] && [ "$RESUME" != 1 ] && has_code "$swap"; then
    die "a stack is already live (swap $swap per $ADDRESSES_FILE). Use nav/smoke/verify - see 'Re-running safely' in docs/deploy/katana-testnet.md"
  fi
  require_balance
  if [ "$DRY_RUN" = 1 ]; then
    info "DRY RUN - deploy + smoke + verify simulated in ONE forge run against $(rpc_host); nothing is sent"
    forge_stack "dryRun()" simulate || die "dry run failed - see $LAST_LOG"
    return 0
  fi
  confirm
  info "Derived role keys"
  write_keys
  snapshot_before
  info "Deploy (broadcast; --slow: one confirmed transaction at a time)"
  # On RESUME, forge re-executes deploy() only to collect signers; KATANA_STACK_RESUME makes
  # it register the 14 keys and stop instead of re-deploying (see KatanaTestnetStack.deploy).
  if [ "$RESUME" = 1 ]; then export KATANA_STACK_RESUME=1; fi
  forge_stack "deploy()" broadcast || rc=$?
  if [ "$RESUME" != 1 ]; then
    # The manifest is printed during simulation, before anything is sent; keep it even if
    # the broadcast dies half-way, so a RESUME=1 run (which prints nothing) can install it.
    extract '@@' "$LAST_LOG" >"$pending.tmp"
    if grep -q '^EVM_ATOMIC_SWAP_ADDRESS=0x' "$pending.tmp"; then mv -f "$pending.tmp" "$pending"; else rm -f "$pending.tmp"; fi
  fi
  if [ "$rc" -ne 0 ]; then
    die "deploy failed (forge exit $rc; log $LAST_LOG). If the log shows transactions were sent, finish with:
    RESUME=1 $0 deploy
If it failed in simulation, nothing was sent: fix the cause and re-run."
  fi
  [ -f "$pending" ] || die "deploy finished but there is no address manifest ($pending)"
  install_addresses "$pending" "deploy"
}

do_nav() {
  load_stack_env
  if [ "$DRY_RUN" = 1 ]; then forge_stack "pushNav()" simulate || die "nav simulation failed"; return 0; fi
  confirm
  info "NAV keep-alive (NAV feed owner key)"
  forge_stack "pushNav()" broadcast || die "nav push failed - see $LAST_LOG"
}

do_smoke() {
  load_stack_env
  if [ "$DRY_RUN" = 1 ]; then forge_stack "smoke()" simulate || die "smoke simulation failed"; return 0; fi
  confirm
  info "Smoke settlement: BUY + REDEEM (quote signer signs, taker submits)"
  forge_stack "smoke()" broadcast || die "smoke failed - see $LAST_LOG"
}

do_verify() {
  load_stack_env
  info "Verify (read-only)"
  forge_stack "verify()" simulate || die "verification FAILED - see $LAST_LOG"
  if [ "$DRY_RUN" != 1 ]; then
    extract '@@' "$LAST_LOG" >"$STATE_DIR/addresses.verified.env"
    install_addresses "$STATE_DIR/addresses.verified.env" "verify: read back on-chain"
  fi
}

# ── main ──────────────────────────────────────────────────────────────────────

preflight
case "$STEP" in
  plan)
    check_balance || printf '    BELOW THE FLOOR - fund the deployer before the deploy step\n'
    ;;
  keys)
    write_keys
    ;;
  deploy)
    do_deploy
    report_spend
    ;;
  nav) do_nav ;;
  smoke) do_smoke ;;
  verify) do_verify ;;
  all)
    if [ "$DRY_RUN" = 1 ]; then
      do_deploy # the dry run already covers smoke + verify in the same simulation
    else
      do_deploy
      do_smoke
      do_verify
      report_spend
    fi
    ;;
esac
if [ "$DRY_RUN" = 1 ]; then info "done ($STEP, DRY RUN - nothing was sent)"; else info "done ($STEP)"; fi
