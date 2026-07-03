// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {GyldDvpEscrow} from "../GyldDvpEscrow.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDCPermit} from "./MockUSDCPermit.sol";

/// @dev MockNavForwarder pins updatedAt to block.timestamp, so staleness can never
///      trigger with it. This variant lets tests set both answer and updatedAt.
contract MockStaleableNavForwarder {
    int256  private _answer;
    uint256 private _updatedAt;

    constructor(int256 initialAnswer) {
        _answer    = initialAnswer;
        _updatedAt = block.timestamp;
    }

    function setAnswer(int256 newAnswer) external { _answer = newAnswer; }
    function setUpdatedAt(uint256 ts) external { _updatedAt = ts; }

    function decimals() external pure returns (uint8) { return 8; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }
}

/// @dev Reports the wrong decimals — must fail setNavConfig's probe.
contract MockBadDecimalsForwarder {
    function decimals() external pure returns (uint8) { return 18; }
}

contract GyldDvpEscrowTest is Test {
    // Mirror events for vm.expectEmit (test pragma predates ContractName.Event syntax)
    event Deposited(
        uint256 indexed termsId,
        address indexed ap,
        address indexed counterparty,
        address token,
        uint256 tokenAmount,
        uint256 usdcAmount,
        uint64  refundAfter
    );
    event Settled(uint256 indexed termsId, address indexed payout, uint256 usdcAmount);
    event Filled(uint256 indexed termsId, address indexed counterparty, uint256 usdcAmount);
    event Refunded(uint256 indexed termsId, address indexed ap, uint256 tokenAmount);
    event GuardianRefunded(
        uint256 indexed termsId,
        address indexed ap,
        address indexed guardian,
        bytes32 reasonCode
    );
    event TermsEpochBumped(uint64 indexed newEpoch);
    event NavConfigSet(address indexed token, address forwarder, uint16 maxDeviationBps, uint32 maxAgeSecs);

    GyldDvpEscrow             escrow;
    GyldBondToken             token;
    IssuanceManager           manager;
    MockUSDCPermit            usdc;
    MockSanctionsList         mockSanctions;
    MockStaleableNavForwarder navFeed;

    address admin      = address(0xA0); // DEFAULT_ADMIN_ROLE everywhere
    address pauser     = address(0xA1); // PAUSER_ROLE
    address settler    = address(0xA2); // SETTLER_ROLE
    address guardian   = address(0xA3); // GUARDIAN_ROLE
    address subscriber = address(0xA4); // IssuanceManager SUBSCRIBER_ROLE (unused here)
    address redeemer   = address(0xA5); // IssuanceManager REDEEMER_ROLE (unused here)
    address treasury   = address(0xB0); // USDC source for settle()
    address ap         = address(0xAB); // the AP / maker
    address buyer      = address(0xBB); // designated P2P counterparty
    address payout     = address(0xCC); // AP's USDC destination (treasury ≠ trading wallet)
    address outsider   = address(0xFF);

    uint256 constant SIGNER_PK = 0x516E5;
    address          signer;

    // NAV $100.00 per token (8dp): 1e18 token ⇔ 100e6 USDC. Standard terms below
    // (10 tokens for 1_000 USDC) sit exactly on NAV.
    int256 constant NAV = 100e8;

    uint256 constant TOKEN_AMOUNT = 10e18;
    uint256 constant USDC_AMOUNT  = 1_000e6;

    function NO_PERMIT() internal pure returns (GyldDvpEscrow.PermitData memory) {
        return GyldDvpEscrow.PermitData({value: 0, deadline: 0, v: 0, r: 0, s: 0});
    }

    function setUp() public {
        vm.warp(1_750_000_000); // realistic timestamp so expiry math is meaningful
        signer = vm.addr(SIGNER_PK);

        mockSanctions = new MockSanctionsList();
        usdc          = new MockUSDCPermit();
        navFeed       = new MockStaleableNavForwarder(NAV);

        // ── GyldBondToken proxy ───────────────────────────────────────────────
        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(address(new ERC1967Proxy(
            address(tokenImpl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Gyld US Treasury Bond 2026-06",
                "GYLD-UST-2606",
                "US912797KR72",
                1_780_000_000,
                admin,
                pauser,
                address(mockSanctions)
            ))
        )));

        // ── IssuanceManager proxy (real registry — deposit gates on it) ──────
        IssuanceManager managerImpl = new IssuanceManager();
        manager = IssuanceManager(address(new ERC1967Proxy(
            address(managerImpl),
            abi.encodeCall(IssuanceManager.initialize, (admin, subscriber, redeemer))
        )));
        bytes32 registrarRole = manager.REGISTRAR_ROLE();
        vm.prank(admin); manager.grantRole(registrarRole, address(this));
        manager.registerToken(address(token));

        // ── GyldDvpEscrow (non-upgradeable — plain constructor) ──────────────
        escrow = new GyldDvpEscrow(
            admin, pauser, signer, settler, guardian,
            address(usdc), address(manager), treasury
        );

        // Fund all sides. AP holds the bond tokens; treasury and buyer hold USDC.
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin); token.grantRole(minterRole, address(this));
        token.mint(ap, 100e18);
        usdc.mint(treasury, 1_000_000e6);
        usdc.mint(buyer, 1_000_000e6);

        // Standing approvals for the default flows (exact-value approvals are
        // exercised in the individual tests where relevant).
        vm.prank(ap);       token.approve(address(escrow), type(uint256).max);
        vm.prank(treasury); usdc.approve(address(escrow), type(uint256).max);
        vm.prank(buyer);    usdc.approve(address(escrow), type(uint256).max);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// Redemption terms: counterparty == 0, settler pays from treasury.
    function _redemptionTerms(uint256 termsId) internal view returns (GyldDvpEscrow.DvpTerms memory) {
        return GyldDvpEscrow.DvpTerms({
            termsId:       termsId,
            ap:            ap,
            counterparty:  address(0),
            token:         address(token),
            tokenAmount:   TOKEN_AMOUNT,
            usdcAmount:    USDC_AMOUNT,
            payout:        payout,
            depositExpiry: uint64(block.timestamp + 1 hours),
            refundAfter:   uint64(block.timestamp + 72 hours),
            epoch:         0
        });
    }

    /// P2P terms: the designated buyer funds USDC and receives the tokens.
    function _p2pTerms(uint256 termsId) internal view returns (GyldDvpEscrow.DvpTerms memory) {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(termsId);
        t.counterparty = buyer;
        return t;
    }

    function _sign(GyldDvpEscrow.DvpTerms memory t) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, escrow.hashDvpTerms(t));
        return abi.encodePacked(r, s, v);
    }

    function _deposit(GyldDvpEscrow.DvpTerms memory t) internal {
        bytes memory sig = _sign(t);
        vm.prank(t.ap);
        escrow.deposit(t, sig, NO_PERMIT());
    }

    // ── Deposit ───────────────────────────────────────────────────────────────

    function test_deposit_locksTokensAndRecordsPosition() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);

        vm.expectEmit(true, true, true, true);
        emit Deposited(1, ap, address(0), address(token), TOKEN_AMOUNT, USDC_AMOUNT, t.refundAfter);
        _deposit(t);

        assertEq(token.balanceOf(address(escrow)), TOKEN_AMOUNT);
        assertEq(token.balanceOf(ap), 90e18);

        GyldDvpEscrow.Position memory p = escrow.positionOf(1);
        assertEq(uint8(p.status), uint8(GyldDvpEscrow.Status.DEPOSITED));
        assertEq(p.ap, ap);
        assertEq(p.token, address(token));
        assertEq(p.tokenAmount, TOKEN_AMOUNT);
        assertEq(p.usdcAmount, USDC_AMOUNT);
        assertEq(p.payout, payout);
        assertEq(p.refundAfter, t.refundAfter);
    }

    function test_deposit_revertsForNonAp() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        bytes memory sig = _sign(t);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.NotAp.selector, ap, outsider));
        escrow.deposit(t, sig, NO_PERMIT());
    }

    function test_deposit_revertsPastDepositExpiry() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        bytes memory sig = _sign(t);
        vm.warp(t.depositExpiry + 1);
        vm.prank(ap);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.TermsExpired.selector, t.depositExpiry));
        escrow.deposit(t, sig, NO_PERMIT());
    }

    function test_deposit_revertsOnShortSettlementWindow() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        t.refundAfter = uint64(block.timestamp + 30 minutes); // < MIN_SETTLEMENT_WINDOW
        bytes memory sig = _sign(t);
        vm.prank(ap);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.SettlementWindowTooShort.selector, t.refundAfter));
        escrow.deposit(t, sig, NO_PERMIT());
    }

    function test_deposit_revertsOnStaleEpoch() public {
        vm.prank(admin);
        escrow.bumpTermsEpoch();
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1); // still epoch 0
        bytes memory sig = _sign(t);
        vm.prank(ap);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.TermsEpochStale.selector, uint64(0), uint64(1)));
        escrow.deposit(t, sig, NO_PERMIT());
    }

    function test_deposit_revertsOnBadSigner() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, escrow.hashDvpTerms(t));
        vm.prank(ap);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.InvalidTermsSigner.selector, vm.addr(0xBAD)));
        escrow.deposit(t, abi.encodePacked(r, s, v), NO_PERMIT());
    }

    function test_deposit_revertsOnUnregisteredToken() public {
        MockUSDCPermit rogue = new MockUSDCPermit(); // any non-registered ERC-20
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        t.token = address(rogue);
        bytes memory sig = _sign(t);
        vm.prank(ap);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.UnregisteredToken.selector, address(rogue)));
        escrow.deposit(t, sig, NO_PERMIT());
    }

    function test_deposit_revertsOnTermsIdReuse_evenAfterRefund() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        _deposit(t);
        vm.warp(t.refundAfter);
        escrow.refund(1);

        // Same termsId can never be deposited again — terminal states are permanent.
        GyldDvpEscrow.DvpTerms memory t2 = _redemptionTerms(1);
        t2.depositExpiry = uint64(block.timestamp + 1 hours);
        t2.refundAfter   = uint64(block.timestamp + 72 hours);
        bytes memory sig = _sign(t2);
        vm.prank(ap);
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.InvalidState.selector, 1, GyldDvpEscrow.Status.REFUNDED)
        );
        escrow.deposit(t2, sig, NO_PERMIT());
    }

    function test_deposit_revertsOnZeroAmounts() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        t.usdcAmount = 0;
        bytes memory sig = _sign(t);
        vm.prank(ap);
        vm.expectRevert(GyldDvpEscrow.ZeroAmount.selector);
        escrow.deposit(t, sig, NO_PERMIT());
    }

    function test_deposit_revertsWhenPaused_butPauseGatesDepositOnly() public {
        // Set up one open position before pausing.
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        _deposit(t);

        vm.prank(pauser);
        escrow.pause();

        // deposit is gated…
        GyldDvpEscrow.DvpTerms memory t2 = _redemptionTerms(2);
        bytes memory sig = _sign(t2);
        vm.prank(ap);
        vm.expectRevert(); // Pausable: EnforcedPause
        escrow.deposit(t2, sig, NO_PERMIT());

        // …but settle still works under pause (never pausable).
        vm.prank(settler);
        escrow.settle(1);
        assertEq(usdc.balanceOf(payout), USDC_AMOUNT);
    }

    function test_pause_roleGates() public {
        vm.prank(outsider);
        vm.expectRevert();
        escrow.pause();

        vm.prank(pauser);
        escrow.pause();

        // Asymmetric: pauser cannot unpause.
        vm.prank(pauser);
        vm.expectRevert();
        escrow.unpause();

        vm.prank(admin);
        escrow.unpause();
    }

    // ── Settle (redemption path) ──────────────────────────────────────────────

    function test_settle_paysApAndForwardsTokensForBurn() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        _deposit(t);

        vm.expectEmit(true, true, false, true);
        emit Settled(1, payout, USDC_AMOUNT);
        vm.prank(settler);
        escrow.settle(1);

        assertEq(usdc.balanceOf(payout), USDC_AMOUNT);
        assertEq(usdc.balanceOf(treasury), 1_000_000e6 - USDC_AMOUNT);
        assertEq(token.balanceOf(address(manager)), TOKEN_AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint8(escrow.positionOf(1).status), uint8(GyldDvpEscrow.Status.SETTLED));
    }

    function test_settle_revertsForNonSettler() public {
        _deposit(_redemptionTerms(1));
        vm.prank(outsider);
        vm.expectRevert();
        escrow.settle(1);
    }

    function test_settle_revertsOnP2PTerms() public {
        _deposit(_p2pTerms(1));
        vm.prank(settler);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.NotRedemptionTerms.selector, 1));
        escrow.settle(1);
    }

    function test_settle_validPastRefundAfter_untilRefunded() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        _deposit(t);
        vm.warp(t.refundAfter + 1 days);

        // Late settlement beats stranding: still valid because nobody refunded.
        vm.prank(settler);
        escrow.settle(1);
        assertEq(usdc.balanceOf(payout), USDC_AMOUNT);

        // And the settled position cannot be refunded afterwards.
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.InvalidState.selector, 1, GyldDvpEscrow.Status.SETTLED)
        );
        escrow.refund(1);
    }

    // ── Fill (P2P path) ───────────────────────────────────────────────────────

    function test_fill_atomicSwap_buyerPaysApReceivesTokens() public {
        _deposit(_p2pTerms(1));

        vm.expectEmit(true, true, false, true);
        emit Filled(1, buyer, USDC_AMOUNT);
        vm.prank(buyer);
        escrow.fill(1, NO_PERMIT());

        assertEq(usdc.balanceOf(payout), USDC_AMOUNT);
        assertEq(usdc.balanceOf(buyer), 1_000_000e6 - USDC_AMOUNT);
        assertEq(token.balanceOf(buyer), TOKEN_AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint8(escrow.positionOf(1).status), uint8(GyldDvpEscrow.Status.SETTLED));
    }

    function test_fill_revertsForNonCounterparty() public {
        _deposit(_p2pTerms(1));
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.NotCounterparty.selector, buyer, outsider));
        escrow.fill(1, NO_PERMIT());
    }

    function test_fill_revertsOnRedemptionTerms() public {
        _deposit(_redemptionTerms(1));
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.NotP2PTerms.selector, 1));
        escrow.fill(1, NO_PERMIT());
    }

    function test_fill_revertsOnReplay() public {
        _deposit(_p2pTerms(1));
        vm.prank(buyer);
        escrow.fill(1, NO_PERMIT());
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.InvalidState.selector, 1, GyldDvpEscrow.Status.SETTLED)
        );
        escrow.fill(1, NO_PERMIT());
    }

    function test_fill_revertsIfBuyerUnderfunded() public {
        _deposit(_p2pTerms(1));
        // Buyer moves USDC away — the pull leg must revert, so the token leg
        // can never execute alone (all-or-nothing).
        vm.startPrank(buyer);
        usdc.transfer(outsider, 1_000_000e6);
        vm.expectRevert();
        escrow.fill(1, NO_PERMIT());
        vm.stopPrank();
        assertEq(token.balanceOf(address(escrow)), TOKEN_AMOUNT); // still locked
    }

    // ── NAV band (P2P fills) ──────────────────────────────────────────────────

    function _enableNavBand() internal {
        vm.prank(admin);
        escrow.setNavConfig(address(token), address(navFeed), 200, 24 hours); // ±2%, 24h freshness
    }

    function test_fill_navBand_passesOnNav() public {
        _enableNavBand();
        _deposit(_p2pTerms(1)); // 10 tokens ⇔ 1_000 USDC — exactly on NAV
        vm.prank(buyer);
        escrow.fill(1, NO_PERMIT());
        assertEq(token.balanceOf(buyer), TOKEN_AMOUNT);
    }

    function test_fill_navBand_revertsOutOfBand() public {
        _enableNavBand();
        GyldDvpEscrow.DvpTerms memory t = _p2pTerms(1);
        t.usdcAmount = 1_021e6; // NAV value 1_000e6, band ±20e6 → out of band
        _deposit(t);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.NavPriceOutOfBand.selector, 1_021e6, 1_000e6)
        );
        escrow.fill(1, NO_PERMIT());
    }

    function test_fill_navBand_exactEdges() public {
        // navValue = TOKEN_AMOUNT * NAV / 1e20 = 1_000e6; band at 200 bps = 20e6.
        // Accept iff navValue - band <= usdc <= navValue + band — pin both edges
        // exactly. fill() is terminal, so each attempt gets its own termsId.
        _enableNavBand();

        // Exact upper edge: navValue + band — fills.
        GyldDvpEscrow.DvpTerms memory t1 = _p2pTerms(1);
        t1.usdcAmount = 1_020_000_000;
        _deposit(t1);
        vm.prank(buyer);
        escrow.fill(1, NO_PERMIT());
        assertEq(uint8(escrow.positionOf(1).status), uint8(GyldDvpEscrow.Status.SETTLED));

        // One above the upper edge — out of band.
        GyldDvpEscrow.DvpTerms memory t2 = _p2pTerms(2);
        t2.usdcAmount = 1_020_000_001;
        _deposit(t2);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.NavPriceOutOfBand.selector, 1_020_000_001, 1_000e6)
        );
        escrow.fill(2, NO_PERMIT());

        // Exact lower edge: navValue - band — fills.
        GyldDvpEscrow.DvpTerms memory t3 = _p2pTerms(3);
        t3.usdcAmount = 980_000_000;
        _deposit(t3);
        vm.prank(buyer);
        escrow.fill(3, NO_PERMIT());
        assertEq(uint8(escrow.positionOf(3).status), uint8(GyldDvpEscrow.Status.SETTLED));

        // One below the lower edge — out of band.
        GyldDvpEscrow.DvpTerms memory t4 = _p2pTerms(4);
        t4.usdcAmount = 979_999_999;
        _deposit(t4);
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.NavPriceOutOfBand.selector, 979_999_999, 1_000e6)
        );
        escrow.fill(4, NO_PERMIT());
    }

    function test_fill_navBand_revertsOnStaleFeed() public {
        _enableNavBand();
        _deposit(_p2pTerms(1));
        // Literals, not block.timestamp arithmetic: via_ir legally assumes
        // block.timestamp is invariant within a frame, so reads can be reordered
        // across vm.warp.
        navFeed.setUpdatedAt(1_750_000_000);
        vm.warp(1_750_000_000 + 25 hours); // feed's updatedAt stays behind
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.StaleNav.selector, address(token), uint256(1_750_000_000))
        );
        escrow.fill(1, NO_PERMIT());
    }

    function test_fill_navBand_revertsOnNonPositiveNav() public {
        _enableNavBand();
        _deposit(_p2pTerms(1));
        navFeed.setAnswer(0);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.InvalidNav.selector, address(token), int256(0)));
        escrow.fill(1, NO_PERMIT());
    }

    function test_fill_unconfiguredSeriesSkipsNavCheck() public {
        // No setNavConfig call: even a wildly off-NAV price fills — firmness is the
        // signed terms (GYL-724's stance), the band is opt-in defense-in-depth.
        GyldDvpEscrow.DvpTerms memory t = _p2pTerms(1);
        t.usdcAmount = 5_000e6;
        _deposit(t);
        vm.prank(buyer);
        escrow.fill(1, NO_PERMIT());
        assertEq(usdc.balanceOf(payout), 5_000e6);
    }

    function test_setNavConfig_probesForwarderDecimals() public {
        MockBadDecimalsForwarder bad = new MockBadDecimalsForwarder();
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.NotValidNavForwarder.selector, address(bad)));
        escrow.setNavConfig(address(token), address(bad), 200, 24 hours);
    }

    function test_setNavConfig_clearAndRoleGate() public {
        _enableNavBand();
        vm.prank(admin);
        escrow.setNavConfig(address(token), address(0), 0, 0); // clear
        assertEq(escrow.navConfigOf(address(token)).forwarder, address(0));

        vm.prank(outsider);
        vm.expectRevert();
        escrow.setNavConfig(address(token), address(navFeed), 200, 24 hours);
    }

    // ── Refund ────────────────────────────────────────────────────────────────

    function test_refund_lockedBeforeRefundAfter() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        _deposit(t);
        vm.expectRevert(abi.encodeWithSelector(GyldDvpEscrow.RefundLocked.selector, t.refundAfter));
        escrow.refund(1);
    }

    function test_refund_permissionless_alwaysToRecordedAp() public {
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        _deposit(t);
        vm.warp(t.refundAfter);

        vm.expectEmit(true, true, false, true);
        emit Refunded(1, ap, TOKEN_AMOUNT);
        vm.prank(outsider); // anyone may trigger; destination is fixed
        escrow.refund(1);

        assertEq(token.balanceOf(ap), 100e18);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint8(escrow.positionOf(1).status), uint8(GyldDvpEscrow.Status.REFUNDED));
    }

    function test_refund_revertsIfApSanctionedMidLock() public {
        // Fail-closed: a sanctioned depositor freezes in escrow — the correct
        // compliance outcome (no internal blacklist, no on-chain recovery).
        GyldDvpEscrow.DvpTerms memory t = _redemptionTerms(1);
        _deposit(t);
        mockSanctions.setSanctioned(ap, true);
        vm.warp(t.refundAfter);
        vm.expectRevert(abi.encodeWithSelector(GyldBondToken.AccountSanctioned.selector, ap));
        escrow.refund(1);
    }

    // ── Guardian refund ───────────────────────────────────────────────────────

    function test_guardianRefund_earlyRefundToRecordedApOnly() public {
        _deposit(_p2pTerms(1)); // well before refundAfter

        vm.expectEmit(true, true, true, true);
        emit GuardianRefunded(1, ap, guardian, "MISPRICED_QUOTE");
        vm.prank(guardian);
        escrow.guardianRefund(1, "MISPRICED_QUOTE");

        assertEq(token.balanceOf(ap), 100e18); // tokens back with the maker — nowhere else
        assertEq(uint8(escrow.positionOf(1).status), uint8(GyldDvpEscrow.Status.REFUNDED));

        // The killed position can no longer be filled.
        vm.prank(buyer);
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.InvalidState.selector, 1, GyldDvpEscrow.Status.REFUNDED)
        );
        escrow.fill(1, NO_PERMIT());
    }

    function test_guardianRefund_roleGated() public {
        _deposit(_redemptionTerms(1));
        bytes32 guardianRole = escrow.GUARDIAN_ROLE(); // read BEFORE prank — getters consume it
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, outsider, guardianRole)
        );
        escrow.guardianRefund(1, "NOPE");
    }

    function test_guardianRefund_revertsOnSettledPosition() public {
        _deposit(_redemptionTerms(1));
        vm.prank(settler);
        escrow.settle(1);
        vm.prank(guardian);
        vm.expectRevert(
            abi.encodeWithSelector(GyldDvpEscrow.InvalidState.selector, 1, GyldDvpEscrow.Status.SETTLED)
        );
        escrow.guardianRefund(1, "TOO_LATE");
    }

    // ── Admin invariants ──────────────────────────────────────────────────────

    function test_renounceAdminRoleReverts() public {
        bytes32 adminRole = escrow.DEFAULT_ADMIN_ROLE(); // read BEFORE prank — getters consume it
        vm.prank(admin);
        vm.expectRevert(GyldDvpEscrow.CannotRenounceAdminRole.selector);
        escrow.renounceRole(adminRole, admin);
    }

    function test_bumpTermsEpoch_adminOnly() public {
        vm.prank(outsider);
        vm.expectRevert();
        escrow.bumpTermsEpoch();

        vm.expectEmit(true, false, false, false);
        emit TermsEpochBumped(1);
        vm.prank(admin);
        escrow.bumpTermsEpoch();
        assertEq(escrow.termsEpoch(), 1);
    }
}
