// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @dev Read-only interface for the Chainalysis on-chain sanctions oracle.
/// Mainnet: 0x40C57923924B5c5c5455c48D93317139ADDaC8fb
interface ISanctionsList {
    function isSanctioned(address addr) external view returns (bool);
}

// ── ERC-8056 "Scaled UI Amount" (Draft, 2025-10-20) ──────────────────────────
// Interfaces are transcribed verbatim from the EIP so that `type(...).interfaceId`
// is computed from the canonical selectors rather than a hand-copied constant.
// The EIP is still Draft — if the selectors change upstream, the ERC-165 ids below
// change with it automatically and GyldBondToken.ScaledUIAmount.t.sol (which pins
// all four ids against the published hex values) fails loudly.

/// @dev Core interface. ERC-165 id `0xa60bf13d` (== `uiMultiplier()` selector; events
///      do not contribute to an interface id).
interface IScaledUIAmount {
    /// @notice Emitted whenever the UI multiplier is changed or (re)scheduled.
    /// @param oldMultiplier        multiplier live immediately before `effectiveAtTimestamp`
    /// @param newMultiplier        multiplier live from `effectiveAtTimestamp` onwards
    /// @param effectiveAtTimestamp activation time; 0 means "effective immediately / always"
    event UIMultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier, uint256 effectiveAtTimestamp);

    /// @notice OPTIONAL per the EIP. Emitted alongside ERC-20 `Transfer` with the
    ///         UI-adjusted amount so indexers need no separate multiplier read.
    event TransferWithUIAmount(address indexed from, address indexed to, uint256 amount, uint256 uiAmount);

    /// @notice Currently effective UI multiplier, 18-dp fixed point (1e18 == 1.0x).
    function uiMultiplier() external view returns (uint256);
}

/// @dev REQUIRED extension per the EIP ("Compliant contracts MUST implement
///      IScaledUIAmountNewUIMultiplier"). ERC-165 id `0x4bd27648`.
interface IScaledUIAmountNewUIMultiplier {
    function newUIMultiplier() external view returns (uint256);
    function effectiveAt() external view returns (uint256);
}

/// @dev OPTIONAL conversion extension. ERC-165 id `0x57854fc3`.
interface IScaledUIAmountConversion {
    function toUIAmount(uint256 rawAmount) external view returns (uint256);
    function fromUIAmount(uint256 uiAmount) external view returns (uint256);
}

/// @dev OPTIONAL balances extension. ERC-165 id `0xd890fd71`.
interface IScaledUIAmountBalances {
    function balanceOfUI(address account) external view returns (uint256);
    function totalSupplyUI() external view returns (uint256);
}

/// @title GyldBondToken
/// @notice Standard ERC-20 per bond series. One token = one unit of bond ownership.
///
///         Token balances are fixed — they only change via mint (subscription) and
///         burn (redemption). Value accrual (coupons, NAV appreciation) is reflected
///         exclusively in the paired KaleidoscopeNAVFeed oracle, not in balances.
///
///         A display-only ERC-8056 (Scaled UI Amount) extension lets integrators show a
///         NAV-scaled balance (`balanceOfUI`) without affecting real balances. The
///         multiplier is rate-limited and deviation-capped on the same terms as
///         KaleidoscopeNAVFeed.updateAnswer — see `_scheduleUiMultiplier`.
///
/// UUPS-upgradeable — the proxy pattern keeps bond token addresses stable post-issuance.
/// Upgrades require DEFAULT_ADMIN_ROLE (a TimelockController in production).
///
/// Compliance:
///   - All secondary transfers check sender, receiver, AND spender (msg.sender in transferFrom)
///     against the Chainalysis on-chain sanctions oracle.
///   - The check is fail-closed: if the oracle call reverts, the transfer reverts.
///   - Mint and burn skip the sanctions check — IssuanceManager pre-screens APs off-chain.
///   - No internal blocklist — sanctioning decisions are made by Chainalysis, not the platform.
///
/// Roles:
///   DEFAULT_ADMIN_ROLE — grants / revokes all other roles; should be a TimelockController
///   MINTER_ROLE        — IssuanceManager only
///   BURNER_ROLE        — IssuanceManager only
///   PAUSER_ROLE        — ops multisig (separate signer set from governance)
///   UI_MULTIPLIER_ROLE — NAV publisher; display-only, cannot move real balances
contract GyldBondToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IScaledUIAmount,
    IScaledUIAmountNewUIMultiplier,
    IScaledUIAmountConversion,
    IScaledUIAmountBalances
{
    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UI_MULTIPLIER_ROLE = keccak256("UI_MULTIPLIER_ROLE");

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice Fixed-point scale for the display-only UI multiplier. 1e18 == 1.0x (no scaling).
    ///         Mandated by ERC-8056 ("The UI multiplier MUST use 18 decimal places").
    uint256 public constant UI_MULTIPLIER_SCALE = 1e18;

    /// @notice Minimum spacing between consecutive UI-multiplier ACTIVATIONS.
    ///         Deliberately identical to KaleidoscopeNAVFeed.MIN_UPDATE_INTERVAL: the
    ///         multiplier is a mirror of that feed's NAV, so it inherits the same
    ///         "a compromised publisher key must not be able to oscillate the value"
    ///         constraint. Not applied to the very first write (nothing to space from),
    ///         mirroring the feed's `_updatedAt == 0` exemption.
    uint256 public constant MIN_UI_MULTIPLIER_UPDATE_INTERVAL = 1 hours;

    /// @notice Maximum per-update UI-multiplier deviation, in basis points.
    ///         1000 bps = 10%, matching KaleidoscopeNAVFeed.MAX_PRICE_DEVIATION_BPS.
    ///         Unlike the feed there is no first-write exemption: the multiplier always
    ///         has a meaningful predecessor (1.0x at worst), so the band always applies.
    uint256 public constant MAX_UI_MULTIPLIER_DEVIATION_BPS = 1000;

    /// @notice Denominator for basis-point arithmetic (1 bps = 1 / 10_000).
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ── ERC-7201 namespaced storage ───────────────────────────────────────────

    /// @custom:storage-location erc7201:gyld.GyldBondToken
    ///
    /// UPGRADE SAFETY: every field below is APPEND-ONLY. `sanctionsList`, `isin` and
    /// `maturityTimestamp` are the original v1 layout and MUST keep offsets 0/1/2
    /// forever. The three ERC-8056 fields are appended at offsets 3/4/5; a proxy
    /// deployed before they existed simply reads zero from those never-written slots,
    /// which `_uiMultiplierState()` normalises (see the F-1 note there). Never insert
    /// or reorder — only append.
    struct GyldBondTokenStorage {
        ISanctionsList sanctionsList;   // offset 0 (v1)
        string isin;                    // offset 1 (v1)
        uint256 maturityTimestamp;      // offset 2 (v1)
        // ── ERC-8056 display-only scaling state (18-dp fixed point; 1e18 == 1.0x) ──
        /// Multiplier live UNTIL `uiMultiplierEffectiveAt`; i.e. the outgoing value.
        uint256 uiMultiplier;           // offset 3
        /// Multiplier live FROM `uiMultiplierEffectiveAt` onwards; i.e. the incoming value.
        uint256 newUIMultiplier;        // offset 4
        /// Activation timestamp for `newUIMultiplier`. 0 is a sentinel meaning "no
        /// schedule has ever been written" — see `_uiMultiplierState()`.
        uint256 uiMultiplierEffectiveAt; // offset 5
    }

    // keccak256(abi.encode(uint256(keccak256("gyld.GyldBondToken")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_LOCATION =
        0x0fe35ba304a016e79d78a184eb899c1e21310138e0bfe9a54648a2dfe0da0d00;

    function _getStorage() private pure returns (GyldBondTokenStorage storage $) {
        assembly {
            $.slot := _STORAGE_LOCATION
        }
    }

    // ── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error AccountSanctioned(address account);
    error CannotRenounceAdminRole();
    error NotValidSanctionsList(address addr);
    error ZeroMultiplier();
    error UiMultiplierEffectiveAtInPast(uint256 requested, uint256 currentTime);
    error UiMultiplierUpdateTooSoon(uint256 nextAllowedAt);
    error UiMultiplierDeviationTooLarge(uint256 submitted, uint256 previous);

    // ── Events ────────────────────────────────────────────────────────────────
    // UIMultiplierUpdated and TransferWithUIAmount are inherited from IScaledUIAmount
    // so their topic0 is derived from the canonical EIP signatures, not a local copy.

    event SanctionsListUpdated(address indexed newSanctionsList);

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ── Initializer ───────────────────────────────────────────────────────────

    /// @param name_              Token name (e.g. "Gyld US Treasury Bond 2026-06")
    /// @param symbol_            Ticker (e.g. "GYLD-UST-2606")
    /// @param isin_              ISO 6166 ISIN, e.g. "US912797KR72"
    /// @param maturityTimestamp_ Unix maturity timestamp; 0 if open-ended.
    /// @param defaultAdmin       Should be a TimelockController in production.
    /// @param pauser             Ops multisig — separate from governance.
    /// @param sanctionsList_     Chainalysis on-chain sanctions oracle (read-only).
    function initialize(
        string memory name_,
        string memory symbol_,
        string memory isin_,
        uint256 maturityTimestamp_,
        address defaultAdmin,
        address pauser,
        address sanctionsList_
    ) external initializer {
        __ERC20_init(name_, symbol_);
        __ERC20Permit_init(name_);
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        if (defaultAdmin == address(0) || pauser == address(0) || sanctionsList_ == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = sanctionsList_.staticcall(
            abi.encodeWithSignature("isSanctioned(address)", address(0))
        );
        if (!ok || data.length != 32) revert NotValidSanctionsList(sanctionsList_);
        GyldBondTokenStorage storage $ = _getStorage();
        $.isin = isin_;
        $.maturityTimestamp = maturityTimestamp_;
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE, pauser);
        $.sanctionsList = ISanctionsList(sanctionsList_);
        emit SanctionsListUpdated(sanctionsList_);

        // ERC-8056: start at 1.0x with nothing scheduled. Both multiplier slots are
        // written so no read path can ever observe a half-populated schedule.
        // `uiMultiplierEffectiveAt` is intentionally left at its 0 sentinel — this
        // matches the EIP reference implementation (`uint256 _effectiveAt = 0`) and
        // exempts the first setUiMultiplier call from the rate limit, exactly as
        // KaleidoscopeNAVFeed exempts its first updateAnswer.
        $.uiMultiplier = UI_MULTIPLIER_SCALE;
        $.newUIMultiplier = UI_MULTIPLIER_SCALE;
        emit UIMultiplierUpdated(0, UI_MULTIPLIER_SCALE, 0);
    }

    // NOTE (F-2): there is deliberately NO `initializeUiMultiplierV2()` reinitializer.
    // An earlier revision shipped one as `external reinitializer(2)` with no access
    // control. Its effect was benign (it wrote 1e18) but ANY address could call it, and
    // doing so permanently consumes the `reinitializer(2)` version slot — a front-runner
    // could therefore block every future v2 migration on a live proxy. It is not merely
    // gated but removed, because `_uiMultiplierState()` already normalises the
    // never-initialised state, making a post-upgrade initializer unnecessary: a bare
    // `upgradeToAndCall(impl, "")` is sufficient and the F-1 window cannot exist.

    // ── Getters ───────────────────────────────────────────────────────────────

    function isin() external view returns (string memory) { return _getStorage().isin; }
    function maturityTimestamp() external view returns (uint256) { return _getStorage().maturityTimestamp; }
    function sanctionsList() external view returns (ISanctionsList) { return _getStorage().sanctionsList; }

    // ── ERC-8056 Scaled UI Amount (display-only) ──────────────────────────────
    // Purely cosmetic view layer. Does NOT touch balanceOf/totalSupply/transfer or any
    // real accounting — the raw ERC-20 balances remain the single source of truth.
    //
    // ACTIVATION SEMANTICS (ERC-8056 leaves scheduling to the implementer; this is ours):
    //   * A write stores the outgoing value in `uiMultiplier`, the incoming value in
    //     `newUIMultiplier`, and the switchover time in `uiMultiplierEffectiveAt`.
    //   * `uiMultiplier()` returns `newUIMultiplier` once
    //     `block.timestamp >= uiMultiplierEffectiveAt`, else the outgoing `uiMultiplier`.
    //     The boundary is INCLUSIVE (`>=`), matching the EIP reference implementation:
    //     the new value is live for the whole of the block that reaches effectiveAt.
    //   * At most ONE schedule is pending at a time. Writing again while a schedule is
    //     still pending REPLACES it (the outgoing value is untouched, so a mis-scheduled
    //     value can be corrected before anyone ever sees it).
    //   * After activation `newUIMultiplier() == uiMultiplier()` and `effectiveAt()` stays
    //     in the past. This preserves the invariant integrators rely on:
    //     `block.timestamp >= effectiveAt()` implies `uiMultiplier() == newUIMultiplier()`.
    //   * `setUiMultiplier(m)` is shorthand for scheduling at `block.timestamp`, i.e.
    //     effective in the same block. The EIP's reference `setUIMultiplier` insists on a
    //     strictly-future timestamp; we allow "now" because the rate limit and deviation
    //     cap below already bound the damage, and because KaleidoscopeNAVFeed — the feed
    //     this multiplier mirrors — likewise applies its updates immediately. Operators
    //     who want a pre-announced change (e.g. a stock split) use scheduleUiMultiplier.

    /// @notice Currently effective display-only UI scaling multiplier (1e18 == 1.0x).
    /// @dev    Never returns 0, even on a proxy upgraded from a pre-ERC-8056 implementation.
    function uiMultiplier() external view override returns (uint256) {
        (uint256 active, , ) = _uiMultiplierState();
        return active;
    }

    /// @notice The pending multiplier scheduled to take effect at `effectiveAt()`.
    /// @dev    Equals `uiMultiplier()` when nothing is pending (including once a schedule
    ///         has matured), so integrators can compare the two to detect a pending change.
    function newUIMultiplier() external view override returns (uint256) {
        (, uint256 pending, ) = _uiMultiplierState();
        return pending;
    }

    /// @notice Timestamp at which `newUIMultiplier()` becomes effective.
    /// @dev    0 means "nothing has ever been scheduled"; a past value means the last
    ///         scheduled change has already activated.
    function effectiveAt() external view override returns (uint256) {
        (, , uint256 effAt) = _uiMultiplierState();
        return effAt;
    }

    /// @notice `account`'s balance scaled by the UI multiplier — for display only.
    function balanceOfUI(address account) external view override returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    /// @notice Total supply scaled by the UI multiplier — for display only.
    function totalSupplyUI() external view override returns (uint256) {
        return toUIAmount(totalSupply());
    }

    /// @notice Scale a raw token amount into its UI (NAV-scaled) representation.
    /// @dev    Rounds down. Reverts on overflow rather than wrapping (Solidity 0.8 checked
    ///         arithmetic), satisfying the EIP's "MUST handle potential overflow".
    function toUIAmount(uint256 rawAmount) public view override returns (uint256) {
        (uint256 active, , ) = _uiMultiplierState();
        return (rawAmount * active) / UI_MULTIPLIER_SCALE;
    }

    /// @notice Convert a UI (NAV-scaled) amount back into a raw token amount. Rounds down.
    /// @dev    The divisor is guaranteed non-zero by `_uiMultiplierState()`, so this cannot
    ///         panic with 0x12 (division by zero) — see the F-1 note there.
    function fromUIAmount(uint256 uiAmount) public view override returns (uint256) {
        (uint256 active, , ) = _uiMultiplierState();
        return (uiAmount * UI_MULTIPLIER_SCALE) / active;
    }

    /// @dev Single source of truth for resolving the three stored multiplier slots into
    ///      (currently effective, pending, activation time). Every ERC-8056 read and the
    ///      setter's guards go through here, so they can never disagree.
    /// @return active  multiplier effective right now — always non-zero
    /// @return pending multiplier that will be / already is effective at `effAt`
    /// @return effAt   activation timestamp, or 0 if nothing was ever scheduled
    function _uiMultiplierState() private view returns (uint256 active, uint256 pending, uint256 effAt) {
        GyldBondTokenStorage storage $ = _getStorage();
        uint256 outgoing = $.uiMultiplier;
        effAt = $.uiMultiplierEffectiveAt;

        if (effAt == 0) {
            // Nothing has ever been scheduled. Two states land here:
            //
            //   (a) F-1: a proxy deployed BEFORE this extension existed. `initialize()`
            //       ran against an older implementation, so offsets 3/4/5 of the namespaced
            //       struct were never written and read as 0. Returning that 0 verbatim is
            //       not just cosmetically wrong, it is dangerous: toUIAmount/balanceOfUI/
            //       totalSupplyUI would report 0 for every holder (everyone appears to hold
            //       nothing) and fromUIAmount would revert with a division-by-zero panic
            //       (0x12). Normalising to 1.0x here means the window between
            //       `upgradeToAndCall` and any follow-up call simply does not exist — no
            //       post-upgrade initializer is needed and the upgrade need not be atomic.
            //       1.0x is the correct value, not a guess: pre-upgrade balances were never
            //       scaled, so 1.0x reproduces the exact pre-upgrade display.
            //
            //   (b) A freshly `initialize()`d token before its first multiplier write.
            //       `outgoing` is already 1e18 there, so the branch is a no-op.
            //
            // A non-zero `outgoing` is always honoured, so a proxy that had a multiplier
            // set by an intermediate implementation keeps it across this upgrade.
            active = outgoing == 0 ? UI_MULTIPLIER_SCALE : outgoing;
            return (active, active, 0);
        }

        // Past this point a schedule exists, and every write path stores non-zero values
        // in BOTH multiplier slots, so neither branch below can yield 0.
        uint256 incoming = $.newUIMultiplier;
        if (block.timestamp >= effAt) return (incoming, incoming, effAt); // matured
        return (outgoing, incoming, effAt);                               // still pending
    }

    // ── ERC20 transfer overrides ──────────────────────────────────────────────

    function transfer(address to, uint256 amount) public override whenNotPaused returns (bool) {
        _transfer(_msgSender(), to, amount);
        return true;
    }

    /// Spender (msg.sender) is checked here because _update() only sees from/to —
    /// it has no knowledge of who holds the allowance.
    function transferFrom(address from, address to, uint256 amount) public override whenNotPaused returns (bool) {
        _requireAccess(_msgSender());
        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount);
        return true;
    }

    /// Sanctions check at the _update layer — the single funnel for ALL balance
    /// changes in OZ v5 (transfer, mint, burn). Mint (from == 0) and burn (to == 0)
    /// are intentionally skipped; IssuanceManager pre-screens APs off-chain.
    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            _requireAccess(from);
            _requireAccess(to);
        }
        super._update(from, to, value);
        // ERC-8056 TransferWithUIAmount. OPTIONAL in the EIP, implemented here because the
        // whole point of the extension is that an EIP-following indexer can reconstruct
        // displayed amounts from logs alone, without replaying uiMultiplier() at every
        // block. Emitted from _update — the single funnel for all balance changes in OZ v5 —
        // so it covers transfer, mint (from == 0) and burn (to == 0) with the same coverage
        // as the canonical ERC-20 Transfer event, matching the EIP reference implementation.
        // Cost is one extra log plus one SLOAD per balance change; accepted deliberately as
        // the price of indexer conformance. `value`, not the balance, is scaled — this event
        // is a view over the transfer, never a substitute for it.
        emit TransferWithUIAmount(from, to, value, toUIAmount(value));
    }

    // NOTE: approve/increaseAllowance/decreaseAllowance do NOT screen `spender`
    // against the Chainalysis oracle. Granting an allowance to a sanctioned address
    // succeeds — no tokens move at approval time. The sanctions check fires on the
    // subsequent transferFrom call when the sanctioned spender attempts to use the
    // allowance. This is intentional: approvals are off-chain agreements; enforcement
    // happens at the point of actual token movement.
    function approve(address spender, uint256 amount) public override whenNotPaused returns (bool) {
        return super.approve(spender, amount);
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) public override whenNotPaused {
        super.permit(owner, spender, value, deadline, v, r, s);
    }

    // ── Mint / Burn (MINTER_ROLE / BURNER_ROLE only) ──────────────────────────
    // whenNotPaused IS enforced — a paused contract stops all token movement including
    // primary issuance. This ensures a compromised SUBSCRIBER_ROLE or REDEEMER_ROLE key
    // cannot mint or burn after the ops multisig has triggered an emergency pause.
    // Sanctions oracle is NOT checked here. IssuanceManager pre-screens APs off-chain.

    /// Mint `amount` tokens to `to`.
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) whenNotPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _mint(to, amount);
    }

    /// Burn `amount` tokens from `from`.
    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) whenNotPaused {
        if (from == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        _burn(from, amount);
    }

    // ── Compliance management ─────────────────────────────────────────────────

    /// @notice Replace the sanctions oracle with a new implementation.
    /// @dev    Fail-closed by design: zero-address is explicitly rejected. Disabling the
    ///         oracle entirely is not permitted — a token with no oracle would silently skip
    ///         all sanctions checks, which is a greater compliance risk than a frozen token.
    ///
    ///         Emergency path if the current oracle is compromised: deploy a new oracle
    ///         contract (e.g. SanctionsOracleMirror) and call this function with the new
    ///         address. The oracle is replaced, not removed.
    ///
    ///         The candidate address is probed via staticcall before storing — rejects EOAs,
    ///         wrong contracts, and stubs that don't implement ISanctionsList.
    function setSanctionsList(address newSanctionsList) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newSanctionsList == address(0)) revert ZeroAddress();
        (bool ok, bytes memory data) = newSanctionsList.staticcall(
            abi.encodeWithSignature("isSanctioned(address)", address(0))
        );
        if (!ok || data.length != 32) revert NotValidSanctionsList(newSanctionsList);
        _getStorage().sanctionsList = ISanctionsList(newSanctionsList);
        emit SanctionsListUpdated(newSanctionsList);
    }

    // ── UI multiplier management (display-only) ───────────────────────────────

    /// @notice Update the display-only UI scaling multiplier, effective immediately.
    /// @dev    Purely cosmetic — does NOT affect balanceOf/totalSupply/transfer or any real
    ///         accounting or settlement logic. Intended to be driven by an off-chain process
    ///         mirroring the paired KaleidoscopeNAVFeed's published NAV so wallets can show
    ///         "current value" without a second contract read.
    ///
    ///         Subject to MAX_UI_MULTIPLIER_DEVIATION_BPS and
    ///         MIN_UI_MULTIPLIER_UPDATE_INTERVAL — see `_scheduleUiMultiplier`.
    /// @param  newMultiplier 18-dp fixed point; 1e18 == 1.0x. Must be non-zero.
    function setUiMultiplier(uint256 newMultiplier) external onlyRole(UI_MULTIPLIER_ROLE) {
        _scheduleUiMultiplier(newMultiplier, block.timestamp);
    }

    /// @notice Pre-announce a UI multiplier change that activates at a future timestamp.
    /// @dev    This is the ERC-8056 scheduling path (`newUIMultiplier()` / `effectiveAt()`),
    ///         intended for changes that must be visible to holders before they take effect
    ///         — the EIP's motivating example is a stock split. Only one schedule can be
    ///         pending; calling again while one is pending replaces it.
    /// @param  newMultiplier        18-dp fixed point; 1e18 == 1.0x. Must be non-zero.
    /// @param  effectiveAtTimestamp Activation time. Must not be in the past, and must be at
    ///                              least MIN_UI_MULTIPLIER_UPDATE_INTERVAL after the
    ///                              previously scheduled activation.
    function scheduleUiMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp)
        external
        onlyRole(UI_MULTIPLIER_ROLE)
    {
        _scheduleUiMultiplier(newMultiplier, effectiveAtTimestamp);
    }

    /// @dev Shared write path for both setters.
    ///
    ///      WHY THE GUARDS (F-3): the branch that introduced this multiplier documented it
    ///      as a MIRROR of KaleidoscopeNAVFeed's NAV, but shipped it with only a zero check.
    ///      That let a single UI_MULTIPLIER_ROLE key set 1000e18 and then 1 in the same
    ///      block, swinging every displayed balance by 1e18x. The NAV feed itself refuses
    ///      exactly that (MAX_PRICE_DEVIATION_BPS + MIN_UPDATE_INTERVAL on `updateAnswer`)
    ///      precisely because an unbounded issuer-writable value channel was judged
    ///      unacceptable, so the mirror inherits the same bounds and the same constants.
    ///
    ///      There is intentionally NO emergency bypass analogous to
    ///      KaleidoscopeNAVFeed.emergencyUpdateAnswer. That bypass exists because a wrong
    ///      NAV is a solvency problem for Morpho markets pricing collateral. A wrong
    ///      multiplier is a display problem only — real balances, quotes and settlement are
    ///      untouched — so the worst case is a few hours of slightly-off display, which does
    ///      not justify re-introducing an unbounded write channel on a second key.
    function _scheduleUiMultiplier(uint256 newMultiplier, uint256 effectiveAtTimestamp) private {
        if (newMultiplier == 0) revert ZeroMultiplier();
        if (effectiveAtTimestamp < block.timestamp) {
            revert UiMultiplierEffectiveAtInPast(effectiveAtTimestamp, block.timestamp);
        }

        (uint256 active, , uint256 effAt) = _uiMultiplierState();

        // Rate limit. Spacing is measured on the ACTIVATION timestamp rather than the call
        // time, because what must not oscillate is the value users actually see: replacing a
        // schedule that never activated has shown nobody anything. A correction can
        // therefore be submitted at any moment, but its activation is pushed to at least
        // MIN_UI_MULTIPLIER_UPDATE_INTERVAL after the previously scheduled one. `effAt == 0`
        // (nothing ever scheduled) exempts the first write, as `_updatedAt == 0` does on the
        // NAV feed.
        if (effAt != 0) {
            uint256 nextAllowedAt = effAt + MIN_UI_MULTIPLIER_UPDATE_INTERVAL;
            if (effectiveAtTimestamp < nextAllowedAt) revert UiMultiplierUpdateTooSoon(nextAllowedAt);
        }

        // Deviation cap, measured against the value that stays live right up until
        // `effectiveAtTimestamp` — i.e. the one holders are looking at now.
        // |new - active| / active > MAX_BPS / 10_000  ↔  |new - active| * 10_000 > active * MAX_BPS
        uint256 diff = newMultiplier > active ? newMultiplier - active : active - newMultiplier;
        if (diff * BPS_DENOMINATOR > active * MAX_UI_MULTIPLIER_DEVIATION_BPS) {
            revert UiMultiplierDeviationTooLarge(newMultiplier, active);
        }

        GyldBondTokenStorage storage $ = _getStorage();
        // Promote the resolved `active` into the outgoing slot. This is what makes the
        // pre-ERC-8056 zero state self-healing: the first write on an upgraded proxy
        // persists the normalised 1e18 instead of leaving a 0 behind.
        $.uiMultiplier = active;
        $.newUIMultiplier = newMultiplier;
        $.uiMultiplierEffectiveAt = effectiveAtTimestamp;
        emit UIMultiplierUpdated(active, newMultiplier, effectiveAtTimestamp);
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ── Role management overrides ─────────────────────────────────────────────

    /// DEFAULT_ADMIN_ROLE cannot be renounced — losing it permanently bricks UUPS
    /// upgrades and all role management for the lifetime of this bond instrument.
    /// Intentional removal must go through revokeRole (explicit, two-party action).
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    // ── UUPS upgrade authorization ────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    // ── ERC-165 ───────────────────────────────────────────────────────────────

    /// @dev Advertises every ERC-8056 interface this contract genuinely implements,
    ///      alongside AccessControl's / ERC-165's own. The EIP requires `true` for the core
    ///      id and for each implemented extension; an earlier revision advertised only the
    ///      core id, so discovery-driven integrators saw `false` for the conversion and
    ///      balances helpers even though both were live (C-3).
    ///      Canonical ids: 0xa60bf13d core, 0x4bd27648 pending, 0x57854fc3 conversion,
    ///      0xd890fd71 balances — pinned against these literals in the test suite.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IScaledUIAmount).interfaceId
            || interfaceId == type(IScaledUIAmountNewUIMultiplier).interfaceId
            || interfaceId == type(IScaledUIAmountConversion).interfaceId
            || interfaceId == type(IScaledUIAmountBalances).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// Fail-closed: reverts if `account` is sanctioned, or if the oracle call itself reverts.
    /// sanctionsList is always non-zero after initialize (enforced there and in setSanctionsList).
    function _requireAccess(address account) internal view {
        ISanctionsList sl = _getStorage().sanctionsList;
        if (address(sl) != address(0) && sl.isSanctioned(account)) revert AccountSanctioned(account);
    }
}
