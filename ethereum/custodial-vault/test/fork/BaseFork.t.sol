// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkSmoke} from "./ForkSmoke.sol";

/// @dev Base fork smoke test; set BASE_RPC_URL to enable.
contract BaseForkTest is ForkSmoke {
    function _rpcEnvVar() internal pure override returns (string memory) {
        return "BASE_RPC_URL";
    }

    function _expectedChainId() internal pure override returns (uint256) {
        return 8453;
    }
}
