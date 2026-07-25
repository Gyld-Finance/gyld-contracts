// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @dev Read-only view of a NAVFeedForwarder (Chainlink AggregatorV3 shape, 8 decimals).
interface INavForwarder {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title GyldAtomicSwap
/// @notice Self-custodial atomic two-leg settlement against platform-signed EIP-712
///         quotes. This contract HOLDS its own inventory (USDC, USDG, bond tokens):
///         BUY pulls the taker's USDC in and pushes bond tokens out of its own balance;
///         REDEEM pulls the taker's bond tokens in and pushes USDC out of its own
///         balance. There is no separate vault — `executeSwap` PULLS `tokenIn` into
///         `address(this)` and TRANSFERS `tokenOut` from `address(this)`'s own balance
///         to the taker (reverting InsufficientInventory / InsufficientUsdcLiquidity
///         if the covering leg is not already on hand).
///
/// Design:
///   - This contract is the ONLY address users ever grant token approvals (or sign
///     EIP-2612 permits) to, AND it is the sole custodian of the settlement inventory
///     — it never grants any standing outbound allowance (Hashflow-exploit lesson:
///     every approval target must be small, verified, and in audit scope).
///   - Inventory is replenished ONLY via the existing IssuanceManager mint-at-fill
///     path (this contract is a whitelisted AP; IssuanceManager.subscribe mints
///     directly to it). This contract has no mint authority. Net flow leaves via
///     withdraw() to a fixed, admin-set withdrawalWallet — see below.
///   - executeSwap enforces a NAV sanity band (maxQuoteDeviationBps vs the series'
///     NAVFeedForwarder) plus a max feed age. The feed is a guard rail, NOT the
///     execution price — the signed quote is the price. A non-positive NAV or a feed
///     older than maxNavAgeSecs fails closed.
///   - Quotes are signed off-chain by a QUOTE_SIGNER_ROLE key (the role itself is the
///     signer registry — multiple holders supported, rotated via grant/revoke).
///   - msg.sender must equal the quote's `taker` — quotes are not bearer paper
///     (0x RFQ mandatory-taker binding) — AND the taker must be on the allowlist.
///   - Single-use quoteIds are consumed via a 1inch-style BitInvalidator bitmap
///     (256 quotes per storage slot); `quoteEpoch` mass-invalidates all outstanding
///     quotes in one transaction (signer-key rotation / incident response).
///
/// Compliance:
///   - No sanctions calls here by design — every swap has exactly one GyldBondToken
///     leg, and the token's _update screens from, to, AND this contract as spender
///     (fail-closed via the Chainalysis oracle in both directions). The quote service
///     pre-screens off-chain to avoid wasted gas.
///
/// Roles:
///   DEFAULT_ADMIN_ROLE   — upgrades, unpause, registerSeries/deregisterSeries,
///                          setMaxQuoteDeviationBps, setMaxNavAgeSecs, setWithdrawalWallet,
///                          bumpQuoteEpoch, role grants; should be a
///                          TimelockController in production
///   ALLOWLIST_ADMIN_ROLE — KYC/compliance ops key (`EVM_KMS_SWAP_ADMIN_`); setAllowed
///                          ONLY — the live taker allowlist. Deliberately split off
///                          DEFAULT_ADMIN_ROLE (GYL-1050) so per-taker allowlisting stays
///                          a synchronous operational action after the production timelock
///                          handover. Held by a hot key by design; grants access to swap,
///                          never to funds or upgrades.
///   QUOTE_SIGNER_ROLE  — quote-service KMS key(s); passive — checked via hasRole
///                        against the recovered EIP-712 signer
///   TREASURER_ROLE     — Kaleidoscope ops MPC wallet; withdraw() net inventory out to
///                        the fixed withdrawalWallet. Deliberately stays LIVE while
///                        paused so funds can be evacuated during an incident.
///   PAUSER_ROLE        — ops multisig; pause() ONLY (asymmetric pause: cheap to
///                        halt, deliberate to resume — this contract sits on the hot
///                        path with a hot signing key)
contract GyldAtomicSwap is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    EIP712Upgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 public constant QUOTE_SIGNER_ROLE = keccak256("QUOTE_SIGNER_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant ALLOWLIST_ADMIN_ROLE = keccak256("ALLOWLIST_ADMIN_ROLE");

    // ── EIP-712 ───────────────────────────────────────────────────────────────

    /// @notice Off-chain-signed quote. `taker` pins the user (quotes are not bearer
    ///         paper); `epoch` must equal the current quoteEpoch (mass invalidation).
    ///         `maxAmountIn`/`price` bound a *range* of draws, not one exact amount —
    ///         see `executeSwap`'s `requestedAmountIn` parameter.
    struct SwapMessage {
        uint256 quoteId; // single-use; consumed via the bitmap below, regardless of draw size
        address taker; // must equal msg.sender at execution
        address tokenIn; // leg the user pays
        uint256 maxAmountIn; // ceiling on tokenIn the taker may draw against this quote
        address tokenOut; // leg the user receives (this contract's inventory / USDC pot)
        uint256 price; // fixed-point amountOut per 1e18 tokenIn; amountOut = requestedAmountIn * price / 1e18
        uint64 expiry; // unix seconds
        uint64 epoch; // quote-signer generation
    }

    /// @notice Optional EIP-2612 permit for the incoming leg; value == 0 skips.
    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    // keccak256("SwapMessage(uint256 quoteId,address taker,address tokenIn,uint256 maxAmountIn,address tokenOut,uint256 price,uint64 expiry,uint64 epoch)")
    bytes32 public constant SWAP_MESSAGE_TYPEHASH = 0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b;

    /// @dev Dust floor on `requestedAmountIn`, expressed as basis points of `maxAmountIn`.
    ///      Prevents a taker griefing the quote-signer's single-use quoteId budget with
    ///      near-zero-value draws (docs/atomic-settlement.md "Proposed amendment").
    uint256 public constant MIN_DRAW_BPS = 100; // 1%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ── ERC-7201 namespaced storage ───────────────────────────────────────────

    /// @custom:storage-location erc7201:gyld.GyldAtomicSwap
    struct GyldAtomicSwapStorage {
        uint64 quoteEpoch; // bumped to mass-invalidate quotes
        uint16 maxQuoteDeviationBps; // quote-vs-NAV sanity band, e.g. 200 = 2%
        uint32 maxNavAgeSecs; // max NAV feed age before StaleNav (fail-closed)
        address withdrawalWallet; // fixed treasury destination for withdraw()
        address usdc; // cash leg discriminator (6 decimals)
        mapping(uint256 => uint256) usedQuoteWords; // quoteId >> 8 → 256-bit usage word
        address[] seriesList; // registered series, for clean deregister
        mapping(address => bool) registeredSeries; // bond token → enabled
        mapping(address => address) navForwarderOf; // bond token → NAVFeedForwarder (stable addr)
        mapping(address => bool) allowed; // executeSwap taker allowlist
    }

    // keccak256(abi.encode(uint256(keccak256("gyld.GyldAtomicSwap")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_LOCATION = 0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300;

    function _getStorage() private pure returns (GyldAtomicSwapStorage storage $) {
        assembly {
            $.slot := _STORAGE_LOCATION
        }
    }

    // ── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error RequestedAmountOutOfRange(uint256 requested, uint256 minAllowed, uint256 maxAllowed);
    error QuoteExpired(uint64 expiry);
    error QuoteEpochStale(uint64 quoteEpoch, uint64 currentEpoch);
    error QuoteAlreadyUsed(uint256 quoteId);
    error InvalidQuoteSigner(address recovered);
    error NotTaker(address taker, address caller);
    error NotAllowed(address taker);
    error CannotRenounceAdminRole();
    // NAV band / series registry (migrated from the former GyldSettlementVault).
    error UnregisteredSeries(address token);
    error NotOneBondLeg(address tokenIn, address tokenOut);
    error QuotePriceOutOfBand(uint256 quotedUsdcAmount, uint256 navUsdcAmount);
    error InvalidNav(address token, int256 nav);
    error StaleNav(address token, uint256 updatedAt);
    error InsufficientInventory(address token, uint256 requested, uint256 available);
    error InsufficientUsdcLiquidity(uint256 requested, uint256 available);
    error InvalidDeviationBps(uint16 bps);
    error InvalidNavAge(uint32 secs);
    error NotValidForwarder(address forwarder);
    error SeriesNotEmpty(address token);

    // ── Events ────────────────────────────────────────────────────────────────

    event SwapExecuted(
        uint256 indexed quoteId,
        address indexed taker,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    );
    event QuoteEpochBumped(uint64 indexed newEpoch);
    event SeriesRegistered(address indexed token, address indexed navForwarder);
    event SeriesDeregistered(address indexed token);
    event MaxQuoteDeviationUpdated(uint16 newBps);
    event MaxNavAgeUpdated(uint32 newSecs);
    event WithdrawalWalletUpdated(address indexed previous, address indexed next);
    event AllowedSet(address indexed account, bool allowed);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    // ── Constructor / Initializer ─────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param defaultAdmin           Should be a TimelockController in production.
    /// @param pauser                 Ops multisig — may pause() but not unpause().
    /// @param quoteSigner            Quote-service KMS key; recovered EIP-712 signers
    ///                               must hold QUOTE_SIGNER_ROLE. Rotate via
    ///                               grant/revoke + bumpQuoteEpoch.
    /// @param treasurer              Kaleidoscope ops MPC wallet (TREASURER_ROLE); may
    ///                               withdraw() inventory out to the withdrawalWallet.
    /// @param usdc_                  USDC token (6 decimals) — the cash leg every quote
    ///                               is priced against.
    /// @param maxQuoteDeviationBps_  Quote-vs-NAV band width in basis points (e.g. 200 =
    ///                               2%). Capped at BPS_DENOMINATOR; 0 is permitted and
    ///                               forces quotes to match NAV exactly (soft-pause).
    /// @param maxNavAgeSecs_         Max NAV feed age before executeSwap fails closed
    ///                               with StaleNav. Must be non-zero.
    /// @dev    withdrawalWallet is deliberately NOT set here — it starts at address(0)
    ///         and must be set post-deploy by the admin via setWithdrawalWallet.
    ///         withdraw() reverts ZeroAddress until then (fail-closed).
    function initialize(
        address defaultAdmin,
        address pauser,
        address quoteSigner,
        address treasurer,
        address usdc_,
        uint16 maxQuoteDeviationBps_,
        uint32 maxNavAgeSecs_
    ) external initializer {
        if (
            defaultAdmin == address(0) || pauser == address(0) || quoteSigner == address(0) || treasurer == address(0)
                || usdc_ == address(0)
        ) revert ZeroAddress();
        if (maxQuoteDeviationBps_ > BPS_DENOMINATOR) revert InvalidDeviationBps(maxQuoteDeviationBps_);
        if (maxNavAgeSecs_ == 0) revert InvalidNavAge(maxNavAgeSecs_);
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __EIP712_init("GyldAtomicSwap", "2"); // v2: capped-allowance SwapMessage (maxAmountIn/price)
        __UUPSUpgradeable_init();
        GyldAtomicSwapStorage storage $ = _getStorage();
        $.usdc = usdc_;
        $.maxQuoteDeviationBps = maxQuoteDeviationBps_;
        $.maxNavAgeSecs = maxNavAgeSecs_;
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, pauser);
        _grantRole(QUOTE_SIGNER_ROLE, quoteSigner);
        _grantRole(TREASURER_ROLE, treasurer);
    }

    // ── Public getters ────────────────────────────────────────────────────────

    /// @notice Current quote-signer generation; quotes signed for an older epoch revert.
    function quoteEpoch() external view returns (uint64) {
        return _getStorage().quoteEpoch;
    }

    /// @notice USDC token (6 decimals) — the cash leg every quote is priced against.
    function usdc() external view returns (address) {
        return _getStorage().usdc;
    }

    /// @notice Fixed treasury destination for withdraw(); address(0) until admin sets it.
    function withdrawalWallet() external view returns (address) {
        return _getStorage().withdrawalWallet;
    }

    /// @notice Quote-vs-NAV sanity band in basis points (e.g. 200 = 2%).
    function maxQuoteDeviationBps() external view returns (uint16) {
        return _getStorage().maxQuoteDeviationBps;
    }

    /// @notice Max NAV feed age (seconds) before executeSwap fails closed with StaleNav.
    function maxNavAgeSecs() external view returns (uint32) {
        return _getStorage().maxNavAgeSecs;
    }

    /// @notice Returns whether `token` is a registered bond series.
    function registeredSeries(address token) external view returns (bool) {
        return _getStorage().registeredSeries[token];
    }

    /// @notice NAVFeedForwarder paired with `token`; address(0) if unregistered.
    function navForwarderOf(address token) external view returns (address) {
        return _getStorage().navForwarderOf[token];
    }

    /// @notice Whether `account` is allowed to be the taker on executeSwap.
    function isAllowed(address account) external view returns (bool) {
        return _getStorage().allowed[account];
    }

    /// @notice Returns whether `quoteId` has already been consumed by executeSwap.
    /// @param  quoteId Single-use quote identifier from the signed SwapMessage.
    /// @return True if the quote can no longer be executed.
    function isQuoteUsed(uint256 quoteId) external view returns (bool) {
        return (_getStorage().usedQuoteWords[quoteId >> 8] >> (quoteId & 0xff)) & 1 != 0;
    }

    // ── Swap execution ────────────────────────────────────────────────────────

    /// @notice Settle a platform-signed quote atomically. Pulls `requestedAmountIn` of
    ///         `tokenIn` from the caller into this contract, then transfers the derived
    ///         `tokenOut` amount from this contract's OWN balance to the caller.
    /// @dev    Verification order (CEI — all checks before any external transfer): taker
    ///         binding → allowlist → price sanity → requested-amount range → expiry →
    ///         epoch → EIP-712 signature against QUOTE_SIGNER_ROLE → single-use quoteId
    ///         consumption (state effect) → derived-amount sanity → NAV band + leg
    ///         classification → optional permit → PULL tokenIn → inventory check + PUSH
    ///         tokenOut. The quoteId is burned in full regardless of how much of
    ///         `maxAmountIn` is drawn — single-shot-capped sizing, not multi-draw (see
    ///         docs/atomic-settlement.md). The optional permit is applied with try/catch
    ///         so a front-run permit() cannot brick the swap (standard griefing
    ///         mitigation) — the subsequent safeTransferFrom enforces the allowance
    ///         regardless. Real USDC permit is non-standard (version "2") and MockUSDC
    ///         has none, hence optional.
    /// @param m                 The quote message exactly as signed by the quote service.
    /// @param signature         65-byte ECDSA signature over hashSwapMessage(m).
    /// @param permitIn          Optional EIP-2612 permit for `m.tokenIn`, sized to
    ///                          `requestedAmountIn` by the taker; permitIn.value == 0 skips.
    /// @param requestedAmountIn Taker-chosen draw size, NOT part of the signed message.
    ///                          Must satisfy `0 < minAllowed <= requestedAmountIn <= m.maxAmountIn`,
    ///                          where minAllowed is a `MIN_DRAW_BPS` dust floor of `maxAmountIn`.
    function executeSwap(
        SwapMessage calldata m,
        bytes calldata signature,
        PermitData calldata permitIn,
        uint256 requestedAmountIn
    ) external nonReentrant whenNotPaused {
        GyldAtomicSwapStorage storage $ = _getStorage();

        if (m.taker != msg.sender) revert NotTaker(m.taker, msg.sender);
        if (!$.allowed[msg.sender]) revert NotAllowed(msg.sender);
        if (m.price == 0) revert ZeroAmount();

        uint256 minAmountIn = (m.maxAmountIn * MIN_DRAW_BPS) / BPS_DENOMINATOR;
        if (requestedAmountIn == 0 || requestedAmountIn < minAmountIn || requestedAmountIn > m.maxAmountIn) {
            revert RequestedAmountOutOfRange(requestedAmountIn, minAmountIn, m.maxAmountIn);
        }

        if (block.timestamp > m.expiry) revert QuoteExpired(m.expiry);
        if (m.epoch != $.quoteEpoch) revert QuoteEpochStale(m.epoch, $.quoteEpoch);

        address signer = ECDSA.recover(hashSwapMessage(m), signature);
        if (!hasRole(QUOTE_SIGNER_ROLE, signer)) revert InvalidQuoteSigner(signer);

        _consumeQuote($, m.quoteId);

        // Rounds down — this contract's favor; a taker-favorable direction would let a
        // taker extract dust across many small draws (docs/atomic-settlement.md).
        uint256 amountOut = (requestedAmountIn * m.price) / 1e18;
        if (amountOut == 0) revert ZeroAmount();

        // Classify buy vs redeem, read NAV, and enforce the quote is within the NAV
        // band and the feed is fresh (reverts NotOneBondLeg / InvalidNav / StaleNav /
        // QuotePriceOutOfBand). The signed quote is the price; the feed only bounds it.
        _checkQuoteBand($, m.tokenIn, requestedAmountIn, m.tokenOut, amountOut);

        // Optional EIP-2612 permit; try/catch so a front-run permit() cannot brick the
        // swap — safeTransferFrom below still enforces the allowance.
        if (permitIn.value != 0) {
            try IERC20Permit(m.tokenIn)
                .permit(
                    msg.sender, address(this), permitIn.value, permitIn.deadline, permitIn.v, permitIn.r, permitIn.s
                ) {}
                catch {} // solhint-disable-line no-empty-blocks
        }

        // Leg 1: user → this contract. (If tokenIn is a GyldBondToken, its _update
        // screens msg.sender as from, this contract as to, and this contract as spender.)
        IERC20(m.tokenIn).safeTransferFrom(msg.sender, address(this), requestedAmountIn);

        // Leg 2: push tokenOut from this contract's OWN inventory to the taker. The
        // outgoing leg must be covered by pre-existing inventory — measuring `available`
        // after the pull-in is correct in both directions (tokenIn != tokenOut since
        // exactly one leg is USDC). (If tokenOut is a GyldBondToken, its _update screens
        // this contract as from and the taker as to.)
        uint256 available = IERC20(m.tokenOut).balanceOf(address(this));
        if (amountOut > available) {
            if (m.tokenOut == $.usdc) revert InsufficientUsdcLiquidity(amountOut, available);
            revert InsufficientInventory(m.tokenOut, amountOut, available);
        }
        IERC20(m.tokenOut).safeTransfer(msg.sender, amountOut);

        emit SwapExecuted(m.quoteId, msg.sender, m.tokenIn, requestedAmountIn, m.tokenOut, amountOut);
    }

    /// @notice EIP-712 digest for a SwapMessage (off-chain signer parity check).
    /// @param  m SwapMessage to hash.
    /// @return The fully-domain-separated digest the quote service must sign.
    function hashSwapMessage(SwapMessage calldata m) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    SWAP_MESSAGE_TYPEHASH,
                    m.quoteId,
                    m.taker,
                    m.tokenIn,
                    m.maxAmountIn,
                    m.tokenOut,
                    m.price,
                    m.expiry,
                    m.epoch
                )
            )
        );
    }

    // ── NAV band ──────────────────────────────────────────────────────────────

    /// @dev Classify the swap (exactly one leg must be a registered series against
    ///      USDC), read the series NAV, fail closed on non-positive or stale NAV, and
    ///      enforce the quoted USDC amount is within maxQuoteDeviationBps of NAV value.
    ///      Decimals: bond tokens 18dp, NAV 8dp, USDC 6dp → 1e18 * 1e8 / 1e20 = 1e6.
    function _checkQuoteBand(
        GyldAtomicSwapStorage storage $,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    ) private view {
        bool buy = $.registeredSeries[tokenOut] && tokenIn == $.usdc;
        bool redeem = $.registeredSeries[tokenIn] && tokenOut == $.usdc;
        if (buy == redeem) revert NotOneBondLeg(tokenIn, tokenOut);

        address bondToken = buy ? tokenOut : tokenIn;
        uint256 tokenAmount = buy ? amountOut : amountIn;
        uint256 usdcAmount = buy ? amountIn : amountOut;

        // navForwarderOf[bondToken] is guaranteed non-zero (set atomically in registerSeries).
        (, int256 nav,, uint256 updatedAt,) = INavForwarder($.navForwarderOf[bondToken]).latestRoundData();
        if (nav <= 0) revert InvalidNav(bondToken, nav);
        if (block.timestamp > updatedAt + $.maxNavAgeSecs) revert StaleNav(bondToken, updatedAt);

        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 navValue = (tokenAmount * uint256(nav)) / 1e20; // nav > 0 checked above
        uint256 band = (navValue * $.maxQuoteDeviationBps) / BPS_DENOMINATOR;
        if (usdcAmount > navValue + band || usdcAmount + band < navValue) {
            revert QuotePriceOutOfBand(usdcAmount, navValue);
        }
    }

    // ── Quote invalidation ────────────────────────────────────────────────────

    /// @dev 1inch BitInvalidator: one bit per quoteId, 256 quotes per storage slot.
    ///      Reverts on reuse — quotes are strictly single-use.
    function _consumeQuote(GyldAtomicSwapStorage storage $, uint256 quoteId) private {
        uint256 word = $.usedQuoteWords[quoteId >> 8];
        uint256 bit = quoteId & 0xff;
        if ((word >> bit) & 1 != 0) revert QuoteAlreadyUsed(quoteId);
        // forge-lint: disable-next-line(incorrect-shift)
        $.usedQuoteWords[quoteId >> 8] = word | (1 << bit); // intentional: 1 shifted to bit position
    }

    /// @notice Kill every outstanding quote in one transaction (signer-key rotation
    ///         or incident response). Quotes signed for the old epoch revert with
    ///         QuoteEpochStale; the quote service must re-issue against the new epoch.
    function bumpQuoteEpoch() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint64 next = ++_getStorage().quoteEpoch;
        emit QuoteEpochBumped(next);
    }

    // ── Series registry ───────────────────────────────────────────────────────

    /// @notice Register a bond series so this contract can hold, value, and serve it.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. The forwarder is probed via
    ///         staticcall before storing — rejects EOAs, wrong contracts, and feeds
    ///         that don't report 8 decimals (the NAV scaling in _checkQuoteBand assumes
    ///         8dp). Re-registering an active series just updates its forwarder.
    /// @param token        GyldBondToken proxy address (18 decimals).
    /// @param navForwarder NAVFeedForwarder paired with the series (stable address).
    function registerSeries(address token, address navForwarder) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || navForwarder == address(0)) revert ZeroAddress();
        // Probe-before-store (house idiom): forwarder must report 8 decimals.
        (bool ok, bytes memory data) = navForwarder.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length != 32 || abi.decode(data, (uint8)) != 8) revert NotValidForwarder(navForwarder);
        GyldAtomicSwapStorage storage $ = _getStorage();
        if (!$.registeredSeries[token]) $.seriesList.push(token);
        $.registeredSeries[token] = true;
        $.navForwarderOf[token] = navForwarder;
        emit SeriesRegistered(token, navForwarder);
    }

    /// @notice Deregister a matured bond series.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Reverts SeriesNotEmpty while this
    ///         contract still holds inventory of the series — silently orphaning
    ///         inventory that can no longer be priced or served is unsafe. Wind the
    ///         series down first (withdraw the remaining balance).
    /// @param token Registered bond series to remove.
    function deregisterSeries(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        GyldAtomicSwapStorage storage $ = _getStorage();
        if (!$.registeredSeries[token]) revert UnregisteredSeries(token);
        if (IERC20(token).balanceOf(address(this)) != 0) revert SeriesNotEmpty(token);
        uint256 n = $.seriesList.length;
        for (uint256 i = 0; i < n;) {
            if ($.seriesList[i] == token) {
                $.seriesList[i] = $.seriesList[n - 1];
                $.seriesList.pop();
                break;
            }
            unchecked {
                i++;
            }
        }
        delete $.registeredSeries[token];
        delete $.navForwarderOf[token];
        emit SeriesDeregistered(token);
    }

    // ── Admin: band params, allowlist, withdrawal wallet ──────────────────────

    /// @notice Set the quote-vs-NAV sanity band in basis points.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Capped at 10_000 (100%); zero is
    ///         permitted and forces quotes to match NAV exactly (effectively a
    ///         soft-pause of executeSwap given rounding).
    /// @param newBps Band width in basis points, e.g. 200 = 2%.
    function setMaxQuoteDeviationBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > BPS_DENOMINATOR) revert InvalidDeviationBps(newBps);
        _getStorage().maxQuoteDeviationBps = newBps;
        emit MaxQuoteDeviationUpdated(newBps);
    }

    /// @notice Set the max NAV feed age (seconds) before executeSwap fails closed.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Must be non-zero.
    /// @param newSecs Max feed age in seconds (e.g. 86400 = 1 day).
    function setMaxNavAgeSecs(uint32 newSecs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSecs == 0) revert InvalidNavAge(newSecs);
        _getStorage().maxNavAgeSecs = newSecs;
        emit MaxNavAgeUpdated(newSecs);
    }

    /// @notice Add or remove `account` from the executeSwap taker allowlist.
    /// @dev    Caller must hold ALLOWLIST_ADMIN_ROLE — deliberately NOT DEFAULT_ADMIN_ROLE
    ///         (GYL-1050): in production DEFAULT_ADMIN_ROLE is the TimelockController, and
    ///         per-taker allowlisting is a live operational action that cannot wait on a
    ///         48h governance proposal per user. executeSwap requires the taker
    ///         (== msg.sender) to be allowed. The withdrawalWallet is intentionally
    ///         NOT required to be on this list — it is a cold treasury address that
    ///         never calls executeSwap; coupling the two adds no security and risks
    ///         bricking withdraw during incident response (see setWithdrawalWallet).
    /// @param account Address to toggle.
    /// @param allowed_ True to allow, false to disallow.
    function setAllowed(address account, bool allowed_) external onlyRole(ALLOWLIST_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _getStorage().allowed[account] = allowed_;
        emit AllowedSet(account, allowed_);
    }

    /// @notice Set the fixed destination that withdraw() sends inventory to.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE (the timelock in production). This is
    ///         the core safety property: the treasurer can pull funds out via withdraw()
    ///         but ONLY ever to this admin-fixed address — never to an arbitrary target.
    ///         The wallet does not need to be on the executeSwap allowlist (it never
    ///         swaps); keeping the two concerns separate avoids a second timelock op and
    ///         cannot brick withdraw if the allowlist changes.
    /// @param newWallet New treasury destination. Reverts ZeroAddress on 0.
    function setWithdrawalWallet(address newWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newWallet == address(0)) revert ZeroAddress();
        GyldAtomicSwapStorage storage $ = _getStorage();
        address previous = $.withdrawalWallet;
        $.withdrawalWallet = newWallet;
        emit WithdrawalWalletUpdated(previous, newWallet);
    }

    // ── Treasury withdrawal ─────────────────────────────────────────────────────

    /// @notice Move `amount` of `token` out of this contract's inventory to the fixed
    ///         withdrawalWallet. Generic across every held token (USDC, USDG, bond
    ///         tokens) — this is how NET flow leaves for the broker/treasury bridge.
    /// @dev    Caller must hold TREASURER_ROLE. Deliberately NOT whenNotPaused: the
    ///         treasury drain must work during an incident pause so funds can be
    ///         evacuated. CEI: no state to write; single external transfer guarded by
    ///         nonReentrant (shared with executeSwap). The treasurer can never redirect
    ///         — funds only ever go to the admin-fixed withdrawalWallet. Reverts
    ///         ZeroAddress until the admin has set the withdrawalWallet (fail-closed).
    /// @param token  Inventory token to withdraw.
    /// @param amount Amount to withdraw (token's native decimals). Must be non-zero.
    function withdraw(address token, uint256 amount) external nonReentrant onlyRole(TREASURER_ROLE) {
        if (amount == 0) revert ZeroAmount();
        address to = _getStorage().withdrawalWallet;
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    /// @notice Halt executeSwap. Asymmetric by design: PAUSER (ops multisig) can halt
    ///         cheaply; only DEFAULT_ADMIN_ROLE (timelock) can resume — this contract
    ///         sits on the hot path with a hot signing key. withdraw() stays live so
    ///         inventory can still be evacuated while paused.
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /// @notice Resume executeSwap. Deliberately admin-gated (see pause()).
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ── Role management overrides ─────────────────────────────────────────────

    /// DEFAULT_ADMIN_ROLE cannot be renounced — losing it permanently bricks UUPS
    /// upgrades, unpause, series registration, withdrawal-wallet control, and all role
    /// management, including quote-signer rotation.
    /// Intentional removal must go through revokeRole (explicit, two-party action).
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    // ── UUPS upgrade authorization ────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
