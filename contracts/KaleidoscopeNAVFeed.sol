// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IUpstreamOracle} from "./interfaces/AggregatorV3Interface.sol";

/// @title KaleidoscopeNAVFeed
/// @notice Publishes the NAV-per-token for a single bond instrument in the
///         AggregatorV3Interface format. This lets Morpho Blue and any other
///         Chainlink-compatible DeFi protocol read collateral prices without
///         needing to trust off-chain API calls.
///
/// @dev Trust model: the owner (a KMS signer or Gnosis Safe) pushes routine
///      price updates via `updateAnswer`. Ownership is transferred via the
///      two-step OZ Ownable2Step pattern to prevent accidental handoffs.
///
///      A second write path, `emergencyUpdateAnswer`, is a 2-of-2 between the immutable
///      `emergencyUpdater` (ops multisig) and an owner signature (FIND-003, D-29).
///
///      Phase 3 migration: transfer ownership to a Chainlink Automation node
///      or RedStone oracle updater; the ABI remains identical so Morpho
///      markets and the NAVFeedForwarder need no changes.
///
///      Formula pushed on-chain:
///        NAV per token = (bonds_held × bond_price_usd) / tokens_outstanding
///
///      Scaling: 8 decimal places, matching standard Chainlink USD price feeds.
///      This feed serves the $1.00 NAV standard: $1.00 → 1e8, and the absolute range
///      below is sized for it. A $95 instrument needs its own feed (audit FIND-003).
///
///      Safety constraints:
///        - MIN_ANSWER / MAX_ANSWER: $0.10-$5.00, on BOTH paths and EVERY push including
///          the first. Below 10 the deviation guard can never pass again and the feed is
///          permanently stuck; far above, its arithmetic overflows. See MIN_ANSWER.
///        - MAX_PRICE_DEVIATION_BPS: price cannot move more than 10% per update
///        - MIN_UPDATE_INTERVAL:     updates must be at least 1 hour apart
///          Both bind `updateAnswer` unconditionally; no key skips them. A larger
///          correction is reached by chaining updates (the band is relative to the
///          LAST price, so it moves with each push); pause the bond token meanwhile
///          if a wrong price must not be liquidated against. See ARCHITECTURE §11.5.
///        - EMERGENCY_MIN_ANSWER / EMERGENCY_MAX_ANSWER: $0.50-$2.00, the band the 2-of-2
///          `emergencyUpdateAnswer` may land in; it skips both guards above (FIND-003).
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

contract KaleidoscopeNAVFeed is IUpstreamOracle, Ownable2Step, EIP712 {
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

    /// Absolute floor for any published answer, first push included (audit FIND-020).
    /// 1e7 at 8 decimals = $0.10 per token. Retuned from $0.01 by audit FIND-003: the band
    /// now also bounds how far a compromised owner key can walk the price given hours.
    ///
    /// The floor is a correctness guard, not a taste guard. The deviation check is
    /// `diff * BPS_DENOMINATOR > last * MAX_PRICE_DEVIATION_BPS`, so a stored `last` of 9
    /// or less can never move again: the smallest possible change gives 1 * 10_000 = 10_000
    /// against at most 9 * 1_000 = 9_000, and every later push reverts
    /// PriceDeviationTooLarge. 10 is the lowest recoverable value. Since the first push
    /// skips the deviation check entirely (there is no `last` to compare against), a
    /// placeholder first answer of 1 would brick the feed permanently — it is not
    /// upgradeable, has no pause or reset, and `_updatedAt` never returns to zero.
    uint256 public constant MIN_ANSWER = 1e7;

    /// Absolute ceiling for any published answer. 5e8 at 8 decimals = $5.00 per token,
    /// retuned from $10bn by audit FIND-003 (this feed serves the $1.00 NAV standard).
    ///
    /// The mirror of MIN_ANSWER: above roughly int256.max / BPS_DENOMINATOR (~5.8e72) the
    /// deviation check's own arithmetic overflows and every later push reverts with a
    /// panic instead of a named error. This ceiling sits ~64 orders of magnitude below
    /// that, so the multiplication cannot overflow for any accepted answer.
    ///
    /// NOT fixed by reordering the deviation arithmetic to divide first: that removes the
    /// overflow at the top while making the bottom strictly worse, because
    /// `last / BPS_DENOMINATOR` truncates to zero for any realistic price and would then
    /// reject every push (audit FIND-020).
    uint256 public constant MAX_ANSWER = 5e8;

    // ── Emergency correction path (audit FIND-003) ────────────────────────────

    /// Absolute floor for an EMERGENCY answer. 5e7 at 8 decimals = $0.50 per token.
    uint256 public constant EMERGENCY_MIN_ANSWER = 5e7;

    /// Absolute ceiling for an EMERGENCY answer. 2e8 at 8 decimals = $2.00 per token.
    /// This band is a STRICT SUBSET of [MIN_ANSWER, MAX_ANSWER] — the relation is the
    /// security argument, and both are `constant` so it is checkable from source. The
    /// emergency path skips the interval and deviation guards but reaches no price
    /// chaining already reaches: it buys latency, not reach (audit FIND-003, D-29).
    /// The one thing the pair does gain is arriving without the intermediate prices, so
    /// without the liquidations each would have fired — hence two keys, not one.
    uint256 public constant EMERGENCY_MAX_ANSWER = 2e8;

    /// Minimum time between consecutive emergency corrections. Deliberately EQUAL to
    /// MIN_UPDATE_INTERVAL, so the invariant is uniform: no path writes this feed more
    /// than once an hour.
    /// @dev Without a cooldown the two keys hold a $0.50 <-> $2.00 oscillation primitive
    ///      every block. Parity rather than something longer, because a longer lock rate-
    ///      limits OPERATIONS, not an attacker: whoever holds both keys also holds the
    ///      owner key, which already writes hourly. A cascading credit event can need a
    ///      second correction the same day, and locking it out puts the operator back on
    ///      the ramp this path exists to avoid (audit FIND-003, D-29).
    uint256 public constant EMERGENCY_COOLDOWN = 1 hours;

    /// EIP-712 type hash for the owner's co-signature over an emergency correction.
    bytes32 public constant EMERGENCY_TYPEHASH =
        keccak256("EmergencyUpdate(int256 answer,uint256 nonce,uint256 deadline)");

    /// @notice The only address that may CALL emergencyUpdateAnswer. Production: the
    ///         Fordefi MPC ops wallet. It submits; it never signs.
    /// @dev    `immutable`, with deliberately NO setter: the absence of any appointment
    ///         surface is what makes this not the D-7 bypass. See ARCHITECTURE D-29.
    ///
    ///         The split mirrors GyldAtomicSwap exactly: there the quote-service KMS key
    ///         SIGNS an EIP-712 message and the taker SUBMITS it; here the KMS feed owner
    ///         SIGNS and this address SUBMITS. Putting the EIP-712 signing on KMS reuses
    ///         machinery already proven in production on every swap.
    address public immutable emergencyUpdater;

    /// @notice Consumed on every emergency correction; binds each owner signature to one use.
    uint256 public emergencyNonce;

    /// @notice Timestamp of the last emergency correction; gates EMERGENCY_COOLDOWN.
    uint256 public lastEmergencyAt;

    // ── Errors ────────────────────────────────────────────────────────────────

    error AnswerOutOfRange(int256 answer);
    error UpdateTooSoon(uint256 nextAllowedAt);
    error PriceDeviationTooLarge(int256 submitted, int256 previous);
    error HistoricalRoundsNotStored(uint80 requested, uint80 current);
    error NoPriceSet();
    // NOTE (GYL-1135): there is deliberately no `PriceStale` error. A declared-but-
    // never-thrown one used to live here and led readers (and two design docs) to
    // believe reads revert on staleness. They do not — see latestRoundData below.
    error CannotRenounceOwnership();
    error InvalidStalenessThreshold(uint256 submitted);
    // audit FIND-003 — the emergency correction path.
    error NotEmergencyUpdater(address caller);
    error EmergencyAnswerOutOfRange(int256 answer);
    error EmergencySignatureExpired(uint256 deadline);
    error EmergencySignerNotOwner();
    error EmergencyCooldownActive(uint256 nextAllowedAt);
    error InvalidEmergencyUpdater(address candidate);
    error OwnerCannotBeEmergencyUpdater();

    // ── Events ────────────────────────────────────────────────────────────────

    /// Standard Chainlink event emitted on every price update.
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    /// Emitted when the owner retunes the isFresh() monitoring window.
    event StalenessThresholdUpdated(uint256 oldSeconds, uint256 newSeconds);

    /// Emitted IN ADDITION TO AnswerUpdated on an emergency correction, never instead of it.
    event EmergencyAnswerUpdated(int256 indexed answer, uint256 indexed roundId, int256 previousAnswer, uint256 nonce);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param initialOwner  Address that may call updateAnswer (KMS signer or Safe).
    /// @param desc          Human-readable description, e.g. "TLT / USD NAV".
    /// @param guardian      The ops multisig: the ONLY address that may call
    ///                      emergencyUpdateAnswer, and only with the owner's signature.
    constructor(address initialOwner, string memory desc, address guardian)
        Ownable(initialOwner)
        EIP712("KaleidoscopeNAVFeed", "1")
    {
        // guardian == owner would collapse the 2-of-2 into a 1-of-1 and re-create D-7.
        if (guardian == address(0) || guardian == initialOwner || guardian == address(this)) {
            revert InvalidEmergencyUpdater(guardian);
        }
        emergencyUpdater = guardian;
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

    /// @notice Ownership may never be handed to the emergency updater: one address in both
    ///         roles collapses the 2-of-2 into a 1-of-1 (audit FIND-003).
    /// @dev    Guarding the public setter suffices — `pendingOwner` is written nowhere else.
    ///         `_transferOwnership` is deliberately NOT overridden: `Ownable`'s constructor
    ///         calls it before `emergencyUpdater` is initialised, which does not compile.
    function transferOwnership(address newOwner) public virtual override {
        if (newOwner == emergencyUpdater) revert OwnerCannotBeEmergencyUpdater();
        super.transferOwnership(newOwner);
    }

    // ── Price update ──────────────────────────────────────────────────────────

    /// @notice Push a new NAV price on-chain.
    /// @param answer NAV per token, 8 decimal places (e.g. 100_000_000 = $1.00).
    ///
    /// Reverts if:
    ///   - caller is not the owner
    ///   - answer is outside MIN_ANSWER..MAX_ANSWER, first push included
    ///   - less than MIN_UPDATE_INTERVAL has elapsed since the last update
    ///   - price deviates more than MAX_PRICE_DEVIATION_BPS from the previous price
    function updateAnswer(int256 answer) external onlyOwner {
        // Applies to EVERY push, the first included — that is the point (FIND-020).
        // Also subsumes the old positivity check: a negative answer is below MIN_ANSWER.
        if (answer < int256(MIN_ANSWER) || answer > int256(MAX_ANSWER)) {
            revert AnswerOutOfRange(answer);
        }

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

    /// @notice The exact EIP-712 digest the owner must sign to authorise `answer`, at the
    ///         CURRENT `emergencyNonce`.
    /// @dev    Signer parity by construction: an operator asks the contract for the digest
    ///         instead of rebuilding the domain off-chain, so a wrong chainId, wrong
    ///         verifyingContract, stale nonce or mis-encoded struct cannot happen. Same
    ///         contract as `GyldAtomicSwap.hashSwapMessage`, and the same reason.
    ///         Sign the returned 32 bytes RAW — no EIP-191 prefix, no second hash
    ///         (`cast wallet sign --no-hash`, or KMS `MessageType=DIGEST`).
    function hashEmergencyUpdate(int256 answer, uint256 deadline) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(EMERGENCY_TYPEHASH, answer, emergencyNonce, deadline)));
    }

    /// @notice Correct the NAV in ONE transaction, skipping the interval and deviation
    ///         guards, when the true price has gapped out of reach of a chained walk-back.
    /// @param  answer    The true NAV, 8dp. Must land in [EMERGENCY_MIN, EMERGENCY_MAX].
    /// @param  deadline  Unix time after which the owner's signature is void.
    /// @param  sig       Owner's EIP-712 signature over (answer, emergencyNonce, deadline).
    /// @dev    2-of-2 (audit FIND-003): the guardian is the only permitted CALLER, and the
    ///         signature must recover to `owner()` at execution time, so neither key acts
    ///         alone. Replay protection is nonce + deadline + signed `answer` + EIP-712
    ///         domain. OPERATIONAL RULE: sign with a SHORT `deadline` — there is no
    ///         on-chain cap, so an unused signature stands until it expires or the nonce
    ///         moves (residual D-29 (d)). Why this is not the D-7 bypass: see
    ///         `emergencyUpdater` above.
    function emergencyUpdateAnswer(int256 answer, uint256 deadline, bytes calldata sig) external {
        if (msg.sender != emergencyUpdater) revert NotEmergencyUpdater(msg.sender);
        // A correction, never an initialisation: the first push must go via updateAnswer.
        if (_updatedAt == 0) revert NoPriceSet();
        if (block.timestamp > deadline) revert EmergencySignatureExpired(deadline);
        if (lastEmergencyAt != 0 && block.timestamp < lastEmergencyAt + EMERGENCY_COOLDOWN) {
            revert EmergencyCooldownActive(lastEmergencyAt + EMERGENCY_COOLDOWN);
        }
        if (answer < int256(EMERGENCY_MIN_ANSWER) || answer > int256(EMERGENCY_MAX_ANSWER)) {
            revert EmergencyAnswerOutOfRange(answer);
        }

        address owner_ = owner();
        // Defence in depth behind the constructor and transferOwnership guards.
        if (owner_ == emergencyUpdater) revert OwnerCannotBeEmergencyUpdater();

        // Same helper the signer used, so on-chain and off-chain digests cannot diverge.
        bytes32 digest = hashEmergencyUpdate(answer, deadline);
        // SignatureChecker, not raw ECDSA: the owner may later be an ERC-1271 Safe.
        if (!SignatureChecker.isValidSignatureNow(owner_, digest, sig)) {
            revert EmergencySignerNotOwner();
        }

        int256 previous = _latestAnswer;
        unchecked { emergencyNonce += 1; }
        lastEmergencyAt = block.timestamp;
        _roundId += 1;
        _latestAnswer = answer;
        _updatedAt = block.timestamp;
        emit AnswerUpdated(answer, _roundId, block.timestamp);
        emit EmergencyAnswerUpdated(answer, _roundId, previous, emergencyNonce - 1);
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
