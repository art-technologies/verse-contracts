// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkSmoke} from "./ForkSmoke.sol";

/// @dev Ethereum Mainnet fork smoke test; set ETHEREUM_RPC_URL to enable.
contract EthereumForkTest is ForkSmoke {
    function _rpcEnvVar() internal pure override returns (string memory) {
        return "ETHEREUM_RPC_URL";
    }

    function _expectedChainId() internal pure override returns (uint256) {
        return 1;
    }
}
