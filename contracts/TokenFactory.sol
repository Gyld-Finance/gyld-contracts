// SPDX-License-Identifier: BUSL-1.1
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
///   DOCUMENT_ROLE             → operator   (ERC-1643 doc set/remove — operational)
///   DEFAULT_ADMIN_ROLE        → owner()    (whoever owns the factory at deploy time)
///   NAVFeed owner             → navFeedOwner (KMS signer)
///
/// DEFAULT_ADMIN_ROLE is wired to factory.owner() so that the governance authority
/// over tokens is always the same entity that governs the factory. In production the
/// factory owner MUST be a TimelockController — this guarantees a mandatory delay on
/// all role changes, role grants, and UUPS upgrades on every deployed token.
///
/// TOKEN-level roles are shed: `_wireRoles` self-revokes `PAUSER_ROLE` and
/// `DEFAULT_ADMIN_ROLE` from the factory on every token it deploys.
///
/// `REGISTRAR_ROLE` on the IssuanceManager is NOT, and must not be — `deployToken` calls
/// `registerToken` on every deployment, so revoking it bricks all later deploys. What
/// bounds it, and why that is safe: ARCHITECTURE.md D-21.
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

    /// ISIN bond-salt (`_bondSalt`) → the token deployed for that ISIN on this chain,
    /// `address(0)` if none. Prevents any same-ISIN deployment regardless of
    /// name/symbol/maturity variations, because the CREATE2 address includes initcode
    /// (name+symbol+maturity) so a same-ISIN deploy with different name/symbol would land
    /// at a different address — creating two on-chain tokens for the same real-world bond.
    ///
    /// Stores the token address rather than a bool (audit FIND-018): a nonzero address
    /// carries exactly the same "already deployed" meaning, so the duplicate guard is
    /// unchanged, and the registry now answers the question it exists to support — which
    /// token belongs to a given bond. `tokenByIsin` is the string-keyed front door;
    /// this mapping is public for callers that already hold the key.
    mapping(bytes32 => address) public tokenOfIsinKey;

    // ── Errors ────────────────────────────────────────────────────────────────

    error ZeroAddress();
    /// audit FIND-003 — navFeedOwner (KMS signer) must differ from operator (NAV guardian).
    error NavFeedOwnerIsOperator();
    error EmptyIsin();
    /// audit FIND-013 — the ISIN is not 12 uppercase alphanumerics.
    error MalformedIsin(string isin);
    error IsinAlreadyDeployed(string isin);
    error MaturityInPast(uint256 maturityTimestamp, uint256 nowTs);
    error MissingRegistrarRole(address factory, address issuanceManager);
    error ProxyDeployFailed();
    error NotValidSanctionsList(address addr);
    /// renounceOwnership() is disabled — the factory must never be left ownerless.
    error CannotRenounceOwnership();

    /// audit FIND-018 — the deployment log now carries the bond identifier, so the
    /// ISIN → token association is recoverable from logs alone.
    /// `isinKey` is `_bondSalt(isin)` = keccak256(isin || chainId), indexed so an indexer
    /// can pull a series' deployment in one filtered `getLogs`. `isin` rides in the data
    /// as well, because an `indexed string` stores only its hash in the topic — filterable,
    /// but not readable.
    /// `forwarder` moved out of the topics to make room: the EVM allows three indexed
    /// parameters and the bond identifier is the more useful filter. It is still in the
    /// data, and still readable from state as `forwarderOf[token]`.
    event TokenDeployed(
        address indexed token,
        address indexed navFeed,
        bytes32 indexed isinKey,
        address forwarder,
        address issuanceManager,
        string isin
    );

    /// @param bondTokenLogic_ GyldBondToken implementation every proxy delegates to.
    /// @param sanctionsList_  on-chain sanctions oracle baked into every token deployed here.
    /// @param owner_          initial owner (Ownable2Step). Passed EXPLICITLY rather than
    ///                        taken from `msg.sender` (GYL-1135): the bootstrap contracts are
    ///                        deployed through the canonical CREATE2 proxy
    ///                        (0x4e59…4956C) so that the same address can never be a
    ///                        different contract type on another chain, and `Ownable(msg.sender)`
    ///                        would have made THAT PROXY the factory owner — permanently
    ///                        bricking `transferOwnership` and with it the hand-over to the
    ///                        TimelockController. In production this must be a
    ///                        TimelockController (or an address that hands over to one).
    constructor(address bondTokenLogic_, address sanctionsList_, address owner_) Ownable(owner_) {
        if (bondTokenLogic_ == address(0) || sanctionsList_ == address(0)) revert ZeroAddress();
        // Same admission terms as GyldBondToken._probeSanctionsOracle, leg for leg, including
        // the code-length and canonical-bool checks (audit FIND-008): a word above 1 passes a
        // length-only probe and then reverts the ABI validator on every transfer of every token
        // deployed here. This is a hand-rolled copy because no token exists yet to call, and
        // `sanctionsList` is immutable with no setter — an oracle this constructor admits but
        // `GyldBondToken.initialize` refuses would make every deployToken revert forever, with
        // no remedy but redeploying the factory. test_constructorProbe_agreesWithBondTokenProbe
        // is what holds the two together.
        if (sanctionsList_.code.length == 0) revert NotValidSanctionsList(sanctionsList_);
        (bool ok, bytes memory data) = sanctionsList_.staticcall(
            abi.encodeWithSignature("isSanctioned(address)", address(0))
        );
        if (!ok || data.length != 32 || abi.decode(data, (uint256)) != 0) {
            revert NotValidSanctionsList(sanctionsList_);
        }
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
    ///                          It is part of the initcode, so a different value here yields a
    ///                          different address.
    /// @return Predicted GyldBondToken proxy address (ERC1967Proxy).
    function predictTokenAddress(
        string memory name,
        string memory symbol,
        string memory isin,
        uint256 maturityTimestamp
    ) external view returns (address) {
        // Audit FIND-013: same rule as deployToken — never quote an undeployable address.
        _requireCanonicalIsin(isin);
        bytes32 salt = _tokenSalt(_bondSalt(isin));
        return address(uint160(uint256(keccak256(
            abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(_tokenInitCode(name, symbol, isin, maturityTimestamp)))
        ))));
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
    /// @param maturityTimestamp  Unix maturity timestamp; 0 = no fixed maturity. Must be in the
    ///                           future (or 0) — reverts MaturityInPast otherwise. Stored as
    ///                           off-chain metadata and never enforced afterwards (FIND-009).
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
        // Audit FIND-011. `navFeedOwner == address(this)` would hand the factory ownership
        // of a feed it cannot write to and cannot pass on; all three reject it, not just operator.
        if (operator == address(0)        || operator == address(this))        revert ZeroAddress();
        if (issuanceManager == address(0) || issuanceManager == address(this)) revert ZeroAddress();
        if (navFeedOwner == address(0)    || navFeedOwner == address(this))    revert ZeroAddress();
        // The feed enforces this too; failing here names the variable to fix.
        if (navFeedOwner == operator)      revert NavFeedOwnerIsOperator();
        _requireCanonicalIsin(isin);

        // A maturity already in the past has no legitimate use and signals a bad payload
        // (audit FIND-009). 0 stays valid — it is the documented open-ended sentinel.
        if (maturityTimestamp != 0 && maturityTimestamp <= block.timestamp) {
            revert MaturityInPast(maturityTimestamp, block.timestamp);
        }

        // Reject duplicate ISINs early with a readable error. Without this,
        // a same-ISIN call with different name/symbol/maturity would deploy to a
        // different CREATE2 address (initcode includes those params) — producing two
        // on-chain tokens for the same real-world bond. Keying by _bondSalt(isin)
        // (ISIN + chainId) catches every same-ISIN deployment regardless of other params.
        bytes32 isinKey = _bondSalt(isin);
        if (tokenOfIsinKey[isinKey] != address(0)) revert IsinAlreadyDeployed(isin);

        // Preflight: verify factory holds REGISTRAR_ROLE on the IssuanceManager
        // before spending gas on three contract deployments. Without this check,
        // the call would succeed through all deployments and fail silently (or
        // revert expensively) at the registerToken() step.
        if (!IssuanceManager(issuanceManager).hasRole(
            IssuanceManager(issuanceManager).REGISTRAR_ROLE(),
            address(this)
        )) revert MissingRegistrarRole(address(this), issuanceManager);

        // Deploy GyldBondToken proxy via assembly CREATE2 using the same _tokenInitCode
        // helper that predictTokenAddress hashes — both paths are identical by construction.
        bytes memory ic = _tokenInitCode(name, symbol, isin, maturityTimestamp);
        bytes32 tokenSalt = _tokenSalt(isinKey);
        address deployedToken;
        assembly {
            deployedToken := create2(0, add(ic, 0x20), mload(ic), tokenSalt)
        }
        if (deployedToken == address(0)) revert ProxyDeployFailed();
        token = deployedToken;

        // Claim the ISIN the instant the address exists, BEFORE any external call.
        // This slot is read by the duplicate guard above, so writing it after the
        // role-wiring and feed deployments would leave a checks-effects-interactions
        // inversion — inert here (`onlyOwner` + `nonReentrant`, and every callee is
        // bytecode this factory just wrote), but Slither is right to flag the shape
        // and there is no reason to keep it.
        tokenOfIsinKey[isinKey] = token;

        _wireRoles(token, issuanceManager, operator);

        // NAV emergency guardian = `operator`, the ops wallet that already holds
        // PAUSER_ROLE. Deliberately not the 48 h timelock: a correction that waits two
        // days is not a correction. See ARCHITECTURE D-29.
        navFeed =
            address(new KaleidoscopeNAVFeed(navFeedOwner, string(abi.encodePacked(symbol, " / USD NAV")), operator));

        // Forwarder is the stable address for DeFi integrations (Morpho Blue, Aave).
        // Owner = factory.owner() (TimelockController in prod) so oracle provider swaps
        // require governance approval. The KMS signer (navFeedOwner) writes prices to
        // navFeed directly and has no control over the forwarder pointer.
        forwarder = address(new NAVFeedForwarder(navFeed, owner()));

        navFeedOf[token]   = navFeed;
        forwarderOf[token] = forwarder;
        emit TokenDeployed(token, navFeed, isinKey, forwarder, issuanceManager, isin);
        IssuanceManager(issuanceManager).registerToken(token);
    }

    /// @notice Disabled (GLD-166) — the factory can never be left ownerless.
    /// @dev    `deployToken` is `onlyOwner`, so renouncing permanently ends the ability
    ///         to issue new bond series, and the factory is not upgradeable so there is
    ///         no path back. Already-deployed tokens are unaffected — `_wireRoles`
    ///         grants DEFAULT_ADMIN_ROLE to `owner()` as a snapshot at deploy time, not
    ///         a live lookup — but every FUTURE series is lost. Rotate with
    ///         transferOwnership + acceptOwnership instead. No `onlyOwner`: nobody can
    ///         ever succeed, so one unambiguous error beats telling a non-owner the
    ///         owner could have done it. Not retrofittable — factories deployed before
    ///         this guard lack it.
    function renounceOwnership() public virtual override {
        revert CannotRenounceOwnership();
    }

    /// @notice The GyldBondToken deployed for `isin` on this chain, `address(0)` if none.
    /// @dev    audit FIND-018. The forward lookup — `GyldBondToken.isin()` only answers the
    ///         reverse. Hashes the ISIN the same way `deployToken` does, so callers do not
    ///         have to reproduce `keccak256(abi.encodePacked(isin, block.chainid))`
    ///         themselves. Pairs with `navFeedOf` / `forwarderOf` to reach a series' feed
    ///         and forwarder from the bond identifier alone.
    function tokenByIsin(string memory isin) external view returns (address) {
        return tokenOfIsinKey[_bondSalt(isin)];
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
        // DOCUMENT_ROLE rides with PAUSER: both are operational ops-hot-wallet powers that
        // must not wait on the 48 h timelock. MUST stay above the DEFAULT_ADMIN_ROLE
        // self-revoke below — the factory can only grant while it still holds admin.
        t.grantRole(t.DOCUMENT_ROLE(),      operator_);
        t.grantRole(t.DEFAULT_ADMIN_ROLE(), owner());
        t.revokeRole(t.PAUSER_ROLE(),       address(this));
        t.revokeRole(t.DEFAULT_ADMIN_ROLE(), address(this));
    }

    /// @dev Audit FIND-013. The salt hashes the raw string, so a case or whitespace variant
    ///      would pass the duplicate guard and deploy a second token for the same bond.
    function _requireCanonicalIsin(string memory isin_) internal pure {
        bytes memory b = bytes(isin_);
        if (b.length == 0) revert EmptyIsin();
        if (b.length != 12) revert MalformedIsin(isin_);
        for (uint256 i; i < 12; ++i) {
            uint8 c = uint8(b[i]);
            bool digit = c >= 0x30 && c <= 0x39;
            bool upper = c >= 0x41 && c <= 0x5A;
            if (!digit && !upper) revert MalformedIsin(isin_);
        }
    }

    /// CREATE2 salt for a bond series: keccak256(isin || chainId).
    /// Including chainId prevents the same ISIN from producing the same address
    /// on two different chains (e.g. Ethereum mainnet vs an L2).
    function _bondSalt(string memory isin_) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(isin_, block.chainid));
    }

    /// CREATE2 salt for a token proxy: keccak256("token" ++ bondSalt).
    /// Shared by deployToken and predictTokenAddress so the two can never drift.
    function _tokenSalt(bytes32 bondSalt_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("token", bondSalt_));
    }

    /// Full CREATE2 initcode for a GyldBondToken proxy.
    /// Shared by deployToken (deployed via assembly create2) and predictTokenAddress
    /// (hashed for address prediction) so both paths are identical by construction.
    function _tokenInitCode(
        string memory name,
        string memory symbol,
        string memory isin,
        uint256 maturityTimestamp
    ) internal view returns (bytes memory) {
        bytes memory tokenInit = abi.encodeCall(
            GyldBondToken.initialize,
            (name, symbol, isin, maturityTimestamp, address(this), address(this), sanctionsList)
        );
        return abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(bondTokenLogic, tokenInit));
    }
}
