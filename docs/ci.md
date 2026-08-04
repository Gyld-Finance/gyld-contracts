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
| `coverage` | `forge coverage --ir-minimum --report summary`, at reduced fuzz intensity, publishing the table to the run summary. **Non-blocking** (`continue-on-error: true`, no threshold) | Nothing, by design — it is a trend instrument, not a gate. See "Coverage" below for what the number is and is not |

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

## Coverage

`forge coverage` produced *nothing* on this repo until 2026-08. `via_ir = true`
defeats solc's coverage instrumentation, and the documented workaround
(`--ir-minimum`) hit two test failures that aborted the run before any table
was emitted. Both were real defects in the tests, not in the contracts:

- **`KaleidoscopeNAVFeedTest::test_updateAnswer_updatedAtAdvances`** —
  `uint256 t0 = block.timestamp` is **not a snapshot** under viaIR. solc treats
  `timestamp()` as a movable, side-effect-free builtin and rematerialises it at
  each use site, because it cannot know that `vm.warp` (an opaque external
  call) mutates block context. Reading such a local after a warp yields the
  *current* time. This is true under the shipping `via_ir` profile too — the
  test only passed there because CSE folded `t0 + 1 days` into the identical
  expression already computed for the `vm.warp` argument, so the sum happened
  to be evaluated pre-warp. Without CSE (`--ir-minimum`) it was recomputed
  post-warp and came out one day late. Fixed by pinning both edges to absolute
  literals, which is strictly stronger than the relative arithmetic it
  replaced. **Do not capture `block.timestamp` into a local you intend to read
  across a `vm.warp`.** A sweep found this was the only such site.
- **`SanctionsOracleMirrorTest::test_isSanctioned_gasGriefingOracle_bounded`** —
  the `GasGriefingOracle` test double burned gas down to `gasleft() > 100`, but
  the gas its own ABI return epilogue needs is compiler-dependent: 100 is just
  barely enough under `via_ir` + optimizer, ~450 under `--ir-minimum`. Under
  coverage the double therefore OOG'd mid-return, the `setForwardingOracle`
  probe saw `ok == false`, and installing the oracle reverted
  `InvalidForwardingOracle` before the test measured anything. The reserve is
  now 5_000 (~10x the measured worst case). The production gas cap
  (`FORWARDING_GAS = 40_000`) was never implicated. A lower-bound assertion was
  added at the same time: the original test asserted only `gasUsed < 100_000`,
  which also passes if the griefer never griefs at all — which is precisely how
  this breakage stayed invisible.

Both are worth remembering as a class: **a test that passes under only one
optimiser configuration was never pinning the property it appeared to pin.**

### What the number means

Production contracts (`contracts/*.sol`) at the first measurement:

| Contract | Lines | Statements | Branches | Funcs |
|---|---|---|---|---|
| `GyldAtomicSwap.sol` | 94.64% (159/168) | 95.32% (224/235) | 95.35% (41/43) | 100% (32/32) |
| `GyldBondToken.sol` | 88.89% (56/63) | 89.33% (67/75) | 90.91% (10/11) | 100% (19/19) |
| `IssuanceManager.sol` | 91.07% (51/56) | 92.19% (59/64) | 100% (14/14) | 100% (14/14) |
| `KaleidoscopeNAVFeed.sol` | 100% (59/59) | 100% (66/66) | 100% (15/15) | 100% (15/15) |
| `NAVFeedForwarder.sol` | 100% (39/39) | 100% (64/64) | 100% (9/9) | 100% (10/10) |
| `SanctionsOracleMirror.sol` | 100% (40/40) | 100% (51/51) | 100% (11/11) | 100% (8/8) |
| `TokenFactory.sol` | 97.87% (46/47) | 96.83% (61/63) | 88.89% (8/9) | 100% (7/7) |
| **7 production contracts** | **95.34% (450/472)** | **95.79% (592/618)** | **96.43% (108/112)** | **100% (105/105)** |

The repo-wide `Total` that `--report summary` prints is **65.08%**. Ignore it:
it is dominated by `DeployEulerStep*` and `AtomicSettlementFlow` scripts that
are broadcast-only and have no test harness, so it measures how many deploy
scripts have tests, not how well the contracts are tested.

Two honest caveats, in order of importance:

1. **It is not the bytecode that ships.** These percentages describe
   `--ir-minimum`-compiled contracts. The deployed artifacts are `via_ir` +
   `optimizer_runs = 200`. Coverage tells you *which source constructs the
   tests reached*, which is optimiser-independent and is the useful part. It
   tells you nothing about optimiser-introduced behaviour, and — as the two
   failures above prove — the two pipelines genuinely do not always behave
   alike. Coverage is not evidence about the shipping bytecode.
2. **A 0-hit line is not necessarily untested.** Most of the 22 uncovered
   production lines are forge source-map attribution artifacts:
   - inline `assembly` bodies are not instrumented at all — every
     `_getStorage()` (`GyldAtomicSwap:250`, `GyldBondToken:68`,
     `IssuanceManager:62`) and the `create2` in `TokenFactory:172` reads as
     uncovered while being executed by essentially every test;
   - empty-bodied inherited initialisers (`__AccessControl_init`,
     `__Pausable_init`, `__ReentrancyGuard_init`, `__UUPSUpgradeable_init`)
     emit no code at the call site, so there is no counter to hit. Their
     non-trivial siblings (`__ERC20_init`, `__EIP712_init`) do show covered;
   - one-line delegating bodies (`pause() { _pause(); }`, `_disableInitializers()`)
     collapse into the inlined callee's source range.

   So real production coverage is *higher* than 95.34%, and `IssuanceManager`'s
   91.07% is **entirely** artifact — it has no genuine gap at all.

### The uncovered paths that actually matter

Exactly two genuine gaps, both narrow, and neither on the hot path:

- **`GyldAtomicSwap.sol:361`** — `initialize()`'s cash-token `decimals()` probe
  failure branch (`!usdcOk || usdcData.length != 32`). Its wrong-decimals
  sibling on line 363 *is* covered, and the analogous guard on
  `registerSeries` is covered for both the wrong-decimals and the
  no-`decimals()`-at-all cases. Only the initializer's "USDC address has no
  `decimals()`" case is untested. Low severity: one-shot at deploy, fails loud.
- **`GyldBondToken.sol:192`** — `mint(to, 0)` → `ZeroAmount`. `burn(x, 0)` and
  `mint(address(0), …)` are both tested; this one is a symmetry gap.

`GyldAtomicSwap.sol:356` (`DEFAULT_MAX_QUOTE_TTL > MAX_QUOTE_TTL_CEILING`) is
a comparison of two constants — the revert side is structurally dead and cannot
be covered without changing the constants. It is a deliberate future-proofing
guard; leave it.

**The reassuring part:** `executeSwap` (lines 471-570) and `_checkQuoteBand`
(571-632) — the value-moving hot path — contain **zero** uncovered lines and
**zero** uncovered branches. Every uncovered branch in `GyldAtomicSwap` is in
`initialize()`. An uncovered branch in a settlement path and an uncovered
branch in a deploy-time guard are not the same finding, and this repo only has
the latter.

## Pinning

Actions are pinned to commit SHAs (comment shows the tag), Foundry is pinned to
`v1.5.1` (the version the team runs locally), and `lib/` submodules are pinned
by gitmodule SHA + `foundry.lock`. Nothing floats, so a red build always means
the code changed, not the environment. Bump the pins deliberately.

## Reproducing a failure locally

```bash
forge test -vvv                      # same command, same foundry.toml intensity
python3 ci/check_chain_guards.py     # the chain-guard scan; exit 1 on violation

# Coverage. --ir-minimum is mandatory (via_ir breaks instrumentation); without
# it forge emits no table at all. The env overrides match the CI job and are
# free: they produce a byte-identical table (1053/1618 lines) in 1.4 s of test
# time instead of 44 s, because coverage only asks whether a line was ever
# reached. Drop them if you want to confirm that for yourself.
FOUNDRY_FUZZ_RUNS=256 FOUNDRY_INVARIANT_RUNS=64 FOUNDRY_INVARIANT_DEPTH=25 \
  forge coverage --ir-minimum --report summary
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

- **A coverage threshold / `--fail-under` gate** — rejected, while the
  `coverage` job itself was adopted as informational. A minimum picked from the
  first-ever measurement is an arbitrary number that then gets defended as if
  it were a standard: it would either sit far enough below 95% to never fire, or
  be set at 95% and start blocking PRs over source-map artifacts (see
  "Coverage" — `IssuanceManager`'s 9% "gap" is entirely uninstrumented
  `assembly` and empty-bodied initialisers). Worse, the number describes
  `--ir-minimum` bytecode, so a gate would be enforcing a property of code that
  never ships. Watch the trend for a few months; if it justifies a floor, set
  the floor on `contracts/*.sol` only and on branches rather than lines.
- **Making `coverage` a blocking job** — rejected for now. It is one optimiser
  configuration away from the `test` job, and the two failures that had to be
  fixed to make it run at all were both optimiser-sensitivity bugs. Until the
  suite has proven itself stable under both pipelines for a while, a red
  `coverage` should be a signal to investigate, not a merge block. Note that
  `--ir-minimum` is a genuinely useful second opinion — it caught two tests
  that were passing by accident — so if it starts failing, read it before
  dismissing it.
- **Excluding tests from the coverage run** (`--no-match-test`) — considered as
  the cheap way to get a number, rejected. Both failing tests had real,
  fixable causes; skipping them would have hidden two live findings about the
  test suite's optimiser-sensitivity and left the coverage number quietly
  measuring less than it claimed. Nothing is excluded.

The bar for adding a job: it must start green, fail only for real defects, and
carry an error message that explains itself two years from now.
