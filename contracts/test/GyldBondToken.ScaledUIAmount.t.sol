// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";

// ── ERC-8056 interfaces, declared locally ─────────────────────────────────────
//
// An interfaceId depends only on the function selectors, so declaring these here
// yields the same `type(...).interfaceId` values as the contract's own declarations
// regardless of where they live. Declaring them locally (rather than importing the
// contract's) keeps this suite an INDEPENDENT check: if someone edits a selector in
// GyldBondToken.sol, these ids stop matching instead of silently moving together.

interface IScaledUIAmount {
    function uiMultiplier() external view returns (uint256);
}

interface IScaledUIAmountNewUIMultiplier {
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}

interface IScaledUIAmountConversion {
    function toUIAmount(uint256 rawAmount) external view returns (uint256);
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);
}

interface IScaledUIAmountBalances {
    function balanceOfUI(address account) external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
}

// ── V2 stubs for storage-layout / reinitializer tests ─────────────────────────

/// Minimal V2 implementation — same storage layout, adds version() getter.
/// Used only to verify upgradeToAndCall preserves all existing state including
/// the appended ERC-8056 fields.
/// @custom:oz-upgrades-unsafe-allow constructor
contract GyldBondTokenScaledV2 is GyldBondToken {
    function version() external pure returns (uint256) { return 2; }
}

/// V2 implementation that consumes the `reinitializer(2)` version slot for its own
/// migration logic. Used by the F-2 regression test to prove that slot is still
/// available — i.e. that no unguarded initializer burned it.
/// @custom:oz-upgrades-unsafe-allow constructor
contract GyldBondTokenReinitV2 is GyldBondToken {
    event V2MigrationRan();

    function initializeV2Migration() external reinitializer(2) {
        emit V2MigrationRan();
    }
}

// ── Test contract ─────────────────────────────────────────────────────────────

contract GyldBondTokenScaledUIAmountTest is Test {

    GyldBondToken     token;
    MockSanctionsList mockSanctions;

    address admin        = address(0xA0); // DEFAULT_ADMIN_ROLE on token
    address operator     = address(0xA1); // PAUSER_ROLE on token
    address issuer       = address(0xA2); // MINTER_ROLE + BURNER_ROLE (granted directly)
    address navPublisher = address(0xA3); // UI_MULTIPLIER_ROLE — dedicated actor,
                                          // deliberately NOT admin, to test role isolation
    address ap           = address(0xAB); // Authorised Participant (token holder)

    uint256 constant ONE = 1e18; // UI_MULTIPLIER_SCALE — 1.0x, no scaling

    // Canonical ERC-8056 ERC-165 interface ids, transcribed from the published EIP
    // (https://eips.ethereum.org/EIPS/eip-8056, "Interface Detection"). Hard-coded on
    // purpose: these must not drift with our own declarations.
    bytes4 constant ID_CORE       = 0xa60bf13d;
    bytes4 constant ID_PENDING    = 0x4bd27648;
    bytes4 constant ID_CONVERSION = 0x57854fc3;
    bytes4 constant ID_BALANCES   = 0xd890fd71;

    // Canonical event signatures from the EIP. topic0 is derived from these strings, so a
    // change of arity (the C-2 bug: 2 params instead of 3) makes the assertions below fail.
    bytes32 constant TOPIC_UI_MULTIPLIER_UPDATED =
        keccak256("UIMultiplierUpdated(uint256,uint256,uint256)");
    bytes32 constant TOPIC_TRANSFER_WITH_UI_AMOUNT =
        keccak256("TransferWithUIAmount(address,address,uint256,uint256)");

    // ERC-7201 namespace root of GyldBondTokenStorage, and the offsets of the three
    // ERC-8056 fields within it. Derived (not copy-pasted) in
    // test_f1_legacyProxyStorageImage_isNeverReadableAsZero, which asserts the derivation
    // matches the contract before using it — so these offsets cannot silently go stale.
    uint256 constant SLOT_UI_MULTIPLIER               = 3;
    uint256 constant SLOT_NEW_UI_MULTIPLIER           = 4;
    uint256 constant SLOT_UI_MULTIPLIER_EFFECTIVE_AT  = 5;

    // Mirrors of the contract's (inherited) events so vm.expectEmit can match them.
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);
    event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);

    function setUp() public {
        mockSanctions = new MockSanctionsList();

        // ── GyldBondToken proxy ───────────────────────────────────────────────
        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(address(new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Gyld US Treasury Bond 2026-06", // name
                "GYLD-UST-2606",                 // symbol
                "US912797KR72",                  // isin
                1_780_000_000,                   // maturityTimestamp
                admin,                           // DEFAULT_ADMIN_ROLE
                operator,                        // PAUSER_ROLE
                address(mockSanctions)           // sanctionsList
            ))
        )));

        // Wire roles: issuer mints/burns directly; navPublisher owns the UI multiplier.
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(),        issuer);
        token.grantRole(token.BURNER_ROLE(),        issuer);
        token.grantRole(token.UI_MULTIPLIER_ROLE(), navPublisher);
        vm.stopPrank();
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// Walk the multiplier to `target` in guard-respecting steps.
    ///
    /// F-3 caps a single update at ±MAX_UI_MULTIPLIER_DEVIATION_BPS and spaces
    /// activations by MIN_UI_MULTIPLIER_UPDATE_INTERVAL, so a test that needs a
    /// far-away multiplier (0.5x, 2x) has to ramp there exactly as an operator would.
    /// Convergence is geometric — each step moves the full 10% unless `target` is closer.
    /// @return steps number of capped updates the walk needed; the rate limit forces a full
    ///               MIN_UI_MULTIPLIER_UPDATE_INTERVAL between consecutive steps.
    function _rampMultiplierTo(uint256 target) internal returns (uint256 steps) {
        uint256 current = token.uiMultiplier();
        uint256 maxBps  = token.MAX_UI_MULTIPLIER_DEVIATION_BPS();
        uint256 denom   = token.BPS_DENOMINATOR();

        for (; current != target; steps++) {
            require(steps < 64, "_rampMultiplierTo: did not converge");

            uint256 band = (current * maxBps) / denom;
            uint256 step;
            if (target > current) {
                uint256 maxUp = current + band;
                step = target < maxUp ? target : maxUp;
            } else {
                uint256 maxDown = current - band;
                step = target > maxDown ? target : maxDown;
            }

            vm.prank(navPublisher);
            token.setUiMultiplier(step);
            current = step;

            // Clear the rate limit so the next step (or the caller's next write) is allowed.
            vm.warp(block.timestamp + token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL());
        }
    }

    /// Set the multiplier to `value` in one step, first clearing the rate limit.
    /// Only valid for values inside the deviation band.
    function _setMultiplierAfterInterval(uint256 value) internal {
        vm.warp(block.timestamp + token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL());
        vm.prank(navPublisher);
        token.setUiMultiplier(value);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 1 — default multiplier after a fresh initialize()
    // ═════════════════════════════════════════════════════════════════════════

    /// A freshly-initialized token reports uiMultiplier() == 1e18 (1.0x) with no
    /// separate setup call needed, and nothing pending.
    function test_uiMultiplier_defaultIsOneAfterInitialize() public view {
        assertEq(token.uiMultiplier(),        ONE, "default uiMultiplier not 1e18");
        assertEq(token.UI_MULTIPLIER_SCALE(), ONE, "UI_MULTIPLIER_SCALE not 1e18");
        assertEq(token.newUIMultiplier(),     ONE, "default newUIMultiplier not 1e18");
        assertEq(token.effectiveAt(),         0,   "fresh token should have nothing scheduled");
    }

    /// initialize() emits the canonical 3-parameter UIMultiplierUpdated when setting the
    /// default. effectiveAtTimestamp is 0 — "effective always" — consistent with
    /// effectiveAt() returning 0 on a fresh token.
    function test_initialize_emitsUIMultiplierUpdated() public {
        GyldBondToken impl = new GyldBondToken();

        vm.expectEmit(false, false, false, true);
        emit UIMultiplierUpdated(0, ONE, 0);

        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Test Bond", "TST", "XX0000000001", 0,
                admin, operator, address(mockSanctions)
            ))
        );
    }

    /// With the default 1.0x multiplier, the UI views mirror the raw views exactly.
    function test_uiViews_identityAtDefaultMultiplier() public {
        vm.prank(issuer);
        token.mint(ap, 1_000e18);

        assertEq(token.balanceOfUI(ap),  token.balanceOf(ap),  "balanceOfUI != balanceOf at 1.0x");
        assertEq(token.totalSupplyUI(),  token.totalSupply(),  "totalSupplyUI != totalSupply at 1.0x");
        assertEq(token.toUIAmount(123e18),   123e18, "toUIAmount not identity at 1.0x");
        assertEq(token.fromUIAmount(123e18), 123e18, "fromUIAmount not identity at 1.0x");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 2 — setUiMultiplier access control and validation
    // ═════════════════════════════════════════════════════════════════════════

    /// UI_MULTIPLIER_ROLE holder can update the multiplier; event carries
    /// (old, new, effectiveAt). Consecutive updates must respect the rate limit, so the
    /// second write here warps a full interval first.
    function test_setUiMultiplier_byRoleHolder_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit UIMultiplierUpdated(ONE, 1.05e18, block.timestamp);

        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        assertEq(token.uiMultiplier(), 1.05e18, "multiplier not updated");
        assertEq(token.effectiveAt(),  block.timestamp, "immediate write should be effective now");

        // Second update: previous value in the event must be the CURRENT value, not 1e18.
        vm.warp(block.timestamp + token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL());

        vm.expectEmit(false, false, false, true);
        emit UIMultiplierUpdated(1.05e18, 0.97e18, block.timestamp);

        vm.prank(navPublisher);
        token.setUiMultiplier(0.97e18);

        assertEq(token.uiMultiplier(), 0.97e18, "second update not applied");
    }

    /// An unprivileged account cannot set the multiplier.
    function test_setUiMultiplier_unprivileged_reverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        token.setUiMultiplier(1.05e18);

        assertEq(token.uiMultiplier(), ONE, "multiplier changed by unprivileged caller");
    }

    /// DEFAULT_ADMIN_ROLE alone is NOT enough — the admin must be granted
    /// UI_MULTIPLIER_ROLE explicitly. Role isolation, same as MINTER/BURNER.
    function test_setUiMultiplier_adminWithoutRole_reverts() public {
        vm.prank(admin);
        vm.expectRevert();
        token.setUiMultiplier(1.05e18);

        assertEq(token.uiMultiplier(), ONE, "multiplier changed by admin without role");
    }

    /// The scheduling entry point is gated by the same role.
    function test_scheduleUiMultiplier_unprivileged_reverts() public {
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        token.scheduleUiMultiplier(1.05e18, block.timestamp + 1 days);

        assertEq(token.effectiveAt(), 0, "schedule written by unprivileged caller");
    }

    /// Zero is an invalid multiplier — fromUIAmount would divide by zero.
    function test_setUiMultiplier_zero_reverts() public {
        vm.prank(navPublisher);
        vm.expectRevert(GyldBondToken.ZeroMultiplier.selector);
        token.setUiMultiplier(0);
    }

    /// A zero multiplier cannot be smuggled in through the scheduling path either.
    function test_scheduleUiMultiplier_zero_reverts() public {
        vm.prank(navPublisher);
        vm.expectRevert(GyldBondToken.ZeroMultiplier.selector);
        token.scheduleUiMultiplier(0, block.timestamp + 1 days);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 3 — toUIAmount / fromUIAmount conversion math
    // ═════════════════════════════════════════════════════════════════════════

    /// Exact scaling for cleanly-divisible amounts at a 1.05x multiplier.
    function test_conversion_exactAtNonUnitMultiplier() public {
        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        assertEq(token.toUIAmount(1_000e18), 1_050e18, "toUIAmount wrong");
        assertEq(token.fromUIAmount(1_050e18), 1_000e18, "fromUIAmount wrong");
    }

    /// Round-trip raw -> UI -> raw is exact or floors by at most 1 wei
    /// (integer division may drop a remainder in each direction).
    function test_conversion_roundTrip_withinRounding() public {
        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        uint256[4] memory amounts = [uint256(7), 999, 123_456_789, 1_000e18 + 1];
        for (uint256 i = 0; i < amounts.length; i++) {
            uint256 raw = amounts[i];
            uint256 roundTripped = token.fromUIAmount(token.toUIAmount(raw));
            assertLe(roundTripped, raw, "round-trip must never inflate");
            assertApproxEqAbs(roundTripped, raw, 1, "round-trip drifted by more than 1 wei");
        }
    }

    /// Conversions also work for a multiplier below 1.0x (e.g. after a markdown).
    /// 0.5x is outside the single-update deviation band, so it is reached by ramping.
    function test_conversion_belowOneMultiplier() public {
        _rampMultiplierTo(0.5e18);

        assertEq(token.uiMultiplier(), 0.5e18, "ramp did not reach 0.5x");
        assertEq(token.toUIAmount(1_000e18), 500e18, "toUIAmount wrong at 0.5x");
        assertEq(token.fromUIAmount(500e18), 1_000e18, "fromUIAmount wrong at 0.5x");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 4 — CRITICAL invariant: display-only, never touches real accounting
    // ═════════════════════════════════════════════════════════════════════════

    /// After setting a non-1.0 multiplier, transfer/mint/burn move RAW amounts and
    /// balanceOf/totalSupply are byte-for-byte what they'd be with no multiplier at
    /// all. Only the *UI views* scale.
    function test_multiplier_doesNotAffectRealAccounting() public {
        address ap2 = address(0xAC);

        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        // Mint — raw amount credited, unscaled.
        vm.prank(issuer);
        token.mint(ap, 1_000e18);
        assertEq(token.balanceOf(ap),   1_000e18, "mint credited a scaled amount");
        assertEq(token.totalSupply(),   1_000e18, "totalSupply scaled by multiplier");
        assertEq(token.balanceOfUI(ap), 1_050e18, "balanceOfUI not scaled");
        assertEq(token.totalSupplyUI(), 1_050e18, "totalSupplyUI not scaled");

        // Transfer — raw amount moves, unscaled on both sides.
        vm.prank(ap);
        token.transfer(ap2, 200e18);
        assertEq(token.balanceOf(ap),    800e18, "sender debited a scaled amount");
        assertEq(token.balanceOf(ap2),   200e18, "receiver credited a scaled amount");
        assertEq(token.balanceOfUI(ap),  840e18, "sender balanceOfUI wrong post-transfer");
        assertEq(token.balanceOfUI(ap2), 210e18, "receiver balanceOfUI wrong post-transfer");

        // Burn — raw amount destroyed, unscaled.
        vm.prank(issuer);
        token.burn(ap, 100e18);
        assertEq(token.balanceOf(ap),   700e18, "burn destroyed a scaled amount");
        assertEq(token.totalSupply(),   900e18, "totalSupply wrong post-burn");
        assertEq(token.balanceOfUI(ap), 735e18, "balanceOfUI wrong post-burn");
        assertEq(token.totalSupplyUI(), 945e18, "totalSupplyUI wrong post-burn");
    }

    /// Changing the multiplier after balances exist re-scales the UI views ONLY —
    /// raw balances are bit-identical before and after the change. 2x is outside the
    /// single-update band, so it is reached by ramping; the point of the test is that
    /// no amount of multiplier movement touches real state.
    function test_multiplierChange_leavesRawBalancesUntouched() public {
        vm.prank(issuer);
        token.mint(ap, 1_000e18);

        uint256 rawBalanceBefore = token.balanceOf(ap);
        uint256 rawSupplyBefore  = token.totalSupply();

        _rampMultiplierTo(2e18);

        assertEq(token.balanceOf(ap), rawBalanceBefore, "balanceOf moved on multiplier change");
        assertEq(token.totalSupply(), rawSupplyBefore,  "totalSupply moved on multiplier change");
        assertEq(token.balanceOfUI(ap), 2_000e18, "balanceOfUI not re-scaled");
        assertEq(token.totalSupplyUI(), 2_000e18, "totalSupplyUI not re-scaled");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // C-1 — REQUIRED IScaledUIAmountNewUIMultiplier extension (scheduled changes)
    // ═════════════════════════════════════════════════════════════════════════

    /// A scheduled change is visible via newUIMultiplier()/effectiveAt() but does NOT
    /// affect uiMultiplier() until its activation timestamp.
    function test_c1_scheduledMultiplier_isPendingUntilEffectiveAt() public {
        uint256 activateAt = block.timestamp + 2 hours;

        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, activateAt);

        assertEq(token.uiMultiplier(),    ONE,        "pending schedule must not change the live value");
        assertEq(token.newUIMultiplier(), 1.1e18,     "newUIMultiplier does not expose the pending value");
        assertEq(token.effectiveAt(),     activateAt, "effectiveAt does not expose the activation time");
    }

    /// Pin the exact activation edge: the new multiplier is live for the whole of the
    /// block that reaches effectiveAt (inclusive `>=`), and not one second earlier.
    function test_c1_activationEdge_isInclusiveAndExact() public {
        uint256 activateAt = block.timestamp + 2 hours;

        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, activateAt);

        vm.warp(activateAt - 1);
        assertEq(token.uiMultiplier(), ONE, "activated one second early");

        vm.warp(activateAt);
        assertEq(token.uiMultiplier(), 1.1e18, "did not activate at exactly effectiveAt");

        vm.warp(activateAt + 1);
        assertEq(token.uiMultiplier(), 1.1e18, "did not stay activated");
    }

    /// The scheduled change flips the *display* views at exactly the same instant.
    function test_c1_scheduledMultiplier_flipsUiViewsAtEffectiveAt() public {
        vm.prank(issuer);
        token.mint(ap, 1_000e18);

        uint256 activateAt = block.timestamp + 2 hours;
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, activateAt);

        vm.warp(activateAt - 1);
        assertEq(token.balanceOfUI(ap),  1_000e18, "balanceOfUI moved before effectiveAt");
        assertEq(token.totalSupplyUI(),  1_000e18, "totalSupplyUI moved before effectiveAt");
        assertEq(token.fromUIAmount(1_000e18), 1_000e18, "fromUIAmount used the pending value early");

        vm.warp(activateAt);
        assertEq(token.balanceOfUI(ap), 1_100e18, "balanceOfUI did not flip at effectiveAt");
        assertEq(token.totalSupplyUI(), 1_100e18, "totalSupplyUI did not flip at effectiveAt");

        // Real accounting is untouched by activation — the whole point of the extension.
        assertEq(token.balanceOf(ap), 1_000e18, "activation moved a real balance");
        assertEq(token.totalSupply(), 1_000e18, "activation moved real totalSupply");
    }

    /// Once a schedule has matured, newUIMultiplier() == uiMultiplier(). Integrators rely on
    /// this to detect "nothing pending" without a separate flag.
    function test_c1_afterActivation_pendingEqualsCurrent() public {
        uint256 activateAt = block.timestamp + 2 hours;

        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, activateAt);
        vm.warp(activateAt);

        assertEq(token.uiMultiplier(), token.newUIMultiplier(), "pending != current after activation");
        assertEq(token.effectiveAt(),  activateAt, "effectiveAt should stay at the matured timestamp");
    }

    /// A still-pending schedule can be REPLACED. The outgoing value keeps displaying, so a
    /// mis-scheduled multiplier can be corrected before any holder ever sees it.
    function test_c1_pendingSchedule_canBeReplacedBeforeActivation() public {
        uint256 firstAt = block.timestamp + 2 hours;

        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, firstAt);

        // Correction: activation is pushed out by the rate limit, but can be submitted now.
        uint256 secondAt = firstAt + token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL();
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(0.95e18, secondAt);

        assertEq(token.newUIMultiplier(), 0.95e18,  "replacement not stored");
        assertEq(token.effectiveAt(),     secondAt, "replacement activation time not stored");

        // The value that was scheduled first must never become live.
        vm.warp(firstAt);
        assertEq(token.uiMultiplier(), ONE, "replaced schedule activated anyway");

        vm.warp(secondAt);
        assertEq(token.uiMultiplier(), 0.95e18, "replacement did not activate");
    }

    /// Scheduling in the past is rejected — it would be an instant change dressed up as a
    /// pre-announcement, and would let the rate limit be walked backwards.
    function test_c1_scheduleInThePast_reverts() public {
        vm.warp(1_000_000);

        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierEffectiveAtInPast.selector, block.timestamp - 1, block.timestamp
        ));
        token.scheduleUiMultiplier(1.05e18, block.timestamp - 1);
    }

    /// Scheduling exactly at `block.timestamp` is allowed and is effective immediately —
    /// this is what setUiMultiplier does internally.
    function test_c1_scheduleAtCurrentTimestamp_isImmediate() public {
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.05e18, block.timestamp);

        assertEq(token.uiMultiplier(), 1.05e18, "scheduling at now was not immediate");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // C-2 — canonical event signatures (topic0 must match the EIP)
    // ═════════════════════════════════════════════════════════════════════════

    /// UIMultiplierUpdated must have the canonical THREE parameters. A different arity is a
    /// different topic0, so an EIP-following indexer would never match the log — this test
    /// compares the emitted topic0 against keccak of the canonical signature string.
    function test_c2_uiMultiplierUpdated_hasCanonicalTopic0AndPayload() public {
        uint256 activateAt = block.timestamp + 3 hours;

        vm.recordLogs();
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, activateAt);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 1, "expected exactly one log");
        assertEq(logs[0].topics[0], TOPIC_UI_MULTIPLIER_UPDATED, "UIMultiplierUpdated topic0 is not canonical");
        assertEq(logs[0].topics.length, 1, "all three params are unindexed per the EIP");

        (uint256 oldM, uint256 newM, uint256 effAt) =
            abi.decode(logs[0].data, (uint256, uint256, uint256));
        assertEq(oldM,  ONE,        "oldMultiplier wrong");
        assertEq(newM,  1.1e18,     "newMultiplier wrong");
        assertEq(effAt, activateAt, "effectiveAtTimestamp wrong: this is the param C-2 added");
    }

    /// TransferWithUIAmount is emitted on transfer with the canonical topic0 and the
    /// UI-scaled transfer amount alongside the raw one.
    function test_c2_transferWithUIAmount_emittedOnTransfer() public {
        vm.prank(issuer);
        token.mint(ap, 1_000e18);
        vm.prank(navPublisher);
        token.setUiMultiplier(1.1e18);

        address ap2 = address(0xAC);

        vm.expectEmit(true, true, false, true);
        emit TransferWithUIAmount(ap, ap2, 200e18, 220e18);

        vm.prank(ap);
        token.transfer(ap2, 200e18);
    }

    /// The event covers mint (from == 0) and burn (to == 0) too, matching the coverage of
    /// the canonical ERC-20 Transfer event, and carries the canonical topic0.
    function test_c2_transferWithUIAmount_coversMintAndBurnWithCanonicalTopic0() public {
        vm.prank(navPublisher);
        token.setUiMultiplier(1.1e18);

        // ── Mint ──
        vm.recordLogs();
        vm.prank(issuer);
        token.mint(ap, 1_000e18);
        Vm.Log[] memory mintLogs = vm.getRecordedLogs();

        bool foundMint;
        for (uint256 i = 0; i < mintLogs.length; i++) {
            if (mintLogs[i].topics[0] != TOPIC_TRANSFER_WITH_UI_AMOUNT) continue;
            foundMint = true;
            assertEq(address(uint160(uint256(mintLogs[i].topics[1]))), address(0), "mint `from` not zero");
            assertEq(address(uint160(uint256(mintLogs[i].topics[2]))), ap,          "mint `to` wrong");
            (uint256 amount, uint256 uiAmount) = abi.decode(mintLogs[i].data, (uint256, uint256));
            assertEq(amount,   1_000e18, "mint raw amount wrong");
            assertEq(uiAmount, 1_100e18, "mint UI amount not scaled");
        }
        assertTrue(foundMint, "TransferWithUIAmount not emitted on mint");

        // ── Burn ──
        vm.recordLogs();
        vm.prank(issuer);
        token.burn(ap, 100e18);
        Vm.Log[] memory burnLogs = vm.getRecordedLogs();

        bool foundBurn;
        for (uint256 i = 0; i < burnLogs.length; i++) {
            if (burnLogs[i].topics[0] != TOPIC_TRANSFER_WITH_UI_AMOUNT) continue;
            foundBurn = true;
            assertEq(address(uint160(uint256(burnLogs[i].topics[1]))), ap,          "burn `from` wrong");
            assertEq(address(uint160(uint256(burnLogs[i].topics[2]))), address(0), "burn `to` not zero");
            (uint256 amount, uint256 uiAmount) = abi.decode(burnLogs[i].data, (uint256, uint256));
            assertEq(amount,   100e18, "burn raw amount wrong");
            assertEq(uiAmount, 110e18, "burn UI amount not scaled");
        }
        assertTrue(foundBurn, "TransferWithUIAmount not emitted on burn");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // C-3 — ERC-165 must advertise every implemented ERC-8056 interface
    // ═════════════════════════════════════════════════════════════════════════

    /// All four interface ids that the contract genuinely implements must report true.
    /// An earlier revision advertised only the core id while conversion and balances were
    /// live but undiscoverable.
    function test_c3_supportsInterface_allFourErc8056Ids() public view {
        assertTrue(token.supportsInterface(ID_CORE),       "core IScaledUIAmount not advertised");
        assertTrue(token.supportsInterface(ID_PENDING),    "IScaledUIAmountNewUIMultiplier not advertised");
        assertTrue(token.supportsInterface(ID_CONVERSION), "IScaledUIAmountConversion not advertised");
        assertTrue(token.supportsInterface(ID_BALANCES),   "IScaledUIAmountBalances not advertised");

        // Pre-existing support must be preserved.
        assertTrue(token.supportsInterface(type(IAccessControl).interfaceId), "IAccessControl support lost");
        assertTrue(token.supportsInterface(type(IERC165).interfaceId),        "IERC165 support lost");
        assertFalse(token.supportsInterface(0xffffffff), "0xffffffff must be unsupported per ERC-165");
    }

    /// Our locally-declared interfaces must hash to the canonical ids published in the EIP.
    /// This is the check that catches a selector typo in either the contract or this suite.
    function test_c3_interfaceIds_matchCanonicalEipValues() public pure {
        assertEq(type(IScaledUIAmount).interfaceId,                ID_CORE,       "core id != 0xa60bf13d");
        assertEq(type(IScaledUIAmountNewUIMultiplier).interfaceId, ID_PENDING,    "pending id != 0x4bd27648");
        assertEq(type(IScaledUIAmountConversion).interfaceId,      ID_CONVERSION, "conversion id != 0x57854fc3");
        assertEq(type(IScaledUIAmountBalances).interfaceId,        ID_BALANCES,   "balances id != 0xd890fd71");
    }

    /// The token is callable through each declared ERC-8056 interface.
    function test_c3_erc8056_viewThroughEachInterface() public {
        uint256 activateAt = block.timestamp + 2 hours;
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.05e18, activateAt);

        vm.prank(issuer);
        token.mint(ap, 1_000e18);

        assertEq(IScaledUIAmount(address(token)).uiMultiplier(), ONE, "core view mismatch");

        assertEq(IScaledUIAmountNewUIMultiplier(address(token)).newUIMultiplier(), 1.05e18, "pending view mismatch");
        assertEq(IScaledUIAmountNewUIMultiplier(address(token)).effectiveAt(), activateAt, "effectiveAt mismatch");

        assertEq(IScaledUIAmountConversion(address(token)).toUIAmount(100e18),   100e18, "toUIAmount mismatch");
        assertEq(IScaledUIAmountConversion(address(token)).fromUIAmount(100e18), 100e18, "fromUIAmount mismatch");

        assertEq(IScaledUIAmountBalances(address(token)).balanceOfUI(ap), 1_000e18, "balanceOfUI mismatch");
        assertEq(IScaledUIAmountBalances(address(token)).totalSupplyUI(), 1_000e18, "totalSupplyUI mismatch");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F-1 — the "upgraded but uninitialised" window must not exist
    // ═════════════════════════════════════════════════════════════════════════

    /// Reproduce the exact storage image of a proxy deployed BEFORE the ERC-8056 fields
    /// existed: offsets 3/4/5 of the namespaced struct were never written, so they read 0.
    ///
    /// Before the fix that state made balanceOfUI/totalSupplyUI/toUIAmount return 0 for
    /// every holder — everyone appears to hold nothing — and made fromUIAmount revert with
    /// a division-by-zero panic (0x12). After the fix a 0 multiplier is unreachable on read:
    /// it normalises to 1.0x, which reproduces the exact pre-upgrade display because
    /// pre-upgrade balances were never scaled.
    function test_f1_legacyProxyStorageImage_isNeverReadableAsZero() public {
        // Derive the ERC-7201 root rather than trusting a copy-pasted literal, and prove the
        // offsets point where we think they do before relying on them.
        bytes32 root = keccak256(abi.encode(uint256(keccak256("gyld.GyldBondToken")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(
            root,
            0x0fe35ba304a016e79d78a184eb899c1e21310138e0bfe9a54648a2dfe0da0d00,
            "ERC-7201 root drifted from the contract's _STORAGE_LOCATION"
        );
        assertEq(
            uint256(vm.load(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER))),
            ONE,
            "offset 3 is not uiMultiplier: slot map is stale"
        );

        vm.prank(issuer);
        token.mint(ap, 1_000e18);

        // Wipe the three ERC-8056 slots: exactly what upgradeToAndCall leaves behind on a
        // pre-extension proxy, with no follow-up initializer call of any kind.
        vm.store(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER),              bytes32(0));
        vm.store(address(token), bytes32(uint256(root) + SLOT_NEW_UI_MULTIPLIER),          bytes32(0));
        vm.store(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER_EFFECTIVE_AT), bytes32(0));

        // Every read is safe and reports the pre-upgrade (unscaled) truth.
        assertEq(token.uiMultiplier(),    ONE, "zeroed storage read back as a 0 multiplier");
        assertEq(token.newUIMultiplier(), ONE, "zeroed storage read back as a 0 pending multiplier");
        assertEq(token.effectiveAt(),     0,   "zeroed storage should report nothing scheduled");

        assertEq(token.balanceOfUI(ap), token.balanceOf(ap), "holder appears to hold nothing");
        assertEq(token.totalSupplyUI(), token.totalSupply(), "totalSupplyUI collapsed to 0");
        assertEq(token.toUIAmount(1_000e18), 1_000e18, "toUIAmount collapsed to 0");

        // This is the call that used to panic with 0x12.
        assertEq(token.fromUIAmount(1_000e18), 1_000e18, "fromUIAmount panicked on a 0 divisor");
    }

    /// A real upgrade with an EMPTY initializer payload is sufficient: no post-upgrade call
    /// is needed, so there is no window between `upgradeToAndCall` and a follow-up tx.
    function test_f1_upgradeWithNoInitializerCall_leavesNoBrokenWindow() public {
        bytes32 root = keccak256(abi.encode(uint256(keccak256("gyld.GyldBondToken")) - 1))
            & ~bytes32(uint256(0xff));

        vm.prank(issuer);
        token.mint(ap, 1_000e18);

        // Pre-extension storage image.
        vm.store(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER),              bytes32(0));
        vm.store(address(token), bytes32(uint256(root) + SLOT_NEW_UI_MULTIPLIER),          bytes32(0));
        vm.store(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER_EFFECTIVE_AT), bytes32(0));

        GyldBondTokenScaledV2 v2Impl = new GyldBondTokenScaledV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(v2Impl), ""); // deliberately no initializer payload

        assertEq(GyldBondTokenScaledV2(address(token)).version(), 2, "upgrade did not take");
        assertEq(token.uiMultiplier(), ONE, "multiplier not usable immediately after a bare upgrade");
        assertEq(token.balanceOfUI(ap), 1_000e18, "balanceOfUI wrong immediately after a bare upgrade");
        assertEq(token.fromUIAmount(1_000e18), 1_000e18, "fromUIAmount panicked after a bare upgrade");
    }

    /// The first write on a migrated proxy persists the normalised 1.0x rather than leaving
    /// a 0 in the outgoing slot, and the deviation cap is measured against 1.0x — so the
    /// self-healing path cannot be used to escape the F-3 band.
    function test_f1_firstWriteOnMigratedProxy_persistsNormalisedValue() public {
        bytes32 root = keccak256(abi.encode(uint256(keccak256("gyld.GyldBondToken")) - 1))
            & ~bytes32(uint256(0xff));
        vm.store(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER),              bytes32(0));
        vm.store(address(token), bytes32(uint256(root) + SLOT_NEW_UI_MULTIPLIER),          bytes32(0));
        vm.store(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER_EFFECTIVE_AT), bytes32(0));

        // Band is enforced relative to the normalised 1.0x, not to the raw 0.
        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierDeviationTooLarge.selector, 2e18, ONE
        ));
        token.setUiMultiplier(2e18);

        uint256 activateAt = block.timestamp + 2 hours;
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, activateAt);

        // Outgoing slot now holds the normalised 1e18, so the pending schedule displays 1.0x
        // rather than 0 while it waits.
        assertEq(
            uint256(vm.load(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER))),
            ONE,
            "outgoing slot was left at 0 instead of the normalised 1e18"
        );
        assertEq(token.uiMultiplier(), ONE, "pending window on a migrated proxy reads wrong");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F-2 — no ungated reinitializer; the version-2 slot stays available
    // ═════════════════════════════════════════════════════════════════════════

    /// `initializeUiMultiplierV2()` was `external reinitializer(2)` with no access control:
    /// any address could call it, and doing so permanently consumed the version-2 slot,
    /// letting a front-runner block every future v2 migration. It is removed outright —
    /// `_uiMultiplierState()` makes it unnecessary — so the selector is not callable at all.
    function test_f2_initializeUiMultiplierV2_selectorIsGone() public {
        (bool ok, ) = address(token).call(abi.encodeWithSignature("initializeUiMultiplierV2()"));
        assertFalse(ok, "initializeUiMultiplierV2 is still callable");
    }

    /// The reinitializer(2) version slot is still unconsumed, so a genuine v2 migration can
    /// use it. Before the fix, anyone could have burned it with a single unpriced call.
    function test_f2_reinitializerVersion2SlotIsStillAvailable() public {
        // OZ Initializable's ERC-7201 storage: the first uint64 is `_initialized`.
        bytes32 initSlot = keccak256(abi.encode(uint256(keccak256("openzeppelin.storage.Initializable")) - 1))
            & ~bytes32(uint256(0xff));
        assertEq(
            uint64(uint256(vm.load(address(token), initSlot))),
            1,
            "version slot advanced past 1 without any migration running"
        );

        GyldBondTokenReinitV2 v2Impl = new GyldBondTokenReinitV2();

        vm.expectEmit(false, false, false, false);
        emit GyldBondTokenReinitV2.V2MigrationRan();

        vm.prank(admin);
        token.upgradeToAndCall(
            address(v2Impl),
            abi.encodeCall(GyldBondTokenReinitV2.initializeV2Migration, ())
        );

        assertEq(
            uint64(uint256(vm.load(address(token), initSlot))),
            2,
            "v2 migration did not consume the version-2 slot"
        );
        // The multiplier is untouched by an unrelated migration.
        assertEq(token.uiMultiplier(), ONE, "v2 migration disturbed the multiplier");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // F-3 — deviation cap + rate limit, mirroring KaleidoscopeNAVFeed
    // ═════════════════════════════════════════════════════════════════════════

    /// The exact reproduction of the reported finding: a role holder setting 1000e18 and
    /// then 1 in the SAME block, swinging displayed balances by 1e18x. Both writes must now
    /// be refused, and the displayed balance must not move at all.
    function test_f3_unboundedSwingInOneBlock_isRefused() public {
        vm.prank(issuer);
        token.mint(ap, 1_000e18);
        uint256 displayedBefore = token.balanceOfUI(ap);

        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierDeviationTooLarge.selector, 1000e18, ONE
        ));
        token.setUiMultiplier(1000e18);

        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierDeviationTooLarge.selector, 1, ONE
        ));
        token.setUiMultiplier(1);

        assertEq(token.uiMultiplier(), ONE, "multiplier moved despite both writes reverting");
        assertEq(token.balanceOfUI(ap), displayedBefore, "displayed balance swung");
    }

    /// Pin the exact upper edge of the deviation band: +10% to the wei is accepted,
    /// +10% plus one wei is refused.
    function test_f3_deviationBand_upperEdgeIsExact() public {
        uint256 maxUp = ONE + (ONE * token.MAX_UI_MULTIPLIER_DEVIATION_BPS()) / token.BPS_DENOMINATOR();
        assertEq(maxUp, 1.1e18, "band arithmetic changed");

        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierDeviationTooLarge.selector, maxUp + 1, ONE
        ));
        token.setUiMultiplier(maxUp + 1);

        vm.prank(navPublisher);
        token.setUiMultiplier(maxUp);
        assertEq(token.uiMultiplier(), maxUp, "exactly +10% should be accepted");
    }

    /// Pin the exact lower edge: -10% to the wei is accepted, one wei further is refused.
    function test_f3_deviationBand_lowerEdgeIsExact() public {
        uint256 maxDown = ONE - (ONE * token.MAX_UI_MULTIPLIER_DEVIATION_BPS()) / token.BPS_DENOMINATOR();
        assertEq(maxDown, 0.9e18, "band arithmetic changed");

        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierDeviationTooLarge.selector, maxDown - 1, ONE
        ));
        token.setUiMultiplier(maxDown - 1);

        vm.prank(navPublisher);
        token.setUiMultiplier(maxDown);
        assertEq(token.uiMultiplier(), maxDown, "exactly -10% should be accepted");
    }

    /// A second update inside MIN_UI_MULTIPLIER_UPDATE_INTERVAL is refused even when it sits
    /// inside the deviation band — this is what stops in-block oscillation.
    function test_f3_secondUpdateWithinInterval_reverts() public {
        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        uint256 firstEffectiveAt = block.timestamp;
        uint256 interval         = token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL();

        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierUpdateTooSoon.selector, firstEffectiveAt + interval
        ));
        token.setUiMultiplier(1.02e18);

        assertEq(token.uiMultiplier(), 1.05e18, "in-interval write mutated the multiplier");
    }

    /// Pin the exact rate-limit edge: one second short of the interval is refused, the
    /// interval boundary itself is accepted.
    function test_f3_rateLimitEdgeIsExact() public {
        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        uint256 nextAllowedAt = block.timestamp + token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL();

        vm.warp(nextAllowedAt - 1);
        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierUpdateTooSoon.selector, nextAllowedAt
        ));
        token.setUiMultiplier(1.06e18);

        vm.warp(nextAllowedAt);
        vm.prank(navPublisher);
        token.setUiMultiplier(1.06e18);
        assertEq(token.uiMultiplier(), 1.06e18, "write at exactly the interval boundary was refused");
    }

    /// The rate limit is measured on ACTIVATION time, so scheduling cannot be used to pack
    /// two activations closer together than the interval.
    function test_f3_schedulingCannotPackActivationsCloserThanInterval() public {
        uint256 interval = token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL();
        uint256 firstAt  = block.timestamp + 10 hours;

        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, firstAt);

        vm.prank(navPublisher);
        vm.expectRevert(abi.encodeWithSelector(
            GyldBondToken.UiMultiplierUpdateTooSoon.selector, firstAt + interval
        ));
        token.scheduleUiMultiplier(1.05e18, firstAt + interval - 1);

        // Exactly one interval later is fine.
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.05e18, firstAt + interval);
        assertEq(token.effectiveAt(), firstAt + interval, "boundary schedule not accepted");
    }

    /// The deviation cap composes with the ramp: repeated capped steps do reach a distant
    /// value, but only across as many intervals as the band requires. Guards bound the
    /// RATE of change, they do not freeze the multiplier.
    ///
    /// The assertion counts UPDATES rather than elapsed `block.timestamp`: under via_ir the
    /// optimiser treats `timestamp()` as readonly and dedupes reads taken either side of a
    /// `vm.warp`, so a wall-clock delta measured in the test body is not trustworthy. Step
    /// count is the honest measure anyway, since the rate limit forces one full
    /// MIN_UI_MULTIPLIER_UPDATE_INTERVAL per step (pinned by test_f3_rateLimitEdgeIsExact).
    function test_f3_rampedUpdates_reachDistantValueAcrossIntervals() public {
        uint256 steps = _rampMultiplierTo(2e18);

        assertEq(token.uiMultiplier(), 2e18, "ramp did not converge");
        // log(2)/log(1.1) ~= 7.27, so a +10%-capped walk needs at least 8 updates,
        // i.e. at least 8 hours of wall time at MIN_UI_MULTIPLIER_UPDATE_INTERVAL == 1 hour.
        assertGe(steps, 8, "reached 2x in fewer capped steps than the band permits");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 7 — storage-layout safety across a UUPS upgrade
    // ═════════════════════════════════════════════════════════════════════════

    /// Pin every field offset in the ERC-7201 namespaced struct against the raw slots.
    ///
    /// This is the test that fails if someone INSERTS rather than APPENDS a field. The v1
    /// fields (sanctionsList / isin / maturityTimestamp) must keep offsets 0/1/2 forever —
    /// every live proxy already has data there — and the three ERC-8056 fields must stay at
    /// 3/4/5. Reordering any of them silently reinterprets live storage on the next upgrade.
    function test_storageLayout_erc7201OffsetsArePinned() public {
        bytes32 root = keccak256(abi.encode(uint256(keccak256("gyld.GyldBondToken")) - 1))
            & ~bytes32(uint256(0xff));

        // Establish distinguishable values in every slot.
        uint256 activateAt = block.timestamp + 5 hours;
        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);
        vm.warp(block.timestamp + token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL());
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, activateAt);

        assertEq(
            address(uint160(uint256(vm.load(address(token), bytes32(uint256(root) + 0))))),
            address(mockSanctions),
            "offset 0 is not sanctionsList"
        );
        // Short strings are stored inline as (data | 2*length) in the same slot.
        assertEq(
            uint256(vm.load(address(token), bytes32(uint256(root) + 1))) & 0xff,
            2 * bytes(token.isin()).length,
            "offset 1 is not isin"
        );
        assertEq(
            uint256(vm.load(address(token), bytes32(uint256(root) + 2))),
            token.maturityTimestamp(),
            "offset 2 is not maturityTimestamp"
        );
        assertEq(
            uint256(vm.load(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER))),
            1.05e18,
            "offset 3 is not uiMultiplier (outgoing value)"
        );
        assertEq(
            uint256(vm.load(address(token), bytes32(uint256(root) + SLOT_NEW_UI_MULTIPLIER))),
            1.1e18,
            "offset 4 is not newUIMultiplier (pending value)"
        );
        assertEq(
            uint256(vm.load(address(token), bytes32(uint256(root) + SLOT_UI_MULTIPLIER_EFFECTIVE_AT))),
            activateAt,
            "offset 5 is not uiMultiplierEffectiveAt"
        );

        // Nothing was written past the struct.
        assertEq(uint256(vm.load(address(token), bytes32(uint256(root) + 6))), 0, "wrote past offset 5");
    }

    /// The appended ERC-8056 fields must not corrupt existing state (isin, maturity,
    /// sanctionsList, balances) — and must themselves survive an upgrade, including a
    /// pending schedule.
    function test_upgrade_preservesStateIncludingUiMultiplier() public {
        // Establish state: balances, a non-default multiplier, and a pending schedule.
        vm.prank(issuer);
        token.mint(ap, 1_000e18);
        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        uint256 activateAt = block.timestamp + token.MIN_UI_MULTIPLIER_UPDATE_INTERVAL() + 1 hours;
        vm.prank(navPublisher);
        token.scheduleUiMultiplier(1.1e18, activateAt);

        uint256 balanceBefore     = token.balanceOf(ap);
        uint256 supplyBefore      = token.totalSupply();
        string  memory isinBefore = token.isin();
        uint256 maturityBefore    = token.maturityTimestamp();
        address sanctionsBefore   = address(token.sanctionsList());
        uint256 multiplierBefore  = token.uiMultiplier();

        // Deploy V2 implementation and upgrade the proxy.
        GyldBondTokenScaledV2 v2Impl = new GyldBondTokenScaledV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(v2Impl), "");

        // V2 code is live.
        assertEq(GyldBondTokenScaledV2(address(token)).version(), 2, "version() not available post-upgrade");

        // All pre-upgrade state is intact — including the new appended fields.
        assertEq(token.balanceOf(ap),            balanceBefore,    "ap balance corrupted");
        assertEq(token.totalSupply(),            supplyBefore,     "totalSupply corrupted");
        assertEq(token.isin(),                   isinBefore,       "ISIN corrupted");
        assertEq(token.maturityTimestamp(),      maturityBefore,   "maturity corrupted");
        assertEq(address(token.sanctionsList()), sanctionsBefore,  "sanctionsList corrupted");
        assertEq(token.uiMultiplier(),           multiplierBefore, "uiMultiplier corrupted");
        assertEq(token.newUIMultiplier(),        1.1e18,           "pending multiplier corrupted");
        assertEq(token.effectiveAt(),            activateAt,       "effectiveAt corrupted");

        // UI views still scale correctly post-upgrade, and the schedule still activates.
        assertEq(token.balanceOfUI(ap), 1_050e18, "balanceOfUI wrong post-upgrade");
        vm.warp(activateAt);
        assertEq(token.balanceOfUI(ap), 1_100e18, "schedule did not survive the upgrade");
    }
}
