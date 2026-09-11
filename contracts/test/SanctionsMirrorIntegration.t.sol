// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {GyldBondToken} from "../GyldBondToken.sol";
import {SanctionsOracleMirror} from "../SanctionsOracleMirror.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {SelectiveRevertingOracle, GasGriefingOracle} from "./SanctionsOracleMirror.t.sol";

/// @title  Audit FIND-006 — a broken forwarding oracle, seen from the transfer path
///
/// @notice Every other misbehaving-oracle test in this tree exercises
///         {SanctionsOracleMirror} standalone: it asserts what `isSanctioned` does, which
///         is one hop short of what anybody actually cares about. This file wires a mirror
///         into a real {GyldBondToken} the way production does — `SANCTIONS_LIST` points at
///         a mirror, the mirror points at a vendor oracle — and asks what a HOLDER
///         experiences when that vendor oracle turns bad underneath them.
///
///         Three things only become visible at this distance, and all three are claims the
///         FIND-006 write-up makes about the token without testing it there:
///
///           1. the blast radius is every transfer of the series, not a failed read;
///           2. the mirror's `FORWARDING_GAS` cap survives the token's UNCAPPED high-level
///              call, so a gas-griefing upstream cannot reach through two hops to drain a
///              holder's transaction (decision D-38);
///           3. recovery does NOT require `setSanctionsList` behind the 48h timelock. The
///              compliance Safe holds `DEFAULT_ADMIN_ROLE` on the mirror and can zero the
///              forwarding oracle in one untimelocked call.
///
///         Each is pinned below, because each is the kind of claim that reads as obvious
///         from the source and stops being true the first time somebody adds a hop.
contract SanctionsMirrorIntegrationTest is Test {
    GyldBondToken           token;
    SanctionsOracleMirror   mirror;
    MockSanctionsList       upstream;

    /// `DEFAULT_ADMIN_ROLE` on the token. In production this is the TimelockController, and
    /// that is the whole point of the recovery test: this address is the SLOW lever.
    address tokenAdmin = address(0xA0);
    /// `DEFAULT_ADMIN_ROLE` on the mirror — the compliance ops Safe, not timelocked.
    address complianceSafe = address(0xA1);
    address keeper = address(0xA2);
    address operator = address(0xA3);

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address sdnHolder = address(0x5D4);

    function setUp() public {
        upstream = new MockSanctionsList(address(this));

        mirror = new SanctionsOracleMirror(complianceSafe, keeper, address(upstream));

        address[] memory sdn = new address[](1);
        sdn[0] = sdnHolder;
        vm.prank(keeper);
        mirror.addToSanctionsList(sdn);

        GyldBondToken impl = new GyldBondToken();
        token = GyldBondToken(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Gyld US Treasury Bond 2026-06",
                "GYLD-UST-2606",
                "US912797KR72",
                1_780_000_000,
                tokenAdmin,
                operator,
                address(mirror)          // the shape production deploys
            ))
        )));

        // The test contract stands in for IssuanceManager; nothing here exercises issuance.
        vm.startPrank(tokenAdmin);
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.grantRole(token.BURNER_ROLE(), address(this));
        vm.stopPrank();

        token.mint(alice, 1_000e18);
    }

    // ── baseline ──────────────────────────────────────────────────────────────

    /// The wiring works before anything is broken, and it still screens. Without this the
    /// tests below could pass against a mirror that was never consulted at all.
    function test_baseline_mirrorScreensThroughTheToken() public {
        vm.prank(alice);
        token.transfer(bob, 100e18);
        assertEq(token.balanceOf(bob), 100e18);

        // Local list reaches the transfer path.
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.AccountSanctioned.selector, sdnHolder));
        vm.prank(alice);
        token.transfer(sdnHolder, 1e18);

        // So does the forwarding oracle.
        upstream.setSanctioned(bob, true);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.AccountSanctioned.selector, bob));
        vm.prank(alice);
        token.transfer(bob, 1e18);
    }

    // ── 1. blast radius ───────────────────────────────────────────────────────

    /// FIND-006's core claim, at the layer it actually bites. {SelectiveRevertingOracle}
    /// answers the `address(0)` admission probe and reverts for every real address, so the
    /// compliance Safe installs it without a hint that anything is wrong — and every
    /// transfer of the series stops on the next block.
    ///
    /// Note what the holder sees: not `AccountSanctioned`, which at least names a cause, but
    /// the upstream's own revert bubbling through two hops.
    function test_transfer_bricksWhenTheUpstreamRevertsForRealHolders() public {
        // Deployed on its own line: `vm.prank` applies to the next call, and an inline
        // `new` would spend it on the CREATE instead of on `setForwardingOracle`.
        SelectiveRevertingOracle bad = new SelectiveRevertingOracle();
        vm.prank(complianceSafe);
        mirror.setForwardingOracle(address(bad)); // admitted

        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 1e18);

        // Not one holder — anyone. The receiver is screened too, so a fresh pair is just
        // as stuck as the pair that was mid-flight.
        vm.expectRevert();
        vm.prank(alice);
        token.transfer(address(0xFEE), 1e18);
    }

    /// Mint and burn are deliberately NOT screened (`_update` skips a zero counterparty), so
    /// issuance and redemption survive a bricked oracle. That is a designed exemption rather
    /// than an accident, and it is what keeps a compliance outage from also trapping the
    /// custodian's own position — worth pinning here, where the oracle is genuinely broken,
    /// and not only in the unit test that asserts it against an unset list.
    function test_mintAndBurn_surviveABrickedUpstream() public {
        SelectiveRevertingOracle bad = new SelectiveRevertingOracle();
        vm.prank(complianceSafe);
        mirror.setForwardingOracle(address(bad));

        token.mint(alice, 1e18);
        token.burn(alice, 1e18);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    // ── 2. the gas cap holds across both hops ────────────────────────────────

    /// D-38: `GyldBondToken._requireAccess` forwards ALL remaining gas to its oracle on
    /// purpose — the cap belongs on the third-party hop inside the mirror, not on the
    /// token's call to its own oracle. That reasoning is only sound if the inner cap
    /// actually survives being called through an uncapped outer one. It does, but nothing
    /// asserted it end to end, which is the gap this test closes.
    ///
    /// The transfer SUCCEEDS: the griefer burns its allowance and then answers `false`, so
    /// the holder pays for the waste but is not censored. That is the fail-closed design
    /// behaving well — the cost is bounded and the answer is honoured.
    function test_transfer_containsAGasGriefingUpstream() public {
        GasGriefingOracle bad = new GasGriefingOracle();
        vm.prank(complianceSafe);
        mirror.setForwardingOracle(address(bad));

        uint256 startGas = gasleft();
        vm.prank(alice);
        token.transfer(bob, 1e18);
        uint256 gasUsed = startGas - gasleft();

        assertEq(token.balanceOf(bob), 1e18, "a contained griefer must not block the transfer");

        // Two screens (`from` and `to`), each capped at FORWARDING_GAS = 40_000, plus the
        // ERC-20 write itself. A failure here means the cap stopped applying through the
        // token's high-level call and D-38's reasoning no longer holds.
        assertLt(gasUsed, 2 * mirror.FORWARDING_GAS() + 100_000, "griefer escaped FORWARDING_GAS");

        // Lower bound, same reason the standalone griefing test carries one: without it this
        // passes just as happily against a griefer that quietly stopped griefing.
        assertGt(gasUsed, mirror.FORWARDING_GAS(), "griefing upstream was never reached - test is vacuous");
    }

    // ── 3. recovery is the fast lever, not the timelock ──────────────────────

    /// The FIND-006 write-up states recovery "requires `GyldBondToken.setSanctionsList()` on
    /// each token, which sits behind the timelock". It does not. `DEFAULT_ADMIN_ROLE` on the
    /// MIRROR is the compliance Safe with no delay, and `_setForwardingOracle` skips its
    /// probe entirely when the new value is zero — which is what makes the escape hatch work
    /// even while the installed oracle is the thing that cannot be called.
    ///
    /// This is the difference between a 48-hour outage and a multisig round trip, so it is
    /// pinned rather than argued.
    function test_complianceSafeCanRecoverWithoutTheTimelock() public {
        SelectiveRevertingOracle bad = new SelectiveRevertingOracle();
        vm.prank(complianceSafe);
        mirror.setForwardingOracle(address(bad));

        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 1e18);

        // One untimelocked call, by an address that is NOT the token's timelocked admin.
        vm.prank(complianceSafe);
        mirror.setForwardingOracle(address(0));

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);

        // The local list still screens, so recovery does not open the gate — it drops the
        // upstream's contribution, which is the documented cost of zeroing.
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.AccountSanctioned.selector, sdnHolder));
        vm.prank(alice);
        token.transfer(sdnHolder, 1e18);
    }

    /// The asymmetry worth knowing about: the fast lever exists because the MIRROR is
    /// healthy and only its upstream is bad. Break the mirror itself and the only way out is
    /// `setSanctionsList` on the token, which IS the timelocked path the finding describes.
    function test_aBrokenMirrorLeavesOnlyTheTimelockedPath() public {
        // Wipe the mirror's code — a stand-in for any fault that takes the mirror itself out.
        vm.etch(address(mirror), "");

        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, 1e18);

        // The mirror-side lever is gone with it; only the token admin can repoint.
        MockSanctionsList replacement = new MockSanctionsList(address(this));
        vm.prank(tokenAdmin);
        token.setSanctionsList(address(replacement));

        vm.prank(alice);
        token.transfer(bob, 1e18);
        assertEq(token.balanceOf(bob), 1e18);
    }
}
