// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {IssuanceManager} from "../IssuanceManager.sol";
import {TokenFactory} from "../TokenFactory.sol";
import {KaleidoscopeNAVFeed} from "../KaleidoscopeNAVFeed.sol";
import {NAVFeedForwarder} from "../NAVFeedForwarder.sol";

// ── Re-entrancy attack helpers ────────────────────────────────────────────────

/// @dev Attacker that owns the factory and implements registerToken so it can
///      trigger a re-entrant deployToken call from inside the factory's step 6.
contract ReentrantAttacker {
    TokenFactory public immutable malFactory;
    address public immutable navFeedOwner;
    bool private _done;

    constructor(address factory_, address navFeedOwner_) {
        malFactory = TokenFactory(factory_);
        navFeedOwner = navFeedOwner_;
    }

    function attack() external {
        // issuanceManager = address(this) so registerToken loops back here
        malFactory.deployToken("Attacker Bond", "ATCK", "US000000001", 0, address(0x1), address(this), navFeedOwner);
    }

    /// @dev Called by the factory during deployToken (step 6: registerToken).
    ///      Triggers the re-entrant deployToken call.
    function registerToken(address) external {
        if (!_done) {
            _done = true;
            malFactory.deployToken("Reentrant Bond", "RENT", "US000000002", 0, address(0x1), address(this), navFeedOwner);
        }
    }

    /// @dev Stub so the preflight hasRole() check passes and the attack reaches
    ///      the nonReentrant guard (which is what this test actually validates).
    function REGISTRAR_ROLE() external pure returns (bytes32) {
        return keccak256("REGISTRAR_ROLE");
    }

    function hasRole(bytes32, address) external pure returns (bool) {
        return true;
    }
}

// ── Test contract ─────────────────────────────────────────────────────────────

contract TokenFactoryTest is Test {
    event TokenDeployed(
        address indexed token,
        address indexed navFeed,
        address indexed forwarder,
        address issuanceManager
    );

    GyldBondToken     bondTokenImpl;
    MockSanctionsList mockSanctions;
    IssuanceManager   issuanceManagerImpl;
    IssuanceManager   issuanceMgr;
    TokenFactory      factory;

    address operator     = address(0x1);
    address alice        = address(0x2);
    address bob          = address(0x3);
    address attacker     = address(0x4);
    address navFeedOwner = address(0x5);

    function setUp() public {
        bondTokenImpl       = new GyldBondToken();
        mockSanctions       = new MockSanctionsList(address(this));
        issuanceManagerImpl = new IssuanceManager();

        // Deploy IssuanceManager proxy — test contract is admin and issuer
        issuanceMgr = IssuanceManager(address(new ERC1967Proxy(
            address(issuanceManagerImpl),
            abi.encodeCall(IssuanceManager.initialize, (address(this), address(this), address(this)))
        )));

        factory = new TokenFactory(address(bondTokenImpl), address(mockSanctions), address(this));

        // Grant factory REGISTRAR_ROLE so deployToken can call registerToken
        issuanceMgr.grantRole(issuanceMgr.REGISTRAR_ROLE(), address(factory));
    }

    string  constant TEST_ISIN     = "US912797KR72";
    uint256 constant TEST_MATURITY = 1_798_761_600; // 2027-01-01 00:00:00 UTC

    // Helper: deploy a token and return all three paired contracts
    function _deploy() internal returns (address token, address navFeed, address forwarder) {
        return factory.deployToken(
            "Test Bond", "tBOND", TEST_ISIN, TEST_MATURITY, operator, address(issuanceMgr), navFeedOwner
        );
    }

    // ── constructor guards ────────────────────────────────────────────────────

    function test_constructor_zeroBondLogic_reverts() public {
        vm.expectRevert(TokenFactory.ZeroAddress.selector);
        new TokenFactory(address(0), address(mockSanctions), address(this));
    }

    function test_constructor_zeroSanctionsList_reverts() public {
        vm.expectRevert(TokenFactory.ZeroAddress.selector);
        new TokenFactory(address(bondTokenImpl), address(0), address(this));
    }

    function test_constructor_eoa_sanctionsList_reverts() public {
        address eoa = address(0xEEEE);
        vm.expectRevert(abi.encodeWithSelector(TokenFactory.NotValidSanctionsList.selector, eoa));
        new TokenFactory(address(bondTokenImpl), eoa, address(this));
    }

    function test_constructor_wrongContract_sanctionsList_reverts() public {
        address wrongContract = address(new MockWrongSanctionsList());
        vm.expectRevert(abi.encodeWithSelector(TokenFactory.NotValidSanctionsList.selector, wrongContract));
        new TokenFactory(address(bondTokenImpl), wrongContract, address(this));
    }

    // ── deployToken input guards ──────────────────────────────────────────────

    function test_deployToken_zeroOperator_reverts() public {
        vm.expectRevert(TokenFactory.ZeroAddress.selector);
        factory.deployToken("Bond", "BND", "US000000001", 0, address(0), address(issuanceMgr), navFeedOwner);
    }

    function test_deployToken_zeroIssuanceManager_reverts() public {
        vm.expectRevert(TokenFactory.ZeroAddress.selector);
        factory.deployToken("Bond", "BND", "US000000001", 0, operator, address(0), navFeedOwner);
    }

    function test_deployToken_zeroNavFeedOwner_reverts() public {
        vm.expectRevert(TokenFactory.ZeroAddress.selector);
        factory.deployToken("Bond", "BND", "US000000001", 0, operator, address(issuanceMgr), address(0));
    }

    function test_deployToken_emptyIsin_reverts() public {
        vm.expectRevert(TokenFactory.EmptyIsin.selector);
        factory.deployToken("Bond", "BND", "", 0, operator, address(issuanceMgr), navFeedOwner);
    }

    function test_deployToken_duplicateIsin_reverts() public {
        // First deployment succeeds
        _deploy();
        // Exact same params — must revert with a readable error, not an opaque
        // CREATE2 collision revert after a 48h timelock delay.
        vm.expectRevert();
        factory.deployToken(
            "Test Bond", "tBOND", TEST_ISIN, TEST_MATURITY,
            operator, address(issuanceMgr), navFeedOwner
        );
    }

    function test_deployToken_missingRegistrarRole_revertsEarly() public {
        // A factory that has never been granted REGISTRAR_ROLE on the
        // IssuanceManager must revert before any contracts are deployed.
        TokenFactory freshFactory = new TokenFactory(address(bondTokenImpl), address(mockSanctions), address(this));
        vm.expectRevert();
        freshFactory.deployToken(
            "Test Bond", "tBOND", "US000000001", 0,
            operator, address(issuanceMgr), navFeedOwner
        );
    }

    function test_deployToken_differentIsin_succeeds() public {
        _deploy(); // TEST_ISIN
        // A different ISIN must deploy without issue
        (address token2,,) = factory.deployToken(
            "Test Bond 2", "tBOND2", "US912797KR73", TEST_MATURITY,
            operator, address(issuanceMgr), navFeedOwner
        );
        assertTrue(token2 != address(0));
        assertTrue(factory.navFeedOf(token2) != address(0));
    }

    function test_deployToken_sameIsin_differentNameSymbol_reverts() public {
        // Same ISIN + different name/symbol → different CREATE2 address (initcode
        // includes name/symbol), but the _deployedIsins registry keys by ISIN only,
        // so this is correctly caught regardless of what name/symbol is passed.
        _deploy();
        vm.expectRevert();
        factory.deployToken(
            "Completely Different Name", "DIFF", TEST_ISIN, TEST_MATURITY,
            operator, address(issuanceMgr), navFeedOwner
        );
    }

    function test_deployToken_sameIsin_differentMaturity_reverts() public {
        // Same ISIN + different maturity → different CREATE2 address (initcode
        // includes maturityTimestamp), but the _deployedIsins registry keys by ISIN
        // only, so this is correctly caught regardless of maturity.
        _deploy();
        vm.expectRevert();
        factory.deployToken(
            "Test Bond", "tBOND", TEST_ISIN, 9_999_999_999,
            operator, address(issuanceMgr), navFeedOwner
        );
    }

    // ── deployment ────────────────────────────────────────────────────────────

    function test_deployToken_returnsAddresses() public {
        (address token, address navFeed, address forwarder) = _deploy();
        assertTrue(token    != address(0));
        assertTrue(navFeed  != address(0));
        assertTrue(forwarder != address(0));
        assertEq(factory.navFeedOf(token),   navFeed);
        assertEq(factory.forwarderOf(token), forwarder);
    }

    function test_deployToken_forwarderWired() public {
        (address token, address navFeed, address forwarder) = _deploy();
        NAVFeedForwarder fwd = NAVFeedForwarder(forwarder);
        // forwarder upstream must point at the raw navFeed
        assertEq(fwd.upstreamOracle(), navFeed, "forwarder upstream wrong");
        // forwarder owner = factory owner (test contract), NOT the navFeedOwner KMS signer
        assertEq(fwd.owner(), address(this), "forwarder owner must be factory owner");
        assertFalse(fwd.owner() == navFeedOwner, "KMS signer must not own forwarder");
        // mappings are consistent
        assertEq(factory.forwarderOf(token), forwarder);
    }

    function test_deployToken_emitsEvent() public {
        vm.expectEmit(false, false, false, false);
        emit TokenDeployed(address(0), address(0), address(0), address(0));
        _deploy();
    }

    function test_deployToken_tokenRegisteredWithIssuanceManager() public {
        (address token,,) = _deploy();
        assertTrue(issuanceMgr.registeredTokens(token));
    }

    // ── NAVFeed ───────────────────────────────────────────────────────────────

    function test_deployToken_navFeedOwnerIsSet() public {
        (address token,,) = _deploy();
        KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(factory.navFeedOf(token));
        assertEq(feed.owner(), navFeedOwner);
    }

    function test_deployToken_navFeedDescriptionMatchesSymbol() public {
        (address token,,) = _deploy();
        KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(factory.navFeedOf(token));
        assertEq(feed.description(), "tBOND / USD NAV");
    }

    function test_deployToken_navFeedOwnerCanPushPrice() public {
        (address token,,) = _deploy();
        KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(factory.navFeedOf(token));
        vm.prank(navFeedOwner);
        feed.updateAnswer(9_542_000_000);
        (, int256 answer,,,) = feed.latestRoundData();
        assertEq(answer, 9_542_000_000);
    }

    function test_deployToken_operatorCannotPushPrice() public {
        (address token,,) = _deploy();
        KaleidoscopeNAVFeed feed = KaleidoscopeNAVFeed(factory.navFeedOf(token));
        vm.prank(operator);
        vm.expectRevert();
        feed.updateAnswer(9_542_000_000);
    }

    // ── role assignment ───────────────────────────────────────────────────────

    function test_deployToken_issuanceManagerHasMinterRole() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        assertTrue(t.hasRole(t.MINTER_ROLE(), address(issuanceMgr)));
    }

    function test_deployToken_issuanceManagerHasBurnerRole() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        assertTrue(t.hasRole(t.BURNER_ROLE(), address(issuanceMgr)));
    }

    function test_deployToken_operatorDoesNotHaveMinterRole() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        assertFalse(t.hasRole(t.MINTER_ROLE(), operator));
    }

    function test_deployToken_operatorDoesNotHaveBurnerRole() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        assertFalse(t.hasRole(t.BURNER_ROLE(), operator));
    }

    function test_deployToken_operatorHasPauserRole() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        assertTrue(t.hasRole(t.PAUSER_ROLE(), operator));
    }

    function test_deployToken_operatorIsFactory_reverts() public {
        vm.expectRevert(TokenFactory.ZeroAddress.selector);
        factory.deployToken("X", "X", "XX0000000001", 0, address(factory), address(issuanceMgr), navFeedOwner);
    }

    function test_deployToken_factoryHasNoMintBurnRoles() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        assertFalse(t.hasRole(t.MINTER_ROLE(), address(factory)));
        assertFalse(t.hasRole(t.BURNER_ROLE(), address(factory)));
        assertFalse(t.hasRole(t.PAUSER_ROLE(), address(factory)));
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(factory)));
    }

    function test_deployToken_factoryOwnerHasDefaultAdminRole() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        // DEFAULT_ADMIN_ROLE is wired to factory.owner() at deploy time.
        // In this test the test contract owns the factory.
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_deployToken_operatorDoesNotHaveDefaultAdminRole() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), operator));
    }

    function test_deployToken_sanctionsListWired() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        assertEq(address(t.sanctionsList()), address(mockSanctions));
    }

    function test_deployToken_sanctionsListSharedAcrossTokens() public {
        (address token1,,) = factory.deployToken(
            "Bond A", "BONDA", "US000000001", 0, operator, address(issuanceMgr), navFeedOwner
        );
        (address token2,,) = factory.deployToken(
            "Bond B", "BONDB", "US000000002", 0, operator, address(issuanceMgr), navFeedOwner
        );
        assertEq(address(GyldBondToken(token1).sanctionsList()), address(mockSanctions));
        assertEq(address(GyldBondToken(token2).sanctionsList()), address(mockSanctions));
    }

    function test_deployToken_onlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.deployToken("Test Bond", "tBOND", TEST_ISIN, TEST_MATURITY, operator, address(issuanceMgr), navFeedOwner);
    }

    // ── mint (via issuanceManager) ────────────────────────────────────────────

    function test_mint_success() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        vm.prank(address(issuanceMgr));
        t.mint(alice, 1000e18);
        assertEq(t.balanceOf(alice), 1000e18);
    }

    function test_mint_unauthorized_operator() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        vm.prank(operator); // operator does not have MINTER_ROLE
        vm.expectRevert();
        t.mint(alice, 1000e18);
    }

    function test_mint_unauthorized_attacker() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        vm.prank(attacker);
        vm.expectRevert();
        t.mint(alice, 1000e18);
    }

    // ── burn (via issuanceManager) ────────────────────────────────────────────

    function test_burn_success() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        // IssuanceManager receives tokens, then burns from its own balance
        vm.prank(address(issuanceMgr)); t.mint(address(issuanceMgr), 1000e18);
        vm.prank(address(issuanceMgr)); t.burn(address(issuanceMgr), 400e18);
        assertEq(t.balanceOf(address(issuanceMgr)), 600e18);
    }

    // ── pause ─────────────────────────────────────────────────────────────────

    function test_pause_success() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        vm.prank(operator); t.pause();
        assertTrue(t.paused());
    }

    function test_unpause_success() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        vm.prank(operator); t.pause();
        vm.prank(operator); t.unpause();
        assertFalse(t.paused());
    }

    function test_transfer_blockedWhenPaused() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);
        vm.prank(address(issuanceMgr)); t.mint(alice, 1000e18);
        vm.prank(operator); t.pause();
        vm.prank(alice);
        vm.expectRevert();
        t.transfer(bob, 100e18);
    }

    // ── Chainalysis sanctions oracle ──────────────────────────────────────────

    function test_sanctioned_blocksTransfer() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);

        vm.prank(address(issuanceMgr)); t.mint(alice, 1000e18);

        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        mockSanctions.addToSanctionsList(addrs);

        vm.prank(alice);
        vm.expectRevert();
        t.transfer(bob, 100e18);
    }

    function test_unsanctioned_restoresTransfer() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);

        vm.prank(address(issuanceMgr)); t.mint(alice, 1000e18);

        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        mockSanctions.addToSanctionsList(addrs);
        mockSanctions.removeFromSanctionsList(addrs);

        vm.prank(alice);
        t.transfer(bob, 100e18);
        assertEq(t.balanceOf(bob), 100e18);
    }

    // ── spender check in transferFrom ─────────────────────────────────────────

    function test_transferFrom_blockedWhenSpenderSanctioned() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);

        vm.prank(address(issuanceMgr)); t.mint(alice, 1000e18);

        // alice approves attacker as spender
        vm.prank(alice); t.approve(attacker, 500e18);

        // Sanction attacker (spender)
        address[] memory addrs = new address[](1);
        addrs[0] = attacker;
        mockSanctions.addToSanctionsList(addrs);

        // Attacker tries to drain alice via transferFrom — should revert on spender check
        vm.prank(attacker);
        vm.expectRevert();
        t.transferFrom(alice, bob, 100e18);
    }

    // ── ISIN + maturity metadata (GYL-243) ───────────────────────────────────

    function test_deployToken_isinStoredCorrectly() public {
        (address token,,) = _deploy();
        assertEq(GyldBondToken(token).isin(), TEST_ISIN);
    }

    function test_deployToken_maturityStoredCorrectly() public {
        (address token,,) = _deploy();
        assertEq(GyldBondToken(token).maturityTimestamp(), TEST_MATURITY);
    }

    function test_predictTokenAddress_matchesDeployed() public {
        address predicted = factory.predictTokenAddress("Test Bond", "tBOND", TEST_ISIN, TEST_MATURITY);
        (address token,,) = _deploy();
        assertEq(predicted, token);
    }

    // ── Chainalysis bypass regression ─────────────────────────────────────────
    // No role — including DEFAULT_ADMIN — may bypass the Chainalysis sanctions
    // check on secondary transfers. These tests are permanent regression guards.

    function test_defaultAdmin_cannotBypassSanctions() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);

        vm.prank(address(issuanceMgr)); t.mint(alice, 1000e18);

        // Sanction alice
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        mockSanctions.addToSanctionsList(addrs);

        // address(this) holds DEFAULT_ADMIN_ROLE (factory owner) — transfer from alice must still revert
        vm.prank(alice);
        vm.expectRevert();
        t.transfer(bob, 100e18);

        // transferFrom via DEFAULT_ADMIN (address(this)) as spender must also revert
        vm.prank(alice); t.approve(address(this), 200e18);
        vm.prank(address(this));
        vm.expectRevert();
        t.transferFrom(alice, bob, 100e18);
    }

    function test_minterRole_cannotBypassSanctions() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);

        vm.prank(address(issuanceMgr)); t.mint(alice, 1000e18);

        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        mockSanctions.addToSanctionsList(addrs);

        // issuanceMgr holds MINTER_ROLE — secondary transfer from sanctioned alice reverts
        vm.prank(alice);
        vm.expectRevert();
        t.transfer(bob, 100e18);
    }

    function test_pauserRole_cannotBypassSanctions() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);

        vm.prank(address(issuanceMgr)); t.mint(operator, 1000e18);

        // Sanction operator (who holds PAUSER_ROLE)
        address[] memory addrs = new address[](1);
        addrs[0] = operator;
        mockSanctions.addToSanctionsList(addrs);

        // Sanctioned PAUSER_ROLE holder cannot transfer their own tokens
        vm.prank(operator);
        vm.expectRevert();
        t.transfer(bob, 100e18);
    }

    // ── M2: exclusive role holders ────────────────────────────────────────────

    function test_deployToken_exactlyOneHolderPerRole() public {
        (address token,,) = _deploy();
        GyldBondToken t = GyldBondToken(token);

        assertTrue(t.hasRole(t.MINTER_ROLE(), address(issuanceMgr)), "issuanceMgr must have MINTER_ROLE");
        assertFalse(t.hasRole(t.MINTER_ROLE(), address(factory)),    "factory must NOT have MINTER_ROLE");
        assertFalse(t.hasRole(t.MINTER_ROLE(), address(this)),       "deployer must NOT have MINTER_ROLE");
        assertFalse(t.hasRole(t.MINTER_ROLE(), operator),            "operator must NOT have MINTER_ROLE");
        assertFalse(t.hasRole(t.MINTER_ROLE(), navFeedOwner),        "navFeedOwner must NOT have MINTER_ROLE");

        assertTrue(t.hasRole(t.BURNER_ROLE(), address(issuanceMgr)), "issuanceMgr must have BURNER_ROLE");
        assertFalse(t.hasRole(t.BURNER_ROLE(), address(factory)),    "factory must NOT have BURNER_ROLE");
        assertFalse(t.hasRole(t.BURNER_ROLE(), address(this)),       "deployer must NOT have BURNER_ROLE");
        assertFalse(t.hasRole(t.BURNER_ROLE(), operator),            "operator must NOT have BURNER_ROLE");
        assertFalse(t.hasRole(t.BURNER_ROLE(), navFeedOwner),        "navFeedOwner must NOT have BURNER_ROLE");

        assertTrue(t.hasRole(t.PAUSER_ROLE(), operator),              "operator must have PAUSER_ROLE");
        assertFalse(t.hasRole(t.PAUSER_ROLE(), address(issuanceMgr)), "issuanceMgr must NOT have PAUSER_ROLE");
        assertFalse(t.hasRole(t.PAUSER_ROLE(), address(factory)),     "factory must NOT have PAUSER_ROLE");
        assertFalse(t.hasRole(t.PAUSER_ROLE(), address(this)),        "deployer must NOT have PAUSER_ROLE");
        assertFalse(t.hasRole(t.PAUSER_ROLE(), navFeedOwner),         "navFeedOwner must NOT have PAUSER_ROLE");

        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)),         "factory owner must have DEFAULT_ADMIN_ROLE");
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(factory)),     "factory must NOT have DEFAULT_ADMIN_ROLE");
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(issuanceMgr)), "issuanceMgr must NOT have DEFAULT_ADMIN_ROLE");
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), operator),             "operator must NOT have DEFAULT_ADMIN_ROLE");
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), navFeedOwner),         "navFeedOwner must NOT have DEFAULT_ADMIN_ROLE");
    }

    // ── M3: production deploy path — timelock as factory owner ───────────────

    function test_deployToken_timelockAsFactoryOwner_defaultAdminIsTimelock() public {
        address[] memory proposers = new address[](1);
        proposers[0] = address(this);
        address[] memory executors = new address[](1);
        executors[0] = address(this);
        TimelockController timelock = new TimelockController(1, proposers, executors, address(0));

        factory.transferOwnership(address(timelock));
        vm.prank(address(timelock));
        factory.acceptOwnership();
        assertEq(factory.owner(), address(timelock));

        vm.prank(address(timelock));
        (address token,,) = factory.deployToken(
            "Timelock Bond", "TLBOND", "US999999TL01", 0, operator, address(issuanceMgr), navFeedOwner
        );

        GyldBondToken t = GyldBondToken(token);
        assertTrue(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(timelock)), "timelock must have DEFAULT_ADMIN_ROLE");
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(this)),    "deployer must NOT have DEFAULT_ADMIN_ROLE");
        assertFalse(t.hasRole(t.DEFAULT_ADMIN_ROLE(), address(factory)), "factory must NOT have DEFAULT_ADMIN_ROLE");
    }

    // ── renounceOwnership is disabled (GLD-166) ──────────────────────────────

    /// The factory owns DEFAULT_ADMIN_ROLE on every deployed GyldBondToken, so
    /// renouncing would hand that governance authority to address(0) and permanently
    /// lose deployToken — with no upgrade path back.
    function test_renounceOwnership_ownerReverts() public {
        vm.prank(address(this));
        vm.expectRevert(TokenFactory.CannotRenounceOwnership.selector);
        factory.renounceOwnership();
        assertEq(factory.owner(), address(this), "owner must be unchanged");
    }

    /// Same error for a non-owner: the call can never succeed for anyone, so it
    /// must not report "not owner" and imply the owner could have done it.
    function test_renounceOwnership_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(TokenFactory.CannotRenounceOwnership.selector);
        factory.renounceOwnership();
        assertEq(factory.owner(), address(this), "owner must be unchanged");
    }

    /// Rotation must be unaffected by the guard: transfer + accept still works.
    function test_renounceOwnershipGuard_rotationStillWorks() public {
        factory.transferOwnership(bob);
        vm.prank(bob);
        factory.acceptOwnership();
        assertEq(factory.owner(), bob, "rotation must still work");
    }

    // ── re-entrancy guard ─────────────────────────────────────────────────────

    function test_deployToken_nonReentrant() public {
        TokenFactory malFactory = new TokenFactory(address(bondTokenImpl), address(mockSanctions), address(this));

        // Attacker owns the factory and acts as issuanceManager (has registerToken)
        ReentrantAttacker reentrancyAttacker = new ReentrantAttacker(address(malFactory), navFeedOwner);
        malFactory.transferOwnership(address(reentrancyAttacker));
        vm.prank(address(reentrancyAttacker));
        malFactory.acceptOwnership();

        // attack() calls deployToken which calls registerToken which re-enters deployToken
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        reentrancyAttacker.attack();
    }

    // ── fuzz: maturity timestamp ──────────────────────────────────────────────

    function testFuzz_deployToken_maturityTimestamp_anyValue(uint256 maturity) public {
        // Each fuzz iteration gets a fresh EVM snapshot, so reusing the same ISIN is safe.
        (address token,,) = factory.deployToken(
            "Fuzz Bond", "FZZ", "US999999FZ99", maturity, operator, address(issuanceMgr), navFeedOwner
        );
        assertEq(GyldBondToken(token).maturityTimestamp(), maturity);
    }

    // ── same operator, multiple tokens ───────────────────────────────────────

    function test_deployToken_sameOperator_multipleTokens_rolesCorrect() public {
        (address token1,,) = factory.deployToken(
            "Bond One", "BND1", "US000000SOM1", 0, operator, address(issuanceMgr), navFeedOwner
        );
        (address token2,,) = factory.deployToken(
            "Bond Two", "BND2", "US000000SOM2", 0, operator, address(issuanceMgr), navFeedOwner
        );

        GyldBondToken t1 = GyldBondToken(token1);
        GyldBondToken t2 = GyldBondToken(token2);

        // Both tokens: operator has PAUSER_ROLE
        assertTrue(t1.hasRole(t1.PAUSER_ROLE(), operator), "token1: operator must have PAUSER_ROLE");
        assertTrue(t2.hasRole(t2.PAUSER_ROLE(), operator), "token2: operator must have PAUSER_ROLE");

        // Factory has no roles on either token
        assertFalse(t1.hasRole(t1.DEFAULT_ADMIN_ROLE(), address(factory)), "token1: factory must not have DEFAULT_ADMIN_ROLE");
        assertFalse(t1.hasRole(t1.MINTER_ROLE(),        address(factory)), "token1: factory must not have MINTER_ROLE");
        assertFalse(t1.hasRole(t1.BURNER_ROLE(),        address(factory)), "token1: factory must not have BURNER_ROLE");
        assertFalse(t1.hasRole(t1.PAUSER_ROLE(),        address(factory)), "token1: factory must not have PAUSER_ROLE");
        assertFalse(t2.hasRole(t2.DEFAULT_ADMIN_ROLE(), address(factory)), "token2: factory must not have DEFAULT_ADMIN_ROLE");
        assertFalse(t2.hasRole(t2.MINTER_ROLE(),        address(factory)), "token2: factory must not have MINTER_ROLE");
        assertFalse(t2.hasRole(t2.BURNER_ROLE(),        address(factory)), "token2: factory must not have BURNER_ROLE");
        assertFalse(t2.hasRole(t2.PAUSER_ROLE(),        address(factory)), "token2: factory must not have PAUSER_ROLE");
    }

    // ── navFeedOf / forwarderOf are unique per token ──────────────────────────

    function test_navFeedOf_forwarderOf_uniquePerToken() public {
        (address token1, address navFeed1, address forwarder1) = factory.deployToken(
            "Bond A", "BNDA", "US000000UPT1", 0, operator, address(issuanceMgr), navFeedOwner
        );
        (address token2, address navFeed2, address forwarder2) = factory.deployToken(
            "Bond B", "BNDB", "US000000UPT2", 0, operator, address(issuanceMgr), navFeedOwner
        );
        (address token3, address navFeed3, address forwarder3) = factory.deployToken(
            "Bond C", "BNDC", "US000000UPT3", 0, operator, address(issuanceMgr), navFeedOwner
        );

        // All navFeed addresses are distinct and non-zero
        assertTrue(navFeed1 != address(0),   "navFeed1 must not be zero");
        assertTrue(navFeed2 != address(0),   "navFeed2 must not be zero");
        assertTrue(navFeed3 != address(0),   "navFeed3 must not be zero");
        assertTrue(navFeed1 != navFeed2,     "navFeed1 and navFeed2 must differ");
        assertTrue(navFeed1 != navFeed3,     "navFeed1 and navFeed3 must differ");
        assertTrue(navFeed2 != navFeed3,     "navFeed2 and navFeed3 must differ");

        // All forwarder addresses are distinct and non-zero
        assertTrue(forwarder1 != address(0), "forwarder1 must not be zero");
        assertTrue(forwarder2 != address(0), "forwarder2 must not be zero");
        assertTrue(forwarder3 != address(0), "forwarder3 must not be zero");
        assertTrue(forwarder1 != forwarder2, "forwarder1 and forwarder2 must differ");
        assertTrue(forwarder1 != forwarder3, "forwarder1 and forwarder3 must differ");
        assertTrue(forwarder2 != forwarder3, "forwarder2 and forwarder3 must differ");

        // Mappings are consistent with return values
        assertEq(factory.navFeedOf(token1),   navFeed1);
        assertEq(factory.navFeedOf(token2),   navFeed2);
        assertEq(factory.navFeedOf(token3),   navFeed3);
        assertEq(factory.forwarderOf(token1), forwarder1);
        assertEq(factory.forwarderOf(token2), forwarder2);
        assertEq(factory.forwarderOf(token3), forwarder3);
    }

    // ── bondSalt: different chainIds → different predicted addresses ──────────

    function test_bondSalt_differentChainIds_differentPredictedAddresses() public {
        string memory isin = "US912797KR72";
        address pred1 = factory.predictTokenAddress("Bond", "BND", isin, 0);
        vm.chainId(999);
        address pred2 = factory.predictTokenAddress("Bond", "BND", isin, 0);
        assertTrue(pred1 != pred2, "same ISIN must produce different addresses on different chains");
    }
}

// ── Unit tests for GyldBondToken paths not covered above ─────────────────────

contract GyldBondTokenUnitTest is Test {
    uint256 private constant WAD = 1e18;

    GyldBondToken     token;
    MockSanctionsList mockSanctions;

    address admin    = address(0xB0);
    address pauser   = address(0xB1);
    address minter   = address(0xB2);
    address burner   = address(0xB3);
    address alice    = address(0xC1);
    address bob      = address(0xC2);
    address outsider = address(0xFF);

    function setUp() public {
        mockSanctions = new MockSanctionsList(address(this));
        GyldBondToken impl = new GyldBondToken();
        token = GyldBondToken(address(new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldBondToken.initialize, (
                "Unit Bond", "UBOND", "US000000UNIT", 0,
                admin, pauser, address(mockSanctions)
            ))
        )));
        bytes32 minterRole = token.MINTER_ROLE();
        bytes32 burnerRole = token.BURNER_ROLE();
        vm.startPrank(admin);
        token.grantRole(minterRole, minter);
        token.grantRole(burnerRole, burner);
        vm.stopPrank();
    }

    function _sanction(address who) internal {
        address[] memory addrs = new address[](1);
        addrs[0] = who;
        mockSanctions.addToSanctionsList(addrs);
    }

    function _mint(address to, uint256 amount) internal {
        vm.prank(minter);
        token.mint(to, amount);
    }

    // ── Compliance — uncovered paths ──────────────────────────────────────────

    function test_transfer_blocksReceiver() public {
        _mint(alice, 1000e18);
        _sanction(bob);
        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, 100e18);
    }

    function test_transferFrom_blocksSender() public {
        _mint(alice, 1000e18);
        vm.prank(alice); token.approve(outsider, 500e18);
        _sanction(alice);
        vm.prank(outsider);
        vm.expectRevert();
        token.transferFrom(alice, bob, 100e18);
    }

    function test_transferFrom_blocksReceiver() public {
        _mint(alice, 1000e18);
        vm.prank(alice); token.approve(outsider, 500e18);
        _sanction(bob);
        vm.prank(outsider);
        vm.expectRevert();
        token.transferFrom(alice, bob, 100e18);
    }

    function test_initialize_zeroSanctionsList_reverts() public {
        GyldBondToken impl = new GyldBondToken();
        vm.expectRevert(GyldBondToken.ZeroAddress.selector);
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldBondToken.initialize, (
                "No Oracle Bond", "NOBOND", "US000000NONE", 0,
                admin, pauser, address(0)
            ))
        );
    }

    // ── setSanctionsList ──────────────────────────────────────────────────────

    function test_setSanctionsList_byAdmin_succeeds() public {
        address newOracle = address(new MockSanctionsList(address(this)));
        vm.expectEmit(true, false, false, false);
        emit SanctionsListUpdated(newOracle);
        vm.prank(admin);
        token.setSanctionsList(newOracle);
        assertEq(address(token.sanctionsList()), newOracle);
    }

    function test_setSanctionsList_byNonAdmin_reverts() public {
        address newOracle = address(new MockSanctionsList(address(this)));
        vm.prank(outsider);
        vm.expectRevert();
        token.setSanctionsList(newOracle);
    }

    function test_setSanctionsList_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(GyldBondToken.ZeroAddress.selector);
        token.setSanctionsList(address(0));
    }

    // ── Pause edge cases ──────────────────────────────────────────────────────

    function test_pause_byNonPauser_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        token.pause();
    }

    function test_approve_blockedWhenPaused() public {
        vm.prank(pauser); token.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.approve(bob, 100e18);
    }

    // ── mint/burn access control ──────────────────────────────────────────────

    function test_mint_zeroAddress_reverts() public {
        vm.prank(minter);
        vm.expectRevert(GyldBondToken.ZeroAddress.selector);
        token.mint(address(0), 100e18);
    }

    function test_burn_zeroAmount_reverts() public {
        _mint(alice, 100e18);
        vm.prank(burner);
        vm.expectRevert(GyldBondToken.ZeroAmount.selector);
        token.burn(alice, 0);
    }

    function test_burn_zeroAddress_reverts() public {
        vm.prank(burner);
        vm.expectRevert(GyldBondToken.ZeroAddress.selector);
        token.burn(address(0), 100e18);
    }

    // ── UUPS upgrade authorization ────────────────────────────────────────────

    function test_gyldBondToken_upgrade_byAdmin_succeeds() public {
        GyldBondToken newImpl = new GyldBondToken();
        vm.prank(admin);
        token.upgradeToAndCall(address(newImpl), "");
    }

    function test_gyldBondToken_upgrade_byOutsider_reverts() public {
        GyldBondToken newImpl = new GyldBondToken();
        vm.prank(outsider);
        vm.expectRevert();
        token.upgradeToAndCall(address(newImpl), "");
    }

    // ── approve when not paused ───────────────────────────────────────────────

    function test_approve_whenNotPaused_succeeds() public {
        vm.prank(alice);
        token.approve(bob, 100e18);
        assertEq(token.allowance(alice, bob), 100e18);
    }

    // ── permit — deadline exactly at 30-day boundary ──────────────────────────

    // ── Event declarations (mirrors GyldBondToken) ────────────────────────────

    event SanctionsListUpdated(address indexed newSanctionsList);
}

// ── Unit tests for MockSanctionsList ─────────────────────────────────────────

contract MockSanctionsListTest is Test {
    MockSanctionsList sanctions;
    address alice = address(0xA1);
    address bob   = address(0xA2);

    function setUp() public {
        sanctions = new MockSanctionsList(address(this));
    }

    function test_isSanctioned_falseByDefault() public view {
        assertFalse(sanctions.isSanctioned(alice));
    }

    // ── Access control (GYL-1135) ─────────────────────────────────────────────
    //
    // Every write function used to be plain `external`. Since GyldBondToken screening is
    // fail-closed and {DeployGuards.requireProdContract} cannot tell a mock from a real
    // oracle by code size, an ownerless mock reachable on any chain meant ANY address
    // could sanction ANY holder — a permissionless transfer freeze on every series.

    function test_owner_isTheConstructorArgument() public {
        assertEq(sanctions.owner(), address(this), "owner must be the constructor argument");
        assertEq(new MockSanctionsList(bob).owner(), bob, "owner must not be msg.sender");
    }

    function test_constructor_zeroOwnerReverts() public {
        vm.expectRevert(MockSanctionsList.ZeroOwner.selector);
        new MockSanctionsList(address(0));
    }

    function test_addToSanctionsList_nonOwnerReverts() public {
        address[] memory addrs = new address[](1);
        addrs[0] = bob;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockSanctionsList.NotOwner.selector, alice));
        sanctions.addToSanctionsList(addrs);
        assertFalse(sanctions.isSanctioned(bob), "a stranger sanctioned an address");
    }

    /// Un-sanctioning is just as privileged: a stranger who could clear the list would
    /// walk a designated address straight through compliance screening.
    function test_removeFromSanctionsList_nonOwnerReverts() public {
        address[] memory addrs = new address[](1);
        addrs[0] = bob;
        sanctions.addToSanctionsList(addrs);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockSanctionsList.NotOwner.selector, alice));
        sanctions.removeFromSanctionsList(addrs);
        assertTrue(sanctions.isSanctioned(bob), "a stranger un-sanctioned an address");
    }

    function test_setSanctioned_nonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockSanctionsList.NotOwner.selector, alice));
        sanctions.setSanctioned(bob, true);
        assertFalse(sanctions.isSanctioned(bob), "a stranger sanctioned an address");
    }

    /// An empty array is a no-op for the owner, but must still be refused for a stranger:
    /// the guard belongs on the function, not on whether it happens to write anything.
    function test_addToSanctionsList_emptyArray_nonOwnerStillReverts() public {
        address[] memory empty = new address[](0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockSanctionsList.NotOwner.selector, alice));
        sanctions.addToSanctionsList(empty);
    }

    function testFuzz_onlyOwnerCanSanction(address caller) public {
        vm.assume(caller != address(this));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(MockSanctionsList.NotOwner.selector, caller));
        sanctions.setSanctioned(bob, true);
    }

    function test_owner_canSanctionAndUnsanction() public {
        sanctions.setSanctioned(bob, true);
        assertTrue(sanctions.isSanctioned(bob));
        sanctions.setSanctioned(bob, false);
        assertFalse(sanctions.isSanctioned(bob));
    }

    function test_addToSanctionsList_emptyArray_noOp() public {
        address[] memory empty = new address[](0);
        sanctions.addToSanctionsList(empty); // must not revert
        assertFalse(sanctions.isSanctioned(alice));
    }

    function test_removeFromSanctionsList_nonSanctionedAddress_noOp() public {
        // alice was never sanctioned — removing is a no-op
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        sanctions.removeFromSanctionsList(addrs); // must not revert
        assertFalse(sanctions.isSanctioned(alice));
    }

    function test_removeFromSanctionsList_emptyArray_noOp() public {
        address[] memory empty = new address[](0);
        sanctions.removeFromSanctionsList(empty); // must not revert
    }

    function test_addThenRemove_isSanctioned_false() public {
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        sanctions.addToSanctionsList(addrs);
        assertTrue(sanctions.isSanctioned(alice));
        sanctions.removeFromSanctionsList(addrs);
        assertFalse(sanctions.isSanctioned(alice));
    }

    function testFuzz_isSanctioned_onlyAddedAddresses(address who) public {
        vm.assume(who != alice);
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        sanctions.addToSanctionsList(addrs);
        assertFalse(sanctions.isSanctioned(who), "only alice should be sanctioned");
    }
}

/// @dev A contract with no isSanctioned() — used to test the factory constructor oracle probe.
contract MockWrongSanctionsList {}
