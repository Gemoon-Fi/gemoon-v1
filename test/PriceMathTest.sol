// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/contracts/utils/Price.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../src/contracts/utils/Price.sol";
import "@uniswap-v3-core/libraries/TickMath.sol";

contract PriceMathTest is Test {
    function testRoundPriceMath() public pure {
        int40 roundedTick = PriceMath.roundTick(-138162, 60);
        assertEq(roundedTick, -138180, "Rounded tick value mismatch");
        int40 roundedTickPositive = PriceMath.roundTick(138162, 60);

        assertEq(roundedTickPositive, 138180, "Rounded tick value mismatch");

        int40 roundedTickLargeTickSpacing = PriceMath.roundTick(-138162, 200);
        assertEq(roundedTick, -138180, "Rounded tick value mismatch");
    }

    function testTick() public pure {
        uint160 sqrtPriceX96 = PriceMath.getSqrtPriceX96(
            1000000 * 10 ** 18,
            1 * 10 ** 18
        );

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        assertEq(tick, -138163, "Tick value mismatch");

        int40 roundedTick = PriceMath.roundTick(tick, 60);

        assertEq(roundedTick, -138180, "Rounded tick value mismatch");
    }

    function testGetSqrtPriceX96() public pure {
        uint160 sqrtPriceX96 = PriceMath.getSqrtPriceX96(3333333 * 1e18 , 1e18);

        assertEq(
            sqrtPriceX96,
            79228162514264337593543950336,
            "Sqrt price mismatch"
        );
    }
}
