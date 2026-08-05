#!/usr/bin/env python3
"""Fail if the ERC-7201 storage layout of an upgradeable contract has drifted.

Why this exists (GYL-1208)
--------------------------
The three UUPS contracts (GyldAtomicSwap, GyldBondToken, IssuanceManager) keep
their state in an ERC-7201 namespaced struct read through an `assembly { $.slot
:= _STORAGE_LOCATION }`. A proxy that is upgraded keeps the *old* storage and
runs the *new* code, so the new struct must describe the same bytes at the same
offsets as the old one did. Nothing in solc, forge build, or forge test checks
that. Two layout bugs have reached a feature branch here — NEITHER reached
`main`, and a human reading the diff caught both. This job exists so the next
one does not depend on someone happening to look:

  - `GyldAtomicSwap.maxQuoteTtl` — a field APPENDED to the struct and seeded
    only in `initialize()`. An already-deployed proxy never re-runs
    `initialize()`, so it read 0 from the fresh slot and `executeSwap` rejected
    every quote. Fixed by reading through `_effectiveMaxQuoteTtl()`, which
    treats zero as "unset" and falls back to a compiled-in default.
  - `GyldBondToken` — a removed ERC-8056 extension left non-zero bytes at
    ERC-7201 offsets B+3..B+5 on two orphaned testnet proxies. Removing a field
    does not clear the slot; it just stops anything from naming it.

This check snapshots each struct's layout into ci/storage-layouts/ and fails if
the regenerated layout does not match, byte for byte. It catches a field
inserted before an existing one, a field's type or width changing, fields
reordered, a field removed, and the ERC-7201 base slot itself moving.

How the layout is obtained
--------------------------
`forge inspect GyldAtomicSwap storageLayout` reports `{"storage": [],
"types": {}}` for all three contracts, and that is correct, not a bug: ERC-7201
state is not a declared state variable, so it has no layout to report. The
struct only gets a layout when something declares it as a variable. So this
script writes a throwaway probe contract

    contract Probe_GyldAtomicSwap { GyldAtomicSwap.GyldAtomicSwapStorage s; }

into a temp directory, inspects *that*, and reads the struct out of the `types`
table. Field slots are therefore relative to the struct's own base, which is
exactly what we want to pin: absolute slots are `_STORAGE_LOCATION + n`, and
`_STORAGE_LOCATION` is snapshotted separately.

The probe run is hermetic — its own src, out and cache directories, all inside
the temp dir — for three reasons. It never touches your `out/`; it cannot be
poisoned by a stale artifact (`forge inspect` on a warm `out/` built without the
storageLayout output selector fails with "storage layout missing from artifact",
which is the `via_ir` tooling breakage this repo has hit before); and pointing
`src` at the probe directory means only the three contracts and their imports
compile, so a cold run is ~2 s rather than a full `via_ir` build.

Usage: python3 ci/check_storage_layout.py [--write]
       --write rewrites the baselines instead of comparing. See the failure
       message for when that is and is not the right move.
Exit codes: 0 = layouts match, 1 = drift or missing baseline, 2 = tooling failure.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

USAGE = "Usage: python3 ci/check_storage_layout.py [--write]"

CONTRACT_DIR = Path("contracts")
BASELINE_DIR = Path("ci/storage-layouts")


def discover_contracts():
    """Every contract that is BOTH upgradeable and ERC-7201 namespaced.

    Deliberately not a hardcoded list. A hardcoded list means a newly added
    upgradeable contract is simply invisible and the job still prints OK, and
    silent under-coverage is the worst property a guard can have. The next
    upgradeable contract should be picked up without anyone remembering to edit
    this file.
    """
    found = []
    for path in sorted(CONTRACT_DIR.glob("*.sol")):
        text = path.read_text()
        if "UUPSUpgradeable" in text and "@custom:storage-location erc7201:" in text:
            found.append(path.stem)
    return found

# `/// @custom:storage-location erc7201:gyld.GyldAtomicSwap` followed by the
# struct it annotates.
NAMESPACE_RE = re.compile(
    r"@custom:storage-location\s+erc7201:(?P<ns>[\w.$-]+)"
    r".*?\bstruct\s+(?P<struct>\w+)\s*\{",
    re.DOTALL,
)

# `bytes32 private constant _STORAGE_LOCATION = 0x...;` — the value may sit on
# the following line, hence \s*.
SLOT_RE = re.compile(r"_STORAGE_LOCATION\s*=\s*(0x[0-9a-fA-F]{64})")

PROBE_SOL = """// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

{imports}

{probes}
"""


def parse_source(name: str) -> dict:
    """Pull namespace, struct name and base slot out of the contract source.

    These three live in `constant`s and comments, so no compiler output
    mentions them; a regex over the source is the only way to see them, and
    also the only way to notice the base slot moving.
    """
    path = CONTRACT_DIR / f"{name}.sol"
    src = path.read_text(encoding="utf-8")

    ns = NAMESPACE_RE.search(src)
    if not ns:
        raise LookupError(
            f"{path}: no `@custom:storage-location erc7201:<id>` immediately "
            f"followed by a `struct` declaration. If this contract stopped "
            f"using ERC-7201 namespaced storage, it will drop out of "
            f"discover_contracts() — delete its baseline too, deliberately."
        )

    slot = SLOT_RE.search(src)
    if not slot:
        raise LookupError(f"{path}: no `_STORAGE_LOCATION = 0x<64 hex>` found.")

    return {
        "contract": name,
        "source": path.as_posix(),
        "namespace": ns.group("ns"),
        "struct": ns.group("struct"),
        "baseSlot": slot.group(1).lower(),
    }


def flatten(types: dict, type_id: str, prefix: str = "", slot_base: int = 0) -> list:
    """Flatten a struct's members into leaf fields, recursing through nested structs.

    Drops solc's `astId` and `contract` keys and resolves each type id to its
    human label: both the ids and the astIds shift when unrelated code above
    them changes, so a raw snapshot would churn on every edit and teach people
    to run --write reflexively. `uint64` / `mapping(address => bool)` /
    `contract ISanctionsList` do not move.
    """
    out = []
    for member in types[type_id].get("members", []):
        t = types[member["type"]]
        name = prefix + member["label"]
        slot = slot_base + int(member["slot"])
        if "members" in t:
            out.extend(flatten(types, member["type"], name + ".", slot))
        else:
            out.append(
                {
                    "name": name,
                    "slot": slot,
                    "offset": int(member["offset"]),
                    "bytes": int(t["numberOfBytes"]),
                    "type": t["label"],
                }
            )
    return out


def inspect_layouts(meta: dict, workdir: Path) -> dict:
    """Compile one probe contract per struct and return {contract: [fields]}."""
    src_dir = workdir / "probe"
    src_dir.mkdir()

    names = sorted(meta)
    imports = "\n".join(
        f'import {{{n}}} from "../../contracts/{n}.sol";' for n in names
    )
    probes = "\n".join(
        f"contract Probe_{n} {{ {n}.{meta[n]['struct']} internal s; }}"
        for n in names
    )
    probe_file = src_dir / "StorageLayoutProbe.sol"
    probe_file.write_text(PROBE_SOL.format(imports=imports, probes=probes))

    env_overrides = {
        "FOUNDRY_SRC": str(src_dir),
        "FOUNDRY_OUT": str(workdir / "out"),
        "FOUNDRY_CACHE_PATH": str(workdir / "cache"),
    }

    layouts = {}
    for name in discover_contracts():
        target = f"{probe_file}:Probe_{name}"
        proc = subprocess.run(
            ["forge", "inspect", target, "storageLayout", "--json"],
            capture_output=True,
            text=True,
            env={**os.environ, **env_overrides},
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"forge inspect failed for {name}:\n{proc.stderr.strip()}"
            )
        types = json.loads(proc.stdout)["types"]
        # solc's type ids embed an astId that shifts on unrelated edits, so find
        # the struct by its stable qualified label instead.
        wanted = f"struct {name}.{meta[name]['struct']}"
        top = next(k for k, v in types.items() if v["label"] == wanted)
        layouts[name] = flatten(types, top)
    return layouts


def build_snapshot(meta: dict, fields: list) -> dict:
    return {**meta, "fields": fields}


def dump(snapshot: dict) -> str:
    """Stable, diff-friendly JSON: sorted keys, 2-space indent, trailing newline."""
    return json.dumps(snapshot, indent=2, sort_keys=True) + "\n"


def describe(old: dict, new: dict) -> tuple:
    """Return (lines, breaking) describing how `new` differs from `old`.

    `breaking` is False only for the one benign shape: fields appended at the
    end with every pre-existing field untouched.
    """
    lines = []
    breaking = False

    for key, label in (
        ("baseSlot", "ERC-7201 BASE SLOT"),
        ("namespace", "ERC-7201 NAMESPACE"),
        ("struct", "STRUCT NAME"),
    ):
        if old.get(key) != new.get(key):
            breaking = True
            lines.append(f"  {label} changed: {old.get(key)}  ->  {new.get(key)}")

    old_f = {f["name"]: f for f in old["fields"]}
    new_f = {f["name"]: f for f in new["fields"]}
    old_order = [f["name"] for f in old["fields"]]
    new_order = [f["name"] for f in new["fields"]]

    added = [f for f in new["fields"] if f["name"] not in old_f]
    removed = [(i, f) for i, f in enumerate(old["fields"]) if f["name"] not in new_f]
    moved, retyped = [], []
    for f in old["fields"]:
        g = new_f.get(f["name"])
        if g is None:
            continue
        if (f["slot"], f["offset"]) != (g["slot"], g["offset"]):
            moved.append((f, g))
        if (f["type"], f["bytes"]) != (g["type"], g["bytes"]):
            retyped.append((f, g))

    # Surviving fields must stay in the same relative order.
    reordered = [n for n in new_order if n in old_f] != [
        n for n in old_order if n in new_f
    ]
    # The one benign shape: every old field still there, in place, and the new
    # ones sitting strictly after them.
    appended_at_tail = new_order[: len(old_order)] == old_order

    breaking |= bool(removed or moved or retyped or reordered)
    breaking |= bool(added) and not appended_at_tail

    # Additions first: on a real diff they are what the author just wrote, and
    # the MOVED cascade below is the consequence they did not intend.
    for f in added:
        verb = "APPENDED " if appended_at_tail else "INSERTED "
        i = new_order.index(f["name"])
        lines.append(
            f"  {verb} field #{i} `{f['name']}` ({f['type']}, {f['bytes']}B) "
            f"at B+{f['slot']} offset {f['offset']}"
        )

    for i, f in removed:
        lines.append(
            f"  REMOVED   field #{i} `{f['name']}` ({f['type']}) was at "
            f"B+{f['slot']} offset {f['offset']}"
        )
        lines.append(
            "            A removed field does NOT clear its slot. Live proxies "
            "keep the old bytes"
        )
        lines.append(
            "            there forever, and whatever lands on that slot next "
            "inherits them."
        )

    for f, g in moved:
        lines.append(
            f"  MOVED     field `{g['name']}` ({g['type']}): "
            f"B+{f['slot']} offset {f['offset']}  ->  "
            f"B+{g['slot']} offset {g['offset']}"
        )

    for f, g in retyped:
        lines.append(
            f"  RETYPED   field `{g['name']}` at B+{g['slot']} offset {g['offset']}: "
            f"{f['type']} ({f['bytes']}B)  ->  {g['type']} ({g['bytes']}B)"
        )

    if reordered:
        lines.append(f"  REORDERED fields: {old_order}  ->  {new_order}")

    return lines, breaking


# Slots that are NOT zero on already-deployed proxies, so the "appended fields
# read zero" advice below is FALSE for them. Observed on-chain 2026-08-05: the
# removed ERC-8056 extension left these behind on the 46050ea lineage. Fresh
# proxies are clean, which is why this is a per-contract exception and not a
# general rule.
DIRTY_SLOTS = {
    "GyldBondToken": {
        3: "1.05e18 (orphaned uiMultiplier)",
        4: "1.04e18 (orphaned newUIMultiplier)",
        5: "1785487668 (orphaned uiMultiplierEffectiveAt)",
    }
}

DIRTY_PROXIES = {
    "GyldBondToken": (
        "Sepolia GTB8056  0xE1C0a83Ab03e4498Fad1f833fA484E2cfc68dE7b\n"
        "    BSC testnet GBSCD 0x7D7B5bE30bfe7A1941c60247b4D5A28ab266305a"
    )
}


def dirty_slot_note(contract, appended):
    """Override APPEND_NOTE when a new field lands on a known-dirty slot.

    APPEND_NOTE's advice — treat zero as unset and fall back — is correct for a
    slot that is genuinely fresh, and WRONG here: these slots already hold
    non-zero bytes, so a zero-sentinel never fires and the field silently
    inherits the old value. This is the one case where the generic note would
    actively mislead.
    """
    dirty = DIRTY_SLOTS.get(contract)
    if not dirty:
        return None
    hits = [(f["name"], f["slot"], dirty[f["slot"]]) for f in appended if f["slot"] in dirty]
    if not hits:
        return None
    body = "\n".join(f"    B+{slot} already holds {val}  (field `{name}`)" for name, slot, val in hits)
    return (
        "STOP — this append lands on a slot that is NOT ZERO on deployed proxies.\n"
        + body
        + "\n\nA zero-sentinel fallback DOES NOT HELP here. The slot never reads zero,"
        "\nso the fallback never fires and your new field silently inherits the old"
        "\nERC-8056 value. Affected proxies (both marked do-not-reuse in DEPLOYMENTS.md):"
        f"\n    {DIRTY_PROXIES[contract]}"
        "\n\nFresh deploys are clean and unaffected. If those two proxies will never be"
        "\nupgraded, this append is safe — say so in the commit message. If either"
        "\nmight be, use a reinitializer that explicitly zeroes the slot first."
    )


APPEND_NOTE = (
    "Appends are the legitimate case, and they are still not free. A field"
    "\nappended to the struct reads ZERO on every proxy that was deployed before"
    "\nit existed, because `initialize()` does not re-run on upgrade. This is"
    "\nexactly the GyldAtomicSwap.maxQuoteTtl bug: it was seeded only in"
    "\n`initialize`, so an upgraded proxy read 0 and executeSwap rejected every"
    "\nquote. Either treat zero as \"unset\" and fall back in the getter (see"
    "\n`_effectiveMaxQuoteTtl`), or add a reinitializer and actually run it."
)

BREAKING_NOTE = (
    "This is NOT an append. A field that moved, changed width, changed order or"
    "\nwas removed re-points live storage: the new code reads bytes that the old"
    "\ncode wrote for a different field. On a deployed proxy that is silent data"
    "\ncorruption, not a revert — GyldBondToken's removed ERC-8056 extension left"
    "\nnon-zero values sitting at B+3..B+5 on two testnet proxies, and only a"
    "\nhuman reading the diff noticed."
    "\n"
    "\nERC-7201 structs are APPEND-ONLY. New fields go at the end; never insert,"
    "\nreorder, resize or delete above them. If a field is genuinely dead, leave"
    "\nit in place renamed to `__deprecated_<name>` so the slot stays reserved."
)

UPDATE_NOTE = (
    "If the change is intended:"
    "\n  python3 ci/check_storage_layout.py --write   # then commit the baseline"
    "\n"
    "\nUpdating a baseline for a contract that is ALREADY DEPLOYED is a migration"
    "\ndecision, not a formality. The baseline is only a record of what the code"
    "\nsays; the proxies keep the old bytes regardless. Before you --write, know"
    "\nwhich proxies exist (DEPLOYMENTS.md), what is in the affected slots, and"
    "\nhow they get to the new shape. Say so in the commit message."
)


def main() -> int:
    argv = sys.argv[1:]
    write = "--write" in argv
    unknown = [a for a in argv if a != "--write"]
    if unknown:
        print(f"error: unrecognised argument(s): {' '.join(unknown)}", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        return 2

    if shutil.which("forge") is None:
        print("error: `forge` not on PATH — this check needs Foundry.", file=sys.stderr)
        return 2

    # The probe is compiled by `forge` in the cwd, so cwd must be the Foundry
    # project. Same convention as ci/check_chain_guards.py.
    if not Path("foundry.toml").is_file() or not CONTRACT_DIR.is_dir():
        print("error: run this from the repo root (no foundry.toml here).", file=sys.stderr)
        print(USAGE, file=sys.stderr)
        return 2

    try:
        meta = {name: parse_source(name) for name in discover_contracts()}
    except (OSError, LookupError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    # Inside the repo root, because FOUNDRY_SRC and the probe's relative
    # imports both have to stay within the Foundry project.
    workdir = Path(tempfile.mkdtemp(dir=".", prefix=".storage-layout-probe-"))
    try:
        layouts = inspect_layouts(meta, workdir)
    except (RuntimeError, KeyError, StopIteration, json.JSONDecodeError) as exc:
        print(f"error: could not read storage layouts: {exc}", file=sys.stderr)
        return 2
    finally:
        shutil.rmtree(workdir, ignore_errors=True)

    if write:
        BASELINE_DIR.mkdir(parents=True, exist_ok=True)
        for name in discover_contracts():
            snap = build_snapshot(meta[name], layouts[name])
            (BASELINE_DIR / f"{name}.json").write_text(dump(snap), encoding="utf-8")
            print(f"wrote {BASELINE_DIR / f'{name}.json'} ({len(snap['fields'])} fields)")
        print(
            "\nBaselines rewritten. `git diff ci/storage-layouts/` and read it before"
            "\ncommitting: for an already-deployed contract this diff is a migration"
            "\ndecision, not a formality."
        )
        return 0

    drifted = []
    missing = []
    dirty_notes = []
    any_breaking = False
    any_append = False

    for name in discover_contracts():
        baseline_path = BASELINE_DIR / f"{name}.json"
        new = build_snapshot(meta[name], layouts[name])
        if not baseline_path.is_file():
            missing.append(baseline_path)
            continue
        old = json.loads(baseline_path.read_text(encoding="utf-8"))
        if dump(old) == dump(new):
            continue
        lines, breaking = describe(old, new)
        if not lines:
            # Same layout, different serialisation (e.g. a key added to the
            # snapshot format). Still a mismatch, still needs --write.
            lines = ["  snapshot format differs but no field-level change was found"]
        any_breaking |= breaking
        any_append |= not breaking
        old_names = {f["name"] for f in old["fields"]}
        appended = [f for f in new["fields"] if f["name"] not in old_names]
        dirty_note = dirty_slot_note(name, appended)
        if dirty_note:
            dirty_notes.append(dirty_note)
        drifted.append((name, new, lines, breaking))

    if missing:
        print("FAIL: no storage-layout baseline for:\n")
        for p in missing:
            print(f"  {p}")
        print(
            "\nEvery UUPS-upgradeable contract needs a checked-in layout baseline, or"
            "\nthis check silently protects nothing. Generate them with:"
            "\n  python3 ci/check_storage_layout.py --write"
        )
        print()

    for name, new, lines, breaking in drifted:
        verdict = "BREAKING" if breaking else "append-only"
        print(f"FAIL: ERC-7201 storage layout drift in {name} ({verdict}).\n")
        print(f"  {new['source']}  struct {new['struct']}")
        print(f"  namespace  erc7201:{new['namespace']}")
        print(f"  base slot  {new['baseSlot']}   (= B below; a field's real slot is B+n)")
        print()
        for line in lines:
            print(line)
        print()

    for note in dirty_notes:
        print(note)
        print()

    for note, fires in (
        (BREAKING_NOTE, any_breaking),
        # Suppressed when a dirty-slot note fired: APPEND_NOTE's "treat zero as
        # unset" advice is wrong for those slots, and printing both would
        # contradict itself.
        (APPEND_NOTE, any_append and not dirty_notes),
        (UPDATE_NOTE, bool(drifted or missing)),
    ):
        if fires:
            print(note)
            print()

    if drifted or missing:
        return 1

    total = sum(len(v) for v in layouts.values())
    print(
        f"OK: ERC-7201 storage layout unchanged for all {len(layouts)} upgradeable "
        f"contract(s), {total} field(s) total"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
