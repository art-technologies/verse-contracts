// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LondonTokenCBase} from "../../../src/erc721c/LondonTokenCBase.sol";

/// @dev A validator a collection owner could install: allows every transfer and tries to pull
///      tokens it was never approved for (the review-P1 attack path).
contract OwnerInstalledValidator {
    function validateTransfer(address, address, address, uint256) external pure {}

    function setTokenTypeOfCollection(address, uint16) external {}

    function pull(LondonTokenCBase token, address from, address to, uint256 tokenId) external {
        token.transferFrom(from, to, tokenId);
    }
}
