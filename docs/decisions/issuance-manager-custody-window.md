# IssuanceManager: Custody Window and Token Recovery

## The custody window

The redemption flow in `IssuanceManager` has a two-step structure:

```
Step 1 — AP transfers bond tokens → IssuanceManager address
         (a standard ERC-20 transfer; the AP initiates this voluntarily)

Step 2 — Backend calls redeem(token, beneficiary, amount)
         → IssuanceManager burns from its own balance
         → Backend sends USDC to the AP off-chain
```

Between Step 1 and Step 2, bond tokens sit inside `IssuanceManager`. The AP has already given up custody of their tokens; the backend has not yet burned them. This gap is the **custody window**.

If the backend never executes Step 2 — due to signing key loss, software bug, or infrastructure failure — those tokens are permanently locked inside the contract with no on-chain recovery path by default.

---

## Industry research

Whether a platform needs a recovery function depends entirely on whether tokens physically sit in a contract during redemption. Research across comparable tokenized securities platforms confirms a clear split:

| Platform | Architecture | Tokens in contract? | Recovery function |
|---|---|---|---|
| **Backed Finance** (bIB01, xStocks) | EOA-based — users send tokens to a Backed-controlled wallet address; burner key burns from that wallet | No | None needed |
| **Superstate** (USTB) | Atomic — user calls `offchainRedeem()`, tokens burned immediately from caller | No | None needed |
| **Ondo Finance** (OUSG) | `OUSGInstantManager` — OUSG transferred to the contract, briefly held, then burned | Yes | `retrieveTokens(address token, address to, uint256 amount)` — `DEFAULT_ADMIN_ROLE` |
| **OpenEden** (TBILL) | Queue-based vault — shares sit in the vault from request until operator processes queue (can be days) | Yes | `offRampQ(address token, uint256 amount)` — operator role |

**Our `IssuanceManager` matches Ondo and OpenEden architecturally** — tokens physically transit the contract. Both platforms added a recovery function specifically because of this custody exposure. Ondo's Code4rena 2024 audit explicitly called `retrieveTokens` an intentional design feature.

---

## Decision: add `retrieveTokens()`

We add:

```solidity
function retrieveTokens(address token, address to, uint256 amount)
    external
    onlyRole(DEFAULT_ADMIN_ROLE)
```

Gated by `DEFAULT_ADMIN_ROLE`, which is held by the `TimelockController` in production (48-hour minimum delay). Any rescue operation must be scheduled through the timelock and wait the full delay before execution — the AP and the public can observe the scheduled operation and react if anything looks wrong.

---

## Security model

`retrieveTokens` adds **zero new attack surface** compared to the UUPS upgrade path:

- `DEFAULT_ADMIN_ROLE` (TimelockController) can already deploy an arbitrary new implementation via `upgradeToAndCall`.
- A malicious upgrade can drain every token, reassign all roles, and corrupt all storage.
- `retrieveTokens` is strictly less powerful — it can only transfer ERC-20 tokens to a specified address.

Both paths require the same gate (TimelockController, 48h delay). `retrieveTokens` is simpler and safer to execute under incident conditions because it requires no new contract deployment and carries no storage-layout risk.

---

## Operator runbook: backend loses ISSUER_ROLE key with tokens in custody

If the backend signing key is lost while tokens are sitting in `IssuanceManager`:

1. **Identify affected tokens**: Query `Transfer` events to `IssuanceManager` address where no matching `Redeemed` event followed. Record `(token, amount, AP address)` for each stuck position.

2. **Do not attempt a forced burn**: `BURNER_ROLE` on each `GyldBondToken` is held by `IssuanceManager`, not by the timelock. A governance upgrade of `IssuanceManager` would be required to burn from the contract itself. Use `retrieveTokens` instead — return tokens to the AP, let them re-initiate redemption once the signing key is restored.

3. **Schedule the rescue through the TimelockController**:
   ```solidity
   timelock.schedule(
       address(issuanceManager),
       0,
       abi.encodeCall(IssuanceManager.retrieveTokens, (tokenAddress, apAddress, amount)),
       bytes32(0),   // predecessor
       salt,         // unique per operation
       48 hours      // minimum delay
   );
   ```

4. **Wait 48 hours**, then execute:
   ```solidity
   timelock.execute(address(issuanceManager), 0, data, bytes32(0), salt);
   ```

5. **Return tokens to the AP**: `retrieveTokens` sends tokens to the specified `to` address. Set `to` to the AP's original wallet or a governance-held multisig pending AP contact.

6. **Restore the ISSUER_ROLE key** (new MPC wallet or restored key) before allowing the AP to re-initiate redemption.

---

## What was intentionally not added

- **No `cancel` function**: There is no mechanism for the backend or admin to unilaterally cancel a redemption and return tokens to the AP before the custody window. The AP voluntarily sent tokens to initiate redemption; only governance (via `retrieveTokens` + timelock) can return them. This prevents operator abuse.
- **No `emergencyBurn`**: Direct burn from `IssuanceManager` balance without AP consent would destroy the AP's asset without settling USDC. Not acceptable for a regulated product.
- **No `multiexcall`**: Ondo's general-purpose admin escape hatch (`multiexcall` — arbitrary calls from contract context) was considered and rejected. Our trust model is fail-closed; a general-purpose admin escape hatch is inconsistent with that posture.
