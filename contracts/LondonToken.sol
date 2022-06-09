// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./ERC2981PerTokenRoyalties.sol";

/// @custom:security-contact contact@verse.works
contract LondonToken is ERC1155, Ownable, ERC2981PerTokenRoyalties {
    constructor() ERC1155("www.com") {}

    string public name = "London Collection";
    uint256 public tokenCount;

    function setURI(string memory newuri) public onlyOwner {
        _setURI(newuri);
    }

    function mint(
        address account,
        uint256 id,
        uint256 amount,
        address royaltyRecipient,
        uint256 royaltyValue
    ) public onlyOwner {
        _mint(account, id, amount, "");
        if (royaltyValue > 0) {
            _setTokenRoyalty(id, royaltyRecipient, royaltyValue);
            tokenCount += amount;
        }
    }

    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        address[] memory royaltyRecipients,
        uint256[] memory royaltyValues
    ) public onlyOwner {
        require(
            ids.length == royaltyRecipients.length &&
                ids.length == royaltyValues.length,
            "ERC1155: Arrays length mismatch"
        );
        _mintBatch(to, ids, amounts, "");

        for (uint256 i; i < ids.length; i++) {
            if (royaltyValues[i] > 0) {
                _setTokenRoyalty(
                    ids[i],
                    royaltyRecipients[i],
                    royaltyValues[i]
                );
            }
        }

        uint256 count;
        for (uint256 i = 0; i < ids.length; i++) {
            for (uint256 j = 0; j < amounts.length; j++) {
                count += ids[i] * amounts[j];
            }
        }
        tokenCount += count;
    }

    /// @inheritdoc	ERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, ERC2981Base)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function totalSupply() public view returns (uint256) {
        return tokenCount;
    }
}
