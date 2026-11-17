// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCTestBase} from "./LondonTokenCTestBase.sol";

contract LondonTokenCFactoryTest is LondonTokenCTestBase {
    event NewCollection(address);

    function test_constructor_wiresImplementationAndRegistry() public view {
        assertEq(factory.custodyRegistry(), address(registry));
        LondonTokenCBase implementation = LondonTokenCBase(factory.tokenImplementation());
        assertEq(address(implementation.custodyRegistry()), address(registry));
    }

    function test_createCollection_emitsAndReturnsClone() public {
        vm.recordLogs();
        vm.prank(outsider);
        address clone = factory.createCollection("u", minter, gateway, "Second", 500, outsider);

        // EIP-1167 runtime pointing at the implementation.
        assertEq(
            clone.code,
            abi.encodePacked(
                hex"363d3d373d3d3d363d73",
                factory.tokenImplementation(),
                hex"5af43d82803e903d91602b57fd5bf3"
            )
        );
        assertEq(LondonTokenCBase(clone).owner(), outsider);
        assertEq(LondonTokenCBase(clone).name(), "Second");
        assertEq(address(LondonTokenCBase(clone).custodyRegistry()), address(registry));
    }

    function test_createCollection_emitsNewCollection() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(false, false, false, true, address(factory));
        emit NewCollection(predicted);
        factory.createCollection("u", minter, gateway, "Third", 500, artist);
    }

    function test_collections_areIndependent() public {
        LondonTokenCBase other = _createCollection(factory, "Other");
        vm.prank(minter);
        other.mint(recipient, CUSTODY_TOKEN);
        assertEq(other.ownerOf(CUSTODY_TOKEN), recipient);
        assertEq(token.ownerOf(CUSTODY_TOKEN), custody);
        assertEq(other.totalSupply(), 1);
        assertEq(token.totalSupply(), 2);
    }
}
