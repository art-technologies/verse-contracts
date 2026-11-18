// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Audit proof-of-concept tests for the LondonTokenC stack (2026-11-18).
// Each test demonstrates one finding from the audit report. They run on the shared unit fixture
// (mock validator etched at the Limit Break default address, one custody EOA registered).

import {stdError} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {OnchainFileStorage} from "../../src/erc721c/OnchainFileStorage.sol";
import {LondonTokenCTestBase} from "../erc721c/LondonTokenCTestBase.sol";
import {OwnerInstalledValidator} from "../erc721c/mocks/OwnerInstalledValidator.sol";

/// @dev A marketplace-style contract: holds deposited tokens and hands them to buyers.
contract RoyaltyFreeMarket is IERC721Receiver {
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

/// @dev A contract with no ERC-721 receiver hook and no way to call the token.
contract NonReceiver {}

contract AuditPoC is LondonTokenCTestBase {
    // ---------------------------------------------------------------------
    // F-01 (Medium, trust): the CustodyRegistry owner can exempt ANY account from the artist's
    // transfer policy and from marketplace royalty enforcement. A registered marketplace-style
    // contract trades the tokens it holds with zero validator involvement, even when the artist
    // has made the collection soulbound.
    // ---------------------------------------------------------------------
    function test_poc_F01_registryOwnerCanExemptAnyContractFromPolicy() public {
        RoyaltyFreeMarket market = new RoyaltyFreeMarket();

        // Collector lists on the market while the policy still allows it.
        vm.prank(collector);
        token.safeTransferFrom(collector, address(market), COLLECTOR_TOKEN);

        // Artist now blocks every transfer (soulbound / block-all).
        validator.setRejectAll(true);
        vm.expectRevert(
            _rejectedError(address(market), address(market), recipient, COLLECTOR_TOKEN)
        );
        market.sell(token, recipient, COLLECTOR_TOKEN);

        // Verse Safe registers the market as a "custody" account.
        vm.prank(verseSafe);
        registry.setCustodian(address(market), true);

        // The sale settles with no validator call at all: policy and enforced royalties bypassed.
        vm.expectCall(
            DEFAULT_VALIDATOR,
            _validateCall(address(market), address(market), recipient, COLLECTOR_TOKEN),
            0
        );
        market.sell(token, recipient, COLLECTOR_TOKEN);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), recipient);
    }

    // ---------------------------------------------------------------------
    // F-02 (Medium, trust): the minting manager (Verse) can mint unlimited token IDs to anyone;
    // mints are never validated and there is no supply cap. The artist's only remedy is to
    // revoke the minter.
    // ---------------------------------------------------------------------
    function test_poc_F02_mintingManagerUnboundedMintBypassesPolicy() public {
        validator.setRejectAll(true); // artist: nothing may move
        uint256 supplyBefore = token.totalSupply();

        vm.startPrank(minter);
        for (uint256 id = 1000; id < 1050; ++id) {
            token.mint(outsider, id);
        }
        vm.stopPrank();

        assertEq(token.totalSupply(), supplyBefore + 50);
        assertEq(token.balanceOf(outsider), 50);

        vm.prank(artist);
        token.setMintingManager(address(0));
        vm.prank(minter);
        vm.expectRevert("Permission denied");
        token.mint(outsider, 2000);
    }

    // ---------------------------------------------------------------------
    // F-03 (Informational, ERC721-C inherent): the artist can freeze every holder at any time,
    // but can never move a holder's or custody's token, with or without a validator.
    // ---------------------------------------------------------------------
    function test_poc_F03_artistCanFreezeHoldersButCannotTakeTokens() public {
        validator.setRejectAll(true);
        vm.prank(collector);
        vm.expectRevert(_rejectedError(collector, collector, recipient, COLLECTOR_TOKEN));
        token.transferFrom(collector, recipient, COLLECTOR_TOKEN);

        // Custody keeps withdrawing.
        vm.prank(custody);
        token.transferFrom(custody, recipient, CUSTODY_TOKEN);
        assertEq(token.ownerOf(CUSTODY_TOKEN), recipient);

        // Artist installs their own validator contract: still no power over tokens.
        OwnerInstalledValidator mine = new OwnerInstalledValidator();
        vm.prank(artist);
        token.setTransferValidator(address(mine));
        vm.expectRevert("ERC721: caller is not token owner or approved");
        mine.pull(token, collector, artist, COLLECTOR_TOKEN);

        vm.prank(artist);
        token.setTransferValidator(address(0));
        vm.prank(artist);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        token.transferFrom(collector, artist, COLLECTOR_TOKEN);
    }

    // ---------------------------------------------------------------------
    // F-04 (Low): OnchainFileStorage accepts a file with an empty pointer list. The name is
    // pushed to `_files` but the existence check keys on the pointer array, so the same name
    // can be added repeatedly and never removed.
    // ---------------------------------------------------------------------
    function test_poc_F04_fileStorageEmptyPointerListLeavesUnremovableDuplicates() public {
        address[] memory none;
        vm.startPrank(artist);
        token.addFile("p5.min.js", none);
        token.addFile("p5.min.js", none);
        vm.stopPrank();

        string[] memory names = token.files();
        assertEq(names.length, 2);
        assertEq(names[0], "p5.min.js");
        assertEq(names[1], "p5.min.js");

        vm.prank(artist);
        vm.expectRevert(OnchainFileStorage.FileNotRegistered.selector);
        token.removeFile("p5.min.js");
    }

    /// @dev Companion: a pointer without code makes `fileContents` panic (underflow) instead of
    ///      returning a clean error.
    function test_poc_F04b_fileContentsPanicsForPointerWithoutCode() public {
        address[] memory ptrs = new address[](1);
        ptrs[0] = makeAddr("notAnSSTORE2Pointer");
        vm.prank(artist);
        token.addFile("sketch.js", ptrs);

        vm.expectRevert(stdError.arithmeticError);
        token.fileContents("sketch.js");
    }

    // ---------------------------------------------------------------------
    // F-05 (Low): mints skip the ERC-721 receiver check, so a token minted to a contract that
    // cannot handle NFTs is stranded forever.
    // ---------------------------------------------------------------------
    function test_poc_F05_mintToContractWithoutReceiverStrandsToken() public {
        NonReceiver sink = new NonReceiver();
        vm.prank(minter);
        token.mint(address(sink), 77);
        assertEq(token.ownerOf(77), address(sink));

        // Nobody, not even the artist, can move it.
        vm.prank(artist);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        token.transferFrom(address(sink), artist, 77);
    }

    // ---------------------------------------------------------------------
    // F-06 (Low): the royalty recipient is not validated; address(0) is accepted and reported
    // through ERC-2981.
    // ---------------------------------------------------------------------
    function test_poc_F06_royaltyRecipientCanBeZero() public {
        vm.prank(artist);
        token.setRoyalties(address(0), 1000);
        (address receiver, uint256 amount) = token.royaltyInfo(COLLECTOR_TOKEN, 1 ether);
        assertEq(receiver, address(0));
        assertEq(amount, 0.1 ether);
    }

    // ---------------------------------------------------------------------
    // F-07 (Low): the factory is permissionless. Anyone can deploy a collection that names a
    // real artist as owner, reuses their collection name, and mints under it. Off-chain systems
    // must not treat `NewCollection` alone as proof of a Studio deployment.
    // ---------------------------------------------------------------------
    function test_poc_F07_anyoneCanDeployCollectionInArtistsName() public {
        vm.prank(outsider);
        LondonTokenCBase fake = LondonTokenCBase(
            factory.createCollection("ipfs://fake", outsider, outsider, token.name(), 1000, artist)
        );
        assertEq(fake.owner(), artist);
        assertEq(fake.name(), token.name());
        assertEq(fake.mintingManager(), outsider);

        vm.prank(outsider);
        fake.mint(collector, 1);
        assertEq(fake.ownerOf(1), collector);
    }

    // ---------------------------------------------------------------------
    // F-08 (Low, design trade-off): a compromised custody account cannot be stopped by the
    // artist's policy (freeze / soulbound). Only the registry owner can cut it off, which also
    // stops legitimate withdrawals.
    // ---------------------------------------------------------------------
    function test_poc_F08_artistPolicyCannotStopCompromisedCustodyAccount() public {
        address thief = makeAddr("thief");
        validator.setRejectAll(true); // artist freezes the collection

        vm.prank(custody); // attacker holding the custody key
        token.transferFrom(custody, thief, CUSTODY_TOKEN);
        assertEq(token.ownerOf(CUSTODY_TOKEN), thief);

        vm.prank(minter);
        token.mint(custody, 3);
        vm.prank(verseSafe);
        registry.setCustodian(custody, false);
        vm.prank(custody);
        vm.expectRevert(_rejectedError(custody, custody, thief, 3));
        token.transferFrom(custody, thief, 3);
    }

    // ---------------------------------------------------------------------
    // Invariant-style fuzz: no caller that is neither owner nor approved can move a holder's
    // token, even if that caller is simultaneously the installed validator and a registered
    // custody account.
    // ---------------------------------------------------------------------
    function testFuzz_poc_noUnapprovedCallerCanMoveHolderToken(address caller) public {
        vm.assume(caller != collector && caller != address(0));
        vm.assume(
            caller != address(token) && caller != address(registry) && caller != address(factory)
                && caller != DEFAULT_VALIDATOR
        );
        assumeNotPrecompile(caller);
        assumeNotForgeAddress(caller);

        if (!registry.isCustody(caller)) {
            vm.prank(verseSafe);
            registry.setCustodian(caller, true);
        }
        vm.etch(caller, address(new OwnerInstalledValidator()).code);
        vm.prank(artist);
        token.setTransferValidator(caller);

        vm.prank(caller);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        token.transferFrom(collector, caller, COLLECTOR_TOKEN);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), collector);
    }
}
