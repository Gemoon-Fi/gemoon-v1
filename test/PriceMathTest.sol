// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "../src/contracts/utils/Price.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";

contract PriceMathTest is Test {
    function testRoundPriceMath() public pure {
        int40 roundedTick = PriceMath.roundTick(-138162, 60);
        assertEq(roundedTick, -138180, "Rounded tick value mismatch");
        int40 roundedTickPositive = PriceMath.roundTick(138162, 60);

        assertEq(roundedTickPositive, 138180, "Rounded tick value mismatch");

        assertEq(roundedTick, -138180, "Rounded tick value mismatch");
    }

    function testTick() public pure {
        uint160 sqrtPriceX96 = PriceMath.getSqrtPriceX96(
            1000000 * 10 ** 18,
            1 * 10 ** 18
        );

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);

        assertEq(tick, -138163, "Tick value mismatch");

        int40 roundedTick = PriceMath.roundTick(tick, 60);

        assertEq(roundedTick, -138180, "Rounded tick value mismatch");
    }

    function testGetSqrtPriceX96() public pure {
        uint160 sqrtPriceX96 = PriceMath.getSqrtPriceX96(3333333 * 1e18, 1e18);

        assertEq(
            sqrtPriceX96,
            43395053968500547563162768,
            "Sqrt price mismatch"
        );
    }

    /// @dev `price = (sqrtPriceX96 / 2^96)^2` in token1 per token0, scaled by 1e36 for the check.
    function _priceX36(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
        return Math.mulDiv(ratioX192, 1e36, 1 << 192);
    }

    /// @dev 300_000 Meme (18 decimals) for 1 USDG (6 decimals), Meme as token0: a ratio of
    /// 3.3e-18 that the old 1e18-scaled formula collapsed to 1e-18.
    function test_GetSqrtPriceX96_SixDecimalPairAsToken1_KeepsPrecision() public pure {
        uint160 sqrtPriceX96 = PriceMath.getSqrtPriceX96(300_000e18, 1e6);
        // 1e6 / 3e23 * 1e36 = 3.333...e18
        assertApproxEqRel(_priceX36(sqrtPriceX96), 3_333_333_333_333_333_333, 1e12, "price");
    }

    function test_GetSqrtPriceX96_SixDecimalPairAsToken0_KeepsPrecision() public pure {
        uint160 sqrtPriceX96 = PriceMath.getSqrtPriceX96(1e6, 300_000e18);
        // 3e23 / 1e6 * 1e36 = 3e53
        assertApproxEqRel(_priceX36(sqrtPriceX96), 3e53, 1e12, "price");
    }

    /// @dev Round trip: amounts in, price out, within 1e-9 relative error for any sane pair.
    function testFuzz_GetSqrtPriceX96_RoundTrip(uint256 token0Amount, uint256 token1Amount)
        public
        pure
    {
        token0Amount = bound(token0Amount, 1e6, 1e30);
        token1Amount = bound(token1Amount, 1e6, 1e30);
        // keep the ratio inside the tick range of Uniswap: ~1e-38 .. 1e38 is far wider, this is
        // just the documented 2^64 bound of the formula
        vm.assume(token1Amount / token0Amount < (1 << 64));

        uint160 sqrtPriceX96 = PriceMath.getSqrtPriceX96(token0Amount, token1Amount);
        uint256 expected = Math.mulDiv(token1Amount, 1e36, token0Amount);
        assertApproxEqRel(_priceX36(sqrtPriceX96), expected, 1e9, "round trip");
    }
}
