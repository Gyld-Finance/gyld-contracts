// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title KaleidoscopeNAVFeed
/// @notice Publishes the NAV-per-token for a single bond instrument in the
///         AggregatorV3Interface format. This lets Morpho Blue and any other
///         Chainlink-compatible DeFi protocol read collateral prices without
///         needing to trust off-chain API calls.
///
/// @dev Trust model: only the owner (a KMS signer or Gnosis Safe) can push
///      price updates via `updateAnswer`. Ownership is transferred via the
///      two-step OZ Ownable2Step pattern to prevent accidental handoffs.
///
///      Phase 3 migration: transfer ownership to a Chainlink Automation node
///      or RedStone oracle updater; the ABI remains identical so Morpho
///      markets and the NAVFeedForwarder need no changes.
///
///      Formula pushed on-chain:
///        NAV per token = (bonds_held × bond_price_usd) / tokens_outstanding
///
///      Scaling: 8 decimal places, matching standard Chainlink USD price feeds.
///      e.g. TLT at $95.42 → answer = 9_542_000_000
///
///      Safety constraints:
///        - MAX_PRICE_DEVIATION_BPS: price cannot move more than 10% per update
///        - MIN_UPDATE_INTERVAL:     updates must be at least 1 hour apart
///        - MAX_STALENESS:           threshold for isFresh() monitoring view;
///                                   reads do NOT revert on stale price (Chainlink/Ondo model)
///                                   so DeFi integrations work over weekends and holidays
///
/// @custom:security-contact security@gyld.fi

// ── Chainlink AggregatorV3Interface (inlined — no @chainlink/contracts dep) ──
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function description() external view returns (string memory);
    function version() external view returns (uint256);
    function getRoundData(uint80 _roundId) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

contract KaleidoscopeNAVFeed is AggregatorV3Interface, Ownable2Step {
    // ── Price state ───────────────────────────────────────────────────────────

    /// Latest NAV per token, 8 decimal places.
    int256 private _latestAnswer;

    /// Block.timestamp of the last successful updateAnswer() call.
    uint256 private _updatedAt;

    /// Monotonically increasing round counter.
    uint80 private _roundId;

    // ── Configuration ─────────────────────────────────────────────────────────

    /// Human-readable description (e.g. "TLT / USD NAV").
    string private _description;

    /// Staleness threshold used by isFresh() for backend monitoring.
    /// 96 hours: covers 3-day US holiday weekends (~87 h gap) with a buffer.
    /// latestRoundData() does NOT revert when this is exceeded — consumers
    /// receive the last known NAV, matching the Chainlink / Ondo Finance model.
    uint256 public constant MAX_STALENESS = 96 hours;

    /// Minimum time between consecutive updateAnswer() calls.
    /// Prevents rapid price oscillation from a compromised updater key.
    uint256 public constant MIN_UPDATE_INTERVAL = 1 hours;

    /// Maximum allowed price deviation per update, in basis points.
    /// 1000 bps = 10%. Reverts if new price deviates more than this from last.
    /// Applies only after the first update (no previous price to compare).
    uint256 public constant MAX_PRICE_DEVIATION_BPS = 1000;

    /// Denominator for basis-point arithmetic (1 bps = 1 / 10_000).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ── Errors ────────────────────────────────────────────────────────────────

    error AnswerMustBePositive();
    error UpdateTooSoon(uint256 nextAllowedAt);
    error PriceDeviationTooLarge(int256 submitted, int256 previous);
    error HistoricalRoundsNotStored(uint80 requested, uint80 current);
    error NoPriceSet();
    error PriceStale(uint256 updatedAt, uint256 currentTime);

    // ── Events ────────────────────────────────────────────────────────────────

    /// Standard Chainlink event emitted on every price update.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param initialOwner  Address that may call updateAnswer (KMS signer or Safe).
    /// @param desc          Human-readable description, e.g. "TLT / USD NAV".
    constructor(address initialOwner, string memory desc) Ownable(initialOwner) {
        _description = desc;
    }

    // ── Price update ──────────────────────────────────────────────────────────

    /// @notice Push a new NAV price on-chain.
    /// @param answer NAV per token, 8 decimal places (e.g. 9_542_000_000 = $95.42).
    ///
    /// Reverts if:
    ///   - caller is not the owner
    ///   - answer is not positive
    ///   - less than MIN_UPDATE_INTERVAL has elapsed since the last update
    ///   - price deviates more than MAX_PRICE_DEVIATION_BPS from the previous price
    function updateAnswer(int256 answer) external onlyOwner {
        if (answer <= 0) revert AnswerMustBePositive();

        if (_updatedAt > 0) {
            if (block.timestamp < _updatedAt + MIN_UPDATE_INTERVAL)
                revert UpdateTooSoon(_updatedAt + MIN_UPDATE_INTERVAL);

            int256 last = _latestAnswer;
            int256 diff = answer > last ? answer - last : last - answer;
            // diff / last > MAX_PRICE_DEVIATION_BPS / 10_000
            // ↔  diff * 10_000 > last * MAX_PRICE_DEVIATION_BPS
            if (diff * int256(BPS_DENOMINATOR) > last * int256(MAX_PRICE_DEVIATION_BPS))
                revert PriceDeviationTooLarge(answer, last);
        }

        _roundId += 1;
        _latestAnswer = answer;
        _updatedAt = block.timestamp;
        emit AnswerUpdated(answer, _roundId, block.timestamp);
    }

    // ── AggregatorV3Interface ─────────────────────────────────────────────────

    function decimals() external pure override returns (uint8) {
        return 8;
    }

    function description() external view override returns (string memory) {
        return _description;
    }

    function version() external pure override returns (uint256) {
        return 3;
    }

    /// @notice AggregatorV3Interface historical round lookup.
    /// @dev This feed stores only the current round — historical answers are not retained.
    ///      Passing any _roundId other than the current one reverts intentionally.
    ///      DeFi integrations (Morpho Blue, Aave V3) use latestRoundData() exclusively;
    ///      getRoundData is implemented solely to satisfy the interface. If a consumer
    ///      requires historical NAV lookup, upgrade to a feed that stores a round history.
    function getRoundData(uint80 _rid) external view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        if (_rid != _roundId) revert HistoricalRoundsNotStored(_rid, _roundId);
        if (_updatedAt == 0) revert NoPriceSet();
        return (_roundId, _latestAnswer, _updatedAt, _updatedAt, _roundId);
    }

    function latestRoundData() external view override returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    ) {
        if (_updatedAt == 0) revert NoPriceSet();
        return (_roundId, _latestAnswer, _updatedAt, _updatedAt, _roundId);
    }

    // ── Chainlink V2 compatibility (Aave V3 calls latestAnswer()) ─────────────

    /// @notice Returns the latest answer. Provided for Aave V3 oracle compatibility
    ///         which calls latestAnswer() via the older AggregatorInterface.
    function latestAnswer() external view returns (int256) {
        if (_updatedAt == 0) revert NoPriceSet();
        return _latestAnswer;
    }

    // ── Monitoring ────────────────────────────────────────────────────────────

    /// @notice Returns true if the last price update is within MAX_STALENESS.
    ///         Use this in backend alerting to detect a stuck KMS signer.
    ///         DeFi read functions (latestRoundData, latestAnswer) never revert
    ///         on staleness — they always return the last known NAV.
    function isFresh() external view returns (bool) {
        if (_updatedAt == 0) return false;
        return block.timestamp - _updatedAt <= MAX_STALENESS;
    }
}
