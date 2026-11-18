// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LondonTokenCTestBase} from "./LondonTokenCTestBase.sol";
import {OnchainFileStorage} from "../../src/erc721c/OnchainFileStorage.sol";

/// @dev PoCs for the 2026-11-18 audit findings (see audit report): each test demonstrates a
///      documented finding against the audited source. No test requires an attacker: these are
///      artist/minter error or inherited-London behaviour PoCs.
contract AuditPoc is LondonTokenCTestBase {
    // ------------------------------------------------------------------
    // F-01 (Low): collection ownership transfer is one-step. A mistyped
    // `transferOwnership` address instantly and irreversibly hands over
    // admin control of the collection (metadata, royalties, validator).
    // ------------------------------------------------------------------
    function test_poc_ownershipTransfer_isOneStep() public {
        address wrongAddress = makeAddr("artistTypo");

        vm.prank(artist);
        token.transferOwnership(wrongAddress);

        // Ownership moved immediately; the new address never has to accept,
        // and a typo'd EOA never can give it back. Note there is no
        // pendingOwner()/acceptOwnership() on the collection at all.
        assertEq(token.owner(), wrongAddress);
    }

    // ------------------------------------------------------------------
    // F-02 (Low): no supply cap. The mintingManager can mint an unlimited
    // number of tokens; a compromised minter key inflates supply at will.
    // ------------------------------------------------------------------
    function test_poc_minting_isUncapped() public {
        uint256 supplyBefore = token.totalSupply();

        vm.startPrank(minter);
        for (uint256 i = 1000; i < 1100; ++i) {
            token.mint(collector, i);
        }
        vm.stopPrank();

        assertEq(token.totalSupply(), supplyBefore + 100);
        // No constant or check bounds totalSupply; nothing reverts at any size.
    }

    // ------------------------------------------------------------------
    // F-03 (Info): OnchainFileStorage.addFile with an empty address array
    // registers a "phantom" file: listed by files(), but unremovable
    // (removeFile reverts FileNotRegistered) and re-addable, duplicating
    // the name. Inherited unchanged from London.
    // ------------------------------------------------------------------
    function test_poc_addFile_emptyArray_makesStuckPhantomEntry() public {
        address[] memory none = new address[](0);

        vm.startPrank(artist);
        token.addFile("phantom", none);

        // Listed by files()...
        string[] memory names = token.files();
        assertEq(names.length, 1, "phantom appears in files()");
        assertEq(names[0], "phantom");

        // ...but any read of its storage reverts.
        vm.expectRevert(OnchainFileStorage.FileNotRegistered.selector);
        token.fileStorage("phantom");

        // The artist cannot remove it: the guard treats it as never registered.
        vm.expectRevert(OnchainFileStorage.FileNotRegistered.selector);
        token.removeFile("phantom");

        // Re-adding the same name succeeds and duplicates the listing.
        token.addFile("phantom", none);
        assertEq(token.files().length, 2, "duplicate phantom in files()");
        vm.stopPrank();
    }
}
