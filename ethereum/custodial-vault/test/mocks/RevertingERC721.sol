// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @dev ERC-721 whose outbound transfers revert after a configurable number
///      of successful transfers, used to prove that one failing item rolls
///      back the entire withdrawal, including earlier transfers and the
///      checkpoint write. Minting is always allowed so tests can seed the
///      vault.
contract RevertingERC721 is ERC721 {
    uint256 public transfersBeforeRevert = type(uint256).max;
    uint256 public transferCount;

    constructor() ERC721("RevertingNFT", "RNFT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    /// @dev n == 0 reverts on the first transfer; n == 1 allows one transfer
    ///      then reverts; type(uint256).max never reverts.
    function setTransfersBeforeRevert(uint256 n) external {
        transfersBeforeRevert = n;
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        if (_ownerOf(tokenId) != address(0)) {
            if (transferCount >= transfersBeforeRevert) {
                revert("RevertingERC721: transfer disabled");
            }
            transferCount += 1;
        }
        return super._update(to, tokenId, auth);
    }
}
