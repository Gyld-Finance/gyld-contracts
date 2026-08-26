#!/usr/bin/env python3
"""Run the Halmos symbolic properties and hold each to its RECORDED outcome.

Three of the four properties in contracts/test/GyldAtomicSwap.halmos.t.sol prove
in under a second. The fourth -- check_executeSwap_redeem_amountOutIsExactFloor
-- does not prove; the solver gives up. See docs/audit/formal-verification.md for
why that is a solver limit and not a defect.

That makes `halmos && echo ok` unusable as a gate: Halmos exits 1 whenever
anything fails to prove, timeouts included, so a plain invocation is permanently
red and would be ignored within a week -- exactly the failure mode docs/ci.md
warns about.

So the gate is per-property, against EXPECTED below:

  PASS    -> must still prove. A regression to TIMEOUT is a failure: it means
             someone made the property materially harder to reason about.
  TIMEOUT -> must still time out, and must NOT become a counterexample. If the
             solver ever finds one, the property is genuinely violated and this
             fails loudly.

A TIMEOUT that starts PASSing also fails, with an instruction to promote it.
That is deliberate: an unproved property quietly becoming proved is good news
this file should record, not absorb.
"""

import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Bound assertion solving. 0 means "no timeout", which on the redeem property
# hangs forever rather than reporting anything (GYL audit trap). 60s is enough
# for every property that can prove -- the three provable ones finish in <1s --
# and is the point past which more budget demonstrably buys nothing: yices gives
# up at 60s, z3 at 182s and cvc5 at 193s on the same query.
SOLVER_TIMEOUT_MS = 60_000

EXPECTED = {
    "check_executeSwap_buy_conservationAndSolvency":  "PASS",
    "check_executeSwap_outOfRangeDraw_alwaysReverts": "PASS",
    "check_executeSwap_replayedQuote_alwaysReverts":  "PASS",
    # Not proved. Solver-hard, cross-checked against three solvers. The concrete
    # expression it restates is pinned by 10,000-run fuzz in
    # testFuzz_executeSwap_redeem_conservesBothPools.
    "check_executeSwap_redeem_amountOutIsExactFloor": "TIMEOUT",
}

ANSI = re.compile(r"\x1b\[[0-9;]*m")
RESULT = re.compile(r"\[(PASS|FAIL|TIMEOUT|ERROR)\]\s+(check_\w+)")


def main() -> int:
    proc = subprocess.run(
        [
            "halmos",
            "--contract", "GyldAtomicSwapHalmosTest",
            "--solver-timeout-assertion", str(SOLVER_TIMEOUT_MS),
        ],
        cwd=ROOT, capture_output=True, text=True,
    )
    output = ANSI.sub("", proc.stdout + proc.stderr)

    actual = {name: status for status, name in RESULT.findall(output)}

    if not actual:
        print("FAIL: Halmos reported no property results at all.", file=sys.stderr)
        print(output[-4000:], file=sys.stderr)
        return 1

    failures = []

    for name, want in EXPECTED.items():
        got = actual.get(name)
        if got is None:
            failures.append(f"{name}: expected {want}, but Halmos did not report it "
                            f"(was it renamed or removed?)")
        elif got == want:
            continue
        elif want == "TIMEOUT" and got in ("FAIL", "ERROR"):
            failures.append(
                f"{name}: expected TIMEOUT, got {got}. A counterexample here means the "
                f"property is genuinely VIOLATED -- read the trace before anything else."
            )
        elif want == "TIMEOUT" and got == "PASS":
            failures.append(
                f"{name}: expected TIMEOUT but it PROVED. Good news. Promote it to PASS "
                f"in ci/check_halmos.py and update docs/audit/formal-verification.md."
            )
        else:
            failures.append(f"{name}: expected {want}, got {got}.")

    unexpected = sorted(set(actual) - set(EXPECTED))
    if unexpected:
        failures.append(
            "New propert(ies) not recorded in EXPECTED: " + ", ".join(unexpected) +
            ". Add them with their outcome and describe them in "
            "docs/audit/formal-verification.md."
        )

    if failures:
        print("FAIL: Halmos outcomes differ from the recorded baseline.\n", file=sys.stderr)
        for f in failures:
            print(f"  - {f}", file=sys.stderr)
        return 1

    proved = sum(1 for v in EXPECTED.values() if v == "PASS")
    print(f"OK: {proved}/{len(EXPECTED)} Halmos properties proved; "
          f"{len(EXPECTED) - proved} timed out as recorded "
          f"(docs/audit/formal-verification.md).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
