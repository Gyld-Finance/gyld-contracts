# Slither triage

Every Slither finding that touches a production contract, with a disposition.
`ci/check_slither.py` fails CI on any production finding **not** on this list, so
this document and `ci/slither-baseline.json` are kept in step by the build.

| | |
|---|---|
| Slither | 0.11.6 |
| solc | 0.8.28, `via_ir = true`, `optimizer_runs = 200` |
| Command | `slither .` (unfiltered — see *The `--filter-paths` trap* below) |
| Results, whole tree | **1,956** |
| Results touching `contracts/*.sol` | **49** (45 unique fingerprints) |
| Live defects found | **0** |

The other ~1,908 results are in `lib/` — OpenZeppelin v5.3.0 and forge-std. They
are not this repo's code and are not triaged here.

## How to read the disposition column

- **False positive** — the detector's precondition does not hold here. No action,
  now or later.
- **Accepted** — the detector is right about the mechanism, and the mechanism is
  deliberate. Carries a reason and, where one exists, a decision-record pointer.

Nothing on this list is marked "fix later". If something needed fixing it was
fixed, not filed.

---

## Medium impact

### `divide-before-multiply` — `GyldAtomicSwap._checkQuoteBand` — **Accepted**

```solidity
navValue = (tokenAmount * uint256(nav)) / 1e20;
band     = (navValue * $.maxQuoteDeviationBps) / BPS_DENOMINATOR;
```

Real, and bounded. `navValue` is deliberately truncated to USDC's 6 decimals
because that is the unit the comparison is made in; computing
`tokenAmount * nav * bps / 1e24` in one expression would keep at most one extra
unit of precision. The error is ≤ 1 unit of USDC (1e-6 USD) on a *tolerance
band*, not on a transferred amount. No value moves on this number — it only
widens or narrows the window a signed quote must fall inside.

### `incorrect-equality` ×5 — `KaleidoscopeNAVFeed` — **False positive**

`getRoundData`, `isFresh`, `latestAnswer`, `latestRoundData`, `stalenessSeconds`,
all on `_updatedAt == 0`.

The detector looks for strict equality against a value an attacker can land on.
`_updatedAt` is a `block.timestamp` written on every push, and `0` is its
*never-written sentinel* — the feed reverts `NoPriceSet` on it. Timestamp 0 is
not reachable on any live chain, so there is no equality to grind toward. A `<= 0`
or `< 1` rewrite would be strictly less clear and no safer.

### `unused-return` — `GyldAtomicSwap._checkQuoteBand` — **Accepted, D-18**

```solidity
(, int256 nav,, uint256 updatedAt,) = AggregatorV3Interface(...).latestRoundData();
```

`roundId`, `startedAt` and `answeredInRound` are discarded on purpose. Chainlink
**deprecated** `answeredInRound`; OCR aggregators return it equal to `roundId`, as
does `KaleidoscopeNAVFeed` by construction, so the classic
`answeredInRound < roundId` guard cannot fire on any feed this contract would be
pointed at. Staleness rides on `updatedAt` against the 72 h-ceilinged
`maxNavAgeSecs` (D-16) plus a future-dating guard (F-6). Recorded as **D-18** in
`ARCHITECTURE.md` §17.1, with the revisit condition.

---

## Low impact

### `return-bomb` ×2 — `SanctionsOracleMirror` — **Accepted**

`isSanctioned` and `_setForwardingOracle` both `staticcall` a third-party oracle
and let Solidity decode the returndata:

```solidity
(bool ok, bytes memory data) = address(fwd).staticcall{gas: FORWARDING_GAS}(...);
if (!ok || data.length != 32) revert InvalidForwardingOracle(address(fwd));
```

The detector's concern is that `returndatacopy` runs in *our* frame before the
length check, so a hostile callee could in principle exhaust our gas by returning
megabytes.

It is bounded here, though not obviously, which is why it is written down. The
callee must first hold that data in *its own* memory, and memory expansion is
quadratic. `FORWARDING_GAS` is **40 000**, which caps the callee's own buffer at
roughly tens of kilobytes, and the copy back costs us 3 gas per word on top. The
worst case is a few thousand wasted gas on a call the mirror is about to revert
anyway — not a denial of service.

Do not remove the gas cap on the assumption the length check protects you: the
length check runs *after* the copy. The cap is the mitigation.

### `shadowing-local` ×5 — `GyldBondToken` — **False positive**

`setDocument`, `_setDocument`, `removeDocument`, `getDocument`, `_removeDocName`
each take a `bytes32 name` that shadows `ERC20.name()`.

`name` is the parameter name in the **ERC-1643 signature** — renaming it would
make the implementation diverge from the standard it declares. The types make
confusion impossible: one is a `bytes32` document key, the other a
`function () view returns (string)`. No call site can resolve to the wrong one.

### `reentrancy-benign` — `TokenFactory.deployToken` — **False positive**

The external calls are `grantRole` on a token the factory **CREATE2-deployed
three lines earlier**, in the same transaction. The callee is `GyldBondToken`
bytecode the factory itself just wrote — not attacker-controlled. There is no
untrusted re-entry point, and `deployToken` is `onlyOwner` (the timelock in
production) and `nonReentrant` besides.

### `timestamp` ×10 — **False positive**

`GyldAtomicSwap` (quote expiry, NAV age), `KaleidoscopeNAVFeed` (update interval,
freshness), `NAVFeedForwarder` (future-date probe), `IssuanceManager` (daily mint
cap window, audit FIND-001).

Every comparison is on an **hour-to-day** scale: `MIN_UPDATE_INTERVAL` is 1 hour,
`maxNavAgeSecs` is ceilinged at 72 hours, quote TTL at 10 minutes, and the
issuance `CAP_WINDOW` is 24 hours. Proposer timestamp latitude is seconds. There
is no threshold here a validator could straddle to gain anything.

The issuance window deserves the explicit version, because it is the one where
straddling a boundary *does* buy something: a mint at the end of one window and
another at the start of the next yields two daily budgets, so the real bound is
2× the cap per rolling 24 h. That is a property of a fixed resetting window, not
of timestamp latitude — it holds at any clock precision, and moving the boundary
by a few seconds neither creates nor widens it. The same design ships in Ondo's
`InstantMintTimeBasedRateLimiter`. It is documented on `CAP_WINDOW` and in the
FIND-001 remediation; the answer if a hard 1× bound is ever required is to halve
the cap, not to chase sub-second accuracy.

---

## Informational

### `missing-inheritance` ×6 — **Accepted (test doubles only)**

`MockSanctionsList`, `SelectiveRevertingOracle`, `MalformedReturnOracle`,
`GasGriefingOracle`, `MockFutureDatedOracle`, `ReentrantToken`.

**Zero production contracts appear in this detector**, which is the point: audit
§4.8 moved every cross-contract interface into `contracts/interfaces/` and made
the implementers declare it (D-20). Before that change Slither could not detect
this class at all — there was no shared interface to compare against — so these
six results are a *consequence* of the fix, not a gap in it.

They are all deliberately non-conforming: the doubles exist to return malformed
data, revert selectively, or grief on gas. Making them `is ISanctionsList` would
force them to be well-behaved and destroy what they test.

### `low-level-calls` ×11 — **Accepted**

`staticcall` probes in `GyldAtomicSwap.initialize` / `registerSeries`,
`GyldBondToken.initialize` / `setSanctionsList`, `IssuanceManager.registerToken`,
`NAVFeedForwarder` ×3, `SanctionsOracleMirror` ×2, `TokenFactory.constructor`.

This is the repo's probe-before-store idiom: before storing an address that will
be called on the hot path, staticcall it and require a well-formed answer, so a
misconfiguration fails at configuration time rather than on a user's transfer. A
high-level call cannot express "try this and tell me if it worked" without
`try/catch`, which cannot bound gas.

### `assembly` ×4 — **Accepted**

Three `_getStorage()` bodies (ERC-7201 namespaced storage; the assembly *is* the
pattern) and the `create2` in `TokenFactory.deployToken`. Layout is pinned
independently by `ci/check_storage_layout.py`.

### `pragma`, `cyclomatic-complexity`, `naming-convention` — **Accepted**

- `pragma`: the tree pins `=0.8.28` exactly; the detector flags the presence of a
  version declaration across files, not a conflict.
- `cyclomatic-complexity`: `GyldAtomicSwap.executeSwap` is the settlement path —
  signature, expiry, epoch, allowlist, replay, band and inventory checks in one
  function *by design*, because splitting it would move checks away from the state
  they guard.
- `naming-convention`: `_rid` in `KaleidoscopeNAVFeed`.

---

## The `--filter-paths` trap

**Do not run `slither . --filter-paths "lib/"`.**

Slither matches that pattern against the **absolute** path. In any checkout whose
own path contains a `lib/` segment — such as the vendored
`kaleidoscope/lib/gyld-contracts` — the pattern matches every file in the project
and Slither reports a confident:

```
0 result(s) found
```

That is a false negative, and it looks exactly like a clean run.

`ci/check_slither.py` runs Slither **unfiltered** and filters afterwards on the
repo-relative path, which is correct regardless of where the repo is checked out.

## Reproducing

```bash
python3 -m venv .venv && ./.venv/bin/pip install slither-analyzer
PATH="$PWD/.venv/bin:$PATH" python3 ci/check_slither.py
```

To re-baseline after triaging a genuinely new finding — **triage it in this
document first**:

```bash
PATH="$PWD/.venv/bin:$PATH" python3 ci/check_slither.py --write
```

Removing code that had a baselined finding is not a failure; the checker prints a
NOTE and you can prune with `--write` when convenient.
