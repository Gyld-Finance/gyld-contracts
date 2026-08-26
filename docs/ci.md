# Continuous Integration

GitHub Actions, defined in `.github/workflows/ci.yml`. Runs on every pull
request, on every push to `main`, and on manual dispatch. `push` is filtered to
`main` deliberately: an unfiltered `push` fires alongside `pull_request` for
every commit on a same-repo PR branch, and because the concurrency group keys on
`github.event_name` the two runs do not cancel each other — every such commit
paid for two full builds. A PR branch is now covered exactly once, by
`pull_request`.

No job uses a secret, an RPC URL, or a private key — the workflow is structurally unable to broadcast anything: there
is no key material on the runner, the test suite contains no fork cheatcodes,
and `GITHUB_TOKEN` is `contents: read`. If a future job needs a secret, put it
in a separate workflow so this one stays trustless.

## Jobs

| Job | What it does | What it protects against |
|-----|--------------|---------------------------|
| `test` | `forge build` + `forge test` at **full** `foundry.toml` intensity (fuzz `runs = 10000`, invariant `runs = 1000, depth = 50`; 543 tests across 20 suites as of 2026-08-26, confirmed with `forge test --list`) | Regressions in contracts, scripts and invariants landing on `main` unnoticed |
| `chain-guard` | `python3 ci/check_chain_guards.py` — comment-aware scan of `contracts/script/`. Fails on (a) any `block.chainid !=` comparison and (b) any script carrying **no** chain guard at all | The GYL-1135 bug class: denylist "mainnet protection" (`require(block.chainid != 1, ...)`) that every L2 walks straight past — a production L2 satisfies `!= 1`, so a zero-delay timelock and a bare-EOA admin sail onto a live chain unopposed. Guards must be allowlists — either a `DeployGuards` call (`isDevChain()` / `requireProdSafe()`) or a positive `block.chainid == <id>` pin, which is a fail-closed allowlist of exactly one chain and is why `AtomicSettlementFlow` and `DeployAtomicSettlementE2E` pass without using the library. Check (b) closes the checker's own blind spot: a *missing* guard is invisible to a scan that only inspects guards that were written, which is how the ungated `DeployMockUSDC.s.sol` survived the first pass |
| `test` (step) | `python3 ci/check_storage_layout.py` — regenerates the ERC-7201 struct layout of the three UUPS contracts and diffs it against the baselines in `ci/storage-layouts/`. Blocking | The GYL-1208 bug class: a namespaced storage field that moves, resizes, reorders or disappears between implementations, which silently re-points storage on an already-deployed proxy. Both known instances (`GyldAtomicSwap.maxQuoteTtl` reading 0 on an upgraded proxy; `GyldBondToken`'s removed ERC-8056 extension leaving live bytes at B+3..B+5) were caught by a human reading the diff — and NEITHER reached `main`. This check does not replace that review; it **forces** it, by turning a subtle Solidity diff into an explicit `ci/storage-layouts/` diff a reviewer cannot skim past, and giving an auditor a concrete artifact to read before an upgrade. The audit remains the thing that decides whether a layout change is safe. See "Storage layout" below |

## Why full fuzz intensity on every run

Measured on a cold build (Apple Silicon, forge 1.5.1): `via_ir` compile 35 s,
full-intensity `forge test` **16 s** wall (48 s CPU). Even at the usual 2–3×
slowdown of a GitHub-hosted runner plus recursive submodule checkout, the whole
job lands well under ~5 minutes cold and less warm (build artifacts are
cached). Reducing fuzz runs would save seconds and cost coverage, so nothing is
dialled down and there is no separate nightly: every run gets the same
scrutiny. If suite runtime ever grows past ~10 minutes, split intensity then —
reduced per-run via `FOUNDRY_FUZZ_RUNS` / `FOUNDRY_INVARIANT_RUNS` env
overrides, full on a schedule.

## Storage layout

**Scope, stated up front.** This check is a review aid, not a safety proof. The
audit before an upgrade is what decides whether a layout change is safe; all this
does is make the change impossible to miss. In this repo's history four layout
changes have landed and human review caught all four, with none reaching `main` —
so the check is not compensating for a broken review process. It exists because
that review depended on someone choosing to look closely, and the two bugs below
were both found by an unusually deep read rather than by routine review.

Most comparable projects do not gate on this (Aave, Morpho, Euler, Lido, Ondo,
Centrifuge all have no such check). Those that do split into three shapes: in the
test suite (Safe, Superstate), a dedicated CI job (Optimism, EtherFi), or
developer-run and committed as a review artifact rather than gating — which is what
BGD Labs, who author Aave's actual upgrade payloads, chose. We sit closest to the
first: the check runs as a step inside `test`, and the Solidity pins in
`GyldAtomicSwap.spec.t.sol` and `GyldBondToken.t.sol` are the primary net. The
script's distinct contribution is that it is **exhaustive by construction** — solc
enumerates every field, whereas a hand-written pin only covers what someone
remembered to write.


`GyldAtomicSwap`, `GyldBondToken` and `IssuanceManager` are UUPS proxies whose
state lives in an ERC-7201 namespaced struct at a computed base slot. On upgrade
the proxy keeps the old storage and runs the new code, so the new struct has to
describe the same bytes at the same offsets the old one did. Neither `solc`,
`forge build` nor `forge test` checks that — and both known violations were
found by a human reading a diff:

- **`GyldAtomicSwap.maxQuoteTtl`** — appended, then seeded only in
  `initialize()`. An already-deployed proxy never re-runs `initialize()`, so it
  read 0 from the fresh slot and `executeSwap` rejected every quote. Fixed by
  reading through `_effectiveMaxQuoteTtl()`, which treats 0 as "unset".
- **`GyldBondToken`** — a removed ERC-8056 extension left non-zero values at
  offsets B+3..B+5 on two orphaned testnet proxies. Removing a field does not
  clear its slot; it just stops anything from naming it.

`ci/storage-layouts/<Contract>.json` pins, per contract: the ERC-7201 namespace,
the `_STORAGE_LOCATION` base slot, the struct name, and every field's name,
slot-relative-to-base, byte offset, width and type. The checker regenerates all
of it and fails on any difference, naming the field and the old → new
slot/offset/type. It classifies each drift as **append-only** (new fields
strictly after every untouched old one) or **BREAKING** (anything else), and the
failure text differs accordingly.

### How the layout is obtained

`forge inspect GyldAtomicSwap storageLayout` returns `{"storage": [], "types":
{}}`, and that is correct rather than the usual `via_ir` breakage: ERC-7201
state is not a declared state variable, so the contract genuinely has no layout
to report. The struct only acquires one when something declares it as a
variable, so the checker writes a throwaway probe —

```solidity
contract Probe_GyldAtomicSwap { GyldAtomicSwap.GyldAtomicSwapStorage internal s; }
```

— into a temp directory and inspects *that*. The probe run is hermetic (its own
`src`, `out` and `cache`), which keeps your `out/` untouched, avoids the real
`via_ir` failure mode here (`forge inspect` against a warm `out/` built without
the `storageLayout` output selector dies with "storage layout missing from
artifact"), and means only the three contracts plus imports compile: **~2 s
cold**, so the job needs no build cache.

Snapshots drop solc's `astId` and `contract` keys and resolve type ids to their
human labels (`uint64`, `mapping(address => bool)`, `contract ISanctionsList`).
Both the ids and the astIds shift whenever unrelated code above them changes; a
raw snapshot would churn on every edit and train people to run `--write`
reflexively, which is the one failure mode that would make this job worthless.

### Updating a baseline

```bash
python3 ci/check_storage_layout.py --write   # then read `git diff` and commit
```

Legitimate appends will happen, so this has to be easy. It should not be
thoughtless: **for a contract that is already deployed, updating a baseline is a
migration decision, not a formality.** The baseline only records what the code
says; the proxies keep their old bytes regardless. Know which proxies exist
(`DEPLOYMENTS.md`), what sits in the affected slots, and how they reach the new
shape — and say so in the commit message. Note that an append is *also* not free:
the new field reads zero on every pre-existing proxy, which is precisely the
`maxQuoteTtl` bug, so either fall back on zero in the getter or add a
reinitializer and actually run it.

### What it does not catch

- **Inherited (non-namespaced) storage.** Only the ERC-7201 struct is pinned.
  If an OpenZeppelin base contract's own layout changed under a submodule bump,
  this job is silent. The three contracts declare no slot-0 state of their own,
  so there is nothing else local to pin.
- **Changes inside a struct reached only through a mapping or array.** The
  recursion follows nested struct *members*, but a struct used as a mapping
  value or array element is pinned by its label and width only, so reordering
  *its* fields would pass. **This is live, not hypothetical:**
  `GyldBondTokenStorage.documents` is a `mapping(bytes32 => IERC1643.Document)`,
  and the type label is byte-identical however `Document`'s three members
  (`uri`, `documentHash`, `lastModified`) are ordered — so a reorder passes this
  check while silently re-pointing every document already stored on a live
  proxy, and `getDocument` starts returning a block timestamp as the document
  hash. Mitigated in Solidity, not here: `c1f240f` added member-offset pins to
  `test_storageLayout_documentFieldsAppendedAtOffsets3and4` in
  `GyldBondToken.t.sol`, which reads raw storage after a real `setDocument` and
  asserts members 1 and 2 individually. That test is the only thing catching a
  `Document` reorder — do not delete it, and extend it if `Document` gains a
  field.
- **Whether the deployed implementation matches this source.** The baseline is a
  property of the tree, not of any chain. It cannot tell you that a live proxy's
  storage actually has the shape recorded here — only that the shape has not
  changed since the last deliberate `--write`.
- **Semantic reuse of a slot.** Renaming `foo` to `bar` at the same slot, width
  and type reads as REMOVED + INSERTED and fails loudly, which is right. But
  repurposing a field's *meaning* while keeping name and type is invisible.

## Coverage

**Local-only — there is no coverage job in CI.** The numbers below were measured
by hand with the command in "Reproducing a failure locally"; they are a
point-in-time reading kept for what they taught us, not something any job
recomputes or gates on.

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
it is dominated by broadcast-only scripts such as `AtomicSettlementFlow` that
have no test harness, so it measures how many deploy scripts have tests, not
how well the contracts are tested.

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
     `_getStorage()` (`GyldAtomicSwap:277`, `GyldBondToken:88`,
     `IssuanceManager:60`) and the `create2` in `TokenFactory:175` reads as
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

- **`GyldAtomicSwap.sol:397`** — `initialize()`'s cash-token `decimals()` probe
  failure branch (`!usdcOk || usdcData.length != 32`). Its wrong-decimals
  sibling on line 398 *is* covered, and the analogous guard on
  `registerSeries` is covered for both the wrong-decimals and the
  no-`decimals()`-at-all cases. The initializer's "cash token has no `decimals()`"
  case is now covered too, by `test_initialize_cashTokenWithoutDecimals_reverts` —
  worth having because `usdc` has no setter, so a bad cash token bricks the proxy
  permanently rather than failing loud on one series.
- **`GyldBondToken.sol:218`** — `mint(to, 0)` → `ZeroAmount`. `burn(x, 0)` and
  `mint(address(0), …)` are both tested; this one is a symmetry gap.

**The reassuring part:** `executeSwap` (lines 497-568) and `_checkQuoteBand`
(599-628) — the value-moving hot path — contain **zero** uncovered lines and
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
python3 ci/check_storage_layout.py   # ERC-7201 layout diff; exit 1 on drift, 2 on tooling failure

# Coverage. Local only — no CI job runs this. --ir-minimum is mandatory (via_ir
# breaks instrumentation); without it forge emits no table at all. The env
# overrides are free: they produce a byte-identical table (1053/1618 lines) in
# 1.4 s of test time instead of 44 s, because coverage only asks whether a line
# was ever reached. Drop them if you want to confirm that for yourself.
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
  restrictable to `view` at `contracts/test/GyldAtomicSwap.halmos.t.sol:235` and
  to `pure` at `contracts/test/GyldAtomicSwap.spec.t.sol:608`) plus ~45
  `forge lint` notes
  (`erc20-unchecked-transfer`, `unsafe-typecast`). Same rule: fix first, then
  enforce, otherwise the job starts red.
- **`openzeppelin-foundry-upgrades` (`Upgrades.validateUpgrade`)** — considered
  instead of `storage-layout`, rejected. It is a new submodule plus an npm
  dependency (`@openzeppelin/upgrades-core`) reached through `ffi = true`, and
  this workflow's whole claim is that it cannot touch the outside world; turning
  on `ffi` to get a layout diff trades that away for something one Python script
  and a checked-in JSON already do. It also wants a "before" *contract* to
  compare against, which means keeping old implementations in the tree, whereas
  a baseline file compares against the last deliberate decision. Revisit if we
  ever need its other checks (constructor/`selfdestruct`/`delegatecall`
  validation), and if so put it behind its own workflow.
- **A checked-in probe contract under `contracts/`** — the probe has to exist for
  solc to emit an ERC-7201 struct's layout at all, but a permanent one would be
  compiled by every `forge build` and every `forge test`, and would show up in
  coverage tables, for the benefit of one CI script. It is generated into a temp
  directory instead and deleted in a `finally`.
- **Gas snapshots** — no `.gas-snapshot` baseline exists, most hot paths are
  fuzz tests (nondeterministic gas), and `via_ir` makes diffs churn on
  unrelated edits. A snapshot job that flakes teaches people to ignore CI.
- **A coverage threshold / `--fail-under` gate** — rejected, and so, for now, is
  any `coverage` job at all: the measurement stays local. A minimum picked from
  the first-ever measurement is an arbitrary number that then gets defended as if
  it were a standard: it would either sit far enough below 95% to never fire, or
  be set at 95% and start blocking PRs over source-map artifacts (see
  "Coverage" — `IssuanceManager`'s 9% "gap" is entirely uninstrumented
  `assembly` and empty-bodied initialisers). Worse, the number describes
  `--ir-minimum` bytecode, so a gate would be enforcing a property of code that
  never ships. Watch the trend for a few months; if it justifies a floor, set
  the floor on `contracts/*.sol` only and on branches rather than lines.
- **A blocking `coverage` job** — rejected for now. It would be one optimiser
  configuration away from the `test` job, and the two failures that had to be
  fixed to make it run at all were both optimiser-sensitivity bugs. Until the
  suite has proven itself stable under both pipelines for a while, a red
  coverage run should be a signal to investigate, not a merge block. Note that
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
