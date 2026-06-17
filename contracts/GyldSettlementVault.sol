// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Read-only view of a NAVFeedForwarder (Chainlink AggregatorV3 shape, 8 decimals).
interface INavForwarder {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title GyldSettlementVault
/// @notice LP-funded liquidity pool backing instant atomic settlement. Holds bond-token
///         inventory (token source on buys) and USDC (lender on redemptions). Buys and
///         redemptions net on this balance sheet — collateral tokens from redemptions
///         re-enter inventory and serve the next buyer; only NET flow is bridged to the
///         broker by the treasurer, each bridge booking a USDC-denominated receivable
///         owed by Kaleidoscope so LP share price never dips while money is in flight:
///
///           totalAssets = USDC + Σ inventoryᵢ·NAVᵢ + Σ replenishmentOwedᵢ + Σ buybackOwedᵢ
///
///         Inventory is replenished ONLY via the existing IssuanceManager mint-at-fill
///         path (this vault is a whitelisted AP). This contract has no mint authority.
///
/// Design:
///   - No standing ERC-20 allowances ever leave this vault. The outgoing swap leg is
///     PUSHED inside onSwap (Hashflow Router→Pool pattern; their June-2023 exploit was
///     a peripheral contract holding open transferFrom claims on pool funds).
///   - onSwap enforces a NAV sanity band (maxQuoteDeviationBps vs the series'
///     NAVFeedForwarder). The feed is a guard rail, NOT the execution price — the
///     signed quote is the price. latestRoundData() never reverts on staleness
///     (existing feed design); staleness alerting stays off-chain.
///   - withdraw() reverts only when FREE USDC cannot cover it; deliberately no
///     buffer-minimum revert (Ondo C4 H-01 lesson). LP exit path when liquidity is
///     deployed: wait for repay/settle or treasurer top-up. ERC-7540 queue is V2.
///   - First-depositor inflation: share conversion uses OZ-style virtual offsets,
///     plus the deploy run-book seeds a dust deposit (belt and braces).
///   - Decimals: bond tokens 18 dp, NAV 8 dp, USDC 6 dp — all conversions go through
///     the single _navValueUsdc helper (Ondo explicit decimal-scaling layer).
///
/// Roles:
///   DEFAULT_ADMIN_ROLE — upgrades, registerSeries/deregisterSeries, setSwap,
///                        setMaxQuoteDeviationBps, unpause; should be a
///                        TimelockController in production
///   SWAP_ROLE          — GyldAtomicSwap proxy; onSwap is the ONLY fund-out path
///                        on the hot path
///   TREASURER_ROLE     — Kaleidoscope ops MPC wallet; bridges NET flow to the broker
///   LP_ROLE            — KYC'd bridging-finance LPs; deposit/withdraw
///   PAUSER_ROLE        — ops multisig; pause() ONLY (asymmetric — admin resumes)
contract GyldSettlementVault is
    Initializable,
    ERC20Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 public constant SWAP_ROLE      = keccak256("SWAP_ROLE");
    bytes32 public constant TREASURER_ROLE = keccak256("TREASURER_ROLE");
    bytes32 public constant LP_ROLE        = keccak256("LP_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");

    // OZ-style anti-inflation virtual offsets (first-depositor attack mitigation).
    uint256 private constant _VIRTUAL_SHARES = 1e3;
    uint256 private constant _VIRTUAL_ASSETS = 1;

    uint16 private constant _MAX_BPS = 10_000;

    // ── ERC-7201 namespaced storage ───────────────────────────────────────────

    /// @custom:storage-location erc7201:gyld.GyldSettlementVault
    struct GyldSettlementVaultStorage {
        IERC20  usdc;
        address issuanceManager;                       // burn-commitment destination (BurnWatcher watches it)
        address swap;                                  // GyldAtomicSwap proxy (holds SWAP_ROLE)
        uint16  maxQuoteDeviationBps;                  // quote-vs-NAV sanity band, e.g. 200 = 2%
        address[] seriesList;                          // registered series, for totalAssets iteration
        mapping(address => bool)    registeredSeries;  // bond token → enabled
        mapping(address => address) navForwarderOf;    // bond token → NAVFeedForwarder (stable addr)
        mapping(address => uint256) replenishmentOwed; // USDC 6dp, drawn to fund broker buys
        mapping(address => uint256) buybackOwed;       // USDC 6dp, tokens forwarded for burn
    }

    // keccak256(abi.encode(uint256(keccak256("gyld.GyldSettlementVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_LOCATION =
        0x151c9d64c83d3cd54bf270d13fe414c5f5d542f89250a5fe95ec1c71ad52fb00;

    function _getStorage() private pure returns (GyldSettlementVaultStorage storage $) {
        assembly {
            $.slot := _STORAGE_LOCATION
        }
    }

    // ── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error UnregisteredSeries(address token);
    error NotOneBondLeg(address tokenIn, address tokenOut);
    error QuotePriceOutOfBand(uint256 quotedUsdcAmount, uint256 navUsdcAmount);
    error InsufficientInventory(address token, uint256 requested, uint256 available);
    error InsufficientUsdcLiquidity(uint256 requested, uint256 available);
    error ObligationUnderflow(address token, uint256 requested, uint256 outstanding);
    error SeriesNotEmpty(address token);
    error InvalidDeviationBps(uint16 bps);
    error InvalidNav(address token, int256 nav);
    error NotValidForwarder(address forwarder);
    error NotValidSwap(address swap);
    error CannotRenounceAdminRole();

    // ── Events ────────────────────────────────────────────────────────────────

    event SwapServed(
        address indexed taker, address indexed tokenIn, uint256 amountIn, address indexed tokenOut, uint256 amountOut
    );
    event Deposited(address indexed lp, uint256 usdcAmount, uint256 shares);
    event Withdrawn(address indexed lp, uint256 shares, uint256 usdcAmount);
    event ReplenishmentDrawn(address indexed token, uint256 usdcAmount);
    event ReplenishmentSettled(address indexed token, uint256 usdcValue);
    event ForwardedForBurn(address indexed token, uint256 tokenAmount, uint256 usdcValue);
    event UsdcRepaid(address indexed token, uint256 usdcAmount);
    event SeriesRegistered(address indexed token, address indexed navForwarder);
    event SeriesDeregistered(address indexed token);
    event SwapUpdated(address indexed previousSwap, address indexed newSwap);
    event MaxQuoteDeviationUpdated(uint16 newBps);

    // ── Constructor / Initializer ─────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param defaultAdmin     Should be a TimelockController in production.
    /// @param pauser           Ops multisig — may pause() but not unpause().
    /// @param treasurer        Kaleidoscope ops MPC wallet (TREASURER_ROLE).
    /// @param usdc_            USDC token address (6 decimals).
    /// @param issuanceManager_ IssuanceManager proxy — burn-commitment destination the
    ///                         backend BurnWatcher already watches. This vault must be
    ///                         added to its AP whitelist post-deploy (run-book step).
    function initialize(address defaultAdmin, address pauser, address treasurer, address usdc_, address issuanceManager_)
        external
        initializer
    {
        if (
            defaultAdmin == address(0) || pauser == address(0) || treasurer == address(0) || usdc_ == address(0)
                || issuanceManager_ == address(0)
        ) revert ZeroAddress();
        __ERC20_init("Gyld Settlement Vault LP", "gyldLP");
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        GyldSettlementVaultStorage storage $ = _getStorage();
        $.usdc                 = IERC20(usdc_);
        $.issuanceManager      = issuanceManager_;
        $.maxQuoteDeviationBps = 200; // 2%
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE,        pauser);
        _grantRole(TREASURER_ROLE,     treasurer);
    }

    // ── Public getters ────────────────────────────────────────────────────────

    /// @notice USDC token this vault pools (6 decimals).
    function usdc() external view returns (IERC20) { return _getStorage().usdc; }

    /// @notice IssuanceManager proxy — destination of forwardForBurn commitments.
    function issuanceManager() external view returns (address) { return _getStorage().issuanceManager; }

    /// @notice GyldAtomicSwap proxy currently holding SWAP_ROLE via setSwap.
    function swap() external view returns (address) { return _getStorage().swap; }

    /// @notice Quote-vs-NAV sanity band in basis points (e.g. 200 = 2%).
    function maxQuoteDeviationBps() external view returns (uint16) { return _getStorage().maxQuoteDeviationBps; }

    /// @notice Returns whether `token` is a registered bond series.
    function registeredSeries(address token) external view returns (bool) {
        return _getStorage().registeredSeries[token];
    }

    /// @notice NAVFeedForwarder paired with `token`; address(0) if unregistered.
    function navForwarderOf(address token) external view returns (address) {
        return _getStorage().navForwarderOf[token];
    }

    /// @notice Outstanding USDC-denominated receivables owed by Kaleidoscope for `token`.
    /// @param  token Bond series address.
    /// @return replenishment USDC (6dp) drawn to fund broker buys, not yet settled.
    /// @return buyback       USDC (6dp) for collateral forwarded to burn, not yet repaid.
    function obligationsOf(address token) external view returns (uint256 replenishment, uint256 buyback) {
        GyldSettlementVaultStorage storage $ = _getStorage();
        return ($.replenishmentOwed[token], $.buybackOwed[token]);
    }

    // ── Hot path: serve a swap leg ────────────────────────────────────────────

    /// @notice Called by GyldAtomicSwap AFTER the incoming leg has landed here.
    ///         Validates exactly one leg is a registered bond series, sanity-checks the
    ///         quoted price against NAV, then PUSHES tokenOut to the taker (no standing
    ///         allowances are ever granted out of this vault).
    /// @dev    Caller must hold SWAP_ROLE. The available-balance check on the outgoing
    ///         leg distinguishes InsufficientInventory (buy) from
    ///         InsufficientUsdcLiquidity (redeem) for off-chain alerting.
    /// @param taker     End user receiving tokenOut (already screened by the bond
    ///                  token's _update on the incoming leg or the outgoing push).
    /// @param tokenIn   Leg the user paid; already transferred to this vault.
    /// @param amountIn  Amount of tokenIn received.
    /// @param tokenOut  Leg the user receives from this vault.
    /// @param amountOut Amount of tokenOut to push.
    function onSwap(address taker, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut)
        external
        nonReentrant
        whenNotPaused
        onlyRole(SWAP_ROLE)
    {
        GyldSettlementVaultStorage storage $ = _getStorage();
        bool buy    = $.registeredSeries[tokenOut] && tokenIn  == address($.usdc);
        bool redeem = $.registeredSeries[tokenIn]  && tokenOut == address($.usdc);
        if (buy == redeem) revert NotOneBondLeg(tokenIn, tokenOut);

        address bondToken   = buy ? tokenOut : tokenIn;
        uint256 tokenAmount = buy ? amountOut : amountIn;
        uint256 usdcAmount  = buy ? amountIn  : amountOut;
        _checkQuoteBand($, bondToken, tokenAmount, usdcAmount);

        uint256 available = IERC20(tokenOut).balanceOf(address(this));
        if (amountOut > available) {
            if (buy) revert InsufficientInventory(tokenOut, amountOut, available);
            revert InsufficientUsdcLiquidity(amountOut, available);
        }
        IERC20(tokenOut).safeTransfer(taker, amountOut);
        emit SwapServed(taker, tokenIn, amountIn, tokenOut, amountOut);
    }

    // ── LP share accounting ───────────────────────────────────────────────────

    /// @notice Deposit USDC for LP shares at the current share price.
    /// @dev    Caller must hold LP_ROLE (KYC'd LPs only). Shares are computed BEFORE
    ///         the transfer lands so the deposit cannot dilute itself.
    /// @param  usdcAmount USDC (6dp) to deposit. Must be greater than zero.
    /// @return shares     LP shares minted to the caller.
    function deposit(uint256 usdcAmount)
        external
        nonReentrant
        whenNotPaused
        onlyRole(LP_ROLE)
        returns (uint256 shares)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        shares = _convertToShares(usdcAmount);
        _getStorage().usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        _mint(msg.sender, shares);
        emit Deposited(msg.sender, usdcAmount, shares);
    }

    /// @notice Burn LP shares for free USDC at the current share price.
    /// @dev    Reverts InsufficientUsdcLiquidity only when FREE USDC cannot cover the
    ///         payout (liquidity is out on inventory or obligations) — deliberately no
    ///         buffer-minimum revert (Ondo C4 H-01 lesson); a queued ERC-7540 exit is
    ///         the flagged V2 follow-up. Documented LP exit path when liquidity is
    ///         deployed: wait for repay/settle or treasurer top-up.
    /// @param  shares     LP shares to burn. Must be greater than zero.
    /// @return usdcAmount USDC (6dp) paid out to the caller.
    function withdraw(uint256 shares)
        external
        nonReentrant
        whenNotPaused
        onlyRole(LP_ROLE)
        returns (uint256 usdcAmount)
    {
        if (shares == 0) revert ZeroAmount();
        usdcAmount = (shares * (totalAssets() + _VIRTUAL_ASSETS)) / (totalSupply() + _VIRTUAL_SHARES);
        GyldSettlementVaultStorage storage $ = _getStorage();
        uint256 free = $.usdc.balanceOf(address(this));
        if (usdcAmount > free) revert InsufficientUsdcLiquidity(usdcAmount, free);
        _burn(msg.sender, shares);
        $.usdc.safeTransfer(msg.sender, usdcAmount);
        emit Withdrawn(msg.sender, shares, usdcAmount);
    }

    /// @dev OZ ERC-4626-style conversion with virtual offsets (anti-inflation).
    function _convertToShares(uint256 assets) private view returns (uint256) {
        return (assets * (totalSupply() + _VIRTUAL_SHARES)) / (totalAssets() + _VIRTUAL_ASSETS);
    }

    // ── Treasurer bridge: NET flow only, each leg books a receivable ──────────

    /// @notice Draw USDC to fund a NET broker buy. Books a replenishment receivable;
    ///         extinguished when IssuanceManager.subscribe() mints fills to this vault.
    /// @dev    Caller must hold TREASURER_ROLE. Receivable in, USDC out — totalAssets
    ///         is unchanged, so the LP share price never dips while money is in flight.
    /// @param token      Registered bond series the draw replenishes.
    /// @param usdcAmount USDC (6dp) transferred to the treasurer. Must not exceed free USDC.
    function drawForReplenishment(address token, uint256 usdcAmount) external nonReentrant onlyRole(TREASURER_ROLE) {
        GyldSettlementVaultStorage storage $ = _getStorage();
        if (!$.registeredSeries[token]) revert UnregisteredSeries(token);
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 free = $.usdc.balanceOf(address(this));
        if (usdcAmount > free) revert InsufficientUsdcLiquidity(usdcAmount, free);
        $.replenishmentOwed[token] += usdcAmount; // receivable in, USDC out: totalAssets unchanged
        $.usdc.safeTransfer(msg.sender, usdcAmount);
        emit ReplenishmentDrawn(token, usdcAmount);
    }

    /// @notice Extinguish a replenishment receivable after subscribe-minted tokens land
    ///         (tokens arrive directly from IssuanceManager.subscribe(token, vault, n)).
    /// @dev    Caller must hold TREASURER_ROLE. The minted inventory is already on this
    ///         balance sheet at NAV, so writing the receivable down keeps totalAssets
    ///         continuous. Partial settlement is allowed (mint-at-fill streams fills).
    /// @param token     Bond series whose receivable is being settled.
    /// @param usdcValue USDC (6dp) portion to extinguish. Must not exceed the outstanding amount.
    function settleReplenishment(address token, uint256 usdcValue) external onlyRole(TREASURER_ROLE) {
        GyldSettlementVaultStorage storage $ = _getStorage();
        uint256 owed = $.replenishmentOwed[token];
        if (usdcValue > owed) revert ObligationUnderflow(token, usdcValue, owed);
        $.replenishmentOwed[token] = owed - usdcValue; // receivable out, inventory (already here) in
        emit ReplenishmentSettled(token, usdcValue);
    }

    /// @notice Forward NET redemption collateral to the IssuanceManager — the existing
    ///         on-chain burn-commitment signal the backend BurnWatcher already consumes.
    ///         Books a buyback receivable at current NAV until Kaleidoscope repays USDC
    ///         from the T+2 broker sale.
    /// @dev    Caller must hold TREASURER_ROLE. Receivable in, tokens out — totalAssets
    ///         is unchanged.
    /// @param token       Registered bond series being forwarded for burn.
    /// @param tokenAmount Token amount (18dp) to forward. Must be greater than zero.
    function forwardForBurn(address token, uint256 tokenAmount) external nonReentrant onlyRole(TREASURER_ROLE) {
        GyldSettlementVaultStorage storage $ = _getStorage();
        if (!$.registeredSeries[token]) revert UnregisteredSeries(token);
        if (tokenAmount == 0) revert ZeroAmount();
        uint256 usdcValue = _navValueUsdc($, token, tokenAmount);
        $.buybackOwed[token] += usdcValue; // receivable in, token out: totalAssets unchanged
        IERC20(token).safeTransfer($.issuanceManager, tokenAmount);
        emit ForwardedForBurn(token, tokenAmount, usdcValue);
    }

    /// @notice Repay a buyback receivable in USDC (pulled from the treasurer wallet).
    /// @dev    Caller must hold TREASURER_ROLE and must have approved this vault for
    ///         `usdcAmount`. Partial repayment is allowed.
    /// @param token      Bond series whose receivable is being repaid.
    /// @param usdcAmount USDC (6dp) to repay. Must not exceed the outstanding amount.
    function repayUsdc(address token, uint256 usdcAmount) external nonReentrant onlyRole(TREASURER_ROLE) {
        GyldSettlementVaultStorage storage $ = _getStorage();
        uint256 owed = $.buybackOwed[token];
        if (usdcAmount > owed) revert ObligationUnderflow(token, usdcAmount, owed);
        $.buybackOwed[token] = owed - usdcAmount;
        $.usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        emit UsdcRepaid(token, usdcAmount);
    }

    // ── Valuation ─────────────────────────────────────────────────────────────

    /// @notice Total pool value in USDC (6dp): free USDC + inventory at NAV +
    ///         outstanding receivables across all registered series.
    function totalAssets() public view returns (uint256 total) {
        GyldSettlementVaultStorage storage $ = _getStorage();
        total = $.usdc.balanceOf(address(this));
        uint256 n = $.seriesList.length;
        for (uint256 i = 0; i < n;) {
            address token = $.seriesList[i];
            total += _navValueUsdc($, token, IERC20(token).balanceOf(address(this)));
            total += $.replenishmentOwed[token] + $.buybackOwed[token];
            unchecked { i++; }
        }
    }

    /// @notice Current NAV value (USDC, 6dp) of this vault's `token` inventory.
    /// @param  token Registered bond series address.
    function inventoryValue(address token) public view returns (uint256) {
        GyldSettlementVaultStorage storage $ = _getStorage();
        if (!$.registeredSeries[token]) revert UnregisteredSeries(token);
        return _navValueUsdc($, token, IERC20(token).balanceOf(address(this)));
    }

    /// @dev token 18dp × NAV 8dp → USDC 6dp. Forwarder reads never revert on staleness
    ///      (existing feed design); staleness alerting is off-chain. A non-positive NAV
    ///      is a hard feed fault and reverts fail-closed — valuing inventory at zero
    ///      (or wrapping negative) would silently mark down the LP share price.
    function _navValueUsdc(GyldSettlementVaultStorage storage $, address token, uint256 tokenAmount)
        private
        view
        returns (uint256)
    {
        (, int256 nav,,,) = INavForwarder($.navForwarderOf[token]).latestRoundData();
        if (nav <= 0) revert InvalidNav(token, nav);
        // forge-lint: disable-next-line(unsafe-typecast)
        return (tokenAmount * uint256(nav)) / 1e20; // 1e18 (token) * 1e8 (nav) / 1e20 = 1e6; nav > 0 checked above
    }

    /// @dev NAV sanity band: the signed quote is the price; the feed only bounds it.
    function _checkQuoteBand(GyldSettlementVaultStorage storage $, address token, uint256 tokenAmount, uint256 usdcAmount)
        private
        view
    {
        uint256 navValue = _navValueUsdc($, token, tokenAmount);
        uint256 band = (navValue * $.maxQuoteDeviationBps) / _MAX_BPS;
        if (usdcAmount > navValue + band || usdcAmount + band < navValue) {
            revert QuotePriceOutOfBand(usdcAmount, navValue);
        }
    }

    // ── Series registry ───────────────────────────────────────────────────────

    /// @notice Register a bond series so the vault can hold, value, and serve it.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. The forwarder is probed via
    ///         staticcall before storing — rejects EOAs, wrong contracts, and feeds
    ///         that don't report 8 decimals (the NAV scaling in _navValueUsdc assumes
    ///         8dp). Re-registering an active series just updates its forwarder.
    /// @param token        GyldBondToken proxy address (18 decimals).
    /// @param navForwarder NAVFeedForwarder paired with the series (stable address).
    function registerSeries(address token, address navForwarder) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0) || navForwarder == address(0)) revert ZeroAddress();
        // Probe-before-store (house idiom): forwarder must report 8 decimals.
        (bool ok, bytes memory data) = navForwarder.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length != 32 || abi.decode(data, (uint8)) != 8) revert NotValidForwarder(navForwarder);
        GyldSettlementVaultStorage storage $ = _getStorage();
        if (!$.registeredSeries[token]) $.seriesList.push(token);
        $.registeredSeries[token] = true;
        $.navForwarderOf[token]   = navForwarder;
        emit SeriesRegistered(token, navForwarder);
    }

    /// @notice Deregister a matured bond series, removing it from totalAssets iteration.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Reverts SeriesNotEmpty while the
    ///         vault still holds inventory or any receivable is outstanding — silently
    ///         dropping valued positions from totalAssets would mark down the LP share
    ///         price. Wind the series down first (forwardForBurn + repayUsdc + settle).
    /// @param token Registered bond series to remove.
    function deregisterSeries(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        GyldSettlementVaultStorage storage $ = _getStorage();
        if (!$.registeredSeries[token]) revert UnregisteredSeries(token);
        if (
            IERC20(token).balanceOf(address(this)) != 0 || $.replenishmentOwed[token] != 0
                || $.buybackOwed[token] != 0
        ) revert SeriesNotEmpty(token);
        uint256 n = $.seriesList.length;
        for (uint256 i = 0; i < n;) {
            if ($.seriesList[i] == token) {
                $.seriesList[i] = $.seriesList[n - 1];
                $.seriesList.pop();
                break;
            }
            unchecked { i++; }
        }
        delete $.registeredSeries[token];
        delete $.navForwarderOf[token];
        emit SeriesDeregistered(token);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Point the vault at a new GyldAtomicSwap proxy. Atomically revokes
    ///         SWAP_ROLE from the previous swap and grants it to the new one, so at
    ///         most one swap contract can ever drive onSwap.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. The candidate is probed via
    ///         staticcall before storing — rejects EOAs, wrong contracts, and stubs
    ///         that don't expose SWAP_MESSAGE_TYPEHASH().
    /// @param newSwap GyldAtomicSwap proxy address.
    function setSwap(address newSwap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSwap == address(0)) revert ZeroAddress();
        // Probe-before-store (house idiom): swap must expose SWAP_MESSAGE_TYPEHASH().
        (bool ok, bytes memory data) = newSwap.staticcall(abi.encodeWithSignature("SWAP_MESSAGE_TYPEHASH()"));
        if (!ok || data.length != 32) revert NotValidSwap(newSwap);
        GyldSettlementVaultStorage storage $ = _getStorage();
        address previous = $.swap;
        if (previous != address(0)) _revokeRole(SWAP_ROLE, previous);
        _grantRole(SWAP_ROLE, newSwap);
        $.swap = newSwap;
        emit SwapUpdated(previous, newSwap);
    }

    /// @notice Set the quote-vs-NAV sanity band in basis points.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. Capped at 10_000 (100%); zero is
    ///         permitted and forces quotes to match NAV exactly (effectively a
    ///         soft-pause of onSwap given rounding).
    /// @param newBps Band width in basis points, e.g. 200 = 2%.
    function setMaxQuoteDeviationBps(uint16 newBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newBps > _MAX_BPS) revert InvalidDeviationBps(newBps);
        _getStorage().maxQuoteDeviationBps = newBps;
        emit MaxQuoteDeviationUpdated(newBps);
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    /// @notice Halt onSwap, deposit, and withdraw. Asymmetric by design: PAUSER (ops
    ///         multisig) can halt cheaply; only DEFAULT_ADMIN_ROLE (timelock) resumes.
    ///         Treasurer bridge functions stay live so receivables can still unwind.
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }

    /// @notice Resume onSwap, deposit, and withdraw. Deliberately admin-gated (see pause()).
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    // ── Role management overrides ─────────────────────────────────────────────

    /// DEFAULT_ADMIN_ROLE cannot be renounced — losing it permanently bricks UUPS
    /// upgrades, unpause, series registration, and all role management.
    /// Intentional removal must go through revokeRole (explicit, two-party action).
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    // ── UUPS upgrade authorization ────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
