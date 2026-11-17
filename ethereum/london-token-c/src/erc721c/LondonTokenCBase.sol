// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ICustodyRegistry} from "../interfaces/ICustodyRegistry.sol";
import {ITransferValidatorManagement} from "../interfaces/ITransferValidatorManagement.sol";
import {LondonERC721} from "./LondonERC721.sol";
import {OnchainFileStorage} from "./OnchainFileStorage.sol";
import {ICreatorToken} from "./vendor/limitbreak/interfaces/ICreatorToken.sol";
import {ICreatorTokenLegacy} from "./vendor/limitbreak/interfaces/ICreatorTokenLegacy.sol";
import {CreatorTokenBase} from "./vendor/limitbreak/utils/CreatorTokenBase.sol";

/// @title LondonTokenCBase
/// @notice The Verse London artist collection (art-technologies/london-protocol `LondonTokenBase`)
///         as an ERC721-C creator token. Transfers are checked by the Limit Break transfer
///         validator (v5 by default), which lets OpenSea enforce creator earnings. The one Verse
///         addition: when a registered Verse custody account moves a token it owns, validation is
///         skipped, so custody withdrawals cannot be broken by later validator policy changes.
/// @dev Deployed once as an implementation and used through EIP-1167 clones created by
///      LondonTokenCFactory. The external ABI of LondonTokenBase is kept (initialize, mint*,
///      payloads, metadata setters, roles, royalties, on-chain file storage) so the Verse minter and
///      indexer need no changes. Mints keep London's two Transfer events (0x0 -> creator ->
///      recipient), bypass the transfer hooks, and are never validated (same as standard ERC721-C).
///      Unlike Limit Break's reference ERC721C, there is no automatic approval of the transfer
///      validator: the owner chooses the validator, so auto-approval would let the owner install a
///      contract that moves holders' (and Verse custody's) tokens without their approval. A
///      validator here can only allow or block transfers.
/// @custom:security-contact contact@verse.works
contract LondonTokenCBase is LondonERC721, OnchainFileStorage, IERC2981, CreatorTokenBase {
    struct RoyaltyInfo {
        address recipient;
        uint24 amount;
    }

    /// @notice Transfer policy applied at deployment (see initializeWithTransferPolicy).
    /// @param whitelist      Operators (marketplace / protocol contracts) allowed to move tokens,
    ///                       e.g. Payment Processor. Empty = no operator is whitelisted.
    /// @param authorizers    Order-level authorizers allowed to vouch for a transfer, e.g. the
    ///                       OpenSea SignedZone (OpenSea enforced-earnings fills). Empty = none.
    /// @param globalOptions  Validator v5 global option flags (bit 0 disables authorization mode,
    ///                       bit 2 enables account freezing, bit 3 also applies Limit Break's
    ///                       default lists on top of this one).
    /// @param rulesetOptions Validator v5 whitelist-ruleset flags (bit 0 blocks all OTC transfers,
    ///                       bit 3 blocks transfers to contracts, ...). 0 keeps the defaults.
    struct TransferPolicy {
        address[] whitelist;
        address[] authorizers;
        uint8 globalOptions;
        uint16 rulesetOptions;
    }

    /// @notice Maximum royalty in basis points (10%), matching OpenSea's cap for enforced earnings.
    uint256 public constant MAX_ROYALTY_BPS = 1000;

    /// @notice Maximum accounts per list type in a deployment-time transfer policy.
    uint256 public constant MAX_POLICY_ACCOUNTS = 32;

    // Limit Break Transfer Validator v5 constants (creator-token-transfer-validator Constants.sol).
    uint8 private constant LIST_TYPE_WHITELIST = 1;
    uint8 private constant LIST_TYPE_AUTHORIZERS = 2;
    // The Whitelist ruleset binding (id 0 is "default", currently also Whitelist, but Limit Break
    // may rebind it); an explicit policy pins whitelist semantics.
    uint8 private constant RULESET_ID_WHITELIST = 4;

    /// @notice Collection symbol. London clones return an empty symbol; this constant fixes that.
    string private constant SYMBOL = "VERSE";

    /// @notice Verse custody registry consulted for the custody exemption. Immutable in the
    ///         implementation bytecode, so every clone shares it. Zero disables the exemption.
    ICustodyRegistry public immutable custodyRegistry;

    /// @notice Emitted when the owner changes the minting manager (not emitted by initialize).
    event MintingManagerUpdated(address indexed previousManager, address indexed newManager);
    /// @notice Emitted when the owner changes the gateway manager (not emitted by initialize).
    event GatewayManagerUpdated(address indexed previousManager, address indexed newManager);

    /// @notice Emitted when a deployment-time transfer policy is applied. `listId` is the
    ///         validator list now applied to this collection and owned by `listOwner`.
    event TransferPolicyApplied(
        uint48 indexed listId,
        address indexed listOwner,
        uint256 whitelistCount,
        uint256 authorizerCount,
        uint8 globalOptions,
        uint16 rulesetOptions
    );

    error AlreadyInitialized();
    error ZeroOwner();
    error RoyaltyTooHigh(uint256 value, uint256 max);
    error TransferPolicyTooManyAccounts(uint256 count, uint256 max);
    error TransferPolicyZeroAccount();
    error TransferValidatorNotDeployed(address validator);

    /**
     * @notice The total number of tokens in existence.
     */
    uint256 public totalSupply;

    /**
     * @notice Address of the creator of the tokens.
     */
    address public creator;

    /**
     * @notice Address responsible for minting new tokens.
     */
    address public mintingManager;

    /**
     * @notice Address responsible for managing gateways (base URI).
     */
    address public gatewayManager;

    /**
     * @notice Stores payloads for each token by their ID.
     */
    mapping(uint256 => string) public _payloads;

    /**
     * @notice Name of the artist associated with the tokens.
     */
    string public artistName;

    /**
     * @notice Description of the project for which the tokens are minted.
     */
    string public projectDescription;

    /**
     * @notice Year of the token creation or release.
     */
    string public year;

    /**
     * @notice Licensing information for the token.
     */
    string public license;

    RoyaltyInfo private _royalties;

    bool private _initialized;

    /// @param custodyRegistry_ Verse CustodyRegistry for this chain (zero disables the exemption).
    constructor(address custodyRegistry_) LondonERC721("", SYMBOL, "") Ownable(_msgSender()) {
        custodyRegistry = ICustodyRegistry(custodyRegistry_);
        // Lock the implementation; clones start with fresh storage and are initialized once.
        _initialized = true;
    }

    /**
     * @notice Initializes a clone. Same signature as LondonTokenBase.initialize.
     * @param uri_ The base URI for token metadata.
     * @param minter_ The address with the ability to mint new tokens.
     * @param gatewayManager_ The address of the gateway manager.
     * @param contractName_ The name of the contract.
     * @param royaltyValue_ The royalty in basis points (at most MAX_ROYALTY_BPS).
     * @param owner_ The initial owner (artist); also creator and royalty recipient.
     */
    function initialize(
        string memory uri_,
        address minter_,
        address gatewayManager_,
        string memory contractName_,
        uint256 royaltyValue_,
        address owner_
    ) public {
        _initializeCollection(uri_, minter_, gatewayManager_, contractName_, royaltyValue_, owner_);
    }

    /**
     * @notice Initializes a clone like {initialize} and applies `policy` in the same transaction:
     *         creates a validator list holding `policy.whitelist` (operators) and
     *         `policy.authorizers`, applies it to this collection with the Whitelist ruleset and
     *         the given option flags, then hands list ownership to `owner_` so the artist can
     *         edit it later. Collections created with {initialize} keep Limit Break's default
     *         policy instead (Payment Processor whitelisted, OpenSea SignedZone authorized).
     * @dev The validator accepts collection-management calls from the collection itself, which is
     *      what makes this atomic. Registered custody accounts stay exempt (see
     *      `_preValidateTransfer`), so no policy can block custody withdrawals.
     */
    function initializeWithTransferPolicy(
        string memory uri_,
        address minter_,
        address gatewayManager_,
        string memory contractName_,
        uint256 royaltyValue_,
        address owner_,
        TransferPolicy calldata policy
    ) external {
        _initializeCollection(uri_, minter_, gatewayManager_, contractName_, royaltyValue_, owner_);
        _applyTransferPolicy(policy, owner_);
    }

    // ---------------------------------------------------------------------
    // Collection metadata (owner)
    // ---------------------------------------------------------------------

    /// @notice Sets the artist name for the collection.
    function setArtistName(string memory artistName_) public onlyOwner {
        artistName = artistName_;
    }

    /// @notice Sets the collection name.
    function setCollectionName(string memory name_) public onlyOwner {
        _name = name_;
    }

    /// @notice Sets the collection description.
    function setDescription(string memory description_) public onlyOwner {
        projectDescription = description_;
    }

    /// @notice Sets the collection year.
    function setYear(string memory year_) public onlyOwner {
        year = year_;
    }

    /// @notice Sets the collection license.
    function setLicense(string memory license_) public onlyOwner {
        license = license_;
    }

    /// @notice Returns the collection symbol.
    function symbol() public pure override returns (string memory) {
        return SYMBOL;
    }

    // ---------------------------------------------------------------------
    // Minting (mintingManager)
    // ---------------------------------------------------------------------

    /**
     * @notice Creates `tokenId` and assigns it to `to`. Emits two Transfer events
     *         (0x0 -> creator, creator -> to) like LondonTokenBase. Mints are not validated.
     */
    function mint(address to, uint256 tokenId) public onlyMinter {
        _mintLondon(to, tokenId);
    }

    /// @notice Same as {mint}, also storing `payload` for the token.
    function mintWithPayload(address to, uint256 tokenId, string memory payload) public onlyMinter {
        _mintLondon(to, tokenId);
        _payloads[tokenId] = payload;
    }

    /// @notice Batch version of {mint}.
    function mintBatch(address[] memory to, uint256[] memory tokenIds) public onlyMinter {
        require(tokenIds.length == to.length, "Arrays length mismatch");

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _mintLondon(to[i], tokenIds[i]);
        }
    }

    /// @notice Batch version of {mintWithPayload}.
    function mintBatchWithPayload(
        address[] memory to,
        uint256[] memory tokenIds,
        string[] memory payloads
    ) public onlyMinter {
        require(
            tokenIds.length == to.length && payloads.length == to.length, "Arrays length mismatch"
        );

        for (uint256 i = 0; i < tokenIds.length; i++) {
            _mintLondon(to[i], tokenIds[i]);
            _payloads[tokenIds[i]] = payloads[i];
        }
    }

    modifier onlyMinter() {
        require(msg.sender == mintingManager, "Permission denied");
        _;
    }

    modifier onlyGatewayManager() {
        require(msg.sender == gatewayManager, "Permission denied");
        _;
    }

    // ---------------------------------------------------------------------
    // Payloads, roles, URI, royalties
    // ---------------------------------------------------------------------

    /// @notice Returns the payload stored for `tokenId`.
    function getPayload(uint256 tokenId) public view returns (string memory) {
        return _payloads[tokenId];
    }

    /// @notice Sets the payload for `tokenId`.
    function setPayload(uint256 tokenId, string memory payload) public onlyOwner {
        _payloads[tokenId] = payload;
    }

    /// @notice Sets the collection royalty recipient and value (basis points, at most 10%).
    function setRoyalties(address royaltyRecipient, uint256 royaltyValue) public onlyOwner {
        _setTokenRoyalty(royaltyRecipient, royaltyValue);
    }

    /// @notice Sets the minting manager.
    function setMintingManager(address minter_) public onlyOwner {
        emit MintingManagerUpdated(mintingManager, minter_);
        mintingManager = minter_;
    }

    /// @notice Sets the gateway manager.
    function setGatewayManager(address gatewayManager_) public onlyOwner {
        emit GatewayManagerUpdated(gatewayManager, gatewayManager_);
        gatewayManager = gatewayManager_;
    }

    /// @notice Sets the base URI for metadata.
    function setURI(string memory newuri) public onlyGatewayManager {
        _setURI(newuri);
    }

    /// @inheritdoc IERC2981
    function royaltyInfo(
        uint256,
        /* tokenId */
        uint256 value
    )
        external
        view
        override
        returns (address receiver, uint256 royaltyAmount)
    {
        RoyaltyInfo memory royalties = _royalties;
        receiver = royalties.recipient;
        royaltyAmount = (value * royalties.amount) / 10_000;
    }

    // ---------------------------------------------------------------------
    // ERC721-C
    // ---------------------------------------------------------------------

    /// @notice Validation function the transfer validator exposes, for transaction simulation.
    function getTransferValidationFunction()
        external
        pure
        returns (bytes4 functionSignature, bool isViewFunction)
    {
        functionSignature = bytes4(keccak256("validateTransfer(address,address,address,uint256)"));
        isViewFunction = true;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(LondonERC721, IERC165)
        returns (bool)
    {
        return interfaceId == type(ICreatorToken).interfaceId
            || interfaceId == type(ICreatorTokenLegacy).interfaceId
            || interfaceId == type(IERC2981).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @notice Returns whether `account` is a registered Verse custody account.
    function isVerseCustody(address account) external view returns (bool) {
        return _isVerseCustody(account);
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _initializeCollection(
        string memory uri_,
        address minter_,
        address gatewayManager_,
        string memory contractName_,
        uint256 royaltyValue_,
        address owner_
    ) private {
        if (_initialized) revert AlreadyInitialized();
        if (owner_ == address(0)) revert ZeroOwner();
        _initialized = true;

        _name = contractName_;
        _baseUri = uri_;
        mintingManager = minter_;
        gatewayManager = gatewayManager_;
        _setTokenRoyalty(owner_, royaltyValue_);
        creator = owner_;
        _transferOwnership(owner_);

        // CreatorTokenBase's constructor only ran for the implementation; do its work per clone.
        _emitDefaultTransferValidator();
        _registerTokenType(getTransferValidator());
    }

    function _applyTransferPolicy(TransferPolicy calldata policy, address listOwner) private {
        _requireValidPolicyAccounts(policy.whitelist);
        _requireValidPolicyAccounts(policy.authorizers);

        address validator = getTransferValidator();
        if (validator.code.length == 0) revert TransferValidatorNotDeployed(validator);
        ITransferValidatorManagement v = ITransferValidatorManagement(validator);

        uint48 listId =
            v.createList(string.concat("LondonTokenC ", Strings.toHexString(address(this))));
        if (policy.whitelist.length > 0) {
            v.addAccountsToList(listId, LIST_TYPE_WHITELIST, policy.whitelist);
        }
        if (policy.authorizers.length > 0) {
            v.addAccountsToList(listId, LIST_TYPE_AUTHORIZERS, policy.authorizers);
        }
        v.setRulesetOfCollection(
            address(this),
            RULESET_ID_WHITELIST,
            address(0),
            policy.globalOptions,
            policy.rulesetOptions
        );
        v.applyListToCollection(address(this), listId);
        v.reassignOwnershipOfList(listId, listOwner);

        emit TransferPolicyApplied(
            listId,
            listOwner,
            policy.whitelist.length,
            policy.authorizers.length,
            policy.globalOptions,
            policy.rulesetOptions
        );
    }

    function _requireValidPolicyAccounts(address[] calldata accounts) private pure {
        uint256 len = accounts.length;
        if (len > MAX_POLICY_ACCOUNTS) {
            revert TransferPolicyTooManyAccounts(len, MAX_POLICY_ACCOUNTS);
        }
        for (uint256 i; i < len; ++i) {
            if (accounts[i] == address(0)) revert TransferPolicyZeroAccount();
        }
    }

    function _mintLondon(address to, uint256 tokenId) private {
        require(to != address(0), "mint to the zero address");
        require(!_exists(tokenId), "ERC721: token already minted");

        _balances[to] += 1;
        totalSupply += 1;
        _owners[tokenId] = to;

        emit Transfer(address(0), creator, tokenId);
        emit Transfer(creator, to, tokenId);
    }

    function _setTokenRoyalty(address recipient, uint256 value) private {
        if (value > MAX_ROYALTY_BPS) revert RoyaltyTooHigh(value, MAX_ROYALTY_BPS);
        // casting to 'uint24' is safe because value <= MAX_ROYALTY_BPS (1000) was checked above
        // forge-lint: disable-next-line(unsafe-typecast)
        _royalties = RoyaltyInfo(recipient, uint24(value));
    }

    /// @dev Ties London's transfer hooks to ERC721-C validation (as Limit Break's ERC721C does).
    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal override {
        _validateBeforeTransfer(from, to, tokenId);
    }

    /// @dev Ties London's transfer hooks to ERC721-C validation (as Limit Break's ERC721C does).
    function _afterTokenTransfer(address from, address to, uint256 tokenId) internal override {
        _validateAfterTransfer(from, to, tokenId);
    }

    /// @dev Custody exemption: a registered Verse custody account moving a token it owns
    ///      (`caller == from`) skips the validator. Any other transfer, including an operator
    ///      moving a custody-held token, goes through normal ERC721-C validation.
    function _preValidateTransfer(
        address caller,
        address from,
        address to,
        uint256 tokenId,
        uint256 value
    ) internal override {
        if (caller == from && _isVerseCustody(from)) {
            return;
        }
        super._preValidateTransfer(caller, from, to, tokenId, value);
    }

    /// @dev Never reverts: a missing, reverting or malformed registry means "not custody".
    function _isVerseCustody(address account) internal view returns (bool) {
        address registry = address(custodyRegistry);
        if (registry.code.length == 0) {
            return false;
        }
        (bool ok, bytes memory ret) =
            registry.staticcall(abi.encodeCall(ICustodyRegistry.isCustody, (account)));
        return ok && ret.length == 32 && abi.decode(ret, (uint256)) == 1;
    }

    function _requireCallerIsContractOwner() internal view override {
        _checkOwner();
    }

    function _tokenType() internal pure override returns (uint16) {
        return uint16(721);
    }
}
