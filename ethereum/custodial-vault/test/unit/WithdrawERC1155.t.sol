// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {ReentrantERC1155Receiver} from "../mocks/ReentrantERC1155Receiver.sol";
import {RevertingERC1155} from "../mocks/RevertingERC1155.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev ERC-1155 withdrawal behavior (§22.3) including editions, duplicate
///      keys, mixed batches, rollback, and receiver reentrancy.
contract WithdrawERC1155Test is VaultTestBase {
    function test_singleUnitWithdrawal() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 1, recipient);
        assertTrue(_withdrawAs(manager1, items));
        assertEq(multi.balanceOf(recipient, 0), 1);
        assertEq(_used(), 1);
    }

    function test_editionWithdrawalCountsOnce() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 42, recipient);
        assertTrue(_withdrawAs(manager1, items));
        assertEq(multi.balanceOf(recipient, 0), 42);
        assertEq(_used(), 1, "amount must never enter the rolling budget");
    }

    function test_zeroAmountReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 0, recipient);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.InvalidAmount.selector, 0));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_duplicateKeysAllowedAndCountOnce() public {
        address other = makeAddr("other");
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](3);
        items[0] = _item1155(3, 5, recipient);
        items[1] = _item1155(3, 7, other);
        items[2] = _item1155(4, 1, recipient);

        assertTrue(_withdrawAs(manager1, items));
        assertEq(multi.balanceOf(recipient, 3), 5);
        assertEq(multi.balanceOf(other, 3), 7);
        assertEq(multi.balanceOf(recipient, 4), 1);
        assertEq(_used(), 2, "duplicate ERC-1155 keys count once");
    }

    function test_sameKeyCountsAgainInLaterWithdrawal() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 1, recipient);
        assertTrue(_withdrawAs(manager1, items));
        assertTrue(_withdrawAs(manager1, items));
        assertEq(_used(), 2, "the same pair in later withdrawals counts again");
    }

    function test_mixedBatchWithBothStandards() public {
        // Canonical order across two token contracts depends on their
        // deployed addresses.
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](4);
        if (address(nft) < address(multi)) {
            items[0] = _item721(0, recipient);
            items[1] = _item721(1, recipient);
            items[2] = _item1155(0, 2, recipient);
            items[3] = _item1155(1, 3, recipient);
        } else {
            items[0] = _item1155(0, 2, recipient);
            items[1] = _item1155(1, 3, recipient);
            items[2] = _item721(0, recipient);
            items[3] = _item721(1, recipient);
        }

        assertTrue(_withdrawAs(manager1, items));
        assertEq(nft.ownerOf(0), recipient);
        assertEq(nft.ownerOf(1), recipient);
        assertEq(multi.balanceOf(recipient, 0), 2);
        assertEq(multi.balanceOf(recipient, 1), 3);
        assertEq(_used(), 4);
    }

    function test_mixedBatchPreservesInputOrder() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        bool nftFirst = address(nft) < address(multi);
        if (nftFirst) {
            items[0] = _item721(0, recipient);
            items[1] = _item1155(0, 1, recipient);
        } else {
            items[0] = _item1155(0, 1, recipient);
            items[1] = _item721(0, recipient);
        }

        vm.recordLogs();
        assertTrue(_withdrawAs(manager1, items));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address firstTokenSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(nft) || logs[i].emitter == address(multi)) {
                firstTokenSeen = logs[i].emitter;
                break;
            }
        }
        assertEq(
            firstTokenSeen,
            nftFirst ? address(nft) : address(multi),
            "transfers must run in input order"
        );
    }

    function test_erc1155DeclaredAsErc721Reverts() public {
        // An ERC-1155 asset declared as ERC-721 with amount != 1 must fail
        // validation.
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 2, recipient);
        items[0].standard = ICustodialNFTVault.TokenStandard.ERC721;
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.InvalidAmount.selector, 0));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_tokenFailureRollsBackEarlierTransfers() public {
        RevertingERC1155 bad = new RevertingERC1155();
        bad.mint(address(vault), 0, 10);
        bad.mint(address(vault), 1, 10);
        bad.setTransfersBeforeRevert(1);

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _item1155(0, 5, recipient);
        items[0].token = address(bad);
        items[1] = _item1155(1, 5, recipient);
        items[1].token = address(bad);

        vm.expectRevert(bytes("RevertingERC1155: transfer disabled"));
        vm.prank(manager1);
        vault.withdraw(items);

        assertEq(bad.balanceOf(address(vault), 0), 10);
        assertEq(bad.balanceOf(address(vault), 1), 10);
        assertEq(_used(), 0);
    }

    function test_recipientCallbackCannotReenterWithdraw() public {
        ReentrantERC1155Receiver attacker = new ReentrantERC1155Receiver();
        address[] memory managers = new address[](2);
        (managers[0], managers[1]) = manager1 < address(attacker)
            ? (manager1, address(attacker))
            : (address(attacker), manager1);
        vm.prank(admin);
        vault.setManagers(managers);

        ICustodialNFTVault.WithdrawalItem[] memory inner =
            new ICustodialNFTVault.WithdrawalItem[](1);
        inner[0] = _item1155(5, 1, address(attacker));
        attacker.arm(address(vault), abi.encodeCall(ICustodialNFTVault.withdraw, (inner)));

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 1, address(attacker));
        vm.prank(manager1);
        assertTrue(vault.withdraw(items));

        assertTrue(attacker.reentryAttempted());
        assertFalse(attacker.reentrySucceeded(), "reentrant withdraw must be blocked");
        assertEq(multi.balanceOf(address(attacker), 5), 0);
        assertEq(_used(), 1);
    }
}
