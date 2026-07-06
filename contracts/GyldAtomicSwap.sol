// SPDX-License-Identifier: MIT
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

/// @dev Minimal view of the GyldSettlementVault used by this contract.
interface IGyldSettlementVault {
    function onSwap(address taker, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut) external;
    function totalAssets() external view returns (uint256);
}

/// @title GyldAtomicSwap
/// @notice Atomic two-leg settlement against platform-signed EIP-712 quotes. Both legs
///         move via transferFrom — this contract NEVER mints and never holds funds
///         beyond a single transaction. BUY: user USDC in, bond token out of vault
///         inventory. REDEEM: user bond token in, USDC out (vault lends against it).
///
/// Design:
///   - This contract is the ONLY address users ever grant token approvals (or sign
///     EIP-2612 permits) to. The vault holds the funds and PUSHES the outgoing leg —
///     no standing allowances ever exist out of the vault (Hashflow-exploit lesson:
///     every approval target must be small, verified, and in audit scope).
///   - Quotes are signed off-chain by a QUOTE_SIGNER_ROLE key (the role itself is the
///     signer registry — multiple holders supported, rotated via grant/revoke).
///   - msg.sender must equal the quote's `taker` — quotes are not bearer paper
///     (0x RFQ mandatory-taker binding). A relayer mode, if ever needed, lands
///     behind a new message version.
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
///   DEFAULT_ADMIN_ROLE — upgrades, unpause, setVault, bumpQuoteEpoch, role grants;
///                        should be a TimelockController in production
///   QUOTE_SIGNER_ROLE  — quote-service KMS key(s); passive — checked via hasRole
///                        against the recovered EIP-712 signer
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
    bytes32 public constant PAUSER_ROLE       = keccak256("PAUSER_ROLE");

    // ── EIP-712 ───────────────────────────────────────────────────────────────

    /// @notice Off-chain-signed quote. `taker` pins the user (quotes are not bearer
    ///         paper); `epoch` must equal the current quoteEpoch (mass invalidation).
    ///         `maxAmountIn`/`price` bound a *range* of draws, not one exact amount —
    ///         see `executeSwap`'s `requestedAmountIn` parameter.
    struct SwapMessage {
        uint256 quoteId;      // single-use; consumed via the bitmap below, regardless of draw size
        address taker;        // must equal msg.sender at execution
        address tokenIn;      // leg the user pays
        uint256 maxAmountIn;  // ceiling on tokenIn the taker may draw against this quote
        address tokenOut;     // leg the user receives (vault inventory / USDC pot)
        uint256 price;        // fixed-point amountOut per 1e18 tokenIn; amountOut = requestedAmountIn * price / 1e18
        uint64  expiry;       // unix seconds
        uint64  epoch;        // quote-signer generation
    }

    /// @notice Optional EIP-2612 permit for the incoming leg; value == 0 skips.
    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8   v;
        bytes32 r;
        bytes32 s;
    }

    // keccak256("SwapMessage(uint256 quoteId,address taker,address tokenIn,uint256 maxAmountIn,address tokenOut,uint256 price,uint64 expiry,uint64 epoch)")
    bytes32 public constant SWAP_MESSAGE_TYPEHASH =
        0x87423ed2b6ce38b5c2943920bccdd1f9e50d2e0493f61560b2302e7508b52f0b;

    /// @dev Dust floor on `requestedAmountIn`, expressed as basis points of `maxAmountIn`.
    ///      Prevents a taker griefing the quote-signer's single-use quoteId budget with
    ///      near-zero-value draws (docs/atomic-settlement.md "Proposed amendment").
    uint256 public constant MIN_DRAW_BPS      = 100;    // 1%
    uint256 public constant BPS_DENOMINATOR   = 10_000;

    // ── ERC-7201 namespaced storage ───────────────────────────────────────────

    /// @custom:storage-location erc7201:gyld.GyldAtomicSwap
    struct GyldAtomicSwapStorage {
        address vault;                              // GyldSettlementVault proxy
        uint64  quoteEpoch;                         // bumped to mass-invalidate quotes
        mapping(uint256 => uint256) usedQuoteWords; // quoteId >> 8 → 256-bit usage word
    }

    // keccak256(abi.encode(uint256(keccak256("gyld.GyldAtomicSwap")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant _STORAGE_LOCATION =
        0x21c91deba1ebb3b1dd4f7372693119a28dc8ce05601a0afdcf4ef40d5ef89300;

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
    error NotValidVault(address vault);
    error CannotRenounceAdminRole();

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
    event VaultUpdated(address indexed previousVault, address indexed newVault);

    // ── Constructor / Initializer ─────────────────────────────────────────────

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @param defaultAdmin Should be a TimelockController in production.
    /// @param pauser       Ops multisig — may pause() but not unpause().
    /// @param quoteSigner  Quote-service KMS key; recovered EIP-712 signers must hold
    ///                     QUOTE_SIGNER_ROLE. Rotate via grant/revoke + bumpQuoteEpoch.
    /// @param vault_       GyldSettlementVault proxy; probed before storing.
    function initialize(address defaultAdmin, address pauser, address quoteSigner, address vault_)
        external
        initializer
    {
        if (defaultAdmin == address(0) || pauser == address(0) || quoteSigner == address(0)) revert ZeroAddress();
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __EIP712_init("GyldAtomicSwap", "2"); // v2: capped-allowance SwapMessage (maxAmountIn/price)
        __UUPSUpgradeable_init();
        _setVault(vault_);
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(PAUSER_ROLE,        pauser);
        _grantRole(QUOTE_SIGNER_ROLE,  quoteSigner);
    }

    // ── Public getters ────────────────────────────────────────────────────────

    /// @notice Current quote-signer generation; quotes signed for an older epoch revert.
    function quoteEpoch() external view returns (uint64) { return _getStorage().quoteEpoch; }

    /// @notice GyldSettlementVault proxy this contract settles against.
    function vault() external view returns (address) { return _getStorage().vault; }

    /// @notice Returns whether `quoteId` has already been consumed by executeSwap.
    /// @param  quoteId Single-use quote identifier from the signed SwapMessage.
    /// @return True if the quote can no longer be executed.
    function isQuoteUsed(uint256 quoteId) external view returns (bool) {
        return (_getStorage().usedQuoteWords[quoteId >> 8] >> (quoteId & 0xff)) & 1 != 0;
    }

    // ── Swap execution ────────────────────────────────────────────────────────

    /// @notice Settle a platform-signed quote atomically. Pulls `requestedAmountIn` of
    ///         `tokenIn` from the caller into the vault, then the vault pushes the
    ///         derived `tokenOut` amount to the caller.
    /// @dev    Verification order: taker binding → price sanity → requested-amount range
    ///         → expiry → epoch → EIP-712 signature against QUOTE_SIGNER_ROLE →
    ///         single-use quoteId consumption → derived-amount sanity. The quoteId is
    ///         burned in full regardless of how much of `maxAmountIn` is drawn — this is
    ///         single-shot-capped sizing, not multi-draw (see docs/atomic-settlement.md).
    ///         The optional permit is applied with try/catch so a front-run permit()
    ///         cannot brick the swap (standard griefing mitigation) — the subsequent
    ///         safeTransferFrom enforces the allowance regardless. Real USDC permit is
    ///         non-standard (version "2") and MockUSDC has none, hence optional.
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
    )
        external
        nonReentrant
        whenNotPaused
    {
        GyldAtomicSwapStorage storage $ = _getStorage();

        if (m.taker != msg.sender) revert NotTaker(m.taker, msg.sender);
        if (m.price == 0)          revert ZeroAmount();

        uint256 minAmountIn = (m.maxAmountIn * MIN_DRAW_BPS) / BPS_DENOMINATOR;
        if (requestedAmountIn == 0 || requestedAmountIn < minAmountIn || requestedAmountIn > m.maxAmountIn) {
            revert RequestedAmountOutOfRange(requestedAmountIn, minAmountIn, m.maxAmountIn);
        }

        if (block.timestamp > m.expiry) revert QuoteExpired(m.expiry);
        if (m.epoch != $.quoteEpoch)    revert QuoteEpochStale(m.epoch, $.quoteEpoch);

        address signer = ECDSA.recover(hashSwapMessage(m), signature);
        if (!hasRole(QUOTE_SIGNER_ROLE, signer)) revert InvalidQuoteSigner(signer);

        _consumeQuote($, m.quoteId);

        // Rounds down — vault's favor; a taker-favorable direction would let a taker
        // extract dust across many small draws (docs/atomic-settlement.md).
        uint256 amountOut = (requestedAmountIn * m.price) / 1e18;
        if (amountOut == 0) revert ZeroAmount();

        // Optional EIP-2612 permit; try/catch so a front-run permit() cannot brick the
        // swap — safeTransferFrom below still enforces the allowance.
        if (permitIn.value != 0) {
            try IERC20Permit(m.tokenIn).permit(
                msg.sender, address(this), permitIn.value, permitIn.deadline, permitIn.v, permitIn.r, permitIn.s
            ) {} catch {} // solhint-disable-line no-empty-blocks
        }

        // Leg 1: user → vault. (If tokenIn is a GyldBondToken, its _update screens
        // msg.sender as from, the vault as to, and this contract as spender.)
        IERC20(m.tokenIn).safeTransferFrom(msg.sender, $.vault, requestedAmountIn);

        // Leg 2: vault validates series + NAV band, then pushes tokenOut to the user.
        IGyldSettlementVault($.vault).onSwap(msg.sender, m.tokenIn, requestedAmountIn, m.tokenOut, amountOut);

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
                    m.quoteId, m.taker, m.tokenIn, m.maxAmountIn, m.tokenOut, m.price, m.expiry, m.epoch
                )
            )
        );
    }

    // ── Quote invalidation ────────────────────────────────────────────────────

    /// @dev 1inch BitInvalidator: one bit per quoteId, 256 quotes per storage slot.
    ///      Reverts on reuse — quotes are strictly single-use.
    function _consumeQuote(GyldAtomicSwapStorage storage $, uint256 quoteId) private {
        uint256 word = $.usedQuoteWords[quoteId >> 8];
        uint256 bit  = quoteId & 0xff;
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

    // ── Admin ─────────────────────────────────────────────────────────────────

    /// @notice Point this contract at a new GyldSettlementVault proxy.
    /// @dev    Caller must hold DEFAULT_ADMIN_ROLE. The candidate is probed via
    ///         staticcall before storing — rejects EOAs, wrong contracts, and stubs
    ///         that don't implement totalAssets(). The new vault must independently
    ///         grant this contract SWAP_ROLE or onSwap will revert.
    /// @param newVault GyldSettlementVault proxy address.
    function setVault(address newVault) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setVault(newVault);
    }

    function _setVault(address newVault) private {
        if (newVault == address(0)) revert ZeroAddress();
        // Probe-before-store (house idiom): vault must answer totalAssets().
        // staticcall handles both EOAs (success=true, data="") and wrong contracts
        // (success=false): we require success AND a full 32-byte return value.
        (bool ok, bytes memory data) = newVault.staticcall(abi.encodeWithSignature("totalAssets()"));
        if (!ok || data.length != 32) revert NotValidVault(newVault);
        emit VaultUpdated(_getStorage().vault, newVault);
        _getStorage().vault = newVault;
    }

    // ── Pause ─────────────────────────────────────────────────────────────────

    /// @notice Halt executeSwap. Asymmetric by design: PAUSER (ops multisig) can halt
    ///         cheaply; only DEFAULT_ADMIN_ROLE (timelock) can resume — this contract
    ///         sits on the hot path with a hot signing key.
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }

    /// @notice Resume executeSwap. Deliberately admin-gated (see pause()).
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    // ── Role management overrides ─────────────────────────────────────────────

    /// DEFAULT_ADMIN_ROLE cannot be renounced — losing it permanently bricks UUPS
    /// upgrades, unpause, and all role management, including quote-signer rotation.
    /// Intentional removal must go through revokeRole (explicit, two-party action).
    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdminRole();
        super.renounceRole(role, callerConfirmation);
    }

    // ── UUPS upgrade authorization ────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}
