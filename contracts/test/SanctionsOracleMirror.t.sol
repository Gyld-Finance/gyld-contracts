// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {SanctionsOracleMirror} from "../SanctionsOracleMirror.sol";

contract SanctionsOracleMirrorTest is Test {
    event SanctionedAddressesAdded(address[] addrs);
    event SanctionedAddressesRemoved(address[] addrs);
    event SanctionedAddress(address indexed addr);
    event NonSanctionedAddress(address indexed addr);

    SanctionsOracleMirror oracle;

    address admin   = address(0xA0);
    address updater = address(0xA1);
    address stranger = address(0xFF);
    address newUpdater = address(0xA2);

    address sanctioned1 = address(0xBAD1);
    address sanctioned2 = address(0xBAD2);
    address clean       = address(0x600D);

    function setUp() public {
        oracle = new SanctionsOracleMirror(admin, updater);
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
        new SanctionsOracleMirror(address(0), updater);
    }

    function test_constructor_zeroUpdater_reverts() public {
        vm.expectRevert(SanctionsOracleMirror.ZeroAddress.selector);
        new SanctionsOracleMirror(admin, address(0));
    }

    // ── name ──────────────────────────────────────────────────────────────────

    function test_name_matchesChainanalysis() public view {
        assertEq(oracle.name(), "Chainalysis sanctions oracle");
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

    // ── isSanctionedVerbose ───────────────────────────────────────────────────

    function test_isSanctionedVerbose_emitsSanctionedEvent() public {
        address[] memory addrs = new address[](1);
        addrs[0] = sanctioned1;
        vm.prank(updater); oracle.addToSanctionsList(addrs);

        vm.expectEmit(true, false, false, false, address(oracle));
        emit SanctionedAddress(sanctioned1);
        bool result = oracle.isSanctionedVerbose(sanctioned1);
        assertTrue(result);
    }

    function test_isSanctionedVerbose_emitsNonSanctionedEvent() public {
        vm.expectEmit(true, false, false, false, address(oracle));
        emit NonSanctionedAddress(clean);
        bool result = oracle.isSanctionedVerbose(clean);
        assertFalse(result);
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
}
