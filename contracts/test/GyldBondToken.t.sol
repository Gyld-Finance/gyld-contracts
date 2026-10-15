// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IERC1643} from "../interfaces/IERC1643.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {ISanctionsList} from "../interfaces/ISanctionsList.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

// ── V2 stub for upgrade test ──────────────────────────────────────────────────

/// Minimal V2 implementation — same storage layout as V1, adds version() getter.
/// Used only to verify upgradeToAndCall preserves all existing state.
/// @custom:oz-upgrades-unsafe-allow constructor
contract GyldBondTokenV2 is GyldBondToken {
    function version() external pure returns (uint256) { return 2; }
}

// ── Test contract ─────────────────────────────────────────────────────────────

contract GyldBondTokenTest is Test {

    GyldBondToken     token;
    IssuanceManager   mgr;
    MockSanctionsList mockSanctions;

    address admin    = address(0xA0); // DEFAULT_ADMIN_ROLE on token + mgr
    address operator = address(0xA1); // PAUSER_ROLE on token
    address issuer   = address(0xA2); // SUBSCRIBER_ROLE + REDEEMER_ROLE on mgr
    address ap       = address(0xAB); // Authorised Participant (whitelisted)

    // Known private key — vm.addr(HOLDER_PK) is the corresponding address.
    // Used in the permit test so we can sign an EIP-712 message in-test.
    uint256 constant HOLDER_PK = 0xA11CE;
    address          holderAddr;

    function setUp() public {
        holderAddr    = vm.addr(HOLDER_PK);
        mockSanctions = new MockSanctionsList(address(this));

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

        // ── IssuanceManager proxy ─────────────────────────────────────────────
        IssuanceManager mgrImpl = new IssuanceManager();
        mgr = IssuanceManager(address(new ERC1967Proxy(
            address(mgrImpl),
            abi.encodeCall(IssuanceManager.initialize, (admin, issuer, issuer))
        )));

        // Wire roles: mgr gets MINTER + BURNER on token
        vm.startPrank(admin);
        token.grantRole(token.MINTER_ROLE(), address(mgr));
        token.grantRole(token.BURNER_ROLE(), address(mgr));
        mgr.grantRole(mgr.REGISTRAR_ROLE(),      admin);
        mgr.grantRole(mgr.WHITELIST_ADMIN_ROLE(), admin);
        mgr.registerToken(address(token));
        mgr.addToWhitelist(ap);
        vm.stopPrank();
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 1 — permit() with a valid EIP-712 signature
    // ═════════════════════════════════════════════════════════════════════════

    /// A correctly signed EIP-712 Permit message sets the allowance and consumes the nonce.
    function test_permit_validSignature_setsAllowance() public {
        address spender  = address(0xBEEF);
        uint256 value    = 500e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce    = token.nonces(holderAddr);

        // Build the EIP-712 digest exactly as ERC20Permit does internally.
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            holderAddr,
            spender,
            value,
            nonce,
            deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01",
            token.DOMAIN_SEPARATOR(),
            structHash
        ));

        // Sign with the holder's private key — no wallet, no RPC call needed.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_PK, digest);

        token.permit(holderAddr, spender, value, deadline, v, r, s);

        assertEq(token.allowance(holderAddr, spender), value, "allowance not set");
        assertEq(token.nonces(holderAddr), 1, "nonce not consumed");
    }

    /// A tampered signature (wrong private key) must revert.
    function test_permit_wrongSignature_reverts() public {
        address spender  = address(0xBEEF);
        uint256 value    = 500e18;
        uint256 deadline = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            holderAddr, spender, value, token.nonces(holderAddr), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));

        // Sign with a DIFFERENT key — produces a signature for a different address.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBADBADBAD, digest);

        vm.expectRevert();
        token.permit(holderAddr, spender, value, deadline, v, r, s);
    }

    /// permit() is blocked while the token is paused.
    function test_permit_whenPaused_reverts() public {
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            holderAddr, address(0xBEEF), 500e18, token.nonces(holderAddr), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(HOLDER_PK, digest);

        vm.prank(operator);
        token.pause();

        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.permit(holderAddr, address(0xBEEF), 500e18, deadline, v, r, s);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 2 — subscribe / redeem when the token is paused
    // ═════════════════════════════════════════════════════════════════════════

    /// subscribe() must revert when the token is paused — even with valid SUBSCRIBER_ROLE.
    /// This is the emergency brake: a compromised issuer key cannot mint after ops pauses.
    function test_subscribe_whenPaused_reverts() public {
        vm.prank(operator);
        token.pause();

        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mgr.subscribe(address(token), ap, 100e18);
    }

    /// redeem() must revert when the token is paused — even with valid REDEEMER_ROLE.
    function test_redeem_whenPaused_reverts() public {
        // First get tokens into mgr's custody (normal redemption initiation).
        vm.prank(issuer);
        mgr.subscribe(address(token), ap, 100e18);
        vm.prank(ap);
        token.transfer(address(mgr), 100e18);

        // Now ops pauses the token.
        vm.prank(operator);
        token.pause();

        // Issuer tries to complete the redemption — must revert.
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        mgr.redeem(address(token), ap, 100e18);
    }

    /// subscribe and redeem both resume normally after unpause.
    function test_subscribe_redeem_afterUnpause_succeed() public {
        vm.prank(operator); token.pause();
        vm.prank(operator); token.unpause();

        vm.prank(issuer); mgr.subscribe(address(token), ap, 100e18);
        assertEq(token.balanceOf(ap), 100e18);

        vm.prank(ap); token.transfer(address(mgr), 100e18);
        vm.prank(issuer); mgr.redeem(address(token), ap, 100e18);
        assertEq(token.balanceOf(address(mgr)), 0);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 3 — storage layout compatibility after a UUPS upgrade
    // ═════════════════════════════════════════════════════════════════════════

    /// Pin every field of the ERC-7201 namespaced struct against its raw storage slot.
    ///
    /// This is the test that fails if someone INSERTS or REORDERS a field rather than
    /// appending one. `sanctionsList` / `isin` / `maturityTimestamp` must keep offsets
    /// 0/1/2 forever — every live proxy already has data there, so a reordering silently
    /// reinterprets that storage on the next upgrade.
    ///
    /// The namespace root is DERIVED here from the same expression the contract uses
    /// rather than copy-pasted as a literal, so the test cannot drift from the contract's
    /// declared storage-location namespace while still appearing to pass.
    ///
    /// The final pair of assertions pins the appended IERC-1643 fields: the `documents`
    /// mapping MUST sit at offset 3 and the `docNames` array MUST sit at offset 4 — appended
    /// after the original three fields, never inserted among them. (Offsets 3/4 are
    /// exercised with real data in `test_storageLayout_documentFieldsAppendedAtOffsets3and4`;
    /// here we only confirm the original layout is still untouched.)
    function test_storageLayout_erc7201OffsetsArePinned() public view {
        bytes32 root = keccak256(abi.encode(uint256(keccak256("gyld.GyldBondToken")) - 1))
            & ~bytes32(uint256(0xff));

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
    }

    /// Pins that the IERC-1643 fields were APPENDED at offsets 3 (documents mapping) and 4
    /// (docNames array), verified against raw storage after a real setDocument. The mapping's
    /// first member (uri length) must live at keccak256(name, slot3), the array length at
    /// slot4, and the array's first element at keccak256(slot4). A field INSERTED anywhere
    /// among offsets 0..2 would shift these and break this test.
    function test_storageLayout_documentFieldsAppendedAtOffsets3and4() public {
        bytes32 root = keccak256(abi.encode(uint256(keccak256("gyld.GyldBondToken")) - 1))
            & ~bytes32(uint256(0xff));
        bytes32 slot3 = bytes32(uint256(root) + 3); // documents mapping
        bytes32 slot4 = bytes32(uint256(root) + 4); // docNames array

        bytes32 name = keccak256("prospectus");
        string memory uri = "ipfs://Qm1234567890abcdef/prospectus.pdf";
        bytes32 hash = keccak256("prospectus-pdf");

        // admin in setUp only holds DEFAULT_ADMIN_ROLE — grant DOCUMENT_ROLE, then set a doc.
        bytes32 docRole = token.DOCUMENT_ROLE();
        vm.prank(admin); token.grantRole(docRole, admin);
        vm.prank(admin); token.setDocument(name, uri, hash);

        // documents mapping offset: uri is a LONG string (> 31 bytes), so its length slot
        // at keccak256(name, slot3) holds 2*len+1 (the long-string marker). Proving that
        // slot carries the uri's length confirms the mapping itself sat at offset 3.
        bytes32 docBase = keccak256(abi.encode(name, slot3));
        assertEq(
            uint256(vm.load(address(token), docBase)),
            2 * bytes(uri).length + 1,
            "documents mapping not at offset 3"
        );

        // Document MEMBER order is live storage layout: `documents` is reached through a
        // mapping, and ci/check_storage_layout.py records only the mapping's type LABEL —
        // which is byte-identical however Document's members are ordered. Reordering them
        // in IERC1643.sol therefore passes CI while re-pointing uri/documentHash/lastModified
        // inside every document already stored on a live proxy, so a holder verifying a
        // prospectus would read a timestamp as its hash. These three pins are the only
        // guard against that; do not delete them, and extend them if Document gains a field.
        assertEq(
            vm.load(address(token), bytes32(uint256(docBase) + 1)),
            hash,
            "Document member 1 is not documentHash"
        );
        assertEq(
            uint256(vm.load(address(token), bytes32(uint256(docBase) + 2))),
            block.timestamp,
            "Document member 2 is not lastModified"
        );
        assertEq(
            vm.load(address(token), keccak256(abi.encode(docBase))),
            bytes32(bytes(uri)),
            "long-string uri payload is not at keccak256(docBase)"
        );

        // docNames array offset: length at slot4, first element at keccak256(slot4).
        assertEq(uint256(vm.load(address(token), slot4)), 1, "docNames length not at offset 4");
        assertEq(
            bytes32(vm.load(address(token), keccak256(abi.encode(slot4)))),
            name,
            "docNames[0] not at keccak256(slot4)"
        );
    }

    /// Upgrading to V2 preserves all existing state: balances, ISIN, maturity,
    /// sanctions list pointer. This is the regression net for future upgrades.
    function test_upgrade_preservesAllState() public {
        // Establish state on V1: mint tokens to ap.
        vm.prank(issuer);
        mgr.subscribe(address(token), ap, 1_000e18);

        // Record everything we want to survive the upgrade.
        uint256 balanceBefore       = token.balanceOf(ap);
        uint256 supplyBefore        = token.totalSupply();
        string  memory isinBefore   = token.isin();
        uint256 maturityBefore      = token.maturityTimestamp();
        address sanctionsBefore     = address(token.sanctionsList());

        // Deploy V2 implementation and upgrade the proxy.
        GyldBondTokenV2 v2Impl = new GyldBondTokenV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(v2Impl), "");

        // Cast to V2 — same proxy address, new implementation behind it.
        GyldBondTokenV2 tokenV2 = GyldBondTokenV2(address(token));

        // V2 code is live.
        assertEq(tokenV2.version(), 2, "version() not available post-upgrade");

        // All pre-upgrade state is intact.
        assertEq(token.balanceOf(ap),          balanceBefore,   "ap balance corrupted");
        assertEq(token.totalSupply(),           supplyBefore,    "totalSupply corrupted");
        assertEq(token.isin(),                  isinBefore,      "ISIN corrupted");
        assertEq(token.maturityTimestamp(),     maturityBefore,  "maturity corrupted");
        assertEq(address(token.sanctionsList()), sanctionsBefore, "sanctionsList corrupted");
    }

    /// After upgrading, the token continues to function: transfers, mint, burn all work.
    function test_upgrade_tokenRemainsOperational() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 500e18);

        GyldBondTokenV2 v2Impl = new GyldBondTokenV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(v2Impl), "");

        // Whitelisted AP can transfer post-upgrade.
        address ap2 = address(0xAC);
        vm.prank(admin); mgr.addToWhitelist(ap2);

        vm.prank(ap);
        token.transfer(ap2, 200e18);
        assertEq(token.balanceOf(ap2), 200e18);

        // IssuanceManager can still mint + burn post-upgrade.
        vm.prank(issuer); mgr.subscribe(address(token), ap, 100e18);
        assertEq(token.balanceOf(ap), 400e18); // 500 - 200 transferred + 100 minted

        vm.prank(ap); token.transfer(address(mgr), 100e18);
        vm.prank(issuer); mgr.redeem(address(token), ap, 100e18);
        assertEq(token.balanceOf(address(mgr)), 0);
    }

    /// Only DEFAULT_ADMIN_ROLE can authorize a UUPS upgrade.
    function test_upgrade_nonAdmin_reverts() public {
        GyldBondTokenV2 v2Impl = new GyldBondTokenV2();

        vm.prank(operator); // PAUSER_ROLE only — not DEFAULT_ADMIN
        vm.expectRevert();
        token.upgradeToAndCall(address(v2Impl), "");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 4 — burn() and the allowance pattern
    // ═════════════════════════════════════════════════════════════════════════

    /// Property A: holding an ERC-20 allowance does NOT grant the ability to call burn().
    /// burn() is gated by BURNER_ROLE, not by allowances.
    function test_burn_withAllowance_butNoBurnerRole_reverts() public {
        // Mint tokens to ap.
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        address attacker = address(0xDEAD);

        // ap grants attacker a full allowance — attacker now controls 1000 tokens via approve.
        vm.prank(ap);
        token.approve(attacker, 1_000e18);
        assertEq(token.allowance(ap, attacker), 1_000e18, "allowance not set");

        // Attacker tries to call burn() directly. Has allowance, does NOT have BURNER_ROLE.
        // Must revert — an allowance alone is not enough to destroy tokens.
        vm.prank(attacker);
        vm.expectRevert();
        token.burn(ap, 500e18);

        // ap's balance is unchanged — allowance did not enable burn.
        assertEq(token.balanceOf(ap), 1_000e18, "tokens were burned despite no BURNER_ROLE");
    }

    /// Property B: BURNER_ROLE is NOT a clawback — `burn` requires `from == msg.sender`
    /// (audit FIND-027). This asserted the opposite until the Information Memorandum
    /// settled it: forced redemption is a capability the contract must NOT have.
    function test_burn_burnerRole_cannotReachAnotherHoldersBalance() public {
        // Mint tokens to ap.
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        address directBurner = address(0xB1);

        // Cache role bytes before pranking — prank is consumed by the first external call,
        // so calling token.BURNER_ROLE() inside vm.prank would consume the prank on the getter.
        bytes32 burnerRole = token.BURNER_ROLE();
        vm.prank(admin); token.grantRole(burnerRole, directBurner);

        // The role alone does not reach ap's balance.
        vm.prank(directBurner);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.CannotBurnFromOtherAccount.selector, ap));
        token.burn(ap, 500e18);

        // Nor the role PLUS a full allowance — `burn` never consults allowances.
        vm.prank(ap); token.approve(directBurner, type(uint256).max);
        vm.prank(directBurner);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.CannotBurnFromOtherAccount.selector, ap));
        token.burn(ap, 500e18);

        assertEq(token.balanceOf(ap), 1_000e18, "a holder's balance was destroyed by BURNER_ROLE");
    }

    /// The other half: a BURNER_ROLE holder CAN destroy what it owns — the redemption path.
    function test_burn_burnerRole_burnsItsOwnBalance() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        address directBurner = address(0xB1);
        bytes32 burnerRole = token.BURNER_ROLE();
        vm.prank(admin); token.grantRole(burnerRole, directBurner);

        vm.prank(ap); token.transfer(directBurner, 500e18);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(directBurner); token.burn(directBurner, 500e18);

        assertEq(token.balanceOf(directBurner), 0,                  "burner kept units it destroyed");
        assertEq(token.balanceOf(ap),           500e18,             "ap balance wrong");
        assertEq(token.totalSupply(),           supplyBefore - 500e18, "supply not reduced");
    }

    /// Revoking BURNER_ROLE immediately removes the ability to burn.
    function test_burn_afterRoleRevoked_reverts() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        address directBurner = address(0xB1);
        bytes32 burnerRole = token.BURNER_ROLE();
        vm.prank(admin); token.grantRole(burnerRole, directBurner);

        // Position the units on the burner — it can only destroy its own balance.
        vm.prank(ap); token.transfer(directBurner, 200e18);

        // Burn works with the role.
        vm.prank(directBurner); token.burn(directBurner, 100e18);
        assertEq(token.balanceOf(directBurner), 100e18);

        // Role is revoked.
        vm.prank(admin); token.revokeRole(burnerRole, directBurner);

        // Burn now reverts.
        vm.prank(directBurner);
        vm.expectRevert();
        token.burn(directBurner, 100e18);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // audit FIND-027 — supply destruction cannot reach a balance it does not own
    // ═════════════════════════════════════════════════════════════════════════

    /// TEST-78. `burn` moved a balance unscreened; the fix removes the capability rather
    /// than screening it, so no unscreened third-party destruction is left to screen.
    function test_burn_fromAnotherAccount_reverts_FIND027() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        // The production burner — the only address holding the role today.
        vm.prank(address(mgr));
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.CannotBurnFromOtherAccount.selector, ap));
        token.burn(ap, 1e18);

        assertEq(token.balanceOf(ap), 1_000e18, "IssuanceManager reached a holder's balance");
    }

    /// The escalation the finding is really about: admin can grant itself BURNER_ROLE and
    /// still cannot touch a holder. Only a proxy upgrade could change that.
    function test_burn_adminSelfGrantingBurnerRole_stillCannotClawBack() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        bytes32 burnerRole = token.BURNER_ROLE();
        vm.prank(admin); token.grantRole(burnerRole, admin);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.CannotBurnFromOtherAccount.selector, ap));
        token.burn(ap, 1_000e18);

        assertEq(token.balanceOf(ap), 1_000e18, "admin clawed back a holder's balance");
    }

    /// A sanctioned holder is frozen, not expropriated — `_update` blocks its transfers and
    /// `burn` cannot destroy it. Any future seizure power needs its own role, not this one.
    function test_burn_sanctionedHolder_balanceCannotBeDestroyed() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        address[] memory addrs = new address[](1);
        addrs[0] = ap;
        mockSanctions.addToSanctionsList(addrs);

        vm.prank(address(mgr));
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.CannotBurnFromOtherAccount.selector, ap));
        token.burn(ap, 1_000e18);

        assertEq(token.balanceOf(ap), 1_000e18, "sanctioned balance was destroyed, not frozen");
    }

    /// No screening crept in by the back door: a self-burn succeeds while the caller is
    /// listed. D-38 liveness — IssuanceManager's own position must never be stranded.
    function test_burn_selfBurn_succeedsWhileCallerIsSanctioned() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);
        vm.prank(ap); token.transfer(address(mgr), 400e18);

        address[] memory addrs = new address[](1);
        addrs[0] = address(mgr);
        mockSanctions.addToSanctionsList(addrs);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(address(mgr)); token.burn(address(mgr), 400e18);

        assertEq(token.balanceOf(address(mgr)), 0, "self-burn blocked by the caller's own listing");
        assertEq(token.totalSupply(), supplyBefore - 400e18, "supply not reduced");
    }

    /// The zero-address guard still fires first, so `burn(0, x)` keeps its existing error.
    function test_burn_zeroAddress_stillReportsZeroAddress() public {
        vm.prank(address(mgr));
        vm.expectRevert(GyldBondToken.ZeroAddress.selector);
        token.burn(address(0), 1e18);
    }

    // ── initialize sanctions oracle probe (M-04) ──────────────────────────────

    function test_initialize_eoa_sanctionsList_reverts() public {
        GyldBondToken impl = new GyldBondToken();
        address eoa = address(0xEEEE);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, eoa));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Test Bond", "TST", "XX0000000001", 0,
                address(0xAD), address(0xAD), eoa
            ))
        );
    }

    function test_initialize_wrongContract_sanctionsList_reverts() public {
        GyldBondToken impl = new GyldBondToken();
        address wrongContract = address(new MockWrongContract());
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, wrongContract));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Test Bond", "TST", "XX0000000001", 0,
                address(0xAD), address(0xAD), wrongContract
            ))
        );
    }

    // ── setSanctionsList probe ────────────────────────────────────────────────

    /// Stand-in for an address on the CURRENT SDN list, supplied by the proposer.
    address constant SDN_FLAGGED = address(0x5D17);

    function test_setSanctionsList_validOracle_succeeds() public {
        MockSanctionsList newOracle = new MockSanctionsList(address(this));
        newOracle.setSanctioned(SDN_FLAGGED, true);
        vm.prank(admin);
        token.setSanctionsList(address(newOracle), SDN_FLAGGED);
        assertEq(address(token.sanctionsList()), address(newOracle));
    }

    function test_setSanctionsList_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(GyldBondToken.ZeroAddress.selector);
        token.setSanctionsList(address(0), SDN_FLAGGED);
    }

    function test_setSanctionsList_eoa_reverts() public {
        address eoa = address(0xBEEF);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, eoa));
        token.setSanctionsList(eoa, SDN_FLAGGED);
    }

    function test_setSanctionsList_wrongContract_reverts() public {
        // A contract that exists but has no isSanctioned() — e.g. a raw ERC1967Proxy with no impl
        address wrongContract = address(new MockWrongContract());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, wrongContract));
        token.setSanctionsList(wrongContract, SDN_FLAGGED);
    }

    /// The oracle is VALID here, so the role check is the only thing that can revert — a
    /// bad oracle would satisfy a bare expectRevert() and hide a missing onlyRole.
    function test_setSanctionsList_onlyAdmin_reverts() public {
        MockSanctionsList newOracle = new MockSanctionsList(address(this));
        newOracle.setSanctioned(SDN_FLAGGED, true);
        vm.prank(address(0xDEAD));
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, address(0xDEAD), bytes32(0)
            )
        );
        token.setSanctionsList(address(newOracle), SDN_FLAGGED);
    }

    // ── Sanctions-oracle admission: interface check (audit FIND-008) ─────────
    //
    // The probe used to check only that the reply was 32 bytes long. It now also requires
    // a contract, and a canonical `false` — the same terms `_requireAccess` decodes on,
    // since that is a HIGH-LEVEL call and solc's ABI bool validator reverts with no reason
    // data on any word above 1. A length-only probe admitted such an oracle and then
    // reverted EVERY transfer of the series.
    //
    // The `address(0)` probe proves the oracle ANSWERS. Since FIND-008 was reopened, a
    // rotation also proves it SCREENS: the candidate must flag a proposer-supplied SDN
    // address, which is what refuses the two oracles that used to be accepted limits.

    function test_setSanctionsList_nonCanonicalBool_reverts() public {
        address bad = address(new NonCanonicalSanctionsList());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, bad));
        token.setSanctionsList(bad, SDN_FLAGGED);
    }

    function test_initialize_nonCanonicalBool_sanctionsList_reverts() public {
        GyldBondToken impl = new GyldBondToken();
        address bad = address(new NonCanonicalSanctionsList());
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, bad));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Test Bond", "TST", "XX0000000001", 0,
                address(0xAD), address(0xAD), bad
            ))
        );
    }

    /// The always-`true` oracle from the finding. `address(0)` is the canonical clean
    /// address — `SanctionsOracleMirror.addToSanctionsList` cannot even hold it — so an
    /// oracle flagging it flags everything. Caught with no fixture and nothing to go stale.
    function test_setSanctionsList_alwaysTrueOracle_reverts() public {
        address bad = address(new AlwaysTrueSanctionsList());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, bad));
        token.setSanctionsList(bad, SDN_FLAGGED);
    }

    /// An oracle that reverts the read is refused, not stored.
    function test_setSanctionsList_revertingOracle_reverts() public {
        address bad = address(new RevertingSanctionsList());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, bad));
        token.setSanctionsList(bad, SDN_FLAGGED);
        assertEq(address(token.sanctionsList()), address(mockSanctions), "must keep the working oracle");
    }

    /// Returndata shorter than a word is refused.
    function test_setSanctionsList_shortReturnData_reverts() public {
        address bad = address(new ShortReturnSanctionsList());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, bad));
        token.setSanctionsList(bad, SDN_FLAGGED);
    }

    /// The case Halborn reopened FIND-008 on. An oracle wired to `false` answers `address(0)`
    /// exactly as a healthy one does, so the interface probe admits it and screening is
    /// silently off. It cannot flag the supplied SDN address, so the rotation is refused and
    /// the working oracle stays.
    function test_setSanctionsList_alwaysFalseOracle_isRejected() public {
        address blind = address(new AlwaysFalseSanctionsList());
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(GyldBondToken.SanctionsOracleMissesFlagged.selector, blind, SDN_FLAGGED)
        );
        token.setSanctionsList(blind, SDN_FLAGGED);
        assertEq(address(token.sanctionsList()), address(mockSanctions), "must keep the working oracle");
    }

    /// The second former accepted limit: canonical for `address(0)`, garbage (a word of 2)
    /// for everyone else, which would revert every transfer. Its garbage answer for the
    /// caller is not a canonical `false`, so the clean-caller probe refuses it first.
    function test_setSanctionsList_canonicalOnlyForZero_isRejected() public {
        address dirty = address(new DirtyForNonZeroSanctionsList());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, dirty));
        token.setSanctionsList(dirty, SDN_FLAGGED);
    }

    /// A healthy, correctly built oracle that simply is not seeded with the supplied address
    /// — an unseeded mirror, or an address delisted inside the 48 h timelock window. Refused
    /// loudly; the current oracle stays in place, and the proposal is re-made.
    function test_setSanctionsList_unseededOracle_isRejected() public {
        MockSanctionsList unseeded = new MockSanctionsList(address(this));
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                GyldBondToken.SanctionsOracleMissesFlagged.selector, address(unseeded), SDN_FLAGGED
            )
        );
        token.setSanctionsList(address(unseeded), SDN_FLAGGED);
        assertEq(address(token.sanctionsList()), address(mockSanctions), "must keep the working oracle");
    }

    /// A zero `knownFlagged` would fail the flagged probe anyway; naming it is clearer.
    function test_setSanctionsList_zeroKnownFlagged_reverts() public {
        MockSanctionsList newOracle = new MockSanctionsList(address(this));
        vm.prank(admin);
        vm.expectRevert(GyldBondToken.ZeroAddress.selector);
        token.setSanctionsList(address(newOracle), address(0));
    }

    /// "Wired to true" in the shape the `address(0)` probe misses: it clears only zero and
    /// flags everyone else, so every transfer would revert. It flags the caller — the
    /// timelock — so the clean-caller probe refuses it.
    function test_setSanctionsList_flagsAllButZeroOracle_isRejected() public {
        address bad = address(new FlagsAllButZeroSanctionsList());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, bad));
        token.setSanctionsList(bad, SDN_FLAGGED);
    }

    /// ACCEPTED LIMIT, pinned so it is not mistaken for coverage. An oracle that flags only
    /// the one address it is probed with passes: any fixed probe can be gamed by an oracle
    /// that chooses its answer per address. The threat here is governance error behind a
    /// 48 h timelock, not an adversarial oracle — and whoever holds DEFAULT_ADMIN_ROLE can
    /// upgrade this token outright, which is strictly worse. D-33.
    function test_setSanctionsList_singleAddressOracle_isAdmitted_acceptedLimit() public {
        address narrow = address(new FlagsOnlySanctionsList(SDN_FLAGGED));
        vm.prank(admin);
        token.setSanctionsList(narrow, SDN_FLAGGED);
        assertEq(address(token.sanctionsList()), narrow);
    }

    // ── Fail-closed on an unset sanctions list (audit §4.1) ───────────────────
    //
    // `_requireAccess` used to read
    //     if (address(sl) != address(0) && sl.isSanctioned(account)) revert ...
    // whose `&&` short-circuits: a zero `sanctionsList` skipped screening entirely
    // and every transfer succeeded unscreened. That is fail-OPEN on the compliance
    // path. It was unreachable — `initialize` and `setSanctionsList` both reject
    // zero (pinned by test_initialize_zeroSanctionsList_reverts and
    // test_setSanctionsList_zeroAddress_reverts) — but the guard depended on an
    // invariant maintained by hand in two places, so a third writer that forgot
    // its zero-check would have silently disabled screening rather than failing.
    //
    // The zero state therefore cannot be reached through the public API, and these
    // tests write the slot directly. That is the point: they pin what happens in a
    // state only a future bug can produce.

    /// Zeroing `sanctionsList` makes secondary transfers revert `SanctionsListNotSet`
    /// rather than sail through unscreened.
    function test_transfer_unsetSanctionsList_revertsFailClosed() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 100e18);

        _zeroSanctionsListSlot();
        assertEq(address(token.sanctionsList()), address(0), "precondition: list is unset");

        vm.prank(ap);
        vm.expectRevert(GyldBondToken.SanctionsListNotSet.selector);
        token.transfer(address(0xB0B), 1e18);
    }

    /// The spender leg (`_requireAccess(_msgSender())` in `transferFrom`) fails closed too.
    function test_transferFrom_unsetSanctionsList_revertsFailClosed() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 100e18);
        vm.prank(ap); token.approve(address(this), 1e18);

        _zeroSanctionsListSlot();

        vm.expectRevert(GyldBondToken.SanctionsListNotSet.selector);
        token.transferFrom(ap, address(0xB0B), 1e18);
    }

    /// Mint and burn deliberately skip `_requireAccess` (IssuanceManager pre-screens APs
    /// off-chain), so an unset list must NOT brick primary issuance. Pins that the new
    /// guard did not widen its blast radius beyond the secondary path.
    function test_mintBurn_unsetSanctionsList_stillWork() public {
        // Position the tokens while the list is still set — `redeem` burns from the
        // manager's own balance, so getting them there is a secondary transfer and
        // would (correctly) fail closed after the slot is zeroed.
        vm.prank(issuer); mgr.subscribe(address(token), ap, 100e18);
        vm.prank(ap);     token.transfer(address(mgr), 40e18);

        _zeroSanctionsListSlot();

        vm.prank(issuer); mgr.subscribe(address(token), ap, 10e18);
        assertEq(token.balanceOf(ap), 70e18, "mint must survive an unset list");

        vm.prank(issuer); mgr.redeem(address(token), ap, 40e18);
        assertEq(token.balanceOf(address(mgr)), 0, "burn must survive an unset list");
    }

    /// A configured list still produces `AccountSanctioned`, not the new error — the
    /// two failure modes stay distinguishable to an integrator.
    function test_transfer_sanctionedAccount_stillRevertsAccountSanctioned() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 100e18);
        mockSanctions.setSanctioned(address(0xB0B), true);

        vm.prank(ap);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.AccountSanctioned.selector, address(0xB0B)));
        token.transfer(address(0xB0B), 1e18);
    }

    /// Force `sanctionsList` to zero. The ERC-7201 root is re-derived from the namespace
    /// string rather than hard-coded, so this cannot drift from the contract; `sanctionsList`
    /// is offset 0 and sole occupant of that word, so zeroing the whole slot is exact.
    /// Same derivation as test_storageLayout_erc7201OffsetsArePinned.
    function _zeroSanctionsListSlot() internal {
        bytes32 root = keccak256(abi.encode(uint256(keccak256("gyld.GyldBondToken")) - 1))
            & ~bytes32(uint256(0xff));
        vm.store(address(token), root, bytes32(0));
    }

    // ── renounceRole guard ────────────────────────────────────────────────────

    function test_renounceRole_defaultAdmin_reverts() public {
        // Cache role bytes before pranking — getter call would consume the prank/expectRevert.
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(GyldBondToken.CannotRenounceAdminRole.selector);
        token.renounceRole(adminRole, admin);
    }

    function test_renounceRole_nonAdminRole_succeeds() public {
        address pauser2 = address(0xCC);
        bytes32 pauserRole = token.PAUSER_ROLE();
        vm.prank(admin); token.grantRole(pauserRole, pauser2);
        assertTrue(token.hasRole(pauserRole, pauser2));

        vm.prank(pauser2);
        token.renounceRole(pauserRole, pauser2);
        assertFalse(token.hasRole(pauserRole, pauser2));
    }


    // ── revokeRole last-admin guard (audit FIND-007 / TEST-59) ────────────────

    /// TEST-59. renounceRole was guarded, revokeRole was not, and DEFAULT_ADMIN_ROLE admins
    /// itself — so the sole holder could self-revoke into the same bricked state.
    function test_revokeRole_lastAdmin_reverts() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE(); // cache: the getter would eat the prank
        assertEq(token.defaultAdminCount(), 1);
        vm.prank(admin);
        vm.expectRevert(GyldBondToken.CannotRemoveLastAdmin.selector);
        token.revokeRole(adminRole, admin);
        assertTrue(token.hasRole(adminRole, admin));
    }

    /// The handover every deploy script performs — grant successor, then self-revoke.
    function test_revokeRole_nonLastAdmin_succeeds() public {
        bytes32 adminRole = token.DEFAULT_ADMIN_ROLE();
        address timelock = address(0xADAD);
        vm.prank(admin); token.grantRole(adminRole, timelock);
        vm.prank(admin); token.revokeRole(adminRole, admin);
        assertFalse(token.hasRole(adminRole, admin));
        vm.prank(timelock);
        vm.expectRevert(GyldBondToken.CannotRemoveLastAdmin.selector);
        token.revokeRole(adminRole, timelock);
    }

    // ── decimals() is a cross-contract invariant ──────────────────────────────

    /// GyldAtomicSwap prices every quote with a hard-coded divisor:
    ///     navValue = tokenAmount * nav / 1e20,   20 = 18 (bond) + 8 (NAV) - 6 (cash)
    /// so 18 decimals here is not cosmetic — it is an input to someone else's arithmetic.
    /// A series reporting 7..17 decimals silently UNDER-prices (a 12dp token makes navValue
    /// 10^6 too small, letting a taker pay ~$0.001 for ~$1,000 of bonds); <=6 truncates
    /// navValue to zero and bricks the series.
    ///
    /// registerSeries staticcall-probes for exactly 18, but only ONCE at registration — an
    /// implementation upgrade adding a `decimals()` override would bypass that probe for
    /// every series already registered, and nothing on-chain would notice. This test is
    /// that missing tripwire: it fails in CI before such an override could ship.
    /// If a series ever genuinely needs different precision, change the swap's scaling to a
    /// per-series factor FIRST, then this test.
    function test_decimals_is18_swapBandDependsOnIt() public view {
        assertEq(token.decimals(), 18, "GyldAtomicSwap's /1e20 band divisor assumes 18 decimals");
    }

    /// The same invariant, stated the way it can actually break: `decimals()` is inherited
    /// from ERC20Upgradeable as a hard-coded `return 18` with no storage behind it, so it
    /// cannot drift at runtime — only a new implementation can change it. Prove an upgrade
    /// that does NOT touch decimals leaves it intact, so this test isolates the override
    /// case rather than incidentally passing because nothing was upgraded.
    function test_decimals_survivesUpgrade() public {
        assertEq(token.decimals(), 18);

        GyldBondTokenV2 v2 = new GyldBondTokenV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(v2), "");

        assertEq(GyldBondTokenV2(address(token)).version(), 2, "precondition: the upgrade landed");
        assertEq(token.decimals(), 18, "decimals must not move across an upgrade");
    }

    // ═════════════════════════════════════════════════════════════════════════
    // Gap 5 — IERC-1643 document management
    // ═════════════════════════════════════════════════════════════════════════

    bytes32 constant DOC_NAME   = keccak256("prospectus");
    string  constant DOC_URI    = "ipfs://Qm1234567890abcdef/prospectus.pdf";
    bytes32 constant DOC_HASH   = keccak256("prospectus-pdf");
    bytes32 constant DOC_NAME2  = keccak256("supplement-1");

    /// Helper: grant `caller` DOCUMENT_ROLE. In setUp only admin holds DEFAULT_ADMIN_ROLE,
    /// so grants are always made as admin. Returns the DOCUMENT_ROLE id to reuse.
    function _grantDocumentRole(address caller) internal returns (bytes32) {
        bytes32 docRole = token.DOCUMENT_ROLE();
        vm.prank(admin); token.grantRole(docRole, caller);
        return docRole;
    }

    /// setDocument stores uri + hash, fires DocumentUpdated, and getDocument reads it back.
    function test_setDocument_addsDocument() public {
        _grantDocumentRole(operator);

        bytes32 name = DOC_NAME;
        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC1643.DocumentUpdated(name, DOC_URI, DOC_HASH);
        token.setDocument(name, DOC_URI, DOC_HASH);

        (string memory uri, bytes32 hash, uint256 lastModified) = token.getDocument(name);
        assertEq(uri, DOC_URI, "uri mismatch");
        assertEq(hash, DOC_HASH, "documentHash mismatch");
        assertEq(lastModified, block.timestamp, "lastModified should be block.timestamp");

        bytes32[] memory names = token.getAllDocuments();
        assertEq(names.length, 1, "getAllDocuments length");
        assertEq(names[0], name, "getAllDocuments[0]");
    }

    /// Replacing an existing document updates in place and does NOT duplicate the array entry.
    function test_setDocument_replacesWithoutDuplicating() public {
        _grantDocumentRole(operator);

        bytes32 name = DOC_NAME;
        vm.prank(operator); token.setDocument(name, DOC_URI, DOC_HASH);

        string memory newUri = "ipfs://Qm9999999999999999/prospectus-v2.pdf";
        bytes32 newHash = keccak256("prospectus-pdf-v2");
        vm.prank(operator); token.setDocument(name, newUri, newHash);

        (string memory uri, bytes32 hash, ) = token.getDocument(name);
        assertEq(uri, newUri, "uri not replaced");
        assertEq(hash, newHash, "hash not replaced");

        bytes32[] memory names = token.getAllDocuments();
        assertEq(names.length, 1, "replacing a doc must not grow the array");
        assertEq(names[0], name);
    }

    /// Multiple documents are all enumerated by getAllDocuments.
    function test_setDocument_multipleDocsEnumerated() public {
        _grantDocumentRole(operator);

        vm.prank(operator); token.setDocument(DOC_NAME, DOC_URI, DOC_HASH);
        vm.prank(operator); token.setDocument(DOC_NAME2, "ipfs://Qm.../supplement-1.pdf", keccak256("supp-1"));

        bytes32[] memory names = token.getAllDocuments();
        assertEq(names.length, 2, "two docs expected");
        assertTrue(names[0] == DOC_NAME || names[1] == DOC_NAME, "DOC_NAME present");
        assertTrue(names[0] == DOC_NAME2 || names[1] == DOC_NAME2, "DOC_NAME2 present");
    }

    /// setDocument is gated by DOCUMENT_ROLE — a caller without it reverts.
    function test_setDocument_nonDocumentRole_reverts() public {
        vm.prank(operator); // PAUSER_ROLE only
        vm.expectRevert();
        token.setDocument(DOC_NAME, DOC_URI, DOC_HASH);
    }

    /// bytes32(0) is the default value of an unset name, so an empty name is the single
    /// most likely miscall — and it would otherwise be pushed into docNames and returned
    /// by getAllDocuments() as an entry no client can decode. Matches CMTAT's
    /// ERC1643InvalidName. Specified in the GLD-264 plan; shipped without it.
    function test_setDocument_zeroName_reverts() public {
        _grantDocumentRole(operator);
        vm.prank(operator);
        vm.expectRevert(GyldBondToken.EmptyDocumentName.selector);
        token.setDocument(bytes32(0), DOC_URI, DOC_HASH);
    }

    /// The zero-name check must reject before the uri/hash checks, so a call that is wrong
    /// in more than one way still reports the name first — and so the check cannot be
    /// bypassed by also passing an empty uri.
    function test_setDocument_zeroName_takesPrecedenceOverEmptyUri() public {
        _grantDocumentRole(operator);
        vm.prank(operator);
        vm.expectRevert(GyldBondToken.EmptyDocumentName.selector);
        token.setDocument(bytes32(0), "", bytes32(0));
    }

    /// A rejected write must leave no trace: no docNames entry, nothing enumerable.
    function test_setDocument_zeroName_doesNotGrowDocNames() public {
        _grantDocumentRole(operator);
        vm.prank(operator);
        vm.expectRevert(GyldBondToken.EmptyDocumentName.selector);
        token.setDocument(bytes32(0), DOC_URI, DOC_HASH);
        assertEq(token.getAllDocuments().length, 0, "rejected write must not enumerate");
    }

    function test_setDocument_emptyUri_reverts() public {
        _grantDocumentRole(operator);
        vm.prank(operator);
        vm.expectRevert(GyldBondToken.EmptyDocumentUri.selector);
        token.setDocument(DOC_NAME, "", DOC_HASH);
    }

    function test_setDocument_zeroHash_reverts() public {
        _grantDocumentRole(operator);
        vm.prank(operator);
        vm.expectRevert(GyldBondToken.EmptyDocumentHash.selector);
        token.setDocument(DOC_NAME, DOC_URI, bytes32(0));
    }

    /// removeDocument clears the doc, fires DocumentRemoved, and drops it from getAllDocuments.
    function test_removeDocument_removesDocument() public {
        _grantDocumentRole(operator);

        bytes32 name = DOC_NAME;
        vm.prank(operator); token.setDocument(name, DOC_URI, DOC_HASH);

        vm.prank(operator);
        vm.expectEmit(true, false, false, true, address(token));
        emit IERC1643.DocumentRemoved(name, DOC_URI, DOC_HASH);
        token.removeDocument(name);

        // getDocument now returns empty values (CMTAT parity) — asserting the cleared
        // struct directly proves removal wiped it, which the old revert only implied.
        (string memory uriAfter, bytes32 hashAfter, uint256 modifiedAfter) = token.getDocument(name);
        assertEq(bytes(uriAfter).length, 0, "uri not cleared");
        assertEq(hashAfter, bytes32(0), "hash not cleared");
        assertEq(modifiedAfter, 0, "lastModified not cleared");

        assertEq(token.getAllDocuments().length, 0, "docNames not emptied");
    }

    function test_removeDocument_nonexistent_reverts() public {
        _grantDocumentRole(operator);
        bytes32 name = DOC_NAME;
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.DocumentDoesNotExist.selector, name));
        token.removeDocument(name);
    }

    function test_removeDocument_nonDocumentRole_reverts() public {
        _grantDocumentRole(operator);
        vm.prank(operator); token.setDocument(DOC_NAME, DOC_URI, DOC_HASH);

        vm.prank(issuer); // no role
        vm.expectRevert();
        token.removeDocument(DOC_NAME);
    }

    function test_removeDocument_keepsOtherDocs() public {
        _grantDocumentRole(operator);

        vm.prank(operator); token.setDocument(DOC_NAME, DOC_URI, DOC_HASH);
        vm.prank(operator); token.setDocument(DOC_NAME2, "ipfs://Qm.../supplement-1.pdf", keccak256("supp-1"));

        vm.prank(operator); token.removeDocument(DOC_NAME);

        bytes32[] memory names = token.getAllDocuments();
        assertEq(names.length, 1, "the other doc should remain");
        assertEq(names[0], DOC_NAME2);
    }

    /// getDocument on a name that was never set returns empty values and does NOT revert,
    /// matching CMTAT and the ERC-1643 reference. A reverting view poisons batched reads:
    /// one absent name would fail a whole Multicall3 aggregate. Unambiguous because
    /// _setDocument rejects an empty uri, so a stored document always has one.
    function test_getDocument_nonexistent_returnsEmptyValues() public view {
        (string memory uri, bytes32 hash, uint256 lastModified) = token.getDocument(DOC_NAME);
        assertEq(bytes(uri).length, 0, "uri must be empty");
        assertEq(hash, bytes32(0), "hash must be zero");
        assertEq(lastModified, 0, "lastModified must be zero");
    }

    /// The batched-read case this change exists for: several names read in one call, one
    /// of them absent. Under the old reverting getDocument this whole read failed.
    function test_getDocument_batchedReadSurvivesOneAbsentName() public {
        _grantDocumentRole(operator);
        vm.prank(operator); token.setDocument(DOC_NAME, DOC_URI, DOC_HASH);

        (string memory presentUri,,) = token.getDocument(DOC_NAME);
        (string memory absentUri,,)  = token.getDocument(DOC_NAME2);

        assertEq(presentUri, DOC_URI, "present document must still read back");
        assertEq(bytes(absentUri).length, 0, "absent document must read empty, not revert");
    }

    /// An empty token enumerates no documents.
    function test_getAllDocuments_empty() public view {
        assertEq(token.getAllDocuments().length, 0, "no docs initially");
    }

    /// Documents survive a UUPS upgrade — the appended layout preserves them across
    /// implementation swaps exactly like the pre-existing state (see test_upgrade_preservesAllState).
    function test_upgrade_preservesDocuments() public {
        _grantDocumentRole(operator);
        vm.prank(operator); token.setDocument(DOC_NAME, DOC_URI, DOC_HASH);

        bytes32[] memory before = token.getAllDocuments();
        assertEq(before.length, 1);

        GyldBondTokenV2 v2Impl = new GyldBondTokenV2();
        vm.prank(admin);
        token.upgradeToAndCall(address(v2Impl), "");
        GyldBondTokenV2 tokenV2 = GyldBondTokenV2(address(token));
        assertEq(tokenV2.version(), 2, "precondition: upgrade landed");

        (string memory uri, bytes32 hash, ) = token.getDocument(DOC_NAME);
        assertEq(uri, DOC_URI, "document uri corrupted across upgrade");
        assertEq(hash, DOC_HASH, "document hash corrupted across upgrade");

        bytes32[] memory afterUpgrade = token.getAllDocuments();
        assertEq(afterUpgrade.length, 1, "doc list corrupted across upgrade");
        assertEq(afterUpgrade[0], DOC_NAME);

        // Document management remains functional post-upgrade (operator holds DOCUMENT_ROLE).
        vm.prank(operator); token.setDocument(DOC_NAME2, "ipfs://Qm.../supplement-1.pdf", keccak256("supp-1"));
        assertEq(token.getAllDocuments().length, 2, "can still add docs post-upgrade");
    }
}

/// @dev A deployed contract with no isSanctioned() function — used to test the probe rejection.
contract MockWrongContract {}


// ── Sanctions-oracle doubles for the admission probe (audit FIND-008) ─────────

/// @dev Reverts on every screen — a broken, paused or self-destructed oracle.
contract RevertingSanctionsList is ISanctionsList {
    error Down();
    function isSanctioned(address) external pure override returns (bool) { revert Down(); }
}

/// @dev Replies with 16 bytes. Written in assembly on purpose: any Solidity return type
///      narrower than a word is still ABI-padded to 32 bytes, so it could not produce this.
contract ShortReturnSanctionsList {
    fallback() external {
        assembly { mstore(0, 1) return(0, 16) }
    }
}

/// @dev Replies with a full word whose value is 2. Length-correct, so the old probe took
///      it; the hot path's ABI bool validator rejects it, so every transfer reverted.
contract NonCanonicalSanctionsList {
    fallback() external {
        assembly { mstore(0, 2) return(0, 32) }
    }
}

/// @dev Flags every address except `address(0)` — "wired to true", past the zero probe.
contract FlagsAllButZeroSanctionsList is ISanctionsList {
    function isSanctioned(address addr) external pure override returns (bool) { return addr != address(0); }
}

/// @dev Flags exactly one address and nothing else — the per-address oracle D-33 names.
contract FlagsOnlySanctionsList is ISanctionsList {
    address public immutable only;
    constructor(address only_) { only = only_; }
    function isSanctioned(address addr) external view override returns (bool) { return addr == only; }
}

/// @dev Canonical for `address(0)` and a non-canonical word (2) for every other address.
///      Passes the `address(0)` probe; refused on rotation by the flagged-address probe.
contract DirtyForNonZeroSanctionsList {
    fallback() external {
        assembly {
            switch calldataload(4)
            case 0 { mstore(0, 0) }
            default { mstore(0, 2) }
            return(0, 32)
        }
    }
}


/// @dev Answers `false` for everything — the silent case. Passes the `address(0)` probe;
///      refused on rotation because it cannot flag the supplied SDN address (FIND-008).
contract AlwaysFalseSanctionsList is ISanctionsList {
    function isSanctioned(address) external pure override returns (bool) { return false; }
}

/// @dev Flags every address, `address(0)` included — the always-`true` case (FIND-008).
contract AlwaysTrueSanctionsList is ISanctionsList {
    function isSanctioned(address) external pure override returns (bool) { return true; }
}
