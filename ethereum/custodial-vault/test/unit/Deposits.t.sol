// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Deposit behavior (§22.2): deposits are ordinary token transfers,
///      receiver callbacks are stateless, and the vault emits nothing.
contract DepositsTest is VaultTestBase {
    address internal alice = makeAddr("alice");

    function test_erc721SafeTransferDeposit() public {
        nft.mint(alice, 1000);
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(vault), 1000);
        assertEq(nft.ownerOf(1000), address(vault));
    }

    function test_erc1155SingleSafeTransferDeposit() public {
        multi.mint(alice, 500, 7);
        vm.prank(alice);
        multi.safeTransferFrom(alice, address(vault), 500, 7, "");
        assertEq(multi.balanceOf(address(vault), 500), 7);
    }

    function test_erc1155BatchSafeTransferDeposit() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 501;
        ids[1] = 502;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 3;
        amounts[1] = 4;
        multi.mintBatch(alice, ids, amounts);

        vm.prank(alice);
        multi.safeBatchTransferFrom(alice, address(vault), ids, amounts, "");
        assertEq(multi.balanceOf(address(vault), 501), 3);
        assertEq(multi.balanceOf(address(vault), 502), 4);
    }

    function test_receiverCallbacksWriteNoStorage() public {
        nft.mint(alice, 1000);
        multi.mint(alice, 500, 7);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 500;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 3;

        vm.record();
        vm.startPrank(alice);
        nft.safeTransferFrom(alice, address(vault), 1000);
        multi.safeTransferFrom(alice, address(vault), 500, 2, "");
        multi.safeBatchTransferFrom(alice, address(vault), ids, amounts, "");
        vm.stopPrank();

        (, bytes32[] memory writes) = vm.accesses(address(vault));
        assertEq(writes.length, 0, "receiver callbacks must not write vault storage");
    }

    function test_vaultEmitsNoDepositEvent() public {
        nft.mint(alice, 1000);
        vm.recordLogs();
        vm.prank(alice);
        nft.safeTransferFrom(alice, address(vault), 1000);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].emitter != address(vault), "vault must emit nothing on deposit");
        }
    }

    function test_depositsSucceedWhileLocked() public {
        vm.prank(admin);
        vault.lock();

        nft.mint(alice, 1000);
        multi.mint(alice, 500, 7);
        vm.startPrank(alice);
        nft.safeTransferFrom(alice, address(vault), 1000);
        multi.safeTransferFrom(alice, address(vault), 500, 7, "");
        vm.stopPrank();

        assertEq(nft.ownerOf(1000), address(vault));
        assertEq(multi.balanceOf(address(vault), 500), 7);
    }

    function test_directErc721TransferFromDepositIsHeld() public {
        nft.mint(alice, 1000);
        // transferFrom performs no receiver callback; the asset is still held.
        vm.prank(alice);
        nft.transferFrom(alice, address(vault), 1000);
        assertEq(nft.ownerOf(1000), address(vault));
    }
}
