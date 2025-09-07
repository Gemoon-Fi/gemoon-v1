// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.21;

import {IPositionCreator, IFeeCollector, DeploymentInfo, PositionID, positionID} from "../interfaces/IPosition.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {INonfungiblePositionManager} from "@uniswap-v3-periphery/interfaces/INonfungiblePositionManager.sol";
import {IUniswapV3Pool} from "@uniswap-v3-core/interfaces/IUniswapV3Pool.sol";
import "@uniswap-v3-core/libraries/TickMath.sol";
import {PoolAddress} from "@uniswap-v3-periphery/libraries/PoolAddress.sol";
import "../utils/Ticks.sol";
import "../interfaces/IGemoon.sol";

/// @title Gemoon UniswapV3 position deployer.
contract UniswapDeployCollector is IPositionCreator, IERC721Receiver {
    event PositionCreated(
        uint256 positionId,
        address indexed creator,
        address indexed token0,
        address indexed token1,
        uint256 poolSupply
    );

    mapping(PositionID => uint256) private _nftPositions;

    INonfungiblePositionManager public positionManager;
    address public lpManager;

    error NftPositionNotFound(string);

    error MintingFailed(
        string message,
        address token0,
        address token1,
        uint160 sqrtX96Price,
        uint256 amount0Desired,
        uint256 amount1Desired,
        int24 currentTick,
        int24 tickLower,
        int24 tickUpper
    );

    int24 public constant MIN_TICK = TickMath.MIN_TICK;
    int24 public constant MAX_TICK = TickMath.MAX_TICK;

    constructor(address uniswapPositionManager, address lpManager_) {
        require(
            uniswapPositionManager != address(0),
            "Position manager address cannot be zero"
        );
        require(lpManager_ != address(0), "LPmanager address cannot be zero");

        positionManager = INonfungiblePositionManager(uniswapPositionManager);
        lpManager = lpManager_;
    }

    function creatorName() external pure override returns (string memory) {
        return "UNISWAP_POSITION_CREATOR";
    }

    function _registerPosition(
        address creator,
        address pool,
        uint256 positionId
    ) internal {
        _nftPositions[positionID(pool, creator)] = positionId;
    }

    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external override returns (bytes4) {
        // unused parameters
        operator;
        data;

        emit Received(from, tokenId);

        return this.onERC721Received.selector;
    }

    // TODO: protect call. Only position creator or protocol admin can call this method!
    function collectRewards(
        address creator,
        address pool
    ) external override returns (uint256 amount0, uint256 amount1) {
        uint256 nftPosition = _nftPositions[positionID(pool, creator)];

        if (nftPosition <= 0) {
            revert NftPositionNotFound("nft position not found");
        }

        (amount0, amount1) = positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: nftPosition,
                recipient: lpManager,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        return (amount0, amount1);
    }

    event Received(address indexed from, uint256 tokenId);

    function deployPosition(
        address /* positionHolder */,
        address creator,
        address deployedToken,
        address pairToken,
        address pool,
        uint160 sqrtX96Price
    ) external override returns (DeploymentInfo memory) {
        require(
            IERC20(deployedToken).approve(
                address(positionManager),
                INITIAL_SUPPLY_X18
            ),
            "Deployed token0 approval failed"
        );
        require(
            IERC20(pairToken).approve(
                address(positionManager),
                INITIAL_SUPPLY_X18
            ),
            "Deployed token1 approval failed"
        );

        address tokenA = deployedToken;
        address tokenB = pairToken;
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);
        PoolAddress.PoolKey memory poolKey = PoolAddress.PoolKey({
            token0: token0,
            token1: token1,
            fee: FEE_TIER
        });

        (int24 tickLower, int24 tickUpper, int24 tick) = Ticks.getTicks(
            poolKey,
            sqrtX96Price,
            deployedToken,
            TICK_SPACING,
            true
        );

        uint256 amount0Desired = token0 == deployedToken
            ? INITIAL_SUPPLY_X18
            : 0;
        uint256 amount1Desired = token1 == deployedToken
            ? INITIAL_SUPPLY_X18
            : 0;
        uint256 balanceOfDeployer = IERC20(deployedToken).balanceOf(
            address(this)
        );

        require(
            balanceOfDeployer >= INITIAL_SUPPLY_X18,
            "Insufficient token balance"
        );

        INonfungiblePositionManager.MintParams
            memory params = INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: FEE_TIER,
                tickLower: int24(tickLower),
                tickUpper: int24(tickUpper),
                amount0Desired: amount0Desired,
                amount1Desired: amount1Desired,
                amount0Min: 0,
                amount1Min: 0,
                recipient: address(this),
                deadline: block.timestamp
            });
        uint256 positionId;
        try positionManager.mint(params) returns (
            uint256 _positionId,
            uint128,
            uint256,
            uint256
        ) {
            positionId = _positionId;
        } catch {
            revert MintingFailed(
                "error minting position, check parameters",
                token0,
                token1,
                sqrtX96Price,
                amount0Desired,
                amount1Desired,
                tick,
                int24(tickLower),
                int24(tickUpper)
            );
        }
        require(
            positionId > 0,
            "create position failed, position ID must be greater than zero"
        );

        emit PositionCreated(
            positionId,
            creator,
            token0,
            token1,
            INITIAL_SUPPLY_X18
        );

        _registerPosition(creator, pool, positionId);

        return
            DeploymentInfo({
                token0: address(token0),
                token1: address(token1),
                upperTick: int24(tickUpper),
                lowerTick: int24(tickLower),
                positionId: positionId,
                poolId: pool,
                rewardRecipient: address(0),
                creatorAdmin: address(0),
                feeCollector: IFeeCollector(this)
            });
    }
}
