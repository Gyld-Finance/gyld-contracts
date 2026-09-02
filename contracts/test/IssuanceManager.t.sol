// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";

contract IssuanceManagerTest is Test {
    // Mirror events for vm.expectEmit (Solidity 0.8.20 doesn't support ContractName.Event syntax)
    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);
    event TokenRegistered(address indexed token);
    event TokenDeregistered(address indexed token);
    event Subscribed(address indexed token, address indexed recipient, uint256 amount);
    event Redeemed(address indexed token, address indexed beneficiary, uint256 amount);

    IssuanceManager mgr;
    GyldBondToken   token;
    MockSanctionsList mockSanctions;

    address admin          = address(0xA0);
    address subscriber     = address(0xA1); // SUBSCRIBER_ROLE — mint path MPC wallet
    address redeemer       = address(0xA4); // REDEEMER_ROLE   — burn path MPC wallet
    address whitelistAdmin = address(0xA2);
    address registrar      = address(0xA3);
    address ap             = address(0xAB);
    address outsider       = address(0xFF);

    function setUp() public {
        IssuanceManager impl = new IssuanceManager();
        mgr = IssuanceManager(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(IssuanceManager.initialize, (admin, subscriber, redeemer))
        )));

        // Cache role bytes before pranking — prank is consumed by the first external call,
        // which would otherwise be the WHITELIST_ADMIN_ROLE() getter, not grantRole.
        bytes32 whitelistAdminRole = mgr.WHITELIST_ADMIN_ROLE();
        bytes32 registrarRole      = mgr.REGISTRAR_ROLE();
        vm.prank(admin); mgr.grantRole(whitelistAdminRole, whitelistAdmin);
        vm.prank(admin); mgr.grantRole(registrarRole, registrar);

        mockSanctions = new MockSanctionsList(address(this));
        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(address(new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Test Bond", "TBOND", "US000000TEST", 0,
                address(this),
                address(this),
                address(mockSanctions)
            ))
        )));

        token.grantRole(token.MINTER_ROLE(), address(mgr));
        token.grantRole(token.BURNER_ROLE(), address(mgr));

        vm.prank(registrar); mgr.registerToken(address(token));
        vm.prank(whitelistAdmin); mgr.addToWhitelist(ap);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _subscribeAp(uint256 amount) internal {
        vm.prank(subscriber);
        mgr.subscribe(address(token), ap, amount);
    }

    function _apSendsToMgr(uint256 amount) internal {
        // ap transfers tokens to mgr (simulating redemption initiation)
        vm.prank(ap);
        token.transfer(address(mgr), amount);
    }

    // ── Initializer guards ────────────────────────────────────────────────────

    function test_initialize_zeroDefaultAdmin_reverts() public {
        IssuanceManager impl2 = new IssuanceManager();
        vm.expectRevert(IssuanceManager.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl2),
            abi.encodeCall(IssuanceManager.initialize, (address(0), subscriber, redeemer))
        );
    }

    function test_initialize_zeroSubscriber_reverts() public {
        IssuanceManager impl2 = new IssuanceManager();
        vm.expectRevert(IssuanceManager.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl2),
            abi.encodeCall(IssuanceManager.initialize, (admin, address(0), redeemer))
        );
    }

    function test_initialize_zeroRedeemer_reverts() public {
        IssuanceManager impl2 = new IssuanceManager();
        vm.expectRevert(IssuanceManager.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl2),
            abi.encodeCall(IssuanceManager.initialize, (admin, subscriber, address(0)))
        );
    }

    // ── Whitelist management ──────────────────────────────────────────────────

    function test_addToWhitelist_success() public {
        address newAp = address(0xBB);
        vm.prank(whitelistAdmin);
        mgr.addToWhitelist(newAp);
        assertTrue(mgr.whitelisted(newAp));
    }

    function test_addToWhitelist_emitsEvent() public {
        address newAp = address(0xBB);
        vm.expectEmit(true, false, false, false, address(mgr));
        emit AddressWhitelisted(newAp);
        vm.prank(whitelistAdmin);
        mgr.addToWhitelist(newAp);
    }

    function test_addToWhitelist_zeroAddress_reverts() public {
        vm.prank(whitelistAdmin);
        vm.expectRevert(IssuanceManager.ZeroAddress.selector);
        mgr.addToWhitelist(address(0));
    }

    function test_addToWhitelist_onlyWhitelistAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        mgr.addToWhitelist(address(0xBB));
    }

    function test_removeFromWhitelist_success() public {
        vm.prank(whitelistAdmin);
        mgr.removeFromWhitelist(ap);
        assertFalse(mgr.whitelisted(ap));
    }

    function test_removeFromWhitelist_emitsEvent() public {
        vm.expectEmit(true, false, false, false, address(mgr));
        emit AddressRemovedFromWhitelist(ap);
        vm.prank(whitelistAdmin);
        mgr.removeFromWhitelist(ap);
    }

    function test_removeFromWhitelist_onlyWhitelistAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        mgr.removeFromWhitelist(ap);
    }

    function test_removeFromWhitelist_zeroAddress_reverts() public {
        vm.prank(whitelistAdmin);
        vm.expectRevert(IssuanceManager.ZeroAddress.selector);
        mgr.removeFromWhitelist(address(0));
    }

    function test_addToWhitelistBatch_success() public {
        address a1 = address(0x01);
        address a2 = address(0x02);
        address a3 = address(0x03);
        address[] memory batch = new address[](3);
        batch[0] = a1; batch[1] = a2; batch[2] = a3;

        vm.expectEmit(true, false, false, false, address(mgr));
        emit AddressWhitelisted(a1);
        vm.expectEmit(true, false, false, false, address(mgr));
        emit AddressWhitelisted(a2);
        vm.expectEmit(true, false, false, false, address(mgr));
        emit AddressWhitelisted(a3);

        vm.prank(whitelistAdmin);
        mgr.addToWhitelistBatch(batch);

        assertTrue(mgr.whitelisted(a1));
        assertTrue(mgr.whitelisted(a2));
        assertTrue(mgr.whitelisted(a3));
    }

    function test_addToWhitelistBatch_zeroAddress_reverts() public {
        address[] memory batch = new address[](3);
        batch[0] = address(0x01);
        batch[1] = address(0);
        batch[2] = address(0x03);
        vm.prank(whitelistAdmin);
        vm.expectRevert(IssuanceManager.ZeroAddress.selector);
        mgr.addToWhitelistBatch(batch);
    }

    function test_addToWhitelistBatch_emptyArray_succeeds() public {
        address[] memory empty = new address[](0);
        vm.prank(whitelistAdmin);
        mgr.addToWhitelistBatch(empty); // no-op, must not revert
    }

    // ── Token registry ────────────────────────────────────────────────────────

    function test_registerToken_success() public {
        GyldBondToken tokenImpl2 = new GyldBondToken();
        GyldBondToken token2 = GyldBondToken(address(new ERC1967Proxy(
            address(tokenImpl2),
            abi.encodeCall(GyldBondToken.initialize, (
                "Bond 2", "B2", "US000000TST2", 0,
                address(this), address(this), address(mockSanctions)
            ))
        )));

        vm.expectEmit(true, false, false, false, address(mgr));
        emit TokenRegistered(address(token2));

        vm.prank(registrar);
        mgr.registerToken(address(token2));

        assertTrue(mgr.registeredTokens(address(token2)));
    }

    function test_registerToken_zeroAddress_reverts() public {
        vm.prank(registrar);
        vm.expectRevert(IssuanceManager.ZeroAddress.selector);
        mgr.registerToken(address(0));
    }

    function test_registerToken_onlyRegistrar_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        mgr.registerToken(address(token));
    }

    function test_deregisterToken_success() public {
        vm.expectEmit(true, false, false, false, address(mgr));
        emit TokenDeregistered(address(token));

        vm.prank(registrar);
        mgr.deregisterToken(address(token));

        assertFalse(mgr.registeredTokens(address(token)));
    }

    function test_deregisterToken_onlyRegistrar_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        mgr.deregisterToken(address(token));
    }

    function test_deregisterToken_zeroAddress_reverts() public {
        vm.prank(registrar);
        vm.expectRevert(IssuanceManager.ZeroAddress.selector);
        mgr.deregisterToken(address(0));
    }

    // ── Subscribe ─────────────────────────────────────────────────────────────

    function test_subscribe_success() public {
        uint256 amount = 100e18;

        vm.expectEmit(true, true, false, true, address(mgr));
        emit Subscribed(address(token), ap, amount);

        vm.prank(subscriber);
        mgr.subscribe(address(token), ap, amount);

        assertEq(token.balanceOf(ap), amount);
    }

    function test_subscribe_unregisteredToken_reverts() public {
        address fakeToken = address(0xDEAD);
        vm.prank(subscriber);
        vm.expectRevert();
        mgr.subscribe(fakeToken, ap, 1e18);
    }

    function test_subscribe_nonWhitelistedRecipient_reverts() public {
        vm.prank(subscriber);
        vm.expectRevert();
        mgr.subscribe(address(token), outsider, 1e18);
    }

    function test_subscribe_zeroAmount_reverts() public {
        vm.prank(subscriber);
        vm.expectRevert(IssuanceManager.ZeroAmount.selector);
        mgr.subscribe(address(token), ap, 0);
    }

    function test_subscribe_onlySubscriber_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        mgr.subscribe(address(token), ap, 1e18);
    }

    function test_subscribe_multipleTokens() public {
        GyldBondToken tokenImpl2 = new GyldBondToken();
        GyldBondToken token2 = GyldBondToken(address(new ERC1967Proxy(
            address(tokenImpl2),
            abi.encodeCall(GyldBondToken.initialize, (
                "Bond 2", "B2", "US000000TST2", 0,
                address(this), address(this), address(mockSanctions)
            ))
        )));
        token2.grantRole(token2.MINTER_ROLE(), address(mgr));
        token2.grantRole(token2.BURNER_ROLE(), address(mgr));
        vm.prank(registrar); mgr.registerToken(address(token2));

        vm.prank(subscriber); mgr.subscribe(address(token),  ap, 100e18);
        vm.prank(subscriber); mgr.subscribe(address(token2), ap, 200e18);

        assertEq(token.balanceOf(ap),  100e18);
        assertEq(token2.balanceOf(ap), 200e18);
    }

    // ── Redeem ────────────────────────────────────────────────────────────────

    function test_redeem_success() public {
        uint256 amount = 80e18;
        _subscribeAp(amount);
        _apSendsToMgr(amount);

        vm.expectEmit(true, true, false, true, address(mgr));
        emit Redeemed(address(token), ap, amount);

        vm.prank(redeemer);
        mgr.redeem(address(token), ap, amount);

        assertEq(token.balanceOf(address(mgr)), 0);
        assertEq(token.totalSupply(), 0);
    }

    function test_redeem_unregisteredToken_reverts() public {
        vm.prank(redeemer);
        vm.expectRevert();
        mgr.redeem(address(0xDEAD), ap, 1e18);
    }

    function test_redeem_nonWhitelistedBeneficiary_reverts() public {
        _subscribeAp(10e18);
        _apSendsToMgr(10e18);

        vm.prank(redeemer);
        vm.expectRevert();
        mgr.redeem(address(token), outsider, 10e18);
    }

    function test_redeem_zeroAmount_reverts() public {
        vm.prank(redeemer);
        vm.expectRevert(IssuanceManager.ZeroAmount.selector);
        mgr.redeem(address(token), ap, 0);
    }

    function test_redeem_onlyRedeemer_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        mgr.redeem(address(token), ap, 1e18);
    }

    function test_redeem_insufficientBalance_reverts() public {
        _subscribeAp(50e18);
        _apSendsToMgr(50e18);

        vm.prank(redeemer);
        vm.expectRevert();
        mgr.redeem(address(token), ap, 100e18);
    }


    // ── Role isolation ────────────────────────────────────────────────────────

    /// Core M-1 regression: subscriber cannot call redeem, redeemer cannot call subscribe.
    /// A compromised mint key cannot burn; a compromised burn key cannot mint.
    function test_subscriber_cannotRedeem() public {
        _subscribeAp(50e18);
        _apSendsToMgr(50e18);
        vm.prank(subscriber);
        vm.expectRevert();
        mgr.redeem(address(token), ap, 50e18);
    }

    function test_redeemer_cannotSubscribe() public {
        vm.prank(redeemer);
        vm.expectRevert();
        mgr.subscribe(address(token), ap, 1e18);
    }

    function test_subscriber_cannotManageWhitelist() public {
        vm.prank(subscriber);
        vm.expectRevert();
        mgr.addToWhitelist(address(0xCC));
    }

    function test_redeemer_cannotManageWhitelist() public {
        vm.prank(redeemer);
        vm.expectRevert();
        mgr.addToWhitelist(address(0xCC));
    }

    function test_whitelistAdmin_cannotSubscribe() public {
        vm.prank(whitelistAdmin);
        vm.expectRevert();
        mgr.subscribe(address(token), ap, 1e18);
    }

    function test_registrar_cannotSubscribe() public {
        vm.prank(registrar);
        vm.expectRevert();
        mgr.subscribe(address(token), ap, 1e18);
    }

    // ── Additional redeem / whitelist / registry tests ────────────────────────

    function test_redeem_partialAmount_succeeds() public {
        uint256 total = 100e18;
        uint256 half = 50e18;
        _subscribeAp(total);
        _apSendsToMgr(total);

        vm.prank(redeemer);
        mgr.redeem(address(token), ap, half);

        // mgr still holds the unredeemed half
        assertEq(token.balanceOf(address(mgr)), half);
        // only half was burned
        assertEq(token.totalSupply(), half);
    }

    function test_addToWhitelist_idempotent_emitsEventAgain() public {
        // ap is already whitelisted in setUp; adding again should emit the event again
        vm.expectEmit(true, false, false, false, address(mgr));
        emit AddressWhitelisted(ap);
        vm.prank(whitelistAdmin);
        mgr.addToWhitelist(ap);
        // still whitelisted
        assertTrue(mgr.whitelisted(ap));
    }

    function test_deregisterToken_twice_isIdempotent() public {
        vm.prank(registrar); mgr.deregisterToken(address(token));
        assertFalse(mgr.registeredTokens(address(token)));

        // second deregister must not revert
        vm.prank(registrar); mgr.deregisterToken(address(token));
        assertFalse(mgr.registeredTokens(address(token)));
    }

    function test_registrar_cannotRedeem() public {
        _subscribeAp(10e18);
        _apSendsToMgr(10e18);

        vm.prank(registrar);
        vm.expectRevert();
        mgr.redeem(address(token), ap, 10e18);
    }

    function testFuzz_subscribe_redeem_roundTrip(uint256 amount) public {
        // Upper bound is the daily cap (FIND-001) — above it subscribe fails closed,
        // which test_subscribe_revertsOverDailyCap covers directly.
        amount = bound(amount, 1e18, mgr.DEFAULT_DAILY_CAP());

        _subscribeAp(amount);
        _apSendsToMgr(amount);

        vm.prank(redeemer);
        mgr.redeem(address(token), ap, amount);

        assertEq(token.totalSupply(), 0);
        assertEq(token.balanceOf(address(mgr)), 0);
    }

    // ── UUPS upgrade ──────────────────────────────────────────────────────────

    function test_unauthorizedUpgrade_reverts() public {
        IssuanceManager newImpl = new IssuanceManager();
        vm.prank(outsider);
        vm.expectRevert();
        mgr.upgradeToAndCall(address(newImpl), "");
    }

    // ── renounceRole guard ────────────────────────────────────────────────────

    function test_renounceRole_defaultAdmin_reverts() public {
        // Cache role bytes before pranking — getter call would consume the prank/expectRevert.
        bytes32 adminRole = mgr.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(IssuanceManager.CannotRenounceAdminRole.selector);
        mgr.renounceRole(adminRole, admin);
    }

    function test_renounceRole_nonAdminRole_succeeds() public {
        bytes32 whitelistAdminRole = mgr.WHITELIST_ADMIN_ROLE();
        vm.prank(admin); mgr.grantRole(whitelistAdminRole, admin);
        assertTrue(mgr.hasRole(whitelistAdminRole, admin));

        vm.prank(admin);
        mgr.renounceRole(whitelistAdminRole, admin);
        assertFalse(mgr.hasRole(whitelistAdminRole, admin));
    }

    // ── registerToken interface validation (GYL-298) ──────────────────────────

    function test_registerToken_nonContractAddress_reverts() public {
        address eoa = address(0xEEEE);
        vm.prank(registrar);
        vm.expectRevert();
        mgr.registerToken(eoa);
    }

    function test_registerToken_wrongContract_reverts() public {
        // MockSanctionsList has no MINTER_ROLE() — not a GyldBondToken
        address wrongContract = address(new MockSanctionsList(address(this)));
        vm.prank(registrar);
        vm.expectRevert();
        mgr.registerToken(wrongContract);
    }

    // ── Reentrancy guard ──────────────────────────────────────────────────────

    function test_redeem_reentrantCall_reverts() public {
        ReentrantToken rtoken = new ReentrantToken(address(mgr));

        // Register the malicious token (needs MINTER_ROLE probe to pass)
        vm.prank(registrar);
        mgr.registerToken(address(rtoken));

        vm.prank(whitelistAdmin);
        mgr.addToWhitelist(ap);

        // Arm the reentrant token with redeemer + beneficiary so it can attempt
        // the re-entry call with valid arguments.
        rtoken.arm(redeemer, ap, 1e18);

        // The burn() call on rtoken will attempt to re-enter redeem() — the
        // ReentrancyGuard must reject the second call.
        vm.prank(redeemer);
        vm.expectRevert();
        mgr.redeem(address(rtoken), ap, 1e18);
    }

    function test_subscribe_reentrantCall_reverts() public {
        ReentrantToken rtoken = new ReentrantToken(address(mgr));

        vm.prank(registrar);
        mgr.registerToken(address(rtoken));

        vm.prank(whitelistAdmin);
        mgr.addToWhitelist(ap);

        rtoken.armMint(subscriber, ap, 1e18);

        vm.prank(subscriber);
        vm.expectRevert();
        mgr.subscribe(address(rtoken), ap, 1e18);
    }
    // ── ERC-7201 storage layout (GYL-1208) ────────────────────────────────────

    /// Pin the namespaced layout. `IssuanceManager` is a UUPS proxy, so on any
    /// deployment its storage outlives the implementation and an upgrade that moves a
    /// field silently re-points live state — and nothing in this file asserted a single
    /// storage slot before now.
    ///
    /// The two negative assertions at the end are the actual point. `whitelisted` and
    /// `registeredTokens` are BOTH `mapping(address => bool)` and adjacent. Swapping
    /// them compiles clean, leaves every other test in this suite passing, and reads
    /// as tidying in a diff — while on a deployed proxy it would make every whitelisted
    /// AP a registered token and vice versa. Nothing else in the repo catches that.
    function test_storageLayout_erc7201OffsetsArePinned() public {
        bytes32 root =
            keccak256(abi.encode(uint256(keccak256("gyld.IssuanceManager")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(
            root,
            0xc8552dd465c7174389604c2ad1f48bf21d46f65ee8d42bbd0456923afc111000,
            "ERC-7201 derivation drifted from the _STORAGE_LOCATION literal"
        );

        vm.prank(whitelistAdmin);
        mgr.addToWhitelist(ap);
        vm.prank(registrar);
        mgr.registerToken(address(token));

        // whitelisted occupies B+0; registeredTokens occupies B+1.
        assertEq(
            uint256(vm.load(address(mgr), keccak256(abi.encode(ap, uint256(root) + 0)))),
            1,
            "whitelisted must occupy B+0"
        );
        assertEq(
            uint256(vm.load(address(mgr), keccak256(abi.encode(address(token), uint256(root) + 1)))),
            1,
            "registeredTokens must occupy B+1"
        );

        // NEGATIVE: the two mappings must not be interchangeable. If a refactor ever
        // swaps them these are the assertions that fail — the positives above would
        // still pass, because each key would simply be found in the other's slot.
        assertEq(
            uint256(vm.load(address(mgr), keccak256(abi.encode(ap, uint256(root) + 1)))),
            0,
            "a whitelisted AP must NOT appear in registeredTokens' slot (fields swapped?)"
        );
        assertEq(
            uint256(vm.load(address(mgr), keccak256(abi.encode(address(token), uint256(root) + 0)))),
            0,
            "a registered token must NOT appear in whitelisted's slot (fields swapped?)"
        );
    }
    // ── Daily mint cap (audit FIND-001) ───────────────────────────────────────

    address pauser = address(0xA5);

    function test_dailyCap_defaultsTo10k() public view {
        assertEq(mgr.dailyCap(address(token)), 10_000e18);
    }

    /// The finding: subscribe() bounded nothing, so one online key could mint without limit.
    function test_subscribe_revertsOverDailyCap() public {
        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(
            IssuanceManager.DailyCapExceeded.selector, address(token), 10_000e18 + 1, 10_000e18));
        mgr.subscribe(address(token), ap, 10_000e18 + 1);
    }

    /// The cap must hold across many small mints, not just one large one.
    function test_subscribe_capIsCumulativeWithinTheDay() public {
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(subscriber);
            mgr.subscribe(address(token), ap, 1_000e18);
        }
        (uint256 minted,) = mgr.mintedToday(address(token));
        assertEq(minted, 10_000e18);

        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(
            IssuanceManager.DailyCapExceeded.selector, address(token), uint256(1), 10_000e18));
        mgr.subscribe(address(token), ap, 1);
    }

    function test_subscribe_windowResetsAfterADay() public {
        vm.prank(subscriber);
        mgr.subscribe(address(token), ap, 10_000e18);

        vm.warp(block.timestamp + 1 days);
        vm.prank(subscriber);
        mgr.subscribe(address(token), ap, 10_000e18);
        assertEq(token.totalSupply(), 20_000e18);
    }

    /// One second early must NOT reset, or the cap is bypassable by waiting slightly less.
    function test_subscribe_windowDoesNotResetEarly() public {
        vm.prank(subscriber);
        mgr.subscribe(address(token), ap, 10_000e18);

        vm.warp(block.timestamp + 1 days - 1);
        vm.prank(subscriber);
        vm.expectRevert(abi.encodeWithSelector(
            IssuanceManager.DailyCapExceeded.selector, address(token), uint256(1), 10_000e18));
        mgr.subscribe(address(token), ap, 1);
    }

    function test_setDailyCap_raisesAndZeroRestoresDefault() public {
        vm.prank(admin);
        mgr.setDailyCap(address(token), 50_000e18);
        assertEq(mgr.dailyCap(address(token)), 50_000e18);

        vm.prank(subscriber);
        mgr.subscribe(address(token), ap, 50_000e18);

        vm.prank(admin);
        mgr.setDailyCap(address(token), 0);
        assertEq(mgr.dailyCap(address(token)), 10_000e18, "zero restores the default");
    }

    /// Usage.minted is a uint192 and subscribe casts to it explicitly, which Solidity does
    /// not check — a cap above that range would truncate the running total and silently
    /// reset the counter. The setter is the only place that can create one.
    function test_setDailyCap_rejectsCapAboveUint192() public {
        uint256 tooBig = uint256(type(uint192).max) + 1;
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IssuanceManager.InvalidCap.selector, tooBig));
        mgr.setDailyCap(address(token), tooBig);

        vm.prank(admin);
        mgr.setDailyCap(address(token), type(uint192).max); // the boundary itself is fine
        assertEq(mgr.dailyCap(address(token)), type(uint192).max);
    }

    /// A cap the online key could raise would not be a cap.
    function test_setDailyCap_subscriberCannotRaiseIt() public {
        vm.prank(subscriber);
        vm.expectRevert();
        mgr.setDailyCap(address(token), type(uint256).max);
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    function _grantPauser() internal {
        bytes32 role = mgr.ISSUANCE_PAUSER_ROLE();
        vm.prank(admin);
        mgr.grantRole(role, pauser);
    }

    function test_pauseIssuance_blocksSubscribe() public {
        _grantPauser();
        vm.prank(pauser); mgr.pauseIssuance();

        vm.prank(subscriber);
        vm.expectRevert();
        mgr.subscribe(address(token), ap, 1e18);
    }

    /// Redeem stays open: trapping APs mid-incident makes the incident worse.
    function test_pauseIssuance_leavesRedeemOpen() public {
        vm.prank(whitelistAdmin); mgr.addToWhitelist(address(mgr));
        vm.prank(subscriber); mgr.subscribe(address(token), address(mgr), 10e18);

        _grantPauser();
        vm.prank(pauser); mgr.pauseIssuance();

        vm.prank(redeemer);
        mgr.redeem(address(token), ap, 10e18);
        assertEq(token.totalSupply(), 0);
    }

    /// Asymmetric, like the swap (D-14): pauser stops it, only the timelock restarts it.
    function test_unpauseIssuance_isTimelockOnly() public {
        _grantPauser();
        vm.prank(pauser); mgr.pauseIssuance();

        vm.prank(pauser);
        vm.expectRevert();
        mgr.unpauseIssuance();

        vm.prank(admin); mgr.unpauseIssuance();
        vm.prank(subscriber); mgr.subscribe(address(token), ap, 1e18);
    }
}

/// @dev Malicious token that attempts to re-enter IssuanceManager on burn() or mint().
contract ReentrantToken {
    IssuanceManager private immutable _mgr;

    // redeem re-entry params
    address private _redeemer;
    address private _beneficiary;
    uint256 private _redeemAmount;
    bool    private _armRedeem;

    // subscribe re-entry params
    address private _subscriber;
    address private _mintRecipient;
    uint256 private _mintAmount;
    bool    private _armMint;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    constructor(address mgr) { _mgr = IssuanceManager(mgr); }

    function arm(address redeemer_, address beneficiary_, uint256 amount_) external {
        _redeemer = redeemer_; _beneficiary = beneficiary_; _redeemAmount = amount_;
        _armRedeem = true;
    }

    function armMint(address subscriber_, address recipient_, uint256 amount_) external {
        _subscriber = subscriber_; _mintRecipient = recipient_; _mintAmount = amount_;
        _armMint = true;
    }

    function burn(address, uint256) external {
        if (_armRedeem) {
            _armRedeem = false;
            vm.prank(_redeemer);
            _mgr.redeem(address(this), _beneficiary, _redeemAmount);
        }
    }

    function mint(address, uint256) external {
        if (_armMint) {
            _armMint = false;
            vm.prank(_subscriber);
            _mgr.subscribe(address(this), _mintRecipient, _mintAmount);
        }
    }

}

// Forge cheatcode interface needed inside ReentrantToken
interface Vm { function prank(address) external; }
Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
