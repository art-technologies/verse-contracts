// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CustodyRegistry} from "../../src/erc721c/CustodyRegistry.sol";
import {ICustodyRegistry} from "../../src/interfaces/ICustodyRegistry.sol";

contract CustodyRegistryTest is Test {
    address internal safe = makeAddr("safe");
    address internal venly = makeAddr("venly");
    address internal vault = makeAddr("vault");
    address internal outsider = makeAddr("outsider");

    CustodyRegistry internal registry;

    function setUp() public {
        address[] memory initial = new address[](1);
        initial[0] = venly;
        registry = new CustodyRegistry(safe, initial);
    }

    function test_constructor_setsOwnerAndCustodians() public view {
        assertEq(registry.owner(), safe);
        assertTrue(registry.isCustody(venly));
        assertFalse(registry.isCustody(vault));
        address[] memory all = registry.custodians();
        assertEq(all.length, 1);
        assertEq(all[0], venly);
    }

    function test_constructor_emitsAndValidates() public {
        address[] memory initial = new address[](2);
        initial[0] = venly;
        initial[1] = vault;
        vm.expectEmit(true, false, false, true);
        emit ICustodyRegistry.CustodianSet(venly, true);
        vm.expectEmit(true, false, false, true);
        emit ICustodyRegistry.CustodianSet(vault, true);
        new CustodyRegistry(safe, initial);

        initial[1] = venly;
        vm.expectRevert(
            abi.encodeWithSelector(ICustodyRegistry.CustodianUnchanged.selector, venly, true)
        );
        new CustodyRegistry(safe, initial);

        initial[1] = address(0);
        vm.expectRevert(ICustodyRegistry.ZeroAddressCustodian.selector);
        new CustodyRegistry(safe, initial);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CustodyRegistry(address(0), new address[](0));
    }

    function test_setCustodian_addAndRemove() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit ICustodyRegistry.CustodianSet(vault, true);
        vm.prank(safe);
        registry.setCustodian(vault, true);
        assertTrue(registry.isCustody(vault));

        vm.expectEmit(true, false, false, true, address(registry));
        emit ICustodyRegistry.CustodianSet(venly, false);
        vm.prank(safe);
        registry.setCustodian(venly, false);
        assertFalse(registry.isCustody(venly));
        assertEq(registry.custodians().length, 1);
    }

    function test_setCustodian_onlyOwner() public {
        vm.prank(outsider);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider)
        );
        registry.setCustodian(outsider, true);
    }

    function test_setCustodian_rejectsNoOpAndZero() public {
        vm.startPrank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(ICustodyRegistry.CustodianUnchanged.selector, venly, true)
        );
        registry.setCustodian(venly, true);
        vm.expectRevert(
            abi.encodeWithSelector(ICustodyRegistry.CustodianUnchanged.selector, vault, false)
        );
        registry.setCustodian(vault, false);
        vm.expectRevert(ICustodyRegistry.ZeroAddressCustodian.selector);
        registry.setCustodian(address(0), true);
        vm.stopPrank();
    }

    function test_setCustodian_cap() public {
        uint256 max = registry.MAX_CUSTODIANS();
        vm.startPrank(safe);
        for (uint256 i = 1; i < max; ++i) {
            // casting to 'uint160' is safe because 0x1000 + i < 2**160 for i < MAX_CUSTODIANS
            // forge-lint: disable-next-line(unsafe-typecast)
            registry.setCustodian(address(uint160(0x1000 + i)), true);
        }
        assertEq(registry.custodians().length, max);
        vm.expectRevert(abi.encodeWithSelector(ICustodyRegistry.TooManyCustodians.selector, max));
        registry.setCustodian(address(uint160(0x9999)), true);
        vm.stopPrank();
    }

    function test_renounceOwnership_disabled() public {
        vm.prank(safe);
        vm.expectRevert(ICustodyRegistry.RenounceOwnershipDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), safe);
    }

    function test_ownershipTransfer_isTwoStep() public {
        address newSafe = makeAddr("newSafe");
        vm.prank(safe);
        registry.transferOwnership(newSafe);
        assertEq(registry.owner(), safe);
        assertEq(registry.pendingOwner(), newSafe);
        vm.prank(newSafe);
        registry.acceptOwnership();
        assertEq(registry.owner(), newSafe);
    }
}
