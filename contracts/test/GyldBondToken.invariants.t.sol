// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {GyldBondToken} from "../GyldBondToken.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Handler: wraps GyldBondToken actions for the invariant fuzzer.
// All state transitions go through this contract so the fuzzer can find
// counter-examples across arbitrary sequences of mint / burn / transfer.
// ─────────────────────────────────────────────────────────────────────────────
contract TokenHandler is CommonBase, StdCheats, StdUtils {
    GyldBondToken public token;

    address[4] public actors;

    constructor(GyldBondToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function mint(uint256 actorSeed, uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        address to = actors[actorSeed % actors.length];
        token.mint(to, amount);
    }

    function burn(uint256 actorSeed, uint256 amount) external {
        address from = actors[actorSeed % actors.length];
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        token.burn(from, amount);
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = actors[fromSeed % actors.length];
        address to   = actors[toSeed   % actors.length];
        if (from == to) return;
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(from);
        token.transfer(to, amount);
    }

    function actorList() external view returns (address[4] memory) {
        return actors;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Invariant test contract
// ─────────────────────────────────────────────────────────────────────────────
contract GyldBondTokenInvariantsTest is StdInvariant, Test {
    GyldBondToken token;
    TokenHandler  handler;

    address alice = address(0xA1);
    address bob   = address(0xA2);
    address carol = address(0xA3);
    address dave  = address(0xA4);

    function setUp() public {
        MockSanctionsList mockSanctions = new MockSanctionsList();

        GyldBondToken tokenImpl = new GyldBondToken();
        bytes memory tokenInit = abi.encodeCall(
            GyldBondToken.initialize,
            ("Test Bond", "TBOND", "US000000TEST", 0, address(this), address(this), address(mockSanctions))
        );
        token = GyldBondToken(address(new ERC1967Proxy(address(tokenImpl), tokenInit)));

        address[4] memory actors_ = [alice, bob, carol, dave];
        handler = new TokenHandler(token, actors_);

        token.grantRole(token.MINTER_ROLE(), address(handler));
        token.grantRole(token.BURNER_ROLE(), address(handler));

        // Seed initial balances.
        token.grantRole(token.MINTER_ROLE(), address(this));
        token.mint(alice, 1_000e18);
        token.mint(bob,     500e18);
        token.mint(carol,   250e18);
        token.revokeRole(token.MINTER_ROLE(), address(this));

        targetContract(address(handler));
    }

    // ── Invariant: supply accounting ──────────────────────────────────────────

    /// totalSupply equals the exact sum of every actor's balance (no rounding).
    function invariant_totalSupply_eq_sumOfBalances() external view {
        address[4] memory actors_ = handler.actorList();
        uint256 sum;
        for (uint256 i; i < actors_.length; ++i) {
            sum += token.balanceOf(actors_[i]);
        }
        assertEq(token.totalSupply(), sum, "totalSupply != sum(balances)");
    }

    /// totalSupply is always non-zero while any actor holds tokens.
    function invariant_totalSupply_gte_anyBalance() external view {
        address[4] memory actors_ = handler.actorList();
        for (uint256 i; i < actors_.length; ++i) {
            assertLe(token.balanceOf(actors_[i]), token.totalSupply(), "balance > totalSupply");
        }
    }

    /// Sum of balances never exceeds totalSupply.
    function invariant_sumOfBalances_lte_totalSupply() external view {
        address[4] memory actors_ = handler.actorList();
        uint256 sum;
        for (uint256 i; i < actors_.length; ++i) {
            sum += token.balanceOf(actors_[i]);
        }
        assertLe(sum, token.totalSupply(), "sum(balances) > totalSupply");
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Fuzz tests — random inputs over isolated execution paths
// ─────────────────────────────────────────────────────────────────────────────
contract GyldBondTokenFuzzTest is Test {
    GyldBondToken token;
    MockSanctionsList mockSanctions;

    address minter = address(0xF1);
    address burner = address(0xF2);
    address alice  = address(0xA1);
    address bob    = address(0xA2);

    function setUp() public {
        mockSanctions = new MockSanctionsList();

        GyldBondToken tokenImpl = new GyldBondToken();
        bytes memory tokenInit = abi.encodeCall(
            GyldBondToken.initialize,
            ("Fuzz Bond", "FZBOND", "US000000FUZZ", 0, address(this), address(this), address(mockSanctions))
        );
        token = GyldBondToken(address(new ERC1967Proxy(address(tokenImpl), tokenInit)));

        token.grantRole(token.MINTER_ROLE(), minter);
        token.grantRole(token.BURNER_ROLE(), burner);
    }

    // ── Supply accounting ─────────────────────────────────────────────────────

    /// mint(to, amount) increases totalSupply and balanceOf(to) by exactly amount.
    function testFuzz_mint_exactSupplyIncrease(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        uint256 supplyBefore = token.totalSupply();
        uint256 balBefore    = token.balanceOf(alice);

        vm.prank(minter);
        token.mint(alice, amount);

        assertEq(token.totalSupply(),       supplyBefore + amount, "totalSupply wrong after mint");
        assertEq(token.balanceOf(alice),    balBefore    + amount, "balanceOf wrong after mint");
    }

    /// mint then burn the same amount leaves balances and totalSupply unchanged.
    function testFuzz_mintBurn_roundTrip(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(minter); token.mint(alice, amount);
        vm.prank(burner); token.burn(alice, amount);

        assertEq(token.totalSupply(),    supplyBefore, "totalSupply changed after roundtrip");
        assertEq(token.balanceOf(alice), 0,            "balance non-zero after full burn");
    }

    /// Multiple mints then burning all results in zero balance and restored supply.
    function testFuzz_multiMint_burnAll(uint256 a, uint256 b) external {
        a = bound(a, 1, 500_000e18);
        b = bound(b, 1, 500_000e18);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(minter); token.mint(alice, a);
        vm.prank(minter); token.mint(alice, b);

        vm.prank(burner); token.burn(alice, a + b);

        assertEq(token.balanceOf(alice), 0,            "shares remain after full burn");
        assertEq(token.totalSupply(),    supplyBefore, "totalSupply not restored");
    }

    /// transfer conserves totalSupply and moves exactly amount from sender to receiver.
    function testFuzz_transfer_conservesSupply(uint256 mintAmt, uint256 transferAmt) external {
        mintAmt     = bound(mintAmt,     1e6, 1_000_000e18);
        transferAmt = bound(transferAmt, 1,   mintAmt);

        vm.prank(minter); token.mint(alice, mintAmt);
        uint256 supplyBefore = token.totalSupply();
        uint256 aliceBefore  = token.balanceOf(alice);
        uint256 bobBefore    = token.balanceOf(bob);

        vm.prank(alice); token.transfer(bob, transferAmt);

        assertEq(token.totalSupply(),    supplyBefore,               "totalSupply changed by transfer");
        assertEq(token.balanceOf(alice), aliceBefore - transferAmt,  "alice balance wrong");
        assertEq(token.balanceOf(bob),   bobBefore   + transferAmt,  "bob balance wrong");
    }

    // ── Sanctions compliance ──────────────────────────────────────────────────

    /// A sanctioned sender cannot transfer tokens.
    function testFuzz_sanctions_blockSender(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(minter); token.mint(alice, amount);

        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        mockSanctions.addToSanctionsList(addrs);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, amount);
    }

    /// A sanctioned receiver cannot receive tokens.
    function testFuzz_sanctions_blockReceiver(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(minter); token.mint(alice, amount);

        address[] memory addrs = new address[](1);
        addrs[0] = bob;
        mockSanctions.addToSanctionsList(addrs);

        vm.prank(alice);
        vm.expectRevert();
        token.transfer(bob, amount);
    }

    /// Mint and burn are unaffected by sanctions (IssuanceManager pre-screens off-chain).
    function testFuzz_sanctions_doNotBlockMintBurn(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        address[] memory addrs = new address[](1);
        addrs[0] = alice;
        mockSanctions.addToSanctionsList(addrs);

        // Mint and burn must succeed even when alice is sanctioned.
        vm.prank(minter); token.mint(alice, amount);
        assertEq(token.balanceOf(alice), amount);

        vm.prank(burner); token.burn(alice, amount);
        assertEq(token.balanceOf(alice), 0);
    }

    // ── Permit ────────────────────────────────────────────────────────────────

    /// permit() with deadline strictly before block.timestamp must always revert.
    function testFuzz_permit_expiredDeadline(uint256 deadline) external {
        vm.assume(block.timestamp > 0);
        deadline = bound(deadline, 0, block.timestamp - 1);
        vm.expectRevert();
        token.permit(alice, bob, 100e18, deadline, 0, bytes32(0), bytes32(0));
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    /// Transfers revert while the contract is paused.
    function testFuzz_pause_blocksTransfer(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(minter); token.mint(alice, amount);

        token.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        token.transfer(bob, amount);
    }

    /// Transfers resume after unpause.
    function testFuzz_unpause_restoresTransfer(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);
        vm.prank(minter); token.mint(alice, amount);

        token.pause();
        token.unpause();

        vm.prank(alice); token.transfer(bob, amount);
        assertEq(token.balanceOf(bob), amount);
    }

    // ── NAV model verification ────────────────────────────────────────────────

    /// Token balance is always exactly what was minted — no hidden accrual on-chain.
    /// Value appreciation is reflected in the NAV feed, not in balanceOf.
    function testFuzz_balance_exactlyWhatWasMinted(uint256 amount) external {
        amount = bound(amount, 1, 1_000_000e18);

        vm.prank(minter); token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount,
            "balanceOf must equal minted amount: value lives in NAV feed, not balance");
    }
}
