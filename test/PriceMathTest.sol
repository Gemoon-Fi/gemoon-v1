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

    /// @dev The start price of a pool is PRICE_PER_TOKEN whole Meme per one whole pair token,
    /// expressed in raw units of each side. Swapping the token order must give the inverse
    /// price, i.e. the same price in human terms: sqrtA * sqrtB == 2^192.
    function test_GetSqrtPriceX96_StartPrice_SameForEitherTokenOrder() public pure {
        uint256 memeAmount = 300_000 * 1e6; // 300_000 whole Meme, 6 decimals
        uint256 pairAmount = 1e18; // 1 whole pair token, 18 decimals

        uint160 memeIsToken0 = PriceMath.getSqrtPriceX96(memeAmount, pairAmount);
        uint160 memeIsToken1 = PriceMath.getSqrtPriceX96(pairAmount, memeAmount);

        assertEq(memeIsToken0, 144650172662492649647717392874717, "meme as token0");
        assertEq(memeIsToken1, 43395051798747794894315217, "meme as token1");
        // pair per raw Meme = 1e18 / 3e11 = 3.33e6; Meme per raw pair = 3e11 / 1e18 = 3e-7
        assertApproxEqRel(_priceX36(memeIsToken0), 3_333_333_333_333_333_333_333_333_333_333_333_333_333_333, 1e12, "t0 price");
        assertApproxEqRel(_priceX36(memeIsToken1), 3e29, 1e12, "t1 price");
        assertApproxEqRel(
            Math.mulDiv(memeIsToken0, memeIsToken1, 1 << 96), 1 << 96, 1e9, "inverse prices"
        );
    }

    /// @dev For any Meme/pair decimals in 6..18 the start price must land inside the Uniswap tick
    /// range in both token orders and the two orders must be inverses of each other.
    function testFuzz_GetSqrtPriceX96_StartPrice_AnyDecimals_InverseAndInRange(
        uint8 memeDecimals,
        uint8 pairDecimals
    ) public pure {
        memeDecimals = uint8(bound(memeDecimals, 6, 18));
        pairDecimals = uint8(bound(pairDecimals, 6, 18));
        uint256 memeAmount = 300_000 * 10 ** memeDecimals;
        uint256 pairAmount = 10 ** pairDecimals;

        uint160 memeIsToken0 = PriceMath.getSqrtPriceX96(memeAmount, pairAmount);
        uint160 memeIsToken1 = PriceMath.getSqrtPriceX96(pairAmount, memeAmount);

        assertGe(memeIsToken0, TickMath.MIN_SQRT_PRICE, "t0 below range");
        assertLt(memeIsToken0, TickMath.MAX_SQRT_PRICE, "t0 above range");
        assertGe(memeIsToken1, TickMath.MIN_SQRT_PRICE, "t1 below range");
        assertLt(memeIsToken1, TickMath.MAX_SQRT_PRICE, "t1 above range");
        assertApproxEqRel(
            Math.mulDiv(memeIsToken0, memeIsToken1, 1 << 96), 1 << 96, 1e9, "inverse prices"
        );
    }
}
