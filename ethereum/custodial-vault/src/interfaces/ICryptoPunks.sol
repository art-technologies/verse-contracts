// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title ICryptoPunks
/// @notice Minimal interface of the original `CryptoPunksMarket` contract
///         (pre-ERC-721). `transferPunk` throws unless the caller currently
///         owns the punk, so a successful call implies the vault held the
///         asset; there is no return value and no receiver callback.
interface ICryptoPunks {
    function transferPunk(address to, uint256 punkIndex) external;
}
