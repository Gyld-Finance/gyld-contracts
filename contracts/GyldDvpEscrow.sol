// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

/// @dev Minimal view of the IssuanceManager used by this contract.
interface IIssuanceManager {
    function registeredTokens(address token) external view returns (bool);
}

/// @dev Read-only view of a NAVFeedForwarder (Chainlink AggregatorV3 shape, 8 decimals).
interface INavForwarder {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
    function decimals() external view returns (uint8);
}

/// @title GyldDvpEscrow
/// @notice Deferred delivery-versus-payment escrow for GyldBondToken ↔ USDC (GYL-724).
///         An AP deposits bond tokens against platform-signed EIP-712 terms; the USDC
///         leg lands later in ONE atomic transaction — either both legs execute or
///         neither does. Two settlement paths share the lock primitive:
///
///           REDEMPTION (terms.counterparty == 0): SETTLER_ROLE pays terms.usdcAmount
///             from the treasury allowance to terms.payout and forwards the tokens to
///             the IssuanceManager burn pipeline (same sink as the vault).
///           P2P FILL (terms.counterparty != 0): the designated counterparty pays
///             terms.usdcAmount from its own balance to terms.payout and receives the
///             tokens. Optionally NAV-band checked (setNavConfig) as defense-in-depth
///             against a compromised terms signer — mirrors the vault's quote band.
///
///         This is a same-chain DvP escrow with a timelock refund, NOT a cross-chain
///         HTLC — no hashlock/secret ceremony, atomicity comes free within one tx.
///
/// Design (see docs/design/ap-dvp-escrow.md, GYL-724):
///   - NON-UPGRADEABLE, a deliberate deviation from the house UUPS style: an escrow
///     position lives days, and an immutable contract means no admin key can ever
///     redirect escrowed funds. A bug is remediated by pausing new deposits, letting
///     open swaps settle/refund out, and deploying a replacement.
///   - Terms are EIP-712 signed by TERMS_SIGNER_ROLE and AP-submitted (taker-bound:
///     msg.sender of deposit() must equal terms.ap). Pricing happens off-chain at
///     signing time; `termsEpoch` mass-invalidates all un-deposited terms.
///   - Single-use termsId: the position record itself is the used-marker — deposit
///     requires status == NONE, and every terminal state is permanent.
///   - Funds can only ever move to (a) the settlement destinations fixed in the
///     signed terms, or (b) back to the recorded depositor. No function takes a
///     caller-supplied destination. guardianRefund can only ACCELERATE the refund
///     the expiry already guarantees — never redirect, never block.
///
/// Compliance:
///   - No sanctions calls here by design — the bond-token legs are screened
///     fail-closed by GyldBondToken._update (from, to, and this contract as
///     spender). If the AP is sanctioned mid-lock, refund reverts and the tokens
///     freeze in escrow: the correct outcome, consistent with the no-internal-
///     blacklist decision. The USDC leg has no on-chain screen — the platform
///     re-screens payout off-chain before every settle (load-bearing).
///
/// Roles:
///   DEFAULT_ADMIN_ROLE — unpause, setNavConfig, bumpTermsEpoch, role grants;
///                        should be a TimelockController in production
///   TERMS_SIGNER_ROLE  — terms-service KMS/Fordefi key(s); passive — checked via
///                        hasRole against the recovered EIP-712 signer
///   SETTLER_ROLE       — platform ops key; spends the treasury USDC allowance in
///                        settle(), so it must not be public
///   GUARDIAN_ROLE      — ops multisig; guardianRefund() only (early refund-to-maker
///                        when signed terms mismatch the off-chain agreement)
///   PAUSER_ROLE        — ops multisig; pause() ONLY, and pause gates deposit() only —
///                        settle/fill/refund are never pausable (a pause must not be
///                        able to strand AP funds past their refund right)
contract GyldDvpEscrow is AccessControl, Pausable, ReentrancyGuard, EIP712 {
    using SafeERC20 for IERC20;

    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 public constant TERMS_SIGNER_ROLE = keccak256("TERMS_SIGNER_ROLE");
    bytes32 public constant SETTLER_ROLE      = keccak256("SETTLER_ROLE");
    bytes32 public constant GUARDIAN_ROLE     = keccak256("GUARDIAN_ROLE");
    bytes32 public constant PAUSER_ROLE       = keccak256("PAUSER_ROLE");

    // ── EIP-712 ───────────────────────────────────────────────────────────────

    /// @notice Platform-signed escrow terms, AP-submitted via deposit(). Field order
    ///         and types are load-bearing once the typehash is frozen — mirror into
    ///         the shared Rust module exactly (golden-digest parity test, as with
    ///         GyldAtomicSwap's SwapMessage).
    struct DvpTerms {
        uint256 termsId;       // single-use; the position record is the used-marker
        address ap;            // taker binding: msg.sender of deposit() MUST equal this
        address counterparty;  // 0 = redemption (settler pays); else the ONLY address that may fill
        address token;         // GyldBondToken series (must be registered with the IssuanceManager)
        uint256 tokenAmount;   // locked on deposit (series decimals, 18)
        uint256 usdcAmount;    // fixed payout, 6 decimals — priced off-chain at signing time
        address payout;        // USDC destination (screened off-chain; allows AP treasury ≠ trading wallet)
        uint64  depositExpiry; // deposit() reverts after this (quote TTL)
        uint64  refundAfter;   // refund() allowed from this timestamp (default T+3 off-chain)
        uint64  epoch;         // terms-signer generation; must equal termsEpoch at deposit
    }

    /// @notice Optional EIP-2612 permit for the incoming leg; value == 0 skips.
    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8   v;
        bytes32 r;
        bytes32 s;
    }

    bytes32 public constant DVP_TERMS_TYPEHASH = keccak256(
        "DvpTerms(uint256 termsId,address ap,address counterparty,address token,uint256 tokenAmount,uint256 usdcAmount,address payout,uint64 depositExpiry,uint64 refundAfter,uint64 epoch)"
    );

    // ── Positions ─────────────────────────────────────────────────────────────

    enum Status {
        NONE,      // termsId never deposited
        DEPOSITED, // tokens locked, awaiting settle/fill or refund
        SETTLED,   // terminal: USDC delivered, tokens released
        REFUNDED   // terminal: tokens returned to the recorded depositor
    }

    /// @dev Everything settle/fill/refund needs is re-read from storage, never from
    ///      caller input. `ap`, `refundAfter`, `status` pack into one slot.
    struct Position {
        address ap;
        uint64  refundAfter;
        Status  status;
        address counterparty;
        address token;
        address payout;
        uint256 tokenAmount;
        uint256 usdcAmount;
    }

    /// @dev Optional per-series NAV sanity band applied to P2P fills.
    ///      forwarder == 0 disables the check for that series.
    struct NavConfig {
        address forwarder;       // NAVFeedForwarder (stable address), 8 decimals
        uint16  maxDeviationBps; // e.g. 200 = 2%
        uint32  maxAgeSecs;      // explicit staleness gate — feed reads never revert on their own
    }

    uint256 private constant _MAX_BPS = 10_000;

    /// @notice Floor between deposit and the refund right unlocking — settle/fill must
    ///         get a real window before the AP can reclaim.
    uint64 public constant MIN_SETTLEMENT_WINDOW = 1 hours;

    // ── Immutables ────────────────────────────────────────────────────────────

    /// @notice USDC token (6 decimals) — the payment leg of every swap.
    IERC20 public immutable USDC;

    /// @notice IssuanceManager: registry gate at deposit + burn-commitment sink on settle().
    IIssuanceManager public immutable ISSUANCE_MANAGER;

    /// @notice Address whose USDC allowance settle() spends (platform treasury).
    address public immutable TREASURY;

    // ── Storage ───────────────────────────────────────────────────────────────

    mapping(uint256 termsId => Position) private _positions;
    mapping(address token => NavConfig) private _navConfigOf;
    uint64 private _termsEpoch;

    // ── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error NotAp(address ap, address caller);
    error NotCounterparty(address counterparty, address caller);
    error NotRedemptionTerms(uint256 termsId);
    error NotP2PTerms(uint256 termsId);
    error TermsExpired(uint64 depositExpiry);
    error TermsEpochStale(uint64 termsEpoch, uint64 currentEpoch);
    error InvalidTermsSigner(address recovered);
    error InvalidState(uint256 termsId, Status status);
    error RefundLocked(uint64 refundAfter);
    error SettlementWindowTooShort(uint64 refundAfter);
    error UnregisteredToken(address token);
    error NotValidNavForwarder(address forwarder);
    error InvalidNavConfig();
    error InvalidNav(address token, int256 nav);
    error StaleNav(address token, uint256 updatedAt);
    error NavPriceOutOfBand(uint256 usdcAmount, uint256 navValue);
    error CannotRenounceAdminRole();

    // ── Events ────────────────────────────────────────────────────────────────

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

    // ── Constructor ───────────────────────────────────────────────────────────

    /// @param defaultAdmin    Should be a TimelockController in production.
    /// @param pauser          Ops multisig — may pause() (deposit only) but not unpause().
    /// @param termsSigner     Terms-service KMS/Fordefi key; recovered EIP-712 signers
    ///                        must hold TERMS_SIGNER_ROLE. May be the same key as the
    ///                        vault's QUOTE_SIGNER_ROLE; the role stays distinct.
    /// @param settler         Platform ops key allowed to settle() redemption swaps.
    /// @param guardian        Ops multisig allowed to guardianRefund() (early refund-to-maker).
    /// @param usdc            USDC token address (6 decimals).
    /// @param issuanceManager IssuanceManager proxy (registry + burn sink).
    /// @param treasury        Address whose USDC allowance settle() spends.
    constructor(
        address defaultAdmin,
        address pauser,
        address termsSigner,
        address settler,
        address guardian,
        address usdc,
        address issuanceManager,
        address treasury
    ) EIP712("GyldDvpEscrow", "1") {
        if (
            defaultAdmin == address(0) || pauser == address(0) || termsSigner == address(0)
                || settler == address(0) || guardian == address(0) || usdc == address(0)
                || issuanceManager == address(0) || treasury == address(0)
        ) revert ZeroAddress();

        USDC             = IERC20(usdc);
        ISSUANCE_MANAGER = IIssuanceManager(issuanceManager);
        TREASURY         = treasury;

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE,        pauser);
        _grantRole(TERMS_SIGNER_ROLE,  termsSigner);
        _grantRole(SETTLER_ROLE,       settler);
        _grantRole(GUARDIAN_ROLE,      guardian);
    }

    // ── Public getters ────────────────────────────────────────────────────────

    /// @notice Current terms-signer generation; terms signed for an older epoch revert.
    function termsEpoch() external view returns (uint64) { return _termsEpoch; }

    /// @notice Full position record for `termsId` (status == NONE if never deposited).
    function positionOf(uint256 termsId) external view returns (Position memory) {
        return _positions[termsId];
    }

    /// @notice NAV band config applied to P2P fills of `token`; forwarder == 0 means disabled.
    function navConfigOf(address token) external view returns (NavConfig memory) {
        return _navConfigOf[token];
    }

    /// @notice EIP-712 digest for DvpTerms (off-chain signer parity check).
    /// @param  t Terms to hash.
    /// @return The fully-domain-separated digest the terms service must sign.
    function hashDvpTerms(DvpTerms calldata t) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    DVP_TERMS_TYPEHASH,
                    t.termsId, t.ap, t.counterparty, t.token, t.tokenAmount,
                    t.usdcAmount, t.payout, t.depositExpiry, t.refundAfter, t.epoch
                )
            )
        );
    }

    // ── Deposit (T+0) ─────────────────────────────────────────────────────────

    /// @notice Lock the AP's bond tokens against platform-signed terms. One AP
    ///         transaction; the platform never relays.
    /// @dev    Check order: termsId unused → taker binding → amounts → deposit TTL →
    ///         settlement window → epoch → EIP-712 signature against
    ///         TERMS_SIGNER_ROLE → registered series. Effects before the pull.
    ///         The optional permit is applied with try/catch so a front-run permit()
    ///         cannot brick the deposit — safeTransferFrom enforces the allowance
    ///         regardless.
    /// @param terms       The terms exactly as signed by the terms service.
    /// @param platformSig 65-byte ECDSA signature over hashDvpTerms(terms).
    /// @param permitIn    Optional EIP-2612 permit for terms.token; value == 0 skips.
    function deposit(DvpTerms calldata terms, bytes calldata platformSig, PermitData calldata permitIn)
        external
        nonReentrant
        whenNotPaused
    {
        Position storage p = _positions[terms.termsId];

        if (p.status != Status.NONE)                     revert InvalidState(terms.termsId, p.status);
        if (terms.ap != msg.sender)                      revert NotAp(terms.ap, msg.sender);
        if (terms.tokenAmount == 0 || terms.usdcAmount == 0) revert ZeroAmount();
        if (terms.payout == address(0))                  revert ZeroAddress();
        if (block.timestamp > terms.depositExpiry)       revert TermsExpired(terms.depositExpiry);
        if (terms.refundAfter < block.timestamp + MIN_SETTLEMENT_WINDOW) {
            revert SettlementWindowTooShort(terms.refundAfter);
        }
        if (terms.epoch != _termsEpoch)                  revert TermsEpochStale(terms.epoch, _termsEpoch);

        address signer = ECDSA.recover(hashDvpTerms(terms), platformSig);
        if (!hasRole(TERMS_SIGNER_ROLE, signer))         revert InvalidTermsSigner(signer);

        if (!ISSUANCE_MANAGER.registeredTokens(terms.token)) revert UnregisteredToken(terms.token);

        p.ap           = terms.ap;
        p.refundAfter  = terms.refundAfter;
        p.status       = Status.DEPOSITED;
        p.counterparty = terms.counterparty;
        p.token        = terms.token;
        p.payout       = terms.payout;
        p.tokenAmount  = terms.tokenAmount;
        p.usdcAmount   = terms.usdcAmount;

        if (permitIn.value != 0) {
            try IERC20Permit(terms.token).permit(
                msg.sender, address(this), permitIn.value, permitIn.deadline, permitIn.v, permitIn.r, permitIn.s
            ) {} catch {} // solhint-disable-line no-empty-blocks
        }

        // GyldBondToken._update screens msg.sender as from, this escrow as to AND
        // as spender (fail-closed via the Chainalysis oracle).
        IERC20(terms.token).safeTransferFrom(msg.sender, address(this), terms.tokenAmount);

        emit Deposited(
            terms.termsId, terms.ap, terms.counterparty, terms.token,
            terms.tokenAmount, terms.usdcAmount, terms.refundAfter
        );
    }

    // ── Settlement — redemption path (T+1) ────────────────────────────────────

    /// @notice Atomically settle a REDEMPTION swap: USDC treasury → payout, tokens
    ///         escrow → IssuanceManager (the tokens-at-IssuanceManager burn-commitment
    ///         signal; a dedicated EscrowWatcher attributes it, not BurnWatcher).
    /// @dev    Valid even past refundAfter as long as the AP has not refunded — late
    ///         settlement beats stranding; the state machine decides races. The
    ///         platform re-screens payout off-chain before calling (invariant 4).
    /// @param termsId Terms identifier from the signed DvpTerms.
    function settle(uint256 termsId) external nonReentrant onlyRole(SETTLER_ROLE) {
        Position storage p = _positions[termsId];

        if (p.status != Status.DEPOSITED)  revert InvalidState(termsId, p.status);
        if (p.counterparty != address(0))  revert NotRedemptionTerms(termsId);

        p.status = Status.SETTLED;

        USDC.safeTransferFrom(TREASURY, p.payout, p.usdcAmount);
        IERC20(p.token).safeTransfer(address(ISSUANCE_MANAGER), p.tokenAmount);

        emit Settled(termsId, p.payout, p.usdcAmount);
    }

    // ── Settlement — P2P path ─────────────────────────────────────────────────

    /// @notice Atomically fill a P2P swap: the designated counterparty pays
    ///         terms.usdcAmount to the AP's payout address and receives the locked
    ///         tokens. Both transfers succeed or the whole tx reverts — a
    ///         short-changed fill is impossible, not merely detectable.
    /// @dev    If a NAV band is configured for the series (setNavConfig), the signed
    ///         price is validated against the live feed with an explicit staleness
    ///         gate — defense-in-depth against a compromised terms signer, mirroring
    ///         GyldSettlementVault's quote band. Real USDC permit is non-standard
    ///         (version "2"), hence optional + try/catch.
    /// @param termsId  Terms identifier from the signed DvpTerms.
    /// @param permitIn Optional EIP-2612 permit for USDC; value == 0 skips.
    function fill(uint256 termsId, PermitData calldata permitIn) external nonReentrant {
        Position storage p = _positions[termsId];

        if (p.status != Status.DEPOSITED)   revert InvalidState(termsId, p.status);
        if (p.counterparty == address(0))   revert NotP2PTerms(termsId);
        if (p.counterparty != msg.sender)   revert NotCounterparty(p.counterparty, msg.sender);

        _checkNavBand(p.token, p.tokenAmount, p.usdcAmount);

        p.status = Status.SETTLED;

        if (permitIn.value != 0) {
            try IERC20Permit(address(USDC)).permit(
                msg.sender, address(this), permitIn.value, permitIn.deadline, permitIn.v, permitIn.r, permitIn.s
            ) {} catch {} // solhint-disable-line no-empty-blocks
        }

        USDC.safeTransferFrom(msg.sender, p.payout, p.usdcAmount);
        IERC20(p.token).safeTransfer(msg.sender, p.tokenAmount);

        emit Filled(termsId, msg.sender, p.usdcAmount);
    }

    // ── Refund ────────────────────────────────────────────────────────────────

    /// @notice Return the locked tokens to the recorded depositor once the refund
    ///         right has unlocked. Callable by ANYONE — the destination is fixed at
    ///         deposit time and not parameterizable (removes an exfiltration vector).
    /// @param termsId Terms identifier from the signed DvpTerms.
    function refund(uint256 termsId) external nonReentrant {
        Position storage p = _positions[termsId];

        if (p.status != Status.DEPOSITED)      revert InvalidState(termsId, p.status);
        if (block.timestamp < p.refundAfter)   revert RefundLocked(p.refundAfter);

        _refund(termsId, p);
    }

    /// @notice Early refund-to-maker: the guardian's ONLY power, for when signed terms
    ///         are discovered to mismatch the off-chain agreement (mis-priced or
    ///         manipulated quote). Strictly a subset of what refund() already
    ///         guarantees at expiry — same fixed destination, just earlier. The
    ///         guardian can never redirect escrowed funds, and can never BLOCK
    ///         refund(), which stays permissionless and unpausable.
    /// @param termsId    Terms identifier from the signed DvpTerms.
    /// @param reasonCode Ops incident/audit reference, emitted on-chain.
    function guardianRefund(uint256 termsId, bytes32 reasonCode) external nonReentrant onlyRole(GUARDIAN_ROLE) {
        Position storage p = _positions[termsId];

        if (p.status != Status.DEPOSITED) revert InvalidState(termsId, p.status);

        emit GuardianRefunded(termsId, p.ap, msg.sender, reasonCode);
        _refund(termsId, p);
    }

    /// @dev Shared refund tail: mark terminal, push tokens to the recorded ap. If the
    ///      ap was sanctioned mid-lock the token transfer reverts fail-closed and the
    ///      tokens stay frozen in escrow — the correct compliance outcome.
    function _refund(uint256 termsId, Position storage p) private {
        p.status = Status.REFUNDED;
        IERC20(p.token).safeTransfer(p.ap, p.tokenAmount);
        emit Refunded(termsId, p.ap, p.tokenAmount);
    }

    // ── NAV band (P2P fills) ──────────────────────────────────────────────────

    /// @dev No-op when no forwarder is configured for the series. Decimal convention
    ///      (house-wide): tokenAmount 18dp × nav 8dp / 1e20 = USDC 6dp. Non-positive
    ///      NAV reverts fail-closed; staleness is OUR check — forwarder reads never
    ///      revert on stale data by design (weekend tolerance).
    function _checkNavBand(address token, uint256 tokenAmount, uint256 usdcAmount) private view {
        NavConfig storage cfg = _navConfigOf[token];
        address forwarder = cfg.forwarder;
        if (forwarder == address(0)) return;

        (, int256 nav,, uint256 updatedAt,) = INavForwarder(forwarder).latestRoundData();
        if (nav <= 0)                                      revert InvalidNav(token, nav);
        if (block.timestamp > updatedAt + cfg.maxAgeSecs)  revert StaleNav(token, updatedAt);

        uint256 navValue = (tokenAmount * uint256(nav)) / 1e20;
        uint256 band = (navValue * cfg.maxDeviationBps) / _MAX_BPS;
        if (usdcAmount > navValue + band || usdcAmount + band < navValue) {
            revert NavPriceOutOfBand(usdcAmount, navValue);
        }
    }

    /// @notice Configure (or clear, with forwarder == 0) the NAV sanity band applied
    ///         to P2P fills of `token`. Redemption settles are deliberately not
    ///         banded — the settler pays from the platform's own treasury, so there
    ///         is no self-dealing vector (GYL-724's no-oracle stance holds there).
    /// @dev    Probe-before-store (house idiom): the forwarder must report 8 decimals.
    /// @param token           GyldBondToken proxy address (18 decimals).
    /// @param forwarder       NAVFeedForwarder stable address, or 0 to disable.
    /// @param maxDeviationBps Allowed |signed price − NAV| band, e.g. 200 = 2%.
    /// @param maxAgeSecs      Max acceptable feed age at fill time.
    function setNavConfig(address token, address forwarder, uint16 maxDeviationBps, uint32 maxAgeSecs)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();

        if (forwarder == address(0)) {
            delete _navConfigOf[token];
            emit NavConfigSet(token, address(0), 0, 0);
            return;
        }

        if (maxDeviationBps == 0 || maxDeviationBps > _MAX_BPS || maxAgeSecs == 0) revert InvalidNavConfig();

        (bool ok, bytes memory data) = forwarder.staticcall(abi.encodeWithSignature("decimals()"));
        if (!ok || data.length != 32 || abi.decode(data, (uint8)) != 8) revert NotValidNavForwarder(forwarder);

        _navConfigOf[token] = NavConfig({forwarder: forwarder, maxDeviationBps: maxDeviationBps, maxAgeSecs: maxAgeSecs});
        emit NavConfigSet(token, forwarder, maxDeviationBps, maxAgeSecs);
    }

    // ── Terms invalidation ────────────────────────────────────────────────────

    /// @notice Kill every outstanding (signed but not yet deposited) terms sheet in
    ///         one transaction — signer-key rotation or incident response. Already-
    ///         deposited positions are NOT affected: their lifecycle is guaranteed by
    ///         the state machine (settle/fill/refund), never by the epoch.
    function bumpTermsEpoch() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint64 next = ++_termsEpoch;
        emit TermsEpochBumped(next);
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    /// @notice Halt NEW deposits. Asymmetric by design: PAUSER (ops multisig) halts
    ///         cheaply, only DEFAULT_ADMIN_ROLE (timelock) resumes. settle/fill/refund
    ///         are never pausable — a pause must not strand AP funds past their
    ///         refund right.
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }

    /// @notice Resume deposits. Deliberately admin-gated (see pause()).
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    // ── Role management overrides ─────────────────────────────────────────────

    /// DEFAULT_ADMIN_ROLE cannot be renounced — losing it permanently bricks unpause,
    /// NAV config, epoch bumps, and all role management including signer rotation.
    /// Intentional removal must go through revokeRole (explicit, two-party action).
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }
}
