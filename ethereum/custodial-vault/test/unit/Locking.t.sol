// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {CustodialNFTVault} from "../../src/CustodialNFTVault.sol";
import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Lock behavior (§2.2) on Pausable: lock == pause, unlock == unpause.
contract LockingTest is VaultTestBase {
    function test_vaultStartsUnlockedAtDeployment() public {
        CustodialNFTVault fresh = new CustodialNFTVault(
            admin,
            _managers2(),
            _lockers1(),
            ICustodialNFTVault.Limits(DEFAULT_MAX_TOKENS, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS)
        );
        assertFalse(fresh.isLocked(), "vault must start unlocked");
        assertFalse(fresh.paused());
        assertEq(fresh.getRecentWithdrawn(), 0);
    }

    function test_lockEmitsPausedOnTransition() public {
        vm.expectEmit(false, false, false, true, address(vault));
        emit Pausable.Paused(locker1);
        vm.prank(locker1);
        vault.lock();
        assertTrue(vault.isLocked());
    }

    function test_lockIsIdempotentAndSilentWhenAlreadyLocked() public {
        vm.prank(locker1);
        vault.lock();
        assertTrue(vault.isLocked());

        // Repeated lock: no revert, no event, state unchanged.
        vm.recordLogs();
        vm.prank(admin);
        vault.lock();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "repeated lock is a silent no-op");
        assertTrue(vault.isLocked());
    }

    function test_unlockEmitsUnpaused() public {
        vm.prank(locker1);
        vault.lock();

        vm.expectEmit(false, false, false, true, address(vault));
        emit Pausable.Unpaused(admin);
        vm.prank(admin);
        vault.unlock();
        assertFalse(vault.isLocked());
    }

    function test_unlockRevertsWhenNotLocked() public {
        _expectExpectedPause();
        vm.prank(admin);
        vault.unlock();
    }

    function test_withdrawalsFailWhileLockedBeforeAnyExternalCall() public {
        vm.prank(locker1);
        vault.lock();

        vm.recordLogs();
        _expectEnforcedPause();
        vm.prank(manager1);
        vault.withdraw(_batch721(0, 1));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 0, "no external token call while locked");
        assertEq(nft.ownerOf(0), address(vault));
    }

    function test_rescueOperationsRemainAvailableWhileLocked() public {
        vm.prank(locker1);
        vault.lock();

        MockERC20 erc20 = new MockERC20();
        erc20.mint(address(vault), 100);
        vm.prank(admin);
        vault.rescueERC20(address(erc20), recipient, 100);
        assertEq(erc20.balanceOf(recipient), 100);

        vm.deal(address(vault), 1 ether);
        vm.prank(admin);
        vault.rescueNative(payable(recipient), 1 ether);
        assertEq(recipient.balance, 1 ether);
    }

    function test_unlockAfterAutoLockRestoresWithdrawals() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 50)));
        assertTrue(_withdrawAs(manager1, _batch721(50, 50)));
        assertFalse(_withdrawAs(manager1, _batch721(100, 1)));
        assertTrue(vault.isLocked());

        vm.prank(admin);
        vault.unlock();
        assertEq(_used(), DEFAULT_MAX_TOKENS, "unlock preserves the consumed window");

        // Still over-limit: the next attempt auto-locks again.
        assertFalse(_withdrawAs(manager1, _batch721(100, 1)));
        assertTrue(vault.isLocked());

        // After the window expires, withdrawals work again.
        vm.prank(admin);
        vault.unlock();
        vm.warp(block.timestamp + DEFAULT_PERIOD);
        assertTrue(_withdrawAs(manager1, _batch721(100, 1)));
    }

    function test_unlockDoesNotChangeActiveUsage() public {
        uint256 t0 = block.timestamp;
        assertTrue(_withdrawAs(manager1, _batch721(0, 3)));
        vm.warp(t0 + 1000);
        assertTrue(_withdrawAs(manager1, _batch721(3, 4)));

        vm.prank(locker1);
        vault.lock();
        vm.warp(t0 + DEFAULT_PERIOD + 500);

        uint256 usedBefore = vault.getRecentWithdrawn();
        vm.prank(admin);
        vault.unlock();

        assertEq(_used(), usedBefore, "unlock never alters usage");
        assertEq(_used(), 4, "only the expired consumption dropped out");
    }
}
