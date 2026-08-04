// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";

contract KaleidoscopeNAVFeedTest is Test {
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event EmergencyUpdaterSet(address indexed previous, address indexed newUpdater);
    event EmergencyAnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    KaleidoscopeNAVFeed feed;
    address owner            = address(0xA1);
    address stranger         = address(0xB2);
    address newOwner         = address(0xC3);
    address emergencyUpdater = address(0xE4);

    uint256 constant ONE_HOUR          = 1 hours;
    int256  constant ANSWER            = 9_542_000_000; // $95.42
    int256  constant ANSWER_PLUS_SMALL = 9_542_000_100; // tiny move, well within 10%

    function setUp() public {
        feed = new KaleidoscopeNAVFeed(owner, "TLT / USD NAV");
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

    function test_updateAnswer_updatedAtAdvances() public {
        uint256 t0 = block.timestamp;
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, t0);

        vm.warp(t0 + 1 days);
        vm.prank(owner);
        feed.updateAnswer(ANSWER_PLUS_SMALL);
        (,,, uint256 updatedAt2,) = feed.latestRoundData();
        assertEq(updatedAt2, t0 + 1 days);
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
        feed.updateAnswer(999_999_999_999); // some big number
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 999_999_999_999);
    }

    function test_updateAnswer_within10PercentAllowed() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER); // 9_542_000_000

        vm.warp(block.timestamp + ONE_HOUR);
        // 9% move up: 9_542_000_000 * 1.09 = 10_400_780_000
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
        vm.expectRevert(KaleidoscopeNAVFeed.AnswerMustBePositive.selector);
        feed.updateAnswer(0);
    }

    function test_updateAnswer_negativeReverts() public {
        vm.prank(owner);
        vm.expectRevert(KaleidoscopeNAVFeed.AnswerMustBePositive.selector);
        feed.updateAnswer(-1);
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

    /// Staleness is NOT an error condition for this feed. Past MAX_STALENESS the read
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
        vm.warp(1_000_000 + 97 hours); // past 96h MAX_STALENESS
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
        // The staleness must be visible to the caller, not papered over: `updatedAt`
        // reports the original push time, never block.timestamp.
        assertEq(updatedAt, 1_000_000, "updatedAt must report the real (stale) push time");
    }

    function test_isFresh_trueBeforeStaleness() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(block.timestamp + 95 hours);
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

        // Past MAX_STALENESS it keeps counting rather than saturating or reverting —
        // an alert needs the magnitude to escalate on, which is exactly what the Base
        // mainnet feed (silent since 2026-05-19) had no way to expose.
        vm.warp(1_000_000 + 100 days);
        assertEq(feed.stalenessSeconds(), 100 days);
        assertFalse(feed.isFresh());

        // A fresh push resets it.
        vm.prank(owner);
        feed.updateAnswer(ANSWER_PLUS_SMALL);
        assertEq(feed.stalenessSeconds(), 0);
        assertTrue(feed.isFresh());
    }

    function test_stalenessSeconds_resetByEmergencyUpdate() public {
        vm.warp(1_000_000);
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        vm.warp(1_000_000 + 10 days);
        assertEq(feed.stalenessSeconds(), 10 days);

        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(ANSWER);
        assertEq(feed.stalenessSeconds(), 0, "the emergency path must also refresh the clock");
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

        // Far beyond any plausible threshold: 1000 days, ~250x MAX_STALENESS.
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
        // Warp well past MAX_STALENESS, then push again. 97 h is >> the 1 h
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

    // ── setEmergencyUpdater ───────────────────────────────────────────────────

    function test_setEmergencyUpdater_ownerSetsAddress() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        assertEq(feed.emergencyUpdater(), emergencyUpdater);
    }

    function test_setEmergencyUpdater_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        feed.setEmergencyUpdater(emergencyUpdater);
    }

    function test_setEmergencyUpdater_zeroAddressDisablesPath() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        feed.setEmergencyUpdater(address(0));
        assertEq(feed.emergencyUpdater(), address(0));
    }

    function test_setEmergencyUpdater_emitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit EmergencyUpdaterSet(address(0), emergencyUpdater);
        feed.setEmergencyUpdater(emergencyUpdater);
    }

    function test_setEmergencyUpdater_emitsEventWithPreviousAddress() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit EmergencyUpdaterSet(emergencyUpdater, newOwner);
        feed.setEmergencyUpdater(newOwner);
    }

    // ── key separation: owner() != emergencyUpdater (GYL-961) ─────────────────

    function test_setEmergencyUpdater_ownerAddressReverts() public {
        vm.prank(owner);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencyUpdaterCannotBeOwner.selector);
        feed.setEmergencyUpdater(owner);
    }

    function test_transferOwnership_toEmergencyUpdaterReverts() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencyUpdaterCannotBeOwner.selector);
        feed.transferOwnership(emergencyUpdater);
    }

    function test_acceptOwnership_intoEmergencyUpdaterReverts() public {
        // Drive the completion funnel (_transferOwnership) directly: start a
        // transfer to `newOwner`, THEN promote that same address to emergency
        // updater, so the fail-fast transferOwnership guard is bypassed and the
        // invariant must be caught at acceptOwnership().
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        vm.prank(owner);
        feed.setEmergencyUpdater(newOwner);
        vm.prank(newOwner);
        vm.expectRevert(KaleidoscopeNAVFeed.EmergencyUpdaterCannotBeOwner.selector);
        feed.acceptOwnership();
    }

    function test_renounceOwnership_stillWorks() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        feed.renounceOwnership();
        assertEq(feed.owner(), address(0));
    }

    function test_transferOwnership_toDifferentAddressStillWorks() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        feed.transferOwnership(newOwner);
        vm.prank(newOwner);
        feed.acceptOwnership();
        assertEq(feed.owner(), newOwner);
    }

    // ── emergencyUpdateAnswer — access control ────────────────────────────────

    function test_emergencyUpdateAnswer_strangerReverts() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(stranger);
        vm.expectRevert(KaleidoscopeNAVFeed.NotEmergencyUpdater.selector);
        feed.emergencyUpdateAnswer(ANSWER);
    }

    function test_emergencyUpdateAnswer_ownerCannotCallDirectly() public {
        // owner is not the emergency updater — different keys by design
        vm.prank(owner);
        vm.expectRevert(KaleidoscopeNAVFeed.NotEmergencyUpdater.selector);
        feed.emergencyUpdateAnswer(ANSWER);
    }

    function test_emergencyUpdateAnswer_revertsWhenPathDisabled() public {
        // emergencyUpdater never set — address(0) — nobody can call
        vm.prank(stranger);
        vm.expectRevert(KaleidoscopeNAVFeed.NotEmergencyUpdater.selector);
        feed.emergencyUpdateAnswer(ANSWER);
    }

    // ── emergencyUpdateAnswer — bypasses guards ───────────────────────────────

    function test_emergencyUpdateAnswer_bypassesInterval() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        feed.updateAnswer(ANSWER);

        // no warp — still within MIN_UPDATE_INTERVAL
        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(ANSWER_PLUS_SMALL); // succeeds without waiting 1h
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER_PLUS_SMALL);
    }

    function test_emergencyUpdateAnswer_bypassesDeviationUp() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        feed.updateAnswer(ANSWER); // $95.42

        // 50% up — way beyond MAX_PRICE_DEVIATION_BPS
        int256 bigMove = (ANSWER * 150) / 100;
        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(bigMove);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, bigMove);
    }

    function test_emergencyUpdateAnswer_bypassesDeviationDown() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        feed.updateAnswer(ANSWER); // $95.42

        // 50% down — way beyond MAX_PRICE_DEVIATION_BPS
        int256 bigDrop = ANSWER / 2;
        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(bigDrop);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, bigDrop);
    }

    // ── emergencyUpdateAnswer — validation ───────────────────────────────────

    function test_emergencyUpdateAnswer_zeroReverts() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(emergencyUpdater);
        vm.expectRevert(KaleidoscopeNAVFeed.AnswerMustBePositive.selector);
        feed.emergencyUpdateAnswer(0);
    }

    function test_emergencyUpdateAnswer_negativeReverts() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(emergencyUpdater);
        vm.expectRevert(KaleidoscopeNAVFeed.AnswerMustBePositive.selector);
        feed.emergencyUpdateAnswer(-1);
    }

    // ── emergencyUpdateAnswer — state ─────────────────────────────────────────

    function test_emergencyUpdateAnswer_storesAnswer() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(ANSWER);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
    }

    function test_emergencyUpdateAnswer_updatesTimestamp() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.warp(1000);
        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(ANSWER);
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(updatedAt, 1000);
    }

    function test_emergencyUpdateAnswer_incrementsRoundId() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.prank(owner);
        feed.updateAnswer(ANSWER);           // round 1

        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(ANSWER);  // round 2
        (uint80 roundId,,,,) = feed.latestRoundData();
        assertEq(roundId, 2);
    }

    // ── emergencyUpdateAnswer — event ─────────────────────────────────────────

    function test_emergencyUpdateAnswer_emitsEmergencyEvent() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.warp(1000);
        vm.prank(emergencyUpdater);
        vm.expectEmit(true, true, false, true);
        emit EmergencyAnswerUpdated(ANSWER, 1, 1000);
        feed.emergencyUpdateAnswer(ANSWER);
    }

    function test_emergencyUpdateAnswer_doesNotEmitAnswerUpdated() public {
        // EmergencyAnswerUpdated and AnswerUpdated are distinct — monitoring
        // rules must watch both but they never fire in the same call.
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);
        vm.recordLogs();
        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(ANSWER);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Only one event emitted; its topic[0] must be EmergencyAnswerUpdated, not AnswerUpdated
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], keccak256("EmergencyAnswerUpdated(int256,uint256,uint256)"));
    }

    // ── Trapped-price scenario — the root cause of this feature ───────────────

    /// A fat-finger pushes a price 9.9 % below correct value (within deviation band,
    /// so it is accepted). The correct price is now 10.97 % above the wrong price —
    /// beyond MAX_PRICE_DEVIATION_BPS, so normal updateAnswer is blocked.
    /// emergencyUpdateAnswer corrects it in one call with no waiting period.
    function test_emergencyUpdateAnswer_solvesTrappedPriceScenario() public {
        vm.prank(owner);
        feed.setEmergencyUpdater(emergencyUpdater);

        int256 correctPrice = 9_500_000_000; // $95.00
        int256 wrongPrice   = 8_560_000_000; // $85.60 — 9.89% below $95.00

        // Step 1: push correct NAV at t=1000 (first update, no deviation check)
        vm.warp(1000);
        vm.prank(owner);
        feed.updateAnswer(correctPrice);

        // Step 2: fat-finger pushes $85.60 at t=4600 (+1 h) — 9.89% below $95.00,
        // just within MAX_PRICE_DEVIATION_BPS — accepted
        vm.warp(4600);
        vm.prank(owner);
        feed.updateAnswer(wrongPrice);

        // Step 3: normal correction at t=8200 (+1 h) — ($95.00 - $85.60) / $85.60 = 10.98%
        // exceeds MAX_PRICE_DEVIATION_BPS from the wrong baseline — BLOCKED
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

        // Step 4: emergency path restores correct price immediately
        vm.prank(emergencyUpdater);
        feed.emergencyUpdateAnswer(correctPrice);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, correctPrice);
    }

}
