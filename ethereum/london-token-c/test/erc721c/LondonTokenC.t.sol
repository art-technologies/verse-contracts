// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Metadata} from "@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {LondonERC721} from "../../src/erc721c/LondonERC721.sol";
import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCFactory} from "../../src/erc721c/LondonTokenCFactory.sol";
import {ICreatorToken} from "../../src/erc721c/vendor/limitbreak/interfaces/ICreatorToken.sol";
import {
    ICreatorTokenLegacy
} from "../../src/erc721c/vendor/limitbreak/interfaces/ICreatorTokenLegacy.sol";
import {LondonTokenCTestBase} from "./LondonTokenCTestBase.sol";
import {MisbehavingCustodyRegistry} from "./mocks/MisbehavingCustodyRegistry.sol";
import {OwnerInstalledValidator} from "./mocks/OwnerInstalledValidator.sol";

contract LondonTokenCTest is LondonTokenCTestBase {
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event TransferValidatorUpdated(address oldValidator, address newValidator);

    // ---------------------------------------------------------------------
    // Initialization
    // ---------------------------------------------------------------------

    function test_initialize_setsLondonState() public view {
        assertEq(token.name(), "Collection by Artist");
        assertEq(token._name(), "Collection by Artist");
        assertEq(token.symbol(), "VERSE");
        assertEq(token.owner(), artist);
        assertEq(token.creator(), artist);
        assertEq(token.mintingManager(), minter);
        assertEq(token.gatewayManager(), gateway);
        assertEq(token._baseUri(), "ipfs://base");
        assertEq(token.getTransferValidator(), DEFAULT_VALIDATOR);
        assertEq(address(token.custodyRegistry()), address(registry));
        (address receiver, uint256 amount) = token.royaltyInfo(CUSTODY_TOKEN, 10_000);
        assertEq(receiver, artist);
        assertEq(amount, ROYALTY_BPS);
    }

    function test_initialize_emitsDefaultValidatorAndRegistersTokenType() public {
        vm.expectEmit(false, false, false, true);
        emit TransferValidatorUpdated(address(0), DEFAULT_VALIDATOR);
        LondonTokenCBase fresh = _createCollection(factory, "Fresh");
        assertEq(validator.tokenTypeOf(address(fresh)), 721);
    }

    function test_initialize_revertsWhenCalledAgain() public {
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        token.initialize("x", outsider, outsider, "Hijack", 0, outsider);
    }

    /// London's guard was `bytes(_name).length == 0`, so an empty name left a clone re-initializable.
    function test_initialize_emptyNameCannotBeReinitialized() public {
        LondonTokenCBase unnamed = _createCollection(factory, "");
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        unnamed.initialize("x", outsider, outsider, "Hijack", 0, outsider);

        vm.prank(artist);
        token.setCollectionName("");
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        token.initialize("x", outsider, outsider, "Hijack", 0, outsider);
    }

    function test_implementation_isLocked() public {
        LondonTokenCBase implementation = LondonTokenCBase(factory.tokenImplementation());
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        implementation.initialize("x", outsider, outsider, "Hijack", 0, outsider);
    }

    function test_initialize_revertsZeroOwner() public {
        vm.expectRevert(LondonTokenCBase.ZeroOwner.selector);
        factory.createCollection("ipfs://base", minter, gateway, "Name", ROYALTY_BPS, address(0));
    }

    function test_initialize_royaltyCap() public {
        LondonTokenCBase atCap =
            LondonTokenCBase(factory.createCollection("u", minter, gateway, "Cap", 1000, artist));
        (, uint256 amount) = atCap.royaltyInfo(1, 1 ether);
        assertEq(amount, 0.1 ether);

        vm.expectRevert(
            abi.encodeWithSelector(LondonTokenCBase.RoyaltyTooHigh.selector, 1001, 1000)
        );
        factory.createCollection("u", minter, gateway, "Over", 1001, artist);
    }

    // ---------------------------------------------------------------------
    // Minting (London parity)
    // ---------------------------------------------------------------------

    function test_mint_emitsLondonTransferPairAndIsNotValidated() public {
        validator.setRejectAll(true);
        vm.expectCall(DEFAULT_VALIDATOR, abi.encodePacked(VALIDATE_TRANSFER_SELECTOR), 0);

        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(address(0), artist, 7);
        vm.expectEmit(true, true, true, true, address(token));
        emit Transfer(artist, recipient, 7);
        vm.prank(minter);
        token.mint(recipient, 7);

        assertEq(token.ownerOf(7), recipient);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token._owners(7), recipient);
        assertEq(token._balances(recipient), 1);
        assertEq(token.totalSupply(), 3);
    }

    function test_mint_onlyMinter() public {
        vm.prank(outsider);
        vm.expectRevert(bytes("Permission denied"));
        token.mint(outsider, 9);
    }

    function test_mint_rejectsZeroRecipientAndDuplicate() public {
        vm.startPrank(minter);
        vm.expectRevert(bytes("mint to the zero address"));
        token.mint(address(0), 9);
        vm.expectRevert(bytes("ERC721: token already minted"));
        token.mint(recipient, CUSTODY_TOKEN);
        vm.stopPrank();
    }

    function test_mintWithPayload_storesPayload() public {
        vm.prank(minter);
        token.mintWithPayload(recipient, 9, "seed=42");
        assertEq(token.getPayload(9), "seed=42");
        assertEq(token._payloads(9), "seed=42");
    }

    function test_mintBatch_andWithPayload() public {
        address[] memory to = new address[](2);
        to[0] = recipient;
        to[1] = custody;
        uint256[] memory ids = new uint256[](2);
        ids[0] = 10;
        ids[1] = 11;
        string[] memory payloads = new string[](2);
        payloads[0] = "a";
        payloads[1] = "b";

        vm.startPrank(minter);
        token.mintBatch(to, ids);
        ids[0] = 12;
        ids[1] = 13;
        token.mintBatchWithPayload(to, ids, payloads);
        vm.stopPrank();

        assertEq(token.ownerOf(10), recipient);
        assertEq(token.ownerOf(11), custody);
        assertEq(token.getPayload(12), "a");
        assertEq(token.getPayload(13), "b");
        assertEq(token.totalSupply(), 6);
    }

    function test_mintBatch_lengthMismatch() public {
        address[] memory to = new address[](2);
        to[0] = recipient;
        to[1] = recipient;
        uint256[] memory ids = new uint256[](1);
        ids[0] = 10;
        string[] memory payloads = new string[](1);
        payloads[0] = "a";
        uint256[] memory twoIds = new uint256[](2);
        twoIds[0] = 20;
        twoIds[1] = 21;

        vm.startPrank(minter);
        vm.expectRevert(bytes("Arrays length mismatch"));
        token.mintBatch(to, ids);
        vm.expectRevert(bytes("Arrays length mismatch"));
        token.mintBatchWithPayload(to, twoIds, payloads);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Owner / gateway roles
    // ---------------------------------------------------------------------

    function test_ownerSetters_onlyOwner() public {
        bytes memory unauthorized =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, outsider);
        vm.startPrank(outsider);
        vm.expectRevert(unauthorized);
        token.setArtistName("x");
        vm.expectRevert(unauthorized);
        token.setCollectionName("x");
        vm.expectRevert(unauthorized);
        token.setDescription("x");
        vm.expectRevert(unauthorized);
        token.setYear("x");
        vm.expectRevert(unauthorized);
        token.setLicense("x");
        vm.expectRevert(unauthorized);
        token.setPayload(1, "x");
        vm.expectRevert(unauthorized);
        token.setRoyalties(outsider, 100);
        vm.expectRevert(unauthorized);
        token.setMintingManager(outsider);
        vm.expectRevert(unauthorized);
        token.setGatewayManager(outsider);
        vm.expectRevert(unauthorized);
        token.setTransferValidator(address(0));
        vm.expectRevert(unauthorized);
        token.addFile("f", new address[](1));
        vm.stopPrank();
    }

    function test_ownerSetters_update() public {
        vm.startPrank(artist);
        token.setArtistName("Artist");
        token.setCollectionName("Renamed");
        token.setDescription("Desc");
        token.setYear("2026");
        token.setLicense("CC0");
        token.setPayload(1, "p");
        vm.expectEmit(true, true, false, false, address(token));
        emit LondonTokenCBase.MintingManagerUpdated(minter, outsider);
        token.setMintingManager(outsider);
        vm.expectEmit(true, true, false, false, address(token));
        emit LondonTokenCBase.GatewayManagerUpdated(gateway, outsider);
        token.setGatewayManager(outsider);
        vm.stopPrank();

        assertEq(token.artistName(), "Artist");
        assertEq(token.name(), "Renamed");
        assertEq(token.projectDescription(), "Desc");
        assertEq(token.year(), "2026");
        assertEq(token.license(), "CC0");
        assertEq(token.getPayload(1), "p");
        assertEq(token.mintingManager(), outsider);
        assertEq(token.gatewayManager(), outsider);
    }

    function test_setRoyalties_capAndUpdate() public {
        vm.startPrank(artist);
        token.setRoyalties(recipient, 1000);
        vm.expectRevert(
            abi.encodeWithSelector(LondonTokenCBase.RoyaltyTooHigh.selector, 1001, 1000)
        );
        token.setRoyalties(recipient, 1001);
        vm.stopPrank();
        (address receiver, uint256 amount) = token.royaltyInfo(1, 2 ether);
        assertEq(receiver, recipient);
        assertEq(amount, 0.2 ether);
    }

    function test_setURI_onlyGatewayManager() public {
        vm.prank(artist);
        vm.expectRevert(bytes("Permission denied"));
        token.setURI("ipfs://new");

        vm.expectEmit(false, false, false, true, address(token));
        emit LondonERC721.MetadataUpdate(type(uint256).max);
        vm.prank(gateway);
        token.setURI("ipfs://new");
        assertEq(token.tokenURI(CUSTODY_TOKEN), "ipfs://new/1");
    }

    // ---------------------------------------------------------------------
    // Interfaces
    // ---------------------------------------------------------------------

    function test_supportsInterface() public view {
        assertTrue(token.supportsInterface(type(IERC165).interfaceId));
        assertTrue(token.supportsInterface(type(IERC721).interfaceId));
        assertTrue(token.supportsInterface(type(IERC721Metadata).interfaceId));
        assertTrue(token.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(token.supportsInterface(type(ICreatorToken).interfaceId));
        assertTrue(token.supportsInterface(type(ICreatorTokenLegacy).interfaceId));
        assertTrue(token.supportsInterface(0x2a55205a)); // ERC-2981
        assertFalse(token.supportsInterface(0xffffffff));
    }

    function test_getTransferValidationFunction() public view {
        (bytes4 selector, bool isView) = token.getTransferValidationFunction();
        assertEq(selector, bytes4(0xcaee23ea));
        assertTrue(isView);
    }

    // ---------------------------------------------------------------------
    // ERC721-C validation and the custody exemption
    // ---------------------------------------------------------------------

    function test_ownerTransfer_isValidatedWithOwnerAsCaller() public {
        vm.expectCall(
            DEFAULT_VALIDATOR, _validateCall(collector, collector, recipient, COLLECTOR_TOKEN), 1
        );
        vm.prank(collector);
        token.transferFrom(collector, recipient, COLLECTOR_TOKEN);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), recipient);
    }

    function test_ownerTransfer_revertsWhenValidatorRejects() public {
        validator.setRejectAll(true);
        vm.prank(collector);
        vm.expectRevert(_rejectedError(collector, collector, recipient, COLLECTOR_TOKEN));
        token.transferFrom(collector, recipient, COLLECTOR_TOKEN);
    }

    function test_operatorTransfer_isValidatedWithOperatorAsCaller() public {
        vm.prank(collector);
        token.setApprovalForAll(operator, true);
        vm.expectCall(
            DEFAULT_VALIDATOR, _validateCall(operator, collector, recipient, COLLECTOR_TOKEN), 1
        );
        vm.prank(operator);
        token.safeTransferFrom(collector, recipient, COLLECTOR_TOKEN);
    }

    function test_custodyOwnTransfer_skipsValidator() public {
        validator.setRejectAll(true);
        vm.expectCall(DEFAULT_VALIDATOR, abi.encodePacked(VALIDATE_TRANSFER_SELECTOR), 0);
        vm.prank(custody);
        token.safeTransferFrom(custody, recipient, CUSTODY_TOKEN);
        assertEq(token.ownerOf(CUSTODY_TOKEN), recipient);
        assertTrue(token.isVerseCustody(custody));
    }

    function test_custodyOwnTransfer_transferFromAlsoExempt() public {
        validator.setRejectAll(true);
        vm.prank(custody);
        token.transferFrom(custody, recipient, CUSTODY_TOKEN);
        assertEq(token.ownerOf(CUSTODY_TOKEN), recipient);
    }

    function test_operatorMovingCustodyToken_isValidated() public {
        vm.prank(custody);
        token.setApprovalForAll(operator, true);
        validator.setRejectAll(true);
        vm.prank(operator);
        vm.expectRevert(_rejectedError(operator, custody, recipient, CUSTODY_TOKEN));
        token.transferFrom(custody, recipient, CUSTODY_TOKEN);
    }

    function test_depositIntoCustody_isValidated() public {
        validator.setRejectAll(true);
        vm.prank(collector);
        vm.expectRevert(_rejectedError(collector, collector, custody, COLLECTOR_TOKEN));
        token.transferFrom(collector, custody, COLLECTOR_TOKEN);
    }

    function test_custodyRemoved_isValidatedAgain() public {
        vm.prank(verseSafe);
        registry.setCustodian(custody, false);
        validator.setRejectAll(true);
        vm.prank(custody);
        vm.expectRevert(_rejectedError(custody, custody, recipient, CUSTODY_TOKEN));
        token.transferFrom(custody, recipient, CUSTODY_TOKEN);
    }

    /// A custody account registered after deployment is exempt on existing collections.
    function test_custodyAddedLater_appliesToExistingCollections() public {
        address futureVault = makeAddr("futureVault");
        vm.prank(collector);
        token.transferFrom(collector, futureVault, COLLECTOR_TOKEN);

        validator.setRejectAll(true);
        vm.prank(futureVault);
        vm.expectRevert(_rejectedError(futureVault, futureVault, recipient, COLLECTOR_TOKEN));
        token.transferFrom(futureVault, recipient, COLLECTOR_TOKEN);

        vm.prank(verseSafe);
        registry.setCustodian(futureVault, true);
        vm.prank(futureVault);
        token.transferFrom(futureVault, recipient, COLLECTOR_TOKEN);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), recipient);
    }

    function test_validatorDisabledByOwner_allowsTransfers() public {
        vm.prank(artist);
        token.setTransferValidator(address(0));
        assertEq(token.getTransferValidator(), address(0));
        validator.setRejectAll(true);
        vm.prank(collector);
        token.transferFrom(collector, recipient, COLLECTOR_TOKEN);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), recipient);
    }

    /// Review P1: with Limit Break's validator auto-approval, an owner-installed validator could
    /// move holders' and custody tokens without approval. LondonTokenC has no auto-approval, so a
    /// validator only allows or blocks transfers.
    function test_ownerInstalledValidator_cannotMoveHoldersOrCustodyTokens() public {
        OwnerInstalledValidator rogue = new OwnerInstalledValidator();
        vm.prank(artist);
        token.setTransferValidator(address(rogue));

        assertFalse(token.isApprovedForAll(collector, address(rogue)));
        assertFalse(token.isApprovedForAll(custody, address(rogue)));
        vm.expectRevert(bytes("ERC721: caller is not token owner or approved"));
        rogue.pull(token, collector, outsider, COLLECTOR_TOKEN);
        vm.expectRevert(bytes("ERC721: caller is not token owner or approved"));
        rogue.pull(token, custody, outsider, CUSTODY_TOKEN);

        // The opt-in switch from Limit Break's ERC721C does not exist on this contract.
        (bool ok,) = address(token)
            .call(
                abi.encodeWithSignature("setAutomaticApprovalOfTransfersFromValidator(bool)", true)
            );
        assertFalse(ok);

        // Standard ERC-721 semantics remain: a holder can still approve any operator explicitly.
        vm.prank(collector);
        token.setApprovalForAll(address(rogue), true);
        rogue.pull(token, collector, recipient, COLLECTOR_TOKEN);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), recipient);
    }

    function testFuzz_nonCustodyOwner_alwaysValidated(address holder) public {
        vm.assume(holder != address(0) && holder != custody && holder != collector);
        vm.assume(holder.code.length == 0);
        vm.prank(minter);
        token.mint(holder, 99);
        validator.setRejectAll(true);
        vm.prank(holder);
        vm.expectRevert(_rejectedError(holder, holder, recipient, 99));
        token.transferFrom(holder, recipient, 99);
    }

    // ---------------------------------------------------------------------
    // Registry failure modes: never exempt, never revert because of the registry
    // ---------------------------------------------------------------------

    function test_registryFailures_fallBackToValidation() public {
        address[4] memory registries = [
            address(new MisbehavingCustodyRegistry(MisbehavingCustodyRegistry.Mode.Revert)),
            address(new MisbehavingCustodyRegistry(MisbehavingCustodyRegistry.Mode.ReturnTwo)),
            address(new MisbehavingCustodyRegistry(MisbehavingCustodyRegistry.Mode.ReturnShort)),
            makeAddr("registryWithoutCode")
        ];
        for (uint256 i; i < registries.length; ++i) {
            _assertCustodyNotExempt(new LondonTokenCFactory(registries[i]));
        }
        _assertCustodyNotExempt(new LondonTokenCFactory(address(0)));
    }

    function _assertCustodyNotExempt(LondonTokenCFactory f) private {
        validator.setRejectAll(false);
        LondonTokenCBase c = _createCollection(f, "Edge");
        vm.prank(minter);
        c.mint(custody, 5);
        assertFalse(c.isVerseCustody(custody));

        validator.setRejectAll(true);
        vm.prank(custody);
        vm.expectRevert(_rejectedError(custody, custody, recipient, 5));
        c.transferFrom(custody, recipient, 5);
    }
}
