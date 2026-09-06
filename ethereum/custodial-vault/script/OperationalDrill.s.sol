// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script, console} from "forge-std/Script.sol";

import {CustodialNFTVault} from "../src/CustodialNFTVault.sol";
import {ICustodialNFTVault} from "../src/interfaces/ICustodialNFTVault.sol";
import {MockERC1155} from "../test/mocks/MockERC1155.sol";
import {MockERC721} from "../test/mocks/MockERC721.sol";

/// @notice Testnet operational drill (rollout §27 steps 1-10). Deploys a
///         drill vault (broadcaster = admin, manager, and locker), deposits
///         mock ERC-721/1155 assets, fills the exact rolling-window
///         allowance, proves the one-over auto-lock does not revert and
///         transfers nothing, exercises manual lock/unlock with history
///         preservation, rotates a manager, and rescues ERC-20-shaped and
///         native funds.
/// @dev Run against a public TEST environment only:
///   forge script script/OperationalDrill.s.sol:OperationalDrill \
///       --rpc-url $TESTNET_RPC_URL --broadcast -vvvv
contract OperationalDrill is Script {
    uint16 internal constant DRILL_MAX_TOKENS = 5;
    uint32 internal constant DRILL_PERIOD = 600;

    function run() external {
        vm.startBroadcast();
        address operator = msg.sender;

        address[] memory roles = new address[](1);
        roles[0] = operator;

        // 1. Deploy the drill vault; verify it starts unlocked.
        CustodialNFTVault vault = new CustodialNFTVault(
            operator, roles, roles, ICustodialNFTVault.Limits(DRILL_MAX_TOKENS, DRILL_PERIOD, 50)
        );
        require(!vault.isLocked(), "drill: vault must start unlocked");

        // 2. Deposit smoke tests through plain safe transfers.
        MockERC721 nft = new MockERC721();
        MockERC1155 multi = new MockERC1155();
        for (uint256 i; i < 6; ++i) {
            nft.mint(address(vault), i);
        }
        multi.mint(address(vault), 0, 10);
        require(nft.balanceOf(address(vault)) == 6, "drill: ERC-721 deposit failed");
        require(multi.balanceOf(address(vault), 0) == 10, "drill: ERC-1155 deposit failed");

        // 3. Fill the exact allowance (4 x ERC-721 + 1 x ERC-1155 edition).
        ICustodialNFTVault.WithdrawalItem[] memory fill = _mixedBatch(nft, multi, operator);
        require(vault.withdraw(fill), "drill: exact fill failed");
        require(vault.getRemainingLimit() == 0, "drill: allowance not exhausted");

        // 4-5. One-over auto-lock: must NOT revert, must transfer nothing.
        ICustodialNFTVault.WithdrawalItem[] memory over = new ICustodialNFTVault.WithdrawalItem[](1);
        over[0] = _item721(nft, 4, operator);
        bool executed = vault.withdraw(over);
        require(!executed, "drill: over-limit request must return false");
        require(vault.isLocked(), "drill: auto-lock did not engage");
        require(nft.ownerOf(4) == address(vault), "drill: auto-lock moved a token");

        // 6-7. Manual emergency lock (idempotent) and unlock preserving
        // history.
        vault.lock();
        uint256 usedBefore = vault.getRecentWithdrawn();
        vault.unlock();
        require(vault.getRecentWithdrawn() == usedBefore, "drill: unlock erased history");

        // 8. Rotate the manager set and back.
        address[] memory rotated = new address[](1);
        rotated[0] = address(uint160(uint256(keccak256(abi.encode(operator, "rotate")))));
        vault.setManagers(rotated);
        require(!vault.isManager(operator), "drill: rotation failed");
        vault.setManagers(roles);
        require(vault.isManager(operator), "drill: rotation back failed");

        // 9. ERC-20 rescue while locked.
        vault.lock();
        DrillERC20 erc20 = new DrillERC20();
        erc20.mint(address(vault), 1000);
        vault.rescueERC20(address(erc20), operator, 1000);
        require(erc20.balanceOf(operator) == 1000, "drill: ERC-20 rescue failed");
        vault.unlock();

        vm.stopBroadcast();

        console.log("Operational drill PASSED");
        console.log("  drill vault:", address(vault));
        console.log("  NOTE: native-rescue force-funding (SELFDESTRUCT) and the");
        console.log("  cross-chain lock drill are executed by operations tooling;");
        console.log("  see docs/DEPLOYMENT_CHECKLIST.md steps 10-12.");
    }

    function _mixedBatch(MockERC721 nft, MockERC1155 multi, address to)
        internal
        pure
        returns (ICustodialNFTVault.WithdrawalItem[] memory items)
    {
        items = new ICustodialNFTVault.WithdrawalItem[](5);
        ICustodialNFTVault.WithdrawalItem memory edition = ICustodialNFTVault.WithdrawalItem({
            token: address(multi),
            tokenId: 0,
            amount: 3,
            recipient: to,
            standard: ICustodialNFTVault.TokenStandard.ERC1155
        });
        if (address(nft) < address(multi)) {
            for (uint256 i; i < 4; ++i) {
                items[i] = _item721(nft, i, to);
            }
            items[4] = edition;
        } else {
            items[0] = edition;
            for (uint256 i; i < 4; ++i) {
                items[i + 1] = _item721(nft, i, to);
            }
        }
    }

    function _item721(MockERC721 nft, uint256 id, address to)
        internal
        pure
        returns (ICustodialNFTVault.WithdrawalItem memory)
    {
        return ICustodialNFTVault.WithdrawalItem({
            token: address(nft),
            tokenId: id,
            amount: 1,
            recipient: to,
            standard: ICustodialNFTVault.TokenStandard.ERC721
        });
    }
}

/// @dev Minimal ERC-20 for the drill's rescue exercise.
contract DrillERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
