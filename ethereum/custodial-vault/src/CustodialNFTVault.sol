// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Arrays} from "@openzeppelin/contracts/utils/Arrays.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {RateLimiter} from "@openzeppelin/contracts/utils/RateLimiter.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {ICustodialNFTVault} from "./interfaces/ICustodialNFTVault.sol";

/// @title CustodialNFTVault
/// @notice Minimal custodial vault for ERC-721 and ERC-1155 assets with a
///         shared sliding-window withdrawal limiter measured in distinct
///         `(token, tokenId)` pairs (v2, built on OpenZeppelin primitives).
///         Extension vaults (e.g. {CustodialNFTVaultWithPunks}) inherit this
///         contract and add asset-specific withdrawal entrypoints through the
///         internal {_checkWithdrawalPreconditions} / {_consumeOrAutoLock}
///         hooks, so every exit path shares the same manager gate, pause
///         state, batch cap, and global window budget.
/// @dev Security model summary:
///      - Deposits arrive through ordinary (safe) token transfers; the
///        receiver callbacks ({ERC721Holder}/{ERC1155Holder}) are stateless
///        and there is no deposit attribution on-chain.
///      - Only configured managers can withdraw; the owner is not
///        implicitly a manager.
///      - An over-limit withdrawal request pauses the vault, emits
///        {AutoLocked}, transfers nothing, and returns false WITHOUT
///        reverting, so the lock persists in the vault's own frame.
///      - Emergency lockers can only lock (pause). Only the owner (expected
///        to be a dedicated Safe multisig, via {Ownable2Step} with
///        renunciation disabled) can unlock or reconfigure.
///      - Rolling-window accounting is OpenZeppelin
///        {RateLimiter.SlidingWindow} under a single global key: a
///        consumption expires exactly when the full period has elapsed;
///        `tryConsume` records nothing when capacity is insufficient.
///        Checkpoint storage grows with successful consumptions at unique
///        timestamps and is truncated on the first consumption after a
///        full-window idle (see docs/THREAT_MODEL.md for the storage-growth
///        trade-off vs the v1 bounded ring).
///      - `periodSeconds` cannot be changed by {setLimits}; the only way to
///        change it is the explicit paused-only {resetWindowAndSetPeriod}
///        epoch operation, which erases window history transparently.
///      - There is no delegatecall and no upgrade path. The contract must be
///        deployed directly, never behind a proxy. The owner has an
///        arbitrary-call {execute} entrypoint (plain CALL, Critical
///        {Executed} event) intended for rescuing non-ERC-721/1155 stuck
///        assets — an accepted design decision documented on {execute}: the
///        owner Safe already holds effective root over custody, so `execute`
///        removes friction rather than granting new capability. The Safe is
///        the security boundary for it.
contract CustodialNFTVault is
    ICustodialNFTVault,
    Ownable2Step,
    Pausable,
    ERC721Holder,
    ERC1155Holder,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using RateLimiter for RateLimiter.SlidingWindow;

    // ---------------------------------------------------------------------
    // Immutable hard caps
    // ---------------------------------------------------------------------

    /// @notice Maximum configurable distinct-token budget per rolling window.
    uint16 public constant HARD_MAX_TOKENS_PER_PERIOD = 2000;
    /// @notice Maximum configurable rolling-window length (30 days).
    uint32 public constant HARD_MAX_PERIOD_SECONDS = 2_592_000;
    /// @notice Maximum configurable items per withdrawal batch.
    uint8 public constant HARD_MAX_ITEMS_PER_BATCH = 50;
    /// @notice Maximum number of withdrawal managers.
    uint8 public constant HARD_MAX_MANAGERS = 10;
    /// @notice Maximum number of emergency lockers.
    uint8 public constant HARD_MAX_EMERGENCY_LOCKERS = 10;
    /// @notice Minimum configurable rolling-window length.
    uint32 public constant MIN_PERIOD_SECONDS = 1;

    /// @dev Single global limiter entry: the allowance is shared by all
    ///      managers across all collections.
    bytes32 private constant GLOBAL_WITHDRAWAL_LIMIT = bytes32(0);

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    /// @dev Withdrawal managers; canonical ascending order is enforced on
    ///      input and reconstructed by sorting on output.
    EnumerableSet.AddressSet private _managers;
    /// @dev Emergency lockers; same canonicalization as managers.
    EnumerableSet.AddressSet private _emergencyLockers;

    /// @dev Shared sliding-window limiter (OpenZeppelin RateLimiter).
    RateLimiter.SlidingWindow private _withdrawalWindow;

    /// @dev Current limit configuration; mirrored into the limiter via
    ///      `updateSettings` on every change. Fits one storage slot.
    Limits private _limits;

    // ---------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------

    /// @notice Deploys the vault. The vault starts unpaused with an empty
    ///         window history.
    /// @param initialOwner Production Safe multisig; non-zero. No deployer
    ///        privilege remains after construction.
    /// @param initialManagers 1..10 non-zero, strictly ascending managers.
    /// @param initialEmergencyLockers 1..10 non-zero, strictly ascending
    ///        emergency lockers.
    /// @param initialLimits Initial limits; validated against the hard caps.
    constructor(
        address initialOwner,
        address[] memory initialManagers,
        address[] memory initialEmergencyLockers,
        Limits memory initialLimits
    ) Ownable(initialOwner) {
        _replaceManagers(initialManagers);
        _replaceEmergencyLockers(initialEmergencyLockers);

        _validateLimits(initialLimits);
        _limits = initialLimits;
        _withdrawalWindow.updateSettings(
            uint48(initialLimits.periodSeconds), uint208(initialLimits.maxTokens)
        );

        emit LimitsChanged(Limits(0, 0, 0), initialLimits);
    }

    // ---------------------------------------------------------------------
    // Native-currency rejection
    // ---------------------------------------------------------------------

    /// @notice Ordinary native-currency transfers are rejected. Forced or
    ///         pre-funded balances are recoverable via {rescueNative}.
    receive() external payable {
        revert DirectNativeTransferRejected();
    }

    /// @notice Calls to unknown selectors are rejected.
    fallback() external payable {
        revert UnknownCall();
    }

    // ---------------------------------------------------------------------
    // Manager operations
    // ---------------------------------------------------------------------

    /// @inheritdoc ICustodialNFTVault
    function withdraw(WithdrawalItem[] calldata items)
        external
        nonReentrant
        returns (bool executed)
    {
        uint256 len = items.length;
        Limits memory limits = _checkWithdrawalPreconditions(len);

        uint256 requestedDistinct = _validateAndCountDistinct(items);

        (bool consumed, uint256 usedBefore) = _consumeOrAutoLock(requestedDistinct, limits);
        if (!consumed) return false;

        // Limiter storage is updated before any external token call, so no
        // reentrant or malicious token can observe unconsumed allowance. A
        // failed transfer reverts the recorded consumption atomically.
        // One external transfer per item is the specified behavior; the loop
        // is bounded by maxItemsPerBatch <= 50.
        for (uint256 i; i < len; ++i) {
            WithdrawalItem calldata item = items[i];
            if (item.standard == TokenStandard.ERC721) {
                // slither-disable-next-line calls-loop
                IERC721(item.token).safeTransferFrom(address(this), item.recipient, item.tokenId);
            } else {
                // slither-disable-next-line calls-loop
                IERC1155(item.token)
                    .safeTransferFrom(address(this), item.recipient, item.tokenId, item.amount, "");
            }
        }

        emit WithdrawalExecuted(
            msg.sender, len, requestedDistinct, usedBefore, usedBefore + requestedDistinct
        );
        return true;
    }

    // ---------------------------------------------------------------------
    // Internal: shared manager-withdrawal rails (used by extension vaults)
    // ---------------------------------------------------------------------

    /// @dev Shared preconditions for every manager withdrawal entrypoint:
    ///      fail-closed stored-configuration assert, manager gate, pause
    ///      check, and batch-size bounds. Extension vaults MUST call this
    ///      first in any additional withdrawal path so the security rails
    ///      are identical across entrypoints.
    /// @param len The batch length.
    /// @return limits The current limit configuration (single storage read).
    function _checkWithdrawalPreconditions(uint256 len)
        internal
        view
        returns (Limits memory limits)
    {
        _assertStoredConfiguration();
        if (!_managers.contains(msg.sender)) revert NotManager();
        _requireNotPaused();
        if (len == 0) revert EmptyBatch();
        limits = _limits;
        if (len > limits.maxItemsPerBatch) revert BatchTooLarge(len, limits.maxItemsPerBatch);
    }

    /// @dev Shared window-consumption step: consumes `requested` distinct
    ///      identifiers from the global sliding window, or — on insufficient
    ///      allowance — pauses the vault and emits {AutoLocked} WITHOUT
    ///      reverting (a revert would roll back the pause itself; nothing is
    ///      recorded and no token has been called yet). Callers must return
    ///      `false` without any external call when `consumed` is false, and
    ///      must perform external transfers only after this returns true so
    ///      consumption is always persisted before any token call.
    /// @param requested Distinct identifiers requested by the batch.
    /// @param limits The limits snapshot from {_checkWithdrawalPreconditions}.
    /// @return consumed True when the allowance was recorded.
    /// @return usedBefore Active window usage before this request.
    function _consumeOrAutoLock(uint256 requested, Limits memory limits)
        internal
        returns (bool consumed, uint256 usedBefore)
    {
        usedBefore = _withdrawalWindow.used(GLOBAL_WITHDRAWAL_LIMIT);
        if (!_withdrawalWindow.tryConsume(GLOBAL_WITHDRAWAL_LIMIT, requested)) {
            _pause();
            emit AutoLocked(
                msg.sender, usedBefore, requested, limits.maxTokens, limits.periodSeconds
            );
            return (false, usedBefore);
        }
        consumed = true;
    }

    // ---------------------------------------------------------------------
    // Locking
    // ---------------------------------------------------------------------

    /// @inheritdoc ICustodialNFTVault
    function lock() external {
        if (msg.sender != owner() && !_emergencyLockers.contains(msg.sender)) {
            revert NotOwnerOrEmergencyLocker();
        }
        if (!paused()) {
            _pause();
        }
    }

    /// @inheritdoc ICustodialNFTVault
    function unlock() external onlyOwner {
        // Reverts with ExpectedPause when not paused; window history is
        // untouched (expiry is purely time-based inside the limiter).
        _unpause();
    }

    // ---------------------------------------------------------------------
    // Ownership hardening
    // ---------------------------------------------------------------------

    /// @notice Ownership renunciation is permanently disabled: the vault
    ///         must never become ownerless.
    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    // ---------------------------------------------------------------------
    // Configuration
    // ---------------------------------------------------------------------

    /// @inheritdoc ICustodialNFTVault
    function setManagers(address[] calldata newManagers) external onlyOwner {
        _replaceManagers(newManagers);
    }

    /// @inheritdoc ICustodialNFTVault
    function setEmergencyLockers(address[] calldata newLockers) external onlyOwner {
        _replaceEmergencyLockers(newLockers);
    }

    /// @inheritdoc ICustodialNFTVault
    function setLimits(Limits calldata newLimits) external onlyOwner {
        _validateLimits(newLimits);
        Limits memory oldLimits = _limits;
        if (newLimits.periodSeconds != oldLimits.periodSeconds) revert PeriodIsImmutable();

        _limits = newLimits;
        // History is preserved; lowering `maxTokens` below current usage
        // simply auto-locks the next attempted withdrawal. Pause state is
        // never changed here.
        _withdrawalWindow.updateSettings(
            uint48(newLimits.periodSeconds), uint208(newLimits.maxTokens)
        );

        emit LimitsChanged(oldLimits, newLimits);
    }

    /// @inheritdoc ICustodialNFTVault
    function resetWindowAndSetPeriod(uint32 newPeriodSeconds) external onlyOwner {
        _requirePaused();
        if (newPeriodSeconds < MIN_PERIOD_SECONDS || newPeriodSeconds > HARD_MAX_PERIOD_SECONDS) {
            revert InvalidLimits();
        }

        uint32 oldPeriod = _limits.periodSeconds;
        _withdrawalWindow.reset(GLOBAL_WITHDRAWAL_LIMIT);
        _limits.periodSeconds = newPeriodSeconds;
        _withdrawalWindow.updateSettings(uint48(newPeriodSeconds), uint208(_limits.maxTokens));

        // The vault stays paused until a separate {unlock}.
        emit WindowEpochReset(oldPeriod, newPeriodSeconds);
    }

    // ---------------------------------------------------------------------
    // Rescue
    // ---------------------------------------------------------------------

    /// @inheritdoc ICustodialNFTVault
    function rescueERC20(address token, address recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (token == address(0)) revert ZeroTokenAddress(0);
        if (recipient == address(0)) revert ZeroRecipientAddress(0);
        IERC20(token).safeTransfer(recipient, amount);
        emit ERC20Rescued(token, recipient, amount);
    }

    /// @inheritdoc ICustodialNFTVault
    function rescueNative(address payable recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (recipient == address(0)) revert ZeroRecipientAddress(0);
        // Value transfer with empty calldata only; bubbles the recipient's
        // revert data (or Errors.FailedCall) on failure.
        Address.sendValue(recipient, amount);
        emit NativeRescued(recipient, amount);
    }

    // ---------------------------------------------------------------------
    // Arbitrary execution (owner only)
    // ---------------------------------------------------------------------

    /// @inheritdoc ICustodialNFTVault
    function execute(address target, uint256 value, bytes calldata data)
        external
        onlyOwner
        nonReentrant
        returns (bytes memory result)
    {
        if (target == address(0)) revert ZeroTokenAddress(0);

        // ACCEPTED-RISK NOTE (design decision, 2026-07-21): the owner Safe
        // already holds effective root over custody without this function —
        // a compromised Safe can replace all managers and emergency lockers,
        // max the limits, epoch-reset the window to the 1-second minimum,
        // and drain the vault in roughly ten transactions. `execute`
        // therefore adds no fundamentally new capability, only removes the
        // multi-transaction friction. The Safe (owner set, threshold,
        // signing hygiene, transaction review) is the security boundary
        // here; every call emits {Executed} (Critical). Plain CALL only —
        // never delegatecall.
        // slither-disable-next-line arbitrary-send-eth,low-level-calls
        result = Address.functionCallWithValue(target, data, value);

        emit Executed(target, value, data);
    }

    // ---------------------------------------------------------------------
    // ERC-165
    // ---------------------------------------------------------------------

    /// @notice ERC-165 reporting: ERC-1155 receiver (via {ERC1155Holder})
    ///         plus the ERC-721 receiver interface.
    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC1155Holder)
        returns (bool)
    {
        return interfaceId == type(IERC721Receiver).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @inheritdoc ICustodialNFTVault
    function getManagers() external view returns (address[] memory) {
        return _sortedValues(_managers);
    }

    /// @inheritdoc ICustodialNFTVault
    function getEmergencyLockers() external view returns (address[] memory) {
        return _sortedValues(_emergencyLockers);
    }

    /// @inheritdoc ICustodialNFTVault
    function isManager(address account) external view returns (bool) {
        return _managers.contains(account);
    }

    /// @inheritdoc ICustodialNFTVault
    function isEmergencyLocker(address account) external view returns (bool) {
        return _emergencyLockers.contains(account);
    }

    /// @inheritdoc ICustodialNFTVault
    function getLimits() external view returns (Limits memory) {
        return _limits;
    }

    /// @inheritdoc ICustodialNFTVault
    function getRecentWithdrawn() external view returns (uint256) {
        return _withdrawalWindow.used(GLOBAL_WITHDRAWAL_LIMIT);
    }

    /// @inheritdoc ICustodialNFTVault
    function getRemainingLimit() external view returns (uint256) {
        return _withdrawalWindow.available(GLOBAL_WITHDRAWAL_LIMIT);
    }

    /// @inheritdoc ICustodialNFTVault
    function getWindowState()
        external
        view
        returns (
            uint256 used,
            uint256 remaining,
            uint256 maxTokens,
            uint256 periodSeconds,
            bool locked
        )
    {
        (used, remaining) = _withdrawalWindow.state(GLOBAL_WITHDRAWAL_LIMIT);
        maxTokens = _limits.maxTokens;
        periodSeconds = _limits.periodSeconds;
        locked = paused();
    }

    /// @inheritdoc ICustodialNFTVault
    function isLocked() external view returns (bool) {
        return paused();
    }

    // ---------------------------------------------------------------------
    // Internal: batch validation and distinct-token counting
    // ---------------------------------------------------------------------

    /// @dev Validates every item and counts distinct `(token, tokenId)` pairs
    ///      in one pass over the canonically ordered batch. Reverts on any
    ///      malformed, unsorted, duplicate-ERC-721, or standard-mismatched
    ///      input before any state update or token call. The zero-value
    ///      initialization of the `prev*` trackers is intentional: they are
    ///      only compared from the second iteration onward. The branch count
    ///      mirrors the specified validation matrix.
    // slither-disable-next-line cyclomatic-complexity
    function _validateAndCountDistinct(WithdrawalItem[] calldata items)
        private
        pure
        returns (uint256 requestedDistinct)
    {
        // slither-disable-start uninitialized-local
        address prevToken;
        uint256 prevTokenId;
        TokenStandard prevStandard;
        // slither-disable-end uninitialized-local

        for (uint256 i; i < items.length; ++i) {
            WithdrawalItem calldata item = items[i];

            if (item.token == address(0)) revert ZeroTokenAddress(i);
            if (item.recipient == address(0)) revert ZeroRecipientAddress(i);
            if (item.standard == TokenStandard.ERC721) {
                if (item.amount != 1) revert InvalidAmount(i);
            } else {
                if (item.amount == 0) revert InvalidAmount(i);
            }

            if (i == 0) {
                requestedDistinct = 1;
            } else {
                bool sameToken = item.token == prevToken;
                if (item.token < prevToken || (sameToken && item.tokenId < prevTokenId)) {
                    revert ItemsNotSorted(i);
                }
                if (sameToken && item.tokenId == prevTokenId) {
                    if (item.standard != prevStandard) revert TokenStandardMismatch(i);
                    if (item.standard != TokenStandard.ERC1155) revert DuplicateERC721(i);
                    // Repeated ERC-1155 key: counts once toward the budget.
                } else {
                    ++requestedDistinct;
                }
            }

            prevToken = item.token;
            prevTokenId = item.tokenId;
            prevStandard = item.standard;
        }
    }

    // ---------------------------------------------------------------------
    // Internal: configuration
    // ---------------------------------------------------------------------

    /// @dev Fail-closed re-check of every stored hard-cap invariant; guards
    ///      the withdrawal path against impossible-but-catastrophic states.
    function _assertStoredConfiguration() private view {
        Limits memory limits = _limits;
        if (
            limits.maxTokens == 0 || limits.maxTokens > HARD_MAX_TOKENS_PER_PERIOD
                || limits.periodSeconds < MIN_PERIOD_SECONDS
                || limits.periodSeconds > HARD_MAX_PERIOD_SECONDS || limits.maxItemsPerBatch == 0
                || limits.maxItemsPerBatch > HARD_MAX_ITEMS_PER_BATCH || _managers.length() == 0
                || _managers.length() > HARD_MAX_MANAGERS || _emergencyLockers.length() == 0
                || _emergencyLockers.length() > HARD_MAX_EMERGENCY_LOCKERS
        ) {
            revert BadStoredConfiguration();
        }
    }

    /// @dev Validates proposed limits against the immutable hard caps.
    function _validateLimits(Limits memory limits) private pure {
        if (
            limits.maxTokens == 0 || limits.maxTokens > HARD_MAX_TOKENS_PER_PERIOD
                || limits.periodSeconds < MIN_PERIOD_SECONDS
                || limits.periodSeconds > HARD_MAX_PERIOD_SECONDS || limits.maxItemsPerBatch == 0
                || limits.maxItemsPerBatch > HARD_MAX_ITEMS_PER_BATCH
        ) {
            revert InvalidLimits();
        }
    }

    /// @dev Requires a canonical role array: non-zero addresses in strictly
    ///      ascending order (which also guarantees uniqueness).
    function _requireCanonicalRoleArray(address[] memory addrs) private pure {
        // `prev` intentionally starts at zero; index 0 is only zero-checked.
        // slither-disable-next-line uninitialized-local
        address prev;
        for (uint256 i; i < addrs.length; ++i) {
            address account = addrs[i];
            if (account == address(0)) revert ZeroRoleAddress();
            if (i > 0 && account <= prev) revert RoleAddressesNotSorted();
            prev = account;
        }
    }

    /// @dev Full replacement of the manager set; emits hashes of the old and
    ///      new canonical arrays. `clear()` is bounded by the 10-member cap.
    function _replaceManagers(address[] memory newManagers) private {
        uint256 n = newManagers.length;
        if (n == 0) revert NoManagers();
        if (n > HARD_MAX_MANAGERS) revert TooManyManagers();
        _requireCanonicalRoleArray(newManagers);

        bytes32 oldHash = keccak256(abi.encode(_sortedValues(_managers)));
        _managers.clear();
        for (uint256 i; i < n; ++i) {
            // Cannot return false: the canonical check rejected duplicates.
            // slither-disable-next-line unused-return
            _managers.add(newManagers[i]);
        }

        emit ManagersChanged(oldHash, keccak256(abi.encode(newManagers)));
    }

    /// @dev Full replacement of the emergency-locker set; same rules as
    ///      {_replaceManagers}.
    function _replaceEmergencyLockers(address[] memory newLockers) private {
        uint256 n = newLockers.length;
        if (n == 0) revert NoEmergencyLockers();
        if (n > HARD_MAX_EMERGENCY_LOCKERS) revert TooManyEmergencyLockers();
        _requireCanonicalRoleArray(newLockers);

        bytes32 oldHash = keccak256(abi.encode(_sortedValues(_emergencyLockers)));
        _emergencyLockers.clear();
        for (uint256 i; i < n; ++i) {
            // Cannot return false: the canonical check rejected duplicates.
            // slither-disable-next-line unused-return
            _emergencyLockers.add(newLockers[i]);
        }

        emit EmergencyLockersChanged(oldHash, keccak256(abi.encode(newLockers)));
    }

    /// @dev Canonical (ascending) copy of a role set. EnumerableSet makes no
    ///      ordering guarantee, so the memory copy is sorted on read.
    function _sortedValues(EnumerableSet.AddressSet storage set)
        private
        view
        returns (address[] memory vals)
    {
        vals = set.values();
        // In-place sort; the returned reference is the same array.
        // slither-disable-next-line unused-return
        Arrays.sort(vals);
    }
}
