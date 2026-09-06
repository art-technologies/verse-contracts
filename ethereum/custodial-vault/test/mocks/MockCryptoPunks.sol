// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Minimal CryptoPunks-style contract: pre-ERC-721, no safe-transfer
///      callbacks, movable only via `transferPunk` from the current holder.
///      Models any future non-standard asset that can get stuck in the vault.
contract MockCryptoPunks {
    mapping(uint256 punkIndex => address holder) public punkIndexToAddress;

    event PunkTransfer(address indexed from, address indexed to, uint256 punkIndex);

    function setInitialOwner(address to, uint256 punkIndex) external {
        punkIndexToAddress[punkIndex] = to;
    }

    function transferPunk(address to, uint256 punkIndex) external {
        require(punkIndexToAddress[punkIndex] == msg.sender, "not punk holder");
        punkIndexToAddress[punkIndex] = to;
        emit PunkTransfer(msg.sender, to, punkIndex);
    }
}
