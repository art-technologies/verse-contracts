// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Multi-purpose hostile token:
///      - claims support for every interface;
///      - its ERC-20 `transfer` re-enters a target with prepared calldata
///        before returning true (rescue-reentrancy case);
///      - its ERC-721-shaped `safeTransferFrom` can revert after a set
///        number of successful calls (mid-batch failure case).
contract MaliciousToken {
    address public target;
    bytes public reentryCalldata;

    bool public reentryAttempted;
    bool public reentrySucceeded;
    bytes public reentryReturnData;

    uint256 public transfersUntilRevert = type(uint256).max;
    uint256 public transferCalls;

    function arm(address target_, bytes calldata reentryCalldata_) external {
        target = target_;
        reentryCalldata = reentryCalldata_;
    }

    function setTransfersUntilRevert(uint256 count) external {
        transfersUntilRevert = count;
    }

    /// @dev Lies: claims to support every interface.
    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }

    /// @dev ERC-20 shape; re-enters `target` before returning success.
    function transfer(address, uint256) external returns (bool) {
        if (target != address(0) && reentryCalldata.length > 0) {
            reentryAttempted = true;
            (bool ok, bytes memory ret) = target.call(reentryCalldata);
            reentrySucceeded = ok;
            reentryReturnData = ret;
        }
        return true;
    }

    /// @dev ERC-721 shape; reverts once the configured call budget is spent.
    function safeTransferFrom(address, address, uint256) external {
        if (transferCalls >= transfersUntilRevert) {
            revert("MaliciousToken: mid-batch revert");
        }
        transferCalls += 1;
    }

    /// @dev ERC-1155 shape; same call budget as the ERC-721 shape.
    function safeTransferFrom(address, address, uint256, uint256, bytes calldata) external {
        if (transferCalls >= transfersUntilRevert) {
            revert("MaliciousToken: mid-batch revert");
        }
        transferCalls += 1;
    }
}
