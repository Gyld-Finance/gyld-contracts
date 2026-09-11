// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract KaleidoscopeNAVFeedTest is Test {
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event StalenessThresholdUpdated(uint256 oldSeconds, uint256 newSeconds);

    KaleidoscopeNAVFeed feed;
    // The owner must be able to produce EIP-712 signatures for the emergency path, so it
    // is a derived key rather than a bare literal (audit FIND-003).
    uint256 constant OWNER_PK = 0xA11CE;
    address owner            = vm.addr(OWNER_PK);
    address stranger         = address(0xB2);
    address newOwner         = address(0xC3);
    address guardian         = address(0xD4);

    uint256 constant ONE_HOUR          = 1 hours;
    // Rescaled from $0.9542 by /100 when FIND-003 tightened MIN/MAX_ANSWER to $0.10-$5.00
    // for the $1.00 NAV standard. The deviation guard is multiplicative, so every band
    // relationship below is preserved exactly by the rescale.
    int256  constant ANSWER            = 95_420_000; // $0.9542
    int256  constant ANSWER_PLUS_SMALL = 95_420_001; // tiny move, well within 10%

    function setUp() public {
        feed = new KaleidoscopeNAVFeed(owner, "TLT / USD NAV", guardian);
    }

    // ── decimals ──────────────────────────────────────────────────────────────

    function test_decimals_isEight() public view {
        assertEq(feed.decimals(), 8);
    }

    // ── description ───────────────────────────────────────────────────────────

    function test_description_matchesConstructorArg() public view {
        assertEq(feed.description(), "TLT / USD NAV");
    }

    // ── updateAnswer — access control ─────────────────────────────────────────

    function test_updateAnswer_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        feed.updateAnswer(ANSWER);
    }

    function test_updateAnswer_ownerSucceeds() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
    }

    // ── updateAnswer — state transitions ──────────────────────────────────────

    function test_updateAnswer_storesAnswer() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
    }

    // Absolute timestamp literals, deliberately — see the note on
    // test_updateAnswer_emitsAnswerUpdated_secondRound below. `uint256 t0 =
    // block.timestamp` is NOT a snapshot under viaIR: solc treats `timestamp()`
    // as a movable, side-effect-free builtin and rematerialises it at each use
    // site, because it cannot model `vm.warp` (an opaque external call) as
    // mutating block context. A read of such a local after a warp therefore
    // yields the *current* time, not the captured one. Pinning both edges to
    // literals is strictly stronger than the relative arithmetic it replaces:
    // the expected values are now compile-time constants that no optimiser
    // setting can re-derive.
    uint256 constant T0 = 1_700_000_000;
    uint256 constant T1 = 1_700_086_400; // T0 + 1 days

    function test_updateAnswer_updatedAtAdvances() public {
        vm.warp(T0);
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, 1_700_000_000);

        vm.warp(T1);
        vm.prank(owner);
        feed.updateAnswer(ANSWER_PLUS_SMALL);
        (,,, uint256 updatedAt2,) = feed.latestRoundData();
        assertEq(updatedAt2, 1_700_086_400);
    }

    function test_updateAnswer_roundIdIncrements() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        vm.prank(owner);
        feed.updateAnswer(ANSWER_PLUS_SMALL);

        (uint80 roundId,,,,) = feed.latestRoundData();
        assertEq(roundId, 2);
    }

    // ── AnswerUpdated event ───────────────────────────────────────────────────

    function test_updateAnswer_emitsAnswerUpdated() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit AnswerUpdated(ANSWER, 1, block.timestamp);
        feed.updateAnswer(ANSWER);
    }

    function test_updateAnswer_emitsAnswerUpdated_secondRound() public {
        // Use explicit absolute timestamps — avoids --ir-minimum block.timestamp
        // read caching where block.timestamp before vm.warp leaks into the emit.
        vm.warp(1000);
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(1000 + ONE_HOUR);
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit AnswerUpdated(ANSWER_PLUS_SMALL, 2, 1000 + ONE_HOUR);
        feed.updateAnswer(ANSWER_PLUS_SMALL);
    }

    // ── MIN_UPDATE_INTERVAL ───────────────────────────────────────────────────

    function test_updateAnswer_firstUpdateAlwaysAllowed() public {
        // no previous price — no interval check
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
    }

    function test_updateAnswer_tooSoonReverts() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        // 59 minutes — not yet 1 hour
        vm.warp(block.timestamp + ONE_HOUR - 1);
        vm.prank(owner);
        vm.expectRevert();
        feed.updateAnswer(ANSWER_PLUS_SMALL);
    }

    function test_updateAnswer_exactlyOneHourAllowed() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        vm.prank(owner);
        feed.updateAnswer(ANSWER_PLUS_SMALL);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER_PLUS_SMALL);
    }

    // ── MAX_PRICE_DEVIATION_BPS ───────────────────────────────────────────────

    function test_updateAnswer_deviationCheckSkippedOnFirstUpdate() public {
        // Even a big price on first update is fine — no previous to compare
        vm.prank(owner);
        feed.updateAnswer(499_000_000); // $4.99 — 5x ANSWER, far beyond the 10% band
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 499_000_000);
    }

    function test_updateAnswer_within10PercentAllowed() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER); // 95_420_000

        vm.warp(block.timestamp + ONE_HOUR);
        // 9% move up: 95_420_000 * 1.09 = 104_007_800
        int256 ninePercentUp = (ANSWER * 109) / 100;
        vm.prank(owner);
        feed.updateAnswer(ninePercentUp);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ninePercentUp);
    }

    function test_updateAnswer_exactly10PercentAllowed() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        // exactly 10% up
        int256 tenPercentUp = (ANSWER * 110) / 100;
        vm.prank(owner);
        feed.updateAnswer(tenPercentUp);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, tenPercentUp);
    }

    function test_updateAnswer_over10PercentUpReverts() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        // 11% up
        int256 elevenPercentUp = (ANSWER * 111) / 100;
        vm.prank(owner);
        vm.expectRevert();
        feed.updateAnswer(elevenPercentUp);
    }

    function test_updateAnswer_over10PercentDownReverts() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        // 11% down
        int256 elevenPercentDown = (ANSWER * 89) / 100;
        vm.prank(owner);
        vm.expectRevert();
        feed.updateAnswer(elevenPercentDown);
    }

    function test_updateAnswer_zeroReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.AnswerOutOfRange.selector, int256(0)));
        feed.updateAnswer(0);
    }

    function test_updateAnswer_negativeReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.AnswerOutOfRange.selector, int256(-1)));
        feed.updateAnswer(-1);
    }

    // ── Absolute answer range (audit FIND-020) ────────────────────────────────

    /// The trap: the first push skips the deviation guard entirely, so a placeholder of 1
    /// used to be storable — and a stored value of 9 or less can never move again, because
    /// the smallest change gives 1 * 10_000 against at most 9 * 1_000. The feed is not
    /// upgradeable and has no reset, so that state was permanent.
    function test_updateAnswer_firstPushBelowFloorReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.AnswerOutOfRange.selector, int256(1)));
        feed.updateAnswer(1);
    }

    /// 9 was the highest value that bricked the feed; the floor sits far above it.
    function test_updateAnswer_firstPushAtTheBrickingBoundaryReverts() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.AnswerOutOfRange.selector, int256(9)));
        feed.updateAnswer(9);
    }

    /// The other end: above ~int256.max / BPS_DENOMINATOR the deviation arithmetic
    /// overflows and every later push panics. The ceiling keeps it unreachable.
    function test_updateAnswer_firstPushAboveCeilingReverts() public {
        int256 tooBig = int256(feed.MAX_ANSWER()) + 1; // cached before the prank
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.AnswerOutOfRange.selector, tooBig));
        feed.updateAnswer(tooBig);
    }

    function test_updateAnswer_rangeBoundariesAreInclusive() public {
        // Cache before pranking — the getter would otherwise consume it (see setUp).
        int256 floor_ = int256(feed.MIN_ANSWER());
        int256 ceiling = int256(feed.MAX_ANSWER());

        vm.prank(owner);
        feed.updateAnswer(floor_);
        assertEq(feed.latestAnswer(), floor_);

        KaleidoscopeNAVFeed f2 = new KaleidoscopeNAVFeed(owner, "ceiling", guardian);
        vm.prank(owner);
        f2.updateAnswer(ceiling);
        assertEq(f2.latestAnswer(), ceiling);
    }

    /// The range binds every push, not just the first — a healthy feed cannot be walked
    /// down below the floor either.
    function test_updateAnswer_rangeAppliesToLaterPushesToo() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.AnswerOutOfRange.selector, int256(5)));
        feed.updateAnswer(5);
    }

    /// A feed at the floor must still be able to move — proving the floor is above the
    /// stuck region rather than merely inside a legal-looking range.
    function test_updateAnswer_feedAtTheFloorCanStillMove() public {
        int256 floor_ = int256(feed.MIN_ANSWER());

        vm.prank(owner);
        feed.updateAnswer(floor_);

        vm.warp(block.timestamp + ONE_HOUR);
        vm.prank(owner);
        feed.updateAnswer(floor_ + 1); // 1 unit is well inside 10%
        assertEq(feed.latestAnswer(), floor_ + 1, "the floor is recoverable");
    }

    // ── latestRoundData ───────────────────────────────────────────────────────

    function test_latestRoundData_revertsBeforeFirstUpdate() public {
        vm.expectRevert(KaleidoscopeNAVFeed.NoPriceSet.selector);
        feed.latestRoundData();
    }

    function test_latestRoundData_returnsCorrectAnswer() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
    }

    function test_latestRoundData_returnsCorrectRoundId() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (uint80 roundId,,,,) = feed.latestRoundData();
        assertEq(roundId, 1);
    }

    function test_latestRoundData_answeredInRoundEqualsRoundId() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (uint80 roundId,,,, uint80 answeredInRound) = feed.latestRoundData();
        assertEq(answeredInRound, roundId);
    }

    /// Staleness is NOT an error condition for this feed. Past stalenessThreshold the read
    /// still succeeds and returns the last known NAV together with its true (old)
    /// `updatedAt`, so DeFi integrations keep functioning across weekends and holidays
    /// and consumers can age-check for themselves. See
    /// test_noStalenessRevertPathExists for the load-bearing version of this claim.
    function test_latestRoundData_byDesignDoesNotRevertOnStaleness_returnsLastNav() public {
        // Absolute timestamps throughout — a `block.timestamp` local captured before a
        // vm.warp can be re-read after it under --ir-minimum (see the comment on
        // test_updateAnswer_emitsAnswerUpdated_secondRound).
        vm.warp(1_000_000);
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(1_000_000 + 97 hours); // far past the 24h default stalenessThreshold
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
        // The staleness must be visible to the caller, not papered over: `updatedAt`
        // reports the original push time, never block.timestamp.
        assertEq(updatedAt, 1_000_000, "updatedAt must report the real (stale) push time");
    }

    function test_isFresh_trueBeforeStaleness() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(block.timestamp + 23 hours);
        assertTrue(feed.isFresh());
    }

    function test_isFresh_falseAfterStaleness() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(block.timestamp + 97 hours);
        assertFalse(feed.isFresh());
    }

    function test_isFresh_falseWhenNoPriceSet() public view {
        assertFalse(feed.isFresh());
    }

    // ── stalenessSeconds — monitoring entrypoint (GYL-1135) ───────────────────

    /// A never-initialised feed must be distinguishable from a just-updated one.
    /// Returning 0 here would make "no price has ever been pushed" look identical to
    /// "pushed this very block" to any threshold-based alert.
    function test_stalenessSeconds_maxWhenNoPriceSet() public view {
        assertEq(feed.stalenessSeconds(), type(uint256).max);
        assertFalse(feed.isFresh(), "isFresh and stalenessSeconds must agree on 'never set'");
    }

    function test_stalenessSeconds_tracksElapsed() public {
        vm.warp(1_000_000);
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        assertEq(feed.stalenessSeconds(), 0, "zero in the push block");

        vm.warp(1_000_000 + 3 hours);
        assertEq(feed.stalenessSeconds(), 3 hours);

        // Past stalenessThreshold it keeps counting rather than saturating or reverting —
        // an alert needs the magnitude to escalate on, which is exactly what the live
        // production feed (silent since 2026-05-19) had no way to expose.
        vm.warp(1_000_000 + 100 days);
        assertEq(feed.stalenessSeconds(), 100 days);
        assertFalse(feed.isFresh());

        // A fresh push resets it.
        vm.prank(owner);
        feed.updateAnswer(ANSWER_PLUS_SMALL);
        assertEq(feed.stalenessSeconds(), 0);
        assertTrue(feed.isFresh());
    }

    // ── The Chainlink-compat decision, pinned (GYL-1135) ─────────────────────

    /// LOAD-BEARING. This feed has exactly ONE revert path on reads — NoPriceSet — and
    /// staleness is deliberately not one of them.
    ///
    /// Do not "fix" this by adding a freshness gate to latestRoundData / latestAnswer /
    /// getRoundData. Chainlink's own aggregators do not revert on stale answers; they
    /// return the last answer with its true `updatedAt` and leave the age check to the
    /// consumer. Two live integrations demonstrated both halves of that contract during
    /// the 2026-05 feed outage: Euler applied its own check and froze correctly, while
    /// Morpho applied none and kept quoting the last pushed price. Reverting here would
    /// have punished Euler for behaving correctly, destroyed the `updatedAt` signal that
    /// made the outage diagnosable, and — worst — frozen Morpho *liquidations*, the one
    /// operation that must keep working while a market is unhealthy, with no way to
    /// unwind it. The defence belongs in consumers (see GyldAtomicSwap.StaleNav) and in
    /// ops alerting, not in the read path.
    ///
    /// If a future requirement genuinely needs a reverting feed, deploy a separate
    /// wrapper contract; do not change these semantics under integrators already live.
    function test_noStalenessRevertPathExists() public {
        // Absolute timestamps — see test_latestRoundData_byDesignDoesNotRevertOnStaleness.
        vm.warp(1_000_000);
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        // Far beyond any plausible threshold: 1000 days, ~1000x the default window.
        vm.warp(1_000_000 + 1000 days);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(answer, ANSWER, "latestRoundData must still return the last NAV");
        assertEq(updatedAt, 1_000_000, "and must report the true, ancient updatedAt");
        assertEq(startedAt, 1_000_000);
        assertEq(roundId, 1);
        assertEq(answeredInRound, roundId);

        assertEq(feed.latestAnswer(), ANSWER, "latestAnswer (Aave V3 path) must not revert either");

        (, int256 histAnswer,, uint256 histUpdatedAt,) = feed.getRoundData(1);
        assertEq(histAnswer, ANSWER, "getRoundData must not revert either");
        assertEq(histUpdatedAt, 1_000_000);

        // Staleness is reported, not enforced.
        assertFalse(feed.isFresh(), "isFresh is the signal that this price is unusable");
        assertEq(feed.stalenessSeconds(), 1000 days);
    }

    function test_latestRoundData_recoversAfterNewUpdate() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        // Warp well past stalenessThreshold, then push again. 97 h is >> the 1 h
        // MIN_UPDATE_INTERVAL, so the second push is unobstructed.
        vm.warp(block.timestamp + 97 hours);
        vm.prank(owner);
        feed.updateAnswer(ANSWER_PLUS_SMALL);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER_PLUS_SMALL);
    }

    // ── latestAnswer (Aave V3 compat) ────────────────────────────────────────

    function test_latestAnswer_revertsBeforeFirstUpdate() public {
        vm.expectRevert(KaleidoscopeNAVFeed.NoPriceSet.selector);
        feed.latestAnswer();
    }

    function test_latestAnswer_returnsCurrentPrice() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        assertEq(feed.latestAnswer(), ANSWER);
    }

    function test_latestAnswer_returnsLastPriceWhenStale() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(block.timestamp + 97 hours);
        assertEq(feed.latestAnswer(), ANSWER);
    }

    // ── version ───────────────────────────────────────────────────────────────

    function test_version_isThree() public view {
        assertEq(feed.version(), 3);
    }

    // ── getRoundData ──────────────────────────────────────────────────────────

    function test_getRoundData_returnsCurrentRound() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (uint80 rId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
            = feed.getRoundData(1);
        assertEq(rId,             1);
        assertEq(answer,          ANSWER);
        assertEq(startedAt,       updatedAt);
        assertGt(updatedAt,       0);
        assertEq(answeredInRound, 1);
    }

    function test_getRoundData_wrongRoundId_reverts() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.expectRevert();
        feed.getRoundData(2);
    }

    function test_getRoundData_revertsBeforeFirstUpdate() public {
        // roundId 0 matches _roundId (both zero), so the roundId check passes;
        // the `_updatedAt == 0` guard then fires with NoPriceSet. That is the ONLY
        // revert path on this read — there is no freshness gate here.
        vm.expectRevert(KaleidoscopeNAVFeed.NoPriceSet.selector);
        feed.getRoundData(0);
    }

    // ── deviation boundary — downward ─────────────────────────────────────────

    function test_updateAnswer_exactly10PercentDownAllowed() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        // exactly 10% down: ANSWER * 90 / 100
        int256 tenPercentDown = (ANSWER * 90) / 100;
        vm.prank(owner);
        feed.updateAnswer(tenPercentDown);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, tenPercentDown);
    }

    /// Prices within 10% (inclusive) downward of the previous price are always accepted.
    function testFuzz_updateAnswer_withinDeviationDown_succeeds(uint16 bps) external {
        bps = uint16(bound(uint256(bps), 0, 1000)); // 0–10%
        vm.prank(owner); feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        int256 newAnswer = ANSWER - (ANSWER * int256(uint256(bps))) / 10_000;
        vm.assume(newAnswer > 0);
        vm.prank(owner);
        feed.updateAnswer(newAnswer);
        (, int256 stored,,,) = feed.latestRoundData();
        assertEq(stored, newAnswer);
    }

    // ── fuzz: deviation boundary ──────────────────────────────────────────────

    /// Prices within 10% (inclusive) of the previous price are always accepted.
    function testFuzz_updateAnswer_withinDeviation_succeeds(uint16 bps) external {
        bps = uint16(bound(uint256(bps), 0, 1000)); // 0–10%
        vm.prank(owner); feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        int256 newAnswer = ANSWER + (ANSWER * int256(uint256(bps))) / 10_000;
        vm.assume(newAnswer > 0);
        vm.prank(owner);
        feed.updateAnswer(newAnswer);
        (, int256 stored,,,) = feed.latestRoundData();
        assertEq(stored, newAnswer);
    }

    /// Prices more than 10% above the previous price always revert.
    function testFuzz_updateAnswer_overDeviationUp_reverts(uint256 bps) external {
        bps = bound(bps, 1001, 20_000);
        vm.prank(owner); feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + ONE_HOUR);
        int256 newAnswer = ANSWER + (ANSWER * int256(bps)) / 10_000;
        vm.assume(newAnswer > 0);
        vm.prank(owner);
        vm.expectRevert();
        feed.updateAnswer(newAnswer);
    }

    // ── Ownable2Step — two-step ownership transfer ────────────────────────────

    function test_owner_isSetInConstructor() public view {
        assertEq(feed.owner(), owner);
    }

    function test_transferOwnership_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        feed.transferOwnership(newOwner);
    }

    function test_transferOwnership_setsPendingOwner() public {
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        assertEq(feed.pendingOwner(), newOwner);
    }

    function test_acceptOwnership_wrongAddressReverts() public {
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        vm.prank(stranger);
        vm.expectRevert();
        feed.acceptOwnership();
    }

    function test_acceptOwnership_completesTransfer() public {
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        vm.prank(newOwner);
        feed.acceptOwnership();
        assertEq(feed.owner(), newOwner);
    }

    function test_newOwner_canUpdateAnswer() public {
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        vm.prank(newOwner);
        feed.acceptOwnership();
        vm.prank(newOwner);
        feed.updateAnswer(ANSWER);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
    }

    function test_oldOwner_cannotUpdateAnswerAfterTransfer() public {
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        vm.prank(newOwner);
        feed.acceptOwnership();
        vm.prank(owner);
        vm.expectRevert();
        feed.updateAnswer(ANSWER);
    }

    // ── renounceOwnership is disabled (GLD-165) ──────────────────────────────

    /// The feed is not upgradeable and its reads never revert on staleness, so a
    /// renounce would freeze the published NAV forever with no recovery path.
    function test_renounceOwnership_ownerReverts() public {
        vm.prank(owner);
        vm.expectRevert(KaleidoscopeNAVFeed.CannotRenounceOwnership.selector);
        feed.renounceOwnership();
        assertEq(feed.owner(), owner, "owner must be unchanged");
    }

    /// Same error for a non-owner: the call can never succeed for anyone, so it
    /// must not report "not owner" and imply the owner could have done it.
    function test_renounceOwnership_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(KaleidoscopeNAVFeed.CannotRenounceOwnership.selector);
        feed.renounceOwnership();
        assertEq(feed.owner(), owner, "owner must be unchanged");
    }

    /// Premise the `_transferOwnership` comment now rests on: OZ's constructor
    /// rejects a zero initialOwner, so that is not a back door to an ownerless
    /// feed. Pinned so the zero path cannot reopen silently if `Ownable(...)` is
    /// ever swapped for a custom initialiser.
    function test_constructor_zeroOwnerReverts() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new KaleidoscopeNAVFeed(address(0), "TLT / USD NAV", guardian);
    }

    /// The other premise: transferOwnership(address(0)) cancels a pending transfer
    /// and never changes owner(), so it is not a renounce by another name.
    function test_transferOwnership_zeroCancelsPendingWithoutChangingOwner() public {
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        assertEq(feed.pendingOwner(), newOwner);

        vm.prank(owner);
        feed.transferOwnership(address(0));
        assertEq(feed.pendingOwner(), address(0), "pending must be cleared");
        assertEq(feed.owner(), owner, "owner must be unchanged");

        // The cancelled heir can no longer claim it.
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        feed.acceptOwnership();
    }

    /// The feed must remain fully operable after a rejected renounce — the guard
    /// blocks the renounce, it does not brick the contract it protects.
    function test_renounceOwnership_feedStillUsableAfterRejectedRenounce() public {
        vm.prank(owner);
        vm.expectRevert(KaleidoscopeNAVFeed.CannotRenounceOwnership.selector);
        feed.renounceOwnership();

        vm.prank(owner);
        feed.updateAnswer(95_420_000);
        assertEq(feed.latestAnswer(), 95_420_000);
    }

    /// Accepting must clear `pendingOwner` and fully revoke the old key. This pins the
    /// completion funnel's real post-conditions directly rather than leaning on a
    /// happy-path `owner()` read. Its emergency-path counterpart is
    /// test_emergency_signatureIsCheckedAgainstTheOwnerAtExecutionTime, which proves the
    /// same revocation reaches the co-signing authority in the same instant.
    function test_acceptOwnership_clearsPendingOwnerAndRevokesOldOwner() public {
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        vm.prank(newOwner);
        feed.acceptOwnership();

        assertEq(feed.owner(), newOwner, "owner must be the acceptor");
        assertEq(feed.pendingOwner(), address(0), "pendingOwner must be cleared on accept");

        // The old key retains nothing: neither price authority nor the ability to
        // start another handoff.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        feed.transferOwnership(stranger);

        // And a replay of acceptOwnership by the (now former) pending owner fails —
        // pendingOwner is address(0), so nobody is authorised.
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        feed.acceptOwnership();
    }

    // ── Emergency correction path — fixtures and helpers (audit FIND-003) ─────

    event EmergencyAnswerUpdated(int256 indexed answer, uint256 indexed roundId, int256 previousAnswer, uint256 nonce);

    /// A second keypair, used to prove the signature is recovered against `owner()` at
    /// EXECUTION time rather than against whoever owned the feed when it was signed.
    uint256 constant ROTATED_PK = 0xB0B;
    address rotatedOwner = vm.addr(ROTATED_PK);
    /// Any key that is not the owner's. Used for the wrong-signer case.
    uint256 constant IMPOSTOR_PK = 0xBAD;

    /// $1.50 — +57% from ANSWER ($0.9542), far outside the 10% band, and inside
    /// [EMERGENCY_MIN_ANSWER, EMERGENCY_MAX_ANSWER].
    int256 constant EMERGENCY_ANSWER = 150_000_000;
    /// $1.20 — a second in-band emergency target, for the tests that need two.
    int256 constant EMERGENCY_ANSWER_2 = 120_000_000;
    /// A deadline that cannot expire, for the tests that are not about deadlines.
    uint256 constant FAR_FUTURE = type(uint256).max;

    /// Restated literally rather than read from the getter, so a silent change to the
    /// signed struct breaks these tests instead of being followed along.
    /// test_emergency_typehashAndDomainMatchTheContract pins the two together.
    bytes32 constant EMERGENCY_TYPEHASH_LOCAL =
        keccak256("EmergencyUpdate(int256 answer,uint256 nonce,uint256 deadline)");
    bytes32 constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    /// Rebuilt from the spec rather than read off the contract: the domain binds chainid
    /// and the feed address, and that binding is half the replay defence.
    function _domainSeparator(address feedAddr) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("KaleidoscopeNAVFeed")),
                keccak256(bytes("1")),
                block.chainid,
                feedAddr
            )
        );
    }

    function _emergencyDigest(address feedAddr, int256 answer, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encodePacked(
                hex"1901",
                _domainSeparator(feedAddr),
                keccak256(abi.encode(EMERGENCY_TYPEHASH_LOCAL, answer, nonce, deadline))
            )
        );
    }

    function _sign(uint256 pk, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    /// A signature by `pk` over the feed's CURRENT nonce.
    ///
    /// ALWAYS call this BEFORE `vm.prank(guardian)`: it makes an external call
    /// (`emergencyNonce()`), and a prank is consumed by the next external call whatever
    /// that call is. Computing a signature after the prank silently spends it and the
    /// emergency call then arrives from the test contract, failing with
    /// NotEmergencyUpdater for a reason that has nothing to do with the test.
    function _sigBy(uint256 pk, int256 answer, uint256 deadline) internal view returns (bytes memory) {
        return _sign(pk, _emergencyDigest(address(feed), answer, feed.emergencyNonce(), deadline));
    }

    function _ownerSig(int256 answer, uint256 deadline) internal view returns (bytes memory) {
        return _sigBy(OWNER_PK, answer, deadline);
    }

    /// The normal first push. The emergency path is a CORRECTION, so every test below
    /// that expects it to get past `NoPriceSet` needs this first.
    function _seedPrice() internal {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
    }

    // ── The emergency key has no appointment surface (audit FIND-003 / D-7) ───

    /// LOAD-BEARING. FIND-003 reinstated an emergency correction path, so
    /// `emergencyUpdateAnswer` and the `emergencyUpdater()` getter DO now exist. The thing
    /// D-7 actually died on must not: an APPOINTMENT surface. `setEmergencyUpdater` was
    /// `onlyOwner`, and this feed's owner is the KMS signer rather than a timelock, so one
    /// compromised key could appoint a second address it also controlled and then hold the
    /// whole bypass alone — a 2-of-2 on paper, a 1-of-1 in practice.
    ///
    /// What replaces it: `emergencyUpdater` is `immutable` with no setter at all, and
    /// `transferOwnership` refuses to hand ownership to it (see
    /// test_transferOwnership_toTheGuardianReverts), so no transaction can collapse the
    /// two roles onto one address.
    ///
    /// This asserts the absence at the ABI level rather than trusting that the source
    /// never grows a setter back: the contract declares no fallback, so a call carrying a
    /// selector it does not implement reverts and `success` is false. If `setOk` ever
    /// returns true, D-7 is back and the entire FIND-003 security argument collapses with
    /// it — the emergency band being a strict subset of the normal one
    /// (test_emergencyRangeIsStrictSubsetOfNormalRange) only buys anything while the
    /// second key is genuinely a second key.
    function test_emergencyKeyIsImmutableAndUnappointable() public {
        vm.startPrank(owner);

        (bool setOk,) = address(feed).call(abi.encodeWithSignature("setEmergencyUpdater(address)", stranger));
        assertFalse(setOk, "setEmergencyUpdater(address) must never exist");

        (bool setOk2,) = address(feed).call(abi.encodeWithSignature("setGuardian(address)", stranger));
        assertFalse(setOk2, "nor under any other name");

        // The D-19 shape — an unbounded, single-argument, owner-only instant price
        // primitive — must also stay gone. What exists is the co-signed three-argument
        // form, and nothing else.
        (bool oldShapeOk,) = address(feed).call(abi.encodeWithSignature("emergencyUpdateAnswer(int256)", ANSWER));
        assertFalse(oldShapeOk, "the unsigned one-argument emergency setter must never exist");

        // Positive control 1: the selector that DOES exist is dispatched. The owner is not
        // the guardian, so it reverts — but with NotEmergencyUpdater, which only the
        // function body can produce. A missing selector would revert with empty data.
        bytes memory emergencyCall =
            abi.encodeWithSignature("emergencyUpdateAnswer(int256,uint256,bytes)", ANSWER, FAR_FUTURE, "");
        (bool updOk, bytes memory ret) = address(feed).call(emergencyCall);
        assertFalse(updOk, "the owner is not the guardian");
        assertEq(bytes4(ret), KaleidoscopeNAVFeed.NotEmergencyUpdater.selector, "the function exists and ran");

        // Positive control 2: the same low-level call shape succeeds against a selector
        // the feed implements, so the assertions above are about missing functions and
        // not about a malformed call or a blanket-reverting contract.
        (bool ctrlOk,) = address(feed).call(abi.encodeWithSignature("updateAnswer(int256)", ANSWER));
        assertTrue(ctrlOk, "control: updateAnswer(int256) still exists and is callable");

        vm.stopPrank();

        // And the guardian is readable, fixed at construction, and is the address setUp
        // passed — an immutable with a getter, not a mutable slot.
        assertEq(feed.emergencyUpdater(), guardian, "the guardian is the constructor argument");
    }

    /// Guards every other test in this file: the helpers above rebuild the EIP-712 domain
    /// and struct from the spec, so if the contract's domain or type hash ever moved, the
    /// signatures would stop verifying and every positive test here would fail for an
    /// unrelated reason. This pins the two representations together directly.
    function test_emergency_typehashAndDomainMatchTheContract() public view {
        assertEq(feed.EMERGENCY_TYPEHASH(), EMERGENCY_TYPEHASH_LOCAL, "type hash");

        (, string memory name, string memory version_, uint256 chainId, address verifying,,) = feed.eip712Domain();
        assertEq(name, "KaleidoscopeNAVFeed");
        assertEq(version_, "1");
        assertEq(chainId, block.chainid, "the domain binds the chain - a fork cannot replay");
        assertEq(verifying, address(feed), "and binds this feed - a sibling feed cannot replay");
    }

    /// SIGNER PARITY. `hashEmergencyUpdate` is the operator's entry point: it is what a
    /// KMS/Fordefi signer is handed, so it must equal an independently-built EIP-712
    /// digest, and it must track `emergencyNonce` as that nonce advances. The helper
    /// existing is the whole reason an operator never rebuilds the domain by hand — the
    /// same contract `GyldAtomicSwap.hashSwapMessage` provides.
    function test_emergency_hashHelperMatchesAnIndependentDigest() public {
        vm.warp(T0);
        _seedPrice();

        uint256 deadline = T0 + 10 minutes;
        assertEq(
            feed.hashEmergencyUpdate(EMERGENCY_ANSWER, deadline),
            _emergencyDigest(address(feed), EMERGENCY_ANSWER, feed.emergencyNonce(), deadline),
            "helper must equal the independently-computed digest"
        );

        // It is nonce-sensitive: after a correction the SAME arguments hash differently,
        // which is what makes a consumed signature unusable.
        bytes32 before = feed.hashEmergencyUpdate(EMERGENCY_ANSWER, deadline);
        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, deadline);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, deadline, sig);
        assertEq(feed.emergencyNonce(), 1, "nonce advanced");
        assertTrue(feed.hashEmergencyUpdate(EMERGENCY_ANSWER, deadline) != before, "digest must follow the nonce");
    }

    // ── Emergency path — access control and key separation ────────────────────

    /// The happy path, and the shape of the 2-of-2: the guardian CALLS, the owner SIGNS.
    function test_emergency_guardianWithOwnerSignatureSucceeds() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);

        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER, "the correction landed");
        assertEq(feed.emergencyNonce(), 1, "the signature is spent");
        assertEq(feed.lastEmergencyAt(), T0, "the cooldown clock started");
    }

    /// A stolen guardian key is worth nothing on its own: it cannot forge the owner's
    /// signature, and it holds no other power on this contract
    /// (test_emergency_guardianHoldsNoOtherPower).
    function test_emergency_missingSignatureReverts() public {
        vm.warp(T0);
        _seedPrice();

        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencySignerNotOwner.selector);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, "");
    }

    function test_emergency_garbageSignatureReverts() public {
        vm.warp(T0);
        _seedPrice();

        // 65 bytes of the right shape and none of the right content.
        bytes memory garbage = new bytes(65);
        for (uint256 i = 0; i < 65; i++) {
            garbage[i] = 0xab;
        }

        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencySignerNotOwner.selector);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, garbage);
    }

    /// A well-formed signature over the correct digest, by the wrong key.
    function test_emergency_wrongSignerReverts() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory impostorSig = _sigBy(IMPOSTOR_PK, EMERGENCY_ANSWER, FAR_FUTURE);
        bytes memory ownerSig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);

        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencySignerNotOwner.selector);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, impostorSig);

        // Control: the identical call with the OWNER's signature over the same digest
        // succeeds at this instant, so the rejection above is the signer and nothing else.
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, ownerSig);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER);
    }

    /// THE point of the two-key split. A compromised owner key gains nothing here beyond
    /// what it already has (+/-10 %/h): it can sign, but it cannot make the call, even
    /// holding a perfectly valid signature of its own.
    function test_emergency_ownerCannotCallItEvenWithAValidSignature() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.NotEmergencyUpdater.selector, owner));
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);
        assertEq(feed.latestAnswer(), ANSWER, "the price must be untouched");

        // Control: the same signature, submitted by the guardian, is accepted.
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER);
    }

    /// The owner's signature is inert in the mempool: anyone can see it, nobody but the
    /// guardian can use it.
    function test_emergency_strangerCannotCallItEvenWithAValidSignature() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.NotEmergencyUpdater.selector, stranger));
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);

        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER, "control: the guardian may use it");
    }

    /// The other half of the split. The guardian is not a second owner: it holds exactly
    /// one capability, and only jointly with the owner's signature.
    function test_emergency_guardianHoldsNoOtherPower() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        bytes memory unauthorised = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian);

        vm.prank(guardian);
        vm.expectRevert(unauthorised);
        feed.updateAnswer(ANSWER_PLUS_SMALL);

        vm.prank(guardian);
        vm.expectRevert(unauthorised);
        feed.setStalenessThreshold(20 hours);

        // `stranger`, not `guardian`, as the target: OwnerCannotBeEmergencyUpdater is
        // checked before the ownership modifier, and this test is about the modifier.
        vm.prank(guardian);
        vm.expectRevert(unauthorised);
        feed.transferOwnership(stranger);

        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.CannotRenounceOwnership.selector);
        feed.renounceOwnership();

        // Control: the one thing it CAN do, it can do — so the four rejections above are
        // about those functions and not about a guardian that is somehow inert.
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER);
        assertEq(feed.owner(), owner, "and it is still not the owner");
    }

    /// If one address ever held both roles the 2-of-2 would be a 1-of-1 — D-7 reached by
    /// a different route. `transferOwnership` is the only writer of `pendingOwner`, so
    /// guarding it is sufficient: `acceptOwnership` can never see the guardian.
    function test_transferOwnership_toTheGuardianReverts() public {
        vm.prank(owner);
        vm.expectRevert(KaleidoscopeNAVFeed.OwnerCannotBeEmergencyUpdater.selector);
        feed.transferOwnership(guardian);
        assertEq(feed.pendingOwner(), address(0), "no pending transfer may be recorded");

        // Control: the same call to any other address still works, so the guard is
        // specific to the guardian and has not simply broken ownership transfer.
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        assertEq(feed.pendingOwner(), newOwner);
    }

    function test_constructor_rejectsZeroGuardian() public {
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.InvalidEmergencyUpdater.selector, address(0)));
        new KaleidoscopeNAVFeed(owner, "TLT / USD NAV", address(0));
    }

    /// The 1-of-1 collapse, blocked at birth rather than only at transfer.
    function test_constructor_rejectsGuardianEqualToOwner() public {
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.InvalidEmergencyUpdater.selector, owner));
        new KaleidoscopeNAVFeed(owner, "TLT / USD NAV", owner);
    }

    /// The third constructor case IS testable: the feed's own address is a pure function
    /// of (deployer, nonce), so it can be computed before the CREATE that produces it.
    function test_constructor_rejectsGuardianEqualToTheFeedItself() public {
        // Control first — prove the prediction is exact, otherwise the assertion below
        // would pass for any address that merely happens not to be a valid guardian.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        KaleidoscopeNAVFeed control = new KaleidoscopeNAVFeed(owner, "control", guardian);
        assertEq(address(control), predicted, "the CREATE address is predictable");

        // A reverted CREATE still consumes the deployer's nonce, so re-predict.
        address self = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.InvalidEmergencyUpdater.selector, self));
        new KaleidoscopeNAVFeed(owner, "self-guardian", self);
    }

    /// The signature is recovered against `owner()` AT EXECUTION TIME, not against a
    /// snapshot taken at construction. A rotation therefore revokes the old key's ability
    /// to authorise emergencies in the same instant it revokes everything else — there is
    /// no window in which a retired key can still co-sign.
    function test_emergency_signatureIsCheckedAgainstTheOwnerAtExecutionTime() public {
        vm.warp(T0);
        _seedPrice();

        vm.prank(owner);
        feed.transferOwnership(rotatedOwner);
        vm.prank(rotatedOwner);
        feed.acceptOwnership();
        assertEq(feed.owner(), rotatedOwner);

        uint256 nonce = feed.emergencyNonce();
        bytes memory oldOwnerSig = _sign(OWNER_PK, _emergencyDigest(address(feed), EMERGENCY_ANSWER, nonce, FAR_FUTURE));
        bytes memory newOwnerSig =
            _sign(ROTATED_PK, _emergencyDigest(address(feed), EMERGENCY_ANSWER, nonce, FAR_FUTURE));

        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencySignerNotOwner.selector);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, oldOwnerSig);

        // The failed call consumed no nonce, so the new owner's signature over the SAME
        // nonce is still the right one.
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, newOwnerSig);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER, "the current owner's signature works");
    }

    // ── Emergency path — replay and signature binding ─────────────────────────

    /// The nonce is consumed, so a signature is worth exactly one correction.
    ///
    /// The warp is load-bearing: replayed inside EMERGENCY_COOLDOWN the call would be
    /// refused by the cooldown and this test would prove nothing about the nonce. Asserting
    /// the specific error — and re-succeeding with a fresh signature at the same
    /// timestamp — makes the distinction real.
    function test_emergency_replayOfAConsumedNonceReverts() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);
        assertEq(feed.emergencyNonce(), 1, "the nonce advanced");

        vm.warp(T0 + feed.EMERGENCY_COOLDOWN());
        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencySignerNotOwner.selector);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);

        // Control: a signature over the NEW nonce is accepted at this very timestamp, so
        // the rejection above is the consumed nonce and not the cooldown.
        bytes memory fresh = _ownerSig(EMERGENCY_ANSWER_2, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER_2, FAR_FUTURE, fresh);
        assertEq(feed.emergencyNonce(), 2);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER_2);
    }

    /// The deadline bounds how long a co-signature sits usable. The comparison is
    /// `block.timestamp > deadline`, so the deadline second itself is still valid.
    function test_emergency_expiredDeadlineReverts() public {
        vm.warp(T0);
        _seedPrice();

        uint256 deadline = T0 + 10 minutes;
        bytes memory expiring = _ownerSig(EMERGENCY_ANSWER, deadline);

        vm.warp(deadline + 1);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.EmergencySignatureExpired.selector, deadline));
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, deadline, expiring);

        // Control: an otherwise identical signature whose deadline is exactly NOW is
        // accepted, so the rejection above is the deadline and the boundary is inclusive.
        bytes memory live = _ownerSig(EMERGENCY_ANSWER, deadline + 1);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, deadline + 1, live);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER);
    }

    /// `answer` is inside the signed struct, so a co-signature authorising $1.50 cannot be
    /// re-aimed at $1.20 by the guardian alone. Without this the guardian would hold a
    /// unilateral in-band price primitive on the strength of one owner approval.
    function test_emergency_signatureIsBoundToTheAnswer() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory sigForA = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);

        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencySignerNotOwner.selector);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER_2, FAR_FUTURE, sigForA);
        assertEq(feed.latestAnswer(), ANSWER, "no price moved");

        // Control: the same signature against the answer it actually authorises.
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sigForA);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER);
    }

    /// The reviewer's question in code: `deadline` is a plain calldata argument, so can
    /// the SUBMITTER simply pass a later one and keep a dead signature alive? No — the
    /// deadline is inside the signed struct, so changing it changes the digest and the
    /// signature stops recovering to the owner. The expiry is therefore chosen by the
    /// SIGNER and is not forgeable by the guardian, which is what makes the
    /// `block.timestamp > deadline` check meaningful rather than advisory.
    function test_emergency_signatureIsBoundToTheDeadline() public {
        vm.warp(T0);
        _seedPrice();

        uint256 signedDeadline = T0 + 10 minutes;
        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, signedDeadline);

        // Past the signed deadline, the guardian tries to buy itself another hour by
        // passing a later value than the owner ever authorised.
        vm.warp(signedDeadline + 1);
        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencySignerNotOwner.selector);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, signedDeadline + 3600, sig);
        assertEq(feed.latestAnswer(), ANSWER, "no price moved");

        // Passing the HONEST deadline does not rescue it either — that is the time check.
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(KaleidoscopeNAVFeed.EmergencySignatureExpired.selector, signedDeadline)
        );
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, signedDeadline, sig);

        // Control: the identical call one second before expiry succeeds, so the two
        // rejections above are the deadline and not some other guard.
        vm.warp(signedDeadline);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, signedDeadline, sig);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER, "the boundary second is still valid");
    }

    // ── Emergency path — the bypass, and the band that bounds it ──────────────

    /// The whole point: one transaction, no chained walk, no hourly waits.
    function test_emergency_bypassesTheDeviationCap() public {
        vm.warp(T0);
        _seedPrice(); // $0.9542

        // Control: the identical jump through the normal path, a full hour later and
        // therefore past MIN_UPDATE_INTERVAL, is refused — +57% against a 10% cap.
        vm.warp(T0 + ONE_HOUR);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(KaleidoscopeNAVFeed.PriceDeviationTooLarge.selector, EMERGENCY_ANSWER, ANSWER)
        );
        feed.updateAnswer(EMERGENCY_ANSWER);

        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);

        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER, "the emergency path takes it in one step");
        (uint80 roundId,,,,) = feed.latestRoundData();
        assertEq(roundId, 2, "one round, not the several a chained walk would cost");
    }

    /// The other guard it skips. This runs in the SAME block as the normal push, the
    /// hardest case for the interval check.
    function test_emergency_bypassesTheMinUpdateInterval() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);

        // Control: the owner's own path is refused at this instant, zero seconds in.
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.UpdateTooSoon.selector, T0 + ONE_HOUR));
        feed.updateAnswer(ANSWER_PLUS_SMALL);

        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER, "no interval applies to a correction");
        assertEq(feed.stalenessSeconds(), 0);
    }

    /// LOAD-BEARING. This pins the entire security argument for FIND-003 in one place:
    /// the emergency band is a STRICT SUBSET of the normal one, so the guardian pair buys
    /// LATENCY, not REACH. Every price the two keys can reach instantly, the owner key
    /// could already reach alone by chaining +/-10% hourly pushes
    /// (test_chainedUpdates_escapeTheBand shows the mechanism); worst case $0.10 -> $2.00
    /// is 32 pushes. That is what separates this path from the unbounded one deleted as
    /// D-19.
    ///
    /// The shipped values are asserted alongside the inequality on purpose. The inequality
    /// alone would still hold if someone widened BOTH bands together, which would silently
    /// grow the reach of the emergency path while this test kept passing. Retuning one
    /// bound must break this test loudly and force the argument to be re-made.
    function test_emergencyRangeIsStrictSubsetOfNormalRange() public view {
        assertEq(feed.MIN_ANSWER(), 1e7, "MIN_ANSWER = $0.10");
        assertEq(feed.MAX_ANSWER(), 5e8, "MAX_ANSWER = $5.00");
        assertEq(feed.EMERGENCY_MIN_ANSWER(), 5e7, "EMERGENCY_MIN_ANSWER = $0.50");
        assertEq(feed.EMERGENCY_MAX_ANSWER(), 2e8, "EMERGENCY_MAX_ANSWER = $2.00");

        assertLt(feed.MIN_ANSWER(), feed.EMERGENCY_MIN_ANSWER(), "the emergency floor must sit ABOVE the normal one");
        assertLt(feed.EMERGENCY_MAX_ANSWER(), feed.MAX_ANSWER(), "the emergency ceiling must sit BELOW the normal one");

        // And the rate limit. Parity with MIN_UPDATE_INTERVAL is the claim: the emergency
        // path buys reach-within-band and freedom from intermediate prices, but NOT
        // frequency. A cooldown longer than the routine interval would rate-limit the
        // operator rather than an attacker, who holds the hourly owner key anyway.
        assertEq(feed.EMERGENCY_COOLDOWN(), 1 hours);
        assertEq(feed.EMERGENCY_COOLDOWN(), feed.MIN_UPDATE_INTERVAL(), "no path writes faster than hourly");
    }

    /// Both emergency bounds are inclusive, matching the normal path's
    /// (test_updateAnswer_rangeBoundariesAreInclusive).
    function test_emergency_bandBoundariesAreInclusive() public {
        int256 floor_ = int256(feed.EMERGENCY_MIN_ANSWER());
        int256 ceiling = int256(feed.EMERGENCY_MAX_ANSWER());

        vm.warp(T0);
        _seedPrice();

        bytes memory sigLo = _ownerSig(floor_, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(floor_, FAR_FUTURE, sigLo);
        assertEq(feed.latestAnswer(), floor_, "$0.50 exactly is accepted");

        vm.warp(T0 + feed.EMERGENCY_COOLDOWN());
        bytes memory sigHi = _ownerSig(ceiling, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(ceiling, FAR_FUTURE, sigHi);
        assertEq(feed.latestAnswer(), ceiling, "$2.00 exactly is accepted");
    }

    /// One unit below the floor. $0.4999... is a perfectly legal answer for the NORMAL
    /// path — that is exactly the point of a narrower emergency band.
    function test_emergency_belowTheBandReverts() public {
        int256 tooLow = int256(feed.EMERGENCY_MIN_ANSWER()) - 1;
        assertGt(tooLow, int256(feed.MIN_ANSWER()), "the rejected value is legal for updateAnswer");

        vm.warp(T0);
        _seedPrice();

        // A fully valid signature, so the range guard is the only thing that can fire.
        bytes memory sig = _ownerSig(tooLow, FAR_FUTURE);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.EmergencyAnswerOutOfRange.selector, tooLow));
        feed.emergencyUpdateAnswer(tooLow, FAR_FUTURE, sig);
        assertEq(feed.latestAnswer(), ANSWER, "nothing moved");
        assertEq(feed.emergencyNonce(), 0, "and nothing was consumed");
    }

    function test_emergency_aboveTheBandReverts() public {
        int256 tooHigh = int256(feed.EMERGENCY_MAX_ANSWER()) + 1;
        assertLt(tooHigh, int256(feed.MAX_ANSWER()), "the rejected value is legal for updateAnswer");

        vm.warp(T0);
        _seedPrice();

        bytes memory sig = _ownerSig(tooHigh, FAR_FUTURE);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.EmergencyAnswerOutOfRange.selector, tooHigh));
        feed.emergencyUpdateAnswer(tooHigh, FAR_FUTURE, sig);
        assertEq(feed.latestAnswer(), ANSWER, "nothing moved");
    }

    /// A correction, never an initialisation. The first price must come through
    /// `updateAnswer`, so it is subject to the wider band and leaves a normal trail —
    /// otherwise the guardian pair could seed the feed inside a band nobody audited.
    function test_emergency_beforeAnyPriceReverts() public {
        vm.warp(T0);

        // A fully valid signature, so this isolates the NoPriceSet rule.
        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        vm.prank(guardian);
        vm.expectRevert(KaleidoscopeNAVFeed.NoPriceSet.selector);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);

        // Control: the identical call, after a normal first push, succeeds. The failure
        // above was the missing price and nothing about the signature.
        _seedPrice();
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER);
    }

    // ── Emergency path — cooldown and resulting state ─────────────────────────

    /// Without the cooldown the two keys would hold a $0.50 <-> $2.00 oscillation
    /// primitive every block. With it they hold one arbitrary in-band jump per hour.
    function test_emergency_secondCorrectionWithinCooldownReverts() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory first = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, first);

        // One second short of the cooldown, with a freshly signed, in-band, unexpired sig:
        // the cooldown is the only guard left that can fire.
        uint256 nextAllowedAt = T0 + feed.EMERGENCY_COOLDOWN();
        vm.warp(nextAllowedAt - 1);
        bytes memory second = _ownerSig(EMERGENCY_ANSWER_2, FAR_FUTURE);
        // nextAllowedAt is read BEFORE the prank: a getter call here would consume it.
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.EmergencyCooldownActive.selector, nextAllowedAt));
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER_2, FAR_FUTURE, second);
        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER, "the second correction did not land");
        assertEq(feed.emergencyNonce(), 1, "and its signature was not consumed");
    }

    function test_emergency_exactlyAtTheCooldownSucceeds() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory first = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, first);

        vm.warp(T0 + feed.EMERGENCY_COOLDOWN());
        bytes memory second = _ownerSig(EMERGENCY_ANSWER_2, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER_2, FAR_FUTURE, second);

        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER_2, "the boundary is inclusive");
        assertEq(feed.lastEmergencyAt(), T0 + feed.EMERGENCY_COOLDOWN(), "and the clock restarts from here");
        assertEq(feed.emergencyNonce(), 2);
    }

    /// An emergency push is a round like any other: consumers reading latestRoundData see
    /// a normal, fresh, advancing feed and need no awareness of this path at all.
    function test_emergency_advancesRoundIdAndUpdatedAt() public {
        vm.warp(T0);
        _seedPrice();
        (uint80 roundBefore,,, uint256 updatedBefore,) = feed.latestRoundData();
        assertEq(roundBefore, 1);
        assertEq(updatedBefore, T0);

        vm.warp(T0 + 3 hours);
        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 2, "the round advanced");
        assertEq(answer, EMERGENCY_ANSWER);
        assertEq(updatedAt, T0 + 3 hours, "updatedAt is the correction's own timestamp");
        assertEq(startedAt, updatedAt);
        assertEq(answeredInRound, roundId);

        assertEq(feed.latestAnswer(), EMERGENCY_ANSWER, "the Aave V3 read agrees");
        (, int256 histAnswer,,,) = feed.getRoundData(2);
        assertEq(histAnswer, EMERGENCY_ANSWER, "and so does getRoundData");
        assertEq(feed.stalenessSeconds(), 0, "an emergency push refreshes the feed");
        assertTrue(feed.isFresh());
    }

    /// AnswerUpdated is emitted FIRST and ALWAYS, so an emergency push is indistinguishable
    /// from a normal one to every existing consumer and indexer. EmergencyAnswerUpdated is
    /// the extra signal monitoring watches for, never a replacement — the counterpart to
    /// test_updateAnswer_emitsOnlyAnswerUpdated, which pins the normal path at exactly one.
    function test_emergency_emitsBothAnswerUpdatedAndEmergencyAnswerUpdated() public {
        vm.warp(T0);
        _seedPrice();

        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE);
        vm.recordLogs();
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 2, "exactly two events, no more and no fewer");

        assertEq(
            logs[0].topics[0],
            keccak256("AnswerUpdated(int256,uint256,uint256)"),
            "AnswerUpdated must come first, so a naive indexer sees the price move"
        );
        assertEq(logs[0].emitter, address(feed));
        assertEq(logs[0].topics[1], bytes32(uint256(EMERGENCY_ANSWER)));
        assertEq(uint256(logs[0].topics[2]), 2, "round 2");
        assertEq(abi.decode(logs[0].data, (uint256)), T0);

        assertEq(
            logs[1].topics[0],
            keccak256("EmergencyAnswerUpdated(int256,uint256,int256,uint256)"),
            "and the extra signal second"
        );
        assertEq(logs[1].emitter, address(feed));
        assertEq(logs[1].topics[1], bytes32(uint256(EMERGENCY_ANSWER)));
        assertEq(uint256(logs[1].topics[2]), 2);
        (int256 previousAnswer, uint256 usedNonce) = abi.decode(logs[1].data, (int256, uint256));
        assertEq(previousAnswer, ANSWER, "the log carries the price that was overwritten");
        assertEq(usedNonce, 0, "and the nonce the signature actually consumed");
    }

    /// The correction leaves NORMAL state, not a special state: the next `updateAnswer`
    /// measures its 10% band against the emergency answer and its 1 h interval against the
    /// emergency timestamp. If either were still anchored to the last normal push, the
    /// owner could immediately undo a correction, or would be blocked from following it.
    function test_emergency_nextNormalUpdateIsMeasuredAgainstTheEmergencyState() public {
        vm.warp(T0);
        _seedPrice(); // $0.9542

        vm.warp(T0 + 3 hours);
        bytes memory sig = _ownerSig(EMERGENCY_ANSWER, FAR_FUTURE); // $1.50
        vm.prank(guardian);
        feed.emergencyUpdateAnswer(EMERGENCY_ANSWER, FAR_FUTURE, sig);

        // The interval runs from the correction, not from the last normal push — which was
        // three hours ago and would otherwise have made this legal.
        vm.warp(T0 + 4 hours - 1);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.UpdateTooSoon.selector, T0 + 4 hours));
        feed.updateAnswer(EMERGENCY_ANSWER_2);

        // And the band is centred on $1.50: the pre-correction price is 36% away and can
        // no longer be pushed back in one step.
        vm.warp(T0 + 4 hours);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(KaleidoscopeNAVFeed.PriceDeviationTooLarge.selector, ANSWER, EMERGENCY_ANSWER)
        );
        feed.updateAnswer(ANSWER);

        // Control: +10% of the NEW answer is accepted at that same instant.
        int256 tenPercentUp = (EMERGENCY_ANSWER * 110) / 100; // $1.65
        vm.prank(owner);
        feed.updateAnswer(tenPercentUp);
        assertEq(feed.latestAnswer(), tenPercentUp);

        (uint80 roundId,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(roundId, 3, "normal push, emergency push, normal push");
        assertEq(updatedAt, T0 + 4 hours);
    }

    /// A NORMAL push emits exactly one event, and it is always `AnswerUpdated`. The
    /// emergency path adds a second log on top of this one, never instead of it — see
    /// test_emergency_emitsBothAnswerUpdatedAndEmergencyAnswerUpdated. If this test ever
    /// starts seeing two events, the privileged signal has leaked onto the ordinary path.
    function test_updateAnswer_emitsOnlyAnswerUpdated() public {
        vm.warp(1000);
        vm.recordLogs();
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "exactly one event per push");
        assertEq(
            logs[0].topics[0],
            keccak256("AnswerUpdated(int256,uint256,uint256)"),
            "the only price event is AnswerUpdated"
        );
        assertEq(logs[0].emitter, address(feed));
    }

    // ── Trapped price: chaining escapes the band (audit §4.11) ───────────────

    /// The scenario the deleted `emergencyUpdateAnswer` was justified by — and the proof
    /// that it never needed to exist.
    ///
    /// The claim used to be: a fat-finger inside the band traps the feed, because the
    /// correct price is then MORE than 10% away from the wrong one, so `updateAnswer`
    /// can never walk back to it. That is true only of a SINGLE step. The deviation band
    /// is measured against the LAST price, and the last price MOVES with every accepted
    /// push — so each push re-centres the band around wherever the feed now is.
    ///
    /// Concretely: from a wrong price W the owner may reach up to W * 1.10 in one push
    /// (the guard is `>`, so the +10% ceiling is INCLUSIVE), and from THERE the band has
    /// travelled with it. Any error that got in through the band (≤10% off) is therefore
    /// always correctable in exactly two chained pushes, at a cost of one extra
    /// MIN_UPDATE_INTERVAL. An unconditional guard plus a 1 h wait is strictly safer than
    /// a second key with uncapped, un-rate-limited price authority — which is why the
    /// D-19 emergency path was removed (audit §4.11). If the bad price must not be
    /// liquidated against during that hour, pause the bond token; do not weaken the feed.
    ///
    /// This mechanism is also what bounds the emergency path FIND-003 later reinstated.
    /// Because chaining reaches any price in [MIN_ANSWER, MAX_ANSWER] given enough hours,
    /// and the emergency band is a strict subset of that range
    /// (test_emergencyRangeIsStrictSubsetOfNormalRange), the guardian pair can reach no
    /// price the owner key could not already reach alone. It buys latency, not reach.
    function test_chainedUpdates_escapeTheBand() public {
        int256 correctPrice = 95_000_000; // $0.95
        int256 wrongPrice   = 85_600_000; // $0.8560 — 9.89% below $0.95

        // Step 1 — the correct NAV. First update: no interval or deviation check.
        vm.warp(1000);
        vm.prank(owner);
        feed.updateAnswer(correctPrice);

        // Step 2 — the fat-finger, +1 h. 9.89% below correct, so it slips through the
        // band and is accepted. This is the state the emergency path claimed to need.
        vm.warp(4600);
        vm.prank(owner);
        feed.updateAnswer(wrongPrice);
        assertEq(feed.latestAnswer(), wrongPrice, "the wrong price is now live");

        // Step 3 — the single-step correction, +1 h. Measured from the WRONG baseline,
        // $0.95 is 10.98% up: beyond the band, so it reverts. The old test stopped here
        // and concluded the feed was trapped.
        vm.warp(8200);
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                KaleidoscopeNAVFeed.PriceDeviationTooLarge.selector,
                correctPrice,
                wrongPrice
            )
        );
        feed.updateAnswer(correctPrice);

        // Step 4 — it is not trapped. Push the +10% ceiling from the wrong price
        // instead. The guard is `diff * 10_000 > last * 1000`, a strict `>`, so exactly
        // +10% is accepted. The revert above consumed no time, so we are still at t=8200,
        // a full hour after step 2. $0.8560 → $94.16.
        int256 ceiling = wrongPrice + (wrongPrice * 1000) / 10_000;
        assertEq(ceiling, 94_160_000, "the +10% ceiling from $0.8560 is $94.16");
        vm.prank(owner);
        feed.updateAnswer(ceiling);
        assertEq(feed.latestAnswer(), ceiling, "the inclusive boundary is accepted");

        // Step 5 — the band has moved with the price. From $94.16, the correct $0.95 is
        // only 0.89% away, comfortably inside the band. +1 h and the feed is corrected.
        vm.warp(11_800);
        vm.prank(owner);
        feed.updateAnswer(correctPrice);
        assertEq(feed.latestAnswer(), correctPrice, "corrected in exactly two chained pushes");

        // Two pushes, four rounds total, no privileged key involved.
        (uint80 roundId,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(roundId, 4);
        assertEq(updatedAt, 11_800);
    }

    // ── stalenessThreshold — settable monitoring window (audit FIND-022) ───────

    /// The window must start at the documented default. A feed that deployed with
    /// zero here would report every price as stale from birth.
    ///
    /// 24 h is not arbitrary: it is GyldAtomicSwap's deployed maxNavAgeSecs, and the
    /// whole point of FIND-022 is that the monitoring view must not sit ABOVE the
    /// strictest age a consumer enforces. If this constant is ever raised past that,
    /// the finding is reintroduced.
    function test_stalenessThreshold_defaultsToTheEnforcedAge() public view {
        assertEq(feed.DEFAULT_STALENESS_THRESHOLD(), 24 hours);
        assertEq(feed.stalenessThreshold(), 24 hours, "constructor must seed the live value");
    }

    /// The point of the finding: as a constant this could only be corrected by
    /// redeploying the feed and repointing every forwarder. It must be a transaction.
    function test_setStalenessThreshold_ownerCanRetune() public {
        vm.prank(owner);
        feed.setStalenessThreshold(20 hours);
        assertEq(feed.stalenessThreshold(), 20 hours);
    }

    function test_setStalenessThreshold_emitsOldAndNew() public {
        vm.expectEmit(false, false, false, true, address(feed));
        emit StalenessThresholdUpdated(24 hours, 20 hours);
        vm.prank(owner);
        feed.setStalenessThreshold(20 hours);
    }

    function test_setStalenessThreshold_revertsForStranger() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        feed.setStalenessThreshold(20 hours);
    }

    /// Zero is never a deliberate window, only a forgotten argument — and it would
    /// make isFresh() false in the same block as a push.
    function test_setStalenessThreshold_rejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KaleidoscopeNAVFeed.InvalidStalenessThreshold.selector, uint256(0)));
        feed.setStalenessThreshold(0);
    }

    /// Deliberately unbounded above (see the setter's natspec): this gates a view and
    /// no on-chain guarantee, so a ceiling here would imply a protection that is absent.
    function test_setStalenessThreshold_hasNoUpperCeiling() public {
        vm.prank(owner);
        feed.setStalenessThreshold(365 days);
        assertEq(feed.stalenessThreshold(), 365 days);
    }

    /// The whole reason the value is settable: isFresh() must follow it, so an
    /// operator can move the alarm ahead of the consumer that enforces the tightest age.
    function test_setStalenessThreshold_isFreshFollowsTheNewWindow() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(block.timestamp + 18 hours);
        assertTrue(feed.isFresh(), "18 h is inside the 24 h default");

        vm.prank(owner);
        feed.setStalenessThreshold(12 hours);
        assertFalse(feed.isFresh(), "the same 18 h age is outside a 12 h window");

        // And it moves back: this is a monitoring dial, not a one-way latch.
        vm.prank(owner);
        feed.setStalenessThreshold(48 hours);
        assertTrue(feed.isFresh());
    }

    /// Retuning the alarm must not touch the price, the round, or the timestamp —
    /// the settlement path reads those and must be unaffected by a monitoring change.
    function test_setStalenessThreshold_doesNotDisturbPriceState() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (uint80 roundBefore,,, uint256 updatedBefore,) = feed.latestRoundData();

        vm.prank(owner);
        feed.setStalenessThreshold(20 hours);

        (uint80 roundAfter, int256 answerAfter,, uint256 updatedAfter,) = feed.latestRoundData();
        assertEq(roundAfter, roundBefore, "round must not advance");
        assertEq(answerAfter, ANSWER, "answer must not move");
        assertEq(updatedAfter, updatedBefore, "updatedAt must not be refreshed");
    }

    /// Staleness stays SURFACED, never ENFORCED — even past a freshly tightened
    /// window the read still serves the last answer rather than reverting.
    function test_setStalenessThreshold_readsStillNeverRevert() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.prank(owner);
        feed.setStalenessThreshold(1 hours);
        vm.warp(block.timestamp + 10 hours);

        assertFalse(feed.isFresh(), "well past the tightened window");
        assertEq(feed.latestAnswer(), ANSWER, "read must not revert on staleness");
        assertEq(feed.stalenessSeconds(), 10 hours);
    }

    /// The deployment log is where an off-chain indexer learns the initial window,
    /// so the constructor's emission is observable behaviour, not an implementation
    /// detail. oldSeconds = 0 is a sentinel the setter can never produce.
    function test_constructor_emitsInitialStalenessThreshold() public {
        vm.recordLogs();
        KaleidoscopeNAVFeed fresh = new KaleidoscopeNAVFeed(owner, "TLT / USD NAV", guardian);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == StalenessThresholdUpdated.selector) {
                (uint256 oldSeconds, uint256 newSeconds) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(oldSeconds, 0, "no previous value at construction");
                assertEq(newSeconds, 24 hours);
                found = true;
            }
        }
        assertTrue(found, "constructor must log the initial window");
        assertEq(fresh.stalenessThreshold(), 24 hours);
    }

    /// isFresh() is inclusive at the boundary (`<=`). The whole finding is about
    /// tuning this number, so the off-by-one at its edge is worth pinning — the same
    /// way test_updateAnswer_exactly10PercentAllowed pins the deviation guard's edge.
    function test_isFresh_inclusiveAtExactlyTheThreshold() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.prank(owner);
        feed.setStalenessThreshold(20 hours);

        vm.warp(block.timestamp + 20 hours);
        assertEq(feed.stalenessSeconds(), 20 hours, "sitting exactly on the window");
        assertTrue(feed.isFresh(), "the boundary is inclusive");

        vm.warp(block.timestamp + 1);
        assertFalse(feed.isFresh(), "one second past it is stale");
    }

    /// The audit response asserts this setter's access control, so it must survive the
    /// two-step handover: a pending owner is still a stranger until acceptOwnership.
    function test_setStalenessThreshold_respectsTwoStepHandover() public {
        vm.prank(owner);
        feed.transferOwnership(newOwner);

        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        feed.setStalenessThreshold(20 hours);

        vm.prank(newOwner);
        feed.acceptOwnership();
        vm.prank(newOwner);
        feed.setStalenessThreshold(20 hours);
        assertEq(feed.stalenessThreshold(), 20 hours);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        feed.setStalenessThreshold(30 hours);
    }
}
