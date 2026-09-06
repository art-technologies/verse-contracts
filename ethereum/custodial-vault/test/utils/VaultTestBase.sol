// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {CustodialNFTVault} from "../../src/CustodialNFTVault.sol";
import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// @dev Shared fixture: a vault with one owner ("admin"), two managers, one
///      emergency locker, permissive default limits, unpaused and pre-funded
///      with NFTs.
abstract contract VaultTestBase is Test {
    CustodialNFTVault internal vault;
    MockERC721 internal nft;
    MockERC1155 internal multi;

    address internal admin = makeAddr("admin");
    address internal manager1 = address(uint160(0xA1));
    address internal manager2 = address(uint160(0xA2));
    address internal locker1 = address(uint160(0xE1));
    address internal outsider = makeAddr("outsider");
    address internal recipient = makeAddr("recipient");

    uint16 internal constant DEFAULT_MAX_TOKENS = 100;
    uint32 internal constant DEFAULT_PERIOD = 1 days;
    uint8 internal constant DEFAULT_MAX_ITEMS = 50;

    function setUp() public virtual {
        // Keep timestamps far above the maximum period so cutoff clamping
        // never engages by accident.
        vm.warp(90 days);

        vault = _deployVault(
            admin,
            _managers2(),
            _lockers1(),
            ICustodialNFTVault.Limits(DEFAULT_MAX_TOKENS, DEFAULT_PERIOD, DEFAULT_MAX_ITEMS)
        );

        nft = new MockERC721();
        multi = new MockERC1155();

        // Seed custody: ERC-721 ids 0..199, ERC-1155 ids 0..49 with 100 units.
        for (uint256 i; i < 200; ++i) {
            nft.mint(address(vault), i);
        }
        for (uint256 i; i < 50; ++i) {
            multi.mint(address(vault), i, 100);
        }
    }

    /// @dev Deploys the vault under test; overridden by suites that target
    ///      an extension vault (e.g. {CustodialNFTVaultWithPunks}) so all
    ///      inherited base behavior runs against the extension too.
    function _deployVault(
        address owner,
        address[] memory managers,
        address[] memory lockers,
        ICustodialNFTVault.Limits memory limits
    ) internal virtual returns (CustodialNFTVault) {
        return new CustodialNFTVault(owner, managers, lockers, limits);
    }

    // -------------------------------------------------------------------
    // Role array helpers (strictly ascending)
    // -------------------------------------------------------------------

    function _managers2() internal view returns (address[] memory arr) {
        arr = new address[](2);
        (arr[0], arr[1]) = manager1 < manager2 ? (manager1, manager2) : (manager2, manager1);
    }

    function _lockers1() internal view returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = locker1;
    }

    function _single(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    // -------------------------------------------------------------------
    // Item helpers
    // -------------------------------------------------------------------

    function _item721(uint256 tokenId, address to)
        internal
        view
        returns (ICustodialNFTVault.WithdrawalItem memory)
    {
        return ICustodialNFTVault.WithdrawalItem({
            token: address(nft),
            tokenId: tokenId,
            amount: 1,
            recipient: to,
            standard: ICustodialNFTVault.TokenStandard.ERC721
        });
    }

    function _item1155(uint256 tokenId, uint256 amount, address to)
        internal
        view
        returns (ICustodialNFTVault.WithdrawalItem memory)
    {
        return ICustodialNFTVault.WithdrawalItem({
            token: address(multi),
            tokenId: tokenId,
            amount: amount,
            recipient: to,
            standard: ICustodialNFTVault.TokenStandard.ERC1155
        });
    }

    /// @dev Batch of `count` distinct ERC-721 items with ids
    ///      [startId, startId + count), already sorted.
    function _batch721(uint256 startId, uint256 count)
        internal
        view
        returns (ICustodialNFTVault.WithdrawalItem[] memory items)
    {
        items = new ICustodialNFTVault.WithdrawalItem[](count);
        for (uint256 i; i < count; ++i) {
            items[i] = _item721(startId + i, recipient);
        }
    }

    function _withdrawAs(address caller, ICustodialNFTVault.WithdrawalItem[] memory items)
        internal
        returns (bool executed)
    {
        vm.prank(caller);
        executed = vault.withdraw(_toCalldata(items));
    }

    /// @dev Identity helper; memory arrays are passed as calldata by the
    ///      external call boundary.
    function _toCalldata(ICustodialNFTVault.WithdrawalItem[] memory items)
        internal
        pure
        returns (ICustodialNFTVault.WithdrawalItem[] memory)
    {
        return items;
    }

    function _used() internal view returns (uint256) {
        return vault.getRecentWithdrawn();
    }

    // -------------------------------------------------------------------
    // OZ error expectation helpers
    // -------------------------------------------------------------------

    function _expectNotOwner(address caller) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
    }

    function _expectEnforcedPause() internal {
        vm.expectRevert(Pausable.EnforcedPause.selector);
    }

    function _expectExpectedPause() internal {
        vm.expectRevert(Pausable.ExpectedPause.selector);
    }
}
