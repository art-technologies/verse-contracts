// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CustodialNFTVault} from "../../src/CustodialNFTVault.sol";
import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Ownership transfer (Ownable2Step), role replacement (EnumerableSet),
///      and limit configuration (§22.8).
contract ConfigurationTest is VaultTestBase {
    address internal newOwner = makeAddr("newOwner");
    address internal otherPending = makeAddr("otherPending");

    function _limits(uint16 maxTokens, uint32 period, uint8 maxItems)
        internal
        pure
        returns (ICustodialNFTVault.Limits memory)
    {
        return ICustodialNFTVault.Limits(maxTokens, period, maxItems);
    }

    function _ascending(uint256 count) internal pure returns (address[] memory arr) {
        arr = new address[](count);
        for (uint256 i; i < count; ++i) {
            // Bounded synthetic addresses; the cast cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            arr[i] = address(uint160(0x1000 + i));
        }
    }

    // -------------------------------------------------------------------
    // Two-step ownership transfer
    // -------------------------------------------------------------------

    function test_twoStepOwnershipTransfer() public {
        vm.prank(admin);
        vault.transferOwnership(newOwner);
        assertEq(vault.pendingOwner(), newOwner);
        assertEq(vault.owner(), admin, "owner unchanged until acceptance");

        vm.prank(newOwner);
        vault.acceptOwnership();
        assertEq(vault.owner(), newOwner);
        assertEq(vault.pendingOwner(), address(0), "acceptance clears pendingOwner");
    }

    function test_newProposalReplacesOlderPending() public {
        vm.prank(admin);
        vault.transferOwnership(newOwner);
        vm.prank(admin);
        vault.transferOwnership(otherPending);
        assertEq(vault.pendingOwner(), otherPending);

        _expectNotOwner(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();

        vm.prank(otherPending);
        vault.acceptOwnership();
        assertEq(vault.owner(), otherPending);
    }

    function test_zeroTransferCancelsPendingWithoutRenouncing() public {
        vm.prank(admin);
        vault.transferOwnership(newOwner);
        // Standard Ownable2Step semantics: transferring to zero cancels the
        // pending transfer; it can never renounce ownership.
        vm.prank(admin);
        vault.transferOwnership(address(0));
        assertEq(vault.pendingOwner(), address(0));
        assertEq(vault.owner(), admin);

        _expectNotOwner(newOwner);
        vm.prank(newOwner);
        vault.acceptOwnership();
    }

    function test_renunciationIsDisabled() public {
        vm.expectRevert(ICustodialNFTVault.OwnershipRenunciationDisabled.selector);
        vm.prank(admin);
        vault.renounceOwnership();

        vm.expectRevert(ICustodialNFTVault.OwnershipRenunciationDisabled.selector);
        vm.prank(outsider);
        vault.renounceOwnership();
        assertEq(vault.owner(), admin);
    }

    // -------------------------------------------------------------------
    // Role arrays
    // -------------------------------------------------------------------

    function test_managerSetAtMinimumAndMaximumSizes() public {
        vm.prank(admin);
        vault.setManagers(_ascending(1));
        assertEq(vault.getManagers().length, 1);

        vm.prank(admin);
        vault.setManagers(_ascending(10));
        assertEq(vault.getManagers().length, 10);
    }

    function test_emptyRoleArraysRevert() public {
        address[] memory empty = new address[](0);
        vm.startPrank(admin);
        vm.expectRevert(ICustodialNFTVault.NoManagers.selector);
        vault.setManagers(empty);
        vm.expectRevert(ICustodialNFTVault.NoEmergencyLockers.selector);
        vault.setEmergencyLockers(empty);
        vm.stopPrank();
    }

    function test_oversizedRoleArraysRevert() public {
        address[] memory eleven = _ascending(11);
        vm.startPrank(admin);
        vm.expectRevert(ICustodialNFTVault.TooManyManagers.selector);
        vault.setManagers(eleven);
        vm.expectRevert(ICustodialNFTVault.TooManyEmergencyLockers.selector);
        vault.setEmergencyLockers(eleven);
        vm.stopPrank();
    }

    function test_duplicateRoleAddressesRevert() public {
        address[] memory dup = new address[](2);
        dup[0] = address(uint160(0x1000));
        dup[1] = address(uint160(0x1000));
        vm.expectRevert(ICustodialNFTVault.RoleAddressesNotSorted.selector);
        vm.prank(admin);
        vault.setManagers(dup);
    }

    function test_unsortedRoleAddressesRevert() public {
        address[] memory desc = new address[](2);
        desc[0] = address(uint160(0x2000));
        desc[1] = address(uint160(0x1000));
        vm.expectRevert(ICustodialNFTVault.RoleAddressesNotSorted.selector);
        vm.prank(admin);
        vault.setEmergencyLockers(desc);
    }

    function test_zeroRoleAddressReverts() public {
        address[] memory withZero = new address[](2);
        withZero[0] = address(0);
        withZero[1] = address(uint160(0x1000));
        vm.expectRevert(ICustodialNFTVault.ZeroRoleAddress.selector);
        vm.prank(admin);
        vault.setManagers(withZero);
    }

    function test_replacementRevokesOldMembersAndReturnsCanonicalArray() public {
        address[] memory replacement = _ascending(3);
        vm.prank(admin);
        vault.setManagers(replacement);

        assertFalse(vault.isManager(manager1), "old managers removed");
        assertFalse(vault.isManager(manager2));
        for (uint256 i; i < 3; ++i) {
            assertTrue(vault.isManager(replacement[i]));
        }
        address[] memory stored = vault.getManagers();
        assertEq(stored.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertEq(stored[i], replacement[i], "canonical ascending order");
        }

        vm.expectRevert(ICustodialNFTVault.NotManager.selector);
        vm.prank(manager1);
        vault.withdraw(_batch721(0, 1));
    }

    function test_lockerReplacementRevokesOldLockers() public {
        vm.prank(admin);
        vault.setEmergencyLockers(_ascending(2));
        assertFalse(vault.isEmergencyLocker(locker1));

        vm.expectRevert(ICustodialNFTVault.NotOwnerOrEmergencyLocker.selector);
        vm.prank(locker1);
        vault.lock();
    }

    // -------------------------------------------------------------------
    // Limits boundaries
    // -------------------------------------------------------------------

    function test_limitsAtEveryBoundaryAccepted() public {
        vm.startPrank(admin);
        vault.setLimits(_limits(1, DEFAULT_PERIOD, 1));
        vault.setLimits(_limits(2000, DEFAULT_PERIOD, 50));
        vm.stopPrank();

        ICustodialNFTVault.Limits memory limits = vault.getLimits();
        assertEq(limits.maxTokens, 2000);
        assertEq(limits.periodSeconds, DEFAULT_PERIOD);
        assertEq(limits.maxItemsPerBatch, 50);

        // Period boundaries are exercised through the constructor.
        new CustodialNFTVault(admin, _managers2(), _lockers1(), _limits(100, 1, 10));
        new CustodialNFTVault(admin, _managers2(), _lockers1(), _limits(100, 2_592_000, 10));
    }

    function test_outOfCapLimitsRevert() public {
        vm.startPrank(admin);
        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        vault.setLimits(_limits(0, DEFAULT_PERIOD, 10));
        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        vault.setLimits(_limits(2001, DEFAULT_PERIOD, 10));
        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        vault.setLimits(_limits(100, 0, 10));
        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        vault.setLimits(_limits(100, 2_592_001, 10));
        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        vault.setLimits(_limits(100, DEFAULT_PERIOD, 0));
        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        vault.setLimits(_limits(100, DEFAULT_PERIOD, 51));
        vm.stopPrank();
    }

    function test_configurationChangesPreserveHistory() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 10)));

        vm.startPrank(admin);
        vault.setManagers(_ascending(3));
        vault.setEmergencyLockers(_ascending(2));
        vault.setLimits(_limits(500, DEFAULT_PERIOD, 25));
        vm.stopPrank();

        assertEq(_used(), 10, "no configuration change may reset the window");
    }

    // -------------------------------------------------------------------
    // Constructor validation
    // -------------------------------------------------------------------

    function test_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CustodialNFTVault(address(0), _managers2(), _lockers1(), _limits(100, 100, 10));
    }

    function test_constructorValidatesLikeSetters() public {
        address[] memory empty = new address[](0);
        vm.expectRevert(ICustodialNFTVault.NoManagers.selector);
        new CustodialNFTVault(admin, empty, _lockers1(), _limits(100, 100, 10));

        vm.expectRevert(ICustodialNFTVault.NoEmergencyLockers.selector);
        new CustodialNFTVault(admin, _managers2(), empty, _limits(100, 100, 10));

        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        new CustodialNFTVault(admin, _managers2(), _lockers1(), _limits(0, 100, 10));

        vm.expectRevert(ICustodialNFTVault.TooManyManagers.selector);
        new CustodialNFTVault(admin, _ascending(11), _lockers1(), _limits(100, 100, 10));

        address[] memory desc = new address[](2);
        desc[0] = address(uint160(0x2000));
        desc[1] = address(uint160(0x1000));
        vm.expectRevert(ICustodialNFTVault.RoleAddressesNotSorted.selector);
        new CustodialNFTVault(admin, desc, _lockers1(), _limits(100, 100, 10));
    }

    function test_constructorSetsInitialState() public {
        CustodialNFTVault fresh =
            new CustodialNFTVault(admin, _managers2(), _lockers1(), _limits(42, 3600, 7));
        assertEq(fresh.owner(), admin);
        assertEq(fresh.pendingOwner(), address(0));
        assertFalse(fresh.isLocked());
        assertTrue(fresh.isManager(manager1));
        assertTrue(fresh.isManager(manager2));
        assertTrue(fresh.isEmergencyLocker(locker1));

        ICustodialNFTVault.Limits memory limits = fresh.getLimits();
        assertEq(limits.maxTokens, 42);
        assertEq(limits.periodSeconds, 3600);
        assertEq(limits.maxItemsPerBatch, 7);
    }

    function test_constructorEmitsExactBaselineEvents() public {
        // Monitoring's deployment baseline (docs/MONITORING.md §1): exactly
        // OwnershipTransferred (from Ownable), ManagersChanged,
        // EmergencyLockersChanged, and LimitsChanged — in that order — and
        // in particular NO Paused event, since the vault deploys unpaused.
        address[] memory managers = _managers2();
        address[] memory lockers = _lockers1();
        address[] memory empty = new address[](0);

        vm.recordLogs();
        new CustodialNFTVault(admin, managers, lockers, _limits(42, 3600, 7));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 4, "constructor must emit exactly four events");
        assertEq(logs[0].topics[0], Ownable.OwnershipTransferred.selector);
        assertEq(logs[0].topics[1], bytes32(0));
        assertEq(logs[0].topics[2], bytes32(uint256(uint160(admin))));
        assertEq(logs[1].topics[0], ICustodialNFTVault.ManagersChanged.selector);
        assertEq(logs[1].topics[1], keccak256(abi.encode(empty)));
        assertEq(logs[1].topics[2], keccak256(abi.encode(managers)));
        assertEq(logs[2].topics[0], ICustodialNFTVault.EmergencyLockersChanged.selector);
        assertEq(logs[2].topics[1], keccak256(abi.encode(empty)));
        assertEq(logs[2].topics[2], keccak256(abi.encode(lockers)));
        assertEq(logs[3].topics[0], ICustodialNFTVault.LimitsChanged.selector);
        assertEq(
            logs[3].data,
            abi.encode(ICustodialNFTVault.Limits(0, 0, 0), ICustodialNFTVault.Limits(42, 3600, 7))
        );
    }
}
