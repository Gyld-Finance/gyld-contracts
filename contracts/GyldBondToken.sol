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

/// @dev Minimal ERC-8056 (Scaled UI Amount) interface marker for ERC-165 discovery.
interface IERC8056 {
    function uiMultiplier() external view returns (uint256);
}

/// @title GyldBondToken
/// @notice Standard ERC-20 per bond series. One token = one unit of bond ownership.
///
///         Token balances are fixed — they only change via mint (subscription) and
///         burn (redemption). Value accrual (coupons, NAV appreciation) is reflected
///         exclusively in the paired KaleidoscopeNAVFeed oracle, not in balances.
///
///         A display-only ERC-8056 (Scaled UI Amount) extension lets integrators show a
///         NAV-scaled balance (`balanceOfUI`) without affecting real balances.
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
contract GyldBondToken is
    Initializable,
    ERC20Upgradeable,
    ERC20PermitUpgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UI_MULTIPLIER_ROLE = keccak256("UI_MULTIPLIER_ROLE");

    // ── Constants ─────────────────────────────────────────────────────────────

    /// @notice Fixed-point scale for the display-only UI multiplier. 1e18 == 1.0x (no scaling).
    uint256 public constant UI_MULTIPLIER_SCALE = 1e18;

    // ── ERC-7201 namespaced storage ───────────────────────────────────────────

    /// @custom:storage-location erc7201:gyld.GyldBondToken
    struct GyldBondTokenStorage {
        ISanctionsList sanctionsList;
        string isin;
        uint256 maturityTimestamp;
        // Display-only ERC-8056 scaling multiplier (18-dp fixed point; 1e18 == 1.0x).
        // Appended at the end so existing field offsets are undisturbed.
        uint256 uiMultiplier;
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

    // ── Events ────────────────────────────────────────────────────────────────

    event SanctionsListUpdated(address indexed newSanctionsList);
    event UIMultiplierUpdated(uint256 previousMultiplier, uint256 newMultiplier);

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
        $.uiMultiplier = UI_MULTIPLIER_SCALE;
        emit UIMultiplierUpdated(0, UI_MULTIPLIER_SCALE);
    }

    /// @notice One-time post-upgrade initializer for proxies deployed before the ERC-8056
    ///         extension existed. Sets uiMultiplier to 1.0x (no value change vs pre-upgrade
    ///         state, since balanceOf/totalSupply were never scaled to begin with).
    ///         Brand-new deployments get this from initialize() directly and never call this.
    function initializeUiMultiplierV2() external reinitializer(2) {
        GyldBondTokenStorage storage $ = _getStorage();
        $.uiMultiplier = UI_MULTIPLIER_SCALE;
        emit UIMultiplierUpdated(0, UI_MULTIPLIER_SCALE);
    }

    // ── Getters ───────────────────────────────────────────────────────────────

    function isin() external view returns (string memory) { return _getStorage().isin; }
    function maturityTimestamp() external view returns (uint256) { return _getStorage().maturityTimestamp; }
    function sanctionsList() external view returns (ISanctionsList) { return _getStorage().sanctionsList; }

    // ── ERC-8056 Scaled UI Amount (display-only) ──────────────────────────────
    // Purely cosmetic view layer. Does NOT touch balanceOf/totalSupply/transfer or any
    // real accounting — the raw ERC-20 balances remain the single source of truth.

    /// @notice Current display-only UI scaling multiplier (18-dp fixed point; 1e18 == 1.0x).
    function uiMultiplier() external view returns (uint256) {
        return _getStorage().uiMultiplier;
    }

    /// @notice `account`'s balance scaled by the UI multiplier — for display only.
    function balanceOfUI(address account) external view returns (uint256) {
        return toUIAmount(balanceOf(account));
    }

    /// @notice Total supply scaled by the UI multiplier — for display only.
    function totalSupplyUI() external view returns (uint256) {
        return toUIAmount(totalSupply());
    }

    /// @notice Scale a raw token amount into its UI (NAV-scaled) representation.
    function toUIAmount(uint256 amount) public view returns (uint256) {
        return (amount * _getStorage().uiMultiplier) / UI_MULTIPLIER_SCALE;
    }

    /// @notice Convert a UI (NAV-scaled) amount back into a raw token amount.
    function fromUIAmount(uint256 uiAmount) public view returns (uint256) {
        return (uiAmount * UI_MULTIPLIER_SCALE) / _getStorage().uiMultiplier;
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

    /// @notice Update the display-only UI scaling multiplier. Purely cosmetic — does NOT
    ///         affect balanceOf/totalSupply/transfer or any real accounting or settlement
    ///         logic. Intended to be driven by an off-chain process mirroring the paired
    ///         KaleidoscopeNAVFeed's published NAV so wallets can show "current value"
    ///         without a second contract read.
    function setUiMultiplier(uint256 newMultiplier) external onlyRole(UI_MULTIPLIER_ROLE) {
        if (newMultiplier == 0) revert ZeroMultiplier();
        GyldBondTokenStorage storage $ = _getStorage();
        uint256 previous = $.uiMultiplier;
        $.uiMultiplier = newMultiplier;
        emit UIMultiplierUpdated(previous, newMultiplier);
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

    /// @dev Advertises ERC-8056 (Scaled UI Amount) support alongside AccessControl's own.
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC8056).interfaceId || super.supportsInterface(interfaceId);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// Fail-closed: reverts if `account` is sanctioned, or if the oracle call itself reverts.
    /// sanctionsList is always non-zero after initialize (enforced there and in setSanctionsList).
    function _requireAccess(address account) internal view {
        ISanctionsList sl = _getStorage().sanctionsList;
        if (address(sl) != address(0) && sl.isSanctioned(account)) revert AccountSanctioned(account);
    }
}
