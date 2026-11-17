// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";

import {CustodialNFTVault} from "../../src/CustodialNFTVault.sol";
import {CustodyRegistry} from "../../src/erc721c/CustodyRegistry.sol";
import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {LondonTokenCFactory} from "../../src/erc721c/LondonTokenCFactory.sol";
import {ICustodialNFTVault} from "../../src/interfaces/ICustodialNFTVault.sol";

/// @dev Subset of the Limit Break Creator Token Transfer Validator v5 used by these tests.
interface ITransferValidatorV5 {
    function setRulesetOfCollection(
        address collection,
        uint8 rulesetId,
        address customRuleset,
        uint8 globalOptions,
        uint16 rulesetOptions
    ) external;
    function freezeAccountsForCollection(address collection, address[] calldata accounts) external;
}

/// @dev LondonTokenC against the live Limit Break validator v5 on an Ethereum fork, using the
///      production Venly custody address. Skipped unless ETHEREUM_RPC_URL is set.
contract EthereumERC721CForkTest is Test {
    address internal constant VALIDATOR_V5 = 0x721C008fdff27BF06E7E123956E2Fe03B63342e3;
    address internal constant VENLY_CUSTODY = 0xB4B57125AF2aCf9Bf605A9D9C3D256537876f65A;
    address internal constant OPENSEA_CONDUIT = 0x1E0049783F008A0085193E00003D00cd54003c71;
    address internal constant SEAPORT_1_6 = 0x0000000000000068F116a894984e2DB1123eB395;
    address internal constant PAYMENT_PROCESSOR = 0x9A1D00bEd7CD04BCDA516d721A596eb22Aac6834;

    // Validator v5 errors and options (creator-token-transfer-validator Errors.sol / Constants.sol).
    bytes4 internal constant CALLER_OR_FROM_MUST_BE_WHITELISTED = 0xe1f1d02e;
    bytes4 internal constant OTC_NOT_ALLOWED_FOR_SMART_WALLETS = 0x42d0e0e4;
    bytes4 internal constant OTC_NOT_ALLOWED_FOR_7702_DELEGATES = 0x369c2f4c;
    bytes4 internal constant SENDER_ACCOUNT_IS_FROZEN =
        bytes4(keccak256("CreatorTokenTransferValidator__SenderAccountIsFrozen()"));
    bytes4 internal constant TOKEN_IS_SOULBOUND =
        bytes4(keccak256("CreatorTokenTransferValidator__TokenIsSoulbound()"));
    uint8 internal constant RULESET_DEFAULT = 0;
    uint8 internal constant RULESET_SOULBOUND = 2;
    uint8 internal constant GO_ACCOUNT_FREEZING = 1 << 2;
    uint16 internal constant WLO_BLOCK_ALL_OTC = 1 << 0;

    address internal verseSafe = makeAddr("verseSafe");
    address internal artist = makeAddr("artist");
    address internal minter = makeAddr("minter");
    address internal collector = makeAddr("collector");
    address internal recipient = makeAddr("recipient");
    address internal operator = makeAddr("operator");
    address internal vaultManager = makeAddr("vaultManager");

    CustodyRegistry internal registry;
    LondonTokenCBase internal token;
    CustodialNFTVault internal vault;

    function setUp() public {
        string memory rpc = vm.envOr("ETHEREUM_RPC_URL", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 1, "unexpected fork chain id");
        assertGt(VALIDATOR_V5.code.length, 0, "validator v5 missing");

        address[] memory initial = new address[](1);
        initial[0] = VENLY_CUSTODY;
        registry = new CustodyRegistry(verseSafe, initial);
        LondonTokenCFactory factory = new LondonTokenCFactory(address(registry));
        token = LondonTokenCBase(
            factory.createCollection("ipfs://base", minter, minter, "Fork 721C", 750, artist)
        );

        address[] memory managers = new address[](1);
        managers[0] = vaultManager;
        address[] memory lockers = new address[](1);
        lockers[0] = makeAddr("vaultLocker");
        vault = new CustodialNFTVault(
            verseSafe, managers, lockers, ICustodialNFTVault.Limits(10, 600, 50)
        );

        vm.startPrank(minter);
        token.mint(VENLY_CUSTODY, 1);
        token.mint(VENLY_CUSTODY, 2);
        token.mint(collector, 3);
        token.mint(address(vault), 4);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------
    // Default validator policy
    // ---------------------------------------------------------------------

    function test_fork_defaults_venlyWithdrawAndCollectorTransfer() public {
        assertEq(token.getTransferValidator(), VALIDATOR_V5);
        _custodyWithdraw(1);
        vm.prank(collector);
        token.transferFrom(collector, recipient, 3);
        assertEq(token.ownerOf(3), recipient);
    }

    function test_fork_defaults_operatorAndUnauthorizedSeaportBlocked() public {
        vm.startPrank(collector);
        token.setApprovalForAll(operator, true);
        token.setApprovalForAll(OPENSEA_CONDUIT, true);
        token.setApprovalForAll(SEAPORT_1_6, true);
        token.setApprovalForAll(PAYMENT_PROCESSOR, true);
        vm.stopPrank();

        _expectBlocked(operator, collector, 3, CALLER_OR_FROM_MUST_BE_WHITELISTED);
        _expectBlocked(OPENSEA_CONDUIT, collector, 3, CALLER_OR_FROM_MUST_BE_WHITELISTED);
        _expectBlocked(SEAPORT_1_6, collector, 3, CALLER_OR_FROM_MUST_BE_WHITELISTED);

        vm.prank(PAYMENT_PROCESSOR);
        token.transferFrom(collector, recipient, 3);
        assertEq(token.ownerOf(3), recipient);
    }

    function test_fork_defaults_operatorOnCustodyTokenStillBlocked() public {
        vm.prank(VENLY_CUSTODY);
        token.setApprovalForAll(operator, true);
        _expectBlocked(operator, VENLY_CUSTODY, 1, CALLER_OR_FROM_MUST_BE_WHITELISTED);
    }

    // ---------------------------------------------------------------------
    // Artist escalations do not break custody withdrawals
    // ---------------------------------------------------------------------

    function test_fork_blockAllOtc_custodyStillWithdraws() public {
        _setPolicy(RULESET_DEFAULT, 0, WLO_BLOCK_ALL_OTC);
        _expectBlocked(collector, collector, 3, CALLER_OR_FROM_MUST_BE_WHITELISTED);
        _custodyWithdraw(1);
    }

    function test_fork_frozenCustody_stillWithdraws() public {
        _setPolicy(RULESET_DEFAULT, GO_ACCOUNT_FREEZING, 0);
        address[] memory frozen = new address[](2);
        frozen[0] = VENLY_CUSTODY;
        frozen[1] = collector;
        vm.prank(artist);
        ITransferValidatorV5(VALIDATOR_V5).freezeAccountsForCollection(address(token), frozen);

        _expectBlocked(collector, collector, 3, SENDER_ACCOUNT_IS_FROZEN);
        _custodyWithdraw(1);
    }

    function test_fork_soulbound_custodyStillWithdraws() public {
        _setPolicy(RULESET_SOULBOUND, 0, 0);
        _expectBlocked(collector, collector, 3, TOKEN_IS_SOULBOUND);
        _custodyWithdraw(1);
    }

    function test_fork_custodyRemovedFromRegistry_isSubjectToPolicy() public {
        _setPolicy(RULESET_DEFAULT, 0, WLO_BLOCK_ALL_OTC);
        vm.prank(verseSafe);
        registry.setCustodian(VENLY_CUSTODY, false);
        _expectBlocked(VENLY_CUSTODY, VENLY_CUSTODY, 1, CALLER_OR_FROM_MUST_BE_WHITELISTED);
    }

    // ---------------------------------------------------------------------
    // Future custody forms
    // ---------------------------------------------------------------------

    function test_fork_vault_blockedUntilRegistered() public {
        ICustodialNFTVault.WithdrawalItem[] memory items =
            new ICustodialNFTVault.WithdrawalItem[](1);
        items[0] = ICustodialNFTVault.WithdrawalItem(
            address(token), 4, 1, recipient, ICustodialNFTVault.TokenStandard.ERC721
        );

        vm.prank(vaultManager);
        vm.expectRevert(OTC_NOT_ALLOWED_FOR_SMART_WALLETS);
        vault.withdraw(items);

        vm.prank(verseSafe);
        registry.setCustodian(address(vault), true);
        vm.prank(vaultManager);
        assertTrue(vault.withdraw(items));
        assertEq(token.ownerOf(4), recipient);
    }

    function test_fork_custodyWith7702Delegation_stillWithdraws() public {
        vm.etch(VENLY_CUSTODY, abi.encodePacked(hex"ef0100", makeAddr("someDelegate")));
        _custodyWithdraw(1);

        vm.prank(verseSafe);
        registry.setCustodian(VENLY_CUSTODY, false);
        _expectBlocked(VENLY_CUSTODY, VENLY_CUSTODY, 2, OTC_NOT_ALLOWED_FOR_7702_DELEGATES);
    }

    // ---------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------

    function _custodyWithdraw(uint256 tokenId) internal {
        vm.prank(VENLY_CUSTODY);
        token.safeTransferFrom(VENLY_CUSTODY, recipient, tokenId);
        assertEq(token.ownerOf(tokenId), recipient);
    }

    function _expectBlocked(address caller, address from, uint256 tokenId, bytes4 err) internal {
        vm.prank(caller);
        vm.expectRevert(err);
        token.transferFrom(from, recipient, tokenId);
    }

    function _setPolicy(uint8 rulesetId, uint8 globalOptions, uint16 rulesetOptions) internal {
        vm.prank(artist);
        ITransferValidatorV5(VALIDATOR_V5)
            .setRulesetOfCollection(
                address(token), rulesetId, address(0), globalOptions, rulesetOptions
            );
    }
}
