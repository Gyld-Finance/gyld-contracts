# Continuous Integration

GitHub Actions, defined in `.github/workflows/ci.yml`. Runs on every push, every
pull request, and on manual dispatch. No job uses a secret, an RPC URL, or a
private key — the workflow is structurally unable to broadcast anything: there
is no key material on the runner, the test suite contains no fork cheatcodes,
and `GITHUB_TOKEN` is `contents: read`. If a future job needs a secret, put it
in a separate workflow so this one stays trustless.

## Jobs

| Job | What it does | What it protects against |
|-----|--------------|---------------------------|
| `test` | `forge build` + `forge test` at **full** `foundry.toml` intensity (fuzz `runs = 10000`, invariant `runs = 1000, depth = 50`, 496 tests) | Regressions in contracts, scripts and invariants landing on `main` unnoticed |
| `chain-guard` | `python3 ci/check_chain_guards.py` — comment-aware scan of `contracts/script/`. Fails on (a) any `block.chainid !=` comparison and (b) any script carrying **no** chain guard at all | The GYL-1135 bug class: denylist "mainnet protection" (`require(block.chainid != 1, ...)`) that every L2 walks straight past — how a zero-delay timelock and a bare-EOA admin reached live Base mainnet. Guards must be allowlists (`DeployGuards.isDevChain()`). Check (b) closes the checker's own blind spot: a *missing* guard is invisible to a scan that only inspects guards that were written, which is how the ungated `DeployMockUSDC.s.sol` survived the first pass |

## Why full fuzz intensity on every push

Measured on a cold build (Apple Silicon, forge 1.5.1): `via_ir` compile 35 s,
full-intensity `forge test` **16 s** wall (48 s CPU). Even at the usual 2–3×
slowdown of a GitHub-hosted runner plus recursive submodule checkout, the whole
job lands well under ~5 minutes cold and less warm (build artifacts are
cached). Reducing fuzz runs would save seconds and cost coverage, so nothing is
dialled down and there is no separate nightly: every push gets the same
scrutiny. If suite runtime ever grows past ~10 minutes, split intensity then —
reduced per-push via `FOUNDRY_FUZZ_RUNS` / `FOUNDRY_INVARIANT_RUNS` env
overrides, full on a schedule.

## Pinning

Actions are pinned to commit SHAs (comment shows the tag), Foundry is pinned to
`v1.5.1` (the version the team runs locally), and `lib/` submodules are pinned
by gitmodule SHA + `foundry.lock`. Nothing floats, so a red build always means
the code changed, not the environment. Bump the pins deliberately.

## Reproducing a failure locally

```bash
forge test -vvv                      # same command, same foundry.toml intensity
python3 ci/check_chain_guards.py     # the chain-guard scan; exit 1 on violation
```

Fuzz/invariant failures print the counterexample; re-run with the seed from the
CI log if you need the exact case.

## Considered and rejected

- **`forge fmt --check`** — the tree is not currently fmt-clean
  (e.g. `contracts/NAVFeedForwarder.sol`), so the check would start red and get
  ignored. Adopt after a dedicated `forge fmt` commit, not before.
- **`forge build --deny-warnings`** — two live solc warnings (state mutability,
  `contracts/test/GyldAtomicSwap.halmos.t.sol:235` and
  `contracts/test/GyldAtomicSwap.spec.t.sol:599`) plus ~40 `forge lint` notes
  (`erc20-unchecked-transfer`, `unsafe-typecast`). Same rule: fix first, then
  enforce, otherwise the job starts red.
- **Gas snapshots** — no `.gas-snapshot` baseline exists, most hot paths are
  fuzz tests (nondeterministic gas), and `via_ir` makes diffs churn on
  unrelated edits. A snapshot job that flakes teaches people to ignore CI.
- ~~**Broadcast-without-guard job**~~ — **adopted**, and it starts green. The
  earlier objection was that 8 of 14 broadcasting scripts (the
  `DeployEulerStep*` family) pin their chain with a bare
  `require(block.chainid == 8453)` and never reference `DeployGuards`, so a
  check for a `DeployGuards` *call* would start red. The fix was to check for
  a **chain guard**, not for the library: a positive `block.chainid ==` pin is
  a fail-closed allowlist of exactly one chain and counts. Both forms are
  accepted, so no script needed rewriting and the job is green at adoption.
  This matters because the `chain-guard` denylist scan is structurally blind
  to a script with no guard at all — which is how the ungated
  `DeployMockUSDC.s.sol` survived the first pass of GYL-1135.

The bar for adding a job: it must start green, fail only for real defects, and
carry an error message that explains itself two years from now.
