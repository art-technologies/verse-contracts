// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {CustodialNFTVault} from "../../src/CustodialNFTVault.sol";
import {CustodialNFTVaultWithPunks} from "../../src/CustodialNFTVaultWithPunks.sol";
import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {MockCryptoPunks} from "../mocks/MockCryptoPunks.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev CryptoPunks withdrawal behavior on the {CustodialNFTVaultWithPunks}
///      extension: the dedicated {withdrawPunks} path reusing the
///      {WithdrawalItem} shape (token = punks contract, tokenId = punk
///      index, amount = 1, standard = the canonical ERC721 placeholder),
///      sharing the manager gate, pause state, batch cap and global window
///      with the inherited {withdraw}.
contract WithdrawPunksTest is VaultTestBase {
    CustodialNFTVaultWithPunks internal punkVault;
    MockCryptoPunks internal punks;

    event PunkWithdrawalExecuted(
        address indexed manager, uint256 itemCount, uint256 usedBefore, uint256 usedAfter
    );
    event AutoLocked(
        address indexed manager,
        uint256 usedInWindow,
        uint256 requested,
        uint256 maxTokens,
        uint256 periodSeconds
    );

    function setUp() public override {
        super.setUp();
        punkVault = CustodialNFTVaultWithPunks(payable(address(vault)));
        punks = new MockCryptoPunks();
        // Seed custody: punk indexes 0..59.
        for (uint256 i; i < 60; ++i) {
            punks.setInitialOwner(address(vault), i);
        }
    }

    /// @dev The whole suite (including the inherited-behavior checks) runs
    ///      against the punks extension vault.
    function _deployVault(
        address owner,
        address[] memory managers,
        address[] memory lockers,
        ICustodialNFTVault.Limits memory limits
    ) internal override returns (CustodialNFTVault) {
        return new CustodialNFTVaultWithPunks(owner, managers, lockers, limits);
    }

    // -------------------------------------------------------------------
    // Item helpers
    // -------------------------------------------------------------------

    function _punkItem(uint256 punkIndex, address to)
        internal
        view
        returns (ICustodialNFTVault.WithdrawalItem memory)
    {
        return ICustodialNFTVault.WithdrawalItem({
            token: address(punks),
            tokenId: punkIndex,
            amount: 1,
            recipient: to,
            standard: ICustodialNFTVault.TokenStandard.ERC721
        });
    }

    /// @dev Batch of `count` punks with indexes [startIndex, startIndex +
    ///      count), already sorted.
    function _punkBatch(uint256 startIndex, uint256 count)
        internal
        view
        returns (ICustodialNFTVault.WithdrawalItem[] memory items)
    {
        items = new ICustodialNFTVault.WithdrawalItem[](count);
        for (uint256 i; i < count; ++i) {
            items[i] = _punkItem(startIndex + i, recipient);
        }
    }

    function _withdrawPunksAs(address caller, ICustodialNFTVault.WithdrawalItem[] memory items)
        internal
        returns (bool executed)
    {
        vm.prank(caller);
        executed = punkVault.withdrawPunks(_toCalldata(items));
    }

    // -------------------------------------------------------------------
    // Happy path
    // -------------------------------------------------------------------

    function test_singlePunkWithdrawal() public {
        assertTrue(_withdrawPunksAs(manager1, _punkBatch(0, 1)));
        assertEq(punks.punkIndexToAddress(0), recipient);
        assertEq(_used(), 1);
    }

    function test_batchPunkWithdrawal() public {
        assertTrue(_withdrawPunksAs(manager1, _punkBatch(0, 3)));
        assertTrue(_withdrawPunksAs(manager2, _punkBatch(3, 2)));
        for (uint256 i; i < 5; ++i) {
            assertEq(punks.punkIndexToAddress(i), recipient);
        }
        assertEq(_used(), 5);
    }

    function test_emitsPunkWithdrawalExecuted() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit PunkWithdrawalExecuted(manager1, 3, 0, 3);
        assertTrue(_withdrawPunksAs(manager1, _punkBatch(0, 3)));
    }

    function test_multiplePunkContractsSortedByAddress() public {
        MockCryptoPunks other = new MockCryptoPunks();
        other.setInitialOwner(address(vault), 7);
        (address low, address high) = address(punks) < address(other)
            ? (address(punks), address(other))
            : (address(other), address(punks));

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _punkItem(low == address(punks) ? 0 : 7, recipient);
        items[0].token = low;
        items[1] = _punkItem(high == address(punks) ? 0 : 7, recipient);
        items[1].token = high;

        assertTrue(_withdrawPunksAs(manager1, items));
        assertEq(punks.punkIndexToAddress(low == address(punks) ? 0 : 0), recipient);
        assertEq(other.punkIndexToAddress(7), recipient);
        assertEq(_used(), 2);
    }

    // -------------------------------------------------------------------
    // Access control and pause
    // -------------------------------------------------------------------

    function test_nonManagerReverts() public {
        vm.expectRevert(ICustodialNFTVault.NotManager.selector);
        vm.prank(outsider);
        punkVault.withdrawPunks(_punkBatch(0, 1));
    }

    function test_ownerIsNotImplicitlyManager() public {
        vm.expectRevert(ICustodialNFTVault.NotManager.selector);
        vm.prank(admin);
        punkVault.withdrawPunks(_punkBatch(0, 1));
    }

    function test_pausedReverts() public {
        vm.prank(locker1);
        vault.lock();
        _expectEnforcedPause();
        vm.prank(manager1);
        punkVault.withdrawPunks(_punkBatch(0, 1));
    }

    // -------------------------------------------------------------------
    // Batch validation
    // -------------------------------------------------------------------

    function test_emptyBatchReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items;
        vm.expectRevert(ICustodialNFTVault.EmptyBatch.selector);
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    function test_oversizedBatchReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _punkBatch(0, 51);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.BatchTooLarge.selector, 51, 50));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    function test_zeroTokenAddressReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _punkBatch(0, 2);
        items[1].token = address(0);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ZeroTokenAddress.selector, 1));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    function test_zeroRecipientReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _punkBatch(0, 2);
        items[1].recipient = address(0);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ZeroRecipientAddress.selector, 1));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    function test_amountNotOneReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _punkBatch(0, 1);
        items[0].amount = 2;
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.InvalidAmount.selector, 0));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);

        items[0].amount = 0;
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.InvalidAmount.selector, 0));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    function test_nonCanonicalStandardReverts() public {
        ICustodialNFTVault.WithdrawalItem[] memory items = _punkBatch(0, 2);
        items[1].standard = ICustodialNFTVault.TokenStandard.ERC1155;
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.InvalidTokenStandard.selector, 1));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    function test_unsortedPunkIndexesRevert() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _punkItem(5, recipient);
        items[1] = _punkItem(4, recipient);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ItemsNotSorted.selector, 1));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    function test_duplicatePunkIndexReverts() public {
        // Strictly ascending order forbids duplicates outright.
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _punkItem(5, recipient);
        items[1] = _punkItem(5, recipient);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ItemsNotSorted.selector, 1));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    function test_unsortedTokenAddressesRevert() public {
        MockCryptoPunks other = new MockCryptoPunks();
        (address low, address high) = address(punks) < address(other)
            ? (address(punks), address(other))
            : (address(other), address(punks));

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _punkItem(0, recipient);
        items[0].token = high;
        items[1] = _punkItem(1, recipient);
        items[1].token = low;
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ItemsNotSorted.selector, 1));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);
    }

    // -------------------------------------------------------------------
    // Shared rolling window
    // -------------------------------------------------------------------

    function test_punksShareWindowWithGenericWithdrawals() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 3)));
        assertTrue(_withdrawPunksAs(manager1, _punkBatch(0, 2)));
        assertEq(_used(), 5);
        assertEq(vault.getRemainingLimit(), DEFAULT_MAX_TOKENS - 5);
    }

    function test_overLimitAutoLocksWithoutTransfer() public {
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(5, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS));

        vm.expectEmit(true, false, false, true, address(vault));
        emit AutoLocked(manager1, 0, 6, 5, DEFAULT_PERIOD);
        assertFalse(_withdrawPunksAs(manager1, _punkBatch(0, 6)));

        assertTrue(vault.isLocked());
        assertEq(_used(), 0, "no consumption recorded");
        for (uint256 i; i < 6; ++i) {
            assertEq(punks.punkIndexToAddress(i), address(vault), "no transfer occurred");
        }
    }

    function test_genericUsageAutoLocksPunkPath() public {
        // Exhaust the shared window through the generic path, then request a
        // single punk: the punk path must observe the same budget.
        assertTrue(_withdrawAs(manager1, _batch721(0, 50)));
        assertTrue(_withdrawAs(manager1, _batch721(50, 50)));
        assertEq(_used(), DEFAULT_MAX_TOKENS);

        assertFalse(_withdrawPunksAs(manager1, _punkBatch(0, 1)));
        assertTrue(vault.isLocked());
        assertEq(punks.punkIndexToAddress(0), address(vault));
        assertEq(_used(), DEFAULT_MAX_TOKENS);
    }

    // -------------------------------------------------------------------
    // Rollback on transfer failure
    // -------------------------------------------------------------------

    function test_unownedPunkMidBatchRevertsWholeBatch() public {
        // Punk 40 is owned by the vault, punk 41 is not: the second transfer
        // throws inside the punks contract and rolls back the first transfer
        // together with the window consumption.
        punks.setInitialOwner(outsider, 41);

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](2);
        items[0] = _punkItem(40, recipient);
        items[1] = _punkItem(41, recipient);

        vm.expectRevert(bytes("not punk holder"));
        vm.prank(manager1);
        punkVault.withdrawPunks(items);

        assertEq(punks.punkIndexToAddress(40), address(vault));
        assertEq(punks.punkIndexToAddress(41), outsider);
        assertEq(_used(), 0);
        assertEq(vault.getRemainingLimit(), DEFAULT_MAX_TOKENS, "consumption rolled back");
    }
}
