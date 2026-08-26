// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IUpstreamOracle} from "./interfaces/AggregatorV3Interface.sol";

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

contract NAVFeedForwarder is IUpstreamOracle, Ownable2Step {
    // ── State ─────────────────────────────────────────────────────────────────

    /// The current upstream oracle. All reads are delegated here.
    /// Changed only via setUpstreamOracle() by the owner (timelock recommended).
    IUpstreamOracle private _upstreamOracle;

    // ── Errors ────────────────────────────────────────────────────────────────

    error UpstreamCannotBeZero();
    error InvalidOracle(address oracle);
    /// Upstream's latestRoundData() reported an `updatedAt` in the future.
    error UpstreamFutureDated(uint256 updatedAt, uint256 blockTimestamp);
    /// renounceOwnership() is disabled — this forwarder must never be left ownerless.
    error CannotRenounceOwnership();

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
        // Also probe version() — pure constant on any AggregatorV3Interface implementation,
        // never reverts for business-logic reasons, catches partial stubs that only have decimals().
        (bool okV, bytes memory dataV) = initialUpstream.staticcall(abi.encodeWithSignature("version()"));
        if (!okV || dataV.length != 32) revert InvalidOracle(initialUpstream);
        _probeNotFutureDated(initialUpstream);
        _upstreamOracle = IUpstreamOracle(initialUpstream);
        emit UpstreamOracleUpdated(address(0), initialUpstream);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Swap the upstream oracle. Effective immediately — all subsequent
    ///         reads return data from the new upstream.
    ///
    /// @dev    MIGRATION GATE — re-check decision D-18 before proposing.
    ///         GyldAtomicSwap._checkQuoteBand deliberately does NOT check
    ///         `answeredInRound < roundId`. That is sound only because every upstream
    ///         we point at returns `answeredInRound == roundId` — true of modern OCR
    ///         aggregators (Chainlink deprecated the field) and true of
    ///         KaleidoscopeNAVFeed by construction. The Phase 2/3 path above leads to
    ///         third-party feeds where that may not hold.
    ///
    ///         The probes below verify decimals(), version() and non-future-dating.
    ///         They CANNOT verify this one: whether a feed's `answeredInRound` can lag
    ///         `roundId` is a property of its round lifecycle, not of any value
    ///         readable at swap time. Adopting such an upstream silently disarms a
    ///         guard the swap never had, and closing it needs a contract change, not
    ///         a setter call. Confirm the new upstream's behaviour off-chain first;
    ///         see ARCHITECTURE.md §11.4 and D-18 (§17.1).
    ///
    /// @param newUpstream  New oracle address. Must implement AggregatorV3Interface
    ///                     + latestAnswer(). Passing address(0) reverts.
    function setUpstreamOracle(address newUpstream) external onlyOwner {
        if (newUpstream == address(0)) revert UpstreamCannotBeZero();
        if (newUpstream == address(this)) revert InvalidOracle(newUpstream);
        // Verify the address implements the oracle interface before storing.
        // Uses decimals() — a pure view that never reverts for business-logic
        // reasons (unlike latestRoundData which reverts when no price is set yet).
        // staticcall handles both EOAs (success=true, data="") and wrong contracts
        // (success=false): we require success AND a full 32-byte return value.
        (bool ok, bytes memory data) = newUpstream.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length != 32 || uint8(data[31]) != 8) revert InvalidOracle(newUpstream);
        // Also probe version() to catch partial interface implementations (M-05).
        (bool okV, bytes memory dataV) = newUpstream.staticcall(abi.encodeWithSignature("version()"));
        if (!okV || dataV.length != 32) revert InvalidOracle(newUpstream);
        _probeNotFutureDated(newUpstream);
        address previous = address(_upstreamOracle);
        _upstreamOracle = IUpstreamOracle(newUpstream);
        emit UpstreamOracleUpdated(previous, newUpstream);
    }

    /// @notice Returns the address of the current upstream oracle.
    function upstreamOracle() external view returns (address) {
        return address(_upstreamOracle);
    }

    /// @notice Disabled (GLD-166) — this forwarder can never be left ownerless.
    /// @dev    `setUpstreamOracle` is the only owner-gated function, so renouncing
    ///         welds the upstream pointer permanently: the Phase 2/3 oracle migration
    ///         this contract exists to enable becomes impossible, and if the installed
    ///         feed dies the forwarder keeps serving it with no way to repoint — its
    ///         address is baked into immutable Morpho market params. Not upgradeable,
    ///         so there is no path back. Rotate with transferOwnership +
    ///         acceptOwnership instead. No `onlyOwner`: nobody can ever succeed, so one
    ///         unambiguous error beats telling a non-owner the owner could have done it.
    ///         Not retrofittable — forwarders deployed before this guard lack it.
    function renounceOwnership() public virtual override {
        revert CannotRenounceOwnership();
    }

    // ── Upstream sanity probe ─────────────────────────────────────────────────

    /// @dev Reject an upstream whose latestRoundData() reports a FUTURE `updatedAt`
    ///      (GYL-1135). Every honest consumer of this forwarder defends itself against
    ///      a dead feed with an age check of the shape
    ///      `block.timestamp - updatedAt <= maxAge`. A future-dated `updatedAt`
    ///      satisfies that check unconditionally, and for as long as it stays ahead of
    ///      the clock — so a single swapped-in upstream would silently disarm the
    ///      staleness defence of every integrator at once, with no event that reads as
    ///      anomalous. That is a strictly worse failure than a stale feed: stale is
    ///      loud and fails closed, synthetic-fresh is silent and fails open.
    ///      GyldAtomicSwap._checkQuoteBand already rejects future `updatedAt` at read
    ///      time (F-6); this is the same invariant enforced one layer earlier, at
    ///      configuration time, where it is cheap and where an operator sees it.
    ///
    ///      Deliberately tolerant of a REVERTING latestRoundData: a freshly deployed
    ///      KaleidoscopeNAVFeed reverts NoPriceSet until its first push, and pointing
    ///      the forwarder at one before that push is a legitimate deploy sequence.
    ///      Garbage/short returndata is likewise tolerated here — the decimals() and
    ///      version() probes above are what establish "this is an oracle at all". This
    ///      probe answers only "is it lying about time?".
    ///
    ///      Note this is a point-in-time probe, not a guarantee: an upstream can start
    ///      returning future timestamps after it is installed. Consumer-side age checks
    ///      remain mandatory.
    function _probeNotFutureDated(address oracle) private view {
        (bool ok, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("latestRoundData()"));
        if (!ok || data.length < 160) return; // no price yet / not decodable — not our check
        (,,, uint256 updatedAt,) = abi.decode(data, (uint80, int256, uint256, uint256, uint80));
        if (updatedAt > block.timestamp) revert UpstreamFutureDated(updatedAt, block.timestamp);
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
