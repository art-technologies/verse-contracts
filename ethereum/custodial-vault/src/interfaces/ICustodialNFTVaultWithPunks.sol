// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICustodialNFTVault} from "./ICustodialNFTVault.sol";

/// @title ICustodialNFTVaultWithPunks
/// @notice External interface of the CryptoPunks extension vault: the full
///         {ICustodialNFTVault} surface plus the dedicated `withdrawPunks`
///         entrypoint. Deployed only on chains with punk custody (Ethereum
///         Mainnet); other chains run the base vault without this selector.
interface ICustodialNFTVaultWithPunks is ICustodialNFTVault {
    /// @notice A punk withdrawal batch executed successfully.
    /// @param manager The manager that submitted the batch.
    /// @param itemCount Number of punks transferred (each counts as one
    ///        distinct token in the shared window).
    /// @param usedBefore Active window usage before this withdrawal.
    /// @param usedAfter Active window usage after this withdrawal.
    event PunkWithdrawalExecuted(
        address indexed manager, uint256 itemCount, uint256 usedBefore, uint256 usedAfter
    );

    /// @notice Withdraw a batch of CryptoPunks to their recipients. Fully
    ///         separate execution path from {withdraw} (it never touches
    ///         ERC-721/1155 assets and only ever calls `transferPunk`), but
    ///         it reuses the {WithdrawalItem} shape: `token` is the
    ///         CryptoPunks contract, `tokenId` is the punk index, `amount`
    ///         must be exactly 1 and `standard` must be the canonical
    ///         `TokenStandard.ERC721` placeholder. It shares the manager
    ///         gate, pause state, batch-size cap and the SAME global
    ///         sliding-window budget (each punk consumes one distinct
    ///         token), so the punk path cannot be used to bypass the rate
    ///         limit.
    /// @dev Manager only. Items must be strictly ascending by
    ///      `(token, tokenId)` (which also forbids duplicates). Transfers
    ///      use the pre-ERC-721 `transferPunk`, which throws unless the
    ///      vault owns the punk. On insufficient window allowance the vault
    ///      pauses itself, emits {AutoLocked}, performs no transfer, records
    ///      no consumption, and returns false without reverting.
    /// @param items The punk withdrawal batch.
    /// @return executed True when the batch executed; false on auto-lock.
    function withdrawPunks(WithdrawalItem[] calldata items) external returns (bool executed);
}
