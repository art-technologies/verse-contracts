// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Gas benchmarks (§24) for the SlidingWindow-backed vault. Gas
///      metering is paused during in-test state preparation and resumed for
///      the single measured vault call. The checkpoint-history series (1 /
///      100 / 2,000 / 10,000 unique-timestamp entries) specifically tracks
///      the dynamic-history storage trade-off adopted with
///      RateLimiter.SlidingWindow. `forge snapshot --match-path
///      "test/gas/*"` records these tests; `.gas-snapshot` is CI-checked.
contract VaultGasTest is VaultTestBase {
    function setUp() public override {
        super.setUp();
        multi.mint(address(vault), 0, 1_000_000);
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(2000, DEFAULT_PERIOD, 50));
    }

    /// @dev One single-item consumption per iteration, each at a fresh
    ///      timestamp so every consumption creates a new checkpoint.
    function _dripUniqueTimestamps(uint256 n, uint256 stepSeconds) internal {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = _item1155(0, 1, recipient);
        for (uint256 i; i < n; ++i) {
            vm.warp(block.timestamp + stepSeconds);
            vm.prank(manager1);
            vault.withdraw(items);
        }
    }

    /// @dev Grows the limiter's checkpoint array to ~10,000 entries: drip
    ///      every second with a 1,000-second window so usage never reaches
    ///      zero (no truncation) while old entries keep expiring.
    function _grow10kHistory() internal {
        vm.startPrank(admin);
        vault.lock();
        vault.resetWindowAndSetPeriod(1000);
        vault.unlock();
        vm.stopPrank();
        _dripUniqueTimestamps(10_000, 1);
    }

    // -------------------------------------------------------------------
    // Withdrawals at increasing history depth
    // -------------------------------------------------------------------

    function test_gas_firstWithdrawal_1item() public {
        vm.prank(manager1);
        vault.withdraw(_batch721(0, 1));
    }

    function test_gas_withdrawal_10items() public {
        vm.prank(manager1);
        vault.withdraw(_batch721(0, 10));
    }

    function test_gas_withdrawal_50items() public {
        vm.prank(manager1);
        vault.withdraw(_batch721(0, 50));
    }

    function test_gas_withdrawalAt100CheckpointHistory() public {
        vm.pauseGasMetering();
        _dripUniqueTimestamps(100, 1);
        vm.resumeGasMetering();

        vm.prank(manager1);
        vault.withdraw(_batch721(0, 10));
    }

    function test_gas_withdrawalAt2000CheckpointHistory() public {
        vm.pauseGasMetering();
        // 2,000 - 100 further entries would exceed maxTokens; expire between
        // batches (usage stays > 0 so history keeps growing).
        vm.startPrank(admin);
        vault.lock();
        vault.resetWindowAndSetPeriod(1000);
        vault.unlock();
        vm.stopPrank();
        _dripUniqueTimestamps(2000, 1);
        vm.resumeGasMetering();

        vm.prank(manager1);
        vault.withdraw(_batch721(0, 10));
    }

    function test_gas_withdrawalAt10000CheckpointHistory() public {
        vm.pauseGasMetering();
        _grow10kHistory();
        vm.resumeGasMetering();

        vm.prank(manager1);
        vault.withdraw(_batch721(0, 10));
    }

    function test_gas_withdrawalAfterFullIdleTruncation() public {
        vm.pauseGasMetering();
        _dripUniqueTimestamps(500, 1);
        vm.warp(block.timestamp + DEFAULT_PERIOD + 1); // full-window idle
        vm.resumeGasMetering();

        // First consumption after idle truncates and reuses dirty slots.
        vm.prank(manager1);
        vault.withdraw(_batch721(0, 1));
    }

    // -------------------------------------------------------------------
    // Locking
    // -------------------------------------------------------------------

    function test_gas_overLimitAutoLock() public {
        vm.pauseGasMetering();
        vm.prank(admin);
        vault.setLimits(ICustodialNFTVault.Limits(10, DEFAULT_PERIOD, 50));
        _dripUniqueTimestamps(10, 1);
        vm.resumeGasMetering();

        vm.prank(manager1);
        vault.withdraw(_batch721(0, 1)); // auto-locks
    }

    function test_gas_manualLock() public {
        vm.prank(locker1);
        vault.lock();
    }

    function test_gas_unlock() public {
        vm.pauseGasMetering();
        _dripUniqueTimestamps(5, 1);
        vm.prank(admin);
        vault.lock();
        vm.resumeGasMetering();

        vm.prank(admin);
        vault.unlock();
    }

    function test_gas_epochReset() public {
        vm.pauseGasMetering();
        _dripUniqueTimestamps(100, 1);
        vm.prank(admin);
        vault.lock();
        vm.resumeGasMetering();

        vm.prank(admin);
        vault.resetWindowAndSetPeriod(3600);
    }

    // -------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------

    function test_gas_setManagers_10addresses() public {
        vm.pauseGasMetering();
        address[] memory ten = new address[](10);
        for (uint256 i; i < 10; ++i) {
            // Test-only synthetic addresses; the cast cannot truncate.
            // forge-lint: disable-next-line(unsafe-typecast)
            ten[i] = address(uint160(0x1000 + i));
        }
        vm.resumeGasMetering();

        vm.prank(admin);
        vault.setManagers(ten);
    }

    // -------------------------------------------------------------------
    // Views at increasing history depth
    // -------------------------------------------------------------------

    function test_gas_views_emptyHistory() public view {
        vault.getRecentWithdrawn();
        vault.getRemainingLimit();
        vault.getWindowState();
    }

    function test_gas_views_2000CheckpointHistory() public {
        vm.pauseGasMetering();
        vm.startPrank(admin);
        vault.lock();
        vault.resetWindowAndSetPeriod(1000);
        vault.unlock();
        vm.stopPrank();
        _dripUniqueTimestamps(2000, 1);
        vm.resumeGasMetering();

        vault.getRecentWithdrawn();
        vault.getRemainingLimit();
        vault.getWindowState();
    }

    function test_gas_views_10000CheckpointHistory() public {
        vm.pauseGasMetering();
        _grow10kHistory();
        vm.resumeGasMetering();

        vault.getRecentWithdrawn();
        vault.getRemainingLimit();
        vault.getWindowState();
    }
}
