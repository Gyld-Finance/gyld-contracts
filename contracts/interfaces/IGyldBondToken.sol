// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title IGyldBondToken — the primary-issuance surface `IssuanceManager` drives
/// @notice The two privileged supply operations. `IssuanceManager.subscribe` mints and
///         `redeem` burns through this interface; `GyldBondToken` declares it so the
///         compiler checks the pair rather than leaving it to a runtime revert.
/// @dev    Deliberately minimal — everything else `IssuanceManager` needs from a token
///         it reaches through `IERC20`. Both supply calls are `MINTER_ROLE`-gated on the
///         token and skip sanctions screening by design (APs are pre-screened off-chain).
interface IGyldBondToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;

    /// @notice Unix maturity of the series, or 0 for an open-ended series.
    /// @dev    Added for audit FIND-009 so `IssuanceManager.subscribe` can close primary
    ///         issuance at maturity. The token itself still does not enforce it — transfers
    ///         stay open after maturity so holders can exit. See `GyldBondToken` (D-30).
    function maturityTimestamp() external view returns (uint256);
}
