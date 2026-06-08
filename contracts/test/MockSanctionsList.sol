// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Writable mock of the Chainalysis SanctionsList for Anvil dev/test.
///
/// Exposes the same `isSanctioned(address)` read interface as the real mainnet
/// contract at 0x40C57923924B5c5c5455c48D93317139ADDaC8fb, plus writable
/// `addToSanctionsList` / `removeFromSanctionsList` so the gateway
/// `mock_sanction_address` admin endpoint can flip an address's status without
/// needing a real Chainalysis account.
///
/// Deploy on Anvil via `DeployMockSanctionsList.s.sol`, then set:
///   CHAINALYSIS_SANCTIONS_CONTRACT=<deployed address>
///   MOCK_SANCTIONS_ADDRESS=<deployed address>
contract MockSanctionsList {
    mapping(address => bool) private _sanctioned;

    function isSanctioned(address addr) external view returns (bool) {
        return _sanctioned[addr];
    }

    function addToSanctionsList(address[] calldata addrs) external {
        for (uint256 i = 0; i < addrs.length; i++) {
            _sanctioned[addrs[i]] = true;
        }
    }

    function removeFromSanctionsList(address[] calldata addrs) external {
        for (uint256 i = 0; i < addrs.length; i++) {
            _sanctioned[addrs[i]] = false;
        }
    }

    /// @dev Test helper — set a single address directly without an array.
    function setSanctioned(address addr, bool sanctioned) external {
        _sanctioned[addr] = sanctioned;
    }
}
