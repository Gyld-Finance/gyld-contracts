// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockNavForwarder} from "./MockNavForwarder.sol";

/// @dev Halmos symbolic-value cheatcodes live at the dedicated SVM address — NOT
///      the forge-std HEVM address (halmos 0.3.3, halmos/cheatcodes.py:
///      `halmos_cheat_code.address = bytes20(uint160(uint256(keccak256("svm cheat code"))))`).
interface SVM {
    function createUint(uint256 bits, string calldata name) external returns (uint256);
    function createUint256(string calldata name) external returns (uint256);
    function createAddress(string calldata name) external returns (address);
}

/// @dev Halmos 0.3.3 storage-decode workaround (halmos `SolidityStorage`/`GenericStorage`
///      `decode`). solc constant-folds `keccak256(abi.encode(role, baseSlot))` when `role`
///      is a COMPILE-TIME constant — e.g. `_grantRole(DEFAULT_ADMIN_ROLE, admin)` inside
///      OZ `AccessControlUpgradeable` initializers — so that inner SHA3 opcode never
///      executes and halmos never registers it in its `KeccakRegistry`. The same logical
///      slot later reached through a RUNTIME role variable (`grantRole`'s
///      `getRoleAdmin(role)`) executes the inner SHA3, registers it, and decodes the
///      outer slot to a DIFFERENT structural key — the read then misses the write
///      (spurious `AccessControlUnauthorizedAccount` in setUp).
///
///      Forcing ONE runtime evaluation of `keccak256(abi.encode(role, base))` per
///      constant role BEFORE any proxy initializer runs registers the inner hash, so
///      every subsequent access (constant- or variable-role) decodes identically.
///      The cross-contract call is essential: arguments are opaque to the optimizer,
///      so the SHA3 cannot be constant-folded here either. Semantically a no-op
///      (pure keccak over constants); `forge test` never executes it (no test* fns).
contract Sha3Warmer {
    function warm(bytes32 a, bytes32 b) external pure returns (bytes32) {
        return keccak256(abi.encode(a, b));
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Halmos symbolic-verification suite for the core economic invariants of
// GyldAtomicSwap (docs/atomic-swap-spec.md §8: I-1, I-2, I-3, I-10, I-11).
//
// Functions use the check_ prefix: `forge test` ignores them (it only runs
// test*), halmos runs them (its default --function prefix is (check|invariant)_).
//
// ECDSA modelling note: quotes are signed with a CONCRETE private key over
// CONCRETE SwapMessage fields (exactly like the unit-test helpers), so the
// EIP-712 digest is fully concrete. Halmos models the resulting (v, r, s)
// abstractly but soundly — vm.sign constrains ecrecover(digest, v, r, s) ==
// vm.addr(key) — so the contract's own ECDSA.recover resolves to the
// registered QUOTE_SIGNER_ROLE holder on every explored path. We assume a
// low-s signature: the high-s malleable counterpart reverts in OZ ECDSA, which
// would otherwise show up as a spurious reverting path in the success checks.
// Only the taker's draw size (requestedAmountIn) and, for the replay check,
// the second-call caller are symbolic.
// ─────────────────────────────────────────────────────────────────────────────
contract GyldAtomicSwapHalmosTest is Test {
    SVM constant svm = SVM(address(0xF3993A62377BCd56AE39D773740A5390411E8BC9));

    GyldAtomicSwap swap;
    GyldBondToken token;
    MockUSDC usdc;
    MockNavForwarder navFeed;
    MockSanctionsList mockSanctions;

    address admin = address(0xA0);
    address pauser = address(0xA1);
    address treasurer = address(0xA2);
    address wallet = address(0xA3);
    address allowlistAdmin = address(0xA4);
    address outsider = address(0xFF);

    // Taker is CONCRETE: no private key is needed (MockUSDC has no permit and the
    // swap's optional permit path is skipped with value == 0). A concrete taker
    // keeps every mapping lookup on the execution path concrete.
    address taker = address(0x1111111111111111111111111111111111111111);

    uint256 constant SIGNER_PK = 0x516E5;
    address signer; // vm.addr(SIGNER_PK) — abstract but consistent under halmos

    int256 constant NAV = 100e8; // $100.00/token, 8dp
    uint16 constant MAX_BPS = 200; // ±2%
    uint32 constant MAX_NAV_AGE = 1 days;

    // Pinned to GyldAtomicSwap.MIN_DRAW_BPS / BPS_DENOMINATOR (contract constants).
    uint256 constant MIN_DRAW_BPS = 100;
    uint256 constant BPS = 10_000;

    // OZ ECDSA.recover malleability bound: s must be <= (secp256k1n - 1) / 2.
    uint256 constant LOW_S_MAX = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    function setUp() public {
        _preWarmSha3Registry(); // MUST run before any proxy initializer — see Sha3Warmer

        vm.warp(1_750_000_000);
        signer = vm.addr(SIGNER_PK);
        vm.assume(signer != address(0)); // prunes the ECDSAInvalidSignature branch

        mockSanctions = new MockSanctionsList(address(this));
        usdc = new MockUSDC();
        navFeed = new MockNavForwarder(NAV);

        GyldBondToken tokenImpl = new GyldBondToken();
        token = GyldBondToken(
            address(
                new ERC1967Proxy(
                    address(tokenImpl),
                    abi.encodeCall(
                        GyldBondToken.initialize,
                        (
                            "Gyld US Treasury Bond 2026-06",
                            "GYLD-UST-2606",
                            "US912797KR72",
                            1_780_000_000,
                            admin,
                            pauser,
                            address(mockSanctions)
                        )
                    )
                )
            )
        );

        swap = _deploySwap(address(usdc));

        vm.prank(admin);
        swap.registerSeries(address(token), address(navFeed));

        // MINTER_ROLE tops up inventory.
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin);
        token.grantRole(minterRole, address(this));

        token.mint(address(swap), 1_000e18);
        token.mint(taker, 100e18);
        usdc.mint(taker, 1_000_000e6);
        usdc.mint(address(swap), 100_000e6);

        vm.startPrank(taker);
        usdc.approve(address(swap), type(uint256).max);
        token.approve(address(swap), type(uint256).max);
        vm.stopPrank();
    }

    // ── Helpers (mirrored from GyldAtomicSwap.spec.t.sol) ─────────────────────

    /// Register every constant-role inner mapping hash used by the OZ
    /// AccessControlUpgradeable instances behind the two ERC1967 proxies, so the
    /// constant-folded `_grantRole` writes inside `initialize` and any
    /// variable-role reads (`grantRole`) decode storage identically (halmos
    /// 0.3.3 workaround — see Sha3Warmer). The base slot is OZ's ERC-7201
    /// `erc7201:openzeppelin.storage.AccessControl`, shared by both proxies.
    function _preWarmSha3Registry() internal {
        bytes32 acBase = 0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800;
        Sha3Warmer warmer = new Sha3Warmer();
        warmer.warm(bytes32(0), acBase); // DEFAULT_ADMIN_ROLE
        warmer.warm(keccak256("QUOTE_SIGNER_ROLE"), acBase);
        warmer.warm(keccak256("TREASURER_ROLE"), acBase);
        warmer.warm(keccak256("PAUSER_ROLE"), acBase);
        warmer.warm(keccak256("ALLOWLIST_ADMIN_ROLE"), acBase);
        warmer.warm(keccak256("MINTER_ROLE"), acBase);
        warmer.warm(keccak256("BURNER_ROLE"), acBase);
    }

    /// Deploy + wire a fresh swap proxy over `cashToken`; withdrawalWallet set;
    /// `taker` allowlisted. (Series registration is done by the caller.)
    function _deploySwap(address cashToken) internal returns (GyldAtomicSwap s) {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        s = GyldAtomicSwap(
            address(
                new ERC1967Proxy(
                    address(impl),
                    abi.encodeCall(
                        GyldAtomicSwap.initialize,
                        (admin, pauser, signer, treasurer, cashToken, MAX_BPS, MAX_NAV_AGE)
                    )
                )
            )
        );
        bytes32 allowlistRole = s.ALLOWLIST_ADMIN_ROLE();
        vm.startPrank(admin);
        s.setWithdrawalWallet(wallet);
        s.grantRole(allowlistRole, allowlistAdmin);
        vm.stopPrank();
        vm.prank(allowlistAdmin);
        s.setAllowed(taker, true);
    }

    /// BUY at exactly NAV: 10 bond tokens per 1_000 USDC (price = 1e28).
    function _buyQuote(uint256 quoteId, uint256 maxAmountIn)
        internal
        view
        returns (GyldAtomicSwap.SwapMessage memory)
    {
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(usdc),
            maxAmountIn: maxAmountIn,
            tokenOut: address(token),
            price: 1e28,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
    }

    /// REDEEM at exactly NAV: 1_000 USDC per 10 bond tokens (price = 100e6).
    function _redeemQuote(uint256 quoteId, uint256 maxAmountIn)
        internal
        view
        returns (GyldAtomicSwap.SwapMessage memory)
    {
        return GyldAtomicSwap.SwapMessage({
            quoteId: quoteId,
            taker: taker,
            tokenIn: address(token),
            maxAmountIn: maxAmountIn,
            tokenOut: address(usdc),
            price: 100e6,
            expiry: uint64(block.timestamp + 15 minutes),
            epoch: 0
        });
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    /// Concrete key over a concrete message — halmos abstracts (v, r, s) but
    /// constrains ecrecover(digest, v, r, s) == signer (see header note).
    function _sign(GyldAtomicSwap.SwapMessage memory m) internal returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(SIGNER_PK, swap.hashSwapMessage(m));
        vm.assume(uint256(s_) <= LOW_S_MAX); // prune the correctly-reverting high-s branch
        return abi.encodePacked(r, s_, v);
    }

    function _minDraw(uint256 maxAmountIn) internal pure returns (uint256) {
        return (maxAmountIn * MIN_DRAW_BPS) / BPS;
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 1. I-3 — draw-range enforcement
    // ═════════════════════════════════════════════════════════════════════════

    /// For ANY requestedAmountIn outside [maxAmountIn * MIN_DRAW_BPS / 10_000,
    /// maxAmountIn], executeSwap reverts and the quoteId is NOT burned (I-9
    /// corollary). The range check (step 5 of §4) precedes signature recovery,
    /// so every out-of-range path reverts regardless of the signature.
    function check_executeSwap_outOfRangeDraw_alwaysReverts() public {
        uint256 maxAmountIn = 1_000e6;
        uint256 minAllowed = _minDraw(maxAmountIn);

        uint256 requestedAmountIn = svm.createUint256("requestedAmountIn");
        vm.assume(requestedAmountIn < minAllowed || requestedAmountIn > maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1, maxAmountIn);
        bytes memory sig = _sign(m);

        vm.prank(taker);
        (bool ok,) = address(swap).call(
            abi.encodeCall(GyldAtomicSwap.executeSwap, (m, sig, _noPermit(), requestedAmountIn))
        );

        assertFalse(ok);
        assertFalse(swap.isQuoteUsed(1));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 2. I-1 / I-10 — conservation + solvency + quote consumption (BUY)
    // ═════════════════════════════════════════════════════════════════════════

    /// A successful BUY moves exactly requestedAmountIn of USDC taker → swap and
    /// exactly floor(requestedAmountIn * price / 1e18) of bond tokens swap →
    /// taker. Fixture is solvent for every in-range draw (max payout 10e18 of
    /// 1_000e18 inventory), so success on every path is itself the I-1 proof.
    /// Total supplies are unchanged and no third party's balance moves (I-10).
    function check_executeSwap_buy_conservationAndSolvency() public {
        uint256 maxAmountIn = 1_000e6;
        uint256 minAllowed = _minDraw(maxAmountIn);

        uint256 requestedAmountIn = svm.createUint256("requestedAmountIn");
        vm.assume(requestedAmountIn >= minAllowed && requestedAmountIn <= maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(2, maxAmountIn);
        bytes memory sig = _sign(m);
        uint256 expectedOut = (requestedAmountIn * m.price) / 1e18;

        uint256 takerUsdcBefore = usdc.balanceOf(taker);
        uint256 swapUsdcBefore = usdc.balanceOf(address(swap));
        uint256 takerBondBefore = token.balanceOf(taker);
        uint256 swapBondBefore = token.balanceOf(address(swap));
        uint256 usdcSupplyBefore = usdc.totalSupply();
        uint256 bondSupplyBefore = token.totalSupply();

        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        // Exact two-party deltas; swapBondBefore - expectedOut >= 0 is the
        // solvency statement (I-1): the payout can never exceed inventory.
        assertEq(usdc.balanceOf(taker), takerUsdcBefore - requestedAmountIn);
        assertEq(usdc.balanceOf(address(swap)), swapUsdcBefore + requestedAmountIn);
        assertEq(token.balanceOf(taker), takerBondBefore + expectedOut);
        assertEq(token.balanceOf(address(swap)), swapBondBefore - expectedOut);

        // Never-mints and no third party touched (I-10).
        assertEq(usdc.totalSupply(), usdcSupplyBefore);
        assertEq(token.totalSupply(), bondSupplyBefore);
        assertEq(usdc.balanceOf(outsider), 0);
        assertEq(token.balanceOf(outsider), 0);

        // Single-use quoteId consumed on success (I-2 forward direction).
        assertTrue(swap.isQuoteUsed(2));
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 3. I-2 — replay protection
    // ═════════════════════════════════════════════════════════════════════════

    /// After one successful (concrete, full-size) execution, ANY second
    /// executeSwap of the same quoteId reverts — for ANY caller (symbolic,
    /// including the taker itself) and ANY requestedAmountIn (symbolic, full
    /// uint256 range, in-range or not).
    function check_executeSwap_replayedQuote_alwaysReverts() public {
        uint256 maxAmountIn = 1_000e6;
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(3, maxAmountIn);
        bytes memory sig = _sign(m);

        // First draw: concrete and full-size; must succeed.
        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), maxAmountIn);
        assertTrue(swap.isQuoteUsed(3));

        // Second draw: symbolic caller + symbolic size; must revert on all paths.
        address caller = svm.createAddress("caller");
        uint256 requestedAmountIn = svm.createUint256("requestedAmountIn2");

        vm.prank(caller);
        (bool ok,) = address(swap).call(
            abi.encodeCall(GyldAtomicSwap.executeSwap, (m, sig, _noPermit(), requestedAmountIn))
        );

        assertFalse(ok);
    }

    // ═════════════════════════════════════════════════════════════════════════
    // 4. I-11 (§5.4) — price-floor rounding (REDEEM, where dust actually exists)
    // ═════════════════════════════════════════════════════════════════════════

    /// The USDC paid out on a REDEEM is exactly floor(requestedAmountIn * price
    /// / 1e18): the largest integer q with q * 1e18 <= requestedAmountIn * price.
    /// At price = 100e6 the product is not generally divisible by 1e18, so the
    /// floor genuinely bites. The observed balance delta is pinned both to the
    /// Solidity expression and, independently, to the mathematical floor bounds.
    function check_executeSwap_redeem_amountOutIsExactFloor() public {
        uint256 maxAmountIn = 10e18;
        uint256 minAllowed = _minDraw(maxAmountIn);

        uint256 requestedAmountIn = svm.createUint256("requestedAmountIn");
        vm.assume(requestedAmountIn >= minAllowed && requestedAmountIn <= maxAmountIn);

        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(4, maxAmountIn);
        bytes memory sig = _sign(m);

        uint256 takerBondBefore = token.balanceOf(taker);
        uint256 swapBondBefore = token.balanceOf(address(swap));
        uint256 takerUsdcBefore = usdc.balanceOf(taker);
        uint256 swapUsdcBefore = usdc.balanceOf(address(swap));

        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit(), requestedAmountIn);

        uint256 paidOut = swapUsdcBefore - usdc.balanceOf(address(swap));
        uint256 product = requestedAmountIn * m.price; // <= 1e27 — no overflow

        // Bond leg moves exactly requestedAmountIn.
        assertEq(token.balanceOf(address(swap)), swapBondBefore + requestedAmountIn);
        assertEq(token.balanceOf(taker), takerBondBefore - requestedAmountIn);

        // USDC leg: the taker gains exactly what the pot loses, and that value
        // is THE floor of product / 1e18 (never more, never less — I-11).
        assertEq(usdc.balanceOf(taker) - takerUsdcBefore, paidOut);
        assertEq(paidOut, product / 1e18);
        assertLe(paidOut * 1e18, product);
        assertLt(product, (paidOut + 1) * 1e18);

        assertTrue(swap.isQuoteUsed(4));
    }

}
