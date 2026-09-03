// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ISanctionsList} from "./interfaces/ISanctionsList.sol";

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
///           - SANCTIONS_UPDATER_ROLE  → Forefi/MPC wallet (write-only); refreshes sanctions list weekly/per epoch
///           - DEFAULT_ADMIN_ROLE      → compliance ops multisig (Gnosis Safe)
contract SanctionsOracleMirror is ISanctionsList, AccessControl {
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
    error CannotRemoveLastAdmin(); // audit FIND-007
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

    /// @notice Gas budget forwarded to the forwarding oracle per call.
    ///         Sized to cover a cold SLOAD + event + overhead with headroom.
    ///         Keeps a misbehaving/compromised oracle from burning the caller's
    ///         entire gas and bricking all secondary transfers.
    uint256 public constant FORWARDING_GAS = 40_000;

    /// @notice Returns true if `addr` is sanctioned on the local list OR on the
    ///         forwarding oracle (if configured). Fail-closed: reverts if the
    ///         forwarding oracle call reverts or returns malformed data.
    function isSanctioned(address addr) public view returns (bool) {
        if (_sanctioned[addr]) return true;
        ISanctionsList fwd = forwardingOracle;
        if (address(fwd) == address(0)) return false;
        // Low-level staticcall: caps gas, bounds returndata to 32 bytes,
        // decodes canonically (non-zero word = true; wrong length = revert).
        (bool ok, bytes memory data) = address(fwd).staticcall{gas: FORWARDING_GAS}(
            abi.encodeWithSelector(ISanctionsList.isSanctioned.selector, addr)
        );
        if (!ok || data.length != 32) revert InvalidForwardingOracle(address(fwd));
        return abi.decode(data, (bool));
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

    /// @dev Audit FIND-007. `renounceRole` above refuses DEFAULT_ADMIN_ROLE, but the role
    ///      admins itself, so the sole holder could self-revoke into the same bricked state.
    ///      Guarding `_revokeRole` covers both paths. Removing a NON-last admin is untouched
    ///      — that is the deploy handover (grant successor, then self-revoke).
    ///      `<= 1` not `== 1`: a proxy upgraded to this code never wrote the slot, so it reads
    ///      0 while holding one admin; blocking there is the safe direction.
    uint256 public defaultAdminCount;

    function _grantRole(bytes32 r, address a) internal override returns (bool granted) {
        granted = super._grantRole(r, a);
        if (granted && r == DEFAULT_ADMIN_ROLE) defaultAdminCount++;
    }

    function _revokeRole(bytes32 r, address a) internal override returns (bool revoked) {
        revoked = super._revokeRole(r, a);
        if (revoked && r == DEFAULT_ADMIN_ROLE) {
            if (defaultAdminCount <= 1) revert CannotRemoveLastAdmin();
            defaultAdminCount--;
        }
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
            // Probe: must implement isSanctioned(address) and return a
            // canonically-decodable bool. Uses the same gas cap and decode
            // logic as the runtime path so a probe-passing oracle cannot
            // revert or return garbage at call time.
            (bool ok, bytes memory data) = newOracle.staticcall{gas: FORWARDING_GAS}(
                abi.encodeWithSelector(ISanctionsList.isSanctioned.selector, address(0))
            );
            if (!ok || data.length != 32) revert InvalidForwardingOracle(newOracle);
            abi.decode(data, (bool)); // canonical bool check — reverts on non-zero word > 1
        }
        emit ForwardingOracleUpdated(address(forwardingOracle), newOracle);
        forwardingOracle = ISanctionsList(newOracle);
    }
}
