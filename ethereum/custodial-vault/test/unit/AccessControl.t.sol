// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {ManagerForwarder} from "../mocks/ManagerForwarder.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Full caller matrix (§22.1): owner, pending owner, manager, emergency
///      locker, unrelated EOA, and contract caller for every external
///      function.
contract AccessControlTest is VaultTestBase {
    address internal pendingAddr = makeAddr("pending");

    function setUp() public override {
        super.setUp();
        vm.prank(admin);
        vault.transferOwnership(pendingAddr);
    }

    function _allNonManagers() internal view returns (address[] memory callers) {
        callers = new address[](4);
        callers[0] = admin;
        callers[1] = pendingAddr;
        callers[2] = locker1;
        callers[3] = outsider;
    }

    function _allNonOwners() internal view returns (address[] memory callers) {
        callers = new address[](4);
        callers[0] = pendingAddr;
        callers[1] = manager1;
        callers[2] = locker1;
        callers[3] = outsider;
    }

    // -------------------------------------------------------------------
    // withdraw
    // -------------------------------------------------------------------

    function test_withdraw_managerAllowed() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 1)));
        assertTrue(_withdrawAs(manager2, _batch721(1, 1)));
    }

    function test_withdraw_nonManagersRejected() public {
        address[] memory callers = _allNonManagers();
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(ICustodialNFTVault.NotManager.selector);
            vm.prank(callers[i]);
            vault.withdraw(_batch721(0, 1));
        }
    }

    function test_withdraw_contractCallerRejectedUnlessWhitelisted() public {
        ManagerForwarder forwarder = new ManagerForwarder();
        vm.expectRevert(ICustodialNFTVault.NotManager.selector);
        forwarder.forwardWithdraw(vault, _batch721(0, 1));
    }

    function test_withdraw_ownerCannotWithdrawUnlessAlsoManager() public {
        vm.expectRevert(ICustodialNFTVault.NotManager.selector);
        vm.prank(admin);
        vault.withdraw(_batch721(0, 1));

        // Separately configured as a manager, the same address may withdraw.
        vm.prank(admin);
        vault.setManagers(_single(admin));
        vm.prank(admin);
        assertTrue(vault.withdraw(_batch721(0, 1)));
    }

    // -------------------------------------------------------------------
    // lock / unlock
    // -------------------------------------------------------------------

    function test_lock_ownerAndLockersAllowed() public {
        vm.prank(admin);
        vault.lock();
        assertTrue(vault.isLocked());

        vm.prank(admin);
        vault.unlock();
        vm.prank(locker1);
        vault.lock();
        assertTrue(vault.isLocked());
    }

    function test_lock_othersRejected() public {
        address[] memory callers = new address[](3);
        callers[0] = pendingAddr;
        callers[1] = manager1;
        callers[2] = outsider;
        for (uint256 i; i < callers.length; ++i) {
            vm.expectRevert(ICustodialNFTVault.NotOwnerOrEmergencyLocker.selector);
            vm.prank(callers[i]);
            vault.lock();
        }
    }

    function test_unlock_onlyOwner() public {
        vm.prank(locker1);
        vault.lock();

        address[] memory callers = _allNonOwners();
        for (uint256 i; i < callers.length; ++i) {
            _expectNotOwner(callers[i]);
            vm.prank(callers[i]);
            vault.unlock();
        }

        vm.prank(admin);
        vault.unlock();
        assertFalse(vault.isLocked());
    }

    function test_emergencyLockerCannotDoAnythingElse() public {
        vm.startPrank(locker1);
        vm.expectRevert(ICustodialNFTVault.NotManager.selector);
        vault.withdraw(_batch721(0, 1));
        _expectNotOwner(locker1);
        vault.setManagers(_single(locker1));
        _expectNotOwner(locker1);
        vault.setLimits(ICustodialNFTVault.Limits(1, DEFAULT_PERIOD, 1));
        _expectNotOwner(locker1);
        vault.resetWindowAndSetPeriod(1);
        _expectNotOwner(locker1);
        vault.rescueERC20(address(1), address(1), 1);
        _expectNotOwner(locker1);
        vault.rescueNative(payable(address(1)), 1);
        _expectNotOwner(locker1);
        vault.transferOwnership(locker1);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // Ownership entrypoints (Ownable2Step)
    // -------------------------------------------------------------------

    function test_transferOwnership_onlyOwner() public {
        address[] memory callers = _allNonOwners();
        for (uint256 i; i < callers.length; ++i) {
            _expectNotOwner(callers[i]);
            vm.prank(callers[i]);
            vault.transferOwnership(callers[i]);
        }
    }

    function test_acceptOwnership_onlyExactPendingOwner() public {
        address[] memory callers = new address[](4);
        callers[0] = admin;
        callers[1] = manager1;
        callers[2] = locker1;
        callers[3] = outsider;
        for (uint256 i; i < callers.length; ++i) {
            _expectNotOwner(callers[i]);
            vm.prank(callers[i]);
            vault.acceptOwnership();
        }

        vm.prank(pendingAddr);
        vault.acceptOwnership();
        assertEq(vault.owner(), pendingAddr);
    }

    function test_configuration_onlyOwner() public {
        address[] memory callers = _allNonOwners();
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            _expectNotOwner(callers[i]);
            vault.setManagers(_single(callers[i]));
            _expectNotOwner(callers[i]);
            vault.setEmergencyLockers(_single(callers[i]));
            _expectNotOwner(callers[i]);
            vault.setLimits(ICustodialNFTVault.Limits(1, DEFAULT_PERIOD, 1));
            _expectNotOwner(callers[i]);
            vault.resetWindowAndSetPeriod(1);
            vm.stopPrank();
        }
    }

    function test_rescue_onlyOwner() public {
        address[] memory callers = _allNonOwners();
        for (uint256 i; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            _expectNotOwner(callers[i]);
            vault.rescueERC20(address(1), address(1), 1);
            _expectNotOwner(callers[i]);
            vault.rescueNative(payable(address(1)), 1);
            vm.stopPrank();
        }
    }

    function test_oldOwnerLosesRightsAfterAcceptance() public {
        vm.prank(pendingAddr);
        vault.acceptOwnership();

        vm.startPrank(admin);
        _expectNotOwner(admin);
        vault.unlock();
        _expectNotOwner(admin);
        vault.transferOwnership(admin);
        // The old owner also cannot lock unless it is an emergency locker.
        vm.expectRevert(ICustodialNFTVault.NotOwnerOrEmergencyLocker.selector);
        vault.lock();
        vm.stopPrank();
    }
}
