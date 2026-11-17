// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {ITransferValidatorManagement} from "../../src/interfaces/ITransferValidatorManagement.sol";
import {LondonTokenCTestBase} from "./LondonTokenCTestBase.sol";
import {MockTransferValidator} from "./mocks/MockTransferValidator.sol";

/// @dev Deployment-time transfer policy (createCollectionWithTransferPolicy) against the mock
///      validator, which only accepts collection configuration from the collection itself.
contract TransferPolicyTest is LondonTokenCTestBase {
    event NewCollection(address);

    address internal paymentProcessor = makeAddr("paymentProcessor");
    address internal openSeaZone = makeAddr("openSeaZone");

    function _policy(address[] memory whitelist, address[] memory authorizers, uint8 go, uint16 ro)
        internal
        pure
        returns (LondonTokenCBase.TransferPolicy memory)
    {
        return LondonTokenCBase.TransferPolicy(whitelist, authorizers, go, ro);
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function _create(LondonTokenCBase.TransferPolicy memory policy)
        internal
        returns (LondonTokenCBase)
    {
        return LondonTokenCBase(
            factory.createCollectionWithTransferPolicy(
                "ipfs://base", minter, gateway, "Policy", ROYALTY_BPS, artist, policy
            )
        );
    }

    function test_policy_appliedAtomicallyAndListHandedToArtist() public {
        uint48 expectedListId = validator.lastListId() + 1;
        vm.expectEmit(true, true, false, true);
        emit LondonTokenCBase.TransferPolicyApplied(expectedListId, artist, 1, 1, 8, 1);
        LondonTokenCBase c = _create(_policy(_one(paymentProcessor), _one(openSeaZone), 8, 1));

        MockTransferValidator.Policy memory p = validator.policyOf(address(c));
        assertEq(p.listId, expectedListId, "list applied to collection");
        assertEq(p.rulesetId, 4, "whitelist ruleset pinned");
        assertEq(p.customRuleset, address(0));
        assertEq(p.globalOptions, 8);
        assertEq(p.rulesetOptions, 1);
        assertEq(validator.listOwners(expectedListId), artist, "artist owns the list");
        assertEq(validator.listAccounts(expectedListId, 1), _one(paymentProcessor));
        assertEq(validator.listAccounts(expectedListId, 2), _one(openSeaZone));
        assertEq(
            validator.listNames(expectedListId),
            string.concat("LondonTokenC ", Strings.toHexString(address(c)))
        );
        // The collection itself is fully initialized as usual.
        assertEq(c.owner(), artist);
        assertEq(c.mintingManager(), minter);
        assertEq(c.getTransferValidator(), DEFAULT_VALIDATOR);
    }

    /// An empty policy is the "no marketplaces" setup: a list with no operators or authorizers.
    function test_policy_emptyPolicyAppliesEmptyList() public {
        vm.expectCall(
            DEFAULT_VALIDATOR,
            abi.encodePacked(ITransferValidatorManagement.addAccountsToList.selector),
            0
        );
        LondonTokenCBase c = _create(_policy(new address[](0), new address[](0), 0, 0));
        MockTransferValidator.Policy memory p = validator.policyOf(address(c));
        assertEq(p.listId, validator.lastListId());
        assertEq(p.rulesetId, 4);
        assertEq(validator.listOwners(p.listId), artist);
        assertEq(validator.listAccounts(p.listId, 1).length, 0);
        assertEq(validator.listAccounts(p.listId, 2).length, 0);
    }

    function test_createCollection_withoutPolicy_keepsValidatorDefaults() public {
        vm.expectCall(
            DEFAULT_VALIDATOR, abi.encodePacked(ITransferValidatorManagement.createList.selector), 0
        );
        LondonTokenCBase c = _createCollection(factory, "Default");
        assertEq(validator.policyOf(address(c)).listId, 0);
    }

    function test_policy_emitsNewCollection() public {
        address predicted = vm.computeCreateAddress(address(factory), vm.getNonce(address(factory)));
        vm.expectEmit(false, false, false, true, address(factory));
        emit NewCollection(predicted);
        _create(_policy(new address[](0), new address[](0), 0, 0));
    }

    function test_policy_rejectsZeroAccounts() public {
        vm.expectRevert(LondonTokenCBase.TransferPolicyZeroAccount.selector);
        _create(_policy(_one(address(0)), new address[](0), 0, 0));
        vm.expectRevert(LondonTokenCBase.TransferPolicyZeroAccount.selector);
        _create(_policy(new address[](0), _one(address(0)), 0, 0));
    }

    function test_policy_capsAccountsPerList() public {
        address[] memory atCap = new address[](32);
        address[] memory overCap = new address[](33);
        for (uint256 i; i < 33; ++i) {
            // casting to 'uint160' is safe because 0x1000 + i < 2**160
            // forge-lint: disable-next-line(unsafe-typecast)
            address a = address(uint160(0x1000 + i));
            if (i < 32) atCap[i] = a;
            overCap[i] = a;
        }
        _create(_policy(atCap, atCap, 0, 0));
        vm.expectRevert(
            abi.encodeWithSelector(LondonTokenCBase.TransferPolicyTooManyAccounts.selector, 33, 32)
        );
        _create(_policy(overCap, new address[](0), 0, 0));
        vm.expectRevert(
            abi.encodeWithSelector(LondonTokenCBase.TransferPolicyTooManyAccounts.selector, 33, 32)
        );
        _create(_policy(new address[](0), overCap, 0, 0));
    }

    function test_policy_revertsWhenValidatorHasNoCode() public {
        vm.etch(DEFAULT_VALIDATOR, "");
        vm.expectRevert(
            abi.encodeWithSelector(
                LondonTokenCBase.TransferValidatorNotDeployed.selector, DEFAULT_VALIDATOR
            )
        );
        _create(_policy(new address[](0), new address[](0), 0, 0));
    }

    function test_policy_initializersAreOneShot() public {
        LondonTokenCBase c = _create(_policy(new address[](0), new address[](0), 0, 0));
        LondonTokenCBase.TransferPolicy memory p = _policy(new address[](0), new address[](0), 0, 0);

        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        c.initializeWithTransferPolicy("x", outsider, outsider, "Hijack", 0, outsider, p);
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        c.initialize("x", outsider, outsider, "Hijack", 0, outsider);
        // A collection created without a policy cannot get one injected later by anyone.
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        token.initializeWithTransferPolicy("x", outsider, outsider, "Hijack", 0, outsider, p);

        LondonTokenCBase implementation = LondonTokenCBase(factory.tokenImplementation());
        vm.expectRevert(LondonTokenCBase.AlreadyInitialized.selector);
        implementation.initializeWithTransferPolicy(
            "x", outsider, outsider, "Hijack", 0, outsider, p
        );
    }

    function test_policy_rejectsZeroOwnerBeforeTouchingValidator() public {
        vm.expectCall(
            DEFAULT_VALIDATOR, abi.encodePacked(ITransferValidatorManagement.createList.selector), 0
        );
        vm.expectRevert(LondonTokenCBase.ZeroOwner.selector);
        factory.createCollectionWithTransferPolicy(
            "u",
            minter,
            gateway,
            "N",
            ROYALTY_BPS,
            address(0),
            _policy(new address[](0), new address[](0), 0, 0)
        );
    }

    /// Custody keeps its exemption under any deployment policy.
    function test_policy_custodyExemptionStillApplies() public {
        LondonTokenCBase c = _create(_policy(new address[](0), new address[](0), 0, 1));
        vm.prank(minter);
        c.mint(custody, 7);
        validator.setRejectAll(true);
        vm.prank(custody);
        c.transferFrom(custody, recipient, 7);
        assertEq(c.ownerOf(7), recipient);
    }
}
