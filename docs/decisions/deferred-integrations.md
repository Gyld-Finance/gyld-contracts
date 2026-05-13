# Deferred Integrations

These adapter crates exist in the workspace and compile, but are **not wired for
production use**. Current focus is EVM (Ethereum) end-to-end. The port-trait
architecture means adding a new chain or oracle later = one new adapter
registration in `bootstrap/src/main.rs` — no core changes.

---

## Solana (`adapter-wallet-sol`, future `adapter-chain-sol`)

**Status:** Crate exists, all methods return `CoreError::NotImplemented`.

**Why deferred:** Token standard (ERC20F), custodian (Alpaca), and compliance
tooling (Chainalysis) are all EVM-native for v1. Solana support adds operational
complexity (different key derivation, SPL vs ERC20, separate RPC) with no
immediate customer demand.

**When to revisit:** After the EVM mint flow is battle-tested on Hoodi/mainnet and
a Solana custodian or issuer relationship exists.

---

## Chainlink oracle (`adapter-oracle-chainlink`)

**Status:** Crate exists, price/nav/attestation methods return `CoreError::NotImplemented`.

**Why deferred:** Bond pricing for mint/redeem is sourced directly from the Alpaca
broker fill price. On-chain Chainlink feeds are needed for the Morpho Blue lending
integration (secondary market collateral valuation), which is post-v1.

**See also:** `docs/plans/2026-04-16-chainlink-morpho-pricing-roadmap.md`

---

## Pyth oracle (`adapter-oracle-pyth`)

**Status:** Crate exists, price/nav/attestation methods return `CoreError::NotImplemented`.

**Why deferred:** Same rationale as Chainlink — not required for the primary
broker-sourced pricing path. Pyth is the backup feed candidate for the same
Morpho phase.

---

## Fordefi wallet (`adapter-wallet-fordefi`)

**Status:** Crate exists, all IWallet methods return `CoreError::NotImplemented`.

**Why deferred:** Production key management target (MPC custody), but requires
Fordefi API access and a signing policy workflow that's out of scope for the
testnet phase. `PrivkeyWallet` (hex key) is used on Hoodi dev.

**When to revisit:** Before mainnet launch — this replaces `PrivkeyWallet` in
`bootstrap/src/main.rs`.
