// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ForkSmoke} from "./ForkSmoke.sol";

/// @dev Polygon PoS fork smoke test; set POLYGON_RPC_URL to enable.
contract PolygonForkTest is ForkSmoke {
    function _rpcEnvVar() internal pure override returns (string memory) {
        return "POLYGON_RPC_URL";
    }

    function _expectedChainId() internal pure override returns (uint256) {
        return 137;
    }
}
