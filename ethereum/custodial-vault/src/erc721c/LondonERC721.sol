// SPDX-License-Identifier: MIT
// Ported from art-technologies/london-protocol `contracts/ERC721.sol` (itself derived from
// OpenZeppelin Contracts v4.8.0). Storage layout and public getters are unchanged. OZ 5 port:
// `Address.isContract` is replaced by `code.length`, and the unused `_mint`/`_burn` internals and
// batch bookkeeping are dropped (London mints write storage directly; see LondonTokenCBase).
pragma solidity 0.8.30;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @title LondonERC721
/// @notice The Verse London ERC-721 core: OZ-style transfers with `_beforeTokenTransfer` /
///         `_afterTokenTransfer` hooks on every non-mint transfer.
abstract contract LondonERC721 is Context, ERC165, IERC721, IERC721Metadata {
    // Token name
    string public _name;

    // Token symbol
    string private _symbol;

    // Mapping from token ID to owner address
    mapping(uint256 => address) public _owners;

    // Mapping owner address to token count
    mapping(address => uint256) public _balances;

    // Mapping from token ID to approved address
    mapping(uint256 => address) private _tokenApprovals;

    // Mapping from owner to operator approvals
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    // Metadata Update event (EIP-4906 style, as emitted by London)
    event MetadataUpdate(uint256 _tokenId);

    // Base URI for all tokens; tokenURI is `<base>/<tokenId>`
    string public _baseUri;

    constructor(string memory name_, string memory symbol_, string memory uri_) {
        _name = name_;
        _symbol = symbol_;
        _baseUri = uri_;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165, IERC165)
        returns (bool)
    {
        return interfaceId == type(IERC721).interfaceId
            || interfaceId == type(IERC721Metadata).interfaceId
            || super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC721
    function balanceOf(address owner) public view virtual override returns (uint256) {
        require(owner != address(0), "ERC721: address zero is not a valid owner");
        return _balances[owner];
    }

    /// @inheritdoc IERC721
    function ownerOf(uint256 tokenId) public view virtual override returns (address) {
        address owner = _ownerOf(tokenId);
        require(owner != address(0), "ERC721: invalid token ID");
        return owner;
    }

    /// @inheritdoc IERC721Metadata
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /// @inheritdoc IERC721Metadata
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /// @inheritdoc IERC721Metadata
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory) {
        _requireMinted(tokenId);

        string memory baseURI = _baseUri;
        return
            bytes(baseURI).length > 0 ? string.concat(baseURI, "/", Strings.toString(tokenId)) : "";
    }

    /// @dev Sets a new base URI for all tokens.
    function _setURI(string memory newuri_) internal virtual {
        _baseUri = newuri_;
        emit MetadataUpdate(type(uint256).max);
    }

    /// @inheritdoc IERC721
    function approve(address to, uint256 tokenId) public virtual override {
        address owner = LondonERC721.ownerOf(tokenId);
        require(to != owner, "ERC721: approval to current owner");

        require(
            _msgSender() == owner || isApprovedForAll(owner, _msgSender()),
            "ERC721: approve caller is not token owner or approved for all"
        );

        _approve(to, tokenId);
    }

    /// @inheritdoc IERC721
    function getApproved(uint256 tokenId) public view virtual override returns (address) {
        _requireMinted(tokenId);

        return _tokenApprovals[tokenId];
    }

    /// @inheritdoc IERC721
    function setApprovalForAll(address operator, bool approved) public virtual override {
        _setApprovalForAll(_msgSender(), operator, approved);
    }

    /// @inheritdoc IERC721
    function isApprovedForAll(address owner, address operator)
        public
        view
        virtual
        override
        returns (bool)
    {
        return _operatorApprovals[owner][operator];
    }

    /// @inheritdoc IERC721
    function transferFrom(address from, address to, uint256 tokenId) public virtual override {
        require(
            _isApprovedOrOwner(_msgSender(), tokenId),
            "ERC721: caller is not token owner or approved"
        );

        _transfer(from, to, tokenId);
    }

    /// @inheritdoc IERC721
    function safeTransferFrom(address from, address to, uint256 tokenId) public virtual override {
        safeTransferFrom(from, to, tokenId, "");
    }

    /// @inheritdoc IERC721
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data)
        public
        virtual
        override
    {
        require(
            _isApprovedOrOwner(_msgSender(), tokenId),
            "ERC721: caller is not token owner or approved"
        );
        _safeTransfer(from, to, tokenId, data);
    }

    /// @dev Transfers `tokenId` and checks that a contract recipient accepts ERC-721 tokens.
    function _safeTransfer(address from, address to, uint256 tokenId, bytes memory data)
        internal
        virtual
    {
        _transfer(from, to, tokenId);
        require(
            _checkOnERC721Received(from, to, tokenId, data),
            "ERC721: transfer to non ERC721Receiver implementer"
        );
    }

    /// @dev Returns the owner of `tokenId`; does not revert if the token does not exist.
    function _ownerOf(uint256 tokenId) internal view virtual returns (address) {
        return _owners[tokenId];
    }

    /// @dev Returns whether `tokenId` exists.
    function _exists(uint256 tokenId) internal view virtual returns (bool) {
        return _ownerOf(tokenId) != address(0);
    }

    /// @dev Returns whether `spender` may manage `tokenId`. Reverts if the token does not exist.
    function _isApprovedOrOwner(address spender, uint256 tokenId)
        internal
        view
        virtual
        returns (bool)
    {
        address owner = LondonERC721.ownerOf(tokenId);
        return
            (spender == owner || isApprovedForAll(owner, spender)
                    || getApproved(tokenId) == spender);
    }

    /// @dev Transfers `tokenId` from `from` to `to` without checking `msg.sender`.
    ///      Calls `_beforeTokenTransfer` / `_afterTokenTransfer` around the state change.
    function _transfer(address from, address to, uint256 tokenId) internal virtual {
        require(LondonERC721.ownerOf(tokenId) == from, "ERC721: transfer from incorrect owner");
        require(to != address(0), "ERC721: transfer to the zero address");

        _beforeTokenTransfer(from, to, tokenId);

        // Check that tokenId was not transferred by `_beforeTokenTransfer` hook
        require(LondonERC721.ownerOf(tokenId) == from, "ERC721: transfer from incorrect owner");

        // Clear approvals from the previous owner
        delete _tokenApprovals[tokenId];

        unchecked {
            // `from` holds at least this token; `to` cannot realistically overflow.
            _balances[from] -= 1;
            _balances[to] += 1;
        }
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);

        _afterTokenTransfer(from, to, tokenId);
    }

    /// @dev Approves `to` to operate on `tokenId`.
    function _approve(address to, uint256 tokenId) internal virtual {
        _tokenApprovals[tokenId] = to;
        emit Approval(LondonERC721.ownerOf(tokenId), to, tokenId);
    }

    /// @dev Approves `operator` to operate on all of `owner`'s tokens.
    function _setApprovalForAll(address owner, address operator, bool approved) internal virtual {
        require(owner != operator, "ERC721: approve to caller");
        _operatorApprovals[owner][operator] = approved;
        emit ApprovalForAll(owner, operator, approved);
    }

    /// @dev Reverts if `tokenId` has not been minted.
    function _requireMinted(uint256 tokenId) internal view virtual {
        require(_exists(tokenId), "ERC721: invalid token ID");
    }

    /// @dev Invokes {IERC721Receiver-onERC721Received} on `to` when it has code.
    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data)
        private
        returns (bool)
    {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(_msgSender(), from, tokenId, data) returns (
                bytes4 retval
            ) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert("ERC721: transfer to non ERC721Receiver implementer");
                } else {
                    /// @solidity memory-safe-assembly
                    assembly {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        } else {
            return true;
        }
    }

    /// @dev Hook called before every transfer made through `_transfer` (never for mints).
    function _beforeTokenTransfer(address from, address to, uint256 tokenId) internal virtual {}

    /// @dev Hook called after every transfer made through `_transfer` (never for mints).
    function _afterTokenTransfer(address from, address to, uint256 tokenId) internal virtual {}
}
