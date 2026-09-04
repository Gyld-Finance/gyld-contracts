// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {NAVFeedForwarder} from "../NAVFeedForwarder.sol";

contract NAVFeedForwarderTest is Test {
    event UpstreamOracleUpdated(address indexed previousOracle, address indexed newOracle);

    KaleidoscopeNAVFeed feedV1;
    KaleidoscopeNAVFeed feedV2;
    NAVFeedForwarder    forwarder;

    address feedOwner      = address(0xA1);
    address forwarderOwner = address(0xA2);
    address stranger       = address(0xB1);
    address newOwner       = address(0xC1);
    address guardian       = address(0xD1); // emergency NAV updater (audit FIND-003)

    // Rescaled /100 onto the $1.00 NAV standard when FIND-003 tightened the feed's
    // absolute range to $0.10-$5.00.
    int256 constant ANSWER_V1 = 95_420_000; // $0.9542
    int256 constant ANSWER_V2 = 99_000_000; // $0.9900  (new oracle, within 10% of V1)

    function setUp() public {
        feedV1    = new KaleidoscopeNAVFeed(feedOwner, "TLT / USD NAV", guardian);
        feedV2    = new KaleidoscopeNAVFeed(feedOwner, "TLT / USD NAV v2", guardian);
        forwarder = new NAVFeedForwarder(address(feedV1), forwarderOwner);

        vm.prank(feedOwner);
        feedV1.updateAnswer(ANSWER_V1);
    }

    // ── constructor ───────────────────────────────────────────────────────────

    function test_constructor_setsUpstream() public view {
        assertEq(forwarder.upstreamOracle(), address(feedV1));
    }

    function test_constructor_setsOwner() public view {
        assertEq(forwarder.owner(), forwarderOwner);
    }

    function test_constructor_zeroUpstreamReverts() public {
        vm.expectRevert(NAVFeedForwarder.UpstreamCannotBeZero.selector);
        new NAVFeedForwarder(address(0), forwarderOwner);
    }

    function test_constructor_emitsEvent() public {
        vm.expectEmit(true, true, false, false);
        emit UpstreamOracleUpdated(address(0), address(feedV1));
        new NAVFeedForwarder(address(feedV1), forwarderOwner);
    }

    // ── setUpstreamOracle — access control ────────────────────────────────────

    function test_setUpstreamOracle_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert();
        forwarder.setUpstreamOracle(address(feedV2));
    }

    function test_setUpstreamOracle_ownerSucceeds() public {
        vm.prank(feedOwner);
        feedV2.updateAnswer(ANSWER_V2);

        vm.prank(forwarderOwner);
        forwarder.setUpstreamOracle(address(feedV2));
        assertEq(forwarder.upstreamOracle(), address(feedV2));
    }

    function test_setUpstreamOracle_zeroAddressReverts() public {
        vm.prank(forwarderOwner);
        vm.expectRevert(NAVFeedForwarder.UpstreamCannotBeZero.selector);
        forwarder.setUpstreamOracle(address(0));
    }

    function test_setUpstreamOracle_emitsEvent() public {
        vm.prank(forwarderOwner);
        vm.expectEmit(true, true, false, false);
        emit UpstreamOracleUpdated(address(feedV1), address(feedV2));
        forwarder.setUpstreamOracle(address(feedV2));
    }

    // ── delegation — reads come from upstream ─────────────────────────────────

    function test_latestRoundData_delegatesToUpstream() public view {
        (, int256 answer,,,) = forwarder.latestRoundData();
        assertEq(answer, ANSWER_V1);
    }

    function test_decimals_delegatesToUpstream() public view {
        assertEq(forwarder.decimals(), 8);
    }

    function test_description_delegatesToUpstream() public view {
        assertEq(forwarder.description(), "TLT / USD NAV");
    }

    function test_version_delegatesToUpstream() public view {
        assertEq(forwarder.version(), 3);
    }

    function test_latestAnswer_delegatesToUpstream() public view {
        assertEq(forwarder.latestAnswer(), ANSWER_V1);
    }

    function test_getRoundData_delegatesToUpstream() public view {
        (uint80 rId, int256 answer,,,) = forwarder.getRoundData(1);
        assertEq(rId, 1);
        assertEq(answer, ANSWER_V1);
    }

    // ── the key scenario: oracle upgrade, zero DeFi breakage ─────────────────

    function test_upgradeUpstream_morphoSeesNewData() public {
        // Morpho market integrates the forwarder address.
        (, int256 before,,,) = forwarder.latestRoundData();
        assertEq(before, ANSWER_V1);

        // We deploy a new oracle provider (e.g. RedStone) — feedV2.
        vm.prank(feedOwner);
        feedV2.updateAnswer(ANSWER_V2);

        // One governance call flips the pointer.
        vm.prank(forwarderOwner);
        forwarder.setUpstreamOracle(address(feedV2));

        // Morpho still queries the same forwarder address — gets new data.
        (, int256 answerAfter,,,) = forwarder.latestRoundData();
        assertEq(answerAfter, ANSWER_V2);

        // Old oracle no longer queried.
        assertEq(forwarder.upstreamOracle(), address(feedV2));
    }

    function test_upgradeUpstream_descriptionReflectsNewOracle() public {
        vm.prank(feedOwner);
        feedV2.updateAnswer(ANSWER_V2);

        vm.prank(forwarderOwner);
        forwarder.setUpstreamOracle(address(feedV2));

        assertEq(forwarder.description(), "TLT / USD NAV v2");
    }

    function test_forwarder_returnsLastPriceWhenStale() public {
        // Forwarder returns last known price over weekends/holidays — no stale revert.
        vm.warp(block.timestamp + 97 hours);
        (, int256 answer,,,) = forwarder.latestRoundData();
        assertEq(answer, ANSWER_V1);
    }

    function test_forwarder_propagatesNoPriceRevert() public {
        // feedV2 has no price set yet — forwarder propagates the revert.
        NAVFeedForwarder emptyForwarder = new NAVFeedForwarder(address(feedV2), forwarderOwner);
        vm.expectRevert(KaleidoscopeNAVFeed.NoPriceSet.selector);
        emptyForwarder.latestRoundData();
    }

    function test_getRoundData_propagatesWrongRoundIdRevert() public {
        // roundId 2 does not exist — KaleidoscopeNAVFeed reverts "historical rounds not stored"
        vm.expectRevert();
        forwarder.getRoundData(2);
    }

    // ── Ownable2Step ──────────────────────────────────────────────────────────

    function test_transferOwnership_setsPendingOwner() public {
        vm.prank(forwarderOwner);
        forwarder.transferOwnership(newOwner);
        assertEq(forwarder.pendingOwner(), newOwner);
    }

    function test_acceptOwnership_completesTransfer() public {
        vm.prank(forwarderOwner);
        forwarder.transferOwnership(newOwner);
        vm.prank(newOwner);
        forwarder.acceptOwnership();
        assertEq(forwarder.owner(), newOwner);
    }

    function test_newOwner_canSetUpstream() public {
        vm.prank(forwarderOwner);
        forwarder.transferOwnership(newOwner);
        vm.prank(newOwner);
        forwarder.acceptOwnership();

        vm.prank(feedOwner);
        feedV2.updateAnswer(ANSWER_V2);

        vm.prank(newOwner);
        forwarder.setUpstreamOracle(address(feedV2));
        assertEq(forwarder.upstreamOracle(), address(feedV2));
    }

    function test_oldOwner_cannotSetUpstreamAfterTransfer() public {
        vm.prank(forwarderOwner);
        forwarder.transferOwnership(newOwner);
        vm.prank(newOwner);
        forwarder.acceptOwnership();

        vm.prank(forwarderOwner);
        vm.expectRevert();
        forwarder.setUpstreamOracle(address(feedV2));
    }

    // ── renounceOwnership is disabled (GLD-166) ──────────────────────────────

    /// The forwarder is a permanent address baked into immutable Morpho market params —
    /// renouncing would weld the upstream pointer forever, making the Phase 2/3
    /// oracle migration this contract exists to enable impossible.
    function test_renounceOwnership_ownerReverts() public {
        vm.prank(forwarderOwner);
        vm.expectRevert(NAVFeedForwarder.CannotRenounceOwnership.selector);
        forwarder.renounceOwnership();
        assertEq(forwarder.owner(), forwarderOwner, "owner must be unchanged");
    }

    /// Same error for a non-owner: the call can never succeed for anyone, so it
    /// must not report "not owner" and imply the owner could have done it.
    function test_renounceOwnership_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert(NAVFeedForwarder.CannotRenounceOwnership.selector);
        forwarder.renounceOwnership();
        assertEq(forwarder.owner(), forwarderOwner, "owner must be unchanged");
    }

    /// Rotation must be unaffected by the guard: transfer + accept still works.
    function test_renounceOwnershipGuard_rotationStillWorks() public {
        vm.prank(forwarderOwner);
        forwarder.transferOwnership(newOwner);
        vm.prank(newOwner);
        forwarder.acceptOwnership();
        assertEq(forwarder.owner(), newOwner, "rotation must still work");
    }

    // ── setUpstreamOracle interface validation (GYL-299) ─────────────────────

    function test_setUpstreamOracle_nonContractAddress_reverts() public {
        address eoa = address(0xEEEE);
        vm.prank(forwarderOwner);
        vm.expectRevert();
        forwarder.setUpstreamOracle(eoa);
    }

    function test_setUpstreamOracle_wrongContract_reverts() public {
        // Deploy a contract that has no decimals() — e.g. a plain mock
        address wrongContract = address(new MockNoOracle());
        vm.prank(forwarderOwner);
        vm.expectRevert();
        forwarder.setUpstreamOracle(wrongContract);
    }

    function test_setUpstreamOracle_freshFeedWithNoPrice_succeeds() public {
        // feedV2 has no price set yet — decimals() is pure so it returns 8 regardless
        vm.prank(forwarderOwner);
        forwarder.setUpstreamOracle(address(feedV2));
        assertEq(forwarder.upstreamOracle(), address(feedV2));
    }

    function test_setUpstreamOracle_wrongDecimals_reverts() public {
        // An oracle returning decimals() != 8 must be rejected
        address wrongDecimals = address(new MockWrongDecimals());
        vm.prank(forwarderOwner);
        vm.expectRevert();
        forwarder.setUpstreamOracle(wrongDecimals);
    }

    function test_constructor_invalidOracle_reverts() public {
        vm.expectRevert();
        new NAVFeedForwarder(address(0xEEEE), forwarderOwner);
    }

    function test_constructor_wrongDecimals_reverts() public {
        address wrongDecimals = address(new MockWrongDecimals());
        vm.expectRevert();
        new NAVFeedForwarder(wrongDecimals, forwarderOwner);
    }

    // ── M-05: partial interface rejection ────────────────────────────────────

    function test_constructor_partialOracle_reverts() public {
        // Contract implements decimals()=8 but nothing else — passes decimals check,
        // must fail on version() probe.
        address stub = address(new MockPartialOracle());
        vm.expectRevert(abi.encodeWithSelector(NAVFeedForwarder.InvalidOracle.selector, stub));
        new NAVFeedForwarder(stub, forwarderOwner);
    }

    function test_setUpstreamOracle_partialOracle_reverts() public {
        address stub = address(new MockPartialOracle());
        vm.prank(forwarderOwner);
        vm.expectRevert(abi.encodeWithSelector(NAVFeedForwarder.InvalidOracle.selector, stub));
        forwarder.setUpstreamOracle(stub);
    }

    // ── future-dated upstream rejection (GYL-1135) ───────────────────────────

    /// The defect: every consumer of this forwarder defends itself against a dead feed
    /// with `block.timestamp - updatedAt <= maxAge`. An upstream that reports an
    /// `updatedAt` in the FUTURE satisfies that check unconditionally — so one
    /// setUpstreamOracle call would silently disarm the staleness defence of every
    /// integrator at once (Morpho, Euler, GyldAtomicSwap), with nothing in the
    /// UpstreamOracleUpdated event that reads as anomalous. That fails OPEN, which is
    /// strictly worse than the stale-feed case that fails closed and loudly.
    /// decimals()/version() cannot catch it: a synthetic-fresh oracle answers both
    /// perfectly.
    function test_setUpstreamOracle_rejectsFutureDatedUpstream() public {
        vm.warp(1_000_000);
        MockFutureDatedOracle bad = new MockFutureDatedOracle(block.timestamp + 1);

        vm.prank(forwarderOwner);
        vm.expectRevert(
            abi.encodeWithSelector(
                NAVFeedForwarder.UpstreamFutureDated.selector, block.timestamp + 1, block.timestamp
            )
        );
        forwarder.setUpstreamOracle(address(bad));

        // Rejected before any state change — the old upstream is still installed.
        assertEq(forwarder.upstreamOracle(), address(feedV1), "a rejected probe must not swap the pointer");
    }

    function test_constructor_rejectsFutureDatedUpstream() public {
        vm.warp(1_000_000);
        MockFutureDatedOracle bad = new MockFutureDatedOracle(block.timestamp + 365 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                NAVFeedForwarder.UpstreamFutureDated.selector, block.timestamp + 365 days, block.timestamp
            )
        );
        new NAVFeedForwarder(address(bad), forwarderOwner);
    }

    /// updatedAt == block.timestamp is the honest case for an oracle updated in this
    /// very block — it must NOT be rejected. Only strictly-future is a lie.
    function test_setUpstreamOracle_acceptsUpdatedAtEqualToNow() public {
        vm.warp(1_000_000);
        MockFutureDatedOracle atNow = new MockFutureDatedOracle(block.timestamp);
        vm.prank(forwarderOwner);
        forwarder.setUpstreamOracle(address(atNow));
        assertEq(forwarder.upstreamOracle(), address(atNow));
    }

    /// A stale-but-honest upstream is still a legitimate swap target. The probe rejects
    /// lying about time, not being old — freezing oracle migrations during an outage is
    /// precisely the wrong time to be unable to migrate.
    function test_setUpstreamOracle_acceptsStaleButHonestUpstream() public {
        vm.warp(1_750_000_000);
        MockFutureDatedOracle old = new MockFutureDatedOracle(block.timestamp - 500 days);
        vm.prank(forwarderOwner);
        forwarder.setUpstreamOracle(address(old));
        assertEq(forwarder.upstreamOracle(), address(old));
    }

    /// The probe must stay tolerant of an upstream whose latestRoundData REVERTS: a
    /// freshly deployed KaleidoscopeNAVFeed reverts NoPriceSet until its first push,
    /// and installing it before that push is a legitimate deploy order. (Duplicated
    /// intent with test_setUpstreamOracle_freshFeedWithNoPrice_succeeds above, kept
    /// separate because this one guards the new probe specifically.)
    function test_setUpstreamOracle_revertingLatestRoundData_stillAccepted() public {
        assertEq(feedV2.stalenessSeconds(), type(uint256).max, "feedV2 must have no price for this test");
        vm.prank(forwarderOwner);
        forwarder.setUpstreamOracle(address(feedV2));
        assertEq(forwarder.upstreamOracle(), address(feedV2));
    }
}

/// @dev Oracle stub with a settable `updatedAt`, used to test the future-dated probe.
///      Answers decimals()/version() correctly so it clears the existing probes —
///      the point is that a synthetic-fresh oracle is indistinguishable by those.
contract MockFutureDatedOracle {
    uint256 private immutable _updatedAt;

    constructor(uint256 updatedAt_) {
        _updatedAt = updatedAt_;
    }

    function decimals() external pure returns (uint8) { return 8; }
    function version() external pure returns (uint256) { return 3; }
    function description() external pure returns (string memory) { return "synthetic"; }
    function latestAnswer() external pure returns (int256) { return 100e8; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 100e8, _updatedAt, _updatedAt, 1);
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 100e8, _updatedAt, _updatedAt, 1);
    }
}

/// @dev Minimal contract with no oracle interface — used to test invalid oracle rejection.
contract MockNoOracle {}

/// @dev Oracle stub that returns decimals() = 18 instead of 8 — used to test decimal check.
contract MockWrongDecimals {
    function decimals() external pure returns (uint8) { return 18; }
}

/// @dev Oracle stub that returns decimals()=8 but has no version() — used to test M-05 partial
///      interface rejection. Passes the decimals check but fails the version() probe.
contract MockPartialOracle {
    function decimals() external pure returns (uint8) { return 8; }
}
