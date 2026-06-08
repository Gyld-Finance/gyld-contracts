// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SanctionsOracleMirror} from "../SanctionsOracleMirror.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";

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
        MockSanctionsList mock = new MockSanctionsList();
        vm.prank(admin);
        oracle.setForwardingOracle(address(mock));
        assertEq(address(oracle.forwardingOracle()), address(mock));
    }

    function test_setForwardingOracle_strangerReverts() public {
        MockSanctionsList mock = new MockSanctionsList();
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setForwardingOracle(address(mock));
    }

    function test_setForwardingOracle_emitsEvent() public {
        MockSanctionsList mock = new MockSanctionsList();
        vm.expectEmit(true, true, false, false, address(oracle));
        emit ForwardingOracleUpdated(address(0), address(mock));
        vm.prank(admin);
        oracle.setForwardingOracle(address(mock));
    }

    function test_setForwardingOracle_canBeZeroed() public {
        MockSanctionsList mock = new MockSanctionsList();
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
        MockSanctionsList mock = new MockSanctionsList();
        mock.setSanctioned(sanctioned1, true);
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // Forwarding: address only on local list → isSanctioned returns true (no external call)
    function test_isSanctioned_trueFromLocalList() public {
        MockSanctionsList mock = new MockSanctionsList();
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);

        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // Forwarding: address on both lists → still returns true
    function test_isSanctioned_trueFromBothLists() public {
        MockSanctionsList mock = new MockSanctionsList();
        mock.setSanctioned(sanctioned1, true);
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);

        assertTrue(oracle.isSanctioned(sanctioned1));
    }

    // Forwarding: clean address on neither list → false
    function test_isSanctioned_falseOnBothLists() public {
        MockSanctionsList mock = new MockSanctionsList();
        vm.prank(admin); oracle.setForwardingOracle(address(mock));
        assertFalse(oracle.isSanctioned(clean));
    }

    // Remove from local list does NOT clear forwarding oracle flag
    function test_removeFromLocal_doesNotClearForwardingFlag() public {
        MockSanctionsList mock = new MockSanctionsList();
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
        MockSanctionsList mock = new MockSanctionsList();
        mock.setSanctioned(sanctioned1, true);
        vm.prank(admin); oracle.setForwardingOracle(address(mock));

        // Zero out forwarding
        vm.prank(admin); oracle.setForwardingOracle(address(0));
        assertFalse(oracle.isSanctioned(sanctioned1));
    }

    function test_constructor_withForwardingOracle() public {
        MockSanctionsList mock = new MockSanctionsList();
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

    // ── forwarding oracle failure paths ───────────────────────────────────────

    // Forwarding oracle reverts at lookup time → isSanctioned reverts (fail-closed).
    // Uses SelectiveRevertingOracle: passes the address(0) probe but reverts on all
    // other addresses — so it can be set, but real lookups fail.
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
        MockSanctionsList mock = new MockSanctionsList();
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
    }

    // ── fuzz: forwarding-path invariant ──────────────────────────────────────

    function testFuzz_forwardingOrLocalTrue_meansTrue(address addr) public {
        vm.assume(addr != address(0));
        MockSanctionsList mock = new MockSanctionsList();
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
    function isSanctioned(address) external view returns (bool) {
        // Attempt to burn all gas via an infinite-ish loop
        uint256 i;
        while (gasleft() > 100) { unchecked { i++; } }
        return false;
    }
}
