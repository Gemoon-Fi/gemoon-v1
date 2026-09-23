// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.21;

import {IPositionCreator, IFeeCollector, DeploymentInfo, PositionID, positionID} from "../interfaces/IPosition.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPositionManager} from "@uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap-v4-periphery/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap-v4-periphery/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {PoolId} from "@uniswap-v4-core/types/PoolId.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../utils/Ticks.sol";
import "../interfaces/IGemoon.sol";

/// @title Gemoon UniswapV4 position deployer.
contract UniswapDeployCollector is IPositionCreator, IERC721Receiver, Ownable {
    event PositionCreated(
        uint256 positionId,
        address indexed creator,
        address indexed token0,
        address indexed token1,
        uint256 poolSupply
    );

    mapping(PositionID => uint256) private _nftPositions;
    mapping(PositionID => PoolKey) private _poolKeys;

    IPositionManager public positionManager;
    IAllowanceTransfer public permit2;
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

    constructor(
        address uniswapPositionManager,
        address permit2_,
        address lpManager_
    ) Ownable(lpManager_) {
        require(
            uniswapPositionManager != address(0),
            "Position manager address cannot be zero"
        );
        require(permit2_ != address(0), "Permit2 address cannot be zero");
        require(lpManager_ != address(0), "LPmanager address cannot be zero");

        positionManager = IPositionManager(uniswapPositionManager);
        permit2 = IAllowanceTransfer(permit2_);
        lpManager = lpManager_;
    }

    function creatorName() external pure override returns (string memory) {
        return "UNISWAP_POSITION_CREATOR";
    }

    function _registerPosition(
        address creator,
        PoolId pool,
        uint256 positionId,
        PoolKey memory poolKey
    ) internal {
        PositionID posId = positionID(pool, creator);
        _nftPositions[posId] = positionId;
        _poolKeys[posId] = poolKey;
    }

    /// @inheritdoc IERC721Receiver
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

    event Received(address indexed from, uint256 tokenId);

    /// @dev grants the position manager a Permit2 allowance for `token`, routed through the
    /// standard two-step Permit2 approval (ERC20 -> Permit2, Permit2 -> spender).
    function _approveViaPermit2(address token, uint256 amount) internal {
        if (amount == 0) {
            return;
        }

        IERC20(token).approve(address(permit2), amount);
        permit2.approve(token, address(positionManager), uint160(amount), uint48(block.timestamp + 1 hours));
    }

    /// @notice claim rewards from uniswap position.
    /// @dev only LPManager can call this method.
    function collectRewards(
        address creator,
        PoolId pool
    ) external override onlyOwner returns (uint256 amount0, uint256 amount1) {
        PositionID posId = positionID(pool, creator);
        uint256 nftPosition = _nftPositions[posId];

        if (nftPosition <= 0) {
            revert NftPositionNotFound("nft position not found");
        }

        PoolKey memory poolKey = _poolKeys[posId];
        Currency currency0 = poolKey.currency0;
        Currency currency1 = poolKey.currency1;

        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        IERC20 token1 = IERC20(Currency.unwrap(currency1));

        uint256 balance0Before = token0.balanceOf(lpManager);
        uint256 balance1Before = token1.balanceOf(lpManager);

        bytes memory actions = abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));

        bytes[] memory params = new bytes[](2);
        // liquidity=0 decrease only settles the fees accrued by the position.
        params[0] = abi.encode(nftPosition, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(currency0, currency1, lpManager);

        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0 = token0.balanceOf(lpManager) - balance0Before;
        amount1 = token1.balanceOf(lpManager) - balance1Before;

        return (amount0, amount1);
    }

    function deployPosition(
        address /* positionHolder */,
        address creator,
        address deployedToken,
        address pairToken,
        PoolId pool,
        uint160 sqrtX96Price,
        address hook
    ) external override returns (DeploymentInfo memory) {
        address tokenA = deployedToken;
        address tokenB = pairToken;
        (address token0, address token1) = tokenA < tokenB
            ? (tokenA, tokenB)
            : (tokenB, tokenA);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            // Must match the key initialized by GemoonController._configurePool.
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hook)
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

        _approveViaPermit2(token0, amount0Desired);
        _approveViaPermit2(token1, amount1Desired);

        uint256 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtX96Price,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Desired,
            amount1Desired
        );

        require(liquidity > 0, "Computed liquidity is zero");

        uint256 positionId = positionManager.nextTokenId();

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            uint128(amount0Desired),
            uint128(amount1Desired),
            address(this),
            bytes("")
        );
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        try positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp) {}
        catch {
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

        _registerPosition(creator, pool, positionId, poolKey);

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
