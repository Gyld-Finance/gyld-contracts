// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";

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
    /// The final assertion pins the END of the struct: `GyldBondTokenStorage` has exactly
    /// three fields, so offset 3 must be untouched. A future field MUST be APPENDED at
    /// offset 3 (never inserted) — doing so is expected to fail this assertion, which is
    /// the intended prompt to extend the pins below rather than a reason to delete them.
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

        // Nothing is written past the struct's three fields.
        assertEq(uint256(vm.load(address(token), bytes32(uint256(root) + 3))), 0, "wrote past offset 2");
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

    /// Property B: BURNER_ROLE can burn from any address without that address's allowance.
    /// This is intentional: forced redemption is a compliance requirement for regulated bonds.
    function test_burn_burnerRole_fromArbitraryAddress_noAllowanceNeeded() public {
        // Mint tokens to ap.
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        // ap has NOT approved directBurner — zero allowance.
        address directBurner = address(0xB1);

        // Cache role bytes before pranking — prank is consumed by the first external call,
        // so calling token.BURNER_ROLE() inside vm.prank would consume the prank on the getter.
        bytes32 burnerRole = token.BURNER_ROLE();
        vm.prank(admin); token.grantRole(burnerRole, directBurner);
        assertEq(token.allowance(ap, directBurner), 0, "allowance should be zero");

        // BURNER_ROLE burns from ap — no allowance check, no approval needed.
        vm.prank(directBurner);
        token.burn(ap, 500e18);

        assertEq(token.balanceOf(ap), 500e18, "burn amount wrong");
    }

    /// Revoking BURNER_ROLE immediately removes the ability to burn.
    function test_burn_afterRoleRevoked_reverts() public {
        vm.prank(issuer); mgr.subscribe(address(token), ap, 1_000e18);

        address directBurner = address(0xB1);
        bytes32 burnerRole = token.BURNER_ROLE();
        vm.prank(admin); token.grantRole(burnerRole, directBurner);

        // Burn works with the role.
        vm.prank(directBurner); token.burn(ap, 100e18);
        assertEq(token.balanceOf(ap), 900e18);

        // Role is revoked.
        vm.prank(admin); token.revokeRole(burnerRole, directBurner);

        // Burn now reverts.
        vm.prank(directBurner);
        vm.expectRevert();
        token.burn(ap, 100e18);
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

    function test_setSanctionsList_validOracle_succeeds() public {
        MockSanctionsList newOracle = new MockSanctionsList(address(this));
        vm.prank(admin);
        token.setSanctionsList(address(newOracle));
        assertEq(address(token.sanctionsList()), address(newOracle));
    }

    function test_setSanctionsList_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(GyldBondToken.ZeroAddress.selector);
        token.setSanctionsList(address(0));
    }

    function test_setSanctionsList_eoa_reverts() public {
        address eoa = address(0xBEEF);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, eoa));
        token.setSanctionsList(eoa);
    }

    function test_setSanctionsList_wrongContract_reverts() public {
        // A contract that exists but has no isSanctioned() — e.g. a raw ERC1967Proxy with no impl
        address wrongContract = address(new MockWrongContract());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.NotValidSanctionsList.selector, wrongContract));
        token.setSanctionsList(wrongContract);
    }

    function test_setSanctionsList_onlyAdmin_reverts() public {
        MockSanctionsList newOracle = new MockSanctionsList(address(this));
        vm.prank(address(0xDEAD));
        vm.expectRevert();
        token.setSanctionsList(address(newOracle));
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
}

/// @dev A deployed contract with no isSanctioned() function — used to test the probe rejection.
contract MockWrongContract {}
