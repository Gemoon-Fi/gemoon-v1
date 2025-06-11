// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap-v3-core/libraries/TickMath.sol";
import "@uniswap-v3-core/libraries/FullMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

library PriceMath {
    /// @notice Calculates the sqrt price in Q64.96 format from token amounts
    /// @param token0Amount The amount of token0
    /// @param token1Amount The amount of token1
    /// @return sqrtPriceX96 The sqrt price in Q64.96 format
    function getSqrtPriceX96(
        uint256 token0Amount,
        uint256 token1Amount
    ) external pure returns (uint160 sqrtPriceX96) {
        require(token0Amount > 0, "token0Amount cannot be zero");
        require(token1Amount > 0, "token1Amount cannot be zero");

        // priceX18 = token1Amount * 1e18 / token0Amount
        uint256 priceX18 = FullMath.mulDiv(token1Amount, 1e18, token0Amount);

        // sqrtPriceX9 = sqrt(priceX18), sqrt(1e18) = 1e9
        uint256 sqrtPriceX9 = Math.sqrt(priceX18);

        // sqrtPriceX96 = sqrtPriceX9 * 2^96 / 1e9
        sqrtPriceX96 = uint160(FullMath.mulDiv(sqrtPriceX9, 2 ** 96, 1e9));
    }

    function roundTick(
        int40 tick,
        int24 tickSpacing
    ) internal pure returns (int40) {
        require(tickSpacing > 0, "Tick spacing must be positive");
        int40 roundedTick = (tick / tickSpacing) * tickSpacing;
        if (tick % tickSpacing != 0) {
            roundedTick += (tick > 0 ? tickSpacing : -tickSpacing);
        }
        return roundedTick;
    }
}
