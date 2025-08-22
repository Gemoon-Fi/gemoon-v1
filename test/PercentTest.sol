pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/contracts/utils/Percent.sol";

contract PercentTest is Test {
    function testSubPercent() public {
        assertEq(Percent.subPercent(100, 20), 80);
        assertEq(Percent.subPercent(100, 0), 100);
        assertEq(Percent.subPercent(0, 20), 0);
        assertEq(Percent.subPercent(1e18, 50), 5e17);
    }

    function testAddPercent() public {
        assertEq(Percent.addPercent(100, 20), 120);
        assertEq(Percent.addPercent(100, 0), 100);
        assertEq(Percent.addPercent(0, 20), 20);
    }
}
