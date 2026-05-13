// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";

contract KaleidoscopeNAVFeedTest is Test {
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    KaleidoscopeNAVFeed feed;
    address owner    = address(0xA1);
    address stranger = address(0xB2);
    address newOwner = address(0xC3);

    uint256 constant THIRTY_SIX_HOURS  = 36 hours;
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

    function test_latestRoundData_revertsWhenStale() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(block.timestamp + THIRTY_SIX_HOURS + 1);
        vm.expectRevert();
        feed.latestRoundData();
    }

    function test_latestRoundData_notStaleAtExactBoundary() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(block.timestamp + THIRTY_SIX_HOURS);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, ANSWER);
    }

    function test_latestRoundData_recoversAfterNewUpdate() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(block.timestamp + THIRTY_SIX_HOURS + 1);
        // stale — new update (within 10% of original, but first update has
        // no interval check; this is the second so we need to warp enough)
        // We already warped 36h+1s which is >> 1h interval requirement
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

    function test_latestAnswer_revertsWhenStale() public {
        vm.prank(owner);
        feed.updateAnswer(ANSWER);
        vm.warp(block.timestamp + THIRTY_SIX_HOURS + 1);
        vm.expectRevert();
        feed.latestAnswer();
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
        // _requireFresh() then fires because _updatedAt == 0.
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

}
