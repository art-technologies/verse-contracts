// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CustodyRegistry} from "../../src/erc721c/CustodyRegistry.sol";
import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCFactory} from "../../src/erc721c/LondonTokenCFactory.sol";
import {MockTransferValidator} from "./mocks/MockTransferValidator.sol";

/// @dev Shared fixture: a CustodyRegistry owned by `verseSafe` with one custody EOA, a factory,
///      the mock validator etched at the Limit Break default validator address, and one artist
///      collection minted into custody and to a collector.
abstract contract LondonTokenCTestBase is Test {
    address internal constant DEFAULT_VALIDATOR = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    bytes4 internal constant VALIDATE_TRANSFER_SELECTOR =
        bytes4(keccak256("validateTransfer(address,address,address,uint256)"));

    address internal verseSafe = makeAddr("verseSafe");
    address internal custody = makeAddr("custodyEoa");
    address internal artist = makeAddr("artist");
    address internal minter = makeAddr("minter");
    address internal gateway = makeAddr("gatewayManager");
    address internal collector = makeAddr("collector");
    address internal recipient = makeAddr("recipient");
    address internal operator = makeAddr("operator");
    address internal outsider = makeAddr("outsider");

    uint256 internal constant ROYALTY_BPS = 750;
    uint256 internal constant CUSTODY_TOKEN = 1;
    uint256 internal constant COLLECTOR_TOKEN = 2;

    CustodyRegistry internal registry;
    LondonTokenCFactory internal factory;
    LondonTokenCBase internal token;
    MockTransferValidator internal validator = MockTransferValidator(DEFAULT_VALIDATOR);

    function setUp() public virtual {
        vm.etch(DEFAULT_VALIDATOR, address(new MockTransferValidator()).code);

        address[] memory initial = new address[](1);
        initial[0] = custody;
        registry = new CustodyRegistry(verseSafe, initial);
        factory = new LondonTokenCFactory(address(registry));
        token = _createCollection(factory, "Collection by Artist");

        vm.startPrank(minter);
        token.mint(custody, CUSTODY_TOKEN);
        token.mint(collector, COLLECTOR_TOKEN);
        vm.stopPrank();
    }

    function _createCollection(LondonTokenCFactory f, string memory name)
        internal
        returns (LondonTokenCBase)
    {
        return LondonTokenCBase(
            f.createCollection("ipfs://base", minter, gateway, name, ROYALTY_BPS, artist)
        );
    }

    function _validateCall(address caller, address from, address to, uint256 tokenId)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(VALIDATE_TRANSFER_SELECTOR, caller, from, to, tokenId);
    }

    function _rejectedError(address caller, address from, address to, uint256 tokenId)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeWithSelector(
            MockTransferValidator.MockTransferRejected.selector, caller, from, to, tokenId
        );
    }
}
