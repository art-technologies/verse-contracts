// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCFactory} from "../../src/erc721c/LondonTokenCFactory.sol";
import {CustodyRegistry} from "../../src/erc721c/CustodyRegistry.sol";
import {OnchainFileStorage} from "../../src/erc721c/OnchainFileStorage.sol";
import {NoNFTReceiver} from "./AuditSecurity.t.sol";

struct AuditPolicy {
    uint8 rulesetId;
    uint48 listId;
    address customRuleset;
    uint8 globalOptions;
    uint16 rulesetOptions;
    uint16 tokenType;
}

interface AuditValidator {
    function getCollectionSecurityPolicy(address) external view returns (AuditPolicy memory);
    function listOwners(uint48) external view returns (address);
    function addAccountsToList(uint48, uint8, address[] calldata) external;
    function applyListToCollection(address, uint48) external;
}

contract LondonTokenCAuditMainnetForkTest is Test {
    uint256 constant AUDIT_BLOCK = 26_440_573;
    LondonTokenCFactory constant FACTORY = LondonTokenCFactory(0x9BCB0a7ed5b13FF6Da5B84121A3b2D744818Dd4C);
    address constant IMPLEMENTATION = 0x488f8e5d99F7C1560103b1A44ab85F4A22584b23;
    CustodyRegistry constant REGISTRY = CustodyRegistry(0x1a74DeF035593bD8B6EA1b41fae860E791B16e84);
    AuditValidator constant VALIDATOR = AuditValidator(0x721C008fdff27BF06E7E123956E2Fe03B63342e3);
    address artist = makeAddr("auditArtist");
    address minter = makeAddr("auditMinter");
    address holder = makeAddr("auditHolder");
    address nextArtist = makeAddr("auditSuccessor");
    address outsider = makeAddr("auditOutsider");
    LondonTokenCBase token;

    function setUp() public {
        vm.createSelectFork(vm.envString("ETHEREUM_RPC_URL"), AUDIT_BLOCK);
        assertEq(block.chainid, 1);
        token = LondonTokenCBase(FACTORY.createCollection("ipfs://audit", minter, artist, "Audit", 750, artist));
    }

    function test_mainnet_wiringAndImplementationLock() public {
        assertEq(FACTORY.tokenImplementation(), IMPLEMENTATION);
        assertEq(FACTORY.custodyRegistry(), address(REGISTRY));
        assertEq(address(token.custodyRegistry()), address(REGISTRY));
        assertEq(REGISTRY.custodians().length, 1);
        assertEq(address(token).code.length, 45);
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        LondonTokenCBase(IMPLEMENTATION).initialize("x", outsider, outsider, "x", 0, outsider);
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        token.initialize("x", outsider, outsider, "x", 0, outsider);
    }

    function test_mainnet_PoC_unsafeMint() public {
        NoNFTReceiver sink = new NoNFTReceiver();
        vm.prank(minter);
        token.mint(address(sink), 1);
        assertEq(token.ownerOf(1), address(sink));
        vm.prank(artist);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        token.transferFrom(address(sink), holder, 1);
    }

    function test_mainnet_PoC_emptyFileCannotBeRemoved() public {
        vm.prank(artist);
        token.addFile("art.html", new address[](0));
        assertEq(token.files().length, 1);
        vm.prank(artist);
        vm.expectRevert(OnchainFileStorage.FileNotRegistered.selector);
        token.removeFile("art.html");
    }

    // Independent validator list ownership survives the collection handoff.
    // This requires a coordinated handover; the successor can replace the list.
    function test_mainnet_PoC_previousOwnerRetainsAppliedListControl() public {
        LondonTokenCBase.TransferPolicy memory p = LondonTokenCBase.TransferPolicy(new address[](0), new address[](0), 0, 0);
        LondonTokenCBase t = LondonTokenCBase(FACTORY.createCollectionWithTransferPolicy(
            "ipfs://audit", minter, artist, "Audit policy", 750, artist, p
        ));
        uint48 listId = VALIDATOR.getCollectionSecurityPolicy(address(t)).listId;
        vm.prank(artist);
        t.transferOwnership(nextArtist);
        assertEq(t.owner(), nextArtist);
        assertEq(VALIDATOR.listOwners(listId), artist);
        address[] memory accounts = new address[](1);
        accounts[0] = outsider;
        vm.prank(nextArtist);
        vm.expectRevert();
        VALIDATOR.addAccountsToList(listId, 1, accounts);
        vm.prank(artist);
        VALIDATOR.addAccountsToList(listId, 1, accounts);
        vm.prank(minter);
        t.mint(holder, 1);
        vm.prank(holder);
        t.approve(outsider, 1);
        vm.prank(outsider);
        t.transferFrom(holder, nextArtist, 1);
        assertEq(t.ownerOf(1), nextArtist);
        vm.prank(nextArtist);
        VALIDATOR.applyListToCollection(address(t), 0);
        assertEq(VALIDATOR.getCollectionSecurityPolicy(address(t)).listId, 0);
    }

    function test_mainnet_outsiderCannotChangeRegistry() public {
        vm.prank(outsider);
        vm.expectRevert();
        REGISTRY.setCustodian(outsider, true);
        assertFalse(REGISTRY.isCustody(outsider));
    }
}
