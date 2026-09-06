// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Event field correctness (§16) and view behavior (§17) for the v2
///      OZ-based ABI.
contract EventsAndViewsTest is VaultTestBase {
    // -------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------

    function test_withdrawalExecutedEventFields() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit ICustodialNFTVault.WithdrawalExecuted(manager1, 3, 3, 0, 3);
        assertTrue(_withdrawAs(manager1, _batch721(0, 3)));

        // Duplicate ERC-1155 keys: itemCount 3, distinct 2.
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](3);
        items[0] = _item1155(0, 1, recipient);
        items[1] = _item1155(0, 2, recipient);
        items[2] = _item1155(1, 1, recipient);
        vm.expectEmit(true, false, false, true, address(vault));
        emit ICustodialNFTVault.WithdrawalExecuted(manager2, 3, 2, 3, 5);
        assertTrue(_withdrawAs(manager2, items));
    }

    function test_managersChangedEmitsCanonicalHashes() public {
        address[] memory oldManagers = vault.getManagers();
        address[] memory newManagers = _single(makeAddr("soloManager"));

        vm.expectEmit(true, true, false, true, address(vault));
        emit ICustodialNFTVault.ManagersChanged(
            keccak256(abi.encode(oldManagers)), keccak256(abi.encode(newManagers))
        );
        vm.prank(admin);
        vault.setManagers(newManagers);
    }

    function test_emergencyLockersChangedEmitsCanonicalHashes() public {
        address[] memory oldLockers = vault.getEmergencyLockers();
        address[] memory newLockers = _single(makeAddr("soloLocker"));

        vm.expectEmit(true, true, false, true, address(vault));
        emit ICustodialNFTVault.EmergencyLockersChanged(
            keccak256(abi.encode(oldLockers)), keccak256(abi.encode(newLockers))
        );
        vm.prank(admin);
        vault.setEmergencyLockers(newLockers);
    }

    function test_limitsChangedEmitsOldAndNewValues() public {
        ICustodialNFTVault.Limits memory oldLimits = vault.getLimits();
        ICustodialNFTVault.Limits memory newLimits = ICustodialNFTVault.Limits(7, DEFAULT_PERIOD, 5);

        vm.expectEmit(false, false, false, true, address(vault));
        emit ICustodialNFTVault.LimitsChanged(oldLimits, newLimits);
        vm.prank(admin);
        vault.setLimits(newLimits);
    }

    function test_ownershipTransferEvents() public {
        address next = makeAddr("nextOwner");

        vm.expectEmit(true, true, false, true, address(vault));
        emit Ownable2Step.OwnershipTransferStarted(admin, next);
        vm.prank(admin);
        vault.transferOwnership(next);

        vm.expectEmit(true, true, false, true, address(vault));
        emit Ownable.OwnershipTransferred(admin, next);
        vm.prank(next);
        vault.acceptOwnership();
    }

    // -------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------

    function test_viewsAtEmptyState() public view {
        assertEq(vault.getRecentWithdrawn(), 0);
        assertEq(vault.getRemainingLimit(), DEFAULT_MAX_TOKENS);
        (uint256 used, uint256 remaining, uint256 maxTokens, uint256 periodSeconds, bool locked) =
            vault.getWindowState();
        assertEq(used, 0);
        assertEq(remaining, DEFAULT_MAX_TOKENS);
        assertEq(maxTokens, DEFAULT_MAX_TOKENS);
        assertEq(periodSeconds, DEFAULT_PERIOD);
        assertFalse(locked);
    }

    function test_getWindowStateFields() public {
        uint256 t0 = block.timestamp;
        assertTrue(_withdrawAs(manager1, _batch721(0, 4)));
        vm.warp(t0 + 100);
        assertTrue(_withdrawAs(manager1, _batch721(4, 6)));

        (uint256 used, uint256 remaining, uint256 maxTokens, uint256 periodSeconds, bool locked) =
            vault.getWindowState();
        assertEq(used, 10);
        assertEq(remaining, DEFAULT_MAX_TOKENS - 10);
        assertEq(maxTokens, DEFAULT_MAX_TOKENS);
        assertEq(periodSeconds, DEFAULT_PERIOD);
        assertFalse(locked);

        // After the first consumption expires, only the second remains; the
        // lock flag tracks pause state.
        vm.warp(t0 + DEFAULT_PERIOD);
        vm.prank(locker1);
        vault.lock();
        (used, remaining,,, locked) = vault.getWindowState();
        assertEq(used, 6);
        assertEq(remaining, DEFAULT_MAX_TOKENS - 6);
        assertTrue(locked);
    }

    function test_viewsAreVirtualWithoutStateChange() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 5)));
        vm.warp(block.timestamp + DEFAULT_PERIOD + 1);

        // Pure view calls: no transaction has touched the limiter since.
        assertEq(vault.getRecentWithdrawn(), 0);
        assertEq(vault.getRemainingLimit(), DEFAULT_MAX_TOKENS);
        (uint256 used,,,,) = vault.getWindowState();
        assertEq(used, 0);
    }

    function test_roleListGettersReturnCanonicalArrays() public view {
        address[] memory managers = vault.getManagers();
        assertEq(managers.length, 2);
        assertTrue(managers[0] < managers[1], "canonical order is strictly ascending");
        assertEq(managers[0], manager1 < manager2 ? manager1 : manager2);

        address[] memory lockers = vault.getEmergencyLockers();
        assertEq(lockers.length, 1);
        assertEq(lockers[0], locker1);
    }

    function test_publicGettersExposeOwnerAndLockState() public {
        assertEq(vault.owner(), admin);
        assertEq(vault.pendingOwner(), address(0));
        assertFalse(vault.isLocked());
        assertFalse(vault.paused());
        assertTrue(vault.isManager(manager1));
        assertFalse(vault.isManager(outsider));
        assertTrue(vault.isEmergencyLocker(locker1));
        assertFalse(vault.isEmergencyLocker(manager1));

        vm.prank(locker1);
        vault.lock();
        assertTrue(vault.isLocked());
        assertTrue(vault.paused());
    }

    function test_erc165InterfaceReporting() public view {
        assertTrue(vault.supportsInterface(0x01ffc9a7), "IERC165");
        assertTrue(vault.supportsInterface(0x150b7a02), "IERC721Receiver");
        assertTrue(vault.supportsInterface(0x4e2312e0), "IERC1155Receiver");
        assertFalse(vault.supportsInterface(0xffffffff));
    }
}
