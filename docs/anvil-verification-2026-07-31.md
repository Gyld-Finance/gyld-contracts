# Live-Anvil verification of the hardened deploy path — 2026-07-31

First end-to-end execution of the GYL-1135 hardened deploy scripts against live nodes.
Until this run the hardening (`contracts/script/lib/DeployGuards.sol`, commits `df5043d`
and `8ce0f2e`) was covered only by `forge test`; no script had been broadcast to a real
chain. This document is the reproducible evidence that it works.

Branch `feat/testnet-erc8056-atomic-swap`, HEAD `8ce0f2e`. Foundry `forge 1.5.1-stable`.

**No source file was changed by this verification.** Every guard fired as designed; no
guard was weakened to make a run succeed. Three findings are recorded in
[§7 Findings](#7-findings) — one of them (F-2) is a real, still-live collision.

---

## How to reproduce

Everything below runs against **local Anvil only**. Three nodes are used because the
production-rule branches of the scripts are selected by `block.chainid`, and
`DeployGuards.isDevChain()` treats 31337/11155111 as dev. Running Anvil with
`--chain-id 8453` is still a local node — it just makes the scripts take the Base
(production) code path.

```bash
# terminal 1..3 — three LOCAL anvil nodes, nothing public is ever contacted
anvil --chain-id 31337    --port 8545      # dev rules
anvil --chain-id 11155111 --port 8546      # dev rules (Sepolia id) — CREATE2 A/B
anvil --chain-id 8453     --port 8547      # production rules (Base id), still local

# always confirm before broadcasting
cast chain-id --rpc-url http://127.0.0.1:8545     # => 31337
cast client   --rpc-url http://127.0.0.1:8547     # => anvil/v1.5.1  (proves it is local)
```

Anvil's published dev keys are used throughout. They are safe by construction — the
whole point of them being published — and appear nowhere outside a local node.

```bash
export RPC=http://127.0.0.1:8545
export DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266            # anvil acct[0]
export DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
export TAKER=0x70997970C51812dc3A010C7d01b50e0d17dc79C8               # anvil acct[1]
export TAKER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
export QUOTE_SIGNER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC        # anvil acct[2]
export QUOTE_SIGNER_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a
```

> **`.env` caveat — read this before reproducing.** `forge` auto-loads `.env` from the
> **current working directory**. This repo's `.env` sets `TIMELOCK_DELAY_SECONDS=0`
> (finding F-1). Every "env var unset" test below is therefore run from a scratch
> directory with `--root`, which is genuinely `.env`-free:
> ```bash
> cd /tmp/scratch && forge script DeployDevNet --root /path/to/gyld-contracts --rpc-url ...
> ```
> Guard 2c is the self-check: from a `.env`-free CWD it reports
> `TIMELOCK_DELAY_SECONDS is required`; from the repo root it would instead report
> `TIMELOCK_DELAY_SECONDS=0 is below the 172800s minimum`. Both are rejections, but only
> the first proves the var was truly absent.

---

## 1. Dev path — full stack on Anvil (chainId 31337)

```bash
forge script contracts/script/DeployDevNet.s.sol \
  --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
```

`ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.` — 21 txs, 14,703,292 gas total.
First tx `0x5baf180743116e16925e95398aa4e1495830adf892d45349f2e7f0edfc4d048b`,
last `0x8d4baadac3baea5314ecb700f7f4959b7948a7f5c1cd5c509901e91f0a020579`.

| output | address |
| --- | --- |
| `TIMELOCK_ADDRESS` (delay 0) | `0xc2A7267adaC02C49d89bAb9e9b0de1129dEc9652` |
| `ISSUANCE_MANAGER` | `0xb354b8522997B5b105D22814A129Ef843F7D731c` |
| `MOCK_SANCTIONS_ADDRESS` | `0xD42Ac90878F863A3202C8F83EC5793e1f991f8Ac` |
| `FACTORY_ADDRESS` | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` |
| `TOKEN_CAT` / `NAVFEED_CAT` / `FORWARDER_CAT` | `0xc8AD5B01DD6D5D7cEde50D7b7d1Eb1107a7289f6` / `0x23dB4a08f2272df049a4932a4Cc3A6Dc1002B33E` / `0x8EFa1819Ff5B279077368d44B593a4543280e402` |
| `TOKEN_C` | `0x8935AecA9db1ae44592aD89C12A7b392E2742239` |
| `TOKEN_KO` | `0x6e1112E3536DE2A34e03D7f222ef66AbE1336580` |

`Factory ownership accepted by timelock (delay=0, dev chain).` — the dev-only
schedule+execute path completed in-run, so all three bond tokens were deployed *through*
the timelock and their `DEFAULT_ADMIN_ROLE` is the timelock, never the deployer EOA.

Then MockUSDC, and **the NAV push first** (the documented gotcha: `executeSwap` fails
closed with `InvalidNav` until a positive NAV exists):

```bash
forge script contracts/script/DeployMockUSDC.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
#   USDC_CONTRACT_ADDRESS=0x59b670e9fA9D0A427751Af201D676719a970857b
cast send $NAVFEED_CAT "updateAnswer(int256)" 10000000000 --rpc-url $RPC --private-key $DEPLOYER_KEY
#   tx 0x3aae5fe66194b2d7360ecce206dbe3ea95f112735b3a8705ec86aec91c62e20b  gas 92128
cast call $FORWARDER_CAT "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $RPC
#   1 / 10000000000 / 1785478003 / 1785478003 / 1   ($100.00 at 8dp, visible through the forwarder)
cast call $FORWARDER_CAT "decimals()(uint8)" --rpc-url $RPC        # => 8  (registerSeries requires this)
```

### Settlement layer

```bash
export QUOTE_SIGNER=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC       # acct[2] — NOT the deployer
export TREASURER_ADDRESS=$DEPLOYER
export WITHDRAWAL_WALLET=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc  # acct[5] — distinct from treasurer
export OPS_MULTISIG=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65       # acct[4]
export ALLOWLIST_ADMIN=$DEPLOYER
export USDC_ADDRESS=0x59b670e9fA9D0A427751Af201D676719a970857b
export EVM_ISSUANCE_MANAGER=0xb354b8522997B5b105D22814A129Ef843F7D731c
export EVM_FACTORY_ADDRESS=0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
export TIMELOCK_ADDRESS=0xc2A7267adaC02C49d89bAb9e9b0de1129dEc9652
export SERIES_TOKENS=$TOKEN_CAT,$TOKEN_C,$TOKEN_KO
export ALLOWED_TAKERS=$TAKER

forge script contracts/script/DeployAtomicSettlement.s.sol \
  --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
```

`EVM_ATOMIC_SWAP=0xc56485e7e9F0dD4cd92D6B6f867A40fB89f12888` — 11 txs, 4,211,310 gas.
All three series registered, `withdrawalWallet` set, taker allowlisted,
`DEFAULT_ADMIN handed to timelock ... on swap`.

Inventory seeded through the unchanged mint-at-fill pipeline (the swap is a whitelisted AP):

```bash
cast send $EVM_ISSUANCE_MANAGER "subscribe(address,address,uint256)" $TOKEN_CAT $SWAP 100000000000000000000 ...
#   tx 0x8d04c4abec14cb6c0765e4cb3f6f45bc4bd70c89a8a1e5a3d11995209023522b
cast send $USDC_ADDRESS "transfer(address,uint256)" $SWAP 10000000000 ...
#   tx 0x1ec9c6d337d5c69dc62bff3bea433562aa7fb1277cf23f9f006b5ca183bd7873
```

Wiring verified by `cast call` against the live node:

```
usdc()                     = 0x59b670e9fA9D0A427751Af201D676719a970857b
quoteEpoch()               = 0
withdrawalWallet()         = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
maxQuoteDeviationBps()     = 200
registeredSeries(CAT)      = true
navForwarderOf(CAT)        = 0x8EFa1819Ff5B279077368d44B593a4543280e402
isAllowed(taker acct[1])   = true
IM.whitelisted(swap)       = true
DEFAULT_ADMIN(timelock)    = true
DEFAULT_ADMIN(deployer)    = false      <-- handover landed
QUOTE_SIGNER_ROLE(acct[2]) = true
```

---

## 2. A real BUY and a real REDEEM through `executeSwap`

Quotes are genuinely EIP-712 signed. The digest comes from the contract itself
(`hashSwapMessage` is the on-chain half of the signer-parity contract) and is signed raw
with `--no-hash`, because an EIP-712 digest must not be re-hashed or EIP-191 prefixed.

```bash
EXPIRY=$(( $(cast block latest --rpc-url $RPC --json | jq -r .timestamp | xargs printf '%d') + 900 ))
QUOTE="(1,$TAKER,$USDC_ADDRESS,1000000000,$TOKEN_CAT,10000000000000000000000000000,$EXPIRY,0)"
DIGEST=$(cast call $SWAP \
  "hashSwapMessage((uint256,address,address,uint256,address,uint256,uint64,uint64))(bytes32)" \
  "$QUOTE" --rpc-url $RPC)
SIG=$(cast wallet sign --no-hash $DIGEST --private-key $QUOTE_SIGNER_KEY)

cast send $USDC_ADDRESS "approve(address,uint256)" $SWAP 1000000000 --rpc-url $RPC --private-key $TAKER_KEY
cast send $SWAP \
  "executeSwap((uint256,address,address,uint256,address,uint256,uint64,uint64),bytes,(uint256,uint256,uint8,bytes32,bytes32),uint256)" \
  "$QUOTE" $SIG "(0,0,0,0x00..00,0x00..00)" 1000000000 \
  --rpc-url $RPC --private-key $TAKER_KEY
```

### BUY — USDC in, bond token out

```
QUOTE  = (1,0x7099…79C8,0x59b6…857b,1000000000,0xc8AD…89f6,10000000000000000000000000000,1785478956,0)
DIGEST = 0x889208d33432e0a14f3e098635b79508bb276c81ad61472c2a66ff0bd97ffb06
SIG    = 0x5781b42f58a296518e98af6e5de4a7a5228bf8b3d54aff49440afe92e3a63b03
         14e9d1ba3d7055aa6eede030c460a1680f4f0c15c243a9ed412b0dbc6d89ecf51b
approve  tx 0x2f629a3ac667d4224b9532b209314c2aaeff295ef4ca44bd6902cdaf5c939d6f
```

| | tx hash | status | gas |
| --- | --- | --- | --- |
| **BUY `executeSwap`** | `0xb834891ccc8128f4e545dbb0a5c7f527cd203fc3c7dce140acd0b7dec01f0452` | `0x1` | **181,973** (block 15) |

Balances, before → after:

| account | asset | before | after | delta |
| --- | --- | --- | --- | --- |
| taker | USDC | 100,000.000000 | 99,000.000000 | **−1,000** |
| taker | CAT | 0 | 10e18 | **+10** |
| swap | USDC | 10,000.000000 | 11,000.000000 | **+1,000** |
| swap | CAT | 100e18 | 90e18 | **−10** |
| — | CAT `totalSupply` | 100e18 | 100e18 | **unchanged** |

`isQuoteUsed(1)` → `true`. Emitted `SwapExecuted` (decoded from the receipt):

```
address   : 0xc56485e7e9f0dd4cd92d6b6f867a40fb89f12888
quoteId   : 1
taker     : 0x70997970c51812dc3a010c7d01b50e0d17dc79c8
tokenIn   : 0x59b670e9fa9d0a427751af201d676719a970857b   (USDC)
amountIn  : 1000000000                                    (1,000 USDC)
tokenOut  : 0xc8ad5b01dd6d5d7cede50d7b7d1eb1107a7289f6   (CAT)
amountOut : 10000000000000000000                          (10 CAT)
```

`totalSupply` unchanged is the load-bearing assertion: settlement moves existing
inventory and never mints or burns.

### REDEEM — bond token in, USDC out

```
REDEEM  = (2,0x7099…79C8,0xc8AD…89f6,10000000000000000000,0x59b6…857b,100000000,1785478956,0)
DIGEST2 = 0x718625c8719554b30eaad2cb68fd33fb149f9c1d20755a45f6a0f4a6c2a92a59
SIG2    = 0x3bf88fcc5b4e2cf74ea57832c3df13a23fa307c95e9ec51e7229502ced11c0ff
          6a5811171fef5068dfb50e7d9bcbba76cc897b897cdf1824896a52d002d739461b
approve   tx 0x7b07bfed5eea68f5c5c1cb0cf3d747e8f8c2ccae33a8f0c787a20682c62b9cb6
```

| | tx hash | status | gas |
| --- | --- | --- | --- |
| **REDEEM `executeSwap`** | `0x2bd78846ee366377f52525ef220c548611faff81d38991ac92abb13b065b8895` | `0x1` | **142,839** (block 17) |

| account | asset | before | after | delta |
| --- | --- | --- | --- | --- |
| taker | USDC | 99,000.000000 | **100,000.000000** | **+1,000 — made whole** |
| taker | CAT | 10e18 | 0 | **−10** |
| swap | USDC | 11,000.000000 | 10,000.000000 | **−1,000** |
| swap | CAT | 90e18 | 100e18 | **+10 — inventory returned** |
| — | CAT `totalSupply` | 100e18 | 100e18 | **unchanged** |

`isQuoteUsed(2)` → `true`. Emitted `SwapExecuted`:

```
quoteId   : 2
taker     : 0x70997970c51812dc3a010c7d01b50e0d17dc79c8
tokenIn   : 0xc8ad5b01dd6d5d7cede50d7b7d1eb1107a7289f6   (CAT)
amountIn  : 10000000000000000000                          (10 CAT)
tokenOut  : 0x59b670e9fa9d0a427751af201d676719a970857b   (USDC)
amountOut : 1000000000                                    (1,000 USDC)
```

### Treasurer withdraw — funds can only reach the admin-fixed wallet

| | tx hash | status | gas |
| --- | --- | --- | --- |
| `withdraw(USDC, 1000e6)` | `0x2405f674af80e3ab910993e0bb769a63c3bf4237f88da044f86261abfb521c27` | `0x1` | 68,965 |

```
withdrawalWallet (acct[5]) USDC : 0 -> 1000000000          <-- funds landed here
treasurer (deployer)       USDC : 90000000000 (unchanged)  <-- treasurer cannot redirect
swap                       USDC : 10000000000 -> 9000000000
```

### Runtime negative proofs (same live swap)

| attempt | revert |
| --- | --- |
| replay consumed `quoteId 1` | `QuoteAlreadyUsed(1)` |
| non-allowlisted taker (acct[3]) | `NotAllowed(0x90F79bf6EB2c4f870365E785982E1f101E93b906)` |
| price 10% above NAV (band is 2%) | `QuotePriceOutOfBand(1000000000, 1100000000)` |
| quote signed by a key without `QUOTE_SIGNER_ROLE` | `InvalidQuoteSigner(0x70997970C51812dc3A010C7d01b50e0d17dc79C8)` |
| `expiry` beyond `maxQuoteTtl` (3600s) | `QuoteExpiryTooFar(1785578161, 1785482137)` |

After all five, `isQuoteUsed(77/78/79)` are all `false` — no state moved.

---

## 3. The two self-contained Anvil scripts

Both hard-require chainId 31337 and both ran green against the live node.

```bash
forge script contracts/script/AtomicSettlementFlow.s.sol   --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
forge script contracts/script/DeployAtomicSettlementE2E.s.sol --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
```

`AtomicSettlementFlow` (25 txs, 14,356,191 gas) drove its own deploy → NAV → wire → seed
→ BUY → REDEEM → WITHDRAW with `require()` at every step and printed:

```
=== FLOW OK: deploy -> NAV -> wire -> seed -> BUY -> REDEEM -> WITHDRAW all asserted ===
```

`DeployAtomicSettlementE2E` (21 txs, 13,914,406 gas) left the chain at `quoteEpoch == 0`
for the Rust M7 golden:

```
E2E_SWAP=0x4631BCAbD6dF18D94796344963cB60d44a4136b6
E2E_TOKEN=0x162925C8BaA6BD9d06e55Ab54Bd244d7FB8B95e2
E2E_USDC=0xD84379CEae14AA33C123Af12424A37803F885889
E2E_NAVFEED=0xA4C8495ba6243F718Aa01cE75Dbd0b63EFCe6f71
E2E_FORWARDER=0xCE5bD920Ade95881D94a4A2d64f7df9E62468859
E2E_ISSUANCE_MANAGER=0xfbC22278A96299D91d41C453234d97b4F5Eb9B2d
E2E_WITHDRAWAL_WALLET=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
```

---

## 4. The guards refuse to do the unsafe thing (chainId 8453, local)

All of the following were run with `--broadcast` against the local 8453 node. **Every
one aborted during config resolution, before any gas was spent** — verified by
`cast nonce $DEPLOYER --rpc-url http://127.0.0.1:8547` still returning `0` afterwards.

### `DeployDevNet` — verbatim rejections

```
=========== GUARD 1: GOVERNANCE_MULTISIG unset on a production chain ===========
  [4866] DeployDevNet::run()
    ├─ [0] VM::envAddress("GOVERNANCE_MULTISIG") [staticcall]
    │   └─ ← [Revert] vm.envAddress: environment variable "GOVERNANCE_MULTISIG" not found
    ├─ [0] VM::toString(8453) [staticcall]
    │   └─ ← [Return] "8453"
    └─ ← [Revert] DeployGuards: env var GOVERNANCE_MULTISIG is required on chainId 8453
Error: script failed: DeployGuards: env var GOVERNANCE_MULTISIG is required on chainId 8453

### deployer nonce on 8453 after the attempt: 0
```

```
=========== GUARD 2: TIMELOCK_DELAY_SECONDS=0 on a production chain ===========
Error: script failed: DeployGuards: TIMELOCK_DELAY_SECONDS=0 is below the 172800s (48h) minimum on production chainId 8453

=========== GUARD 2b: TIMELOCK_DELAY_SECONDS=3600 (below 48h) ===========
Error: script failed: DeployGuards: TIMELOCK_DELAY_SECONDS=3600 is below the 172800s (48h) minimum on production chainId 8453

=========== GUARD 2c: TIMELOCK_DELAY_SECONDS unset on a production chain ===========
Error: script failed: DeployGuards: env var TIMELOCK_DELAY_SECONDS is required on chainId 8453

=========== GUARD 2d: SANCTIONS_LIST unset -> refuses to deploy a writable mock oracle ===========
Error: script failed: DeployGuards: env var SANCTIONS_LIST is required on chainId 8453

=========== GUARD 2e: GOVERNANCE_MULTISIG == deployer EOA (the Base incident shape) ===========
Error: script failed: DeployGuards: GOVERNANCE_MULTISIG must not be the deployer EOA (0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) on production chainId 8453

=========== GUARD 2f: SUBSCRIBER_ADDRESS == REDEEMER_ADDRESS (quorum split collapsed) ===========
Error: script failed: DeployGuards: SUBSCRIBER_ADDRESS and REDEEMER_ADDRESS must be different addresses on production chainId 8453 (single address defeats the split)

=========== GUARD 2g: SANCTIONS_LIST is an EOA (no code) ===========
Error: script failed: DeployGuards: SANCTIONS_LIST (0x000000000000000000000000000000000000dEaD) has no code - a contract is required on production chainId 8453
```

### `DeployAtomicSettlement` — verbatim rejections

```
=========== GUARD 3: TIMELOCK_ADDRESS unset on a production chain ===========
(previously this SILENTLY SKIPPED the handover, leaving the deployer permanent DEFAULT_ADMIN)
    └─ ← [Revert] DeployGuards: env var TIMELOCK_ADDRESS is required on chainId 8453
Error: script failed: DeployGuards: env var TIMELOCK_ADDRESS is required on chainId 8453

=========== GUARD 3b: TIMELOCK_ADDRESS set to an EOA (no code) ===========
Error: script failed: DeployGuards: TIMELOCK_ADDRESS (0x000000000000000000000000000000000000dEaD) has no code - a contract is required on production chainId 8453

=========== GUARD 3c: QUOTE_SIGNER == deployer EOA ===========
Error: script failed: DeployGuards: QUOTE_SIGNER must not be the deployer EOA (0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) on production chainId 8453

=========== GUARD 3d: WITHDRAWAL_WALLET == deployer EOA ===========
Error: script failed: DeployGuards: WITHDRAWAL_WALLET must not be the deployer EOA (0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) on production chainId 8453

=========== GUARD 3e: USDC_ADDRESS unset (required on EVERY chain) ===========
Error: script failed: DeployGuards: env var USDC_ADDRESS is required on chainId 8453
```

### Bonus: the CREATE2 vacancy pre-flight

Re-running a completed deploy names the clash instead of reverting mid-broadcast:

```
Error: script failed: DeployGuards: predicted CREATE2 address 0xd9CfE25fa85e161c5b156d0A7b1AC88AA441F12a
  for 'DeployDevNet:TimelockController' already has code on chainId 8453
Error: script failed: DeployGuards: predicted CREATE2 address 0xEDE8bE4Bb24b4CF121ee3A6EBf3Ff5bB2F27E485
  for 'DeployAtomicSettlement:GyldAtomicSwap.impl' already has code on chainId 8453
```

---

## 5. Production happy path (chainId 8453, local) — deployer ends up with nothing

A real `SanctionsOracleMirror` was deployed first, because production refuses both a mock
and a codeless address (guards 2d/2g). It stands in for the platform mirror here:

```bash
forge create contracts/SanctionsOracleMirror.sol:SanctionsOracleMirror \
  --rpc-url http://127.0.0.1:8547 --private-key $DEPLOYER_KEY --broadcast \
  --constructor-args 0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC \
                     0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f \
                     0x0000000000000000000000000000000000000000
#   Deployed to: 0x5FbDB2315678afecb367f032d93F642f64180aa3

export GOVERNANCE_MULTISIG=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
export OPS_MULTISIG=0x90F79bf6EB2c4f870365E785982E1f101E93b906
export SUBSCRIBER_ADDRESS=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
export REDEEMER_ADDRESS=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
export WHITELIST_ADMIN=0x976EA74026E726554dB657fA54763abd0C3a0aa9
export NAV_FEED_OWNER=0x14dC79964da2C08b23698B3D3cc7Ca32193d9955
export SANCTIONS_LIST=0x5FbDB2315678afecb367f032d93F642f64180aa3
export TIMELOCK_DELAY_SECONDS=172800

forge script contracts/script/DeployDevNet.s.sol \
  --rpc-url http://127.0.0.1:8547 --broadcast --private-key $DEPLOYER_KEY
```

Succeeded as **Phase 1** (13 txs, 8,915,416 gas): with a real 48h delay the in-run
`acceptOwnership` is correctly *not* attempted, and the script prints the Phase 2
run-book instead. `TIMELOCK_ADDRESS=0xd9CfE25fa85e161c5b156d0A7b1AC88AA441F12a`,
`ISSUANCE_MANAGER=0x40a866990c446D7ff6E1Be89224F393CF2B31262`. No `MOCK_SANCTIONS_ADDRESS`
line — the mock branch was never taken.

Verified independently with `cast call` against the local node (not script logs):

```
--- timelock is a real gate ---
timelock.getMinDelay()             = 172800          <- >= 48h
timelock PROPOSER(governance safe) = true
timelock PROPOSER(deployer)        = false           <- deployer proposes nothing
timelock CANCELLER(deployer)       = false
timelock DEFAULT_ADMIN(deployer)   = false
timelock EXECUTOR(address(0))      = true            <- open execute after the delay

--- IssuanceManager: deployer holds NOTHING ---
IM.hasRole(DEFAULT_ADMIN_ROLE,   deployer) = false
IM.hasRole(SUBSCRIBER_ROLE,      deployer) = false
IM.hasRole(REDEEMER_ROLE,        deployer) = false
IM.hasRole(WHITELIST_ADMIN_ROLE, deployer) = false
IM.hasRole(REGISTRAR_ROLE,       deployer) = false

--- intended holders ---
IM DEFAULT_ADMIN(timelock)   = true
IM SUBSCRIBER(0x15d3..6A65)  = true
IM REDEEMER(0x9965..A4dc)    = true
IM WHITELIST_ADMIN(0x976E..) = true

--- the publicly-known Anvil key is not an AP on production ---
IM.whitelisted(anvil acct[1]) = false

--- factory ownership: two-step, pending to the timelock (Phase 2 completes it) ---
factory.owner()        = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266   (deployer, pre-accept — see F-3)
factory.pendingOwner() = 0xd9CfE25fa85e161c5b156d0A7b1AC88AA441F12a   (timelock)
factory.sanctionsList()= 0x5FbDB2315678afecb367f032d93F642f64180aa3
```

### `DeployAtomicSettlement` production happy path

Same chain, `TIMELOCK_ADDRESS` + all five privileged addresses distinct and non-deployer.
8 txs, 3,817,477 gas. `EVM_ATOMIC_SWAP=0x58bE41E48329aFaaDF629F0799dd93DDf53f85B2`.

The script correctly declined to whitelist the swap itself, because on production the
deployer does *not* hold `WHITELIST_ADMIN_ROLE`:

```
!! Broadcaster lacks WHITELIST_ADMIN_ROLE - run via ops Safe:
   issuanceMgr.addToWhitelist(0x58bE41E48329aFaaDF629F0799dd93DDf53f85B2)
```

Verified on-chain:

```
swap DEFAULT_ADMIN(timelock)          = true
swap DEFAULT_ADMIN(deployer)          = false
swap ALLOWLIST_ADMIN_ROLE (deployer)  = false
swap PAUSER_ROLE          (deployer)  = false
swap TREASURER_ROLE       (deployer)  = false
swap QUOTE_SIGNER_ROLE    (deployer)  = false
ALLOWLIST_ADMIN 0x976E..0aa9 = true      PAUSER       0x90F7..b906 = true
TREASURER       0x15d3..6A65 = true      QUOTE_SIGNER 0x3C44..93BC = true
withdrawalWallet()           = 0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
IM.whitelisted(swap)         = false     (correct — needs the ops Safe)
```

`assertTimelockSane` ran against the real 172800s timelock and passed, so the handover
is provably not cosmetic.

---

## 6. CREATE2 collision fix (chainId 31337 vs 11155111)

Same script, same deployer key, `TIMELOCK_DELAY_SECONDS` pinned to `0` on **both** chains
so that `block.chainid` is the only differing input:

```bash
TIMELOCK_DELAY_SECONDS=0 forge script contracts/script/DeployDevNet.s.sol \
  --rpc-url http://127.0.0.1:8546 --broadcast --private-key $DEPLOYER_KEY
```

| contract | chainId 31337 | chainId 11155111 | differ? |
| --- | --- | --- | --- |
| `TimelockController` (CREATE2) | `0xc2A7267adaC02C49d89bAb9e9b0de1129dEc9652` | `0x260A4Decc21253A941c26135d73d922233a2480D` | **YES** |
| `IssuanceManager` proxy (CREATE2) | `0xb354b8522997B5b105D22814A129Ef843F7D731c` | `0x86dda747C7c4083704fAC94Ec888A9dA175Ed665` | **YES** |
| `MockSanctionsList` (CREATE2) | `0xD42Ac90878F863A3202C8F83EC5793e1f991f8Ac` | `0x16CF00c15c698d47ce02C91C2C1Ad66FAD549f04` | **YES** |
| `TokenFactory` (plain CREATE) | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` | `0x5FC8d32690cc91D4c39d9d3abcBD16989F875707` | **NO — see F-2** |

`MockSanctionsList` is the cleanest control: it takes no constructor arguments, so its
init code is byte-identical on both chains. The addresses differ purely because
`DeployGuards.saltFor` mixes in `block.chainid`:

```
saltFor('DeployDevNet:MockSanctionsList') @ 31337    = 0x21e7c0aaa1dc47410f8e7c69d12fad29b2f1d8a3339bdfcf4b6609d818dfb151
saltFor('DeployDevNet:MockSanctionsList') @ 11155111 = 0x1a0c0f4d5f4b19636edb1247719eb5f18a0c5269f0474000e26797bf9a1fb660
saltFor('DeployDevNet:MockSanctionsList') @ 8453     = 0x47b23d12a7ba944d9e5ec46f2249f291f5ef5d4d3672935681018216124a137c
```

**The fix works for every contract routed through CREATE2.**

---

## 7. Findings

### F-1 — `.env` ships `TIMELOCK_DELAY_SECONDS=0` (the exact incident value)

`forge` auto-loads `.env` from the CWD, and this repo's `.env` sets
`TIMELOCK_DELAY_SECONDS=0` — the precise value that produced the zero-delay Base
timelock. On a dev chain that is harmless (Anvil's dev default is 0 anyway). On a
production chain the guard catches it:

```
Error: script failed: DeployGuards: TIMELOCK_DELAY_SECONDS=0 is below the 172800s (48h) minimum on production chainId 8453
```

So the guard is doing exactly its job, and the residual risk is only that the value is
silently inherited rather than consciously chosen. Suggested follow-up: remove
`TIMELOCK_DELAY_SECONDS` from `.env` (or set it to `172800`) so a production run must
name the delay explicitly. Not changed here — `.env` is developer-local and untracked.

### F-2 — `TokenFactory` still collides across chains (pre-existing, documented, still live)

`TokenFactory` is the one bootstrap contract deliberately **not** routed through the
CREATE2 proxy (`DeployDevNet.s.sol:255-259`, because its `Ownable(msg.sender)` constructor
would make the shared proxy the permanent owner). It therefore still uses nonce-based
`CREATE` — and it empirically landed at the **identical address on all three chains**,
including across the dev/production split:

```
chainId 31337     TokenFactory@0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
    codehash      = 0x69e522240788c04301bb7c27fe3fd5883cfbde20d4fe25314efc850cfedb9d96
    sanctionsList = 0xD42Ac90878F863A3202C8F83EC5793e1f991f8Ac
    owner         = 0xc2A7267adaC02C49d89bAb9e9b0de1129dEc9652
chainId 11155111  TokenFactory@0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
    codehash      = 0x87d59c19964e19fe6742fbe028f8e543881cf72fa6a997dff0ca9658fdfd7e79
    sanctionsList = 0x16CF00c15c698d47ce02C91C2C1Ad66FAD549f04
    owner         = 0x260A4Decc21253A941c26135d73d922233a2480D
chainId 8453      TokenFactory@0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
    codehash      = 0xb6aeece8cdbba6425b2a06e9e6605ab04aebbbd969985768f4054a64736157a2
    sanctionsList = 0x5FbDB2315678afecb367f032d93F642f64180aa3
    owner         = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

The three **codehashes differ** (`sanctionsList` and `bondTokenLogic` are `immutable`, so
they are baked into runtime bytecode) — these are genuinely different contracts sharing
one address, which is exactly the `0x7c1798…70ad`-style collision class the CREATE2 work
set out to eliminate.

It is worth stressing how fragile the nonce path is: the 8453 run deployed a *different
set of contracts* from the 31337 run (a real `SanctionsOracleMirror` instead of a
`MockSanctionsList`) and the factory still landed on the same address, because the
deployer's nonce happened to coincide at 5.

The fix named in the existing code comment — give `TokenFactory` an explicit `owner_`
constructor parameter so it can go through the CREATE2 proxy — is a contract change and
was out of scope for GYL-1135 and for this verification. **F-2 is not a regression; it is
the known remaining hole, now demonstrated empirically rather than argued in a comment.**

### F-3 — on production the deployer holds `TokenFactory` ownership until Phase 2

With a real 48h delay, `factory.transferOwnership(timelock)` is only the first half of
`Ownable2Step`; `factory.owner()` remains the deployer EOA until governance executes
`acceptOwnership` after the delay. During that window the deployer can still call
`deployToken` and thereby choose `DEFAULT_ADMIN_ROLE` on newly created tokens.

This is intended and clearly documented in the script's Phase 2 output, and
`_assertFinalTopology` does enforce `pendingOwner == timelock`. Flagging it only because
"the deployer ends up holding no roles" is true of `IssuanceManager`, the swap and the
timelock, but *not* of factory ownership until Phase 2 completes. Worth an explicit line
in the production run-book.

### Non-finding — `cast wallet verify` rejects a valid EIP-712 signature

```
Error: Validation failed. Address 0x3C44…93BC did not sign this message.
```

Expected: `cast wallet verify` applies the EIP-191 prefix and re-hashes, whereas the
signature was produced over the raw EIP-712 digest with `--no-hash`. The contract
accepted both signatures and recovered the correct `QUOTE_SIGNER_ROLE` holder, which is
the authoritative check. Do not "fix" this by dropping `--no-hash`.

### Non-finding — `TimelockUnexpectedOperationState` with no `--rpc-url`

Running `forge script DeployDevNet` without `--rpc-url` reverts at the dev-path
`schedule`/`execute` pair:

```
Error: script failed: TimelockUnexpectedOperationState(0xdbf878…b3ab, 0x…04)
```

Cause: forge's bare local EVM starts at `block.timestamp == 1`, so with `delay == 0` the
scheduled op stores timestamp `1`, which equals OpenZeppelin's `_DONE_TIMESTAMP` sentinel
and makes `getOperationState` report `Done` instead of `Ready`. It cannot occur against a
real node (or Anvil), where `block.timestamp` is current unix time. Always pass
`--rpc-url` when running this script.

---

## 8. Test suite

```bash
forge test
# Ran 19 test suites: 511 tests passed, 0 failed, 0 skipped (511 total tests)
```

Unchanged from before this verification, as expected — no source file was modified.

---

## Summary

| # | Claim | Result |
| --- | --- | --- |
| 1 | Full dev stack deploys cleanly on Anvil 31337 | PASS |
| 2 | BUY settles with an EIP-712-signed quote; supply unchanged | PASS — `0xb834891c…` |
| 3 | REDEEM settles; taker made whole | PASS — `0x2bd78846…` |
| 4 | Treasurer withdraw reaches only the fixed wallet | PASS — `0x2405f674…` |
| 5 | `GOVERNANCE_MULTISIG` unset ⇒ production run reverts | PASS |
| 6 | `TIMELOCK_DELAY_SECONDS=0` rejected on production | PASS |
| 7 | `TIMELOCK_ADDRESS` unset ⇒ reverts, no silent skip | PASS |
| 8 | Production happy path: deployer holds no roles, 48h delay, not a proposer | PASS (except factory ownership, F-3) |
| 9 | CREATE2 addresses differ across chains | PASS for CREATE2 contracts; `TokenFactory` still collides (F-2) |
| 10 | `forge test` still 511 passing | PASS |

---

## Follow-up: ERC-8056 (historical)

This run did not touch the ERC-8056 (Scaled UI Amount) UI multiplier. That lifecycle was
verified separately against live Anvil in
[`anvil-verification-erc8056-2026-07-31.md`](anvil-verification-erc8056-2026-07-31.md)
(GYL-1136), which also numbers the ERC-8056 spec's own F-1/F-2/F-3 remediation items —
unrelated to the F-1/F-2/F-3 findings in [§7](#7-findings) above. The extension was
**subsequently dropped on EVM** (GYL-1201, 2026-08-03) and removed from the codebase; that
document is retained as a historical record only. See
[`decisions/erc8056-dropped-on-evm.md`](decisions/erc8056-dropped-on-evm.md).
