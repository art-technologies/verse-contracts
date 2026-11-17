// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ITransferValidatorManagement
/// @notice The subset of Limit Break Creator Token Transfer Validator v5 list and collection
///         management used by LondonTokenC to apply a transfer policy at deployment. Signatures
///         match limitbreakinc/creator-token-transfer-validator `CreatorTokenTransferValidator`.
interface ITransferValidatorManagement {
    /// @notice Creates a list owned by the caller and returns its id.
    function createList(string calldata name) external returns (uint48 id);

    /// @notice Adds accounts to list `id` under `listType` (1 = whitelist, 2 = authorizers).
    ///         Caller must own the list.
    function addAccountsToList(uint48 id, uint8 listType, address[] calldata accounts) external;

    /// @notice Sets the ruleset and option flags for `collection`. Caller must be the collection,
    ///         its owner, or its admin.
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;

    /// @notice Applies list `id` to `collection`. Caller must be the collection, its owner, or its
    ///         admin.
    function applyListToCollection(address collection, uint48 id) external;

    /// @notice Transfers ownership of list `id` to `newOwner`. Caller must own the list.
    function reassignOwnershipOfList(uint48 id, address newOwner) external;
}
