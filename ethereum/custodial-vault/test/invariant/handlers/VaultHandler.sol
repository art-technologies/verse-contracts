// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CustodialNFTVault} from "../../../src/CustodialNFTVault.sol";
import {ICustodialNFTVault} from "../../../src/interfaces/ICustodialNFTVault.sol";
import {MockERC1155} from "../../mocks/MockERC1155.sol";
import {MockERC721} from "../../mocks/MockERC721.sol";

/// @dev Stateful fuzz handler. Drives managers, the owner, and emergency
///      lockers with bounded random actions (including the paused epoch
///      reset), asserts the acceptance properties of every action, and
///      maintains ghost accounting for the invariant checks.
contract VaultHandler is Test {
    CustodialNFTVault public vault;
    MockERC721 public nft;
    MockERC1155 public multi;

    address public owner;
    address[] public managerPool;
    address public locker;
    address public recipient = address(0xBEEF);
    address public executeRecipient = address(0xEC);

    uint256 public constant NFT_SUPPLY = 4000;
    uint256 public constant MULTI_IDS = 10;
    uint256 public constant MULTI_UNITS = 1_000_000;

    // Ghost state.
    uint256 public ghost721Withdrawn; // manager-path cursor from the front
    uint256 public ghostExecuted721; // owner-execute cursor from the back
    mapping(uint256 id => uint256 units) public ghost1155Withdrawn;
    uint256 public ghostSuccessfulWithdrawals;
    uint256 public ghostAutoLocks;
    uint256 public ghostEpochResets;
    uint256 public ghostExecutes;

    constructor(
        CustodialNFTVault vault_,
        MockERC721 nft_,
        MockERC1155 multi_,
        address owner_,
        address[] memory managerPool_,
        address locker_
    ) {
        vault = vault_;
        nft = nft_;
        multi = multi_;
        owner = owner_;
        managerPool = managerPool_;
        locker = locker_;
    }

    function _manager(uint256 seed) private view returns (address) {
        address[] memory current = vault.getManagers();
        return current[seed % current.length];
    }

    // -------------------------------------------------------------------
    // Manager actions
    // -------------------------------------------------------------------

    function withdrawSequential721(uint256 seed, uint256 count) external {
        count = bound(count, 1, 5);
        // Manager path consumes ids from the front; owner execute consumes
        // from the back — the cursors must never cross.
        if (ghost721Withdrawn + count > NFT_SUPPLY - ghostExecuted721) return;
        if (vault.isLocked()) return;

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](count);
        for (uint256 i; i < count; ++i) {
            items[i] = ICustodialNFTVault.WithdrawalItem({
                token: address(nft),
                tokenId: ghost721Withdrawn + i,
                amount: 1,
                recipient: recipient,
                standard: ICustodialNFTVault.TokenStandard.ERC721
            });
        }

        uint256 usedBefore = vault.getRecentWithdrawn();
        ICustodialNFTVault.Limits memory limits = vault.getLimits();
        vm.prank(_manager(seed));
        bool executed = vault.withdraw(items);

        if (executed) {
            ghost721Withdrawn += count;
            ghostSuccessfulWithdrawals += 1;
            uint256 usedAfter = vault.getRecentWithdrawn();
            assertLe(usedAfter, limits.maxTokens, "usage above limit after success");
            assertEq(usedAfter, usedBefore + count, "wrong budget consumption");
        } else {
            ghostAutoLocks += 1;
            assertTrue(vault.isLocked(), "false return implies locked");
            assertGt(usedBefore + count, limits.maxTokens, "spurious auto-lock");
            assertEq(vault.getRecentWithdrawn(), usedBefore, "auto-lock must not consume");
        }
    }

    function withdraw1155WithDuplicates(uint256 seed, uint256 id, uint256 dup) external {
        id = bound(id, 0, MULTI_IDS - 1);
        dup = bound(dup, 1, 3);
        if (vault.isLocked()) return;
        if (ghost1155Withdrawn[id] + dup > MULTI_UNITS) return;

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](dup);
        for (uint256 i; i < dup; ++i) {
            items[i] = ICustodialNFTVault.WithdrawalItem({
                token: address(multi),
                tokenId: id,
                amount: 1,
                recipient: recipient,
                standard: ICustodialNFTVault.TokenStandard.ERC1155
            });
        }

        uint256 usedBefore = vault.getRecentWithdrawn();
        vm.prank(_manager(seed));
        bool executed = vault.withdraw(items);

        if (executed) {
            ghost1155Withdrawn[id] += dup;
            ghostSuccessfulWithdrawals += 1;
            assertEq(
                vault.getRecentWithdrawn(),
                usedBefore + 1,
                "duplicate keys in one batch must count once"
            );
        } else {
            ghostAutoLocks += 1;
            assertTrue(vault.isLocked());
        }
    }

    /// @dev Deliberate over-limit attempt whenever the remaining allowance
    ///      makes it possible within one batch.
    function attemptOverLimit(uint256 seed) external {
        if (vault.isLocked()) return;
        uint256 remaining = vault.getRemainingLimit();
        ICustodialNFTVault.Limits memory limits = vault.getLimits();
        if (remaining + 1 > limits.maxItemsPerBatch) return;
        uint256 count = remaining + 1;

        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](count);
        for (uint256 i; i < count; ++i) {
            items[i] = ICustodialNFTVault.WithdrawalItem({
                token: address(multi),
                tokenId: (i * MULTI_IDS) / count, // sorted non-decreasing ids
                amount: 1,
                recipient: recipient,
                standard: ICustodialNFTVault.TokenStandard.ERC1155
            });
        }

        uint256 usedBefore = vault.getRecentWithdrawn();
        uint256 vaultBalance = multi.balanceOf(address(vault), 0);

        vm.prank(_manager(seed));
        bool executed = vault.withdraw(items);

        // Distinct count may be below `count` due to duplicates, so the call
        // may legitimately succeed; when it fails it must be a clean lock.
        if (!executed) {
            ghostAutoLocks += 1;
            assertTrue(vault.isLocked());
            assertEq(vault.getRecentWithdrawn(), usedBefore, "auto-lock consumed budget");
            assertEq(multi.balanceOf(address(vault), 0), vaultBalance, "auto-lock moved a token");
        } else {
            ghostSuccessfulWithdrawals += 1;
            for (uint256 i; i < count; ++i) {
                ghost1155Withdrawn[items[i].tokenId] += 1;
            }
        }
    }

    // -------------------------------------------------------------------
    // Owner / locker actions
    // -------------------------------------------------------------------

    /// @dev Owner-root custody movement via `execute` (accepted-risk design):
    ///      moves one ERC-721 from the BACK of the id range, bypassing the
    ///      rolling window entirely. Asserts the bypass properties: no
    ///      budget consumption and no lock-state change.
    function ownerExecute721(uint256) external {
        if (ghost721Withdrawn + 1 > NFT_SUPPLY - ghostExecuted721) return;
        uint256 tokenId = NFT_SUPPLY - 1 - ghostExecuted721;

        uint256 usedBefore = vault.getRecentWithdrawn();
        bool lockedBefore = vault.isLocked();

        vm.prank(owner);
        vault.execute(
            address(nft),
            0,
            abi.encodeCall(nft.transferFrom, (address(vault), executeRecipient, tokenId))
        );

        ghostExecuted721 += 1;
        ghostExecutes += 1;
        assertEq(
            vault.getRecentWithdrawn(),
            usedBefore,
            "execute must never consume rolling-window budget"
        );
        assertEq(vault.isLocked(), lockedBefore, "execute must not change lock state");
        assertEq(nft.ownerOf(tokenId), executeRecipient, "execute moved the asset");
    }

    function warpTime(uint256 dt) external {
        dt = bound(dt, 1, 3 days);
        vm.warp(block.timestamp + dt);
    }

    function lockAsLocker() external {
        vm.prank(locker);
        vault.lock();
    }

    function unlockAsOwner() external {
        if (!vault.isLocked()) return;
        uint256 usedBefore = vault.getRecentWithdrawn();
        vm.prank(owner);
        vault.unlock();
        assertEq(
            vault.getRecentWithdrawn(), usedBefore, "unlock changed usage without time passing"
        );
    }

    function setRandomLimits(uint16 maxTokens, uint8 maxItems) external {
        maxTokens = uint16(bound(maxTokens, 1, 2000));
        maxItems = uint8(bound(maxItems, 1, 50));
        uint32 period = vault.getLimits().periodSeconds;
        vm.prank(owner);
        vault.setLimits(ICustodialNFTVault.Limits(maxTokens, period, maxItems));
    }

    /// @dev Paused-only period change; leaves the vault paused (a later
    ///      unlockAsOwner action reopens it).
    function epochReset(uint32 newPeriod) external {
        newPeriod = uint32(bound(newPeriod, 1, 2_592_000));
        if (!vault.isLocked()) {
            vm.prank(locker);
            vault.lock();
        }
        vm.prank(owner);
        vault.resetWindowAndSetPeriod(newPeriod);
        ghostEpochResets += 1;
        assertEq(vault.getRecentWithdrawn(), 0, "epoch reset must erase usage");
        assertTrue(vault.isLocked(), "epoch reset never unpauses");
    }

    function rotateManagers(uint256 seed) external {
        uint256 count = 1 + (seed % managerPool.length);
        address[] memory arr = new address[](count);
        for (uint256 i; i < count; ++i) {
            arr[i] = managerPool[i];
        }
        // managerPool is constructed strictly ascending.
        vm.prank(owner);
        vault.setManagers(arr);
    }
}
