// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProjectToken} from "../src/contracts/ProjectToken.sol";
import {IERC1046} from "../src/contracts/interfaces/IERC1046.sol";

contract ProjectTokenTest is Test {
    ProjectToken internal token;
    address internal owner = makeAddr("owner");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.prank(owner);
        token = new ProjectToken("Project", "PRJ", "https://example.com/meta.json", owner);
    }

    function test_Constructor_MintsSupplyToDeployerAndSetsOwner() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(owner), token.TOTAL_SUPPLY());
        assertEq(token.owner(), owner);
        assertEq(token.totalHolders(), 1);
        assertEq(token.decimals(), 18);
    }

    function test_TokenURI_ReturnsStoredLinkAsIs() public view {
        assertEq(token.tokenURI(), "https://example.com/meta.json");
    }

    function test_SetTokenURI_Owner_UpdatesAndEmits() public {
        vm.expectEmit(address(token));
        emit ProjectToken.UpdateTokenURI("ipfs://new");
        vm.prank(owner);
        token.setTokenURI("ipfs://new");
        assertEq(token.tokenURI(), "ipfs://new");
    }

    function test_SetTokenURI_NotOwner_Reverts() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        token.setTokenURI("ipfs://evil");
    }

    function test_UpdateImageAndDescription_NotOwner_Reverts() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        token.updateImage("x");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        token.changeDescription("x");
        vm.stopPrank();
    }

    function test_UpdateImageAndDescription_Owner_Updates() public {
        vm.startPrank(owner);
        token.updateImage("https://img");
        token.changeDescription("desc");
        vm.stopPrank();
        assertEq(token.imageAddress(), "https://img");
        assertEq(token.description(), "desc");
    }

    function test_SupportsInterface_ERC1046AndERC20_True() public view {
        assertTrue(token.supportsInterface(type(IERC1046).interfaceId));
        assertTrue(token.supportsInterface(type(IERC20).interfaceId));
        assertFalse(token.supportsInterface(0xffffffff));
    }

    function testFuzz_SetTokenURI_AnyString_RoundTrips(string calldata uri) public {
        vm.prank(owner);
        token.setTokenURI(uri);
        assertEq(token.tokenURI(), uri);
    }

    function testFuzz_SetTokenURI_AnyNonOwner_Reverts(address caller) public {
        vm.assume(caller != owner);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        token.setTokenURI("x");
    }

    function testFuzz_Transfer_SupplyConstantAndHoldersConsistent(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != owner);
        amount = bound(amount, 0, token.TOTAL_SUPPLY());
        vm.prank(owner);
        token.transfer(to, amount);
        assertEq(token.totalSupply(), token.TOTAL_SUPPLY());
        uint256 expected = (token.balanceOf(owner) > 0 ? 1 : 0) + (token.balanceOf(to) > 0 ? 1 : 0);
        assertEq(token.totalHolders(), expected);
    }
}
