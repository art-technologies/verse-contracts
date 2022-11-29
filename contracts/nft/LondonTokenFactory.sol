// SPDX-License-Identifier: MIT
pragma solidity 0.8.13;

import "./LondonToken.sol";

contract LondonTokenFactory {
    event CreateLondontoken(address indexed contractAddress, address indexed creatorAddress);

    LondonToken[] public contractArray;

    function CreateNewLondonToken(string memory uri_, address minter_) public {
        LondonToken lt = new LondonToken(uri_, minter_);
        contractArray.push(lt);
        emit CreateLondontoken(address(lt), msg.sender);
    }

    function getAddress(uint256 index) public view returns (address) {
        return address(contractArray[index]);
    }

    function count() public view returns (uint256) {
        return contractArray.length;
    }
}
