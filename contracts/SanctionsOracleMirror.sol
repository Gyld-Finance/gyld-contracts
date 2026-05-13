// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title  SanctionsOracleMirror
/// @notice Production-grade mirror of the Chainalysis on-chain sanctions oracle
///         (mainnet: 0x40C57923924B5c5c5455c48D93317139ADDaC8fb).
///
///         Deploy on chains where Chainalysis has not deployed their own oracle
///         (e.g. Mantle L2). A keeper bot holding SANCTIONS_UPDATER_ROLE polls
///         the OFAC SDN CSV every 4 hours and calls addToSanctionsList /
///         removeFromSanctionsList with deltas.
///
///         Interface compatibility: identical function signatures and events to
///         the real Chainalysis oracle so GyldBondToken._requireAccess() and any
///         external tooling work without modification on any chain.
///
///         Access control differs from the real oracle (which uses Ownable with a
///         single Chainalysis-controlled key). We use AccessControl so:
///           - SANCTIONS_UPDATER_ROLE  → keeper bot hot wallet (write-only)
///           - DEFAULT_ADMIN_ROLE      → compliance ops multisig (Gnosis Safe)
///         This lets the keeper rotate without a governance vote and lets
///         compliance revoke a compromised keeper without touching admin keys.
contract SanctionsOracleMirror is AccessControl {
    bytes32 public constant SANCTIONS_UPDATER_ROLE = keccak256("SANCTIONS_UPDATER_ROLE");

    mapping(address => bool) private _sanctioned;

    // Identical events to the real Chainalysis oracle for tooling compatibility.
    event SanctionedAddressesAdded(address[] addrs);
    event SanctionedAddressesRemoved(address[] addrs);

    error ZeroAddress();
    error CannotRenounceAdminRole();

    constructor(address admin, address updater) {
        if (admin == address(0) || updater == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE,      admin);
        _grantRole(SANCTIONS_UPDATER_ROLE,  updater);
    }

    // ── Chainalysis-compatible read interface ─────────────────────────────────

    /// @notice Returns "Chainalysis sanctions oracle" — matches the real oracle's
    ///         name() so any tooling that checks the name still works.
    function name() external pure returns (string memory) {
        return "Chainalysis sanctions oracle";
    }

    /// @notice Returns true if `addr` is on the sanctions list.
    function isSanctioned(address addr) public view returns (bool) {
        return _sanctioned[addr];
    }

    // ── Keeper write interface (SANCTIONS_UPDATER_ROLE) ───────────────────────

    /// @notice Add addresses to the sanctions list.
    ///         Called by the keeper bot when new OFAC designations are published.
    function addToSanctionsList(address[] calldata addrs)
        external
        onlyRole(SANCTIONS_UPDATER_ROLE)
    {
        for (uint256 i = 0; i < addrs.length;) {
            if (addrs[i] == address(0)) revert ZeroAddress();
            _sanctioned[addrs[i]] = true;
            unchecked { i++; }
        }
        emit SanctionedAddressesAdded(addrs);
    }

    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    /// @notice Remove addresses from the sanctions list.
    ///         Called by the keeper bot when OFAC removes a designation.
    function removeFromSanctionsList(address[] calldata addrs)
        external
        onlyRole(SANCTIONS_UPDATER_ROLE)
    {
        for (uint256 i = 0; i < addrs.length;) {
            if (addrs[i] == address(0)) revert ZeroAddress();
            _sanctioned[addrs[i]] = false;
            unchecked { i++; }
        }
        emit SanctionedAddressesRemoved(addrs);
    }
}
