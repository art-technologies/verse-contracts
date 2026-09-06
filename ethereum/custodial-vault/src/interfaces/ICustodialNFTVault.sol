// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ICustodialNFTVault
/// @notice External interface of the custodial ERC-721 / ERC-1155 vault with
///         a shared distinct-token sliding-window withdrawal limiter (v2).
///         Extension vaults add asset-specific entrypoints in their own
///         interfaces (see {ICustodialNFTVaultWithPunks}).
/// @dev The vault holds NFTs deposited through ordinary (safe) token transfers.
///      There is no deposit entrypoint and no on-chain deposit attribution.
///      Withdrawals are restricted to configured manager accounts and bounded
///      by a rolling window measured in distinct `(token, tokenId)` pairs,
///      backed by OpenZeppelin `RateLimiter.SlidingWindow`.
///
///      v2 uses standard OpenZeppelin administration primitives, inherited by
///      the implementation and intentionally not redeclared here:
///      - `Ownable2Step`: `owner()`, `pendingOwner()`,
///        `transferOwnership(address)` (zero cancels a pending transfer),
///        `acceptOwnership()`; ownership renunciation is disabled.
///      - `Pausable`: `paused()`, `Paused`/`Unpaused` events,
///        `EnforcedPause`/`ExpectedPause` errors. "Locked" == "paused".
interface ICustodialNFTVault {
    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @notice Supported NFT token standards for the generic {withdraw}
    ///         path. CryptoPunks are intentionally NOT part of this enum;
    ///         they are handled by the separate `withdrawPunks` entrypoint
    ///         of {ICustodialNFTVaultWithPunks}.
    enum TokenStandard {
        ERC721,
        ERC1155
    }

    /// @notice One asset movement inside a withdrawal batch.
    /// @param token Token contract address; must be non-zero.
    /// @param tokenId Token identifier within `token`.
    /// @param amount Units to transfer; must be exactly 1 for ERC-721 and
    ///        greater than zero for ERC-1155.
    /// @param recipient Destination address; must be non-zero.
    /// @param standard Token standard used for the transfer call.
    struct WithdrawalItem {
        address token;
        uint256 tokenId;
        uint256 amount;
        address recipient;
        TokenStandard standard;
    }

    /// @notice Configurable withdrawal limits; each value is bounded by an
    ///         immutable hard cap compiled into the contract.
    /// @param maxTokens Maximum distinct `(token, tokenId)` pairs withdrawable
    ///        inside one rolling window; 1..2000.
    /// @param periodSeconds Rolling window length in seconds; 1..2592000.
    ///        Immutable via {setLimits}; changeable only through the explicit
    ///        {resetWindowAndSetPeriod} epoch operation while paused.
    /// @param maxItemsPerBatch Maximum items in one `withdraw` call; 1..50.
    struct Limits {
        uint16 maxTokens;
        uint32 periodSeconds;
        uint8 maxItemsPerBatch;
    }

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    /// @notice Caller is not a withdrawal manager.
    error NotManager();
    /// @notice Caller is neither the owner nor an emergency locker.
    error NotOwnerOrEmergencyLocker();
    /// @notice Ownership renunciation is permanently disabled.
    error OwnershipRenunciationDisabled();
    /// @notice The withdrawal batch is empty.
    error EmptyBatch();
    /// @notice The withdrawal batch exceeds the configured maximum size.
    error BatchTooLarge(uint256 supplied, uint256 maximum);
    /// @notice Item `index` has a zero token address.
    error ZeroTokenAddress(uint256 index);
    /// @notice Item `index` has a zero recipient address.
    error ZeroRecipientAddress(uint256 index);
    /// @notice Item `index` has an invalid amount for its standard.
    error InvalidAmount(uint256 index);
    /// @notice Item `index` declares an invalid token standard.
    /// @dev On {withdraw} this is reserved for interface completeness:
    ///      Solidity's calldata validator rejects out-of-range enum values
    ///      with a data-less revert before the function body runs (covered
    ///      by a malformed-calldata test). Extension entrypoints (e.g.
    ///      `withdrawPunks`) emit it for items whose `standard` is not the
    ///      canonical value they require.
    error InvalidTokenStandard(uint256 index);
    /// @notice Item `index` breaks non-decreasing `(token, tokenId)` order.
    error ItemsNotSorted(uint256 index);
    /// @notice Item `index` repeats an ERC-721 `(token, tokenId)` pair.
    error DuplicateERC721(uint256 index);
    /// @notice Item `index` repeats a key with a different token standard.
    error TokenStandardMismatch(uint256 index);
    /// @notice Proposed limits violate the immutable hard caps.
    error InvalidLimits();
    /// @notice `setLimits` cannot change the period; use
    ///         {resetWindowAndSetPeriod}.
    error PeriodIsImmutable();
    /// @notice A manager set must contain at least one address.
    error NoManagers();
    /// @notice A manager set must contain at most ten addresses.
    error TooManyManagers();
    /// @notice An emergency-locker set must contain at least one address.
    error NoEmergencyLockers();
    /// @notice An emergency-locker set must contain at most ten addresses.
    error TooManyEmergencyLockers();
    /// @notice A role array is not strictly ascending (or contains duplicates).
    error RoleAddressesNotSorted();
    /// @notice A role array contains the zero address.
    error ZeroRoleAddress();
    /// @notice Stored configuration violates the hard caps; fail closed.
    error BadStoredConfiguration();
    /// @notice Ordinary native-currency transfers to the vault are rejected.
    error DirectNativeTransferRejected();
    /// @notice A call to an unknown function selector was rejected.
    error UnknownCall();

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    /// @notice A withdrawal batch executed successfully.
    /// @param manager The manager that submitted the batch.
    /// @param itemCount Number of items in the batch.
    /// @param distinctTokens Distinct `(token, tokenId)` pairs consumed.
    /// @param usedBefore Active window usage before this withdrawal.
    /// @param usedAfter Active window usage after this withdrawal.
    event WithdrawalExecuted(
        address indexed manager,
        uint256 itemCount,
        uint256 distinctTokens,
        uint256 usedBefore,
        uint256 usedAfter
    );

    /// @notice A manager request exceeded the remaining window allowance and
    ///         the vault paused itself. No transfer occurred. Emitted
    ///         together with the standard `Paused` event.
    /// @param manager The manager whose request triggered the lock.
    /// @param usedInWindow Active usage at the time of the request.
    /// @param requested Distinct tokens requested by the batch.
    /// @param maxTokens Configured window budget.
    /// @param periodSeconds Configured window length.
    event AutoLocked(
        address indexed manager,
        uint256 usedInWindow,
        uint256 requested,
        uint256 maxTokens,
        uint256 periodSeconds
    );

    /// @notice The manager set was replaced.
    /// @param oldHash keccak256(abi.encode(previous canonical array)).
    /// @param newHash keccak256(abi.encode(new canonical array)).
    event ManagersChanged(bytes32 indexed oldHash, bytes32 indexed newHash);

    /// @notice The emergency-locker set was replaced.
    /// @param oldHash keccak256(abi.encode(previous canonical array)).
    /// @param newHash keccak256(abi.encode(new canonical array)).
    event EmergencyLockersChanged(bytes32 indexed oldHash, bytes32 indexed newHash);

    /// @notice The withdrawal limits were changed.
    event LimitsChanged(Limits oldLimits, Limits newLimits);

    /// @notice The window history was explicitly reset and a new period
    ///         applied (paused-only epoch operation).
    event WindowEpochReset(uint32 oldPeriodSeconds, uint32 newPeriodSeconds);

    /// @notice Accidentally received ERC-20 tokens were rescued.
    event ERC20Rescued(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Forced or pre-funded native currency was rescued.
    event NativeRescued(address indexed recipient, uint256 amount);

    /// @notice The owner executed an arbitrary call from the vault. CRITICAL
    ///         monitoring signal: every occurrence must reconcile with an
    ///         approved rescue ticket.
    event Executed(address indexed target, uint256 value, bytes data);

    // ---------------------------------------------------------------------
    // Manager operations
    // ---------------------------------------------------------------------

    /// @notice Withdraw a batch of NFTs to their recipients.
    /// @dev Manager only. Items must be sorted non-decreasingly by
    ///      `(token, tokenId)`. When the batch's distinct-token count would
    ///      exceed the remaining rolling-window allowance, the vault pauses
    ///      itself, emits {AutoLocked}, performs no transfer, records no
    ///      consumption, and returns false without reverting.
    /// @param items The withdrawal batch.
    /// @return executed True when the batch executed; false on auto-lock.
    function withdraw(WithdrawalItem[] calldata items) external returns (bool executed);

    // ---------------------------------------------------------------------
    // Locking
    // ---------------------------------------------------------------------

    /// @notice Pause withdrawals. Owner or emergency locker. Idempotent: a
    ///         repeated lock is a silent no-op (the standard `Paused` event
    ///         fires only on the actual transition).
    function lock() external;

    /// @notice Unpause withdrawals. Owner only. Reverts with `ExpectedPause`
    ///         when not paused. Never erases window history.
    function unlock() external;

    // ---------------------------------------------------------------------
    // Configuration (owner only)
    // ---------------------------------------------------------------------

    /// @notice Replace the entire manager set.
    /// @param newManagers 1..10 non-zero, strictly ascending addresses.
    function setManagers(address[] calldata newManagers) external;

    /// @notice Replace the entire emergency-locker set.
    /// @param newLockers 1..10 non-zero, strictly ascending addresses.
    function setEmergencyLockers(address[] calldata newLockers) external;

    /// @notice Change `maxTokens` / `maxItemsPerBatch` inside the immutable
    ///         hard caps. The period cannot change here; window history is
    ///         preserved. Lowering `maxTokens` below current usage simply
    ///         auto-locks the next attempted withdrawal.
    /// @param newLimits The new limit configuration (same `periodSeconds`).
    function setLimits(Limits calldata newLimits) external;

    /// @notice Explicit new-epoch operation: erases ALL window history and
    ///         applies a new period. Only callable while paused; the vault
    ///         stays paused until a separate {unlock}.
    /// @param newPeriodSeconds The new window length; 1..2592000.
    function resetWindowAndSetPeriod(uint32 newPeriodSeconds) external;

    // ---------------------------------------------------------------------
    // Rescue (owner only; available while paused)
    // ---------------------------------------------------------------------

    /// @notice Rescue accidentally received ERC-20 tokens.
    /// @param token ERC-20 token contract; non-zero.
    /// @param recipient Destination; non-zero.
    /// @param amount Amount to transfer.
    function rescueERC20(address token, address recipient, uint256 amount) external;

    /// @notice Rescue forced or pre-funded native currency via
    ///         `Address.sendValue` (bubbles the recipient's revert data).
    /// @param recipient Destination; non-zero.
    /// @param amount Wei to transfer.
    function rescueNative(address payable recipient, uint256 amount) external;

    // ---------------------------------------------------------------------
    // Arbitrary execution (owner only)
    // ---------------------------------------------------------------------

    /// @notice Execute an arbitrary call from the vault. Owner only. Plain
    ///         CALL (never delegatecall); bubbles the target's revert data;
    ///         emits {Executed} (Critical). Primary purpose: recovering
    ///         assets that follow none of the supported standards (ERC-721,
    ///         ERC-1155, CryptoPunks) and would otherwise be stuck forever.
    /// @dev ACCEPTED-RISK NOTE (design decision, 2026-07-21): the owner
    ///      already holds effective root over custody without this function —
    ///      a compromised owner Safe can replace all managers and emergency
    ///      lockers, max the limits, epoch-reset the window to the 1-second
    ///      minimum, and drain the vault in roughly ten transactions.
    ///      `execute` therefore does not grant a fundamentally new
    ///      capability; it removes the multi-transaction friction. The Safe
    ///      itself (owner set, threshold, signing hygiene, transaction
    ///      review) is the security boundary for this entrypoint, and every
    ///      call is a Critical monitoring event.
    /// @param target Contract to call; non-zero.
    /// @param value Native currency to forward from the vault balance.
    /// @param data Full calldata for the call.
    /// @return result The call's raw return data.
    function execute(address target, uint256 value, bytes calldata data)
        external
        returns (bytes memory result);

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Canonical (ascending) manager array.
    function getManagers() external view returns (address[] memory);

    /// @notice Canonical (ascending) emergency-locker array.
    function getEmergencyLockers() external view returns (address[] memory);

    /// @notice True when `account` is a withdrawal manager.
    function isManager(address account) external view returns (bool);

    /// @notice True when `account` is an emergency locker.
    function isEmergencyLocker(address account) external view returns (bool);

    /// @notice Current limit configuration.
    function getLimits() external view returns (Limits memory);

    /// @notice Distinct tokens withdrawn inside the currently active window.
    function getRecentWithdrawn() external view returns (uint256);

    /// @notice Remaining window allowance, clamped at zero.
    function getRemainingLimit() external view returns (uint256);

    /// @notice Aggregate window telemetry computed at `block.timestamp`.
    /// @return used Active distinct-token usage.
    /// @return remaining Remaining allowance, clamped at zero.
    /// @return maxTokens Configured window budget.
    /// @return periodSeconds Configured window length.
    /// @return locked Current pause state.
    function getWindowState()
        external
        view
        returns (
            uint256 used,
            uint256 remaining,
            uint256 maxTokens,
            uint256 periodSeconds,
            bool locked
        );

    /// @notice Current lock state; alias of `paused()`.
    function isLocked() external view returns (bool);
}
