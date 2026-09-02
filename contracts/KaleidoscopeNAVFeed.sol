// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IUpstreamOracle} from "./interfaces/AggregatorV3Interface.sol";

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
///          Both guards are unconditional — there is no privileged bypass. A larger
///          correction is reached by chaining updates (the band is relative to the
///          LAST price, so it moves with each push); pause the bond token meanwhile
///          if a wrong price must not be liquidated against. See ARCHITECTURE D-19.
///        - stalenessThreshold:      threshold for the isFresh() monitoring view;
///                                   reads do NOT revert on stale price (Chainlink/Ondo model)
///                                   so DeFi integrations work over weekends and holidays.
///                                   Staleness is SURFACED (isFresh, stalenessSeconds),
///                                   never ENFORCED here — every consumer must age-check
///                                   `updatedAt` itself. See latestRoundData for why.
///                                   Owner-settable and pinned to the strictest consumer
///                                   threshold (audit FIND-022): this contract has no proxy,
///                                   so a constant here could only be corrected by
///                                   redeploying the feed and repointing every forwarder.
///

contract KaleidoscopeNAVFeed is IUpstreamOracle, Ownable2Step {
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

    /// Initial value written to `stalenessThreshold` by the constructor.
    ///
    /// 24 hours, matching GyldAtomicSwap's deployed `maxNavAgeSecs` (audit FIND-022).
    /// The window is deliberately pinned to the strictest age any consumer enforces, so
    /// `isFresh()` answers exactly one question: **will executeSwap accept this NAV right
    /// now?** It goes false the moment settlement starts refusing, not a day later.
    ///
    /// It therefore reads false over weekends and market holidays, because the keeper
    /// pushes once per market day and settlement genuinely is refusing then. That is
    /// correct, not noise: `isFresh()` reports settlement availability, and nothing pages
    /// on it. Distinguishing "the keeper died" from "the market is closed" is the job of
    /// `stalenessSeconds()` plus a calendar-aware off-chain rule — no on-chain constant
    /// can tell those apart, which is why this one does not try.
    ///
    /// Keep this equal to (or below) the tightest consumer threshold. If maxNavAgeSecs
    /// is retuned, retune this with it via setStalenessThreshold.
    uint256 public constant DEFAULT_STALENESS_THRESHOLD = 24 hours;

    /// Staleness threshold used by isFresh() for backend monitoring.
    /// latestRoundData() does NOT revert when this is exceeded — consumers
    /// receive the last known NAV, matching the Chainlink / Ondo Finance model.
    /// Settable by the owner; see setStalenessThreshold (audit FIND-022).
    uint256 public stalenessThreshold;

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
    // NOTE (GYL-1135): there is deliberately no `PriceStale` error. A declared-but-
    // never-thrown one used to live here and led readers (and two design docs) to
    // believe reads revert on staleness. They do not — see latestRoundData below.
    error CannotRenounceOwnership();
    error InvalidStalenessThreshold(uint256 submitted);

    // ── Events ────────────────────────────────────────────────────────────────

    /// Standard Chainlink event emitted on every price update.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    /// Emitted when the owner retunes the isFresh() monitoring window.
    event StalenessThresholdUpdated(uint256 oldSeconds, uint256 newSeconds);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param initialOwner  Address that may call updateAnswer (KMS signer or Safe).
    /// @param desc          Human-readable description, e.g. "TLT / USD NAV".
    constructor(address initialOwner, string memory desc) Ownable(initialOwner) {
        _description = desc;
        stalenessThreshold = DEFAULT_STALENESS_THRESHOLD;
        // oldSeconds = 0 is a "no previous value" sentinel the setter can never emit
        // (it rejects zero), so an indexer can reconstruct the window from this log
        // alone and tell the deployment apart from every later retune.
        emit StalenessThresholdUpdated(0, DEFAULT_STALENESS_THRESHOLD);
    }

    // ── Ownership ─────────────────────────────────────────────────────────────

    /// @notice Disabled (GLD-165) — this feed can never be left without an owner.
    /// @dev    An ownerless feed is unrecoverable: `updateAnswer` dies, there is no
    ///         proxy to upgrade, and reads never revert on staleness (see
    ///         `latestRoundData`) so it serves its last answer forever instead of
    ///         failing loudly. Rotate with transferOwnership + acceptOwnership instead.
    ///         No `onlyOwner`: nobody can ever succeed, so one unambiguous error
    ///         beats telling a non-owner the owner could have done it.
    ///         Not retrofittable — feeds deployed before this guard lack it.
    function renounceOwnership() public virtual override {
        revert CannotRenounceOwnership();
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

    /// @notice Latest round. Reverts ONLY when no price has ever been pushed.
    /// @dev    Deliberately does NOT revert on staleness (GYL-1135). Chainlink's own
    ///         aggregators return the last answer with its `updatedAt`; consumers are
    ///         expected to age-check `updatedAt` themselves. Two live consumers prove
    ///         both halves of that contract: Euler froze correctly on its own
    ///         `PriceOracle_TooStale` check, while Morpho — which does not age-check —
    ///         kept quoting the last pushed answer. Making this revert would break the
    ///         consumers that check correctly, destroy the diagnosability of `updatedAt`,
    ///         and unfixably freeze Morpho *liquidations* during an outage. Integrators
    ///         MUST enforce their own max-age (GyldAtomicSwap does, via StaleNav).
    ///         `stalenessSeconds()` below is the monitoring entrypoint.
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

    /// @notice Returns true if the last price update is within `stalenessThreshold`.
    ///         Use this in backend alerting to detect a stuck KMS signer.
    ///         DeFi read functions (latestRoundData, latestAnswer) never revert
    ///         on staleness — they always return the last known NAV.
    /// @dev    Reads as "will executeSwap accept this NAV right now?" — the window is
    ///         pinned to the strictest consumer threshold (FIND-022), so this goes false
    ///         as settlement starts refusing rather than a day after. It is false over
    ///         weekends by design, because settlement is refusing then too. It cannot
    ///         tell "the keeper died" from "the market is closed"; that is the job of
    ///         `stalenessSeconds()` plus a calendar-aware off-chain rule. Nothing pages
    ///         on this boolean.
    function isFresh() external view returns (bool) {
        if (_updatedAt == 0) return false;
        return block.timestamp - _updatedAt <= stalenessThreshold;
    }

    /// @notice Retune the isFresh() monitoring window.
    /// @param newSeconds New threshold in seconds. Must be non-zero.
    ///
    /// @dev    Exists because this contract has no proxy (audit FIND-022). As a
    ///         `constant` the window could only be corrected by deploying a
    ///         replacement feed and repointing every NAVFeedForwarder at it via
    ///         setUpstreamOracle — so a value that turned out wrong after launch
    ///         became permanent. A setter makes that a transaction instead.
    ///
    ///         Deliberately carries no structural ceiling, unlike
    ///         GyldAtomicSwap.setMaxNavAgeSecs (D-16). That one bounds the ONLY
    ///         staleness defence on the settlement path, so an admin must not be
    ///         able to widen it into a no-op. This one gates a view and nothing
    ///         else: no read reverts on it, no transfer depends on it, and no
    ///         on-chain guarantee changes with it. A ceiling here would suggest
    ///         a protection that does not exist. Zero is still rejected — it is
    ///         never a deliberate choice, only a forgotten argument.
    ///
    ///         NOT retrofittable: feeds deployed before this setter hold the window
    ///         as a `constant` and cannot be retuned at all — reaching them needs a
    ///         replacement feed plus a setUpstreamOracle repoint on every forwarder.
    ///
    ///         Widening this is the one extra power a compromised owner key gains: it
    ///         can hold isFresh() at `true` through an outage. It cannot touch
    ///         `stalenessSeconds()`, which is the designated monitoring entrypoint for
    ///         exactly that reason, and the change emits StalenessThresholdUpdated.
    ///
    ///         Keep this at or below the tightest age any consumer enforces — today
    ///         GyldAtomicSwap.maxNavAgeSecs, and note that is now per-series
    ///         (setMaxNavAgeSecsFor), so a series held to a tighter age wants this
    ///         tightened with it. A window ABOVE the enforced age is the defect
    ///         FIND-022 raised: the view would read healthy while settlement fails.
    function setStalenessThreshold(uint256 newSeconds) external onlyOwner {
        if (newSeconds == 0) revert InvalidStalenessThreshold(newSeconds);
        uint256 old = stalenessThreshold;
        stalenessThreshold = newSeconds;
        emit StalenessThresholdUpdated(old, newSeconds);
    }

    /// @notice Seconds elapsed since the last price push; type(uint256).max if a price
    ///         has never been set.
    /// @dev    Monitoring entrypoint (GYL-1135). Reads never revert on staleness by
    ///         design — see latestRoundData — so freshness must be surfaced, not
    ///         enforced. This returns a magnitude rather than the boolean `isFresh()`
    ///         gives, which lets an alerting rule pick its own threshold (page at 26 h,
    ///         escalate at 48 h) instead of being pinned to `stalenessThreshold`, and lets a
    ///         dashboard chart the gap. The sentinel for "never set" is
    ///         type(uint256).max rather than 0 so a never-initialised feed can never be
    ///         mistaken for a just-updated one.
    ///
    ///         NOT retrofittable: KaleidoscopeNAVFeed is not upgradeable (no proxy,
    ///         Ownable2Step only), so feeds already deployed — including the live
    ///         production feed — do not have this function. It benefits future deployments
    ///         only. Monitoring of existing feeds must derive age off-chain from
    ///         `latestRoundData().updatedAt` (or watch `AnswerUpdated`), which works on
    ///         every version of this contract.
    function stalenessSeconds() external view returns (uint256) {
        if (_updatedAt == 0) return type(uint256).max;
        return block.timestamp - _updatedAt;
    }
}
