// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Property tests for batch validation, distinct-token counting, the
///      shared allowance, and window expiry.
contract WithdrawalFuzzTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        multi.mint(address(vault), 0, 1_000_000);
    }

    /// @dev Distinct counting: `distinct` ERC-1155 keys, each repeated
    ///      `1 + dup` times, must consume exactly `distinct` budget units
    ///      regardless of duplicates or amounts.
    function testFuzz_duplicateKeysCountOnce(uint256 distinct, uint256 dup, uint256 amountSeed)
        public
    {
        distinct = bound(distinct, 1, 16);
        dup = bound(dup, 0, 2);
        uint256 total = distinct * (1 + dup);
        vm.assume(total <= DEFAULT_MAX_ITEMS);

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](total);
        uint256 k;
        for (uint256 id; id < distinct; ++id) {
            for (uint256 r; r <= dup; ++r) {
                uint256 amount = 1 + uint256(keccak256(abi.encode(amountSeed, id, r))) % 5;
                items[k++] = _item1155(id, amount, recipient);
            }
        }

        uint256 usedBefore = _used();
        assertTrue(_withdrawAs(manager1, items));
        assertEq(_used(), usedBefore + distinct, "duplicates and amounts never add budget");
    }

    /// @dev Any adjacent order violation must revert before any state
    ///      change, wherever it occurs in the batch.
    function testFuzz_unsortedBatchAlwaysReverts(uint256 size, uint256 swapAt) public {
        size = bound(size, 2, 20);
        swapAt = bound(swapAt, 1, size - 1);

        ICustodialNFTVault.WithdrawalItem[] memory items = _batch721(0, size);
        // Break ordering at swapAt: give it a smaller tokenId than its
        // predecessor.
        items[swapAt].tokenId = items[swapAt - 1].tokenId;
        items[swapAt - 1].tokenId = items[swapAt].tokenId + 1;

        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ItemsNotSorted.selector, swapAt));
        vm.prank(manager1);
        vault.withdraw(items);
        assertEq(_used(), 0);
    }

    /// @dev The shared allowance: any request is executed iff it fits, and
    ///      otherwise auto-locks with no state mutation beyond the lock.
    function testFuzz_allowanceConsumption(uint16 maxTokens, uint256 first, uint256 second) public {
        maxTokens = uint16(bound(maxTokens, 1, 100));
        first = bound(first, 1, 50);
        second = bound(second, 1, 50);
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(maxTokens, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS));

        vm.prank(manager1);
        bool executedFirst = vault.withdraw(_batch721(0, first));
        if (first > maxTokens) {
            assertFalse(executedFirst);
            assertTrue(vault.isLocked());
            assertEq(_used(), 0);
            return;
        }
        assertTrue(executedFirst);
        assertEq(_used(), first);

        vm.prank(manager2);
        bool executedSecond = vault.withdraw(_batch721(100, second));
        if (first + second > maxTokens) {
            assertFalse(executedSecond, "over-limit must not execute");
            assertTrue(vault.isLocked());
            assertEq(_used(), first, "no budget consumed on auto-lock");
            assertEq(nft.ownerOf(100), address(vault), "no transfer on auto-lock");
        } else {
            assertTrue(executedSecond);
            assertEq(_used(), first + second);
            assertFalse(vault.isLocked());
        }
    }

    /// @dev Expiry: usage drops to zero exactly at `timestamp + period` and
    ///      not one second earlier.
    function testFuzz_windowExpiryBoundary(uint32 period, uint256 elapsed, uint256 count) public {
        period = uint32(bound(period, 1, 2_592_000));
        count = bound(count, 1, 20);
        elapsed = bound(elapsed, 0, uint256(period) * 2);
        // Period changes require the explicit paused epoch reset.
        vm.startPrank(admin);
        vault.lock();
        vault.resetWindowAndSetPeriod(period);
        vault.unlock();
        vm.stopPrank();

        uint256 t0 = block.timestamp;
        assertTrue(_withdrawAs(manager1, _batch721(0, count)));
        vm.warp(t0 + elapsed);

        if (elapsed < period) {
            assertEq(_used(), count, "active strictly inside the window");
        } else {
            assertEq(_used(), 0, "expired at or after the boundary");
        }
    }

    /// @dev Repeated single-token withdrawals never let active usage exceed
    ///      the configured limit, under random time advancement.
    function testFuzz_neverExceedsLimit(uint256 seed) public {
        vm.startPrank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(10, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS));
        vault.lock();
        vault.resetWindowAndSetPeriod(1000);
        vault.unlock();
        vm.stopPrank();

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 1, recipient);

        for (uint256 i; i < 30; ++i) {
            uint256 dt = uint256(keccak256(abi.encode(seed, i))) % 400;
            vm.warp(block.timestamp + dt);
            if (vault.isLocked()) {
                vm.prank(admin);
                vault.unlock();
            }
            vm.prank(manager1);
            vault.withdraw(items);
            assertLe(_used(), 10, "active usage must never exceed maxTokens");
        }
    }
}
