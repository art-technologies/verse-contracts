// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Plain mintable ERC-20 for rescue tests.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev ERC-20 without a boolean return value (USDT-style) to exercise
///      SafeERC20 handling of non-standard return behavior.
contract NoReturnERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        // No return value on purpose.
    }
}

/// @dev ERC-20 that returns false instead of reverting.
contract FalseReturnERC20 {
    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }
}
