// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "../src/contracts/utils/Hash.sol";

contract HashTest is Test {
    function testHashTokenPair() external pure {
        address tokenA = address(0x123);
        address tokenB = address(0x456);

        Hash hash1 = Hashes.hashTokenPair(tokenA, tokenB);
        Hash hash2 = Hashes.hashTokenPair(tokenB, tokenA);

        assertEq(
            Hash.unwrap(hash1),
            Hash.unwrap(hash2),
            "Hashes should be equal regardless of order"
        );
    }
}
