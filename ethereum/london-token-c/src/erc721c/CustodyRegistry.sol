// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ICustodyRegistry} from "../interfaces/ICustodyRegistry.sol";

/// @title CustodyRegistry
/// @notice One registry per chain listing Verse custody accounts. Every LondonTokenC collection
///         reads it on transfers: when a registered account moves a token it owns, the collection
///         skips ERC721-C transfer validation. Withdrawals from Verse custody therefore keep working
///         whatever transfer policy a collection owner or Limit Break applies later, and a future
///         custody vault becomes compatible with every existing collection by registering it.
/// @dev Security: the owner can exempt any account, including a contract that trades for third
///      parties, which would let it move Verse ERC721-C tokens it owns without royalties. The owner
///      MUST be the production Safe (optionally behind a TimelockController). Removal is the
///      emergency control. The registry cannot move tokens itself.
contract CustodyRegistry is ICustodyRegistry, Ownable2Step {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Upper bound on registered accounts, so `custodians()` stays cheap to read.
    uint256 public constant MAX_CUSTODIANS = 32;

    EnumerableSet.AddressSet private _custodians;

    constructor(address initialOwner, address[] memory initialCustodians) Ownable(initialOwner) {
        uint256 len = initialCustodians.length;
        for (uint256 i; i < len; ++i) {
            _setCustodian(initialCustodians[i], true);
        }
    }

    /// @inheritdoc ICustodyRegistry
    function isCustody(address account) external view returns (bool) {
        return _custodians.contains(account);
    }

    /// @inheritdoc ICustodyRegistry
    function setCustodian(address account, bool isCustodian) external onlyOwner {
        _setCustodian(account, isCustodian);
    }

    /// @inheritdoc ICustodyRegistry
    function custodians() external view returns (address[] memory) {
        return _custodians.values();
    }

    /// @notice Disabled: an ownerless registry could never remove a compromised custodian.
    function renounceOwnership() public pure override {
        revert RenounceOwnershipDisabled();
    }

    function _setCustodian(address account, bool isCustodian) private {
        if (account == address(0)) revert ZeroAddressCustodian();
        bool changed = isCustodian ? _custodians.add(account) : _custodians.remove(account);
        if (!changed) revert CustodianUnchanged(account, isCustodian);
        if (_custodians.length() > MAX_CUSTODIANS) revert TooManyCustodians(MAX_CUSTODIANS);
        emit CustodianSet(account, isCustodian);
    }
}
