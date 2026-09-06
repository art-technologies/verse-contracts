// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CustodialNFTVault} from "../../src/CustodialNFTVault.sol";
import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {MockERC1155} from "../mocks/MockERC1155.sol";
import {MockERC721} from "../mocks/MockERC721.sol";

/// @dev Shared fork smoke drill. Each chain-specific test provides its RPC
///      env var and expected chain ID; the test is skipped when the env var
///      is unset so the suite stays green without network access.
///      Implements the ERC-1155 receiver hooks because setUp mints editions
///      to this contract before depositing them into the vault.
abstract contract ForkSmoke is Test {
    function _rpcEnvVar() internal pure virtual returns (string memory);
    function _expectedChainId() internal pure virtual returns (uint256);

    CustodialNFTVault internal vault;
    MockERC721 internal nft;
    MockERC1155 internal multi;

    address internal admin = makeAddr("forkAdmin");
    address internal manager = makeAddr("forkManager");
    address internal locker = makeAddr("forkLocker");
    address internal recipient = makeAddr("forkRecipient");

    function setUp() public {
        string memory rpc = vm.envOr(_rpcEnvVar(), string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, _expectedChainId(), "unexpected fork chain id");

        address[] memory managers = new address[](1);
        managers[0] = manager;
        address[] memory lockers = new address[](1);
        lockers[0] = locker;

        vault =
            new CustodialNFTVault(admin, managers, lockers, ICustodialNFTVault.Limits(10, 600, 50));

        nft = new MockERC721();
        multi = new MockERC1155();
        for (uint256 i; i < 12; ++i) {
            nft.mint(address(this), i);
        }
        multi.mint(address(this), 0, 100);
    }

    function test_fork_depositWithdrawAndAutoLockDrill() public {
        // Deposit through ordinary safe transfers.
        for (uint256 i; i < 12; ++i) {
            nft.safeTransferFrom(address(this), address(vault), i);
        }
        multi.safeTransferFrom(address(this), address(vault), 0, 100, "");
        assertEq(nft.balanceOf(address(vault)), 12);

        // Withdraw a mixed batch (canonical order across both contracts).
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](3);
        ICustodialNFTVault.WithdrawalItem memory it721a = _item721(0);
        ICustodialNFTVault.WithdrawalItem memory it721b = _item721(1);
        ICustodialNFTVault.WithdrawalItem memory it1155 = _item1155(0, 5);
        if (address(nft) < address(multi)) {
            (items[0], items[1], items[2]) = (it721a, it721b, it1155);
        } else {
            (items[0], items[1], items[2]) = (it1155, it721a, it721b);
        }
        vm.prank(manager);
        assertTrue(vault.withdraw(items));
        assertEq(nft.ownerOf(0), recipient);
        assertEq(multi.balanceOf(recipient, 0), 5);
        assertEq(vault.getRecentWithdrawn(), 3);

        // Fill the exact allowance.
        ICustodialNFTVault.WithdrawalItem[] memory fill = new ICustodialNFTVault.WithdrawalItem[](7);
        for (uint256 i; i < 7; ++i) {
            fill[i] = _item721(2 + i);
        }
        vm.prank(manager);
        assertTrue(vault.withdraw(fill));
        assertEq(vault.getRemainingLimit(), 0);

        // One-over triggers auto-lock without reverting or transferring.
        ICustodialNFTVault.WithdrawalItem[] memory over = new ICustodialNFTVault.WithdrawalItem[](1);
        over[0] = _item721(9);
        vm.prank(manager);
        assertFalse(vault.withdraw(over));
        assertTrue(vault.isLocked());
        assertEq(nft.ownerOf(9), address(vault));

        // Emergency lock path and Safe-style unlock preserve history.
        vm.prank(locker);
        vault.lock();
        vm.prank(admin);
        vault.unlock();
        assertEq(vault.getRecentWithdrawn(), 10, "unlock preserved history");
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] calldata,
        uint256[] calldata,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function _item721(uint256 id) internal view returns (ICustodialNFTVault.WithdrawalItem memory) {
        return ICustodialNFTVault.WithdrawalItem({
            token: address(nft),
            tokenId: id,
            amount: 1,
            recipient: recipient,
            standard: ICustodialNFTVault.TokenStandard.ERC721
        });
    }

    function _item1155(uint256 id, uint256 amount)
        internal
        view
        returns (ICustodialNFTVault.WithdrawalItem memory)
    {
        return ICustodialNFTVault.WithdrawalItem({
            token: address(multi),
            tokenId: id,
            amount: amount,
            recipient: recipient,
            standard: ICustodialNFTVault.TokenStandard.ERC1155
        });
    }
}
