// SPDX-License-Identifier: MIT
pragma solidity =0.8.28;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./GyldBondToken.sol";
import "./KaleidoscopeNAVFeed.sol";
import "./NAVFeedForwarder.sol";
import "./IssuanceManager.sol";

/// @title TokenFactory
/// @notice Deploys a (GyldBondToken proxy, KaleidoscopeNAVFeed) pair per bond instrument
///         and wires roles atomically.
///
/// Compliance model: every GyldBondToken reads directly from the Chainalysis on-chain
/// sanctions oracle (`sanctionsList`). There is no internal blocklist. If an address
/// appears on OFAC/SDN/UN lists, transfers revert automatically — no platform action needed.
///
/// Role wiring after deploy:
///   MINTER_ROLE + BURNER_ROLE → issuanceManager exclusively (not operator)
///   PAUSER_ROLE               → operator   (ops hot wallet — no delay needed)
///   DEFAULT_ADMIN_ROLE        → owner()    (whoever owns the factory at deploy time)
///   NAVFeed owner             → navFeedOwner (KMS signer)
///
/// DEFAULT_ADMIN_ROLE is wired to factory.owner() so that the governance authority
/// over tokens is always the same entity that governs the factory. In production the
/// factory owner MUST be a TimelockController — this guarantees a mandatory delay on
/// all role changes, role grants, and UUPS upgrades on every deployed token.
///
/// The factory holds no permanent permissions after deployment.
/// DEFAULT_ADMIN_ROLE is self-revoked from the factory at the end of _wireRoles.
///
/// The factory owner should be a TimelockController (48-hour delay) in production.
contract TokenFactory is Ownable2Step, ReentrancyGuard {
    address public immutable bondTokenLogic;

    /// Chainalysis on-chain sanctions oracle shared by all tokens deployed by this factory.
    /// Mainnet: 0x40C57923924B5c5c5455c48D93317139ADDaC8fb
    /// Devnet:  MockSanctionsList
    address public immutable sanctionsList;

    /// token address → its paired KaleidoscopeNAVFeed address (backend writes prices here)
    mapping(address => address) public navFeedOf;

    /// token address → its paired NAVFeedForwarder address (DeFi protocols integrate this)
    mapping(address => address) public forwarderOf;

    /// ISIN bond-salt → whether this ISIN has been deployed on this chain.
    /// Prevents any same-ISIN deployment regardless of name/symbol/maturity variations,
    /// because CREATE2 address includes initcode (name+symbol+maturity) so a same-ISIN
    /// deploy with different name/symbol would land at a different address — creating
    /// two on-chain tokens for the same real-world bond.
    mapping(bytes32 => bool) private _deployedIsins;

    // ── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    error EmptyIsin();
    error IsinAlreadyDeployed(string isin);
    error MissingRegistrarRole(address factory, address issuanceManager);

    event TokenDeployed(
        address indexed token,
        address indexed navFeed,
        address indexed forwarder,
        address issuanceManager
    );

    constructor(address bondTokenLogic_, address sanctionsList_) Ownable(msg.sender) {
        if (bondTokenLogic_ == address(0) || sanctionsList_ == address(0)) revert ZeroAddress();
        bondTokenLogic = bondTokenLogic_;
        sanctionsList  = sanctionsList_;
    }

    /// @notice Predict the deterministic address a GyldBondToken will be deployed to
    ///         before calling deployToken. Uses the same CREATE2 salt formula.
    /// @dev    All four parameters must match the values you intend to pass to deployToken.
    ///         The `operator` argument does NOT affect the CREATE2 address and is therefore
    ///         not required here.
    /// @param name              Token name — must match deployToken call exactly.
    /// @param symbol            Ticker — must match deployToken call exactly.
    /// @param isin              ISO 6166 ISIN — must match deployToken call exactly.
    /// @param maturityTimestamp Unix maturity timestamp — must match deployToken call exactly.
    /// @return Predicted GyldBondToken proxy address (ERC1967Proxy).
    function predictTokenAddress(
        string memory name,
        string memory symbol,
        string memory isin,
        uint256 maturityTimestamp
    ) external view returns (address) {
        bytes32 bondSalt  = _bondSalt(isin);
        bytes32 tokenSalt = keccak256(abi.encodePacked("token", bondSalt));
        bytes memory tokenInit = abi.encodeCall(
            GyldBondToken.initialize,
            (name, symbol, isin, maturityTimestamp, address(this), address(this), sanctionsList)
        );
        bytes memory initCode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(bondTokenLogic, tokenInit)
        );
        bytes32 hash = keccak256(
            abi.encodePacked(bytes1(0xff), address(this), tokenSalt, keccak256(initCode))
        );
        return address(uint160(uint256(hash)));
    }

    /// @notice Deploy a GyldBondToken proxy, KaleidoscopeNAVFeed, and NAVFeedForwarder
    ///         atomically for a single bond series. Wires all roles in the same transaction.
    /// @dev    Caller must be the factory owner (TimelockController in production).
    ///         The factory holds DEFAULT_ADMIN_ROLE temporarily during role wiring and
    ///         self-revokes before returning — it holds no permanent permissions post-deploy.
    /// @param name               Token name, e.g. "Gyld US Treasury Bond 2026-06".
    /// @param symbol             Ticker, e.g. "GYLD-UST-2606".
    /// @param isin               ISO 6166 ISIN, e.g. "US912797KR72". Used as CREATE2 salt
    ///                           (together with chainId) so token addresses are stable and
    ///                           predictable before issuance.
    /// @param maturityTimestamp  Unix maturity timestamp; 0 = no fixed maturity.
    /// @param operator           Platform hot-wallet — receives PAUSER_ROLE.
    ///                           Does NOT receive MINTER_ROLE, BURNER_ROLE, or DEFAULT_ADMIN_ROLE.
    /// @param issuanceManager    Deployed IssuanceManager — receives MINTER_ROLE and BURNER_ROLE.
    /// @param navFeedOwner       KMS signer that calls KaleidoscopeNAVFeed.updateAnswer() daily.
    ///                           Does NOT own the NAVFeedForwarder — forwarder owner is
    ///                           factory.owner() so oracle provider swaps require governance.
    /// @return token     Deployed GyldBondToken proxy address.
    /// @return navFeed   Deployed KaleidoscopeNAVFeed address (backend writes prices here).
    /// @return forwarder Deployed NAVFeedForwarder address (give this to Morpho Blue / Aave).
    function deployToken(
        string memory name,
        string memory symbol,
        string memory isin,
        uint256 maturityTimestamp,
        address operator,
        address issuanceManager,
        address navFeedOwner
    ) external onlyOwner nonReentrant returns (address token, address navFeed, address forwarder) {
        if (operator == address(0) || operator == address(this)) revert ZeroAddress();
        if (issuanceManager == address(0)) revert ZeroAddress();
        if (navFeedOwner == address(0))    revert ZeroAddress();
        if (bytes(isin).length == 0)       revert EmptyIsin();

        // Reject duplicate ISINs early with a readable error. Without this,
        // a same-ISIN call with different name/symbol/maturity would deploy to a
        // different CREATE2 address (initcode includes those params) — producing two
        // on-chain tokens for the same real-world bond. Keying by _bondSalt(isin)
        // (ISIN + chainId) catches every same-ISIN deployment regardless of other params.
        bytes32 isinKey = _bondSalt(isin);
        if (_deployedIsins[isinKey]) revert IsinAlreadyDeployed(isin);

        // Preflight: verify factory holds REGISTRAR_ROLE on the IssuanceManager
        // before spending gas on four contract deployments. Without this check,
        // the call would succeed through all deployments and fail silently (or
        // revert expensively) at the registerToken() step.
        if (!IssuanceManager(issuanceManager).hasRole(
            IssuanceManager(issuanceManager).REGISTRAR_ROLE(),
            address(this)
        )) revert MissingRegistrarRole(address(this), issuanceManager);

        // Deploy GyldBondToken proxy (UUPS). Factory is temporary DEFAULT_ADMIN + PAUSER.
        // sanctionsList is the read-only Chainalysis oracle — no internal blocklist.
        bytes memory tokenInit = abi.encodeCall(
            GyldBondToken.initialize,
            (name, symbol, isin, maturityTimestamp, address(this), address(this), sanctionsList)
        );
        token = address(
            new ERC1967Proxy{salt: keccak256(abi.encodePacked("token", isinKey))}(
                bondTokenLogic,
                tokenInit
            )
        );

        _wireRoles(token, issuanceManager, operator);

        navFeed = address(new KaleidoscopeNAVFeed(
            navFeedOwner,
            string(abi.encodePacked(symbol, " / USD NAV"))
        ));

        // Forwarder is the stable address for DeFi integrations (Morpho Blue, Aave).
        // Owner = factory.owner() (TimelockController in prod) so oracle provider swaps
        // require governance approval. The KMS signer (navFeedOwner) writes prices to
        // navFeed directly and has no control over the forwarder pointer.
        forwarder = address(new NAVFeedForwarder(navFeed, owner()));

        IssuanceManager(issuanceManager).registerToken(token);
        _deployedIsins[isinKey] = true;
        navFeedOf[token]        = navFeed;
        forwarderOf[token]      = forwarder;
        emit TokenDeployed(token, navFeed, forwarder, issuanceManager);
    }

    // ── Internal helpers ──────────────────────────────────────────────────────

    /// @dev Wire all roles on a freshly-deployed GyldBondToken.
    ///      operator_  receives PAUSER_ROLE (ops hot wallet).
    ///      owner()    receives DEFAULT_ADMIN_ROLE — whoever owns the factory at deploy time.
    ///                 In production the factory owner must be a TimelockController.
    function _wireRoles(address token_, address issuanceManager_, address operator_) internal {
        GyldBondToken t = GyldBondToken(token_);
        t.grantRole(t.MINTER_ROLE(),        issuanceManager_);
        t.grantRole(t.BURNER_ROLE(),        issuanceManager_);
        t.grantRole(t.PAUSER_ROLE(),        operator_);
        t.grantRole(t.DEFAULT_ADMIN_ROLE(), owner());
        t.revokeRole(t.PAUSER_ROLE(),       address(this));
        t.revokeRole(t.DEFAULT_ADMIN_ROLE(), address(this));
    }

    /// CREATE2 salt for a bond series: keccak256(isin || chainId).
    /// Including chainId prevents the same ISIN from producing the same address
    /// on two different chains (e.g. Ethereum mainnet vs Base).
    function _bondSalt(string memory isin_) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(isin_, block.chainid));
    }
}
