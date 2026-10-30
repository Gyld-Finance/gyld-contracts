# Fordefi replay

Forge cannot sign through Fordefi. This tool takes the plan a forge **dry-run**
writes (`broadcast/<Script>.s.sol/<chain>/dry-run/<sig>-latest.json`) and sends
exactly those transactions, in order, through the Fordefi vault that is each
transaction's `from`. No blockchain private key exists anywhere.

Each transaction goes through Fordefi's raw API, [`POST /api/v1/transactions`](https://docs.fordefi.com/api/openapi/transactions/create_transaction_api_v1_transactions_post)
(`evm_raw_transaction`, `details.custom_nonce` = the planned nonce, one idempotence id per
step), and is polled with `GET /api/v1/transactions/{id}` — the Fordefi Web3 provider
cannot pin a nonce, so it is used only by `sign-message.mjs` (`personal_sign`).

**Runbook (phase commands, signers, governance proof): [`docs/deploy/bsc-testnet.md`](../../docs/deploy/bsc-testnet.md#fordefi-vaults-gld-978).**
BSC mainnet (56, `CHAIN_ID=56`): [`docs/deploy/bsc-mainnet.md`](../../docs/deploy/bsc-mainnet.md).
Rehearsal on an Anvil fork, through this tool: `script-bsc/simulate-fordefi-stack.sh` (`CHAIN=56` for mainnet).

| File | Purpose |
|---|---|
| `replay.mjs` | Plan mode (default, offline): table + `PLAN_SHA256`. `--execute`: send the approved plan. `--clear <idx>`: drop a `submitting` step's idempotence id and Fordefi id, so the next `--execute` re-checks the nonce and creates a new request |
| `sign-message.mjs` | `personal_sign` via the Contract Admin vault, for `FORDEFI_GOVERNANCE_SIG` |
| `fordefi.mjs` | Vault/credential loading shared by both |
| `roles.example.env` | Every env var name; copy to `roles.env` (git-ignored) |
| `roles.bsc-mainnet.example.env` | The same for BSC mainnet (`CHAIN_ID=56`) |

## Prerequisites

- **Fordefi API users** (with a paired API signer key) for every vault that
  signs: Contract Admin (proof, run B), Blocklist Updater (A2), NAV Feeder (C2),
  Whitelister + Subscriber (C4). The deploys themselves are signed by the KMS
  deployer, which maps to no vault, so the replay refuses any of its txs.
  Each signing vault needs `FORDEFI_<LABEL>_VAULT_ID` (the create call takes the vault id).
  The **API signer must be online**.
- **Run from an allowlisted host** (UAT host or VPN egress) — never a laptop.
  Check egress with `curl -s https://api.ipify.org`, not the VPN status.
- **tBNB in every signing vault** — each vault pays its own gas.
- Node 20+, `npm install` here, `forge build` in the repo root.

## Fordefi policy on deploy day

See [the runbook](../../docs/deploy/bsc-testnet.md#fordefi-vaults-gld-978): Contract Admin
3-of-4, NAV Feeder auto-approve; no Deployer vault.

Always dry-run each phase **after** the previous one is confirmed: the plan
pins every sender's nonce and every created address to the chain state forge
simulated against.

## Safety checks

- `--execute` refuses unless `PLAN_SHA256` equals the hash of the plan on disk
  (type, from, to, value, calldata, gas, nonce, chain id, expected contracts).
- Plan must be all chain `CHAIN_ID` (default 97); the RPC must report the same chain.
- Before the first send: every `from` maps to exactly one labelled vault with
  credentials, every vault connects and resolves to its address, every vault
  has gas.
- Before each send the sender's pending nonce must equal the planned nonce, and
  the Fordefi request pins it (`custom_nonce`); after it, the mined tx must have
  that nonce, `status == 1`, and every contract the plan creates must have code.
- Plain `CREATE` (no `to`) is sent without `to`; CREATE2 is a normal call to
  `0x4e59b44847b379578588920cA78FbF26c0B4956C`.
- `REPLAY_TEST_RPC_SIGNER=1` (rehearsal only) sends as anvil-impersonated
  accounts instead of Fordefi; it refuses any RPC that is not a local anvil node.

## Stops and resume

Progress is `<plan>.progress.json` (git-ignored), bound to the plan hash.
Re-running the same `--execute` command skips confirmed txs and waits on any
tx that was sent but not yet confirmed — it never resubmits those.

| Stop | What to do |
|---|---|
| Rejected / aborted in Fordefi, or create refused (4xx) | Nothing was sent; the step's marker is dropped automatically. Fix the cause, re-run the same command |
| Approval, network or 5xx timeout ("outcome unknown") | Progress keeps `submitting` with its idempotence id (and Fordefi id once created). Re-run the same command: it polls the saved Fordefi id; else it looks the request up by its note (unique per attempt) and polls it; else it re-posts under the same `x-idempotence-id` (a 409 is resolved by the same lookup). Several requests with that note stop the run: resolve them in the console |
| Fordefi state `error_pushing_to_blockchain`, `dropped`, `accelerated` or `cancelled` | Check the sender's nonce on the explorer. Planned nonce unused: `node replay.mjs <plan> --clear <idx>`, then re-run (new request, same pinned nonce). Used: archive the progress file, dry-run the phase again |
| No receipt within `RECEIPT_TIMEOUT_MS` | Re-run; it waits on the saved hash |
| Nonce mismatch | Chain moved since the dry-run; archive the progress file, dry-run again |
| Reverted on chain | Investigate on the explorer; then dry-run again |
| Different plan hash vs progress file | Archive the old progress file (it records what was sent) first |

The forge scripts skip steps that are already done, so a fresh dry-run after a
partial phase yields only the remaining transactions.
