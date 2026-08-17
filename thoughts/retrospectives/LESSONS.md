# Retrospective Lessons (LESSONS.md)

Curated, reusable process lessons distilled from per-ticket retrospectives.
Read at the start of the **research**, **plan**, and **implement** stages.

## How this file is maintained

- **`## Standing Lessons`** is the always-read working memory — a fixed-size index of rules, not a log. Curate under hard budgets (≤30 bullets, ≤8192 bytes, ≤400 chars each); add only by merging/superseding; evidence lives in each ticket's retro artifact, never here.
- **`## Recent`** is a bounded rolling log (≤8 blocks) kept only for the newest tickets; older blocks roll off (their evidence lives in each ticket's per-ticket retro artifact).
- Read this file in full; the merge stage resolves conflicts semantically, not by union.

## Standing Lessons

- **Rollout-stage artifacts scoped in a plan don't ship with the implementation — hand them off**: an upgrade/deploy script, a `DEPLOYMENTS.md` rollout entry, or an invariant-handler extension in the plan tends to get deferred and silently drop out until the deploy critical path. Deliver them or pass as a named, tracked item to the rollout ticket. (see GLD-264 retro)
- **An immutable-logic factory caps a UUPS upgrade to existing proxies**: an implementation address pinned at construction (baked into proxy initcode) means new series still need a new factory or a logic-address setter — verify the bind mechanism and flag a factory follow-up at research, not at deploy. (see GLD-264 retro)
- **Upgradeable (UUPS/ERC-7201) storage: append-only + slot-pin the new offsets + upgrade-preservation test**: never reorder fields; prove layout safety with a raw-storage slot-pin for each new offset and a state-survives-`upgradeToAndCall` test — a stated-intention comment is not proof. (see GLD-264 retro; skill `upgradeable-storage-layout-safety`)
- **Enumerate every plan deviation at handoff**: flag intentional deviations (data-structure choice, initial-role-grant timing, scope exclusions) in the implementation comment so review adjudicates, not re-litigates; an undeclared deviation is rediscovered at review. (see GLD-264 retro)
- **Carve out-of-scope companions as named tickets**: bound an off-chain pipeline or a do-not-upgrade set at research and name the companion ticket, so the implementation and review hold the scope line without creep. (see GLD-264 retro)

## Recent

### GLD-264 — 2026-08-17 — Implement IERC-1643 document management on GyldBondToken (5 files +342/−8, 1 commit on feat/gld-264-erc-1643, base main; 0 rework, review PASS first pass, ~25m)
- **Plan-vs-delivery gap on rollout artifacts**: the plan's invariant-handler extension + `UpgradeBondTokenERC1643.s.sol` upgrade script and `DEPLOYMENTS.md` rollout entries were not delivered; reviewer re-enumerated them for the rollout ticket. Hand rollout/deploy items to the rollout ticket explicitly. (→ Standing)
- **An immutable-logic factory (TokenFactory) means a UUPS upgrade lifts only existing proxies** — new series need a new factory at the new logic. Caught at research, confirmed at implementation, must land in the rollout ticket. (→ Standing)
- **Layout safety was proved, not assumed**: append-only ERC-7201 struct + slot-pin extended to offsets 3/4 + `test_upgrade_preservesDocuments`; review approved on the evidence. (→ skill `upgradeable-storage-layout-safety`)
- **Extracted skill `upgradeable-storage-layout-safety`**: when extending state in an upgradeable Solidity contract — append-only, extend the slot-pin, add an upgrade-preservation test, run the full suite. Bound to Implementer + Reviewer.