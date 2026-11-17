// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Registry stand-in that answers `isCustody` badly, to prove the collection treats any
///      failure as "not custody" (validate as normal) instead of reverting or exempting.
contract MisbehavingCustodyRegistry {
    enum Mode {
        Revert,
        ReturnTwo,
        ReturnShort
    }

    Mode public immutable mode;

    constructor(Mode mode_) {
        mode = mode_;
    }

    fallback() external {
        Mode m = mode;
        if (m == Mode.Revert) {
            revert("registry down");
        }
        if (m == Mode.ReturnTwo) {
            assembly {
                mstore(0, 2)
                return(0, 32)
            }
        }
        assembly {
            mstore(0, 1)
            return(31, 1)
        }
    }
}
