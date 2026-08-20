// SPDX-License-Identifier: BUSL-1.1
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
///        - MAX_STALENESS:           threshold for the isFresh() monitoring view;
///                                   reads do NOT revert on stale price (Chainlink/Ondo model)
///                                   so DeFi integrations work over weekends and holidays.
///                                   Staleness is SURFACED (isFresh, stalenessSeconds),
///                                   never ENFORCED here — every consumer must age-check
///                                   `updatedAt` itself. See latestRoundData for why.
///

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

    // ── Emergency updater ─────────────────────────────────────────────────────

    /// Address authorised to call emergencyUpdateAnswer().
    /// Should be a Gnosis Safe multisig — a DIFFERENT key from the KMS owner so
    /// a compromised KMS key cannot bypass the deviation / interval guards.
    /// address(0) means the emergency path is disabled.
    address private _emergencyUpdater;

    // ── Errors ────────────────────────────────────────────────────────────────

    error AnswerMustBePositive();
    error UpdateTooSoon(uint256 nextAllowedAt);
    error PriceDeviationTooLarge(int256 submitted, int256 previous);
    error HistoricalRoundsNotStored(uint80 requested, uint80 current);
    error NoPriceSet();
    // NOTE (GYL-1135): there is deliberately no `PriceStale` error. A declared-but-
    // never-thrown one used to live here and led readers (and two design docs) to
    // believe reads revert on staleness. They do not — see latestRoundData below.
    error NotEmergencyUpdater();
    error EmergencyUpdaterCannotBeOwner();
    error CannotRenounceOwnership();

    // ── Events ────────────────────────────────────────────────────────────────

    /// Standard Chainlink event emitted on every price update.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    /// Emitted when the emergency updater address is changed.
    event EmergencyUpdaterSet(address indexed previous, address indexed newUpdater);

    /// Emitted by emergencyUpdateAnswer() — distinct from AnswerUpdated so
    /// monitoring rules can alert on any emergency use.
    event EmergencyAnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param initialOwner  Address that may call updateAnswer (KMS signer or Safe).
    /// @param desc          Human-readable description, e.g. "TLT / USD NAV".
    constructor(address initialOwner, string memory desc) Ownable(initialOwner) {
        _description = desc;
    }

    // ── Emergency updater management ─────────────────────────────────────────

    /// @notice Returns the current emergency updater address.
    function emergencyUpdater() external view returns (address) {
        return _emergencyUpdater;
    }

    /// @notice Set or clear the emergency updater address.
    /// @dev    Must be a Gnosis Safe multisig — a different key from the KMS
    ///         owner. A compromised KMS key must not be able to call
    ///         emergencyUpdateAnswer. Pass address(0) to disable the path.
    function setEmergencyUpdater(address newUpdater) external onlyOwner {
        // Key-separation invariant: the emergency updater must be a different
        // key from the owner (see design doc §4). address(0) disables the path
        // and is always allowed — the owner is never address(0) while set.
        if (newUpdater == owner()) revert EmergencyUpdaterCannotBeOwner();
        address previous = _emergencyUpdater;
        _emergencyUpdater = newUpdater;
        emit EmergencyUpdaterSet(previous, newUpdater);
    }

    // ── Ownership (key-separation guards) ─────────────────────────────────────

    /// @dev Fail-fast guard: reject starting an ownership transfer to the current
    ///      emergency updater so the two roles can never collapse into one key.
    ///      address(0) is allowed (cancels a pending transfer).
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        if (newOwner != address(0) && newOwner == _emergencyUpdater)
            revert EmergencyUpdaterCannotBeOwner();
        super.transferOwnership(newOwner);
    }

    /// @notice Disabled (GLD-165) — this feed can never be left without an owner.
    /// @dev    An ownerless feed is unrecoverable: `updateAnswer` dies, there is no
    ///         proxy to upgrade, and reads never revert on staleness (see
    ///         `latestRoundData`) so it serves its last answer forever instead of
    ///         failing loudly. Renouncing with an `_emergencyUpdater` set is worse
    ///         still — that address keeps unbounded price authority with nobody left
    ///         to clear it. Rotate with transferOwnership + acceptOwnership instead.
    ///         No `onlyOwner`: nobody can ever succeed, so one unambiguous error
    ///         beats telling a non-owner the owner could have done it.
    ///         Not retrofittable — feeds deployed before this guard lack it.
    function renounceOwnership() public virtual override {
        revert CannotRenounceOwnership();
    }

    /// @dev Single funnel that actually changes owner() (acceptOwnership). Enforce
    ///      the key-separation invariant here so it holds regardless of the path.
    ///      The address(0) carve-out is retained defensively — with
    ///      renounceOwnership() disabled above and OZ's constructor rejecting a zero
    ///      initialOwner, nothing currently reaches this with address(0).
    function _transferOwnership(address newOwner) internal virtual override {
        if (newOwner != address(0) && newOwner == _emergencyUpdater)
            revert EmergencyUpdaterCannotBeOwner();
        super._transferOwnership(newOwner);
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

    /// @notice Correct a wrong NAV without the normal interval / deviation guards.
    /// @dev    Use only when a bad price is stuck — e.g. a fat-finger within the
    ///         10 % band that makes the correct price unreachable in one step.
    ///         Caller must be the emergencyUpdater (set via setEmergencyUpdater).
    ///         Emits EmergencyAnswerUpdated, NOT AnswerUpdated — keep both event
    ///         types in your monitoring rules so any emergency use pages on-call.
    ///         Every use should trigger an immediate ops review.
    function emergencyUpdateAnswer(int256 answer) external {
        if (msg.sender != _emergencyUpdater) revert NotEmergencyUpdater();
        if (answer <= 0) revert AnswerMustBePositive();
        _roundId += 1;
        _latestAnswer = answer;
        _updatedAt = block.timestamp;
        emit EmergencyAnswerUpdated(answer, _roundId, block.timestamp);
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

    /// @notice Returns true if the last price update is within MAX_STALENESS.
    ///         Use this in backend alerting to detect a stuck KMS signer.
    ///         DeFi read functions (latestRoundData, latestAnswer) never revert
    ///         on staleness — they always return the last known NAV.
    function isFresh() external view returns (bool) {
        if (_updatedAt == 0) return false;
        return block.timestamp - _updatedAt <= MAX_STALENESS;
    }

    /// @notice Seconds elapsed since the last price push; type(uint256).max if a price
    ///         has never been set.
    /// @dev    Monitoring entrypoint (GYL-1135). Reads never revert on staleness by
    ///         design — see latestRoundData — so freshness must be surfaced, not
    ///         enforced. This returns a magnitude rather than the boolean `isFresh()`
    ///         gives, which lets an alerting rule pick its own threshold (page at 26 h,
    ///         escalate at 96 h) instead of being pinned to MAX_STALENESS, and lets a
    ///         dashboard chart the gap. The sentinel for "never set" is
    ///         type(uint256).max rather than 0 so a never-initialised feed can never be
    ///         mistaken for a just-updated one.
    ///
    ///         NOT retrofittable: KaleidoscopeNAVFeed is not upgradeable (no proxy,
    ///         Ownable2Step only), so feeds already deployed — including the live
    ///         production feed — do not have this function. It benefits future deployments
    ///         only. Monitoring of existing feeds must derive age off-chain from
    ///         `latestRoundData().updatedAt` (or watch `AnswerUpdated` /
    ///         `EmergencyAnswerUpdated`), which works on every version of this contract.
    function stalenessSeconds() external view returns (uint256) {
        if (_updatedAt == 0) return type(uint256).max;
        return block.timestamp - _updatedAt;
    }
}
