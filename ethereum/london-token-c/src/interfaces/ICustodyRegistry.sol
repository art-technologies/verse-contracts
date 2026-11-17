// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ICustodyRegistry
/// @notice Verse-owned list of custody accounts (custody EOAs and vault contracts) whose
///         owner-initiated transfers Verse ERC721-C collections exempt from transfer validation.
interface ICustodyRegistry {
    /// @notice Emitted when an account is added to or removed from the registry.
    event CustodianSet(address indexed account, bool isCustodian);

    /// @notice The zero address cannot be a custodian.
    error ZeroAddressCustodian();

    /// @notice The call would not change the registry (already added / not present).
    error CustodianUnchanged(address account, bool isCustodian);

    /// @notice Adding would exceed MAX_CUSTODIANS.
    error TooManyCustodians(uint256 max);

    /// @notice Renouncing ownership would freeze the registry and is disabled.
    error RenounceOwnershipDisabled();

    /// @notice Returns whether `account` is a registered Verse custody account.
    function isCustody(address account) external view returns (bool);

    /// @notice Adds (`isCustodian = true`) or removes (`false`) a custody account. Owner only.
    function setCustodian(address account, bool isCustodian) external;

    /// @notice Returns every registered custody account (unordered).
    function custodians() external view returns (address[] memory);
}
