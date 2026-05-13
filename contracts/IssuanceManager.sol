// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
interface IGyldBondToken {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @title IssuanceManager
/// @notice Single gate for primary issuance and redemption of all Gyld bond series.
///
/// Design:
///   - Only whitelisted Authorised Participant (AP) addresses may be minted to or redeemed from.
///   - This contract holds MINTER_ROLE and BURNER_ROLE on every registered GyldBondToken.
///   - The platform backend (SUBSCRIBER_ROLE/REDEEMER_ROLE) calls subscribe/redeem after confirming USDC receipt
///     or token receipt off-chain. The smart contract enforces whitelist compliance on-chain.
///
/// Mint flow:
///   1. Backend confirms USDC received from whitelisted AP source.
///   2. Backend calls subscribe(token, recipient, amount).
///   3. IssuanceManager checks recipient is whitelisted, then calls token.mint(recipient, amount).
///
/// Redemption flow:
///   1. Customer (whitelisted AP) transfers bond tokens to this contract's address.
///   2. Backend confirms receipt and customer identity.
///   3. Backend calls redeem(token, beneficiary, amount).
///   4. IssuanceManager checks beneficiary is whitelisted, burns from its own balance.
///   5. Backend sends USDC to customer off-chain (or via platform wallet).
///
/// Roles:
///   DEFAULT_ADMIN_ROLE   — grants / revokes all roles; should be a TimelockController
///   WHITELIST_ADMIN_ROLE — adds / removes APs from the whitelist
///   SUBSCRIBER_ROLE      — calls subscribe() (mint path); separate MPC wallet from redeemer
///   REDEEMER_ROLE        — calls redeem()    (burn path); separate MPC wallet from subscriber
///   DEFAULT_ADMIN_ROLE   — also authorizes UUPS upgrades (should be a TimelockController)
contract IssuanceManager is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    // ── Roles ─────────────────────────────────────────────────────────────────

    bytes32 public constant WHITELIST_ADMIN_ROLE = keccak256("WHITELIST_ADMIN_ROLE");
    bytes32 public constant SUBSCRIBER_ROLE      = keccak256("SUBSCRIBER_ROLE");
    bytes32 public constant REDEEMER_ROLE        = keccak256("REDEEMER_ROLE");
    bytes32 public constant REGISTRAR_ROLE       = keccak256("REGISTRAR_ROLE");

    // ── ERC-7201 namespaced storage ───────────────────────────────────────────

    /// @custom:storage-location erc7201:gyld.IssuanceManager
    struct IssuanceManagerStorage {
        mapping(address => bool) whitelisted;
        mapping(address => bool) registeredTokens;
    }

    // keccak256(abi.encode(uint256(keccak256("gyld.IssuanceManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_LOCATION =
        0xc8552dd465c7174389604c2ad1f48bf21d46f65ee8d42bbd0456923afc111000;

    function _getStorage() private pure returns (IssuanceManagerStorage storage $) {
        assembly {
            $.slot := _STORAGE_LOCATION
        }
    }

    // ── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error ZeroAmount();
    error UnregisteredToken(address token);
    error NotWhitelisted(address account);
    error NotValidTokenContract(address token);
    error CannotRenounceAdminRole();

    // ── Events ────────────────────────────────────────────────────────────────

    event Subscribed(address indexed token, address indexed recipient, uint256 amount);
    event Redeemed(address indexed token, address indexed beneficiary, uint256 amount);
    event AddressWhitelisted(address indexed account);
    event AddressRemovedFromWhitelist(address indexed account);
    event TokenRegistered(address indexed token);
    event TokenDeregistered(address indexed token);

    // ── Constructor / Initializer ─────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param defaultAdmin  Should be a TimelockController in production.
    /// @param subscriber    MPC wallet authorised to call subscribe() (mint path only).
    /// @param redeemer      MPC wallet authorised to call redeem()    (burn path only).
    function initialize(address defaultAdmin, address subscriber, address redeemer) external initializer {
        if (defaultAdmin == address(0) || subscriber == address(0) || redeemer == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();
        _grantRole(DEFAULT_ADMIN_ROLE,  defaultAdmin);
        _grantRole(SUBSCRIBER_ROLE,     subscriber);
        _grantRole(REDEEMER_ROLE,       redeemer);
    }

    // ── Public getters ────────────────────────────────────────────────────────

    /// @notice Returns whether `account` is on the Authorised Participant whitelist.
    /// @param  account Address to query.
    /// @return True if `account` may be a mint recipient or redemption beneficiary.
    function whitelisted(address account) external view returns (bool) {
        return _getStorage().whitelisted[account];
    }

    /// @notice Returns whether `token` has been registered with this manager.
    /// @param  token GyldBondToken proxy address to query.
    /// @return True if `subscribe` and `redeem` may be called for this token.
    function registeredTokens(address token) external view returns (bool) {
        return _getStorage().registeredTokens[token];
    }

    // ── Primary issuance ──────────────────────────────────────────────────────

    /// @notice Mint `amount` bond tokens to `recipient` after off-chain USDC settlement.
    /// @dev    Caller must hold SUBSCRIBER_ROLE. The Chainalysis oracle is NOT checked here —
    ///         IssuanceManager pre-screens APs off-chain before calling. Only registered
    ///         tokens and whitelisted recipients are accepted.
    /// @param token     A registered GyldBondToken proxy address.
    /// @param recipient Whitelisted AP wallet that receives the bond tokens.
    /// @param amount    Token amount in 18-decimal units. Must be greater than zero.
    function subscribe(address token, address recipient, uint256 amount)
        external
        nonReentrant
        onlyRole(SUBSCRIBER_ROLE)
    {
        if (!_getStorage().registeredTokens[token]) revert UnregisteredToken(token);
        if (!_getStorage().whitelisted[recipient])   revert NotWhitelisted(recipient);
        if (amount == 0)                             revert ZeroAmount();
        // nonReentrant: defense-in-depth; mint/burn are role-gated with no untrusted callbacks
        IGyldBondToken(token).mint(recipient, amount);
        emit Subscribed(token, recipient, amount);
    }

    // ── Redemption ────────────────────────────────────────────────────────────

    /// @notice Burn `amount` tokens from this contract's balance to settle a redemption.
    ///
    /// @dev    Custody window — intentional two-step design:
    ///
    ///         Step 1 (AP): The AP transfers bond tokens to this contract's address.
    ///                      That ERC-20 Transfer event is the on-chain commitment signal.
    ///
    ///         Step 2 (backend): The off-chain event listener detects the Transfer,
    ///                      confirms the AP's identity and whitelist status, then calls
    ///                      this function to burn the tokens and records the obligation
    ///                      to send USDC off-chain.
    ///
    ///         Tokens held by this contract during the window are inert — the contract
    ///         has no withdraw(), transfer(), or rescue() function, so they cannot be
    ///         extracted without REDEEMER_ROLE calling redeem().  A rogue REDEEMER_ROLE
    ///         key could burn tokens for a wrong beneficiary address, but cannot redirect
    ///         the off-chain USDC payment — that settlement is handled by a separate
    ///         backend service keyed to the beneficiary recorded in the Redeemed event.
    ///         The beneficiary must also be whitelisted, limiting the blast radius of a
    ///         compromised key to addresses already KYC-approved.
    ///
    ///         Atomicity is not required because value does not move on-chain at redemption
    ///         time — USDC is sent off-chain after this call succeeds.
    ///
    /// @param token       A registered GyldBondToken proxy address.
    /// @param beneficiary Whitelisted AP who sent the tokens (recorded in event for audit trail).
    /// @param amount      Token amount to burn. Must not exceed this contract's token balance.
    function redeem(address token, address beneficiary, uint256 amount)
        external
        nonReentrant
        onlyRole(REDEEMER_ROLE)
    {
        if (!_getStorage().registeredTokens[token])    revert UnregisteredToken(token);
        if (!_getStorage().whitelisted[beneficiary])   revert NotWhitelisted(beneficiary);
        if (amount == 0)                               revert ZeroAmount();
        // nonReentrant: defense-in-depth; mint/burn are role-gated with no untrusted callbacks
        IGyldBondToken(token).burn(address(this), amount);
        emit Redeemed(token, beneficiary, amount);
    }

    // ── Whitelist management ──────────────────────────────────────────────────

    /// @notice Add a single address to the AP whitelist.
    /// @dev    Caller must hold WHITELIST_ADMIN_ROLE. Idempotent — adding an
    ///         already-whitelisted address emits the event again but has no other effect.
    /// @param account Address to whitelist. Must not be address(0).
    function addToWhitelist(address account) external onlyRole(WHITELIST_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _getStorage().whitelisted[account] = true;
        emit AddressWhitelisted(account);
    }

    /// @notice Remove a single address from the AP whitelist.
    /// @dev    Caller must hold WHITELIST_ADMIN_ROLE. Idempotent — removing an
    ///         address that was not whitelisted has no effect.
    /// @param account Address to remove.
    function removeFromWhitelist(address account) external onlyRole(WHITELIST_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _getStorage().whitelisted[account] = false;
        emit AddressRemovedFromWhitelist(account);
    }

    /// @notice Add multiple addresses to the AP whitelist in one transaction.
    /// @dev    Caller must hold WHITELIST_ADMIN_ROLE. Reverts if any address in
    ///         the batch is address(0) — the entire batch is rolled back.
    /// @param accounts Array of addresses to whitelist.
    function addToWhitelistBatch(address[] calldata accounts) external onlyRole(WHITELIST_ADMIN_ROLE) {
        for (uint256 i = 0; i < accounts.length;) {
            if (accounts[i] == address(0)) revert ZeroAddress();
            _getStorage().whitelisted[accounts[i]] = true;
            emit AddressWhitelisted(accounts[i]);
            unchecked { i++; }
        }
    }

    // ── Token registry ────────────────────────────────────────────────────────

    /// @notice Register a GyldBondToken so it may be used in subscribe/redeem.
    /// @dev    Caller must hold REGISTRAR_ROLE. In production this is the
    ///         TokenFactory, which calls registerToken atomically during deployToken.
    /// @param token GyldBondToken proxy address to register.
    function registerToken(address token) external onlyRole(REGISTRAR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        // Verify the address implements GyldBondToken — reverts at registration
        // time rather than silently failing downstream in subscribe/redeem.
        // staticcall handles both EOAs (success=true, data="") and wrong contracts
        // (success=false): we require success AND a full 32-byte return value.
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("MINTER_ROLE()"));
        if (!ok || data.length != 32) revert NotValidTokenContract(token);
        _getStorage().registeredTokens[token] = true;
        emit TokenRegistered(token);
    }

    /// @notice Deregister a token, preventing further subscribe/redeem calls for it.
    /// @dev    Caller must hold REGISTRAR_ROLE. Used when a bond series has matured
    ///         and primary issuance is permanently closed.
    /// @param token GyldBondToken proxy address to deregister.
    function deregisterToken(address token) external onlyRole(REGISTRAR_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        _getStorage().registeredTokens[token] = false;
        emit TokenDeregistered(token);
    }

    // ── Role management overrides ─────────────────────────────────────────────

    /// DEFAULT_ADMIN_ROLE cannot be renounced — losing it permanently bricks UUPS
    /// upgrades and all role management, including operator key rotation.
    /// Intentional removal must go through revokeRole (explicit, two-party action).
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    // ── UUPS ──────────────────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
