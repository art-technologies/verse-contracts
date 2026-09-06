// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {ManagerForwarder} from "../mocks/ManagerForwarder.sol";
import {OuterRevertingManager} from "../mocks/OuterRevertingManager.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Sliding-window accounting (§22.4) on OpenZeppelin
///      RateLimiter.SlidingWindow: shared allowance, auto-lock, expiry
///      boundary, same-timestamp coalescing, limit changes, and the
///      paused-only epoch reset.
contract RollingWindowTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        // Deep ERC-1155 balance for high-volume drip tests.
        multi.mint(address(vault), 0, 1_000_000);
    }

    /// @dev One single-item withdrawal (1 distinct token) per iteration.
    function _drip(uint256 n) internal {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 1, recipient);
        for (uint256 i; i < n; ++i) {
            vm.prank(manager1);
            assertTrue(vault.withdraw(items));
        }
    }

    // -------------------------------------------------------------------
    // Basic consumption
    // -------------------------------------------------------------------

    function test_firstWithdrawal() public {
        assertEq(_used(), 0);
        assertTrue(_withdrawAs(manager1, _batch721(0, 3)));
        assertEq(_used(), 3);
        assertEq(vault.getRemainingLimit(), DEFAULT_MAX_TOKENS - 3);
    }

    function test_multipleManagersShareOneAllowance() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 50)));
        assertTrue(_withdrawAs(manager2, _batch721(50, 50)));
        assertEq(_used(), 100);
        assertEq(vault.getRemainingLimit(), 0);

        // Either manager is now over-limit for even one token.
        assertFalse(_withdrawAs(manager2, _batch721(100, 1)));
        assertTrue(vault.isLocked());
    }

    function test_exactFillSucceeds() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 50)));
        assertTrue(_withdrawAs(manager1, _batch721(50, 50)));
        assertEq(_used(), DEFAULT_MAX_TOKENS);
        assertFalse(vault.isLocked());
    }

    // -------------------------------------------------------------------
    // Auto-lock
    // -------------------------------------------------------------------

    function test_oneOverLimitAutoLocksWithoutReverting() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 50)));
        assertTrue(_withdrawAs(manager1, _batch721(50, 50)));

        vm.recordLogs();
        vm.prank(manager1);
        bool executed = vault.withdraw(_batch721(100, 1));

        assertFalse(executed, "over-limit withdraw must return false");
        assertTrue(vault.isLocked(), "vault must auto-lock");
        assertEq(nft.ownerOf(100), address(vault), "no transfer may occur");
        assertEq(_used(), DEFAULT_MAX_TOKENS, "no consumption recorded");

        // No token contract was called: only the vault's Paused + AutoLocked.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertEq(logs[i].emitter, address(vault), "auto-lock makes no external calls");
        }

        // Subsequent withdrawals now revert with EnforcedPause.
        _expectEnforcedPause();
        vm.prank(manager1);
        vault.withdraw(_batch721(100, 1));
    }

    function test_autoLockEventFields() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 40)));
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(80, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS));

        vm.expectEmit(true, false, false, true, address(vault));
        emit ICustodialNFTVault.AutoLocked(manager2, 40, 50, 80, DEFAULT_PERIOD);
        assertFalse(_withdrawAs(manager2, _batch721(40, 50)));
    }

    // -------------------------------------------------------------------
    // Expiry boundary and coalescing
    // -------------------------------------------------------------------

    function test_windowExpiryAtExactBoundary() public {
        uint256 t0 = block.timestamp;
        assertTrue(_withdrawAs(manager1, _batch721(0, 5)));

        vm.warp(t0 + DEFAULT_PERIOD - 1);
        assertEq(_used(), 5, "still active one second before the boundary");

        vm.warp(t0 + DEFAULT_PERIOD);
        assertEq(_used(), 0, "expires exactly when the full period has elapsed");
        assertEq(vault.getRemainingLimit(), DEFAULT_MAX_TOKENS);
    }

    function test_sameTimestampWithdrawalsCoalesceWithoutLosingUsage() public {
        // Multiple consumptions in one block coalesce into one checkpoint
        // inside the limiter; `used` must still be exact.
        _drip(3);
        assertEq(_used(), 3);

        vm.warp(block.timestamp + DEFAULT_PERIOD - 1);
        assertEq(_used(), 3);
        vm.warp(block.timestamp + 1);
        assertEq(_used(), 0, "identically timestamped consumptions expire together");
    }

    function test_partialExpiry() public {
        uint256 t0 = block.timestamp;
        assertTrue(_withdrawAs(manager1, _batch721(0, 4)));
        vm.warp(t0 + 1000);
        assertTrue(_withdrawAs(manager1, _batch721(4, 6)));

        // First consumption expired, second still active.
        vm.warp(t0 + DEFAULT_PERIOD);
        assertEq(_used(), 6);

        // A state-changing withdrawal after partial expiry sees the same.
        assertTrue(_withdrawAs(manager1, _batch721(10, 1)));
        assertEq(_used(), 7);
    }

    function test_fullExpiryAndHistoryTruncation() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 4)));
        assertTrue(_withdrawAs(manager1, _batch721(4, 6)));
        vm.warp(block.timestamp + DEFAULT_PERIOD + 1);
        assertEq(_used(), 0);

        // First consumption after a full-window idle truncates history and
        // starts fresh.
        assertTrue(_withdrawAs(manager1, _batch721(10, 50)));
        assertEq(_used(), 50);
    }

    // -------------------------------------------------------------------
    // Limit changes (§8.5 adapted: period is immutable via setLimits)
    // -------------------------------------------------------------------

    function test_loweringMaxTokensBelowUsageAutoLocksNextWithdrawal() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 10)));
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(5, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS));

        assertEq(_used(), 10, "history preserved above the new limit");
        assertEq(vault.getRemainingLimit(), 0, "remaining clamps at zero");
        assertFalse(vault.isLocked(), "setLimits itself does not lock");

        assertFalse(_withdrawAs(manager1, _batch721(10, 1)));
        assertTrue(vault.isLocked());
    }

    function test_raisingMaxTokensFreesAllowanceWithoutTouchingHistory() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 50)));
        assertTrue(_withdrawAs(manager1, _batch721(50, 50)));
        assertEq(vault.getRemainingLimit(), 0);

        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(150, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS));
        assertEq(_used(), 100);
        assertEq(vault.getRemainingLimit(), 50);
        assertTrue(_withdrawAs(manager1, _batch721(100, 50)));
    }

    function test_setLimitsCannotChangePeriod() public {
        vm.expectRevert(ICustodialNFTVault.PeriodIsImmutable.selector);
        vm.prank(admin);
        vault.setLimits(
            ICustodialNFTVault.Limits(DEFAULT_MAX_TOKENS, DEFAULT_PERIOD + 1, DEFAULT_MAX_ITEMS)
        );
    }

    function test_changingMaxItemsPerBatchDoesNotAffectHistory() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 10)));
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(DEFAULT_MAX_TOKENS, DEFAULT_PERIOD, 5));
        assertEq(_used(), 10);
    }

    // -------------------------------------------------------------------
    // Epoch reset (paused-only period change)
    // -------------------------------------------------------------------

    function test_epochResetRequiresPause() public {
        _expectExpectedPause();
        vm.prank(admin);
        vault.resetWindowAndSetPeriod(3600);
    }

    function test_epochResetErasesHistoryAppliesPeriodAndStaysPaused() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 10)));
        vm.prank(locker1);
        vault.lock();

        vm.expectEmit(false, false, false, true, address(vault));
        emit ICustodialNFTVault.WindowEpochReset(DEFAULT_PERIOD, 3600);
        vm.prank(admin);
        vault.resetWindowAndSetPeriod(3600);

        assertTrue(vault.isLocked(), "vault stays paused after the epoch reset");
        assertEq(_used(), 0, "history was explicitly erased");
        ICustodialNFTVault.Limits memory limits = vault.getLimits();
        assertEq(limits.periodSeconds, 3600);

        // Fresh epoch works under the new period after unlock.
        vm.prank(admin);
        vault.unlock();
        uint256 t0 = block.timestamp;
        assertTrue(_withdrawAs(manager1, _batch721(50, 5)));
        vm.warp(t0 + 3600 - 1);
        assertEq(_used(), 5);
        vm.warp(t0 + 3600);
        assertEq(_used(), 0);
    }

    function test_epochResetValidatesPeriodBounds() public {
        vm.prank(locker1);
        vault.lock();
        vm.startPrank(admin);
        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        vault.resetWindowAndSetPeriod(0);
        vm.expectRevert(ICustodialNFTVault.InvalidLimits.selector);
        vault.resetWindowAndSetPeriod(2_592_001);
        vault.resetWindowAndSetPeriod(2_592_000);
        vault.resetWindowAndSetPeriod(1);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // Lock interactions with history
    // -------------------------------------------------------------------

    function test_unlockPreservesActiveHistory() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 7)));
        vm.prank(locker1);
        vault.lock();
        vm.prank(admin);
        vault.unlock();
        assertEq(_used(), 7, "unlock must not erase active history");
    }

    function test_repeatedManualLockDoesNotAlterHistory() public {
        assertTrue(_withdrawAs(manager1, _batch721(0, 7)));
        vm.prank(locker1);
        vault.lock();
        vm.prank(locker1);
        vault.lock();
        vm.prank(admin);
        vault.lock();
        vm.prank(admin);
        vault.unlock();
        assertEq(_used(), 7);
    }

    // -------------------------------------------------------------------
    // Views match state-changing calculations
    // -------------------------------------------------------------------

    function test_viewsMatchStateChangingCalculations() public {
        uint256 t0 = block.timestamp;
        assertTrue(_withdrawAs(manager1, _batch721(0, 4)));
        vm.warp(t0 + 1000);
        assertTrue(_withdrawAs(manager1, _batch721(4, 6)));
        vm.warp(t0 + DEFAULT_PERIOD + 500);

        // Virtual (view) result.
        uint256 viewUsed = vault.getRecentWithdrawn();

        // State-changing result: perform a withdrawal and check the emitted
        // usedBefore matches the view.
        vm.expectEmit(true, false, false, true, address(vault));
        emit ICustodialNFTVault.WithdrawalExecuted(manager1, 1, 1, viewUsed, viewUsed + 1);
        assertTrue(_withdrawAs(manager1, _batch721(20, 1)));
    }

    // -------------------------------------------------------------------
    // Long-running histories (dynamic-checkpoint storage behavior)
    // -------------------------------------------------------------------

    function test_manyUniqueTimestampCheckpointsStayExact() public {
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(2000, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS));

        // 500 consumptions at unique timestamps inside one window.
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 1, recipient);
        for (uint256 i; i < 500; ++i) {
            vm.warp(block.timestamp + 1);
            vm.prank(manager1);
            assertTrue(vault.withdraw(items));
        }
        assertEq(_used(), 500);

        // Advance until the first 100 expire (window still spans the rest).
        vm.warp(block.timestamp + DEFAULT_PERIOD - 400);
        assertEq(_used(), 400);
    }

    // -------------------------------------------------------------------
    // Contract managers (§22.6)
    // -------------------------------------------------------------------

    function test_managerForwarderHandlesFalseCorrectly() public {
        ManagerForwarder forwarder = new ManagerForwarder();
        vm.prank(admin);
        vault.setManagers(_single(address(forwarder)));

        // Fill the allowance, then trigger an over-limit request through the
        // forwarder: it must observe `false` without reverting.
        assertTrue(forwarder.forwardWithdraw(vault, _batch721(0, 50)));
        assertTrue(forwarder.forwardWithdraw(vault, _batch721(50, 50)));
        bool executed = forwarder.forwardWithdraw(vault, _batch721(100, 1));
        assertFalse(executed);
        assertTrue(vault.isLocked(), "auto-lock persists for a non-reverting forwarder");
    }

    function test_outerRevertingManagerRollsBackAutoLock() public {
        // Documented EVM limitation (§2.3): a contract manager that reverts
        // its own outer frame also rolls back the vault's auto-lock. This is
        // why production managers must be direct EOAs.
        OuterRevertingManager evil = new OuterRevertingManager();
        address[] memory managers = new address[](2);
        (managers[0], managers[1]) =
            manager1 < address(evil) ? (manager1, address(evil)) : (address(evil), manager1);
        vm.prank(admin);
        vault.setManagers(managers);

        assertTrue(_withdrawAs(manager1, _batch721(0, 50)));
        assertTrue(_withdrawAs(manager1, _batch721(50, 50)));

        vm.expectRevert(OuterRevertingManager.OuterRevert.selector);
        evil.withdrawThenRevert(vault, _batch721(100, 1));

        assertFalse(vault.isLocked(), "outer revert rolled the auto-lock back");
    }
}
