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
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @dev Read-only view of a NAVFeedForwarder (Chainlink AggregatorV3 shape, 8 decimals).
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
///                          setMaxQuoteDeviationBps, setMaxNavAgeSecs, setMaxQuoteTtl,
///                          setWithdrawalWallet, bumpQuoteEpoch, role grants; should be a
///                          TimelockController in production. Note that all three
///                          band/staleness/TTL knobs are bounded by `public constant`
///                          ceilings (GYL-1134/1135): this role can TIGHTEN a guard but
///                          cannot widen one into a no-op. Weakening a guard past its
///                          ceiling requires a code change and a re-audit, not an admin tx.
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
    ///         `maxAmountIn`/`price` bound a range of *draw sizes*, exactly one of
    ///         which may be taken — the unused remainder is forfeited. See
    ///         `executeSwap`'s `requestedAmountIn` parameter.
    struct SwapMessage {
        // Single-use, globally and permanently, across ALL epochs — the usage bitmap
        // below is NOT epoch-scoped (bumpQuoteEpoch does not clear it), so the quote
        // service must allocate ids from one monotonic counter that never resets.
        uint256 quoteId; // consumed via the bitmap on the first draw, whatever its size
        address taker; // must equal msg.sender at execution
        address tokenIn; // leg the user pays
        uint256 maxAmountIn; // ceiling on the taker's single draw of tokenIn
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
    ///      near-zero-value draws (docs/ARCHITECTURE.md "Proposed amendment").
    uint256 public constant MIN_DRAW_BPS = 100; // 1%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Fallback quote lifetime when `maxQuoteTtl` is unset. NOT seeded by initialize.
    /// @dev    A signed fixed price is a free option — the leak grows with the TTL — and 90s
    ///         is ~7 Ethereum blocks: issuance, wallet approval, inclusion, no idling.
    ///         Zero means UNSET, not zero seconds. Keeping this a fallback rather than a
    ///         seed is what stops a proxy upgraded across the field's addition from
    ///         rejecting every quote. Read only via `_effectiveMaxQuoteTtl`.
    uint64 public constant DEFAULT_MAX_QUOTE_TTL = 90 seconds;

    /// @dev Structural upper bound on `maxNavAgeSecs` (GYL-1135). Without it,
    ///      `setMaxNavAgeSecs` only rejected zero — and `uint32` tops out at ~136 years,
    ///      so a single DEFAULT_ADMIN_ROLE call could disable the StaleNav guard entirely
    ///      while leaving the NAV band nominally "enforced" against a price nobody
    ///      refreshed. The upstream feed deliberately does NOT revert on staleness
    ///      (Chainlink read semantics), so this consumer-side check is the only thing
    ///      standing between a frozen NAV keeper and quotes validated against a dead
    ///      price. 72 h matches Euler's structural MAX_STALENESS_UPPER_BOUND and keeps
    ///      3-day-holiday tolerance available; the deployed default is 24 h.
    ///      Enforced in BOTH initialize and setMaxNavAgeSecs — a `constant` costs no
    ///      storage slot, so the ERC-7201 layout is unchanged.
    uint32 public constant MAX_NAV_AGE_CEILING = 72 hours;

    /// @dev Structural upper bound on `maxQuoteDeviationBps` (GYL-1135). Previously the
    ///      only bound was BPS_DENOMINATOR itself — a ±100% band, which admits any price
    ///      from zero to 2× NAV and makes the band decorative. Together with the quote
    ///      TTL, this band is the containment on a COMPROMISED QUOTE-SIGNER KEY: it caps
    ///      how far a validly-signed quote may sit from the published NAV, and therefore
    ///      the value extractable per swap. An admin must not be able to widen it to the
    ///      point where a signed quote is unconstrained.
    ///
    ///      1000 bps (10%) is anchored to KaleidoscopeNAVFeed.MAX_PRICE_DEVIATION_BPS,
    ///      which is this system's own codified definition of the largest plausible
    ///      single-step price move for these instruments — the feed REJECTS any push
    ///      beyond it. A quote band wider than that would let this contract settle
    ///      against a price the NAV oracle itself would refuse to publish, so 10% is
    ///      simultaneously the widest defensible band and the smallest ceiling that never
    ///      blocks a legitimate configuration: NAV publishes at most hourly
    ///      (MIN_UPDATE_INTERVAL), so a quote struck off live market during a genuine
    ///      dislocation can legitimately sit up to one full update step from the last
    ///      published NAV. The deployed default is 200 bps (2%).
    ///
    ///      What breaks at the ceiling: a quote priced more than 10% away from the last
    ///      published NAV can never settle. That is intended — such a quote is either
    ///      stale-priced or wrong. The correct operational response to a real >10% gap is
    ///      to walk the published NAV up to the new level and then trade at the refreshed
    ///      price — NOT to widen this band and trade against a dead one. The feed has no
    ///      privileged bypass: `updateAnswer` is chained, one ≤10% step per hour, and the
    ///      band is measured against the LAST stored price so it moves with each push. If
    ///      the interim prices must not be traded or liquidated against, `pause()` the bond
    ///      token for the duration — that also blocks swaps here, which is the point.
    ///      See ARCHITECTURE §11.5 and D-19.
    ///
    ///      Zero remains permitted: that is the RESTRICTIVE end (quotes must match NAV
    ///      exactly — effectively a soft-pause), and a soft-pause is safe.
    ///      Enforced in BOTH initialize and setMaxQuoteDeviationBps — bounding only the
    ///      setter would let a fresh deployment be born with the band already disabled.
    ///      A `constant` costs no storage slot, so the ERC-7201 layout is unchanged.
    uint16 public constant MAX_QUOTE_DEVIATION_BPS_CEILING = 1000; // 10%

    /// @notice Structural upper bound on `maxQuoteTtl`, enforced in `setMaxQuoteTtl`.
    /// @dev    Set well above the 90s default on purpose: this is the headroom an admin can
    ///         reach through a timelocked `setMaxQuoteTtl` during an incident. Being a
    ///         `constant`, widening it later needs a proxy upgrade — which is hardest to run
    ///         calmly at exactly the moment you would need it. Bounds the setter only; it
    ///         does not retro-narrow a value an earlier initializer already wrote.
    uint64 public constant MAX_QUOTE_TTL_CEILING = 10 minutes;

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
        // APPEND-ONLY (ERC-7201): new fields go here, never insert/reorder above.
        // Quote expiry cap (F-4): expiry <= block.timestamp + effective TTL.
        // ZERO MEANS UNSET, not zero seconds — always read via _effectiveMaxQuoteTtl(),
        // never directly, or a proxy upgraded from a pre-F-4 implementation (where this
        // slot has never been written) will reject every quote. See the fallback rationale
        // on DEFAULT_MAX_QUOTE_TTL.
        uint64 maxQuoteTtl;
        // Per-series NAV age override (audit FIND-022). ZERO MEANS UNSET, not zero
        // seconds — always read via _effectiveMaxNavAge(), never directly. A proxy
        // upgraded from a pre-FIND-022 implementation has never written this mapping,
        // so a raw read returns 0 for every series; treating that as a literal age
        // would revert StaleNav on every swap. Unset means "follow the global
        // maxNavAgeSecs", which is exactly the pre-upgrade behaviour.
        mapping(address => uint32) maxNavAgeSecsOf;
    }

    // keccak256(abi.encode(uint256(keccak256("gyld.GyldAtomicSwap")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_LOCATION = 0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300;

    function _getStorage() private pure returns (GyldAtomicSwapStorage storage $) {
        assembly {
            $.slot := _STORAGE_LOCATION
        }
    }

    /// @dev The quote-lifetime cap actually in force. Treats an unset slot (zero) as
    ///      "use the compiled-in default" rather than "zero seconds". This is the ONLY
    ///      permitted read path for `maxQuoteTtl` — see DEFAULT_MAX_QUOTE_TTL for why a
    ///      raw read bricks executeSwap on a proxy upgraded across the field's addition.
    function _effectiveMaxQuoteTtl(GyldAtomicSwapStorage storage $) private view returns (uint64) {
        uint64 ttl = $.maxQuoteTtl;
        return ttl == 0 ? DEFAULT_MAX_QUOTE_TTL : ttl;
    }

    /// @dev The max NAV age actually in force for one series (audit FIND-022). A series
    ///      with no override follows the global `maxNavAgeSecs`, so a feed pushing daily
    ///      and one pushing hourly are no longer forced onto a single threshold that is
    ///      necessarily wrong for one of them. This is the ONLY permitted read path for
    ///      `maxNavAgeSecsOf` — see the field's note for why a raw read bricks
    ///      executeSwap on a proxy upgraded across the mapping's addition.
    function _effectiveMaxNavAge(GyldAtomicSwapStorage storage $, address bondToken)
        private
        view
        returns (uint32)
    {
        uint32 perSeries = $.maxNavAgeSecsOf[bondToken];
        return perSeries == 0 ? $.maxNavAgeSecs : perSeries;
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
    /// @dev maxQuoteTtl above MAX_QUOTE_TTL_CEILING (GYL-1135). Zero is legal and means
    ///      "unset — fall back to DEFAULT_MAX_QUOTE_TTL", not zero seconds.
    error InvalidQuoteTtl(uint64 ttl);
    error NotValidForwarder(address forwarder);
    error SeriesNotEmpty(address token);
    // F-1: bond token must report 18dp and the cash token 6dp (the /1e20 ladder in
    // _checkQuoteBand silently mis-scales otherwise). decimals == 0 signals "no usable
    // decimals()". F-4: quote expiry beyond block.timestamp + maxQuoteTtl.
    error InvalidTokenDecimals(address token, uint8 decimals);
    error QuoteExpiryTooFar(uint64 expiry, uint64 maxAllowed);

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
    /// newSecs == 0 means the override was CLEARED and the series follows the global value.
    event MaxNavAgeForSeriesUpdated(address indexed token, uint32 newSecs);
    event MaxQuoteTtlUpdated(uint64 newTtl);
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
    /// @param usdc_                  USDC token (6 decimals, probed on-chain — F-1) —
    ///                               the cash leg every quote is priced against.
    /// @param maxQuoteDeviationBps_  Quote-vs-NAV band width in basis points (e.g. 200 =
    ///                               2%). Must be at most MAX_QUOTE_DEVIATION_BPS_CEILING
    ///                               (1000 bps = 10%) — see GYL-1135; 0 is permitted and
    ///                               forces quotes to match NAV exactly (soft-pause).
    /// @param maxNavAgeSecs_         Max NAV feed age before executeSwap fails closed
    ///                               with StaleNav. Must be non-zero and at most
    ///                               MAX_NAV_AGE_CEILING (72 h) — see GYL-1135.
    /// @dev    withdrawalWallet is deliberately NOT set here — it starts at address(0)
    ///         and must be set post-deploy by the admin via setWithdrawalWallet.
    ///         withdraw() reverts ZeroAddress until then (fail-closed).
    ///         maxQuoteTtl is deliberately NOT seeded — it is read through a fallback to
    ///         DEFAULT_MAX_QUOTE_TTL (90 s, F-4), so a fresh deploy and a proxy upgraded
    ///         across the field's addition enforce the same cap with no migration step.
    ///         This covers proxies whose slot was never written. A proxy that WAS seeded
    ///         by an older initializer keeps that seeded value — see the scope note on
    ///         DEFAULT_MAX_QUOTE_TTL.
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
        if (maxQuoteDeviationBps_ > MAX_QUOTE_DEVIATION_BPS_CEILING) revert InvalidDeviationBps(maxQuoteDeviationBps_);
        if (maxNavAgeSecs_ == 0 || maxNavAgeSecs_ > MAX_NAV_AGE_CEILING) revert InvalidNavAge(maxNavAgeSecs_);
        // No maxQuoteTtl seed here, deliberately: the field is read through
        // _effectiveMaxQuoteTtl, which falls back to DEFAULT_MAX_QUOTE_TTL on an unset
        // slot. Seeding it would make a fresh deploy differ from an upgraded proxy —
        // the exact divergence that bricked executeSwap before this was a fallback.
        // Probe-before-store (house idiom, F-1): the cash token must report 6 decimals —
        // the /1e20 ladder in _checkQuoteBand assumes 18dp bond / 8dp NAV / 6dp USDC and
        // mis-scales silently for any other cash token.
        (bool usdcOk, bytes memory usdcData) = usdc_.staticcall(abi.encodeWithSignature("decimals()"));
        if (!usdcOk || usdcData.length != 32) revert InvalidTokenDecimals(usdc_, 0);
        uint8 usdcDecimals = abi.decode(usdcData, (uint8));
        if (usdcDecimals != 6) revert InvalidTokenDecimals(usdc_, usdcDecimals);
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

    /// @notice Upper bound on quote lifetime (seconds). executeSwap rejects quotes
    ///         expiring further than this far in the future (F-4).
    /// @dev    Returns the EFFECTIVE cap, so an unset slot reports DEFAULT_MAX_QUOTE_TTL
    ///         rather than 0 — integrators reading this to size their own TTLs must see
    ///         what the chain will actually enforce, not the raw storage word.
    function maxQuoteTtl() external view returns (uint64) {
        return _effectiveMaxQuoteTtl(_getStorage());
    }

    // ── Swap execution ────────────────────────────────────────────────────────

    /// @notice Settle a platform-signed quote atomically. Pulls `requestedAmountIn` of
    ///         `tokenIn` from the caller into this contract, then transfers the derived
    ///         `tokenOut` amount from this contract's OWN balance to the caller.
    /// @dev    Verification order (CEI — all checks before any external transfer): taker
    ///         binding → allowlist → price sanity → requested-amount range → expiry →
    ///         expiry-within-TTL → epoch → EIP-712 signature against QUOTE_SIGNER_ROLE →
    ///         single-use quoteId consumption (state effect) → derived-amount sanity →
    ///         NAV band + leg classification → optional permit → PULL tokenIn →
    ///         inventory check + PUSH tokenOut. The quoteId is burned in full regardless
    ///         of how much of `maxAmountIn` is drawn — single-shot-capped sizing, not
    ///         multi-draw (see docs/ARCHITECTURE.md). The optional permit is applied
    ///         with try/catch so a front-run permit() cannot brick the swap (standard
    ///         griefing mitigation) — the subsequent safeTransferFrom enforces the
    ///         allowance regardless. Real USDC permit is non-standard (version "2") and
    ///         MockUSDC has none, hence optional.
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
        // F-4: expiry must also be NEAR-TERM. A long-dated quote is an American option —
        // the taker chooses the moment within its life when the frozen price is most
        // favourable to them, so the leak costs close to the full band width rather than
        // some fraction of it. Read through the fallback, never $.maxQuoteTtl directly.
        uint64 ttlCap = _effectiveMaxQuoteTtl($);
        if (m.expiry > block.timestamp + ttlCap) {
            // forge-lint: disable-next-line(unsafe-typecast)
            revert QuoteExpiryTooFar(m.expiry, uint64(block.timestamp + ttlCap));
        }
        if (m.epoch != $.quoteEpoch) revert QuoteEpochStale(m.epoch, $.quoteEpoch);

        address signer = ECDSA.recover(hashSwapMessage(m), signature);
        if (!hasRole(QUOTE_SIGNER_ROLE, signer)) revert InvalidQuoteSigner(signer);

        _consumeQuote($, m.quoteId);

        // Rounds down — this contract's favor; a taker-favorable direction would let a
        // taker extract dust across many small draws (docs/ARCHITECTURE.md).
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
    ///      USDC), read the series NAV, fail closed on non-positive, stale, or
    ///      future-dated NAV, and enforce the quoted USDC amount is within
    ///      maxQuoteDeviationBps of NAV value.
    ///      Decimals: bond tokens 18dp, NAV 8dp, USDC 6dp → 1e18 * 1e8 / 1e20 = 1e6
    ///      (bond/cash decimals enforced by the registerSeries/initialize probes, F-1).
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
        // roundId/startedAt/answeredInRound are deliberately discarded. Chainlink deprecated
        // answeredInRound and OCR aggregators return it equal to roundId, as does
        // KaleidoscopeNAVFeed — so an `answeredInRound < roundId` guard cannot fire on any
        // feed we would point at. Staleness rides on updatedAt below (D-18, audit §4.10).
        (, int256 nav,, uint256 updatedAt,) = AggregatorV3Interface($.navForwarderOf[bondToken]).latestRoundData();
        if (nav <= 0) revert InvalidNav(bondToken, nav);
        // F-6: a future-dated updatedAt would otherwise satisfy the age check forever
        // (updatedAt + maxNavAgeSecs stays ahead of block.timestamp) — treat as stale.
        if (updatedAt > block.timestamp) revert StaleNav(bondToken, updatedAt);
        if (block.timestamp > updatedAt + _effectiveMaxNavAge($, bondToken)) revert StaleNav(bondToken, updatedAt);

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
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Both probes are probe-before-store
    ///         (house idiom): the forwarder is staticcall-probed for 8 decimals (the NAV
    ///         scaling in _checkQuoteBand assumes 8dp) and the bond token for 18 decimals
    ///         (F-1 — the /1e20 ladder assumes 18dp bond / 8dp NAV / 6dp USDC and
    ///         mis-scales silently for anything else). Re-registering an active series
    ///         just updates its forwarder.
    /// @param token        GyldBondToken proxy address (18 decimals).
    /// @param navForwarder NAVFeedForwarder paired with the series (stable address).
    function registerSeries(address token, address navForwarder) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || navForwarder == address(0)) revert ZeroAddress();
        // Probe-before-store (house idiom): forwarder must report 8 decimals.
        (bool ok, bytes memory data) = navForwarder.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length != 32 || abi.decode(data, (uint8)) != 8) revert NotValidForwarder(navForwarder);
        // Same probe on the bond token (F-1): it must report 18 decimals.
        (bool tokenOk, bytes memory tokenData) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!tokenOk || tokenData.length != 32) revert InvalidTokenDecimals(token, 0);
        uint8 tokenDecimals = abi.decode(tokenData, (uint8));
        if (tokenDecimals != 18) revert InvalidTokenDecimals(token, tokenDecimals);
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
    ///
    ///         A PAUSED bond token blocks this call. Clearing the balance requires
    ///         withdraw(), which a paused token blocks (see withdraw below), so the
    ///         revert you get is SeriesNotEmpty — naming the balance, not the pause
    ///         that is stopping you from clearing it. Check token.paused() before
    ///         opening the timelock proposal; see the runbook's "Evacuating a paused
    ///         bond token".
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
        // Clear the per-series age override too (FIND-022). Leaving it would silently
        // re-apply a matured series' threshold if the same token were ever re-registered.
        delete $.maxNavAgeSecsOf[token];
        emit SeriesDeregistered(token);
    }

    // ── Admin: band params, allowlist, withdrawal wallet ──────────────────────

    /// @notice Set the quote-vs-NAV sanity band in basis points.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Capped at
    ///         MAX_QUOTE_DEVIATION_BPS_CEILING (1000 bps = 10%), NOT at BPS_DENOMINATOR.
    ///         The ceiling is deliberate (GYL-1135) and the knob is asymmetric: the
    ///         restrictive end (0) forces quotes to match NAV exactly and is merely a
    ///         soft-pause of executeSwap, whereas the permissive end is "accept a signed
    ///         quote at an arbitrary price". A ±100% band — the old bound — admits
    ///         anything from zero to 2× NAV, i.e. no band at all. Since this band and the
    ///         quote TTL are the containment on a compromised quote-signer key, an admin
    ///         must not be able to widen it into a no-op. See the constant for why 10%.
    /// @param newBps Band width in basis points, e.g. 200 = 2%. 0 <= newBps <= 1000.
    function setMaxQuoteDeviationBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > MAX_QUOTE_DEVIATION_BPS_CEILING) revert InvalidDeviationBps(newBps);
        _getStorage().maxQuoteDeviationBps = newBps;
        emit MaxQuoteDeviationUpdated(newBps);
    }

    /// @notice Set the max NAV feed age (seconds) before executeSwap fails closed.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Must be non-zero AND at most
    ///         MAX_NAV_AGE_CEILING (72 h). The ceiling is deliberate (GYL-1135): the
    ///         StaleNav check is the ONLY staleness defence in this system — the NAV
    ///         feed follows Chainlink read semantics and never reverts on a stale
    ///         answer — so an admin must not be able to widen it to a value that
    ///         effectively disables it. maxQuoteDeviationBps and maxQuoteTtl are bounded
    ///         for the same reason (GYL-1135) — in each the permissive end disables a
    ///         guard, here "accept an arbitrarily old price". (For this setter and the
    ///         deviation band the restrictive end is a safe soft-pause; maxQuoteTtl
    ///         differs — its zero is the UNSET sentinel, not a pause.)
    /// @param newSecs Max feed age in seconds (e.g. 86400 = 1 day). 0 < newSecs <= 72 h.
    function setMaxNavAgeSecs(uint32 newSecs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSecs == 0 || newSecs > MAX_NAV_AGE_CEILING) revert InvalidNavAge(newSecs);
        _getStorage().maxNavAgeSecs = newSecs;
        emit MaxNavAgeUpdated(newSecs);
    }

    /// @notice Hold ONE series to its own max NAV age instead of the global value.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE (audit FIND-022). The global
    ///         `maxNavAgeSecs` is a single value applied to every registered series, so
    ///         a feed pushing hourly and one pushing daily are held to one threshold
    ///         that is necessarily wrong for one of them: sized for the daily feed, the
    ///         hourly one may be most of a day dead and still settle.
    ///
    ///         The SAME 72 h ceiling as the global setter applies (D-16). An override is
    ///         a per-series tightening or loosening WITHIN that bound, never an escape
    ///         from it — otherwise a single series could be widened into the no-op the
    ///         ceiling exists to prevent.
    ///
    ///         `newSecs == 0` CLEARS the override and returns the series to the global
    ///         value. It does not mean "zero seconds", and it is the one place this
    ///         setter's zero differs from `setMaxNavAgeSecs`, where zero is rejected
    ///         because the global has no value to fall back to.
    ///
    ///         Requires the series to be registered, so a typo cannot park an override
    ///         on an address that is not a series. `deregisterSeries` clears it again.
    /// @param token   Registered bond series to hold to its own threshold.
    /// @param newSecs Max feed age in seconds for this series, or 0 to clear the
    ///                override. Non-zero values must be <= MAX_NAV_AGE_CEILING (72 h).
    function setMaxNavAgeSecsFor(address token, uint32 newSecs) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_getStorage().registeredSeries[token]) revert UnregisteredSeries(token);
        if (newSecs > MAX_NAV_AGE_CEILING) revert InvalidNavAge(newSecs);
        _getStorage().maxNavAgeSecsOf[token] = newSecs;
        emit MaxNavAgeForSeriesUpdated(token, newSecs);
    }

    /// @notice The max NAV age actually enforced for `token` by executeSwap.
    /// @dev    Resolves the override against the global fallback, so this is what the
    ///         StaleNav check will use — read this rather than `maxNavAgeSecs()` when
    ///         reasoning about one series (audit FIND-022).
    function maxNavAgeSecsFor(address token) external view returns (uint32) {
        return _effectiveMaxNavAge(_getStorage(), token);
    }

    /// @notice Set the upper bound on quote lifetime (seconds).
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. executeSwap rejects quotes expiring
    ///         further than this far in the future (F-4), so a buggy or compromised
    ///         signer cannot issue long-dated quotes. Capped at MAX_QUOTE_TTL_CEILING
    ///         (10 minutes) — the setter previously had NO validation at all, and `uint64`
    ///         reaches ~584 billion years, so one admin call could defeat quote expiry
    ///         outright and leave a leaked signed quote executable forever.
    ///
    ///         PASSING ZERO DOES NOT PAUSE ANYTHING. Zero is the unset sentinel and
    ///         resets the cap to DEFAULT_MAX_QUOTE_TTL (90 s) — the fallback that keeps
    ///         an upgraded proxy working. To halt swaps use `pause()`, which is a hot key
    ///         (PAUSER_ROLE) and lands in one block, rather than this setter, which in
    ///         production waits on the 48 h timelock.
    ///
    ///         The knob is genuinely two-way between 1 second and the 10-minute
    ///         ceiling, so the TTL can be widened during a congestion incident — or
    ///         tightened further — without an upgrade. Beyond 10 minutes there is no
    ///         admin call: the ceiling is a `constant` and moving it needs new code.
    ///         Note the cap is compared against the EXECUTING block, not signing time:
    ///         setting it below the TTL the quote service issues does not shorten quote
    ///         life, it forbids prompt execution until the quote is nearly expired. Keep
    ///         this above the service's longest issued TTL (~60s class today). See the
    ///         constant for the full rationale.
    /// @param newTtl Max quote lifetime in seconds (e.g. 90 = the shipped default).
    ///               0 resets to the default; otherwise 0 < newTtl <= 600 (10 min).
    function setMaxQuoteTtl(uint64 newTtl) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTtl > MAX_QUOTE_TTL_CEILING) revert InvalidQuoteTtl(newTtl);
        _getStorage().maxQuoteTtl = newTtl;
        emit MaxQuoteTtlUpdated(newTtl);
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
    ///         evacuated.
    ///
    ///         Scope of that exemption: it covers THIS contract's pause only. Moving a
    ///         GyldBondToken calls its `transfer`, which is `whenNotPaused` on the token,
    ///         so a paused bond token blocks its own evacuation — the revert is
    ///         `EnforcedPause`, raised by that `whenNotPaused` modifier on
    ///         GyldBondToken.transfer itself, not here and not in the token's
    ///         `_update` (which carries only the sanctions check). That is a
    ///         design requirement: a pause inventory can be moved through is not a pause,
    ///         and the swap holds no privileged position on the token. Do not add a
    ///         bypass. Operators unpause the token, withdraw, then re-pause (PAUSER_ROLE
    ///         on the token — no admin, no timelock); see the runbook's "Evacuating a
    ///         paused bond token". USDC has no pause and is unaffected.
    ///
    ///         CEI: no state to write; single external transfer guarded by
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
    /// management, including quote-signer rotation. There is no other holder by
    /// construction, so this one really is unrecoverable.
    ///
    /// Every OTHER role stays renounceable, deliberately. An earlier revision also blocked
    /// PAUSER_ROLE and TREASURER_ROLE (F-7) on the theory that a sole holder self-renouncing
    /// would strand incident response. That guard was inert and mildly harmful, so it was
    /// removed: DEFAULT_ADMIN_ROLE administers every role (no `_setRoleAdmin` call anywhere,
    /// `getRoleAdmin`/`grantRole` unoverridden), so a renounce is never permanent — it costs
    /// one re-grant. Meanwhile OZ's `renounceRole` only ever affects the caller
    /// (`callerConfirmation == msg.sender`), so there is no accidental or third-party path to
    /// it, and both roles are held by M-of-N wallets in production. What the guard did remove
    /// is the one case that matters: a holder who KNOWS their key is compromised could no
    /// longer shed the role immediately and had to wait on a timelocked revokeRole instead.
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    // ── UUPS upgrade authorization ────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
