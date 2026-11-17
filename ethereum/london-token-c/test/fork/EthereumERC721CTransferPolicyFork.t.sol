// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CustodyRegistry} from "../../src/erc721c/CustodyRegistry.sol";
import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCFactory} from "../../src/erc721c/LondonTokenCFactory.sol";

struct CollectionSecurityPolicyV5 {
    uint8 rulesetId;
    uint48 listId;
    address customRuleset;
    uint8 globalOptions;
    uint16 rulesetOptions;
    uint16 tokenType;
}

interface IValidatorV5 {
    function beforeAuthorizedTransfer(address operator, address token, uint256 tokenId) external;
    function afterAuthorizedTransfer(address token, uint256 tokenId) external;
    function getCollectionSecurityPolicy(address collection)
        external
        view
        returns (CollectionSecurityPolicyV5 memory);
    function listOwners(uint48 id) external view returns (address);
    function addAccountsToList(uint48 id, uint8 listType, address[] calldata accounts) external;
}

/// @dev Etched at the OpenSea SignedZone address. Authorizes itself as operator and moves the token
///      in one call, as a Seaport fill does (authorize -> transfer -> clear in one transaction);
///      the validator keeps that authorization in transient storage.
contract SeaportFillHarness {
    function fill(LondonTokenCBase token, address from, address to, uint256 tokenId) external {
        IValidatorV5 v = IValidatorV5(0x721C008fdff27BF06E7E123956E2Fe03B63342e3);
        v.beforeAuthorizedTransfer(address(this), address(token), tokenId);
        token.transferFrom(from, to, tokenId);
        v.afterAuthorizedTransfer(address(token), tokenId);
    }
}

/// @dev Deployment-time transfer policies against the live Limit Break validator v5 on an Ethereum
///      fork. Skipped unless ETHEREUM_RPC_URL is set.
contract EthereumERC721CTransferPolicyForkTest is Test {
    IValidatorV5 internal constant VALIDATOR =
        IValidatorV5(0x721C008fdff27BF06E7E123956E2Fe03B63342e3);
    address internal constant OPENSEA_ZONE = 0x000056F7000000EcE9003ca63978907a00FFD100;
    address internal constant PAYMENT_PROCESSOR = 0x9A1D00bEd7CD04BCDA516d721A596eb22Aac6834;
    address internal constant VENLY_CUSTODY = 0xB4B57125AF2aCf9Bf605A9D9C3D256537876f65A;

    bytes4 internal constant CALLER_OR_FROM_MUST_BE_WHITELISTED = 0xe1f1d02e;
    bytes4 internal constant CALLER_MUST_BE_AN_AUTHORIZER = 0xbc8ea062;
    bytes4 internal constant CALLER_DOES_NOT_OWN_LIST = 0x4e680cb0;
    uint8 internal constant GO_EXTEND_DEFAULT_LISTS = 1 << 3;
    uint16 internal constant WLO_BLOCK_ALL_OTC = 1 << 0;

    address internal artist = makeAddr("artist");
    address internal minter = makeAddr("minter");
    address internal collector = makeAddr("collector");
    address internal recipient = makeAddr("recipient");

    LondonTokenCFactory internal factory;

    function setUp() public {
        string memory rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1, "unexpected fork chain id");
        vm.etch(OPENSEA_ZONE, address(new SeaportFillHarness()).code);

        address[] memory custodians = new address[](1);
        custodians[0] = VENLY_CUSTODY;
        factory = new LondonTokenCFactory(
            address(new CustodyRegistry(makeAddr("verseSafe"), custodians))
        );
    }

    // ---------------------------------------------------------------------
    // Policies
    // ---------------------------------------------------------------------

    function test_fork_policy_empty_blocksEveryMarketplace() public {
        LondonTokenCBase t = _create(_policy(new address[](0), new address[](0), 0, 0));
        CollectionSecurityPolicyV5 memory p = VALIDATOR.getCollectionSecurityPolicy(address(t));
        assertEq(p.rulesetId, 4, "whitelist ruleset");
        assertGt(p.listId, 0, "custom list applied");
        assertEq(VALIDATOR.listOwners(p.listId), artist, "artist owns the list");

        _expectOpenSeaFill(t, 1, CALLER_MUST_BE_AN_AUTHORIZER);
        _expectPaymentProcessor(t, 1, CALLER_OR_FROM_MUST_BE_WHITELISTED);
        _collectorOtc(t, 1, bytes4(0));
        _custodyWithdraw(t);
    }

    function test_fork_policy_paymentProcessorOnly() public {
        LondonTokenCBase t = _create(_policy(_one(PAYMENT_PROCESSOR), new address[](0), 0, 0));
        _expectOpenSeaFill(t, 1, CALLER_MUST_BE_AN_AUTHORIZER);
        _expectPaymentProcessor(t, 2, bytes4(0));
    }

    function test_fork_policy_openSeaOnly() public {
        LondonTokenCBase t = _create(_policy(new address[](0), _one(OPENSEA_ZONE), 0, 0));
        _expectPaymentProcessor(t, 1, CALLER_OR_FROM_MUST_BE_WHITELISTED);
        _expectOpenSeaFill(t, 2, bytes4(0));
    }

    function test_fork_policy_blockAllOtc_custodyStillWithdraws() public {
        LondonTokenCBase t =
            _create(_policy(new address[](0), new address[](0), 0, WLO_BLOCK_ALL_OTC));
        _collectorOtc(t, 1, CALLER_OR_FROM_MUST_BE_WHITELISTED);
        _custodyWithdraw(t);
    }

    function test_fork_policy_artistCanEditListLater() public {
        LondonTokenCBase t = _create(_policy(new address[](0), new address[](0), 0, 0));
        uint48 listId = VALIDATOR.getCollectionSecurityPolicy(address(t)).listId;
        _expectPaymentProcessor(t, 1, CALLER_OR_FROM_MUST_BE_WHITELISTED);

        vm.prank(makeAddr("verseOrAnyoneElse"));
        vm.expectRevert(CALLER_DOES_NOT_OWN_LIST);
        VALIDATOR.addAccountsToList(listId, 1, _one(PAYMENT_PROCESSOR));

        vm.prank(artist);
        VALIDATOR.addAccountsToList(listId, 1, _one(PAYMENT_PROCESSOR));
        _expectPaymentProcessor(t, 1, bytes4(0));
    }

    function test_fork_policy_extendDefaultLists_behavesLikeDefaults() public {
        LondonTokenCBase t =
            _create(_policy(new address[](0), new address[](0), GO_EXTEND_DEFAULT_LISTS, 0));
        _expectPaymentProcessor(t, 1, bytes4(0));
        _expectOpenSeaFill(t, 2, bytes4(0));
    }

    function test_fork_createCollectionWithoutPolicy_keepsDefaults() public {
        LondonTokenCBase t = LondonTokenCBase(
            factory.createCollection("ipfs://x", minter, minter, "Default", 750, artist)
        );
        _mintAndApprove(t);
        assertEq(VALIDATOR.getCollectionSecurityPolicy(address(t)).listId, 0, "default list");
        _expectPaymentProcessor(t, 1, bytes4(0));
        _expectOpenSeaFill(t, 2, bytes4(0));
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _policy(address[] memory whitelist, address[] memory authorizers, uint8 go, uint16 ro)
        internal
        pure
        returns (LondonTokenCBase.TransferPolicy memory)
    {
        return LondonTokenCBase.TransferPolicy(whitelist, authorizers, go, ro);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _create(LondonTokenCBase.TransferPolicy memory policy)
        internal
        returns (LondonTokenCBase t)
    {
        t = LondonTokenCBase(
            factory.createCollectionWithTransferPolicy(
                "ipfs://x", minter, minter, "Policy", 750, artist, policy
            )
        );
        _mintAndApprove(t);
    }

    function _mintAndApprove(LondonTokenCBase t) internal {
        vm.startPrank(minter);
        t.mint(collector, 1);
        t.mint(collector, 2);
        t.mint(VENLY_CUSTODY, 100);
        vm.stopPrank();
        vm.startPrank(collector);
        t.setApprovalForAll(OPENSEA_ZONE, true);
        t.setApprovalForAll(PAYMENT_PROCESSOR, true);
        vm.stopPrank();
    }

    function _expectOpenSeaFill(LondonTokenCBase t, uint256 id, bytes4 err) internal {
        if (err != bytes4(0)) vm.expectRevert(err);
        SeaportFillHarness(OPENSEA_ZONE).fill(t, collector, recipient, id);
        if (err == bytes4(0)) assertEq(t.ownerOf(id), recipient, "OpenSea fill");
    }

    function _expectPaymentProcessor(LondonTokenCBase t, uint256 id, bytes4 err) internal {
        vm.prank(PAYMENT_PROCESSOR);
        if (err != bytes4(0)) vm.expectRevert(err);
        t.transferFrom(collector, recipient, id);
        if (err == bytes4(0)) assertEq(t.ownerOf(id), recipient, "Payment Processor");
    }

    function _collectorOtc(LondonTokenCBase t, uint256 id, bytes4 err) internal {
        vm.prank(collector);
        if (err != bytes4(0)) vm.expectRevert(err);
        t.transferFrom(collector, recipient, id);
    }

    function _custodyWithdraw(LondonTokenCBase t) internal {
        vm.prank(VENLY_CUSTODY);
        t.safeTransferFrom(VENLY_CUSTODY, recipient, 100);
        assertEq(t.ownerOf(100), recipient, "custody withdrawal");
    }
}
