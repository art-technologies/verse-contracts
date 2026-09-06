// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";

/// @dev Contract manager that calls `withdraw` and then reverts its own
///      frame. Demonstrates the documented EVM transaction-frame limitation:
///      the outer revert also rolls back the vault's auto-lock. This is why
///      production managers should be direct EOAs.
contract OuterRevertingManager {
    error OuterRevert();

    function withdrawThenRevert(
        ICustodialNFTVault vault,
        ICustodialNFTVault.WithdrawalItem[] calldata items
    ) external {
        vault.withdraw(items);
        revert OuterRevert();
    }
}
