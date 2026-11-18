// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LondonTokenCTestBase} from "../erc721c/LondonTokenCTestBase.sol";
import {LondonTokenCBase} from "../../src/erc721c/LondonTokenCBase.sol";

contract AuditTokenHandler is Test {
    LondonTokenCBase public token;
    address public minter;
    address public outsider;
    address[4] public holders;
    uint256 public nextId = 3;
    mapping(uint256 => address) public modelOwner;

    constructor(LondonTokenCBase t, address m, address c, address collector, address recipient, address operator, address attacker) {
        token = t;
        minter = m;
        outsider = attacker;
        holders = [c, collector, recipient, operator];
        modelOwner[1] = c;
        modelOwner[2] = collector;
    }

    function mint(uint256 recipientSeed) external {
        if (nextId > 80) return;
        address to = holders[recipientSeed % 4];
        vm.prank(minter);
        token.mint(to, nextId);
        modelOwner[nextId++] = to;
    }

    function transfer(uint256 tokenSeed, uint256 recipientSeed, bool safe) external {
        uint256 id = 1 + tokenSeed % (nextId - 1);
        address from = modelOwner[id];
        address to = holders[recipientSeed % 4];
        vm.prank(from);
        if (safe) token.safeTransferFrom(from, to, id);
        else token.transferFrom(from, to, id);
        modelOwner[id] = to;
        assertEq(token.getApproved(id), address(0));
    }

    function approvedTransfer(uint256 tokenSeed, uint256 recipientSeed) external {
        uint256 id = 1 + tokenSeed % (nextId - 1);
        address from = modelOwner[id];
        address to = holders[recipientSeed % 4];
        vm.prank(from);
        token.approve(outsider, id);
        vm.prank(outsider);
        token.transferFrom(from, to, id);
        modelOwner[id] = to;
        assertEq(token.getApproved(id), address(0));
    }

    function revokedOperatorCannotTransfer(uint256 tokenSeed) external {
        uint256 id = 1 + tokenSeed % (nextId - 1);
        address from = modelOwner[id];
        vm.startPrank(from);
        token.setApprovalForAll(outsider, true);
        token.setApprovalForAll(outsider, false);
        vm.stopPrank();
        vm.prank(outsider);
        (bool ok,) = address(token).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, outsider, id));
        assertFalse(ok);
    }

    function incorrectFromCannotTransfer(uint256 tokenSeed) external {
        uint256 id = 1 + tokenSeed % (nextId - 1);
        vm.prank(modelOwner[id]);
        (bool ok,) = address(token).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", outsider, outsider, id));
        assertFalse(ok);
    }
}

contract LondonTokenCAuditInvariantTest is LondonTokenCTestBase {
    AuditTokenHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new AuditTokenHandler(token, minter, custody, collector, recipient, operator, outsider);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.transfer.selector;
        selectors[2] = handler.approvedTransfer.selector;
        selectors[3] = handler.revokedOperatorCannotTransfer.selector;
        selectors[4] = handler.incorrectFromCannotTransfer.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_balancesSupplyOwnershipAndApprovalsAgree() public view {
        uint256[4] memory expected;
        uint256 count = handler.nextId() - 1;
        for (uint256 id = 1; id <= count; ++id) {
            address owner = handler.modelOwner(id);
            assertEq(token.ownerOf(id), owner);
            assertEq(token.getApproved(id), address(0));
            for (uint256 j; j < 4; ++j) {
                if (owner == handler.holders(j)) ++expected[j];
            }
        }
        uint256 sum;
        for (uint256 j; j < 4; ++j) {
            assertEq(token.balanceOf(handler.holders(j)), expected[j]);
            sum += expected[j];
        }
        assertEq(token.totalSupply(), count);
        assertEq(sum, count);
        assertEq(token.balanceOf(outsider), 0);
    }
}
