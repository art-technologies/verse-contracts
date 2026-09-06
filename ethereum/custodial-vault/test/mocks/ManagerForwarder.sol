// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";

/// @dev Minimal contract manager that forwards a withdrawal and surfaces the
///      vault's boolean result instead of reverting on `false`. Models the
///      only acceptable shape for a contract-based manager.
contract ManagerForwarder {
    event Forwarded(bool executed);

    function forwardWithdraw(
        ICustodialNFTVault vault,
        ICustodialNFTVault.WithdrawalItem[] calldata items
    ) external returns (bool executed) {
        executed = vault.withdraw(items);
        emit Forwarded(executed);
    }
}
