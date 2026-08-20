# DEPLOYMENTS — authoritative on-chain address register

This file is the **only** authoritative list of Gyld contracts on public chains.
Every row below was verified directly against the chain with `cast code` /
`cast call` on **2026-08-04** (Sepolia head ~11,416,602; BSC testnet head
~123,091,110). If an address is not in this file, do not send
funds to it, approve it, or wire it into a config.

Deployer EOA for everything below: `0xcEae7F1093762C75fdbC2B95FAcE3dE954b9FEAd`.

---

## WARNING: never treat `broadcast/` as an address book

Foundry keys `broadcast/` output **by chain ID only**. A local Anvil node
started with `--chain-id 1` writes its run files into
`broadcast/<Script>.s.sol/1/` — byte-for-byte indistinguishable in layout
from a genuine production-mainnet broadcast. This repository's verification
workflow deliberately runs production code paths against local nodes that borrow
real chain IDs — production chain IDs and 11155111 alike — so the tree routinely
accumulates records of contracts that **do not exist** on the real chain.

This was not hypothetical. Before the 2026-08-04 cleanup, `run-latest.json`
files sitting under borrowed production chain IDs described deployments whose
receipts were at blocks 2–12 (Anvil), whose sender was Anvil dev account 0
(`0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`, private key public), and whose
addresses had **no code on the real chain**. Worse, two addresses named in
spoofed Sepolia artifacts (`0x09635F…ceBef`, listed as "MockUSDC", and
`0xc3e53F…63690`, listed as "GyldBondToken") resolve on real Sepolia to a
**stranger's "My Hardhat Token" (MHT)** owned by that same public Hardhat
account — anyone who copied those into a config would have been approving or
transferring to a contract they do not control.

Rules:

1. Addresses come from **this file**, never from `broadcast/**` (which is
   gitignored and machine-local anyway).
2. A broadcast run is only trustworthy if its receipt block numbers are
   consistent with the real chain's height **and** its sender is a key the
   team actually controls — check both before believing anything in it.
3. When exercising production scripts locally, prefer `--chain-id 31337`; if a
   real chain ID must be borrowed, delete the resulting `broadcast/<Script>/<id>/`
   directory immediately afterwards.

---

## Ethereum Sepolia (chainId 11155111)

Two generations coexist. **Do not mix them.**

### Generation 1 — devnet stack, deployed 2026-05-14 (`DeployDevNet`, commit era `6349ec5`)

| Contract | Address | Source commit | Privileged roles | Explorer verified | Status |
|---|---|---|---|---|---|
| TimelockController | `0xf803F99B7BCFE4D0db52FDE5a76c5FC257D9ef72` | 6349ec5 | minDelay = 0; proposer = deployer EOA; open executor | Yes (Blockscout) | live (test) — **this row is a Sepolia record and nothing else.** The same deployer at the same nonces produces this same address on any chain, so never read this address as identifying the same contract elsewhere |
| IssuanceManager (ERC1967 proxy) | `0x5BA267367f06378816c58d47C5850fC9863Ce67F` | 6349ec5 | DEFAULT_ADMIN_ROLE = timelock | Yes (Blockscout) | live (test) |
| IssuanceManager (implementation) | `0xEA637cdB348d4d14d1329E304F025cC8FD428E5a` | 6349ec5 | — | Yes (Blockscout) | live (test) |
| MockSanctionsList | `0x7C1798643e0793EAB998B777b2CD0B7c2F2870Ad` | 6349ec5 (pre-GYL-1135 version) | **NONE — `addToSanctionsList`/`removeFromSanctionsList` are plain `external`, no owner, no access control. Anyone on the internet can sanction or unsanction any address.** Because token screening is fail-closed, this is a permissionless transfer-freeze on every holder of every series wired to it. | Yes (Blockscout) | **do-not-reuse — ungated sanctions oracle.** Never point a new deployment at it. (The hardened, owner-gated version exists only in current source; this deployed instance predates it — its `owner()` selector reverts.) |
| GyldBondToken (implementation, gen-1) | `0x18Ce55785bD24Dd096dAC11111168B1E94A76317` | 6349ec5 | — | Yes (Blockscout) | abandoned |
| TokenFactory | `0xb11BdcFE08c69c461F410453BdF80A8cb9Cd07aE` | 6349ec5 | owner = timelock | Yes (Blockscout) | abandoned |
| Series "Caterpillar Inc 3.7% 2028" (proxy) | `0xC545645b889027F5C2e7c1460566B08673273B07` | 6349ec5 | admin = timelock | Yes (Blockscout) | abandoned demo |
| — NAVFeed / Forwarder | `0x0e21b8E3D40d92244a07977905c056EBF5f88DDE` / `0xDcBd2c177212aebD18e8F1429457483644C50C00` | 6349ec5 | — | — | abandoned demo |
| Series "Citigroup Inc 3.887% 2028" (proxy) | `0xF62dd0722ed16593B0e8A00dD80D0Ea43A0e0c1E` | 6349ec5 | admin = timelock | — | abandoned demo |
| — NAVFeed / Forwarder | `0x0248FaB2aa4a481b6c7C81DDdd28ac24E8EacEc7` / `0x24A5eb80F6ab34C9563f5667D1bc1ccB3167B9c0` | 6349ec5 | — | — | abandoned demo |
| Series "Coca-Cola Co 2.25% 2032" (proxy) | `0xb7Fc5791910CeddB54BbD53136D2cfc67719A2B4` | 6349ec5 | admin = timelock | — | abandoned demo |
| — NAVFeed / Forwarder | `0x5039770267e05A8A38023CF925b3b7FF6a8076d8` / `0x38Bc14C8C39C62F712207c950d423957A51550bA` | 6349ec5 | — | — | abandoned demo |

### Generation 2 — ERC-8056 / atomic-swap stack, deployed 2026-07-31 (commit **`46050ea`**)

| Contract | Address | Source commit | Privileged roles | Explorer verified | Status |
|---|---|---|---|---|---|
| GyldBondToken implementation (ERC-8056) | `0x72FAE4fa227e7E28BF315BA363dE39E371a49C52` | **46050ea** | — | Yes (Blockscout) | live (test) |
| GTB8056 "Gyld Test Bond 8056" (ERC1967 proxy, CREATE2) | `0xE1C0a83Ab03e4498Fad1f833fA484E2cfc68dE7b` | **46050ea** | DEFAULT_ADMIN_ROLE = timelock `0xf803…ef72` (deployer-controlled, zero delay) | Yes (Blockscout) | **do-not-reuse** — experimental ERC-8056 proxy; wired to the ungated MockSanctionsList lineage and to source that is not on `main` |
| — KaleidoscopeNAVFeed / NAVFeedForwarder | `0x4266a4A43Db435056f60C02b37fA8586E58597Fa` / `0x49be531A7C48077483997d92D7BeF759dd7b2b53` | 46050ea | — | — | live (test) |
| GyldAtomicSwap (implementation) | `0x287edc0d5F6d3D07beBD0390509C88Fc50a8f79b` | 46050ea | — | Yes (Blockscout) | live (test) |
| GyldAtomicSwap (ERC1967 proxy, CREATE2) | `0x7036206Fc1eBDF8917836b67375E6D49Bc02aBE8` | 46050ea | DEFAULT_ADMIN_ROLE = deployer EOA (all init roles set to deployer) | Yes (Blockscout) | live (test) — settlement asset is Circle Sepolia USDC `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

---

## BSC testnet (chainId 97)

Deployed 2026-08-03 (`Erc8056ExplorerDemo`, commit era **`46050ea`**). (That
script no longer exists in the tree — it went with the ERC-8056 extension under
GYL-1201; the record is kept as history, reachable via tag
`deployed/sepolia-bsc-gen2-46050ea`.)

| Contract | Address | Source commit | Privileged roles | Explorer verified | Status |
|---|---|---|---|---|---|
| SanctionsOracleMirror | `0x3ed17C11D29384d3E7e4BEC8fFA58D63C21Cf584` | 46050ea | DEFAULT_ADMIN_ROLE and SANCTIONS_UPDATER_ROLE both = deployer EOA (role-gated, unlike the Sepolia mock) | Unknown — BscScan needs `ETHERSCAN_API_KEY`; no Blockscout instance | live (test) |
| GyldBondToken implementation (ERC-8056) | `0x27faeeAAE973c374B5C477e0187C73f10A47E608` | 46050ea | — | Unknown (same) | live (test) |
| GBSCD "Gyld BSC Demo Bond" (ERC1967 proxy) | `0x7D7B5bE30bfe7A1941c60247b4D5A28ab266305a` | 46050ea | DEFAULT_ADMIN_ROLE = deployer EOA | Unknown (same) | **do-not-reuse** — experimental ERC-8056 demo proxy |

---

## Source-commit preservation — resolved 2026-08-05

- **`6349ec5`** (Sepolia gen-1): on `main` and `origin/main`. Safe.
- **`46050ea`** (Sepolia gen-2 + BSC testnet ERC-8056 bytecode): **not on
  `main`** — the extension was removed under GYL-1201, so this source will never
  be reachable from `main`. It is preserved by the annotated tag
  **`deployed/sepolia-bsc-gen2-46050ea`**, pushed to `origin`, and therefore
  survives deletion or squash-merge of the feature branches it came from. That
  mattered: `feat/GYL-1135-hardening` was deleted when PR #2 merged, so branch
  deletion is routine here. The tag message carries the address list and the
  do-not-upgrade caveats.
- Bytecode check confirming the gap: the current working tree builds a
  GyldBondToken runtime of 13,202 bytes (ERC-1643 added ~1.9 KB in `c1f240f`);
  the live Sepolia/BSC implementations are 13,184 bytes.
  Current source still does **not** reproduce any deployed implementation — but
  read that conclusion carefully now: the margin against the live 13,184 is
  **18 bytes**, not two kilobytes. Size is no longer evidence either way here;
  only a bytecode comparison settles it.

## Known hazards, in one place

1. `0x7C1798643e0793EAB998B777b2CD0B7c2F2870Ad` on **Sepolia** = ungated
   MockSanctionsList. **Re-verified on-chain 2026-08-05:** `owner()` reverts (the
   selector is absent — pre-GYL-1135 bytecode), and `addToSanctionsList([0xdEaD])`
   `eth_call`s cleanly from an arbitrary EOA, so it is permissionlessly writable.
   **FOUR live Sepolia tokens point at it**, not three — each verified by reading
   `sanctionsList()`:

   | Token | Symbol | totalSupply |
   | -- | -- | -- |
   | `0xC545645b889027F5C2e7c1460566B08673273B07` | 14913UBF6 | 1e24 |
   | `0xF62dd0722ed16593B0e8A00dD80D0Ea43A0e0c1E` | 172967LD1 | 0 |
   | `0xb7Fc5791910CeddB54BbD53136D2cfc67719A2B4` | 191216DP2 | 0 |
   | `0xE1C0a83Ab03e4498Fad1f833fA484E2cfc68dE7b` | GTB8056 | 1e20 |

   Because screening is fail-closed (`GyldBondToken._update` → `_checkNotSanctioned`
   → revert `AccountSanctioned`), any caller can freeze transfers for every holder of
   all four. Two carry supply.

   **Accepted as testnet-only (GYL-1203).** The gated version is on `main` and applies
   to all future deploys; the deployed instance is a plain contract, not a proxy, so it
   cannot be retro-gated. Redeploying against the real oracle is **not available** —
   `0x40C57923924B5c5c5455c48D93317139ADDaC8fb` has **no code on Sepolia**; Chainalysis
   does not publish an oracle there.

   **If Sepolia demos resume, rewire rather than redeploy:** `setSanctionsList()` is
   `DEFAULT_ADMIN_ROLE`-gated and live on all four proxies, and the timelock
   `0xf803…ef72` holds that role — so all four can be pointed at a freshly deployed
   gated mock in a handful of transactions, no upgrade needed. Note that timelock has
   `minDelay = 0` and an open executor, which is its own problem (see GYL-1206).

   Chain matters: this is a **Sepolia** record and nothing else. The same 20 bytes
   reached on another chain are a different contract — copying addresses between
   chains here is not a theoretical risk.
2. `0xE1C0a83Ab03e4498Fad1f833fA484E2cfc68dE7b` (Sepolia GTB8056) and
   `0x7D7B5bE30bfe7A1941c60247b4D5A28ab266305a` (BSC GBSCD): **do-not-reuse**
   ERC-8056 proxies.
3. `0x09635F643e140090A9A8Dcd712eD6285858ceBef` and
   `0xc3e53F4d16Ae77Db1c982e75a937B9f60FE63690` on Sepolia are a stranger's
   "My Hardhat Token" — they appeared in (now deleted) spoofed broadcast
   artifacts as "MockUSDC" and "GyldBondToken". Never use them.
4. The single timelock left in this file, Sepolia `0xf803…ef72`, has
   `minDelay = 0` and an open executor role: it provides accounting, not delay.
   All privileged control ultimately rests with the single deployer EOA
   `0xcEae…FEAd`.
