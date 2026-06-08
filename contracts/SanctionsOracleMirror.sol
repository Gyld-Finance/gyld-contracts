// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @dev Minimal read interface shared by Chainalysis oracle and this contract.
interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}

/// @title  SanctionsOracleMirror
/// @notice Self-owned sanctions oracle for Gyld bond tokens.
///
///         Maintains a local sanctions list (OFAC SDN + EU + UN designations)
///         that is kept current by a keeper bot holding SANCTIONS_UPDATER_ROLE.
///
///         Composite forwarding: if a forwardingOracle is configured, isSanctioned()
///         checks the local list first, then the forwarding oracle. Returns true if
///         either source flags the address. This lets us inherit a frozen upstream
///         oracle (e.g. the deprecated Chainalysis contract) while building up our
///         own complete list — then zero out forwardingOracle once the local list
///         is self-sufficient.
///
///         Chains where Chainalysis was never deployed (e.g. Mantle L2): deploy
///         with forwardingOracle = address(0) and seed the full historical list via
///         the initial backfill script.
///
///         Interface compatibility: identical function signatures and events to
///         the Chainalysis oracle so GyldBondToken._requireAccess() works unchanged.
///
///         Access control:
///           - SANCTIONS_UPDATER_ROLE  → keeper bot hot wallet (write-only)
///           - DEFAULT_ADMIN_ROLE      → compliance ops multisig (Gnosis Safe)
contract SanctionsOracleMirror is AccessControl {
    bytes32 public constant SANCTIONS_UPDATER_ROLE = keccak256("SANCTIONS_UPDATER_ROLE");

    mapping(address => bool) private _sanctioned;

    /// @notice External oracle to forward lookups to after checking the local list.
    ///         Set to address(0) to disable forwarding (local list only).
    ///         While set, every isSanctioned() call makes one external staticcall.
    ///         Fail-closed: if the forwarding oracle reverts, isSanctioned() reverts.
    ISanctionsList public forwardingOracle;

    // Identical events to the Chainalysis oracle for tooling compatibility.
    event SanctionedAddressesAdded(address[] addrs);
    event SanctionedAddressesRemoved(address[] addrs);
    /// @notice Emitted when the forwarding oracle is changed (including zeroed out).
    event ForwardingOracleUpdated(address indexed previous, address indexed next);

    error ZeroAddress();
    error CannotRenounceAdminRole();
    error InvalidForwardingOracle(address addr);
    error SelfReferenceOracle();

    constructor(address admin, address updater, address forwardingOracle_) {
        if (admin == address(0) || updater == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE,      admin);
        _grantRole(SANCTIONS_UPDATER_ROLE,  updater);
        if (forwardingOracle_ != address(0)) {
            _setForwardingOracle(forwardingOracle_);
        }
    }

    // ── Chainalysis-compatible read interface ─────────────────────────────────

    /// @notice Returns "Gyld sanctions oracle".
    function name() external pure returns (string memory) {
        return "Gyld sanctions oracle";
    }

    /// @notice Returns true if `addr` is sanctioned on the local list OR on the
    ///         forwarding oracle (if configured). Fail-closed: reverts if the
    ///         forwarding oracle call reverts.
    function isSanctioned(address addr) public view returns (bool) {
        if (_sanctioned[addr]) return true;
        ISanctionsList fwd = forwardingOracle;
        if (address(fwd) == address(0)) return false;
        return fwd.isSanctioned(addr);
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
    ///         Note: if an address is still flagged by the forwardingOracle,
    ///         isSanctioned() will continue to return true until forwarding is
    ///         disabled. This is intentional — the forwarding oracle is a
    ///         secondary source of truth, not overridden by local removals.
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

    // ── Forwarding oracle management (DEFAULT_ADMIN_ROLE) ─────────────────────

    /// @notice Replace or disable the forwarding oracle.
    /// @param  newOracle  New oracle address, or address(0) to disable forwarding.
    ///                    IMPORTANT: setting to address(0) drops all addresses
    ///                    inherited from the forwarding oracle. Only do this once
    ///                    the local list is fully seeded and reconciled.
    ///                    In production this call should go through the
    ///                    TimelockController — treat it as governance-weight.
    function setForwardingOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setForwardingOracle(newOracle);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    function _setForwardingOracle(address newOracle) internal {
        if (newOracle == address(this)) revert SelfReferenceOracle();
        if (newOracle != address(0)) {
            // Probe: must implement isSanctioned(address) returning a bool.
            // Rejects EOAs, wrong contracts, and self-destructed addresses.
            (bool ok, bytes memory data) = newOracle.staticcall(
                abi.encodeWithSelector(ISanctionsList.isSanctioned.selector, address(0))
            );
            if (!ok || data.length != 32) revert InvalidForwardingOracle(newOracle);
        }
        emit ForwardingOracleUpdated(address(forwardingOracle), newOracle);
        forwardingOracle = ISanctionsList(newOracle);
    }
}
