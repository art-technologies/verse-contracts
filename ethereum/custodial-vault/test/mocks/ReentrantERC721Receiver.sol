// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @dev Withdrawal recipient that attempts to re-enter the vault with
///      arbitrary prepared calldata from inside `onERC721Received`. Records
///      whether the reentrant call succeeded so tests can assert it was
///      blocked without failing the outer transfer.
contract ReentrantERC721Receiver is IERC721Receiver {
    address public target;
    bytes public reentryCalldata;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    function arm(address target_, bytes calldata reentryCalldata_) external {
        target = target_;
        reentryCalldata = reentryCalldata_;
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        override
        returns (bytes4)
    {
        if (target != address(0) && reentryCalldata.length > 0) {
            reentryAttempted = true;
            (bool ok, bytes memory ret) = target.call(reentryCalldata);
            reentrySucceeded = ok;
            reentryReturnData = ret;
        }
        return IERC721Receiver.onERC721Received.selector;
    }
}
