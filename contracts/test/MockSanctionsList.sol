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
/// ## Access control (GYL-1135)
///
/// The write functions used to be plain `external` with no caller check at all. Because
/// {DeployGuards.requireProdContract} can only assert `code.length != 0`, this mock
/// SATISFIES the production `SANCTIONS_LIST` requirement — so an ownerless mock reachable
/// on a production chain let ANY address sanction ANY holder. GyldBondToken screening is
/// fail-closed, so that is a permissionless transfer freeze on every holder of every
/// series. The list is therefore mutable only by {owner}, fixed at construction.
///
/// `owner` is a plain storage variable rather than `immutable` on purpose: the deploy
/// scripts compare a candidate oracle's EXTCODEHASH against
/// `keccak256(type(MockSanctionsList).runtimeCode)` to refuse a dev mock on production
/// (see {DeployGuards.requireProdNotMock}), and `runtimeCode` is unavailable for a
/// contract that contains immutables.
///
/// Deploy on Anvil via `DeployMockSanctionsList.s.sol` (which refuses to run on any
/// non-dev chain), then set:
///   CHAINALYSIS_SANCTIONS_CONTRACT=<deployed address>
///   MOCK_SANCTIONS_ADDRESS=<deployed address>
/// The gateway key that calls `mock_sanction_address` must be the `owner` printed by
/// that script (the deployer/broadcaster).
contract MockSanctionsList {
    mapping(address => bool) private _sanctioned;

    /// The only address permitted to mutate the list. Set at construction, never changes.
    address public owner;

    error NotOwner(address caller);
    error ZeroOwner();

    /// @param owner_ the address allowed to mutate the sanctions list. Passed explicitly
    ///        rather than taken from `msg.sender` because these mocks are deployed through
    ///        the canonical CREATE2 proxy, which would otherwise own every one of them.
    constructor(address owner_) {
        if (owner_ == address(0)) revert ZeroOwner();
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    function isSanctioned(address addr) external view returns (bool) {
        return _sanctioned[addr];
    }

    function addToSanctionsList(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            _sanctioned[addrs[i]] = true;
        }
    }

    function removeFromSanctionsList(address[] calldata addrs) external onlyOwner {
        for (uint256 i = 0; i < addrs.length; i++) {
            _sanctioned[addrs[i]] = false;
        }
    }

    /// @dev Test helper — set a single address directly without an array.
    function setSanctioned(address addr, bool sanctioned) external onlyOwner {
        _sanctioned[addr] = sanctioned;
    }
}
