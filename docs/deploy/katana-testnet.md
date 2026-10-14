# Katana testnet "Bokuto" (chain 737373) — full-stack deploy in the production topology

GLD-738. A port of the BSC testnet tooling (GLD-713) to Katana's testnet. Bokuto is a
**dev chain** (`DeployGuards.isDevChain()` is true for 31337, 11155111 and 737373 only;
Katana mainnet 747474 stays on the production path), so the scripts would accept a zero
timelock delay, a mock sanctions oracle and the deployer holding every role. **This
deploy uses none of the role fallbacks**: every privileged role gets its own key, so the
testnet stack rehearses mainnet. Only the timelock delay (0) and the mocks (sanctions
list, cash token) are testnet-grade.

**The Halborn-audited contracts are deployed unchanged.** Nothing under `contracts/` is
modified for this chain.

**Cash leg: the repo's `MockUSDC` (6 decimals).** The audited `GyldAtomicSwap.initialize`
probes the cash token and requires exactly 6dp (F-1). There is no Circle USDC on Bokuto.
`MockUSDC` (`contracts/test/MockUSDC.sol`) has a **permissionless `mint`** and is named
"USD Coin". It is worthless test cash. It is deployed directly, behind the same
`requireProdSafe` dev-chain guard as `DeployMockUSDC`. `DeployMockUSDC` itself is not
used because it mints 100k to three publicly-keyed Anvil accounts.

```bash
# once: put the funded key in a private file (see "Providing the key")
DRY_RUN=1 script-katana/deploy-katana-testnet.sh     # whole flow simulated, nothing sent
script-katana/deploy-katana-testnet.sh               # broadcast; asks you to type "broadcast"
```

| File | What |
|---|---|
| `script-katana/deploy-katana-testnet.sh` | Driver: preflight, keys, steps, logs, address file |
| `script-katana/KatanaTestnetStack.s.sol` | The on-chain work. Runs `DeployDevNet` and `DeployAtomicSettlement` **unchanged** (instantiates them and calls `run()`), deploys MockUSDC, plus the steps those scripts leave to other key holders on mainnet |
| `~/.gyld/katana-testnet-pk` | **You create it**: the funded key, chmod 600 |
| `~/.gyld/katana-testnet-derived-keys.env` | Written by the script: every derived role key + address, chmod 600, never committed |
| `docs/deploy/katana-testnet-addresses.env` | Written by the script: every address, **no secrets** — commit it |
| `~/.gyld/katana-testnet/logs/` | Full forge output per step (no secrets) |

## Roles & keys

The funded key is **deployer + gas funder only**. Every other role is a throwaway key
derived from it, deterministically:

```
pk(role) = keccak256(abi.encodePacked(KATANA_TESTNET_PK, "gyld.katana737373." + role)) mod (n − 1) + 1
```

`plan` prints role → address. `keys` (and `deploy`) writes the keys to the derived-keys
file. `verify` asserts all 14 holders are distinct and the deployer holds no role.

| Role (label) | Address var | On-chain power | ETH float |
|---|---|---|---|
| **deployer** (the funded key) | `DEPLOYER_ADDRESS` | Broadcasts the deploy scripts and funds every key below. Holds setup roles only transiently: they are revoked in the same broadcast | — |
| governance | `GOVERNANCE_MULTISIG` | Timelock PROPOSER + CANCELLER. Through the timelock: DEFAULT_ADMIN on IssuanceManager, the swap and every bond token; owner of the TokenFactory and every forwarder; `rangeGovernor` of every NAV feed | 0.002 |
| ops | `OPS_MULTISIG` | Bond-token PAUSER + DOCUMENT, swap PAUSER, NAV-feed `emergencyUpdater` | 0.0005 |
| nav-feed-owner | `NAV_FEED_OWNER` | Owner of the three NAV feeds (`updateAnswer`; must differ from ops, FIND-003) | 0.001 |
| subscriber | `SUBSCRIBER_ADDRESS` | IssuanceManager SUBSCRIBER_ROLE (`subscribe` = mint) | 0.001 |
| redeemer | `REDEEMER_ADDRESS` | IssuanceManager REDEEMER_ROLE (`redeem` = burn) | 0.0005 |
| whitelist-admin | `WHITELIST_ADMIN` | IssuanceManager WHITELIST_ADMIN_ROLE (whitelists the swap as an AP) | 0.0005 |
| issuance-pauser | `ISSUANCE_PAUSER` | IssuanceManager ISSUANCE_PAUSER_ROLE (FIND-001) | 0.0005 |
| quote-signer | `QUOTE_SIGNER` | Swap QUOTE_SIGNER_ROLE: signs EIP-712 quotes off-chain, never sends a tx | 0 |
| treasurer | `TREASURER_ADDRESS` | Swap TREASURER_ROLE (`withdraw` to the withdrawal wallet) | 0.0005 |
| allowlist-admin | `ALLOWLIST_ADMIN` | Swap ALLOWLIST_ADMIN_ROLE (`setAllowed` takers) | 0.0005 |
| distribution | `WITHDRAWAL_WALLET` = `SWAP_DISTRIBUTION_WALLET` | Swap `withdrawalWallet` | 0.0005 |
| sanctions-admin | `MOCK_SANCTIONS_OWNER` | MockSanctionsList owner, standing in for the SanctionsOracleMirror keeper | 0.0005 |
| taker | `SMOKE_TAKER` | Test AP: allowlisted on the swap, holds 1,000 MockUSDC. Not a protocol role | 0.001 |

Contracts that hold roles: the **TimelockController** (delay 0, open EXECUTOR,
self-administered) is DEFAULT_ADMIN everywhere. The **IssuanceManager** holds MINTER +
BURNER on every bond token. The **TokenFactory** holds REGISTRAR on the IssuanceManager.
DeployDevNet also whitelists Anvil account[1] (a public key) as an AP on dev chains.

Rotating a role to the gateway or KMS works exactly as in the BSC runbook
(`docs/deploy/bsc-testnet.md` on `feat/GLD-713-bsc-testnet`, "Moving a role to the
gateway / AWS KMS"). Use `--rpc-url https://rpc-bokuto.katanarpc.com` and **drop
`--legacy`**: Katana is EIP-1559.

## Providing the key and funding it

Use a **temporary** account that holds only testnet ETH.

```bash
mkdir -p ~/.gyld && chmod 700 ~/.gyld
(umask 077; pbpaste > ~/.gyld/katana-testnet-pk) && pbcopy </dev/null   # also clears the clipboard
stat -f %Lp ~/.gyld/katana-testnet-pk                                   # 600
```

- **Format.** The file holds the bare 64-hex key. A `0x` prefix and a trailing newline
  are tolerated.
- **Permissions.** The script refuses the file unless its mode is 600 or 400. Use
  `KATANA_TESTNET_PK_FILE=<path>` to keep it elsewhere.
- **Where the key goes.** The key reaches forge only through the environment
  (`KATANA_TESTNET_PK`). It never appears on a command line or in a log. The only file
  the script writes key material to is the chmod-600 derived-keys file.
- **Shell history.** Avoid `export KATANA_TESTNET_PK=…` at a prompt: it lands in your
  shell history.

**Funding.** `script-katana/deploy-katana-testnet.sh plan` prints the deployer address.
Get Bokuto ETH in one of two ways:

- bridge Sepolia ETH at https://bridge.katana.network;
- use the Katana Bokuto faucet, which needs an access code from the Katana team.

The preflight floor is `MIN_DEPLOYER_ETH` (default **0.02**). Explorer:
https://bokuto.katanascan.com.

## Steps

`script-katana/deploy-katana-testnet.sh [plan|keys|deploy|nav|smoke|verify|all]`. The
default is `all` = deploy + smoke + verify.

1. **Preflight.** Checks the tools, the key file's mode and format, and that the RPC
   (default `https://rpc-bokuto.katanarpc.com`, override with `RPC_URL`) is chain 737373.
   Then it derives the role plan and checks the deployer balance. Before broadcasting,
   the script asks you to type `broadcast`; `CONFIRM=1` skips the prompt.
2. **Keys.** Writes the derived-keys file (chmod 600). The script refuses to overwrite a
   file that was derived from a different deployer.
3. **Deploy.** One forge broadcast with `--slow`. There is **no `--legacy` and no fixed
   gas price**: Katana is EIP-1559 with an L1 data fee, so forge estimates the fees.
   1. Top up each role key to its ETH float.
   2. Deploy `MockSanctionsList` (CREATE2, owner = sanctions-admin).
   3. Run `DeployDevNet` with `TIMELOCK_DELAY_SECONDS=0`, `SANCTIONS_LIST` = the mock
      and every role pinned. Governance is not the deployer, so it stops after Phase 1,
      as on mainnet.
   4. Deploy `MockUSDC` (6dp, CREATE2).
   5. **Governance Phase 2** through the timelock: `factory.acceptOwnership`, then
      `deployToken` for CAT, C and KO.
   6. The NAV owner pushes **$1.00 = 1e8** to each feed. This must happen before
      `registerSeries`, which otherwise reverts `NavFeedNotPriced` (FIND-002).
   7. Run `DeployAtomicSettlement` with `USDC_ADDRESS` = MockUSDC, the three series and
      the dedicated role holders. Admin goes to the timelock.
   8. The whitelist admin whitelists the swap. The subscriber mints 1,000 of each series
      into the swap. The deployer mints 10,000 MockUSDC to the swap and 1,000 to the
      taker. The allowlist admin allowlists the taker.
4. **Smoke.** The quote signer signs a BUY quote (10 USDC → 10 CAT) and a REDEEM quote
   (10 CAT → 10 USDC), each valid for 85 s (the cap is 90 s). The taker executes both.
   Prices use the swap's convention, "tokenOut raw per 1e18 tokenIn raw", with the band
   value `usdc = tokens × nav / 1e20`. That gives BUY `1e38 / nav` (1e30 at $1.00) and
   REDEEM `nav / 100` (1e6 at $1.00), the same prices as `AtomicSettlementFlow.s.sol`.
5. **Verify** (read-only). Runs **68 on-chain assertions**:
   - every role holder, including the timelock's own roles;
   - the deployer holds no role;
   - the swap's cash token is MockUSDC with `decimals() == 6`;
   - feed ranges and bounds, forwarders, and series registration.

   It then rewrites the address file from what the chain returns.

**Keep-alive.** Run `nav` at least daily. Swaps refuse a NAV older than 24 h, and
`nav` re-pushes the current answer once 1 h has passed since the last push.

## Cost

Rehearsed on an Anvil fork of Bokuto (2026-10-14):

- **Deploy:** 58 transactions, 24.5 M gas.
- **Smoke:** 4 transactions, 0.45 M gas.
- **Verify:** 68/68.

At Bokuto's ~0.002 gwei the L2 execution cost is about 0.00005 ETH. The L1 data fee
comes on top; Anvil does not model it, but it is small on a Sepolia-settled chain. The
role floats total 0.0095 ETH and stay on those keys. A 0.02 ETH floor is generous.

## Dry run and rehearsal

- **`DRY_RUN=1`** simulates deploy + smoke + verify in one forge run against the live
  chain, with your real key and nonce. Nothing is sent.
- **Fork rehearsal** (real transactions, local only):

  ```bash
  anvil --fork-url https://rpc-bokuto.katanarpc.com --chain-id 737373 --port 8599 --silent &
  RPC_URL=http://127.0.0.1:8599 CONFIRM=1 script-katana/deploy-katana-testnet.sh all
  kill %1
  ```

  With a local RPC, the script keeps the fork's files separate from the real ones:
  - keys and addresses go to `*.fork.env`;
  - forge's broadcast journal goes to `$STATE_DIR/broadcast-fork`.

  A later real `RESUME=1` therefore cannot replay fork transactions. The script also
  mines a block before each step so that the fork's `latest` timestamp is current.

## Re-running safely

- **`deploy` refuses when the address file points at a live swap.** Use
  `nav`/`smoke`/`verify` on an existing stack. CREATE2 salts are chain- and name-based,
  so a second stack from the same commit collides. That collision is caught in
  simulation, before any gas is spent.
- **Interrupted broadcast:** run `RESUME=1 script-katana/deploy-katana-testnet.sh
  deploy`.
  - Forge resends only the missing transactions from
    `broadcast/KatanaTestnetStack.s.sol/737373/deploy-latest.json`.
  - `KATANA_STACK_RESUME` makes the script only register the 14 signers instead of
    re-deploying.
- **`smoke`** takes its quote ids from the block timestamp, so it can be re-run.
- **`verify`** is read-only and **`keys`** is deterministic.
- **The public RPC returns 504 on wide-range `eth_getLogs`.** Nothing here calls
  `eth_getLogs`. Any indexer pointed at Bokuto must page its log queries.

## Verifying contracts on katanascan

`VERIFY_CONTRACTS=1` adds `--verify --chain katana-bokuto` to the deploy broadcast.
`katana-bokuto` is the Etherscan V2 entry in `foundry.toml`, and it needs
`ETHERSCAN_API_KEY`. To verify afterwards:

```bash
forge verify-contract --chain katana-bokuto --watch <address> <path>:<ContractName> \
  --constructor-args <abi-encoded args>
```

## Gateway caveats

- **Address names.** `docs/deploy/katana-testnet-addresses.env` uses the gateway's
  names, for example `EVM_CHAIN_ID=737373`, `EVM_FACTORY_ADDRESS` and
  `USDC_CONTRACT_ADDRESS`.
- **Sanctions mock owner.** The mock is owned by sanctions-admin, not the gateway
  platform key. Use `SANCTIONS_ADMIN_PK` to flip addresses.
