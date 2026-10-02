// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@uniswap-v4-core/libraries/FullMath.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

library PriceMath {
    /// @notice Calculates the sqrt price in Q64.96 format from token amounts, in raw units.
    /// @dev `sqrtPriceX96 = sqrt(token1Amount / token0Amount) * 2^96`, computed as
    /// `sqrt(token1Amount * 2^192 / token0Amount)` so that very small ratios (e.g. a 6-decimal
    /// pair token against an 18-decimal Meme) keep their precision. Requires
    /// `token1Amount / token0Amount < 2^64`, which every Meme/pair pair satisfies.
    /// @param token0Amount The amount of token0 that is worth `token1Amount` of token1
    /// @param token1Amount The amount of token1 that is worth `token0Amount` of token0
    /// @return sqrtPriceX96 The sqrt price in Q64.96 format
    function getSqrtPriceX96(
        uint256 token0Amount,
        uint256 token1Amount
    ) external pure returns (uint160 sqrtPriceX96) {
        require(token0Amount > 0, "token0Amount cannot be zero");
        require(token1Amount > 0, "token1Amount cannot be zero");

        uint256 ratioX192 = FullMath.mulDiv(token1Amount, 1 << 192, token0Amount);
        sqrtPriceX96 = uint160(Math.sqrt(ratioX192));
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
