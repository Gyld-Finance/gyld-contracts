# Decision: SanctionsOracleMirror — sanctions compliance on L2 chains

**Status:** Superseded (GYL-1051, 2026-07-25)  
**Date:** 2026-05-08  
**Applies to:** `contracts/SanctionsOracleMirror.sol`, `contracts/test/SanctionsOracleMirror.t.sol`  
**Linear:** GYL-282, superseded by GYL-1051

> **Superseded (GYL-1051, 2026-07-25).** The platform-operated
> `SanctionsOracleMirror` is the production sanctions oracle on **every** EVM chain,
> **including Ethereum mainnet**. This document's founding premise — that mainnet
> uses the Chainalysis-operated oracle directly and the mirror exists only for
> chains where Chainalysis has not deployed — no longer holds, and neither does its
> "deployment gap adapter" framing (§4) or its retire-the-mirror migration
> direction (§9), which is now inverted. The rationale below was accurate when
> written and is retained as a dated record; do not treat it as current policy.
>
> **Live record:** the root-repo ADR `docs/decisions/sanctions-oracle-mirror.md`.
> Access control (§5), keeper design (§6) and the not-a-blacklist argument (§4's
> first half) carry over unchanged — only the *which chain uses which oracle*
> question was reversed.

---

## 1. The problem — Chainalysis oracle is mainnet-only

> Superseded — see banner. Chainalysis mainnet availability is no longer the
> deciding factor; the platform mirror is the configured oracle on every chain.

`GyldBondToken` relies exclusively on the Chainalysis on-chain sanctions oracle for
every secondary transfer check. The call is:

```solidity
function _requireAccess(address account) internal view {
    ISanctionsList sl = _getStorage().sanctionsList;
    if (address(sl) != address(0)) {
        require(!sl.isSanctioned(account), "GyldBondToken: account sanctioned");
    }
}
```

On Ethereum mainnet this is straightforward — point `sanctionsList` at
`0x40C57923924B5c5c5455c48D93317139ADDaC8fb` and the real Chainalysis oracle handles everything.

**On any other EVM chain, that address does not exist.** Chainalysis has not deployed
their oracle contract on Mantle, Arbitrum, Base, or most L2s. This means:

- If we deploy `GyldBondToken` on Mantle and point it at the mainnet address, every
  transfer check calls a non-existent contract and reverts.
- If we set `sanctionsList = address(0)`, the `if` guard short-circuits and the
  sanctions check is completely disabled — the bond token becomes uncompliant.

Neither option is acceptable. `SanctionsOracleMirror` is the solution.

---

## 2. Why Mantle specifically

Mantle is an EVM-compatible L2 that uses the same Solidity/EVM execution environment
as Ethereum mainnet. Contracts written for mainnet compile and deploy on Mantle without
modification — including `GyldBondToken`, `IssuanceManager`, and `TokenFactory`.

The problem is purely at the **oracle layer**: the compliance data (OFAC SDN list) lives
on Ethereum mainnet inside Chainalysis's contract. Mantle has no cross-chain message
passing to that mainnet state.

Mantle is the first target because:

1. **L2 economics.** Mantle gas fees are significantly lower than mainnet, making bond
   token secondary transfers cheaper for institutional APs — important for a product
   that needs high-frequency transfer events.
2. **EVM compatibility.** Zero Solidity changes. `GyldBondToken` bytecode deploys
   identically. The only difference is the `sanctionsList` address passed at `initialize()`.
3. **No Chainalysis deployment.** As of 2026-05-08, Chainalysis has not deployed their
   oracle on Mantle.

---

## 3. What SanctionsOracleMirror does

`SanctionsOracleMirror` is a native Mantle (or any L2) contract that:

1. **Holds a local copy of the OFAC/SDN sanctions list** — a `mapping(address => bool)`.
2. **Exposes the exact same function signatures as the real Chainalysis oracle:**

| Function | Signature | Notes |
|---|---|---|
| `isSanctioned(address)` | `view returns (bool)` | Used by `GyldBondToken._requireAccess()` |
| `isSanctionedVerbose(address)` | `returns (bool)` | Emits per-address event; nonpayable to match real oracle |
| `addToSanctionsList(address[])` | `external` | Keeper bot write path |
| `removeFromSanctionsList(address[])` | `external` | Keeper bot write path |
| `name()` | `pure returns (string)` | Returns `"Chainalysis sanctions oracle"` — tooling compatibility |

Because the function signatures and events are identical, `GyldBondToken` treats this
contract as if it were the real Chainalysis oracle. No change to `GyldBondToken` or
`IssuanceManager` is required when deploying on Mantle.

3. **Is kept current by a keeper bot** that polls the OFAC SDN delta every ~4 hours
   and calls `addToSanctionsList` / `removeFromSanctionsList` with the diff.

---

## 4. Why this is NOT an internal blacklist

This is the most important design constraint. The CLAUDE.md hard rule is:

> **No internal blacklist.** Compliance relies exclusively on the Chainalysis
> on-chain sanctions oracle. There is no platform-managed blocked-address mapping
> and we will not add one.

`SanctionsOracleMirror` does not violate this rule because:

- **The data source is OFAC/SDN** — the same dataset that powers the real Chainalysis oracle.
  The keeper bot reads the same Chainalysis SDN feed. We are mirroring, not deciding.
- **No platform discretion.** The mirror contains only addresses that are formally
  designated by OFAC, the UN, or the EU consolidated list — identical scope to the real
  oracle. The platform does not add addresses for business reasons.
- **Deterministic delta.** The keeper computes `new_addresses = ofac_current - mirror_current`
  and calls `addToSanctionsList(new_addresses)`. There is no human review step that could
  introduce platform-subjective blocking.

> Superseded — see banner. The mirror is the **primary platform sanctions oracle**
> on every chain, not a deployment gap adapter, and it is not retired when a vendor
> oracle becomes available on a chain. The not-a-blacklist reasoning above still
> holds; the paragraph below does not.

If Chainalysis were to deploy their oracle on Mantle, we would switch `GyldBondToken`'s
`sanctionsList` pointer to the Chainalysis address and retire the mirror. The mirror is a
**deployment gap adapter**, not a compliance philosophy change.

---

## 5. Access control — why AccessControl over Ownable

The real Chainalysis oracle uses `Ownable` with a single Chainalysis-controlled key.
We cannot replicate that model because we are not Chainalysis — we need operational
separation between the bot that writes data and the governance that controls the system.

`SanctionsOracleMirror` uses `AccessControl` with two roles:

| Role | Holder | What they can do |
|---|---|---|
| `SANCTIONS_UPDATER_ROLE` | Keeper bot hot wallet | `addToSanctionsList`, `removeFromSanctionsList` |
| `DEFAULT_ADMIN_ROLE` | Compliance ops multisig (Gnosis Safe) | Grant/revoke any role |

**Why this separation matters:**

- The keeper bot runs automatically, 24/7, and must sign transactions. Its private key
  lives in an automated system — a higher exposure surface than a human-operated multisig.
  If the bot key is compromised, the attacker can only write to the sanctions list; they
  cannot change who holds the updater role or grant themselves admin privileges.
- The compliance multisig can revoke the compromised bot key and grant a fresh one in a
  single 2-of-N multisig transaction — without touching the admin role or requiring a
  timelock.
- The admin cannot write to the sanctions list directly (only `SANCTIONS_UPDATER_ROLE`
  can). This prevents the compliance team from accidentally or intentionally blocking
  addresses outside the OFAC/SDN feed by calling `addToSanctionsList` manually.

---

## 6. How the keeper bot works (keeper not yet in repo)

The keeper bot is a separate off-chain service (to be implemented). Its loop:

```
every 4 hours:
    1. Fetch current OFAC SDN list (Chainalysis API or public CSV)
    2. Fetch current mirror state: all SanctionedAddressesAdded / Removed events from chain
    3. Compute delta:
         to_add    = ofac_current ∖ mirror_current
         to_remove = mirror_current ∖ ofac_current
    4. If to_add is non-empty:    call addToSanctionsList(to_add)
    5. If to_remove is non-empty: call removeFromSanctionsList(to_remove)
    6. Emit metrics: addresses_added, addresses_removed, total_mirrored
```

The keeper signs with the hot wallet holding `SANCTIONS_UPDATER_ROLE`.

**Why 4 hours:** OFAC publishes SDN updates asynchronously. The real Chainalysis oracle
does not have a published update frequency. 4 hours is a reasonable balance between
freshness (a newly-designated address is blocked within 4 hours) and on-chain cost
(each batch update is one transaction).

---

## 7. Integration with GyldBondToken on Mantle

When deploying a bond series on Mantle:

```
DeployDevNet.s.sol (Mantle version):
    1. Deploy SanctionsOracleMirror(admin = opsMultisig, updater = keeperBot)
    2. Deploy IssuanceManager proxy
    3. Deploy TokenFactory(owner = timelockController, sanctionsList = address(SanctionsOracleMirror))
    4. factory.deployToken(...)  — GyldBondToken proxy initializes with SanctionsOracleMirror address

GyldBondToken._requireAccess() → SanctionsOracleMirror.isSanctioned()
                               → returns true/false from local mapping
                               → identical behaviour to mainnet oracle call
```

`GyldBondToken` cannot distinguish the mirror from the real oracle — same interface,
same fail-closed behaviour (if the mirror contract itself reverts, the transfer reverts).

---

## 8. What we deliberately do NOT do

- **Do not add platform-discretionary addresses.** `addToSanctionsList` must only be
  called by the keeper bot with OFAC-derived data. No compliance officer should call it
  directly to block an address for a non-sanctions reason.
- **Do not share the mirror across chains.** Each L2 deployment gets its own
  `SanctionsOracleMirror` instance. Cross-chain state sharing requires bridges and
  introduces bridge failure modes into the compliance path.
- **Do not remove the `SANCTIONS_UPDATER_ROLE` guard.** Without it, any address could
  add themselves to the sanctions list (griefing) or remove themselves (evasion).
- **Do not give the keeper `DEFAULT_ADMIN_ROLE`.** The keeper is an automated system.
  If compromised it should not be able to grant itself or anyone else admin privileges.

---

## 9. Upgrade and migration path

> Superseded — see banner. The migration direction below is **inverted**: the
> platform does not migrate off the mirror onto a vendor oracle. A vendor oracle
> may be consumed *through* the mirror's optional gas-capped `forwardingOracle`,
> and `setSanctionsList()` is used to rotate between platform oracle contracts.

If Chainalysis deploys their oracle on Mantle:

```
1. opsMultisig calls GyldBondToken.setSanctionsList(chainalysisAddress)
   (gated by DEFAULT_ADMIN_ROLE → TimelockController, 48h delay)
2. After timelock executes, GyldBondToken reads from the real oracle.
3. Stop the keeper bot — SanctionsOracleMirror receives no further updates.
4. SanctionsOracleMirror can be left deployed (harmless) or deprecated.
```

`GyldBondToken.setSanctionsList()` is the clean migration hook. No token migration,
no holder disruption, no LP redeployment required.
