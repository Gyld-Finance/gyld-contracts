// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SanctionsOracleMirror} from "../SanctionsOracleMirror.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {ISanctionsList} from "../interfaces/ISanctionsList.sol";

contract SanctionsOracleMirrorTest is Test {
    event SanctionedAddressesAdded(address[] addrs);
    event SanctionedAddressesRemoved(address[] addrs);
    event ForwardingOracleUpdated(address indexed previous, address indexed next);

    SanctionsOracleMirror oracle;

    address admin      = address(0xA0);
    address updater    = address(0xA1);
    address stranger   = address(0xFF);
    address newUpdater = address(0xA2);

    address sanctioned1 = address(0xBAD1);
    address sanctioned2 = address(0xBAD2);
    address clean       = address(0x600D);

    function setUp() public {
        oracle = new SanctionsOracleMirror(admin, updater, address(0));
    }

    // ── constructor ───────────────────────────────────────────────────────────

    function test_constructor_setsAdminRole() public view {
        assertTrue(oracle.hasRole(oracle.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_constructor_setsUpdaterRole() public view {
        assertTrue(oracle.hasRole(oracle.SANCTIONS_UPDATER_ROLE(), updater));
    }

    function test_constructor_zeroAdmin_reverts() public {
        vm.expectRevert(SanctionsOracleMirror.ZeroAddress.selector);
        new SanctionsOracleMirror(address(0), updater, address(0));
    }

    function test_constructor_zeroUpdater_reverts() public {
        vm.expectRevert(SanctionsOracleMirror.ZeroAddress.selector);
        new SanctionsOracleMirror(admin, address(0), address(0));
    }

    // ── name ──────────────────────────────────────────────────────────────────

    function test_name() public view {
        assertEq(oracle.name(), "Gyld sanctions oracle");
    }

    // ── isSanctioned — initial state ──────────────────────────────────────────

    function test_isSanctioned_returnsFalseByDefault() public view {
        assertFalse(oracle.isSanctioned(sanctioned1));
    }

    // ── addToSanctionsList ────────────────────────────────────────────────────

    function test_addToSanctionsList_singleAddress() public {
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater);
        oracle.addToSanctionsList(addrs);
        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    function test_addToSanctionsList_multipleAddresses() public {
        address[] memory addrs = new address[](2);
        addrs[0] = sanctioned1;
        addrs[1] = sanctioned2;
        vm.prank(updater);
        oracle.addToSanctionsList(addrs);
        assertTrue(oracle.isSanctioned(sanctioned1));
        assertTrue(oracle.isSanctioned(sanctioned2));
    }

    function test_addToSanctionsList_doesNotAffectCleanAddress() public {
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater);
        oracle.addToSanctionsList(addrs);
        assertFalse(oracle.isSanctioned(clean));
    }

    function test_addToSanctionsList_emitsEvent() public {
        address[] memory addrs = new address[](2);
        addrs[0] = sanctioned1;
        addrs[1] = sanctioned2;

        vm.expectEmit(false, false, false, true, address(oracle));
        emit SanctionedAddressesAdded(addrs);

        vm.prank(updater);
        oracle.addToSanctionsList(addrs);
    }

    function test_addToSanctionsList_strangerReverts() public {
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(stranger);
        vm.expectRevert();
        oracle.addToSanctionsList(addrs);
    }

    function test_addToSanctionsList_adminReverts() public {
        // Admin holds DEFAULT_ADMIN_ROLE, not SANCTIONS_UPDATER_ROLE — cannot add
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(admin);
        vm.expectRevert();
        oracle.addToSanctionsList(addrs);
    }

    function test_addToSanctionsList_emptyArray_noRevert() public {
        address[] memory empty = new address[](0);
        vm.prank(updater);
        oracle.addToSanctionsList(empty);
    }

    function test_addToSanctionsList_zeroAddress_reverts() public {
        address[] memory addrs = new address[](2);
        addrs[0] = sanctioned1;
        addrs[1] = address(0);
        vm.prank(updater);
        vm.expectRevert(SanctionsOracleMirror.ZeroAddress.selector);
        oracle.addToSanctionsList(addrs);
    }

    function test_removeFromSanctionsList_zeroAddress_reverts() public {
        address[] memory addrs = new address[](2);
        addrs[0] = sanctioned1;
        addrs[1] = address(0);
        vm.prank(updater);
        vm.expectRevert(SanctionsOracleMirror.ZeroAddress.selector);
        oracle.removeFromSanctionsList(addrs);
    }

    function test_addToSanctionsList_idempotent() public {
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);
        vm.prank(updater); oracle.addToSanctionsList(addrs); // second call is fine
        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // ── removeFromSanctionsList ───────────────────────────────────────────────

    function test_removeFromSanctionsList_clearsAddress() public {
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);
        vm.prank(updater); oracle.removeFromSanctionsList(addrs);
        assertFalse(oracle.isSanctioned(sanctioned1));
    }

    function test_removeFromSanctionsList_emitsEvent() public {
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);

        vm.expectEmit(false, false, false, true, address(oracle));
        emit SanctionedAddressesRemoved(addrs);
        vm.prank(updater); oracle.removeFromSanctionsList(addrs);
    }

    function test_removeFromSanctionsList_strangerReverts() public {
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(stranger);
        vm.expectRevert();
        oracle.removeFromSanctionsList(addrs);
    }

    function test_removeFromSanctionsList_nonExistentAddress_noRevert() public {
        address[] memory addrs = new address[](1);
        addrs[0] = clean; // was never added
        vm.prank(updater);
        oracle.removeFromSanctionsList(addrs); // idempotent — must not revert
        assertFalse(oracle.isSanctioned(clean));
    }

    function test_removeFromSanctionsList_onlyTargetAddress() public {
        address[] memory both = new address[](2);
        both[0] = sanctioned1; both[1] = sanctioned2;
        vm.prank(updater); oracle.addToSanctionsList(both);

        address[] memory one = new address[](1);
        one[0] = sanctioned1;
        vm.prank(updater); oracle.removeFromSanctionsList(one);

        assertFalse(oracle.isSanctioned(sanctioned1));
        assertTrue(oracle.isSanctioned(sanctioned2)); // untouched
    }

    // ── role management (DEFAULT_ADMIN_ROLE) ──────────────────────────────────

    function test_admin_canGrantUpdaterRole() public {
        // Cache role bytes before pranking — prank is consumed by the first external
        // call, which would otherwise be the SANCTIONS_UPDATER_ROLE() getter.
        bytes32 updaterRole = oracle.SANCTIONS_UPDATER_ROLE();
        vm.prank(admin);
        oracle.grantRole(updaterRole, newUpdater);
        assertTrue(oracle.hasRole(updaterRole, newUpdater));
    }

    function test_admin_canRevokeUpdaterRole() public {
        bytes32 updaterRole = oracle.SANCTIONS_UPDATER_ROLE();
        vm.prank(admin);
        oracle.revokeRole(updaterRole, updater);
        assertFalse(oracle.hasRole(updaterRole, updater));
    }

    function test_revokedUpdater_cannotAdd() public {
        bytes32 updaterRole = oracle.SANCTIONS_UPDATER_ROLE();
        vm.prank(admin);
        oracle.revokeRole(updaterRole, updater);

        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater);
        vm.expectRevert();
        oracle.addToSanctionsList(addrs);
    }

    function test_newUpdater_canAddAfterGrant() public {
        bytes32 updaterRole = oracle.SANCTIONS_UPDATER_ROLE();
        vm.prank(admin);
        oracle.grantRole(updaterRole, newUpdater);

        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(newUpdater);
        oracle.addToSanctionsList(addrs);
        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    function test_stranger_cannotGrantRole() public {
        bytes32 updaterRole = oracle.SANCTIONS_UPDATER_ROLE();
        vm.prank(stranger);
        vm.expectRevert();
        oracle.grantRole(updaterRole, newUpdater);
    }

    // ── GyldBondToken integration compatibility ───────────────────────────────

    function test_isSanctioned_isViewFunction() public {
        // GyldBondToken._requireAccess calls isSanctioned as a view.
        // This test confirms it returns the right value without side effects.
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);

        // Simulate exactly what GyldBondToken._requireAccess does
        bool blocked = oracle.isSanctioned(sanctioned1);
        assertTrue(blocked);
        assertFalse(oracle.isSanctioned(clean));
    }

    function test_sanctionsUpdaterRole_constantValue() public view {
        assertEq(
            oracle.SANCTIONS_UPDATER_ROLE(),
            keccak256("SANCTIONS_UPDATER_ROLE")
        );
    }

    // ── fuzz ──────────────────────────────────────────────────────────────────

    function testFuzz_addRemoveRoundTrip(address addr) public {
        vm.assume(addr != address(0));

        address[] memory addrs = new address[](1);
        addrs[0] = addr;

        vm.prank(updater); oracle.addToSanctionsList(addrs);
        assertTrue(oracle.isSanctioned(addr));

        vm.prank(updater); oracle.removeFromSanctionsList(addrs);
        assertFalse(oracle.isSanctioned(addr));
    }

    // ── forwarding oracle ─────────────────────────────────────────────────────

    function test_setForwardingOracle_adminCanSet() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(admin);
        oracle.setForwardingOracle(address(mock));
        assertEq(address(oracle.forwardingOracle()), address(mock));
    }

    function test_setForwardingOracle_strangerReverts() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setForwardingOracle(address(mock));
    }

    function test_setForwardingOracle_emitsEvent() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.expectEmit(true, true, false, false, address(oracle));
        emit ForwardingOracleUpdated(address(0), address(mock));
        vm.prank(admin);
        oracle.setForwardingOracle(address(mock));
    }

    function test_setForwardingOracle_canBeZeroed() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(admin); oracle.setForwardingOracle(address(mock));
        vm.prank(admin); oracle.setForwardingOracle(address(0));
        assertEq(address(oracle.forwardingOracle()), address(0));
    }

    function test_setForwardingOracle_selfReferenceReverts() public {
        vm.prank(admin);
        vm.expectRevert(SanctionsOracleMirror.SelfReferenceOracle.selector);
        oracle.setForwardingOracle(address(oracle));
    }

    function test_setForwardingOracle_invalidContractReverts() public {
        // EOA has no code — staticcall probe must reject it
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            SanctionsOracleMirror.InvalidForwardingOracle.selector, stranger
        ));
        oracle.setForwardingOracle(stranger);
    }

    // Forwarding: address only on forwarding oracle → isSanctioned returns true
    function test_isSanctioned_trueFromForwardingOracle() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // Forwarding: address only on local list → isSanctioned returns true (no external call)
    function test_isSanctioned_trueFromLocalList() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);

        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // Forwarding: address on both lists → still returns true
    function test_isSanctioned_trueFromBothLists() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);

        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // Forwarding: clean address on neither list → false
    function test_isSanctioned_falseOnBothLists() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(admin); oracle.setForwardingOracle(address(mock));
        assertFalse(oracle.isSanctioned(clean));
    }

    // Remove from local list does NOT clear forwarding oracle flag
    function test_removeFromLocal_doesNotClearForwardingFlag() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);
        vm.prank(updater); oracle.removeFromSanctionsList(addrs);

        // local cleared, but forwarding oracle still flags it
        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // After zeroing forwarding oracle, removed-local address is clean
    function test_zeroForwarding_thenRemovedLocal_isFalse() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        // Zero out forwarding
        vm.prank(admin); oracle.setForwardingOracle(address(0));
        assertFalse(oracle.isSanctioned(sanctioned1));
    }

    function test_constructor_withForwardingOracle() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        SanctionsOracleMirror o2 = new SanctionsOracleMirror(admin, updater, address(mock));
        assertTrue(o2.isSanctioned(sanctioned1));
        assertFalse(o2.isSanctioned(clean));
    }

    // ── renounceRole override ─────────────────────────────────────────────────

    function test_admin_cannotRenounceAdminRole() public {
        bytes32 adminRole = oracle.DEFAULT_ADMIN_ROLE(); // cache before prank; prank consumed by first call
        vm.prank(admin);
        vm.expectRevert(SanctionsOracleMirror.CannotRenounceAdminRole.selector);
        oracle.renounceRole(adminRole, admin);
    }

    function test_updater_canRenounceOwnRole() public {
        bytes32 updaterRole = oracle.SANCTIONS_UPDATER_ROLE();
        vm.prank(updater);
        oracle.renounceRole(updaterRole, updater);
        assertFalse(oracle.hasRole(updaterRole, updater));
    }


    // ── revokeRole last-admin guard (audit FIND-007 / TEST-59) ────────────────

    /// TEST-59. renounceRole was guarded, revokeRole was not, and DEFAULT_ADMIN_ROLE admins
    /// itself — so the sole holder could self-revoke into the same bricked state.
    function test_revokeRole_lastAdmin_reverts() public {
        bytes32 adminRole = oracle.DEFAULT_ADMIN_ROLE(); // cache: the getter would eat the prank
        assertEq(oracle.defaultAdminCount(), 1);
        vm.prank(admin);
        vm.expectRevert(SanctionsOracleMirror.CannotRemoveLastAdmin.selector);
        oracle.revokeRole(adminRole, admin);
        assertTrue(oracle.hasRole(adminRole, admin));
    }

    /// The handover every deploy script performs — grant successor, then self-revoke.
    function test_revokeRole_nonLastAdmin_succeeds() public {
        bytes32 adminRole = oracle.DEFAULT_ADMIN_ROLE();
        address timelock = address(0xADAD);
        vm.prank(admin); oracle.grantRole(adminRole, timelock);
        vm.prank(admin); oracle.revokeRole(adminRole, admin);
        assertFalse(oracle.hasRole(adminRole, admin));
        vm.prank(timelock);
        vm.expectRevert(SanctionsOracleMirror.CannotRemoveLastAdmin.selector);
        oracle.revokeRole(adminRole, timelock);
    }

    // ── forwarding oracle failure paths ───────────────────────────────────────

    // Forwarding oracle reverts at lookup time → isSanctioned reverts (fail-closed).
    // Uses SelectiveRevertingOracle: answers both admission probes but reverts on every
    // other address — so it can be set, but real lookups fail.
    function test_isSanctioned_forwardingOracleReverts_propagates() public {
        SelectiveRevertingOracle bad = new SelectiveRevertingOracle();
        vm.prank(admin); oracle.setForwardingOracle(address(bad));
        vm.expectRevert();
        oracle.isSanctioned(clean); // non-zero address → oracle reverts → fail-closed
    }

    // Local true short-circuits before the reverting oracle is called
    function test_isSanctioned_localTrue_shortCircuitsRevertingOracle() public {
        SelectiveRevertingOracle bad = new SelectiveRevertingOracle();
        vm.prank(admin); oracle.setForwardingOracle(address(bad));

        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);

        // Must not revert — local check returns true before reaching the bad oracle
        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // Non-canonical bool word (> 1) from forwarding oracle → revert (fail-closed)
    function test_isSanctioned_nonCanonicalBool_reverts() public {
        MalformedReturnOracle bad = new MalformedReturnOracle();
        // Probe also uses same decode — expect revert on setForwardingOracle
        vm.prank(admin);
        vm.expectRevert();
        oracle.setForwardingOracle(address(bad));
    }

    // Self-destructed oracle (code wiped) → probe rejects it
    function test_setForwardingOracle_selfDestructedOracle_reverts() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        // Wipe the contract's code with vm.etch — simulates self-destruct
        vm.etch(address(mock), "");

        // Subsequent isSanctioned call hits codeless address → staticcall ok=true,
        // data.length=0 → revert InvalidForwardingOracle (fail-closed)
        vm.expectRevert(
            abi.encodeWithSelector(SanctionsOracleMirror.InvalidForwardingOracle.selector, address(mock))
        );
        oracle.isSanctioned(clean);
    }

    // ── gas cap ───────────────────────────────────────────────────────────────

    // Gas-griefing oracle is contained — call does not consume unbounded gas
    function test_isSanctioned_gasGriefingOracle_bounded() public {
        GasGriefingOracle bad = new GasGriefingOracle();
        // bad returns a valid false so probe passes
        vm.prank(admin); oracle.setForwardingOracle(address(bad));

        uint256 gasBefore = gasleft();
        // Call with ample gas; the griefing oracle tries to burn it all
        try oracle.isSanctioned{gas: 200_000}(clean) returns (bool) {} catch {}
        uint256 gasUsed = gasBefore - gasleft();

        // Should use well under 100k despite the oracle attempting to burn 1M+
        assertLt(gasUsed, 100_000);

        // Lower bound: the griefer must actually have reached its burn loop.
        // Without this, the assertion above would also pass if GasGriefingOracle
        // silently stopped griefing (which is exactly how the --ir-minimum
        // breakage hid itself). The griefer burns FORWARDING_GAS minus its
        // return reserve, so ~35_000 lands here regardless of optimiser
        // settings — the loop is bounded by gasleft(), not by an iteration
        // count, so its consumption does not move with codegen.
        assertGt(gasUsed, 25_000, "griefing oracle never burned its budget - test is vacuous");
    }

    // ── audit FIND-019: forwarding cycles ─────────────────────────────────────

    /// Builds a chain of real mirrors: mock ← a ← b ← ... and returns them.
    /// Every link is installed through the normal constructor path.
    function _chain(uint256 n, address tail)
        internal
        returns (SanctionsOracleMirror[] memory ms)
    {
        ms = new SanctionsOracleMirror[](n);
        address prev = tail;
        for (uint256 i = 0; i < n; i++) {
            ms[i] = new SanctionsOracleMirror(admin, updater, prev);
            prev = address(ms[i]);
        }
    }

    // 2-cycle: a→mock, b→a. Closing a→b makes a→b→a. Rejected, and a keeps mock.
    function test_setForwardingOracle_twoCycleRejected() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        SanctionsOracleMirror[] memory m = _chain(2, address(mock));
        SanctionsOracleMirror a = m[0];
        SanctionsOracleMirror b = m[1];

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SanctionsOracleMirror.InvalidForwardingOracle.selector, address(b))
        );
        a.setForwardingOracle(address(b));

        // Write rolled back and the chain still resolves.
        assertEq(address(a.forwardingOracle()), address(mock));
        assertTrue(a.isSanctioned(sanctioned1));
        assertFalse(a.isSanctioned(clean));
        assertTrue(b.isSanctioned(sanctioned1));
    }

    // 3-cycle: a→mock, b→a, c→b. Closing a→c makes a→c→b→a.
    function test_setForwardingOracle_threeCycleRejected() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        SanctionsOracleMirror[] memory m = _chain(3, address(mock));
        SanctionsOracleMirror a = m[0];
        SanctionsOracleMirror c = m[2];

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SanctionsOracleMirror.InvalidForwardingOracle.selector, address(c))
        );
        a.setForwardingOracle(address(c));

        assertEq(address(a.forwardingOracle()), address(mock));
        assertTrue(c.isSanctioned(sanctioned1));
    }

    // A non-cyclic chain of mirrors is still installable — the fix rejects cycles, not depth.
    function test_setForwardingOracle_acyclicChainStillAllowed() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        SanctionsOracleMirror[] memory m = _chain(2, address(mock));

        vm.prank(admin); oracle.setForwardingOracle(address(m[1])); // oracle→b→a→mock
        assertEq(address(oracle.forwardingOracle()), address(m[1]));
        assertTrue(oracle.isSanctioned(sanctioned1));
        assertFalse(oracle.isSanctioned(clean));
    }

    // The failed probe returns ok == false rather than bubbling an out-of-gas: the whole
    // rejected call stays inside a small multiple of FORWARDING_GAS.
    function test_setForwardingOracle_cycleRejection_isCheap() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        SanctionsOracleMirror[] memory m = _chain(2, address(mock));

        uint256 before = gasleft();
        vm.prank(admin);
        try m[0].setForwardingOracle{gas: 1_000_000}(address(m[1])) {
            revert("cycle should have been rejected");
        } catch {}
        uint256 used = before - gasleft();
        emit log_named_uint("FIND-019 rejected-cycle gas", used);
        assertLt(used, 200_000);
    }

    // address(0) is "no forwarding": the probe is skipped, so it works even when the
    // currently-installed oracle is dead. This is the escape hatch out of a bad config.
    function test_setForwardingOracle_zeroSkipsProbe_evenWithDeadOracle() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(admin); oracle.setForwardingOracle(address(mock));
        vm.etch(address(mock), ""); // installed oracle now unreadable

        vm.prank(admin); oracle.setForwardingOracle(address(0));
        assertEq(address(oracle.forwardingOracle()), address(0));
        assertFalse(oracle.isSanctioned(clean));
    }

    // ── audit FIND-019: constructor path ──────────────────────────────────────

    // The constructor calls _setForwardingOracle too, so it now writes the pointer before
    // probing. An oracle that reads back through its caller therefore hits an address with
    // no code yet — staticcall succeeds with empty returndata, the callee reverts, the probe
    // sees ok == false, and construction fails closed. No half-built mirror survives.
    function test_constructor_oracleThatReadsBackThroughCaller_reverts() public {
        CallerBackReferenceOracle back = new CallerBackReferenceOracle();
        vm.expectRevert(
            abi.encodeWithSelector(SanctionsOracleMirror.InvalidForwardingOracle.selector, address(back))
        );
        new SanctionsOracleMirror(admin, updater, address(back));
    }

    // Same oracle, post-construction: now address(this) HAS code, so the read back is real
    // recursion. It still terminates on the gas cap and is still rejected.
    function test_setForwardingOracle_oracleThatReadsBackThroughCaller_reverts() public {
        CallerBackReferenceOracle back = new CallerBackReferenceOracle();
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(SanctionsOracleMirror.InvalidForwardingOracle.selector, address(back))
        );
        oracle.setForwardingOracle(address(back));

        assertEq(address(oracle.forwardingOracle()), address(mock));
        assertFalse(oracle.isSanctioned(clean));
    }

    // A mirror constructed onto a live chain of mirrors still works (constructor probe
    // passes through two hops).
    function test_constructor_withMirrorChain() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        mock.setSanctioned(sanctioned1, true);
        SanctionsOracleMirror[] memory m = _chain(2, address(mock));
        SanctionsOracleMirror top = new SanctionsOracleMirror(admin, updater, address(m[1]));
        assertTrue(top.isSanctioned(sanctioned1));
        assertFalse(top.isSanctioned(clean));
    }

    // ── audit FIND-019: per-address routing is NOT caught (accepted limit) ───

    // ACCEPTED LIMIT. The probe asks one question — isSanctioned(address(0)). A candidate
    // that short-circuits that address (defensible on its face: it is the mint/burn
    // endpoint) and forwards every other address back into the mirror passes admission and
    // then bricks screening for every real holder. A second, derived probe subject was
    // tried and removed: a router sharding its keyspace on a property of the address
    // (parity, bitmask) still passed ~55% of the time, so the extra subject bought a coin
    // flip for permanent bytecode and gas. The control that actually works is a deploy-time
    // and monitoring read of the INSTALLED oracle against a fresh subject — see D-36.
    function test_setForwardingOracle_perAddressRouter_isAdmitted_acceptedLimit() public {
        SelectiveRouter r = new SelectiveRouter();
        r.shortCircuit(address(0));

        vm.prank(admin);
        oracle.setForwardingOracle(address(r)); // admitted
        assertEq(address(oracle.forwardingOracle()), address(r));

        vm.expectRevert(); // and every real holder is now unscreenable
        oracle.isSanctioned(clean);
    }

    // ── audit FIND-019: head-first chaining is NOT caught (accepted limit) ────

    // ACCEPTED LIMIT, and the more natural wiring order. Every mirror is deployed with
    // forwardingOracle = 0, which skips the probe entirely; pointing each at the NEXT one
    // means the candidate's own forwardingOracle is still zero when probed, so every probe
    // is a trivial one-hop pass. No cycle is ever formed, yet the head bricks once the
    // chain outgrows FORWARDING_GAS. Depth cannot be bounded at admission: a parent's view
    // of depth goes stale the moment a child gains its own child.
    function test_headFirstChain_everyProbePasses_thenHeadBricks_acceptedLimit() public {
        uint256 n = 30; // warm-read depth; a cold read dies far shallower
        SanctionsOracleMirror[] memory ms = new SanctionsOracleMirror[](n);
        for (uint256 i = 0; i < n; i++) ms[i] = new SanctionsOracleMirror(admin, updater, address(0));

        for (uint256 i = 0; i + 1 < n; i++) {
            vm.prank(admin);
            ms[i].setForwardingOracle(address(ms[i + 1])); // every one succeeds
        }

        vm.expectRevert(); // the head can no longer screen anybody
        ms[0].isSanctioned(clean);
    }

    // ── audit FIND-019: no depth regression ──────────────────────────────────

    // The reorder does not change what depth is admissible — the probe starts at the
    // candidate in either order, and an acyclic candidate chain does not contain `this`.
    function test_acyclicChainDepth_unchangedByTheReorder() public {
        MockSanctionsList mock = new MockSanctionsList(address(this));
        address prev = address(mock);
        uint256 built;
        for (uint256 i = 0; i < 32; i++) {
            try new SanctionsOracleMirror(admin, updater, prev) returns (SanctionsOracleMirror m) {
                prev = address(m); built = i + 1;
            } catch { break; }
        }
        emit log_named_uint("FIND-019 max constructible chain depth", built);
        assertGt(built, 4, "chain never got deep - test is vacuous");
    }

    // ── fuzz: forwarding-path invariant ──────────────────────────────────────

    function testFuzz_forwardingOrLocalTrue_meansTrue(address addr) public {
        vm.assume(addr != address(0));
        MockSanctionsList mock = new MockSanctionsList(address(this));
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        // local only
        address[] memory addrs = new address[](1);
        addrs[0] = addr;
        vm.prank(updater); oracle.addToSanctionsList(addrs);
        assertTrue(oracle.isSanctioned(addr));

        // clear local, set forwarding only
        vm.prank(updater); oracle.removeFromSanctionsList(addrs);
        mock.setSanctioned(addr, true);
        assertTrue(oracle.isSanctioned(addr));

        // both clear
        mock.setSanctioned(addr, false);
        assertFalse(oracle.isSanctioned(addr));
    }
}

// ── Helper contracts for failure-path tests ───────────────────────────────────

// Passes the address(0) probe but reverts for any real address.
// Models an oracle that is callable but broken for non-zero inputs.
contract SelectiveRevertingOracle {
    function isSanctioned(address addr) external pure returns (bool) {
        if (addr == address(0)) return false;
        revert("reverts on real addresses");
    }
}

contract MalformedReturnOracle {
    function isSanctioned(address) external pure returns (bytes32) {
        return bytes32(uint256(2)); // non-canonical bool word
    }
}

contract GasGriefingOracle {
    /// Gas this oracle keeps back so it can still ABI-encode and return its
    /// bool after burning everything else.
    ///
    /// This reserve must exceed the cost of the callee's own return epilogue,
    /// which is COMPILER-DEPENDENT. The original value was 100, which is just
    /// barely enough under `via_ir` + optimizer but not under
    /// `forge coverage --ir-minimum`, whose unoptimised IR needs ~450. Under
    /// --ir-minimum the griefer therefore ran out of gas mid-return, the
    /// `setForwardingOracle` probe saw `ok == false`, and installing this
    /// oracle reverted `InvalidForwardingOracle` before the test could measure
    /// anything. 5_000 is ~10x the measured worst case, so the double behaves
    /// identically under every optimiser setting.
    ///
    /// This does not soften the test. The oracle is handed FORWARDING_GAS =
    /// 40_000 by the staticcall, so it still burns ~35_000 — the entire
    /// forwarded budget bar the reserve — and the assertion below is unchanged.
    uint256 constant RETURN_RESERVE = 5_000;

    function isSanctioned(address) external view returns (bool) {
        // Attempt to burn all gas via an infinite-ish loop
        uint256 i;
        while (gasleft() > RETURN_RESERVE) { unchecked { i++; } }
        return false;
    }
}

/// Reads back through whoever called it — the shape that closes a cycle without any
/// mirror-specific knowledge. Used for the audit FIND-019 constructor test.
contract CallerBackReferenceOracle {
    function isSanctioned(address addr) external view returns (bool) {
        return ISanctionsList(msg.sender).isSanctioned(addr);
    }
}

/// Per-address routing: answers `false` for an explicit set of addresses and forwards
/// everything else back to its caller. The shape that defeats a one-question probe.
contract SelectiveRouter {
    mapping(address => bool) private _short;

    function shortCircuit(address addr) external { _short[addr] = true; }

    function isSanctioned(address addr) external view returns (bool) {
        if (_short[addr]) return false;
        return ISanctionsList(msg.sender).isSanctioned(addr);
    }
}

