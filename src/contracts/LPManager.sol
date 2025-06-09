// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {ILPManager} from "./interfaces/ILPManager.sol";
import {IUniswapV3Factory} from "@uniswap-v3-core/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import {INonfungiblePositionManager} from "@uniswap-v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {RewardsConfig, PoolConfig} from "./interfaces/IGemoon.sol";
import "@uniswap-v3-core/libraries/TickMath.sol";

contract LPManager is ILPManager {
    INonfungiblePositionManager public positionManager;
    IUniswapV3Factory public factory;

    constructor(address positionManager_, address factory_) {
        require(
            positionManager_ != address(0),
            "Position manager address cannot be zero"
        );
        require(factory_ != address(0), "Factory address cannot be zero");
        positionManager = INonfungiblePositionManager(positionManager_);
        factory = IUniswapV3Factory(factory_);
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        emit Received(from, tokenId);

        return this.onERC721Received.selector;
    }

    function createPosition(
        RewardsConfig memory rewardsConfig_,
        PoolConfig memory poolConfig_
    ) external override returns (uint256 positionId) {
        address pool = factory.createPool(
            poolConfig_.token0,
            poolConfig_.token1,
            3000
        );

        // TickMath.getSqrtRatioAtTick();

        IUniswapV3Pool(pool).initialize(0);
    }

    function claimRewards(
        address token
    ) external override returns (uint256 amount) {}

    function showRewardsForCreator(
        address creator
    ) external view override returns (uint256 amount) {}
}
