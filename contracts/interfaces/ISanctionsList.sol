// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

/// @title ISanctionsList — read interface for an on-chain sanctions oracle
/// @notice The shape `GyldBondToken` screens every secondary transfer against, and the
///         shape `SanctionsOracleMirror` implements. Matches the Chainalysis on-chain
///         oracle (mainnet `0x40C57923924B5c5c5455c48D93317139ADDaC8fb`) so either can
///         be installed without a code change.
///
/// @dev    This declaration is deliberately SHARED rather than repeated per file. It
///         used to be written out twice — once in `GyldBondToken.sol`, once in
///         `SanctionsOracleMirror.sol`. Identical text, but Solidity types are
///         per-declaration, so those were two unrelated types and the compiler could
///         not check them against each other. Renaming the implementation compiled
///         cleanly; only a test caught it (audit §4.8). With one declaration imported
///         by caller and implementer alike, that drift is a build failure.
///
///         Keep `SanctionsOracleMirror is ISanctionsList` in place — inheriting the
///         interface is what makes the compiler enforce the match. A contract that
///         merely happens to expose `isSanctioned` proves nothing.
interface ISanctionsList {
    /// @param addr Address to screen.
    /// @return True if `addr` appears on the oracle's sanctions list.
    function isSanctioned(address addr) external view returns (bool);
}
