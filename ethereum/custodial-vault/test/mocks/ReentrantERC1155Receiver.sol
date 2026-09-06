// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @dev Withdrawal recipient that attempts to re-enter the vault with
///      arbitrary prepared calldata from inside the ERC-1155 receiver
///      callbacks.
contract ReentrantERC1155Receiver is IERC1155Receiver {
    address public target;
    bytes public reentryCalldata;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    function arm(address target_, bytes calldata reentryCalldata_) external {
        target = target_;
        reentryCalldata = reentryCalldata_;
    }

    function _reenter() private {
        if (target != address(0) && reentryCalldata.length > 0) {
            reentryAttempted = true;
            (bool ok, bytes memory ret) = target.call(reentryCalldata);
            reentrySucceeded = ok;
            reentryReturnData = ret;
        }
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        _reenter();
        return IERC1155Receiver.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external override returns (bytes4) {
        _reenter();
        return IERC1155Receiver.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
