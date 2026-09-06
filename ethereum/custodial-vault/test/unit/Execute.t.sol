// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";
import {ReentrantNativeRecipient} from "../mocks/ForceSend.sol";
import {MockCryptoPunks} from "../mocks/MockCryptoPunks.sol";
import {VaultTestBase} from "../utils/VaultTestBase.sol";

/// @dev Owner-only arbitrary `execute`: the recovery path for assets that
///      follow neither ERC-721 nor ERC-1155 and would otherwise be stuck in
///      the vault forever. Accepted-risk design (see NatSpec on `execute`):
///      the owner Safe already holds effective root over custody, so this
///      entrypoint removes friction rather than granting new capability.
contract ExecuteTest is VaultTestBase {
    MockCryptoPunks internal punks;
    uint256 internal constant PUNK_ID = 42;

    function setUp() public override {
        super.setUp();
        punks = new MockCryptoPunks();
        // A punk gets "deposited" without any callback: it simply lands on
        // the vault address.
        punks.setInitialOwner(address(vault), PUNK_ID);
    }

    function _punkCalldata() internal view returns (bytes memory) {
        return abi.encodeCall(MockCryptoPunks.transferPunk, (recipient, PUNK_ID));
    }

    function test_executeOnlyOwner() public {
        address[] memory callers = new address[](3);
        callers[0] = manager1;
        callers[1] = locker1;
        callers[2] = outsider;
        for (uint256 i; i < callers.length; ++i) {
            _expectNotOwner(callers[i]);
            vm.prank(callers[i]);
            vault.execute(address(punks), 0, _punkCalldata());
        }
    }

    function test_punkRescueEndToEnd() public {
        assertEq(punks.punkIndexToAddress(PUNK_ID), address(vault), "punk stuck in vault");

        vm.expectEmit(true, false, false, true, address(vault));
        emit ICustodialNFTVault.Executed(address(punks), 0, _punkCalldata());
        vm.prank(admin);
        vault.execute(address(punks), 0, _punkCalldata());

        assertEq(punks.punkIndexToAddress(PUNK_ID), recipient, "punk recovered");
    }

    function test_executeReturnsCallResult() public {
        bytes memory data = abi.encodeWithSignature("punkIndexToAddress(uint256)", PUNK_ID);
        vm.prank(admin);
        bytes memory result = vault.execute(address(punks), 0, data);
        assertEq(abi.decode(result, (address)), address(vault));
    }

    function test_executeZeroTargetReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ICustodialNFTVault.ZeroTokenAddress.selector, 0));
        vm.prank(admin);
        vault.execute(address(0), 0, "");
    }

    function test_executeBubblesTargetRevert() public {
        bytes memory data = abi.encodeCall(MockCryptoPunks.transferPunk, (recipient, 999));
        vm.expectRevert(bytes("not punk holder"));
        vm.prank(admin);
        vault.execute(address(punks), 0, data);
    }

    function test_executeForwardsValueFromVaultBalance() public {
        vm.deal(address(vault), 1 ether);
        PayableSink sink = new PayableSink();
        bytes memory data = abi.encodeCall(PayableSink.deposit, ());

        vm.prank(admin);
        vault.execute(address(sink), 0.4 ether, data);

        assertEq(address(sink).balance, 0.4 ether);
        assertEq(address(vault).balance, 0.6 ether);
    }

    function test_executeCannotReenterVault() public {
        ReentrantNativeRecipient hostile = new ReentrantNativeRecipient();
        hostile.arm(
            address(vault),
            abi.encodeCall(ICustodialNFTVault.rescueNative, (payable(address(hostile)), 1))
        );
        vm.deal(address(vault), 1 ether);

        vm.prank(admin);
        vault.execute(address(hostile), 0.1 ether, "");

        assertTrue(hostile.reentryAttempted());
        assertFalse(hostile.reentrySucceeded(), "reentry must be blocked");
        assertEq(address(hostile).balance, 0.1 ether);
    }

    function test_executeWorksWhileLocked() public {
        // Rescues happen during incidents; execute is not pause-gated.
        vm.prank(locker1);
        vault.lock();
        vm.prank(admin);
        vault.execute(address(punks), 0, _punkCalldata());
        assertEq(punks.punkIndexToAddress(PUNK_ID), recipient);
    }

    function test_executeIsPlainCallNotDelegatecall() public {
        // If execute used delegatecall, the storage write below would hit
        // the VAULT's storage; with a plain call it hits the target's.
        StorageWriter writer = new StorageWriter();
        vm.prank(admin);
        vault.execute(address(writer), 0, abi.encodeCall(StorageWriter.write, ()));
        assertEq(writer.slot0(), 1, "target storage written => plain CALL");
        assertEq(vault.owner(), admin, "vault storage untouched");
    }

    /// @dev Documents the accepted risk: `execute` CAN move standard custody
    ///      assets when called by the owner. This is a deliberate design
    ///      decision (owner == root); the Safe is the security boundary.
    function test_acceptedRisk_ownerCanMoveCustodyAssetsViaExecute() public {
        bytes memory data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)", address(vault), recipient, uint256(0)
        );
        vm.prank(admin);
        vault.execute(address(nft), 0, data);
        assertEq(nft.ownerOf(0), recipient);
    }
}

/// @dev Payable target for the value-forwarding test.
contract PayableSink {
    function deposit() external payable {}
}

/// @dev Distinguishes CALL from DELEGATECALL by writing its own slot 0.
contract StorageWriter {
    uint256 public slot0;

    function write() external {
        slot0 = 1;
    }
}
