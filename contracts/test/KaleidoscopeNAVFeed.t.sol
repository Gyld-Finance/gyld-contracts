// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract KaleidoscopeNAVFeedTest is Test {
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event StalenessThresholdUpdated(uint256 oldSeconds, uint256 newSeconds);

    KaleidoscopeNAVFeed feed;
    address owner            = address(0xA1);
    address stranger         = address(0xB2);
    address newOwner         = address(0xC3);

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
        new KaleidoscopeNAVFeed(address(0), "TLT / USD NAV");
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
        feed.updateAnswer(9_542_000_000);
        assertEq(feed.latestAnswer(), 9_542_000_000);
    }

    /// Accepting must clear `pendingOwner` and fully revoke the old key. Previously the
    /// only place `_transferOwnership` (the completion funnel) was exercised beyond a
    /// happy-path `owner()` read was the key-separation test that has been removed with
    /// the emergency path; this pins the funnel's real post-conditions directly.
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

    // ── The emergency path is gone (audit §4.11) ─────────────────────────────

    /// LOAD-BEARING. `updateAnswer` is now the ONLY way a price reaches this feed, and
    /// its interval + deviation guards have no privileged bypass. This asserts the
    /// removal at the ABI level rather than trusting that the source no longer mentions
    /// it: the contract declares no fallback, so a call carrying a selector it does not
    /// implement reverts, and `success` is false.
    ///
    /// If any of these three ever starts returning true, a bypass has been reintroduced
    /// and `test_chainedUpdates_escapeTheBand` below no longer describes the system.
    function test_emergencyPathSurfaceIsGone() public {
        vm.startPrank(owner);

        (bool setOk,) = address(feed).call(
            abi.encodeWithSignature("setEmergencyUpdater(address)", stranger)
        );
        assertFalse(setOk, "setEmergencyUpdater(address) must no longer exist");

        (bool updOk,) = address(feed).call(
            abi.encodeWithSignature("emergencyUpdateAnswer(int256)", ANSWER)
        );
        assertFalse(updOk, "emergencyUpdateAnswer(int256) must no longer exist");

        (bool getOk,) = address(feed).call(abi.encodeWithSignature("emergencyUpdater()"));
        assertFalse(getOk, "the emergencyUpdater() getter must no longer exist");

        // Control: the same low-level call shape DOES succeed against a selector the
        // feed implements, so the three assertions above are about the missing
        // functions and not about a malformed call or a blanket-reverting contract.
        (bool ctrlOk,) = address(feed).call(abi.encodeWithSignature("updateAnswer(int256)", ANSWER));
        assertTrue(ctrlOk, "control: updateAnswer(int256) still exists and is callable");

        vm.stopPrank();
    }

    /// Every price push emits exactly one event, and it is always `AnswerUpdated` —
    /// there is no second, privileged price event for monitoring to have to watch.
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
    /// emergency path was removed (audit §4.11). If the bad price must not be liquidated
    /// against during that hour, pause the bond token; do not weaken the feed.
    function test_chainedUpdates_escapeTheBand() public {
        int256 correctPrice = 9_500_000_000; // $95.00
        int256 wrongPrice   = 8_560_000_000; // $85.60 — 9.89% below $95.00

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
        // $95.00 is 10.98% up: beyond the band, so it reverts. The old test stopped here
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
        // a full hour after step 2. $85.60 → $94.16.
        int256 ceiling = wrongPrice + (wrongPrice * 1000) / 10_000;
        assertEq(ceiling, 9_416_000_000, "the +10% ceiling from $85.60 is $94.16");
        vm.prank(owner);
        feed.updateAnswer(ceiling);
        assertEq(feed.latestAnswer(), ceiling, "the inclusive boundary is accepted");

        // Step 5 — the band has moved with the price. From $94.16, the correct $95.00 is
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
        KaleidoscopeNAVFeed fresh = new KaleidoscopeNAVFeed(owner, "TLT / USD NAV");

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
