# ERC4626 Compatibility — GyldBondToken

## Summary

GyldBondToken is a standard ERC-20. Any third party (or Gyld itself) can build an ERC4626
vault using GyldBondToken as the underlying `asset()` with no changes to existing contracts.

---

## How the Stack Works

```
Vault Share Token (ERC-20)   ← freely tradeable, no compliance restrictions
ERC4626 Vault Contract       ← holds GyldBondToken, issues/burns shares
GyldBondToken (ERC-20)       ← underlying asset, unchanged
```

- Depositing GyldBondToken mints vault shares proportionally.
- Redeeming vault shares returns GyldBondToken from the vault.
- Vault shares are plain ERC-20 tokens — they carry none of GyldBondToken's
  pause or sanctions mechanics and can be traded freely on secondary markets.

---

## Compatibility Confirmation

| Capability | Status |
|---|---|
| ERC4626 vault using GyldBondToken as `asset()` | Fully compatible |
| Vault `deposit()` / `withdraw()` calling `transferFrom` / `transfer` | Works — vault and user addresses pass sanctions check |
| Secondary market trading of vault shares | Unrestricted — no GyldBondToken transfer involved |
| Redeeming vault shares back to GyldBondToken | Works — sanctions check fires on redeemer at exit |

---

## Buying and Selling Vault Shares

Vault shares are a separate ERC-20 issued by the vault — they carry none of
GyldBondToken's compliance mechanics. This makes them freely tradeable.

**Secondary market (DEX / OTC):**
- Buying or selling vault shares involves no GyldBondToken transfer.
- No sanctions check, no pause dependency, no whitelist.
- Vault shares can be listed on any DEX or traded OTC without restriction.

**Minting shares (deposit path):**
- User calls `vault.deposit(amount, receiver)`.
- Vault calls `gyldToken.transferFrom(user, vault, amount)`.
- Sanctions check fires on the user and vault address at this point.

**Burning shares (redeem path):**
- User calls `vault.redeem(shares, receiver, owner)`.
- Vault calls `gyldToken.transfer(receiver, amount)`.
- Sanctions check fires on the receiver at this point.

**Compliance note for legal/compliance team:** A sanctioned address can buy vault
shares on a secondary market and hold economic exposure to the bond without triggering
the Chainalysis oracle — the oracle only fires at deposit and redemption, not during
share-to-share transfers. Whether this is acceptable is a compliance decision, not a
technical one. The system behaves as designed.

---

## Known Upstream Properties

Vault builders must document these as upstream risk (not vault bugs):

- **Pause:** If GyldBondToken is paused by the ops multisig, vault deposits and
  withdrawals freeze until unpaused. This is intentional by design — same behaviour
  as USDC or any other pausable ERC-20.
- **Sanctions check:** Users must not be on the Chainalysis sanctions list to deposit
  or redeem. The check fires on `transfer` / `transferFrom` at the GyldBondToken layer.
  Vault share trading between two non-sanctioned parties is unaffected.

---

## What Needs to Be Built

No changes to existing Gyld contracts are required. A vault builder needs only:

1. An ERC4626 contract (OpenZeppelin `ERC4626.sol` is sufficient) with
   `asset()` returning the GyldBondToken proxy address.
2. Documentation of the pause and sanctions upstream properties for vault users.

The NAVFeedForwarder (Chainlink-compatible oracle) is already deployed and can be
used by lending protocols to price vault share collateral independently of the vault's
`totalAssets()`.
