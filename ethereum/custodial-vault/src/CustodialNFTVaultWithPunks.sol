// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CustodialNFTVault} from "./CustodialNFTVault.sol";
import {ICryptoPunks} from "./interfaces/ICryptoPunks.sol";
import {ICustodialNFTVaultWithPunks} from "./interfaces/ICustodialNFTVaultWithPunks.sol";

/// @title CustodialNFTVaultWithPunks
/// @notice CryptoPunks extension of {CustodialNFTVault}: inherits the entire
///         base vault unchanged (storage, roles, limiter, locking, rescue,
///         execute) and adds the single {withdrawPunks} entrypoint. Deployed
///         only on chains with punk custody (Ethereum Mainnet); other chains
///         run the base vault, which does not carry this selector.
/// @dev The punk path is built exclusively on the base vault's internal
///      rails — {_checkWithdrawalPreconditions} and {_consumeOrAutoLock} —
///      so the manager gate, pause state, auto-lock semantics, batch cap,
///      and the global sliding-window budget are shared with {withdraw} by
///      construction: one punk consumes one distinct identifier, and the
///      punk path cannot bypass the rate limit. No base behavior is
///      overridden.
contract CustodialNFTVaultWithPunks is CustodialNFTVault, ICustodialNFTVaultWithPunks {
    /// @notice Deploys the punks extension vault; parameters are forwarded
    ///         to the {CustodialNFTVault} constructor unchanged.
    constructor(
        address initialOwner,
        address[] memory initialManagers,
        address[] memory initialEmergencyLockers,
        Limits memory initialLimits
    ) CustodialNFTVault(initialOwner, initialManagers, initialEmergencyLockers, initialLimits) {}

    /// @inheritdoc ICustodialNFTVaultWithPunks
    function withdrawPunks(WithdrawalItem[] calldata items)
        external
        nonReentrant
        returns (bool executed)
    {
        uint256 len = items.length;
        Limits memory limits = _checkWithdrawalPreconditions(len);

        _validatePunkItems(items);

        (bool consumed, uint256 usedBefore) = _consumeOrAutoLock(len, limits);
        if (!consumed) return false;

        // Limiter storage is updated before any external call (same ordering
        // argument as {withdraw}). transferPunk throws unless the vault owns
        // the punk, so a failed transfer reverts the consumption atomically;
        // there is no receiver callback on this path.
        for (uint256 i; i < len; ++i) {
            // slither-disable-next-line calls-loop
            ICryptoPunks(items[i].token).transferPunk(items[i].recipient, items[i].tokenId);
        }

        emit PunkWithdrawalExecuted(msg.sender, len, usedBefore, usedBefore + len);
        return true;
    }

    /// @dev Validates a {withdrawPunks} batch: non-zero addresses, `amount`
    ///      exactly 1, `standard` fixed to the canonical
    ///      `TokenStandard.ERC721` placeholder (punks are non-fungible and
    ///      the field is otherwise unused on this path), and strictly
    ///      ascending `(token, tokenId)` order, which also forbids
    ///      duplicates. Every item is therefore one distinct token in the
    ///      shared window. Reverts before any state update or token call.
    function _validatePunkItems(WithdrawalItem[] calldata items) private pure {
        // slither-disable-start uninitialized-local
        address prevToken;
        uint256 prevTokenId;
        // slither-disable-end uninitialized-local

        for (uint256 i; i < items.length; ++i) {
            WithdrawalItem calldata item = items[i];

            if (item.token == address(0)) revert ZeroTokenAddress(i);
            if (item.recipient == address(0)) revert ZeroRecipientAddress(i);
            if (item.amount != 1) revert InvalidAmount(i);
            if (item.standard != TokenStandard.ERC721) revert InvalidTokenStandard(i);

            if (
                i > 0
                    && (item.token < prevToken
                        || (item.token == prevToken && item.tokenId <= prevTokenId))
            ) {
                revert ItemsNotSorted(i);
            }

            prevToken = item.token;
            prevTokenId = item.tokenId;
        }
    }
}
