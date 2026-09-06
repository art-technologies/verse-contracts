// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CustodialNFTVault} from "../../src/CustodialNFTVault.sol";
import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";

/// @dev Stateful invariants (§23) over the OZ SlidingWindow-backed vault.
///      The handler performs bounded random manager withdrawals, over-limit
///      attempts, lock/unlock cycles, limit changes, epoch resets, manager
///      rotation, and time warps.
contract VaultInvariantsTest is Test {
    CustodialNFTVault internal vault;
    MockERC721 internal nft;
    MockERC1155 internal multi;
    VaultHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal locker = address(uint160(0xE1));

    function setUp() public {
        vm.warp(90 days);

        // Strictly ascending manager pool.
        address[] memory pool = new address[](3);
        pool[0] = address(uint160(0xA1));
        pool[1] = address(uint160(0xA2));
        pool[2] = address(uint160(0xA3));

        address[] memory lockers = new address[](1);
        lockers[0] = locker;

        vault =
            new CustodialNFTVault(owner, pool, lockers, ICustodialNFTVault.Limits(200, 1 days, 50));

        nft = new MockERC721();
        multi = new MockERC1155();
        handler = new VaultHandler(vault, nft, multi, owner, pool, locker);

        for (uint256 i; i < handler.NFT_SUPPLY(); ++i) {
            nft.mint(address(vault), i);
        }
        for (uint256 id; id < handler.MULTI_IDS(); ++id) {
            multi.mint(address(vault), id, handler.MULTI_UNITS());
        }

        targetContract(address(handler));
    }

    /// @dev Window accounting is internally consistent and usage never
    ///      exceeds the immutable hard cap.
    function invariant_windowAccountingConsistent() public view {
        (uint256 used, uint256 remaining, uint256 maxTokens, uint256 periodSeconds, bool locked) =
            vault.getWindowState();
        assertEq(used, vault.getRecentWithdrawn());
        assertEq(remaining, vault.getRemainingLimit());
        if (used >= maxTokens) {
            assertEq(remaining, 0);
        } else {
            assertEq(remaining, maxTokens - used);
        }
        // Usage can exceed a lowered maxTokens but never the immutable cap.
        assertLe(used, 2000);
        assertEq(locked, vault.paused());
        assertEq(periodSeconds, vault.getLimits().periodSeconds);
    }

    /// @dev Assets leave custody only through the two modeled exits — the
    ///      rate-limited manager `withdraw` path and the owner-root
    ///      `execute` path (accepted-risk design) — both fully tracked by
    ///      the handler's ghosts. Nothing else may move custody.
    function invariant_balancesOnlyLeaveThroughModeledExits() public view {
        assertEq(
            nft.balanceOf(address(vault)),
            handler.NFT_SUPPLY() - handler.ghost721Withdrawn() - handler.ghostExecuted721(),
            "ERC-721 custody drifted from ghost accounting"
        );
        assertEq(
            nft.balanceOf(handler.recipient()),
            handler.ghost721Withdrawn(),
            "manager-path recipient drifted"
        );
        assertEq(
            nft.balanceOf(handler.executeRecipient()),
            handler.ghostExecuted721(),
            "owner-execute recipient drifted"
        );
        for (uint256 id; id < handler.MULTI_IDS(); ++id) {
            assertEq(
                multi.balanceOf(address(vault), id),
                handler.MULTI_UNITS() - handler.ghost1155Withdrawn(id),
                "ERC-1155 custody drifted from ghost accounting"
            );
        }
    }

    /// @dev Role sets stay canonical, bounded, and consistent between the
    ///      membership checks and the enumerated arrays.
    function invariant_roleRepresentationsConsistent() public view {
        address[] memory managers = vault.getManagers();
        assertGe(managers.length, 1);
        assertLe(managers.length, 10);
        address prev;
        for (uint256 i; i < managers.length; ++i) {
            assertTrue(vault.isManager(managers[i]));
            assertTrue(managers[i] != address(0));
            if (i > 0) assertTrue(managers[i] > prev, "canonical order violated");
            prev = managers[i];
        }

        address[] memory lockers = vault.getEmergencyLockers();
        assertGe(lockers.length, 1);
        assertLe(lockers.length, 10);
        for (uint256 i; i < lockers.length; ++i) {
            assertTrue(vault.isEmergencyLocker(lockers[i]));
        }
    }

    /// @dev Stored limits always satisfy the immutable hard caps.
    function invariant_limitsWithinHardCaps() public view {
        ICustodialNFTVault.Limits memory limits = vault.getLimits();
        assertGe(limits.maxTokens, 1);
        assertLe(limits.maxTokens, 2000);
        assertGe(limits.periodSeconds, 1);
        assertLe(limits.periodSeconds, 2_592_000);
        assertGe(limits.maxItemsPerBatch, 1);
        assertLe(limits.maxItemsPerBatch, 50);
    }

    /// @dev The owner can never be zero (renunciation is disabled) and the
    ///      ghost counters never revert.
    function invariant_ownerNeverZero() public view {
        assertTrue(vault.owner() != address(0));
        handler.ghostSuccessfulWithdrawals();
        handler.ghostAutoLocks();
        handler.ghostEpochResets();
        handler.ghostExecutes();
    }
}
