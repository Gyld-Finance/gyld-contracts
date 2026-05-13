// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title NAVFeedForwarder
/// @notice A permanent, stable oracle address that forwards all price queries
///         to an upgradeable upstream oracle (AggregatorV3Interface-compatible).
///
/// @dev Problem solved: DeFi protocols like Morpho Blue bake the oracle address
///      into immutable market parameters at creation time. Pointing them directly
///      at KaleidoscopeNAVFeed means any oracle upgrade (e.g. self → RedStone →
///      Chainlink NAVLink) forces a full market redeployment and liquidity migration.
///
///      Solution: DeFi protocols point at this forwarder (permanent). When we
///      upgrade the oracle provider, we call setUpstreamOracle() once. The
///      forwarder pointer flips. All integrations update instantly with no code
///      changes on their side.
///
///      Upgrade path:
///        Phase 1: upstream = KaleidoscopeNAVFeed (our backend pushes NAV)
///        Phase 2: upstream = RedStone Classic feed (third-party attested)
///        Phase 3: upstream = Chainlink NAVLink feed (institutional grade)
///
///      Governance: owner should be a TimelockController (recommended: 24-48 hour
///      delay) to give DeFi integrators advance notice of oracle changes. The
///      two-step OZ Ownable2Step pattern prevents accidental owner handoffs.
///
///      Interface: implements both AggregatorV3Interface (Morpho, modern DeFi)
///      and latestAnswer() (Aave V3 legacy AggregatorInterface). All calls are
///      pure delegations — no local state, no transformation, no caching.
///
/// @custom:security-contact security@gyld.fi

interface IUpstreamOracle {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 roundId) external view returns (
        uint80, int256, uint256, uint256, uint80
    );
    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256, uint80
    );
    function latestAnswer() external view returns (int256);
}

contract NAVFeedForwarder is Ownable2Step {
    // ── State ─────────────────────────────────────────────────────────────────

    /// The current upstream oracle. All reads are delegated here.
    /// Changed only via setUpstreamOracle() by the owner (timelock recommended).
    IUpstreamOracle private _upstreamOracle;

    // ── Errors ────────────────────────────────────────────────────────────────

    error UpstreamCannotBeZero();
    error InvalidOracle(address oracle);

    // ── Events ────────────────────────────────────────────────────────────────

    event UpstreamOracleUpdated(address indexed previousOracle, address indexed newOracle);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param initialUpstream  Initial upstream oracle (KaleidoscopeNAVFeed at launch).
    /// @param initialOwner     Owner that may call setUpstreamOracle.
    ///                         Recommended: a TimelockController address so oracle
    ///                         upgrades have a mandatory delay period.
    constructor(address initialUpstream, address initialOwner) Ownable(initialOwner) {
        if (initialUpstream == address(0)) revert UpstreamCannotBeZero();
        (bool ok, bytes memory data) = initialUpstream.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length != 32 || uint8(data[31]) != 8) revert InvalidOracle(initialUpstream);
        _upstreamOracle = IUpstreamOracle(initialUpstream);
        emit UpstreamOracleUpdated(address(0), initialUpstream);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Swap the upstream oracle. Effective immediately — all subsequent
    ///         reads return data from the new upstream.
    /// @param newUpstream  New oracle address. Must implement AggregatorV3Interface
    ///                     + latestAnswer(). Passing address(0) reverts.
    function setUpstreamOracle(address newUpstream) external onlyOwner {
        if (newUpstream == address(0)) revert UpstreamCannotBeZero();
        // Verify the address implements the oracle interface before storing.
        // Uses decimals() — a pure view that never reverts for business-logic
        // reasons (unlike latestRoundData which reverts when no price is set yet).
        // staticcall handles both EOAs (success=true, data="") and wrong contracts
        // (success=false): we require success AND a full 32-byte return value.
        (bool ok, bytes memory data) = newUpstream.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length != 32 || uint8(data[31]) != 8) revert InvalidOracle(newUpstream);
        address previous = address(_upstreamOracle);
        _upstreamOracle = IUpstreamOracle(newUpstream);
        emit UpstreamOracleUpdated(previous, newUpstream);
    }

    /// @notice Returns the address of the current upstream oracle.
    function upstreamOracle() external view returns (address) {
        return address(_upstreamOracle);
    }

    // ── AggregatorV3Interface — pure delegation ───────────────────────────────

    function decimals() external view returns (uint8) {
        return _upstreamOracle.decimals();
    }

    function description() external view returns (string memory) {
        return _upstreamOracle.description();
    }

    function version() external view returns (uint256) {
        return _upstreamOracle.version();
    }

    function getRoundData(uint80 roundId) external view returns (
        uint80 rId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return _upstreamOracle.getRoundData(roundId);
    }

    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        return _upstreamOracle.latestRoundData();
    }

    // ── Chainlink V2 compatibility (Aave V3 calls latestAnswer()) ─────────────

    function latestAnswer() external view returns (int256) {
        return _upstreamOracle.latestAnswer();
    }
}
