#!/usr/bin/env python3
"""Fail if a denylist-style chain guard reappears in contracts/script/.

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

Usage: python3 ci/check_chain_guards.py [script-dir]   (default: contracts/script)
Exit codes: 0 = clean, 1 = violation found, 2 = script dir missing.
"""

import re
import sys
from pathlib import Path

FORBIDDEN = re.compile(
    r"block\s*\.\s*chainid\s*!=|!=\s*block\s*\.\s*chainid"
)


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
    for path in files:
        code = strip_comments_and_strings(path.read_text(encoding="utf-8"))
        for lineno, line in enumerate(code.splitlines(), start=1):
            if FORBIDDEN.search(line):
                violations.append((path, lineno, line.strip()))

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
        return 1

    print(f"OK: no denylist chain guards in {len(files)} file(s) under {root}/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
