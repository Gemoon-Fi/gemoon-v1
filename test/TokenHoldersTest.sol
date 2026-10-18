// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {GemoonToken} from "../src/contracts/Token.sol";
import {TokenConfig, SocialMedia} from "../src/contracts/interfaces/IToken.sol";
import {AdminConfig} from "../src/contracts/utils/Admin.sol";

function _newToken() returns (GemoonToken) {
    AdminConfig[] memory admins = new AdminConfig[](1);
    admins[0] = AdminConfig({admin: address(0xA11CE), removable: false});
    return new GemoonToken(
        TokenConfig({
            imgUrl: "ipfs://meme",
            description: "holders",
            socialMedia: SocialMedia({farcaster: "", twitterX: "", telegram: "", website: ""}),
            name: "Meme",
            symbol: "MEME",
            admins: admins
        }),
        address(0xC0FFEE)
    );
}

/// @notice `totalHolders` = number of addresses with a non-zero balance. The whole supply is minted
/// to the deployer (this test), so it starts as the only holder.
contract TokenHoldersTest is Test {
    GemoonToken token;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() external {
        token = _newToken();
    }

    function test_TotalHolders_AfterMint_DeployerOnly() external view {
        assertEq(token.totalHolders(), 1);
    }

    function test_TotalHolders_TransferToNew_Increments() external {
        token.transfer(alice, 1);
        assertEq(token.totalHolders(), 2);
    }

    function test_TotalHolders_TransferToExistingHolder_Unchanged() external {
        token.transfer(alice, 1);
        token.transfer(alice, 5);
        assertEq(token.totalHolders(), 2);
    }

    function test_TotalHolders_WholeBalanceMoved_SenderLeaves() external {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.transfer(bob, 10);
        assertEq(token.totalHolders(), 2, "deployer + bob");
    }

    function test_TotalHolders_ZeroValueTransfer_Unchanged() external {
        token.transfer(alice, 0);
        assertEq(token.totalHolders(), 1);
    }

    function test_TotalHolders_SelfTransfer_Unchanged() external {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.transfer(alice, 10);
        assertEq(token.totalHolders(), 2);
    }

    function test_TotalHolders_BurnWholeBalance_Leaves() external {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.burn(10);
        assertEq(token.totalHolders(), 1);
    }

    function test_TotalHolders_BurnPart_Unchanged() external {
        token.transfer(alice, 10);
        vm.prank(alice);
        token.burn(4);
        assertEq(token.totalHolders(), 2);
    }

    function test_TotalHolders_TransferFrom_CountsLikeTransfer() external {
        token.approve(alice, 10);
        vm.prank(alice);
        token.transferFrom(address(this), bob, 10);
        assertEq(token.totalHolders(), 2);
    }

    function test_TotalHolders_EverythingBurned_Zero() external {
        token.burn(token.balanceOf(address(this)));
        assertEq(token.totalHolders(), 0);
    }

    /// @dev Count after a transfer of any amount between any two addresses matches the balances.
    function testFuzz_TotalHolders_Transfer_MatchesBalances(
        address to,
        uint256 first,
        uint256 second
    ) external {
        vm.assume(to != address(0) && to != address(this) && to != alice);
        uint256 supply = token.balanceOf(address(this));
        first = bound(first, 0, supply);
        token.transfer(alice, first);
        second = bound(second, 0, token.balanceOf(alice));
        vm.prank(alice);
        token.transfer(to, second);

        uint256 expected = (token.balanceOf(address(this)) != 0 ? 1 : 0)
            + (token.balanceOf(alice) != 0 ? 1 : 0) + (token.balanceOf(to) != 0 ? 1 : 0);
        assertEq(token.totalHolders(), expected);
    }
}

// ------------------------------------------------------------------ invariant

/// @dev Owns the token (receives the whole mint) and moves it between a fixed set of actors by
/// transfer, transferFrom, self transfer, zero transfer and burn.
contract TokenHoldersHandler is Test {
    GemoonToken public immutable token;
    address[] public actors;

    constructor() {
        token = _newToken();
        actors.push(address(this));
        for (uint256 i; i < 4; ++i) {
            actors.push(makeAddr(string.concat("holder", vm.toString(i))));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(_actor(toSeed), amount);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount)
        external
    {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.approve(spender, amount);
        vm.prank(spender);
        token.transferFrom(from, _actor(toSeed), amount);
    }

    function burn(uint256 fromSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.burn(amount);
    }

    function burnAll(uint256 fromSeed) external {
        address from = _actor(fromSeed);
        uint256 balance = token.balanceOf(from);
        vm.prank(from);
        token.burn(balance);
    }
}

/// @notice Invariant: `totalHolders` == number of actors with a non-zero balance (all tokens stay
/// within the actor set, so this is every holder).
contract TokenHoldersInvariantTest is Test {
    TokenHoldersHandler handler;

    function setUp() external {
        handler = new TokenHoldersHandler();
        targetContract(address(handler));
    }

    function invariant_TotalHoldersEqualsNonZeroBalances() external view {
        GemoonToken token = handler.token();
        uint256 count;
        for (uint256 i; i < handler.actorCount(); ++i) {
            if (token.balanceOf(handler.actors(i)) != 0) ++count;
        }
        assertEq(token.totalHolders(), count);
    }
}
