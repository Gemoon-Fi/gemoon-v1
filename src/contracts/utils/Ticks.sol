pragma solidity ^0.8.20;

import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import "./Price.sol";

library Ticks {
    function getTicks(
        PoolKey memory poolKey,
        uint160 sqrtPriceX96,
        address deployedToken,
        int24 tickSpacing,
        bool useFullRange
    )
        external
        pure
        returns (int24 lowerTick, int24 upperTick, int24 currentTick)
    {
        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        int40 tickLower;
        int40 tickUpper;

        if (useFullRange) {
            if (Currency.unwrap(poolKey.currency0) == deployedToken) {
                int40 roundedTick = PriceMath.roundTick(
                    tick + tickSpacing * 2,
                    tickSpacing
                );

                tickLower = PriceMath.roundTick(
                    roundedTick - tickSpacing,
                    tickSpacing
                );
                tickUpper = (TickMath.MAX_TICK / tickSpacing) * tickSpacing;
            } else {
                int40 roundedTick = PriceMath.roundTick(
                    tick - tickSpacing * 2,
                    tickSpacing
                );

                tickLower = (TickMath.MIN_TICK / tickSpacing) * tickSpacing;
                tickUpper = PriceMath.roundTick(
                    roundedTick + tickSpacing,
                    tickSpacing
                );
            }
        } else {
            if (Currency.unwrap(poolKey.currency0) == deployedToken) {
                int40 roundedTick = PriceMath.roundTick(
                    tick + tickSpacing * 2,
                    tickSpacing
                );

                tickLower = PriceMath.roundTick(
                    roundedTick - tickSpacing,
                    tickSpacing
                );
                tickUpper = roundedTick;
            } else {
                int40 roundedTick = PriceMath.roundTick(
                    tick - tickSpacing * 2,
                    tickSpacing
                );

                tickLower = roundedTick;
                tickUpper = PriceMath.roundTick(
                    roundedTick + tickSpacing,
                    tickSpacing
                );
            }
        }

        return (int24(tickLower), int24(tickUpper), tick);
    }
}
