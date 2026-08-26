#!/usr/bin/env python3
"""Fail CI on any Slither finding in a production contract that is not triaged.

Why a baseline rather than `slither --fail-high`:

  Slither reports ~1,950 results against this tree, of which ~48 touch
  `contracts/*.sol`; the rest are OpenZeppelin and forge-std under `lib/`.
  Nothing in the production set is a live defect (see docs/audit/known-issues.md
  for the finding-by-finding triage), but they are also not suppressible by
  severity: the set spans Informational to Medium, and the Medium ones are the
  *most* clearly false (five `incorrect-equality` hits on a `_updatedAt == 0`
  sentinel). A severity gate would either pass everything or block on all five.

  So the gate is: the set of (detector, file, element) fingerprints must not
  GROW. A new finding fails the build; an existing one does not. That satisfies
  the repo's bar in docs/ci.md -- start green, fail only for real defects.

TRAP (GYL audit): do NOT reach for `--filter-paths "lib/"`. Slither matches that
pattern against the ABSOLUTE path, so in any checkout whose own path contains a
`lib/` segment -- e.g. the vendored `kaleidoscope/lib/gyld-contracts` -- it
filters out the entire project and reports a confident "0 results found". This
script runs Slither unfiltered and filters afterwards on the repo-relative path,
which is correct in every checkout.

Regenerating the baseline is a deliberate act. If a change legitimately
introduces a new finding, triage it in docs/audit/known-issues.md FIRST, then
re-run with --write. Never regenerate to make a red build green.
"""

import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
BASELINE = ROOT / "ci" / "slither-baseline.json"

# A production contract: under contracts/, but not a test or a deploy script.
def _is_production(path: str) -> bool:
    return (
        path.startswith("contracts/")
        and not path.startswith("contracts/test")
        and not path.startswith("contracts/script")
    )


def _fingerprints(report: dict) -> set:
    """(detector, file, element) for every finding touching a production contract.

    Keyed on the element NAME rather than a line number on purpose: line numbers
    churn on every unrelated edit above the finding, which would make the
    baseline useless within a week.
    """
    found = set()
    for result in report.get("results", {}).get("detectors", []):
        paths = {
            e.get("source_mapping", {}).get("filename_relative", "")
            for e in result.get("elements", [])
        }
        if not any(_is_production(p) for p in paths if p):
            continue
        primary = (result.get("elements") or [{}])[0]
        found.add((
            result["check"],
            primary.get("source_mapping", {}).get("filename_relative", ""),
            primary.get("name", ""),
        ))
    return found


def _load_baseline() -> set:
    data = json.loads(BASELINE.read_text())
    return {(f["check"], f["file"], f["element"]) for f in data["findings"]}


def main() -> int:
    write = "--write" in sys.argv

    with tempfile.TemporaryDirectory() as tmp:
        out = pathlib.Path(tmp) / "slither.json"
        # Unfiltered on purpose -- see the TRAP note in this module's docstring.
        proc = subprocess.run(
            ["slither", ".", "--json", str(out)],
            cwd=ROOT, capture_output=True, text=True,
        )
        if not out.exists():
            print("FAIL: Slither produced no JSON report.", file=sys.stderr)
            print(proc.stderr[-4000:], file=sys.stderr)
            return 1
        report = json.loads(out.read_text())

    current = _fingerprints(report)

    if write:
        rows = [
            {"check": c, "file": f, "element": e}
            for c, f, e in sorted(current)
        ]
        payload = json.loads(BASELINE.read_text())
        payload["findings"] = rows
        BASELINE.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"Wrote {len(rows)} baseline entries to {BASELINE.relative_to(ROOT)}.")
        return 0

    baseline = _load_baseline()
    new = sorted(current - baseline)
    gone = sorted(baseline - current)

    if new:
        print(f"FAIL: {len(new)} Slither finding(s) in production contracts are not triaged.\n",
              file=sys.stderr)
        for check, path, element in new:
            print(f"  {check:<28} {path}:{element}", file=sys.stderr)
        print(
            "\nTriage each in docs/audit/known-issues.md, then re-run:\n"
            "  python3 ci/check_slither.py --write\n"
            "Do not regenerate the baseline to silence a finding.",
            file=sys.stderr,
        )
        return 1

    if gone:
        # Not a failure: deleting code should not be harder than adding it.
        print(f"NOTE: {len(gone)} baselined finding(s) no longer occur "
              f"(code was removed or fixed). Prune with --write when convenient:")
        for check, path, element in gone:
            print(f"  {check:<28} {path}:{element}")

    print(f"OK: {len(current)} Slither finding(s) in production contracts, all triaged "
          f"(docs/audit/known-issues.md).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
