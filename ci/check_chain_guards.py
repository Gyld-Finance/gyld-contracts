#!/usr/bin/env python3
"""Fail if a deploy script has a denylist chain guard — or no chain guard at all.

Why this exists (GYL-1135)
--------------------------
The live Base mainnet stack was once deployed with a zero-delay timelock and a
bare EOA holding every privileged role. The scripts *had* a "mainnet
protection" — but it was written as a denylist:

    require(block.chainid != 1, "not on mainnet");

Ethereum mainnet is chain 1, so the check passed on Base (8453) — and on
Arbitrum, Optimism, Polygon and every other L2 — and the dev-only fallbacks
(deployer-as-admin, delay = 0, mock sanctions oracle) ran on a production
chain. The fix is `DeployGuards.isDevChain()`: an ALLOWLIST where only Anvil
(31337) and Sepolia (11155111) count as development chains and every
unrecognised chain fails closed as production.

This check fails CI if any `block.chainid != ...` comparison appears in
executable code under contracts/script/. Comparing the chain id with `!=` is
denylist thinking: it names the chains you remembered, and silently trusts
the ones you didn't. If you hit this failure, express the condition as an
allowlist instead — `DeployGuards.isDevChain()`, `DeployGuards.requireProdSafe()`,
or an explicit `block.chainid == <the one chain this script is for>`.

Comments and string literals are stripped before matching, so prose that
*describes* the old bug (as DeployGuards.sol and DeployDevNet.s.sol do) does
not trip the check.

Check 2 — a MISSING guard (GYL-1135 follow-up)
----------------------------------------------
Check 1 can only see a guard that is written badly; it is structurally blind to
a script with no guard at all. That blindness is what let `DeployMockUSDC.s.sol`
survive the first pass of this ticket: it had no chain check of any kind, so it
deployed a fake "USD Coin" on any chain and minted it to publicly-keyed Anvil
accounts. Every script under contracts/script/ must therefore carry at least one
of:

  - a `DeployGuards.<guard>()` call — the dev/production allowlist path; or
  - a positive `block.chainid == <id>` pin — for scripts written for exactly one
    chain (the Euler steps on Base, the Anvil-only flow scripts).

Usage: python3 ci/check_chain_guards.py [script-dir]   (default: contracts/script)
Exit codes: 0 = clean, 1 = violation found, 2 = script dir missing.
"""

import re
import sys
from pathlib import Path

FORBIDDEN = re.compile(
    r"block\s*\.\s*chainid\s*!=|!=\s*block\s*\.\s*chainid"
)

# A guard that classifies the chain: either the shared library (whose entire
# surface is production-aware) or an explicit single-chain pin.
GUARD_PRESENT = re.compile(
    r"DeployGuards\s*\.\s*[A-Za-z_]\w*\s*\("
    r"|block\s*\.\s*chainid\s*=="
    r"|==\s*block\s*\.\s*chainid"
)

# Files that are not deploy scripts and so need no chain guard of their own.
# DeployGuards.sol IS the guard library: it defines isDevChain, and requiring it
# to "call a guard" would be circular.
GUARD_EXEMPT = {"lib/DeployGuards.sol"}


def strip_comments_and_strings(src: str) -> str:
    """Blank out //, /* */ comments and "…"/'…' string literals.

    Replaces their contents with spaces, preserving newlines so that line
    numbers in the report still refer to the original file.
    """
    out = []
    i, n = 0, len(src)
    NORMAL, LINE_COMMENT, BLOCK_COMMENT, STRING = 0, 1, 2, 3
    state, quote = NORMAL, ""
    while i < n:
        c = src[i]
        nxt = src[i + 1] if i + 1 < n else ""
        if state == NORMAL:
            if c == "/" and nxt == "/":
                state = LINE_COMMENT
                out.append("  ")
                i += 2
            elif c == "/" and nxt == "*":
                state = BLOCK_COMMENT
                out.append("  ")
                i += 2
            elif c in ('"', "'"):
                state, quote = STRING, c
                out.append(" ")
                i += 1
            else:
                out.append(c)
                i += 1
        elif state == LINE_COMMENT:
            if c == "\n":
                state = NORMAL
                out.append(c)
            else:
                out.append(" ")
            i += 1
        elif state == BLOCK_COMMENT:
            if c == "*" and nxt == "/":
                state = NORMAL
                out.append("  ")
                i += 2
            else:
                out.append(c if c == "\n" else " ")
                i += 1
        else:  # STRING
            if c == "\\":
                out.append("  ")
                i += 2
            elif c == quote:
                state = NORMAL
                out.append(" ")
                i += 1
            else:
                out.append(c if c == "\n" else " ")
                i += 1
    return "".join(out)


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("contracts/script")
    if not root.is_dir():
        print(f"error: script directory not found: {root}", file=sys.stderr)
        return 2

    files = sorted(root.rglob("*.sol"))
    violations = []
    unguarded = []
    for path in files:
        code = strip_comments_and_strings(path.read_text(encoding="utf-8"))
        for lineno, line in enumerate(code.splitlines(), start=1):
            if FORBIDDEN.search(line):
                violations.append((path, lineno, line.strip()))
        rel = path.relative_to(root).as_posix()
        if rel not in GUARD_EXEMPT and not GUARD_PRESENT.search(code):
            unguarded.append(path)

    if unguarded:
        print("FAIL: deploy script with NO chain guard at all.\n")
        for path in unguarded:
            print(f"  {path}")
        print(
            "\nA script with no chain check runs on EVERY chain, which is how an"
            "\nungated DeployMockUSDC could mint a fake 'USD Coin' to publicly-keyed"
            "\nAnvil accounts on Base mainnet (GYL-1135). The denylist scan above"
            "\ncannot catch this: it only sees guards that are written, never guards"
            "\nthat are absent."
            "\n"
            "\nEvery script under contracts/script/ must carry one of:"
            "\n  - DeployGuards.requireProdSafe(..)   -- dev-only script, fails closed"
            "\n  - DeployGuards.envAddressProdRequired -- production path, strict env"
            "\n  - require(block.chainid == <id>)      -- pin a script to one chain"
        )

    if violations:
        print("FAIL: denylist-style chain guard found in deploy scripts.\n")
        for path, lineno, line in violations:
            print(f"  {path}:{lineno}: {line}")
        print(
            "\n`block.chainid != <x>` guards are how a zero-delay timelock and a"
            "\nbare-EOA admin ended up on live Base mainnet (GYL-1135): the old"
            "\n`require(block.chainid != 1, ...)` check only knows about Ethereum"
            "\nmainnet, so Base, Arbitrum, Optimism and every future L2 walk straight"
            "\npast it and get the dev-only code path. Chain guards must be"
            "\nALLOWLISTS that fail closed on chains they do not recognise."
            "\n"
            "\nUse instead (contracts/script/lib/DeployGuards.sol):"
            "\n  - DeployGuards.isDevChain()        -- true only on Anvil / Sepolia"
            "\n  - DeployGuards.requireProdSafe(..) -- revert unless on a dev chain"
            "\n  - require(block.chainid == <id>)   -- pin a script to one chain"
        )

    if violations or unguarded:
        return 1

    print(f"OK: every one of {len(files)} file(s) under {root}/ carries an allowlist chain guard")
    return 0


if __name__ == "__main__":
    sys.exit(main())
