// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {LondonTokenCTestBase} from "../erc721c/LondonTokenCTestBase.sol";
import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";
import {OnchainFileStorage} from "../../src/erc721c/OnchainFileStorage.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

contract NoNFTReceiver {}

contract ForwardingReceiver is IERC721Receiver {
    LondonTokenCBase immutable token;
    address immutable recipient;
    address immutable victim;
    uint256 immutable victimId;
    bool public stolen;

    constructor(LondonTokenCBase t, address to, address v, uint256 id) {
        token = t;
        recipient = to;
        victim = v;
        victimId = id;
    }

    function onERC721Received(address, address, uint256 id, bytes calldata)
        external returns (bytes4)
    {
        (stolen,) = address(token).call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", victim, recipient, victimId)
        );
        token.transferFrom(address(this), recipient, id);
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract WritingValidator {
    uint256 public calls;
    function setTokenTypeOfCollection(address, uint16) external {}
    function validateTransfer(address, address, address, uint256) external { ++calls; }
}

contract ReinitializingValidator {
    bool public hijacked;
    function setTokenTypeOfCollection(address collection, uint16) external {
        (hijacked,) = collection.call(abi.encodeWithSignature(
            "initialize(string,address,address,string,uint256,address)",
            "attacker", address(this), address(this), "attacker", 0, address(this)
        ));
    }
    function validateTransfer(address, address, address, uint256) external pure {}
}

contract LondonTokenCAuditSecurityTest is LondonTokenCTestBase {
    // L-01: a normal minter can accidentally assign an NFT permanently to a contract
    // with neither a receiver callback nor a method capable of moving it out.
    function test_PoC_unsafeMintLocksTokenInNonReceiver() public {
        NoNFTReceiver sink = new NoNFTReceiver();
        vm.prank(minter);
        token.mintWithPayload(address(sink), 100, "artwork");
        assertEq(token.ownerOf(100), address(sink));
        assertEq(token.balanceOf(address(sink)), 1);
        vm.prank(artist);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        token.transferFrom(address(sink), recipient, 100);
        vm.prank(collector);
        vm.expectRevert("ERC721: transfer to non ERC721Receiver implementer");
        token.safeTransferFrom(collector, address(sink), COLLECTOR_TOKEN);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), collector);
    }

    // L-02: empty pointer lists are accepted, but are also the nonexistence sentinel.
    // Retrying with real content produces duplicate names; removal leaves a ghost entry.
    function test_PoC_emptyFileRegistrationCannotBeRemovedAndCorruptsEnumeration() public {
        vm.startPrank(artist);
        token.addFile("art.html", new address[](0));
        assertEq(token.files().length, 1);
        vm.expectRevert(OnchainFileStorage.FileNotRegistered.selector);
        token.removeFile("art.html");
        vm.expectRevert(OnchainFileStorage.FileNotRegistered.selector);
        token.fileStorage("art.html");
        address[] memory pointer = new address[](1);
        pointer[0] = makeAddr("bytecodePointer");
        vm.etch(pointer[0], hex"00617274");
        token.addFile("art.html", pointer);
        assertEq(token.files().length, 2);
        assertEq(token.fileContents("art.html"), bytes("art"));
        token.removeFile("art.html");
        string[] memory remaining = token.files();
        assertEq(remaining.length, 1);
        assertEq(remaining[0], "");
        vm.expectRevert(OnchainFileStorage.FileNotRegistered.selector);
        token.removeFile("");
        vm.stopPrank();
    }

    function test_PoC_codeFreeFilePointerMakesContentReadPanic() public {
        address[] memory pointer = new address[](1);
        pointer[0] = makeAddr("EOA");
        vm.prank(artist);
        token.addFile("bad.html", pointer);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        token.fileContents("bad.html");
    }

    // Permissionless factory provenance cannot establish artist consent. The
    // attacker can nominate an artist as owner while choosing their own minter.
    function test_PoC_factoryOwnerAndCreatorDoNotProveArtistConsent() public {
        vm.prank(outsider);
        LondonTokenCBase impostor = LondonTokenCBase(factory.createCollection(
            "ipfs://impostor", outsider, outsider, "Collection by Artist", 750, artist
        ));
        assertEq(impostor.owner(), artist);
        assertEq(impostor.creator(), artist);
        vm.prank(outsider);
        impostor.mint(outsider, 1);
        assertEq(impostor.ownerOf(1), outsider);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), collector);
    }

    // Recipients may forward their received token during the callback, but cannot
    // take another holder's token or leave stale balances/approvals behind.
    function test_receiverReentrancyPreservesOwnershipAndApprovals() public {
        ForwardingReceiver receiver = new ForwardingReceiver(token, recipient, custody, CUSTODY_TOKEN);
        vm.prank(collector);
        token.approve(operator, COLLECTOR_TOKEN);
        vm.prank(operator);
        token.safeTransferFrom(collector, address(receiver), COLLECTOR_TOKEN);
        assertFalse(receiver.stolen());
        assertEq(token.ownerOf(COLLECTOR_TOKEN), recipient);
        assertEq(token.ownerOf(CUSTODY_TOKEN), custody);
        assertEq(token.balanceOf(collector), 0);
        assertEq(token.balanceOf(address(receiver)), 0);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.balanceOf(custody), 1);
        assertEq(token.totalSupply(), 2);
        assertEq(token.getApproved(COLLECTOR_TOKEN), address(0));
    }

    function test_validatorRunsUnderStaticcallAndCannotMutateState() public {
        WritingValidator writing = new WritingValidator();
        vm.prank(artist);
        token.setTransferValidator(address(writing));
        vm.prank(collector);
        vm.expectRevert();
        token.transferFrom(collector, recipient, COLLECTOR_TOKEN);
        assertEq(writing.calls(), 0);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), collector);
        vm.prank(custody);
        token.transferFrom(custody, recipient, CUSTODY_TOKEN);
        assertEq(token.ownerOf(CUSTODY_TOKEN), recipient);
    }

    function test_registrationCallbackCannotReinitializeClone() public {
        vm.etch(DEFAULT_VALIDATOR, address(new ReinitializingValidator()).code);
        LondonTokenCBase fresh = _createCollection(factory, "Honest");
        assertFalse(ReinitializingValidator(DEFAULT_VALIDATOR).hijacked());
        assertEq(fresh.owner(), artist);
        assertEq(fresh.name(), "Honest");
        assertEq(fresh.mintingManager(), minter);
    }

    function test_policyFailureRollsBackCloneAndFactoryNonce() public {
        uint64 nonce = vm.getNonce(address(factory));
        address predicted = vm.computeCreateAddress(address(factory), nonce);
        LondonTokenCBase.TransferPolicy memory p;
        p.whitelist = new address[](1); // zero is rejected after initialization
        p.authorizers = new address[](0);
        vm.expectRevert(LondonTokenCBase.TransferPolicyZeroAccount.selector);
        factory.createCollectionWithTransferPolicy("x", minter, gateway, "x", 750, artist, p);
        assertEq(predicted.code.length, 0);
        assertEq(vm.getNonce(address(factory)), nonce);
    }

    // The existing regression calls the absent opt-in selector as a non-owner.
    // Calling as the artist also rules out a merely owner-gated selector.
    function test_artistCannotEnableValidatorAutoApproval() public {
        vm.prank(artist);
        (bool ok,) = address(token).call(abi.encodeWithSignature(
            "setAutomaticApprovalOfTransfersFromValidator(bool)", true
        ));
        assertFalse(ok);
    }

    function testFuzz_unapprovedAccountCannotTransfer(address attacker, bool safe) public {
        vm.assume(attacker != collector && attacker != address(0));
        vm.prank(attacker);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        if (safe) token.safeTransferFrom(collector, recipient, COLLECTOR_TOKEN);
        else token.transferFrom(collector, recipient, COLLECTOR_TOKEN);
        assertEq(token.ownerOf(COLLECTOR_TOKEN), collector);
    }

    function testFuzz_approvalClearedEvenOnSelfTransfer(uint256 id) public {
        vm.assume(id != CUSTODY_TOKEN && id != COLLECTOR_TOKEN);
        vm.prank(minter);
        token.mint(collector, id);
        vm.prank(collector);
        token.approve(operator, id);
        vm.prank(operator);
        token.transferFrom(collector, collector, id);
        assertEq(token.getApproved(id), address(0));
        assertEq(token.balanceOf(collector), 2);
        vm.prank(operator);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        token.transferFrom(collector, recipient, id);
    }
}
