// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title IGyldBondToken — the primary-issuance surface `IssuanceManager` drives
/// @notice The two privileged supply operations. `IssuanceManager.subscribe` mints and
///         `redeem` burns through this interface; `GyldBondToken` declares it so the
///         compiler checks the pair rather than leaving it to a runtime revert.
/// @dev    Deliberately minimal — everything else `IssuanceManager` needs from a token
///         it reaches through `IERC20`. `mint` is `MINTER_ROLE`-gated and `burn` is
///         `BURNER_ROLE`-gated; both skip sanctions screening by design (APs are
///         pre-screened off-chain).
interface IGyldBondToken {
    /// @notice Mint `amount` tokens to `to`. `MINTER_ROLE` on the token.
    /// @dev    ALSO `whenNotPaused` on the token (audit FIND-005). That pause is independent
    ///         of `IssuanceManager`'s own, so a paused token reverts this call even when the
    ///         manager is running — and both raise OpenZeppelin's `EnforcedPause()`, whose
    ///         4-byte payload carries no contract identity, so the revert alone cannot say
    ///         which is set. Read `paused()` on each contract to tell them apart; a trace
    ///         also names the reverting frame. The remedies differ: `unpauseIssuance()` is
    ///         DEFAULT_ADMIN_ROLE behind a 48h timelock, `GyldBondToken.unpause()` is
    ///         PAUSER_ROLE on the ops multisig and immediate. See the runbook.
    function mint(address to, uint256 amount) external;

    /// @notice Burn `amount` tokens from `from`. `BURNER_ROLE` on the token.
    /// @dev    ALSO `whenNotPaused` on the token (audit FIND-005) — see {mint}. `redeem`
    ///         carries no pause of its own, so on that path the token's is the only one in
    ///         play and `EnforcedPause()` is unambiguous by elimination.
    function burn(address from, uint256 amount) external;

    /// @notice Unix maturity of the series, or 0 for an open-ended series.
    /// @dev    Added for audit FIND-009 so `IssuanceManager.subscribe` can close primary
    ///         issuance at maturity. The token itself still does not enforce it — transfers
    ///         stay open after maturity so holders can exit. See `GyldBondToken` (D-30).
    function maturityTimestamp() external view returns (uint256);
}
