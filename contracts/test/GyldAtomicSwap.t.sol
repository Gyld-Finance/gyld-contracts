// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {GyldAtomicSwap} from "../GyldAtomicSwap.sol";
import {GyldSettlementVault} from "../GyldSettlementVault.sol";
import {GyldBondToken} from "../GyldBondToken.sol";
import {MockSanctionsList} from "./MockSanctionsList.sol";
import {MockUSDC} from "./MockUSDC.sol";
import {MockUSDCPermit} from "./MockUSDCPermit.sol";
import {MockNavForwarder} from "./MockNavForwarder.sol";

contract GyldAtomicSwapTest is Test {
    // Mirror events for vm.expectEmit (test pragma predates ContractName.Event syntax)
    event SwapExecuted(
        uint256 indexed quoteId,
        address indexed taker,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    );
    event QuoteEpochBumped(uint64 indexed newEpoch);
    event VaultUpdated(address indexed previousVault, address indexed newVault);

    GyldAtomicSwap      swap;
    GyldSettlementVault vault;
    GyldBondToken       token;
    MockUSDCPermit      usdc;
    MockNavForwarder    navFeed;
    MockSanctionsList   mockSanctions;

    address admin       = address(0xA0); // DEFAULT_ADMIN_ROLE on swap + vault
    address pauser      = address(0xA1); // PAUSER_ROLE on swap + vault
    address treasurer   = address(0xA2); // TREASURER_ROLE on vault (unused here)
    address issuanceMgr = address(0x1111); // burn-commitment destination (plain address)
    address outsider    = address(0xFF);

    // Known private keys — vm.addr(PK) is the corresponding address.
    // SIGNER_PK signs SwapMessages (QUOTE_SIGNER_ROLE); TAKER_PK signs permits.
    uint256 constant SIGNER_PK = 0x516E5;
    uint256 constant TAKER_PK  = 0xA11CE;
    address          signer;
    address          taker;

    // NAV $100.00 per token (8dp): 1e18 token ⇔ 100e6 USDC. The standard quote
    // below (10 tokens for 1_000 USDC) sits exactly on NAV — inside the 2% band.
    int256 constant NAV = 100e8;

    bytes32 constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    function setUp() public {
        vm.warp(1_750_000_000); // realistic timestamp so expiry math is meaningful
        signer = vm.addr(SIGNER_PK);
        taker  = vm.addr(TAKER_PK);

        mockSanctions = new MockSanctionsList();
        usdc          = new MockUSDCPermit();
        navFeed       = new MockNavForwarder(NAV);

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

        // ── GyldSettlementVault proxy ─────────────────────────────────────────
        GyldSettlementVault vaultImpl = new GyldSettlementVault();
        vault = GyldSettlementVault(address(new ERC1967Proxy(
            address(vaultImpl),
            abi.encodeCall(GyldSettlementVault.initialize, (
                admin, pauser, treasurer, address(usdc), issuanceMgr
            ))
        )));

        // ── GyldAtomicSwap proxy ──────────────────────────────────────────────
        GyldAtomicSwap swapImpl = new GyldAtomicSwap();
        swap = GyldAtomicSwap(address(new ERC1967Proxy(
            address(swapImpl),
            abi.encodeCall(GyldAtomicSwap.initialize, (admin, pauser, signer, address(vault)))
        )));

        // Wire: vault recognises the swap (grants SWAP_ROLE) + values the series.
        vm.prank(admin); vault.setSwap(address(swap));
        vm.prank(admin); vault.registerSeries(address(token), address(navFeed));

        // Fund both sides. Inventory is minted straight to the vault (stands in
        // for the IssuanceManager.subscribe mint-at-fill path).
        bytes32 minterRole = token.MINTER_ROLE();
        vm.prank(admin); token.grantRole(minterRole, address(this));
        token.mint(address(vault), 1_000e18);
        token.mint(taker, 100e18);
        usdc.mint(taker, 1_000_000e6);
        usdc.mint(address(vault), 100_000e6);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /// BUY: taker pays 1_000 USDC, receives 10 bond tokens (exactly at NAV).
    function _buyQuote(uint256 quoteId) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId:   quoteId,
            taker:     taker,
            tokenIn:   address(usdc),
            amountIn:  1_000e6,
            tokenOut:  address(token),
            amountOut: 10e18,
            expiry:    uint64(block.timestamp + 15 minutes),
            epoch:     0
        });
    }

    /// REDEEM: taker pays 10 bond tokens, receives 1_000 USDC (exactly at NAV).
    function _redeemQuote(uint256 quoteId) internal view returns (GyldAtomicSwap.SwapMessage memory) {
        return GyldAtomicSwap.SwapMessage({
            quoteId:   quoteId,
            taker:     taker,
            tokenIn:   address(token),
            amountIn:  10e18,
            tokenOut:  address(usdc),
            amountOut: 1_000e6,
            expiry:    uint64(block.timestamp + 15 minutes),
            epoch:     0
        });
    }

    function _sign(GyldAtomicSwap.SwapMessage memory m, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, swap.hashSwapMessage(m));
        return abi.encodePacked(r, s, v);
    }

    function _noPermit() internal pure returns (GyldAtomicSwap.PermitData memory) {
        return GyldAtomicSwap.PermitData(0, 0, 0, bytes32(0), bytes32(0));
    }

    /// EIP-2612 permit signed by the taker for `asset`, spender = the swap contract.
    /// Works for both MockUSDCPermit and GyldBondToken (standard Permit typehash).
    function _signPermit(address asset, uint256 value, uint256 deadline)
        internal
        view
        returns (GyldAtomicSwap.PermitData memory)
    {
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH, taker, address(swap), value, IERC20Permit(asset).nonces(taker), deadline
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", IERC20Permit(asset).DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(TAKER_PK, digest);
        return GyldAtomicSwap.PermitData(value, deadline, v, r, s);
    }

    // ── Happy path: BUY (USDC in via permit, bond token out) ──────────────────

    function test_executeSwap_buy_withPermit_succeeds() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(1);
        bytes memory sig = _sign(m, SIGNER_PK);
        GyldAtomicSwap.PermitData memory p = _signPermit(address(usdc), 1_000e6, block.timestamp + 15 minutes);

        vm.expectEmit(true, true, false, true, address(swap));
        emit SwapExecuted(1, taker, address(usdc), 1_000e6, address(token), 10e18);

        vm.prank(taker);
        swap.executeSwap(m, sig, p);

        assertEq(usdc.balanceOf(taker),          1_000_000e6 - 1_000e6, "taker USDC not debited");
        assertEq(usdc.balanceOf(address(vault)), 100_000e6 + 1_000e6,   "vault USDC not credited");
        assertEq(token.balanceOf(taker),          100e18 + 10e18,       "taker tokens not credited");
        assertEq(token.balanceOf(address(vault)), 1_000e18 - 10e18,     "vault inventory not debited");
        assertEq(usdc.allowance(taker, address(swap)), 0, "permit allowance not fully consumed");
        assertTrue(swap.isQuoteUsed(1), "quoteId not consumed");
    }

    /// permitIn.value == 0 skips the permit — a plain pre-approval works too.
    function test_executeSwap_buy_withAllowance_succeeds() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(2);
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        usdc.approve(address(swap), 1_000e6);

        vm.prank(taker);
        swap.executeSwap(m, sig, _noPermit());

        assertEq(token.balanceOf(taker), 100e18 + 10e18);
        assertEq(usdc.balanceOf(address(vault)), 100_000e6 + 1_000e6);
    }

    // ── Happy path: REDEEM (bond token in via GyldBondToken permit, USDC out) ─

    function test_executeSwap_redeem_withBondPermit_succeeds() public {
        GyldAtomicSwap.SwapMessage memory m = _redeemQuote(3);
        bytes memory sig = _sign(m, SIGNER_PK);
        GyldAtomicSwap.PermitData memory p = _signPermit(address(token), 10e18, block.timestamp + 15 minutes);

        vm.expectEmit(true, true, false, true, address(swap));
        emit SwapExecuted(3, taker, address(token), 10e18, address(usdc), 1_000e6);

        vm.prank(taker);
        swap.executeSwap(m, sig, p);

        assertEq(token.balanceOf(taker),          100e18 - 10e18,      "taker tokens not debited");
        assertEq(token.balanceOf(address(vault)), 1_000e18 + 10e18,    "vault collateral not credited");
        assertEq(usdc.balanceOf(taker),           1_000_000e6 + 1_000e6, "taker USDC not credited");
        assertEq(usdc.balanceOf(address(vault)),  100_000e6 - 1_000e6, "vault USDC not debited");
        assertTrue(swap.isQuoteUsed(3));
    }

    // ── Quote validation ──────────────────────────────────────────────────────

    function test_executeSwap_expiredQuote_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(4);
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.warp(uint256(m.expiry) + 1);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteExpired.selector, m.expiry));
        swap.executeSwap(m, sig, _noPermit());
    }

    function test_executeSwap_staleEpoch_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(5); // epoch 0
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(admin);
        swap.bumpQuoteEpoch(); // current epoch is now 1

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteEpochStale.selector, uint64(0), uint64(1)));
        swap.executeSwap(m, sig, _noPermit());
    }

    function test_executeSwap_replayedQuoteId_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(6);
        bytes memory sig = _sign(m, SIGNER_PK);
        GyldAtomicSwap.PermitData memory p = _signPermit(address(usdc), 1_000e6, block.timestamp + 15 minutes);

        vm.prank(taker);
        swap.executeSwap(m, sig, p);

        // Same quoteId signed again (even on a different leg) must be rejected.
        GyldAtomicSwap.SwapMessage memory replay = _redeemQuote(6);
        bytes memory replaySig = _sign(replay, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.QuoteAlreadyUsed.selector, uint256(6)));
        swap.executeSwap(replay, replaySig, _noPermit());
    }

    function test_executeSwap_wrongSigner_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(7);
        uint256 badPk = 0xBADBADBAD;
        bytes memory sig = _sign(m, badPk); // valid signature, wrong key

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteSigner.selector, vm.addr(badPk)));
        swap.executeSwap(m, sig, _noPermit());
    }

    function test_executeSwap_wrongTaker_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(8);
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(outsider); // quote pins `taker` — anyone else must be rejected
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotTaker.selector, taker, outsider));
        swap.executeSwap(m, sig, _noPermit());
    }

    function test_executeSwap_tamperedMessage_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(9);
        bytes memory sig = _sign(m, SIGNER_PK);

        m.amountOut = 100e18; // taker tries to get 10x the tokens on a real signature

        vm.prank(taker);
        vm.expectRevert(); // recovered signer is garbage → InvalidQuoteSigner
        swap.executeSwap(m, sig, _noPermit());
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    function test_executeSwap_whenPaused_reverts() public {
        vm.prank(pauser);
        swap.pause();

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(10);
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("EnforcedPause()"));
        swap.executeSwap(m, sig, _noPermit());
    }

    /// Asymmetric pause: PAUSER halts but cannot resume; admin resumes.
    function test_pause_asymmetric_onlyAdminUnpauses() public {
        vm.prank(pauser);
        swap.pause();

        vm.prank(pauser);
        vm.expectRevert();
        swap.unpause();

        vm.prank(admin);
        swap.unpause();

        // Swap works again post-unpause.
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(11);
        bytes memory sig = _sign(m, SIGNER_PK);
        vm.prank(taker); usdc.approve(address(swap), 1_000e6);
        vm.prank(taker); swap.executeSwap(m, sig, _noPermit());
        assertTrue(swap.isQuoteUsed(11));
    }

    // ── Permit front-run griefing ─────────────────────────────────────────────

    /// An attacker who observes the permit in the mempool and submits it directly
    /// consumes the nonce — the in-swap permit then fails, but the try/catch
    /// swallows it and the allowance (already set by the front-run) still covers
    /// the transferFrom. The swap MUST NOT brick.
    function test_executeSwap_permitFrontRun_doesNotBrick() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(12);
        bytes memory sig = _sign(m, SIGNER_PK);
        uint256 deadline = block.timestamp + 15 minutes;
        GyldAtomicSwap.PermitData memory p = _signPermit(address(usdc), 1_000e6, deadline);

        // Front-run: outsider lands the exact same permit first.
        vm.prank(outsider);
        usdc.permit(taker, address(swap), 1_000e6, deadline, p.v, p.r, p.s);
        assertEq(usdc.nonces(taker), 1, "front-run permit not consumed");
        assertEq(usdc.allowance(taker, address(swap)), 1_000e6);

        // Taker's original transaction still succeeds.
        vm.prank(taker);
        swap.executeSwap(m, sig, p);

        assertEq(token.balanceOf(taker), 100e18 + 10e18, "swap bricked by permit front-run");
        assertTrue(swap.isQuoteUsed(12));
    }

    // ── Zero amounts ──────────────────────────────────────────────────────────

    function test_executeSwap_zeroAmountIn_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(13);
        m.amountIn = 0;
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(GyldAtomicSwap.ZeroAmount.selector);
        swap.executeSwap(m, sig, _noPermit());
    }

    function test_executeSwap_zeroAmountOut_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(14);
        m.amountOut = 0;
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker);
        vm.expectRevert(GyldAtomicSwap.ZeroAmount.selector);
        swap.executeSwap(m, sig, _noPermit());
    }

    // ── Quote epoch ───────────────────────────────────────────────────────────

    function test_bumpQuoteEpoch_incrementsAndEmits() public {
        assertEq(swap.quoteEpoch(), 0);

        vm.expectEmit(true, false, false, false, address(swap));
        emit QuoteEpochBumped(1);

        vm.prank(admin);
        swap.bumpQuoteEpoch();
        assertEq(swap.quoteEpoch(), 1);
    }

    function test_bumpQuoteEpoch_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.bumpQuoteEpoch();
    }

    /// Quotes signed for the NEW epoch execute fine after a bump.
    function test_executeSwap_newEpochQuote_succeedsAfterBump() public {
        vm.prank(admin);
        swap.bumpQuoteEpoch();

        GyldAtomicSwap.SwapMessage memory m = _buyQuote(15);
        m.epoch = 1;
        bytes memory sig = _sign(m, SIGNER_PK);

        vm.prank(taker); usdc.approve(address(swap), 1_000e6);
        vm.prank(taker); swap.executeSwap(m, sig, _noPermit());
        assertTrue(swap.isQuoteUsed(15));
    }

    // ── setVault probe ────────────────────────────────────────────────────────

    function test_setVault_eoa_reverts() public {
        address eoa = address(0xEEEE);
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotValidVault.selector, eoa));
        swap.setVault(eoa);
    }

    function test_setVault_wrongContract_reverts() public {
        // A deployed contract with no totalAssets() — staticcall fails.
        address wrongContract = address(new MockUSDC());
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotValidVault.selector, wrongContract));
        swap.setVault(wrongContract);
    }

    function test_setVault_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(GyldAtomicSwap.ZeroAddress.selector);
        swap.setVault(address(0));
    }

    function test_setVault_onlyAdmin_reverts() public {
        vm.prank(outsider);
        vm.expectRevert();
        swap.setVault(address(vault));
    }

    function test_setVault_validVault_succeeds() public {
        GyldSettlementVault vaultImpl2 = new GyldSettlementVault();
        GyldSettlementVault vault2 = GyldSettlementVault(address(new ERC1967Proxy(
            address(vaultImpl2),
            abi.encodeCall(GyldSettlementVault.initialize, (
                admin, pauser, treasurer, address(usdc), issuanceMgr
            ))
        )));

        vm.expectEmit(true, true, false, false, address(swap));
        emit VaultUpdated(address(vault), address(vault2));

        vm.prank(admin);
        swap.setVault(address(vault2));
        assertEq(swap.vault(), address(vault2));
    }

    function test_initialize_invalidVault_reverts() public {
        GyldAtomicSwap impl = new GyldAtomicSwap();
        address eoa = address(0xEEEE);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.NotValidVault.selector, eoa));
        new ERC1967Proxy(
            address(impl),
            abi.encodeCall(GyldAtomicSwap.initialize, (admin, pauser, signer, eoa))
        );
    }

    // ── renounceRole guard ────────────────────────────────────────────────────

    function test_renounceRole_defaultAdmin_reverts() public {
        // Cache role bytes before pranking — getter call would consume the prank.
        bytes32 adminRole = swap.DEFAULT_ADMIN_ROLE();
        vm.prank(admin);
        vm.expectRevert(GyldAtomicSwap.CannotRenounceAdminRole.selector);
        swap.renounceRole(adminRole, admin);
    }

    function test_renounceRole_quoteSigner_succeeds() public {
        bytes32 signerRole = swap.QUOTE_SIGNER_ROLE();
        vm.prank(signer);
        swap.renounceRole(signerRole, signer);
        assertFalse(swap.hasRole(signerRole, signer));
    }

    // ── M2: EIP-712 typehash / domain regression ──────────────────────────────

    /// The hardcoded SWAP_MESSAGE_TYPEHASH literal must exactly equal keccak256 of
    /// the canonical EIP-712 type string. Any struct field add/remove/reorder/rename
    /// silently changes this hash and breaks every off-chain signature — this test
    /// fails loudly the moment that happens.
    function test_swapMessageTypehash_matchesCanonicalString() public view {
        bytes32 expected = keccak256(
            bytes(
                "SwapMessage(uint256 quoteId,address taker,address tokenIn,uint256 amountIn,address tokenOut,uint256 amountOut,uint64 expiry,uint64 epoch)"
            )
        );
        assertEq(swap.SWAP_MESSAGE_TYPEHASH(), expected, "SWAP_MESSAGE_TYPEHASH drifted from canonical type string");
    }

    /// Cross-check hashSwapMessage against a hand-built _hashTypedDataV4 equivalent:
    /// reconstruct the domain separator from name "GyldAtomicSwap" / version "1" and
    /// the struct hash from the canonical typehash, then assert the contract produces
    /// the identical digest the off-chain signer would. Guards both the typehash AND
    /// the EIP-712 domain (name/version/chainId/verifyingContract).
    function test_hashSwapMessage_matchesHandBuiltDigest() public view {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(100);

        bytes32 EIP712_DOMAIN_TYPEHASH = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSeparator = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("GyldAtomicSwap")),
                keccak256(bytes("1")),
                block.chainid,
                address(swap)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                swap.SWAP_MESSAGE_TYPEHASH(),
                m.quoteId, m.taker, m.tokenIn, m.amountIn, m.tokenOut, m.amountOut, m.expiry, m.epoch
            )
        );
        bytes32 expectedDigest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        assertEq(swap.hashSwapMessage(m), expectedDigest, "hashSwapMessage diverged from EIP-712 hand-built digest");
    }

    // ── N2: signature malleability / malformed signature ──────────────────────

    /// A valid signature has an ECDSA-counterpart (s' = n - s, v flipped) recovering
    /// the SAME signer. OZ's ECDSA.recover rejects high-s to prevent malleability —
    /// the malleated variant must revert with ECDSAInvalidSignatureS, never execute.
    function test_executeSwap_highSMalleableSignature_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(20);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, swap.hashSwapMessage(m));

        // secp256k1 order n.
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes32 highS = bytes32(n - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;
        bytes memory malleable = abi.encodePacked(r, highS, flippedV);

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureS(bytes32)", highS));
        swap.executeSwap(m, malleable, _noPermit());
    }

    /// A zero-length signature is malformed — ECDSA.recover rejects the bad length.
    function test_executeSwap_zeroLengthSignature_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(21);
        bytes memory empty = "";

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", uint256(0)));
        swap.executeSwap(m, empty, _noPermit());
    }

    /// A wrong-length (64-byte, truncated) signature is malformed and rejected.
    function test_executeSwap_wrongLengthSignature_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(22);
        (, bytes32 r, bytes32 s) = vm.sign(SIGNER_PK, swap.hashSwapMessage(m));
        bytes memory truncated = abi.encodePacked(r, s); // 64 bytes, missing v

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSignature("ECDSAInvalidSignatureLength(uint256)", uint256(64)));
        swap.executeSwap(m, truncated, _noPermit());
    }

    /// A well-formed signature from a key that does NOT hold QUOTE_SIGNER_ROLE
    /// recovers a real-but-unauthorized address → InvalidQuoteSigner(recovered).
    function test_executeSwap_nonSignerRoleKey_reverts() public {
        GyldAtomicSwap.SwapMessage memory m = _buyQuote(23);
        uint256 strangerPk = 0xC0FFEE;
        bytes memory sig = _sign(m, strangerPk);

        assertFalse(swap.hasRole(swap.QUOTE_SIGNER_ROLE(), vm.addr(strangerPk)));

        vm.prank(taker);
        vm.expectRevert(abi.encodeWithSelector(GyldAtomicSwap.InvalidQuoteSigner.selector, vm.addr(strangerPk)));
        swap.executeSwap(m, sig, _noPermit());
    }
}
