// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";

// ── Minimal ERC-8056 interface ────────────────────────────────────────────────

/// The interfaceId depends only on the function selectors, so declaring this
/// locally yields the same `type(IERC8056).interfaceId` as the contract's own
/// declaration regardless of where it lives.
interface IERC8056 {
    function uiMultiplier() external view returns (uint256);
}

// ── V2 stub for storage-layout upgrade test ───────────────────────────────────

/// Minimal V2 implementation — same storage layout, adds version() getter.
/// Used only to verify upgradeToAndCall preserves all existing state including
/// the appended uiMultiplier field.
/// @custom:oz-upgrades-unsafe-allow constructor
contract GyldBondTokenScaledV2 is GyldBondToken {
    function version() external pure returns (uint256) { return 2; }
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

    // Mirror of the contract's event so vm.expectEmit can match it.
    event UIMultiplierUpdated(uint256 previousMultiplier, uint256 newMultiplier);

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

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 1 — default multiplier after a fresh initialize()
    // ═════════════════════════════════════════════════════════════════════════

    /// A freshly-initialized token reports uiMultiplier() == 1e18 (1.0x) with no
    /// separate setup call needed.
    function test_uiMultiplier_defaultIsOneAfterInitialize() public view {
        assertEq(token.uiMultiplier(), ONE, "default uiMultiplier not 1e18");
        assertEq(token.UI_MULTIPLIER_SCALE(), ONE, "UI_MULTIPLIER_SCALE not 1e18");
    }

    /// initialize() emits UIMultiplierUpdated(0, 1e18) when setting the default.
    function test_initialize_emitsUIMultiplierUpdated() public {
        GyldBondToken impl = new GyldBondToken();

        vm.expectEmit(false, false, false, true);
        emit UIMultiplierUpdated(0, ONE);

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

    /// UI_MULTIPLIER_ROLE holder can update the multiplier; event carries (prev, new).
    function test_setUiMultiplier_byRoleHolder_updatesAndEmits() public {
        vm.expectEmit(false, false, false, true);
        emit UIMultiplierUpdated(ONE, 1.05e18);

        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        assertEq(token.uiMultiplier(), 1.05e18, "multiplier not updated");

        // Second update: previous value in the event must be the CURRENT value, not 1e18.
        vm.expectEmit(false, false, false, true);
        emit UIMultiplierUpdated(1.05e18, 0.97e18);

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

    /// Zero is an invalid multiplier — fromUIAmount would divide by zero.
    function test_setUiMultiplier_zero_reverts() public {
        vm.prank(navPublisher);
        vm.expectRevert(GyldBondToken.ZeroMultiplier.selector);
        token.setUiMultiplier(0);
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
    function test_conversion_belowOneMultiplier() public {
        vm.prank(navPublisher);
        token.setUiMultiplier(0.5e18);

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
    /// raw balances are bit-identical before and after the change.
    function test_multiplierChange_leavesRawBalancesUntouched() public {
        vm.prank(issuer);
        token.mint(ap, 1_000e18);

        uint256 rawBalanceBefore = token.balanceOf(ap);
        uint256 rawSupplyBefore  = token.totalSupply();

        vm.prank(navPublisher);
        token.setUiMultiplier(2e18);

        assertEq(token.balanceOf(ap), rawBalanceBefore, "balanceOf moved on multiplier change");
        assertEq(token.totalSupply(), rawSupplyBefore,  "totalSupply moved on multiplier change");
        assertEq(token.balanceOfUI(ap), 2_000e18, "balanceOfUI not re-scaled");
        assertEq(token.totalSupplyUI(), 2_000e18, "totalSupplyUI not re-scaled");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 5 — reinitializer for pre-extension proxies
    // ═════════════════════════════════════════════════════════════════════════

    /// initializeUiMultiplierV2() exists for proxies deployed BEFORE this extension.
    /// On a token freshly initialized post-extension the default is already set, so:
    ///   - a first call either reverts (initializer version slot already consumed)
    ///     or succeeds idempotently (re-sets the same 1e18 default);
    ///   - a SECOND call must always revert (version guard consumed either way);
    ///   - uiMultiplier stays 1e18 throughout — no path corrupts the default.
    /// Exact OZ revert selectors are deliberately not asserted (spec: bare expectRevert).
    function test_initializeUiMultiplierV2_guardIsSane_onFreshToken() public {
        // First call: tolerated either way (see doc comment above).
        try token.initializeUiMultiplierV2() {} catch {}
        assertEq(token.uiMultiplier(), ONE, "uiMultiplier corrupted by V2 initializer");

        // Second call: the reinitializer(2) guard must now be consumed.
        vm.expectRevert();
        token.initializeUiMultiplierV2();

        assertEq(token.uiMultiplier(), ONE, "uiMultiplier corrupted by repeated V2 initializer");
    }

    /// The reinitializer never overwrites an operator-set multiplier on a live token:
    /// once the version guard is consumed, calling it again reverts and the current
    /// (non-default) multiplier survives.
    function test_initializeUiMultiplierV2_cannotResetLiveMultiplier() public {
        // Consume the version-2 slot if a fresh initialize() hasn't already.
        try token.initializeUiMultiplierV2() {} catch {}

        vm.prank(navPublisher);
        token.setUiMultiplier(1.25e18);

        vm.expectRevert();
        token.initializeUiMultiplierV2();

        assertEq(token.uiMultiplier(), 1.25e18, "live multiplier reset by reinitializer");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 6 — ERC-165 interface support
    // ═════════════════════════════════════════════════════════════════════════

    /// supportsInterface reports IERC8056 in addition to the pre-existing
    /// IAccessControl and IERC165 support.
    function test_supportsInterface_erc8056AndExisting() public view {
        assertTrue(token.supportsInterface(type(IERC8056).interfaceId),      "IERC8056 not supported");
        assertTrue(token.supportsInterface(type(IAccessControl).interfaceId), "IAccessControl support lost");
        assertTrue(token.supportsInterface(type(IERC165).interfaceId),       "IERC165 support lost");
        assertFalse(token.supportsInterface(0xffffffff), "0xffffffff must be unsupported per ERC-165");
    }

    /// The token is callable through the minimal IERC8056 interface.
    function test_erc8056_viewThroughInterface() public {
        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

        assertEq(IERC8056(address(token)).uiMultiplier(), 1.05e18, "IERC8056 view mismatch");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 7 — storage-layout safety across a UUPS upgrade
    // ═════════════════════════════════════════════════════════════════════════

    /// The appended uiMultiplier field must not corrupt existing state (isin,
    /// maturity, sanctionsList, balances) — and must itself survive an upgrade.
    function test_upgrade_preservesStateIncludingUiMultiplier() public {
        // Establish state: balances + a non-default multiplier.
        vm.prank(issuer);
        token.mint(ap, 1_000e18);
        vm.prank(navPublisher);
        token.setUiMultiplier(1.05e18);

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

        // All pre-upgrade state is intact — including the new appended field.
        assertEq(token.balanceOf(ap),            balanceBefore,    "ap balance corrupted");
        assertEq(token.totalSupply(),            supplyBefore,     "totalSupply corrupted");
        assertEq(token.isin(),                   isinBefore,       "ISIN corrupted");
        assertEq(token.maturityTimestamp(),      maturityBefore,   "maturity corrupted");
        assertEq(address(token.sanctionsList()), sanctionsBefore,  "sanctionsList corrupted");
        assertEq(token.uiMultiplier(),           multiplierBefore, "uiMultiplier corrupted");

        // UI views still scale correctly post-upgrade.
        assertEq(token.balanceOfUI(ap), 1_050e18, "balanceOfUI wrong post-upgrade");
    }
}
