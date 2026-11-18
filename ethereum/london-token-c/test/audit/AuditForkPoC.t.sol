// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Audit proof-of-concept tests against the LIVE Limit Break transfer validator v5 on an Ethereum
// mainnet fork (2026-11-18). Skipped unless ETHEREUM_RPC_URL is set.

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {CustodyRegistry} from "../../src/erc721c/CustodyRegistry.sol";
import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCFactory} from "../../src/erc721c/LondonTokenCFactory.sol";

interface IValidatorV5Audit {
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
    function listOwners(uint48 id) external view returns (address);
    function owner() external view returns (address);
}

contract RoyaltyFreeMarketFork is IERC721Receiver {
    function sell(LondonTokenCBase t, address buyer, uint256 id) external {
        t.transferFrom(address(this), buyer, id);
    }

    function onERC721Received(address, address, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract AuditForkPoC is Test {
    address internal constant VALIDATOR_V5 = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    address internal constant VENLY_CUSTODY = 0xB4B57125AF2aCf9Bf605A9D9C3D256537876f65A;
    address internal constant PAYMENT_PROCESSOR = 0x9A1D00bEd7CD04BCDA516d721A596eb22Aac6834;

    bytes4 internal constant CALLER_OR_FROM_MUST_BE_WHITELISTED = 0xe1f1d02e;
    bytes4 internal constant OTC_NOT_ALLOWED_FOR_7702_DELEGATES = 0x369c2f4c;
    bytes4 internal constant TOKEN_IS_SOULBOUND =
        bytes4(keccak256("CreatorTokenTransferValidator__TokenIsSoulbound()"));
    uint8 internal constant RULESET_DEFAULT = 0;
    uint8 internal constant RULESET_SOULBOUND = 2;
    uint16 internal constant WLO_BLOCK_ALL_OTC = 1 << 0;

    address internal verseSafe = makeAddr("verseSafe");
    address internal artist = makeAddr("artist");
    address internal minter = makeAddr("minter");
    address internal collector = makeAddr("collector");
    address internal recipient = makeAddr("recipient");

    CustodyRegistry internal registry;
    LondonTokenCBase internal token;

    function setUp() public {
        string memory rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1);

        address[] memory initial = new address[](1);
        initial[0] = VENLY_CUSTODY;
        registry = new CustodyRegistry(verseSafe, initial);
        LondonTokenCFactory factory = new LondonTokenCFactory(address(registry));
        token = LondonTokenCBase(
            factory.createCollection("ipfs://base", minter, minter, "Audit 721C", 750, artist)
        );

        vm.startPrank(minter);
        token.mint(VENLY_CUSTODY, 1);
        token.mint(collector, 3);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // F-09 (Informational, product): under the default policy a collector whose EOA carries an
    // EIP-7702 delegation (smart-account wallets) cannot transfer their own token wallet-to-
    // wallet and cannot deposit it into Verse custody. Whitelisted operators can still move it.
    // ---------------------------------------------------------------------
    function test_forkpoc_F09_7702DelegatedCollectorIsStuckOtc() public {
        vm.etch(collector, abi.encodePacked(hex"ef0100", makeAddr("walletDelegate")));

        vm.prank(collector);
        vm.expectRevert(OTC_NOT_ALLOWED_FOR_7702_DELEGATES);
        token.transferFrom(collector, recipient, 3);

        vm.prank(collector);
        vm.expectRevert(OTC_NOT_ALLOWED_FOR_7702_DELEGATES);
        token.safeTransferFrom(collector, VENLY_CUSTODY, 3);

        vm.prank(collector);
        token.setApprovalForAll(PAYMENT_PROCESSOR, true);
        vm.prank(PAYMENT_PROCESSOR);
        token.transferFrom(collector, recipient, 3);
        assertEq(token.ownerOf(3), recipient);
    }

    // ---------------------------------------------------------------------
    // F-10 (Informational, operations): an artist policy that blocks OTC transfers also blocks
    // every deposit INTO Verse custody (the exemption only covers custody moving its own
    // tokens). Withdrawals keep working.
    // ---------------------------------------------------------------------
    function test_forkpoc_F10_blockAllOtcBlocksDepositsIntoCustody() public {
        vm.prank(artist);
        IValidatorV5Audit(VALIDATOR_V5)
            .setRulesetOfCollection(address(token), RULESET_DEFAULT, address(0), 0, WLO_BLOCK_ALL_OTC);

        vm.prank(collector);
        vm.expectRevert(CALLER_OR_FROM_MUST_BE_WHITELISTED);
        token.safeTransferFrom(collector, VENLY_CUSTODY, 3);

        vm.prank(VENLY_CUSTODY);
        token.safeTransferFrom(VENLY_CUSTODY, recipient, 1);
        assertEq(token.ownerOf(1), recipient);
    }

    // ---------------------------------------------------------------------
    // F-01 on the live validator: a contract registered by the Verse Safe trades the tokens it
    // holds with no validator call, even when the artist made the collection soulbound.
    // ---------------------------------------------------------------------
    function test_forkpoc_F01_registeredContractTradesUnderSoulbound() public {
        RoyaltyFreeMarketFork market = new RoyaltyFreeMarketFork();
        vm.prank(collector);
        token.safeTransferFrom(collector, address(market), 3);

        vm.prank(artist);
        IValidatorV5Audit(VALIDATOR_V5)
            .setRulesetOfCollection(address(token), RULESET_SOULBOUND, address(0), 0, 0);

        vm.expectRevert(TOKEN_IS_SOULBOUND);
        market.sell(token, recipient, 3);

        vm.prank(verseSafe);
        registry.setCustodian(address(market), true);
        market.sell(token, recipient, 3);
        assertEq(token.ownerOf(3), recipient);
    }

    // ---------------------------------------------------------------------
    // F-11 (Informational, trust): collections created with `createCollection` run on Limit
    // Break's ruleset 0 and list 0, both owned and mutable by Limit Break, not by the artist.
    // ---------------------------------------------------------------------
    function test_forkpoc_F11_defaultCollectionsFollowLimitBreakOwnedList() public view {
        address listZeroOwner = IValidatorV5Audit(VALIDATOR_V5).listOwners(0);
        address validatorOwner = IValidatorV5Audit(VALIDATOR_V5).owner();
        assertTrue(listZeroOwner != artist && listZeroOwner != address(token));
        assertEq(listZeroOwner, validatorOwner, "default list owned by the validator owner");
    }
}
