# BSC testnet (chain 97) — DEV deploy runbook

GLD-713. BSC testnet is a **dev chain** exactly like Sepolia: `DeployGuards.isDevChain()`
returns true for 31337, 11155111 and 97 only. That means a zero timelock delay, the
`MockSanctionsList` compliance oracle and deployer fall-backs for every privileged role
are all accepted here. BSC **mainnet (56)** and opBNB (204) are NOT on the list and take
the strict production path.

The one real difference from Sepolia is the cash leg: there is no Circle USDC on BSC
testnet, and BNB-chain stablecoins are **18 decimals**. We deploy our own 18dp
**Gyld Test USD (gUSD)** with `DeployMockStablecoin.s.sol` and pass it as
`USDC_ADDRESS` (the env var keeps its historical name). `GyldAtomicSwap.initialize`
probes and stores the cash token's decimals (6..18 accepted, GLD-713).

For the background on each step (what the swap script does, why NAV comes first,
notional caps), see [`../atomic-settlement-testnet-runbook.md`](../atomic-settlement-testnet-runbook.md)
— this page only gives the BSC-testnet-specific sequence.

## 0. Prerequisites

| Item | Value |
|---|---|
| RPC | `https://bsc-testnet-rpc.publicnode.com` (also the `bsc_testnet` alias in `foundry.toml`) |
| Chain id | `97` — check with `cast chain-id --rpc-url $RPC` |
| Gas | tBNB from the BNB Chain faucet (https://www.bnbchain.org/en/testnet-faucet). **The faucet gives ~0.3 tBNB per day per address** — fund the deployer a day ahead, and also fund the NAV-feed-owner, subscriber, allowlist-admin and taker keys if they are distinct. |
| Explorer | https://testnet.bscscan.com — verification goes through the Etherscan V2 API with the normal `ETHERSCAN_API_KEY` (no separate BscScan key) |

```bash
export RPC=https://bsc-testnet-rpc.publicnode.com
export PRIVKEY=<deployer key>              # never commit or echo it
export WALLET=$(cast wallet address --private-key $PRIVKEY)
export ETHERSCAN_API_KEY=<etherscan v2 key>

cast chain-id --rpc-url $RPC               # expect 97
cast balance $WALLET --rpc-url $RPC --ether
python3 ci/check_chain_guards.py           # every deploy script carries an allowlist guard
```

### Environment variables

| Var | Script | Needed on 97? |
|---|---|---|
| `TIMELOCK_DELAY_SECONDS` | DeployDevNet | **Set to `0`.** The default is 0 only on Anvil; on 97 it defaults to 48 h and the script stops after Phase 1 (no bond tokens deployed). |
| `GOVERNANCE_MULTISIG`, `OPS_MULTISIG`, `SUBSCRIBER_ADDRESS`, `REDEEMER_ADDRESS`, `WHITELIST_ADMIN`, `NAV_FEED_OWNER` | DeployDevNet | Optional — fall back to the deployer (NAV_FEED_OWNER gets a derived address if it would collide with OPS_MULTISIG; read it from the script output). |
| `SANCTIONS_LIST` | DeployDevNet | **Leave unset** — a `MockSanctionsList` is deployed (`MOCK_SANCTIONS_ADDRESS`). `SANCTIONS_PROBE_FLAGGED` is unused on dev chains. |
| `MOCK_STABLE_DECIMALS` | DeployMockStablecoin | Optional, default `18` (6..18). |
| `MOCK_STABLE_MINT_TO` / `MOCK_STABLE_MINT_AMOUNT` | DeployMockStablecoin | Optional, default broadcaster / `1000000` whole gUSD. |
| `USDC_ADDRESS` | DeployAtomicSettlement | **Required** — the gUSD address from step 2. |
| `EVM_ISSUANCE_MANAGER`, `EVM_FACTORY_ADDRESS` | DeployAtomicSettlement | **Required** — step-1 outputs. |
| `SERIES_TOKENS`, `ALLOWED_TAKERS` | DeployAtomicSettlement | Optional; this runbook registers series in the script and allowlists the taker afterwards (step 6). |
| `TIMELOCK_ADDRESS`, `OPS_MULTISIG`, `TREASURER_ADDRESS`, `QUOTE_SIGNER`, `ALLOWLIST_ADMIN`, `WITHDRAWAL_WALLET` | DeployAtomicSettlement | Optional on 97 (deployer fall-back). Set `QUOTE_SIGNER` to the quote-service key and `TIMELOCK_ADDRESS` to the step-1 timelock so the stack mirrors Sepolia DEV. |
| `MAX_QUOTE_DEVIATION_BPS`, `MAX_NAV_AGE_SECS` | DeployAtomicSettlement | Optional (200 bps / 86400 s). |

## 1. Base stack — `DeployDevNet` (timelock delay 0)

```bash
TIMELOCK_DELAY_SECONDS=0 \
forge script contracts/script/DeployDevNet.s.sol \
  --rpc-url $RPC --broadcast --private-key $PRIVKEY --verify
```

Record from the output: `EVM_FACTORY_ADDRESS`, `EVM_ISSUANCE_MANAGER`,
`TIMELOCK_ADDRESS`, `MOCK_SANCTIONS_ADDRESS` (= gateway `CHAINALYSIS_SANCTIONS_CONTRACT`),
`TOKEN_CAT` / `TOKEN_C` / `TOKEN_KO` and their `NAVFEED_*`.

```bash
cast call $EVM_FACTORY_ADDRESS "forwarderOf(address)(address)" $TOKEN_CAT --rpc-url $RPC
# non-zero → record as FORWARDER_CAT (repeat per series)
```

## 2. Cash token — `DeployMockStablecoin` (18dp gUSD)

```bash
forge script contracts/script/DeployMockStablecoin.s.sol \
  --rpc-url $RPC --broadcast --private-key $PRIVKEY --verify
export USDC_ADDRESS=<printed USDC_ADDRESS>

cast call $USDC_ADDRESS "decimals()(uint8)" --rpc-url $RPC    # expect 18
```

The deployer is the token's permanent `minter`; nobody else can mint.

## 3. NAV publish — before the swap registers any series

`registerSeries` (run inside step 4) reverts `NavFeedNotPriced` for a feed that has
never been pushed (audit FIND-002), so publish NAV **first**. Sender = `NAV_FEED_OWNER`.

```bash
# $1.00 at 8 decimals — NAV is 8dp regardless of the cash token's decimals
cast send $NAVFEED_CAT "updateAnswer(int256)" 100000000 \
  --rpc-url $RPC --private-key $NAV_FEED_OWNER_KEY
cast call $FORWARDER_CAT "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC
# second value 100000000, fourth value a recent timestamp
```

Repeat per series. The keeper must keep pushing more often than `MAX_NAV_AGE_SECS`
or every swap reverts `StaleNav`.

## 4. Swap — `DeployAtomicSettlement` (+ whitelist series)

One broadcast: proxy deploy + initialize (probes gUSD → 18dp) → whitelists the swap as
an AP on IssuanceManager → `registerSeries` for each `SERIES_TOKENS` entry → withdrawal
wallet → `ALLOWLIST_ADMIN_ROLE` → DEFAULT_ADMIN handover to `TIMELOCK_ADDRESS`.

```bash
export EVM_ISSUANCE_MANAGER=<step 1>
export EVM_FACTORY_ADDRESS=<step 1>
export TIMELOCK_ADDRESS=<step 1>
export SERIES_TOKENS=$TOKEN_CAT,$TOKEN_C,$TOKEN_KO
export QUOTE_SIGNER=<quote-service signer address>
# OPS_MULTISIG / TREASURER_ADDRESS / ALLOWLIST_ADMIN / WITHDRAWAL_WALLET: deployer if unset

forge script contracts/script/DeployAtomicSettlement.s.sol \
  --rpc-url $RPC --broadcast --private-key $PRIVKEY --verify
export SWAP=<printed EVM_ATOMIC_SWAP>

cast call $SWAP "usdc()(address)" --rpc-url $RPC                          # $USDC_ADDRESS
cast call $SWAP "registeredSeries(address)(bool)" $TOKEN_CAT --rpc-url $RPC # true
cast call $EVM_ISSUANCE_MANAGER "whitelisted(address)(bool)" $SWAP --rpc-url $RPC  # true
```

A series added later is a `registerSeries(token, forwarder)` call by DEFAULT_ADMIN —
after the handover that is a timelock schedule + execute (delay 0 here, so both can
run back to back).

## 5. Fund inventory (bond tokens) and cash (gUSD)

```bash
# 100 CAT (18dp) minted straight into the swap — sender holds SUBSCRIBER_ROLE
cast send $EVM_ISSUANCE_MANAGER "subscribe(address,address,uint256)" \
  $TOKEN_CAT $SWAP 100000000000000000000 \
  --rpc-url $RPC --private-key $SUBSCRIBER_KEY

# 10,000 gUSD — 18 decimals, NOT 6: 10000 * 1e18
cast send $USDC_ADDRESS "transfer(address,uint256)" $SWAP 10000000000000000000000 \
  --rpc-url $RPC --private-key $PRIVKEY
# (or mint more first: cast send $USDC_ADDRESS "mint(address,uint256)" <to> <raw> --private-key $PRIVKEY)

cast call $TOKEN_CAT "balanceOf(address)(uint256)" $SWAP --rpc-url $RPC
cast call $USDC_ADDRESS "balanceOf(address)(uint256)" $SWAP --rpc-url $RPC
```

Every gUSD amount (quotes, approvals, funding, caps such as
`setMaxNavRoundNotionalFor`) is in the token's own 18dp units — copying a 6dp figure
from the Sepolia runbook under-funds by 10^12.

## 6. Allowlist the taker — `setAllowed`

Sender holds `ALLOWLIST_ADMIN_ROLE` (deployer if `ALLOWLIST_ADMIN` was unset; the role
survives the timelock handover).

```bash
cast send $SWAP "setAllowed(address,bool)" $TAKER true \
  --rpc-url $RPC --private-key $ALLOWLIST_ADMIN_KEY
cast call $SWAP "isAllowed(address)(bool)" $TAKER --rpc-url $RPC   # true
```

(Alternatively pass `ALLOWED_TAKERS=$TAKER` to step 4.) The taker also needs tBNB for
gas and gUSD for a buy.

## Verifying contracts manually

`--verify` on each script normally suffices. If it fails (rate limit, flaky RPC),
verify after the fact — Foundry resolves the `bsc-testnet` `[etherscan]` entry from
the chain id:

```bash
forge verify-contract --chain 97 --watch \
  <address> contracts/test/GyldTestUSD.sol:GyldTestUSD \
  --constructor-args $(cast abi-encode "constructor(uint8,address)" 18 $WALLET)

forge verify-contract --chain 97 --watch <address> <path>:<ContractName> \
  --constructor-args <abi-encoded args>
```

Use `--chain 97` (or `--chain bsc-testnet`, hyphenated — `bsc_testnet` is rejected as
a chain name; it is only the RPC alias).

## Gateway env (DEV on 97)

Point the gateway's EVM chain at 97 with the outputs above: `EVM_FACTORY_ADDRESS`,
`EVM_ISSUANCE_MANAGER`, `EVM_ATOMIC_SWAP=$SWAP`, `CHAINALYSIS_SANCTIONS_CONTRACT=$MOCK_SANCTIONS_ADDRESS`,
cash token `$USDC_ADDRESS` — and make sure the gateway's cash-amount handling uses the
token's 18 decimals, not a hard-coded 6.
