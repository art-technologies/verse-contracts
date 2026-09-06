// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @dev ERC-1155 whose outbound transfers revert after a configurable number
///      of successful transfers. Minting is always allowed.
contract RevertingERC1155 is ERC1155 {
    uint256 public transfersBeforeRevert = type(uint256).max;
    uint256 public transferCount;

    constructor() ERC1155("uri://reverting/{id}") {}

    function mint(address to, uint256 id, uint256 amount) external {
        _mint(to, id, amount, "");
    }

    /// @dev n == 0 reverts on the first transfer; type(uint256).max never
    ///      reverts.
    function setTransfersBeforeRevert(uint256 n) external {
        transfersBeforeRevert = n;
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        if (from != address(0)) {
            if (transferCount >= transfersBeforeRevert) {
                revert("RevertingERC1155: transfer disabled");
            }
            transferCount += 1;
        }
        super._update(from, to, ids, values);
    }
}
