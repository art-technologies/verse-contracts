// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {MaliciousToken} from "../mocks/MaliciousToken.sol";
import {ReentrantERC721Receiver} from "../mocks/ReentrantERC721Receiver.sol";
import {RevertingERC721} from "../mocks/RevertingERC721.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev ERC-721 withdrawal behavior (§22.3) plus batch validation and
///      rollback/reentrancy cases (§22.6).
contract WithdrawERC721Test is VaultTestBase {
    function test_singleWithdrawal() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 1)));
        assertEq(nft.ownerOf(0), recipient);
        assertEq(_used(), 1);
    }

    function test_multipleWithdrawals() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 3)));
        assertTrue(_withdrawAs(manager1, _batch721(3, 2)));
        for (uint256 i; i < 5; ++i) {
            assertEq(nft.ownerOf(i), recipient);
        }
        assertEq(_used(), 5);
    }

    function test_transfersPreserveInputOrder() public {
        vm.recordLogs();
        assertTrue(_withdrawAs(manager1, _batch721(10, 3)));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 seen;
        bytes32 transferSig = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(nft) && logs[i].topics[0] == transferSig) {
                assertEq(uint256(logs[i].topics[3]), 10 + seen, "transfer order mismatch");
                ++seen;
            }
        }
        assertEq(seen, 3);
    }

    // -------------------------------------------------------------------
    // Batch validation
    // -------------------------------------------------------------------

    function test_emptyBatchReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items;
        vm.expectRevert(ICustodialNFTVault.EmptyBatch.selector);
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_oversizedBatchReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _batch721(0, 51);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.BatchTooLarge.selector, 51, 50));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_batchOverConfiguredMaxReverts() public {
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(DEFAULT_MAX_TOKENS, DEFAULT_PERIOD, 2));
        ICustodialNFTVault.WithdrawalItem[] memory items = _batch721(0, 3);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.BatchTooLarge.selector, 3, 2));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_zeroTokenAddressReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _batch721(0, 2);
        items[1].token = address(0);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ZeroTokenAddress.selector, 1));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_zeroRecipientReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _batch721(0, 2);
        items[1].recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ZeroRecipientAddress.selector, 1));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_erc721AmountNotOneReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _batch721(0, 1);
        items[0].amount = 2;
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.InvalidAmount.selector, 0));
        vm.prank(manager1);
        vault.withdraw(items);

        items[0].amount = 0;
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.InvalidAmount.selector, 0));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_unsortedTokenIdsRevert() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _item721(5, recipient);
        items[1] = _item721(4, recipient);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ItemsNotSorted.selector, 1));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_unsortedTokenAddressesRevert() public {
        MaliciousToken other = new MaliciousToken();
        (address lowToken, address highToken) = address(nft) < address(other)
            ? (address(nft), address(other))
            : (address(other), address(nft));

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _item721(0, recipient);
        items[0].token = highToken;
        items[1] = _item721(1, recipient);
        items[1].token = lowToken;
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ItemsNotSorted.selector, 1));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_duplicateErc721Reverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _item721(5, recipient);
        items[1] = _item721(5, recipient);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.DuplicateERC721.selector, 1));
        vm.prank(manager1);
        vault.withdraw(items);
    }

    function test_invalidEnumValueRejectedByAbiDecoder() public {
        // The TokenStandard enum has two members (0, 1). A raw calldata
        // value of 2 is rejected by solc 0.8.30's calldata validator with a
        // data-less revert before the function body runs; the
        // InvalidTokenStandard error is therefore unreachable through
        // external calls and reserved for interface completeness.
        bytes memory callData = abi.encodeCall(ICustodialNFTVault.withdraw, (_batch721(0, 1)));
        // Layout: selector(4) + array offset(32) + length(32) + item fields
        // (token, tokenId, amount, recipient, standard) of 32 bytes each.
        // The standard word ends at byte 4 + 32*7 - 1 = 227.
        callData[227] = 0x02;

        vm.prank(manager1);
        (bool ok, bytes memory ret) = address(vault).call(callData);
        assertFalse(ok, "malformed enum calldata must revert");
        assertEq(ret.length, 0, "calldata validation reverts without data");
        assertEq(_used(), 0, "no state change");
        assertEq(nft.ownerOf(0), address(vault));
    }

    function test_standardMismatchOnRepeatedKeyReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _item721(5, recipient);
        items[1] = _item721(5, recipient);
        items[1].standard = ICustodialNFTVault.TokenStandard.ERC1155;
        vm.expectRevert(
            abi.encodeWithSelector(ICustodialNFTVault.TokenStandardMismatch.selector, 1)
        );
        vm.prank(manager1);
        vault.withdraw(items);
    }

    // -------------------------------------------------------------------
    // Rollback on token failure
    // -------------------------------------------------------------------

    function test_tokenFailureRevertsEarlierTransfersAndCheckpoint() public {
        RevertingERC721 bad = new RevertingERC721();
        bad.mint(address(vault), 0);
        bad.mint(address(vault), 1);
        // The first transfer succeeds, the second reverts: the first must be
        // rolled back along with the checkpoint write.
        bad.setTransfersBeforeRevert(1);

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _item721(0, recipient);
        items[0].token = address(bad);
        items[1] = _item721(1, recipient);
        items[1].token = address(bad);

        uint256 usedBefore = _used();
        vm.expectRevert(bytes("RevertingERC721: transfer disabled"));
        vm.prank(manager1);
        vault.withdraw(items);

        // Whole path rolled back: ownership and window state unchanged.
        assertEq(bad.ownerOf(0), address(vault));
        assertEq(bad.ownerOf(1), address(vault));
        assertEq(_used(), usedBefore);
        assertEq(vault.getRemainingLimit(), DEFAULT_MAX_TOKENS, "consumption rolled back");
    }

    function test_maliciousTokenMidBatchRevertRollsBackWindowState() public {
        // MaliciousToken lies about interface support and reverts after its
        // first accepted transfer call.
        MaliciousToken malicious = new MaliciousToken();
        malicious.setTransfersUntilRevert(1);
        assertTrue(malicious.supportsInterface(0xffffffff), "mock must lie about interfaces");

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _item721(0, recipient);
        items[0].token = address(malicious);
        items[1] = _item721(1, recipient);
        items[1].token = address(malicious);

        vm.expectRevert(bytes("MaliciousToken: mid-batch revert"));
        vm.prank(manager1);
        vault.withdraw(items);

        assertEq(_used(), 0);
        assertEq(vault.getRemainingLimit(), DEFAULT_MAX_TOKENS, "consumption rolled back");
    }

    // -------------------------------------------------------------------
    // Reentrancy through the recipient callback
    // -------------------------------------------------------------------

    function test_recipientCallbackCannotReenterWithdraw() public {
        ReentrantERC721Receiver attacker = new ReentrantERC721Receiver();
        // Whitelist the attacker as a manager so only the reentrancy guard
        // stands between it and a nested withdrawal.
        address[] memory managers = new address[](2);
        (managers[0], managers[1]) = manager1 < address(attacker)
            ? (manager1, address(attacker))
            : (address(attacker), manager1);
        vm.prank(admin);
        vault.setManagers(managers);

        ICustodialNFTVault.WithdrawalItem[] memory inner = _batch721(5, 1);
        attacker.arm(address(vault), abi.encodeCall(ICustodialNFTVault.withdraw, (inner)));

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item721(0, address(attacker));
        vm.prank(manager1);
        assertTrue(vault.withdraw(items));

        assertTrue(attacker.reentryAttempted());
        assertFalse(attacker.reentrySucceeded(), "reentrant withdraw must be blocked");
        assertEq(nft.ownerOf(5), address(vault));
        assertEq(_used(), 1);
    }

    function test_recipientCallbackCannotReenterOtherFunctions() public {
        ReentrantERC721Receiver attacker = new ReentrantERC721Receiver();

        bytes[] memory attempts = new bytes[](4);
        attempts[0] = abi.encodeCall(ICustodialNFTVault.unlock, ());
        attempts[1] = abi.encodeCall(ICustodialNFTVault.setManagers, (_single(address(attacker))));
        attempts[2] =
            abi.encodeCall(ICustodialNFTVault.rescueNative, (payable(address(attacker)), 0));
        attempts[3] = abi.encodeCall(ICustodialNFTVault.lock, ());

        for (uint256 i; i < attempts.length; ++i) {
            attacker.arm(address(vault), attempts[i]);
            ICustodialNFTVault.WithdrawalItem[] memory items =
                new ICustodialNFTVault.WithdrawalItem[](1);
            items[0] = _item721(20 + i, address(attacker));
            vm.prank(manager1);
            assertTrue(vault.withdraw(items));
            assertTrue(attacker.reentryAttempted());
            assertFalse(attacker.reentrySucceeded(), "reentry must be rejected");
        }
        assertFalse(vault.isLocked());
    }
}
