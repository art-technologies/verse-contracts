// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Forces native currency into a target that rejects ordinary
///      transfers, via SELFDESTRUCT balance transfer (still effective for
///      balance movement post-EIP-6780).
contract ForceSend {
    constructor() payable {}

    function boom(address payable target) external {
        selfdestruct(target);
    }
}

/// @dev Native-rescue recipient that attempts to re-enter the vault from its
///      receive hook.
contract ReentrantNativeRecipient {
    address public target;
    bytes public reentryCalldata;

    bool public reentryAttempted;
    bool public reentrySucceeded;

    function arm(address target_, bytes calldata reentryCalldata_) external {
        target = target_;
        reentryCalldata = reentryCalldata_;
    }

    receive() external payable {
        if (target != address(0) && reentryCalldata.length > 0) {
            reentryAttempted = true;
            (bool ok,) = target.call(reentryCalldata);
            reentrySucceeded = ok;
        }
    }
}
