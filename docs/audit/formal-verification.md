# Halmos symbolic verification

Four properties in [`contracts/test/GyldAtomicSwap.halmos.t.sol`](../../contracts/test/GyldAtomicSwap.halmos.t.sol)
are checked symbolically — over *all* inputs in the declared domain, not sampled
ones. `ci/check_halmos.py` holds each to the outcome recorded here, so this
document cannot drift from the build.

| | |
|---|---|
| Halmos | 0.3.3 |
| Solver | yices 2.6.5 (Halmos default) |
| `--solver-timeout-assertion` | **60 000 ms** — see *The zero-timeout trap* |
| Result | **3 proved, 1 timeout, 0 counterexamples** |
| Wall clock | ~63 s (three properties ≈ 0.4 s; the timeout burns the full 60 s) |

`forge test` **skips** these — the `check_` prefix is invisible to Foundry's
`test_` convention — so they run only under Halmos, and only in the `halmos` CI
job.

## Results

| Property | Invariant | Outcome | Paths | Time |
|---|---|---|---|---|
| `check_executeSwap_buy_conservationAndSolvency` | I-1/I-2 | **PASS** | 14 | 0.22 s |
| `check_executeSwap_outOfRangeDraw_alwaysReverts` | I-3 | **PASS** | 3 | 0.06 s |
| `check_executeSwap_replayedQuote_alwaysReverts` | I-10 | **PASS** | 7 | 0.13 s |
| `check_executeSwap_redeem_amountOutIsExactFloor` | I-11 | **TIMEOUT** | 23 | 61.04 s |

A **PASS** is a proof over the whole symbolic domain. A **TIMEOUT** is neither a
proof nor a refutation — the solver ran out of budget. It is emphatically *not* a
counterexample, and the distinction is the entire point of this document.

## Triage: the redeem timeout

`check_executeSwap_redeem_amountOutIsExactFloor` asserts that USDC paid out on a
REDEEM is exactly `floor(requestedAmountIn * price / 1e18)`, pinned twice — once
against the Solidity expression and once against the mathematical floor bounds
`paidOut * 1e18 <= product < (paidOut + 1) * 1e18`.

**Why it is hard.** `requestedAmountIn` is symbolic and `price` is a 256-bit
value; the assertion multiplies them and then divides. Symbolic
multiplication-then-division over 256-bit bitvectors is among the worst cases for
SMT — the solver cannot factor it and falls back to reasoning about the full
bit-level circuit. The other three properties are comparison- and
equality-shaped, which is why they discharge in milliseconds.

**It is a solver limit, not a budget shortfall.** Verified against three
independent solvers on the same query:

| Solver | Outcome | Budget |
|---|---|---|
| yices 2.6.5 (default) | TIMEOUT | 60 s |
| z3 | TIMEOUT | 180 s |
| cvc5 | TIMEOUT | 180 s |

Three engines with different decision procedures all give up. Raising the budget
is not the missing ingredient — an earlier 300 s attempt on the default solver
also produced no additional progress. (bitwuzla could not be evaluated: its
fetched binary errors on this platform.)

**What covers it instead.** The concrete expression the property restates is
pinned by fuzz, at `foundry.toml`'s `runs = 10000`:

- `testFuzz_executeSwap_redeem_conservesBothPools`
  (`GyldAtomicSwap.spec.t.sol`) — computes `expectedOut = (requestedAmountIn *
  price) / 1e18` and asserts USDC moves by exactly that on **both** sides of the
  trade, plus that `usdc.totalSupply()` is unchanged.
- `testFuzz_executeSwap_buy_amountOut_matchesPriceRoundedDown`
  (`GyldAtomicSwap.invariants.t.sol`) — the same rounding property on the BUY
  leg, which *does* prove symbolically via
  `check_executeSwap_buy_conservationAndSolvency`.

**The residual gap, stated precisely.** Fuzz pins that the implementation matches
the Solidity expression `(amountIn * price) / 1e18`. What remains unproved is the
*independent* restatement — the floor bounds — which would catch the expression
itself being the wrong formula, on sampled inputs only rather than all of them.
Given the BUY leg proves symbolically and both legs share the rounding helper,
the unproved surface is narrow. It is not zero, and it should be named as such to
an auditor rather than rounded down to "3 of 4 passed".

**Do not** make this property prove by weakening it — narrowing the input bound
or dropping the mathematical restatement would turn a known gap into a hidden
one. The recorded TIMEOUT is more honest than a green tick bought that way.

## The zero-timeout trap

**Do not run with `--solver-timeout-assertion 0`.**

Zero means *no timeout*. On the redeem property the solver then runs
indefinitely: no result, no counterexample, no progress indication — a hung CI
job that looks like a slow one. `ci/check_halmos.py` hard-codes 60 000 ms and
should keep doing so.

## What CI enforces

`ci/check_halmos.py` compares each property against `EXPECTED` and fails on any
divergence:

- a **PASS** that regresses to TIMEOUT — someone made a proved property
  materially harder to reason about;
- the **TIMEOUT** turning into a counterexample — the property is genuinely
  violated, and that is the loudest signal in this repo;
- the **TIMEOUT** starting to PASS — good news, and the job says to promote it
  here rather than silently absorbing it;
- a property renamed, removed, or added without being recorded.

A plain `halmos` invocation could not do this: Halmos exits non-zero whenever
anything fails to prove, timeouts included, so the job would be permanently red
and ignored within a week — precisely the bar [`docs/ci.md`](../ci.md) sets
against.

## Reproducing

```bash
python3 -m venv .venv && ./.venv/bin/pip install halmos==0.3.3
PATH="$PWD/.venv/bin:$PATH" python3 ci/check_halmos.py
```

Or drive Halmos directly:

```bash
halmos --contract GyldAtomicSwapHalmosTest --solver-timeout-assertion 60000
```

Expect exit code **1** from the bare command — the timeout counts as a failure to
Halmos. That is why the checker exists.
