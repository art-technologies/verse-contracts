// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {ForceSend, ReentrantNativeRecipient} from "../mocks/ForceSend.sol";
import {MaliciousToken} from "../mocks/MaliciousToken.sol";
import {FalseReturnERC20, MockERC20, NoReturnERC20} from "../mocks/MockERC20.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev ERC-20 and native rescue behavior (§22.7) including reentrancy and
///      hybrid-token boundaries. Native rescue uses Address.sendValue, so
///      failures bubble the recipient's revert data or Errors.FailedCall.
contract RescueTest is VaultTestBase {
    MockERC20 internal erc20;

    function setUp() public override {
        super.setUp();
        erc20 = new MockERC20();
        erc20.mint(address(vault), 1000);
    }

    // -------------------------------------------------------------------
    // ERC-20 rescue
    // -------------------------------------------------------------------

    function test_erc20RescueWhileUnlockedAndLocked() public {
        vm.prank(admin);
        vault.rescueERC20(address(erc20), recipient, 400);
        assertEq(erc20.balanceOf(recipient), 400);

        vm.prank(locker1);
        vault.lock();
        vm.prank(admin);
        vault.rescueERC20(address(erc20), recipient, 600);
        assertEq(erc20.balanceOf(recipient), 1000);
    }

    function test_erc20RescueEmitsEvent() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit ICustodialNFTVault.ERC20Rescued(address(erc20), recipient, 5);
        vm.prank(admin);
        vault.rescueERC20(address(erc20), recipient, 5);
    }

    function test_erc20RescueZeroAddressesRevert() public {
        vm.startPrank(admin);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ZeroTokenAddress.selector, 0));
        vault.rescueERC20(address(0), recipient, 1);
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ZeroRecipientAddress.selector, 0));
        vault.rescueERC20(address(erc20), address(0), 1);
        vm.stopPrank();
    }

    function test_noReturnValueErc20IsHandled() public {
        NoReturnERC20 usdtLike = new NoReturnERC20();
        usdtLike.mint(address(vault), 100);
        vm.prank(admin);
        vault.rescueERC20(address(usdtLike), recipient, 100);
        assertEq(usdtLike.balanceOf(recipient), 100);
    }

    function test_falseReturningErc20Reverts() public {
        FalseReturnERC20 broken = new FalseReturnERC20();
        vm.expectRevert();
        vm.prank(admin);
        vault.rescueERC20(address(broken), recipient, 1);
    }

    function test_erc20RescueCannotMoveStandardNFTs() public {
        // Standard ERC-721 and ERC-1155 contracts expose no
        // `transfer(address,uint256)`; the rescue call must revert and the
        // assets must stay in custody.
        vm.startPrank(admin);
        vm.expectRevert();
        vault.rescueERC20(address(nft), recipient, 1);
        vm.expectRevert();
        vault.rescueERC20(address(multi), recipient, 1);
        vm.stopPrank();

        assertEq(nft.ownerOf(0), address(vault));
        assertEq(multi.balanceOf(address(vault), 0), 100);
    }

    function test_erc20RescueReentrancyBlocked() public {
        MaliciousToken hostile = new MaliciousToken();
        hostile.arm(
            address(vault),
            abi.encodeCall(ICustodialNFTVault.rescueERC20, (address(erc20), recipient, 1))
        );

        vm.prank(admin);
        vault.rescueERC20(address(hostile), recipient, 1);

        assertTrue(hostile.reentryAttempted());
        assertFalse(hostile.reentrySucceeded(), "reentrant rescue must be blocked");
    }

    // -------------------------------------------------------------------
    // Native currency
    // -------------------------------------------------------------------

    function test_ordinaryNativeTransferReverts() public {
        vm.deal(outsider, 1 ether);
        vm.expectRevert(ICustodialNFTVault.DirectNativeTransferRejected.selector);
        vm.prank(outsider);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        ok;
        assertEq(address(vault).balance, 0);
    }

    function test_unknownSelectorReverts() public {
        vm.expectRevert(ICustodialNFTVault.UnknownCall.selector);
        vm.prank(outsider);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("doesNotExist()"));
        ok;
    }

    function test_forcedNativeCanBeRescued() public {
        ForceSend bomb = new ForceSend{value: 3 ether}();
        bomb.boom(payable(address(vault)));
        assertEq(address(vault).balance, 3 ether, "forced native currency arrives");

        vm.prank(locker1);
        vault.lock();

        vm.expectEmit(true, false, false, true, address(vault));
        emit ICustodialNFTVault.NativeRescued(recipient, 3 ether);
        vm.prank(admin);
        vault.rescueNative(payable(recipient), 3 ether);
        assertEq(recipient.balance, 3 ether);
        assertEq(address(vault).balance, 0);
    }

    function test_nativeRescueZeroRecipientReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ZeroRecipientAddress.selector, 0));
        vm.prank(admin);
        vault.rescueNative(payable(address(0)), 0);
    }

    function test_nativeRescueInsufficientBalanceReverts() public {
        // Address.sendValue pre-checks the vault balance.
        vm.expectRevert(abi.encodeWithSelector(Errors.InsufficientBalance.selector, 0, 1 ether));
        vm.prank(admin);
        vault.rescueNative(payable(recipient), 1 ether);
    }

    function test_nativeRescueFailureBubblesFailedCall() public {
        vm.deal(address(vault), 1 ether);
        // This test contract has no receive function, so the value transfer
        // fails with empty returndata -> Errors.FailedCall.
        vm.expectRevert(Errors.FailedCall.selector);
        vm.prank(admin);
        vault.rescueNative(payable(address(this)), 1 ether);
    }

    function test_nativeRescueReentrancyBlocked() public {
        ReentrantNativeRecipient hostile = new ReentrantNativeRecipient();
        hostile.arm(
            address(vault),
            abi.encodeCall(ICustodialNFTVault.rescueNative, (payable(address(hostile)), 1))
        );

        vm.deal(address(vault), 1 ether);
        vm.prank(admin);
        vault.rescueNative(payable(address(hostile)), 0.5 ether);

        assertTrue(hostile.reentryAttempted());
        assertFalse(hostile.reentrySucceeded(), "reentrant native rescue must be blocked");
        assertEq(address(hostile).balance, 0.5 ether);
    }

    /// @dev This test contract has no receive function, so it rejects the
    ///      native rescue in test_nativeRescueFailureBubblesFailedCall.
    fallback() external {}
}
