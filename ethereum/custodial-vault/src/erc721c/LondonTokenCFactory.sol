// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

import {LondonTokenCBase} from "./LondonTokenCBase.sol";

/**
 * @title LondonTokenCFactory
 * @notice Creates Verse ERC721-C artist collections: EIP-1167 clones of LondonTokenCBase.
 *         `createCollection` and the `NewCollection` event match LondonTokenFactory, so Verse
 *         Studio can deploy either variant with the same call shape.
 */
contract LondonTokenCFactory {
    event NewCollection(address);

    /// @notice Implementation every collection clones.
    address public immutable tokenImplementation;

    /// @notice Verse custody registry baked into the implementation.
    address public immutable custodyRegistry;

    /// @param custodyRegistry_ Verse CustodyRegistry for this chain.
    constructor(address custodyRegistry_) {
        custodyRegistry = custodyRegistry_;
        tokenImplementation = address(new LondonTokenCBase(custodyRegistry_));
    }

    /**
     * @notice Creates and initializes a new collection.
     * @param uri_ The base URI for the collection's metadata.
     * @param minter_ The address allowed to mint new tokens.
     * @param gatewayManager_ The address allowed to update the base URI.
     * @param contractName_ The name of the new token contract.
     * @param royaltyValue_ The royalty in basis points (at most 1000).
     * @param owner_ The collection owner (artist).
     * @return clone The new collection address (also emitted as NewCollection).
     */
    function createCollection(
        string memory uri_,
        address minter_,
        address gatewayManager_,
        string memory contractName_,
        uint256 royaltyValue_,
        address owner_
    ) external returns (address clone) {
        clone = Clones.clone(tokenImplementation);
        LondonTokenCBase(clone)
            .initialize(uri_, minter_, gatewayManager_, contractName_, royaltyValue_, owner_);
        emit NewCollection(clone);
    }

    /**
     * @notice Creates a collection like {createCollection} and applies `policy` atomically:
     *         the given operator whitelist and authorizers replace Limit Break's default lists for
     *         this collection (e.g. an empty policy blocks every marketplace). The artist
     *         (`owner_`) owns the resulting validator list and can change the policy later.
     * @return clone The new collection address (also emitted as NewCollection).
     */
    function createCollectionWithTransferPolicy(
        string memory uri_,
        address minter_,
        address gatewayManager_,
        string memory contractName_,
        uint256 royaltyValue_,
        address owner_,
        LondonTokenCBase.TransferPolicy calldata policy
    ) external returns (address clone) {
        clone = Clones.clone(tokenImplementation);
        LondonTokenCBase(clone)
            .initializeWithTransferPolicy(
                uri_, minter_, gatewayManager_, contractName_, royaltyValue_, owner_, policy
            );
        emit NewCollection(clone);
    }
}
