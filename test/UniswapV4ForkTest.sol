// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "../src/contracts/deploy_collectors/UniswapDeployCollector.sol";
import "../src/contracts/Token.sol";
import "../src/contracts/interfaces/IGemoon.sol";
import {PoolId} from "@uniswap-v4-core/types/PoolId.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap-v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap-v4-core/types/PoolOperation.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PriceMath} from "../src/contracts/utils/Price.sol";

/// @notice Exercises UniswapDeployCollector's v4 mint/collect flow against the real
/// PoolManager/PositionManager/Permit2 deployment on a forked Monad mainnet, since the
/// Actions-encoding used in deployPosition/collectRewards has no other test coverage.
contract UniswapV4ForkTest is Test {
    address constant POSITION_MANAGER = 0x5b7eC4a94fF9beDb700fb82aB09d5846972F4016;
    address constant POOL_MANAGER = 0x188d586Ddcf52439676Ca21A244753fA19F9Ea8e;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    UniswapDeployCollector collector;
    address deployedToken;
    address pairToken;
    address lpManager = address(0x1234);

    function setUp() external {
        string memory rpc = vm.envOr("RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        collector = new UniswapDeployCollector(POSITION_MANAGER, PERMIT2, lpManager);

        AdminConfig[] memory admins = new AdminConfig[](0);
        TokenConfig memory config = TokenConfig({
            imgUrl: "ipfs://test",
            description: "fork test token",
            socialMedia: SocialMedia({farcaster: "", twitterX: "", telegram: "", website: ""}),
            name: "Fork Test Token",
            symbol: "FORK",
            admins: admins
        });

        GemoonToken token = new GemoonToken(config);
        deployedToken = address(token);
        token.transfer(address(collector), INITIAL_SUPPLY_X18);

        TokenConfig memory pairConfig = config;
        pairConfig.name = "Pair Token";
        pairConfig.symbol = "PAIR";
        pairToken = address(new GemoonToken(pairConfig));
    }

    function testDeployPositionAndCollectRewardsOnFork() external {
        if (address(collector) == address(0)) return; // skipped, no RPC configured

        address tokenA = deployedToken;
        address tokenB = pairToken;
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        uint160 sqrtX96Price = PriceMath.getSqrtPriceX96(
            token0 == deployedToken ? PRICE_PER_TOKEN : 1e18, token1 == deployedToken ? PRICE_PER_TOKEN : 1e18
        );

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        // mirrors GemoonController._configurePool, which initializes the pool before minting.
        IPoolManager(POOL_MANAGER).initialize(poolKey, sqrtX96Price);

        PoolId poolId = PoolId.wrap(keccak256("fork-test-pool"));

        DeploymentInfo memory depInfo =
            collector.deployPosition(lpManager, address(this), deployedToken, pairToken, poolId, sqrtX96Price, address(0));

        assertGt(depInfo.positionId, 0, "position id must be assigned");
        assertEq(depInfo.token0, token0, "token0 mismatch");
        assertEq(depInfo.token1, token1, "token1 mismatch");

        // fresh position has accrued no fees yet; collect must not revert and returns zero.
        vm.prank(lpManager);
        (uint256 amount0Before, uint256 amount1Before) = collector.collectRewards(address(this), poolId);
        assertEq(amount0Before, 0, "no fees should have accrued yet");
        assertEq(amount1Before, 0, "no fees should have accrued yet");

        // trade against the position's one-sided liquidity, then verify collectRewards
        // (DECREASE_LIQUIDITY + TAKE_PAIR) still settles. LP fee is 0 by design (the swap fee is
        // charged by HookManager), so the position accrues nothing.
        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(POOL_MANAGER));
        bool pairIsToken0 = pairToken == token0;
        uint256 swapAmount = 1_000 * 1e18;
        IERC20(pairToken).approve(address(swapRouter), swapAmount);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: pairIsToken0,
                amountSpecified: -int256(swapAmount),
                sqrtPriceLimitX96: pairIsToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );

        vm.prank(lpManager);
        (uint256 amount0, uint256 amount1) = collector.collectRewards(address(this), poolId);

        assertEq(amount0, 0, "LP fee is 0, no fees should accrue");
        assertEq(amount1, 0, "LP fee is 0, no fees should accrue");
        assertEq(IERC20(token0).balanceOf(lpManager), amount0, "lpManager token0 balance must match collected amount");
        assertEq(IERC20(token1).balanceOf(lpManager), amount1, "lpManager token1 balance must match collected amount");
    }
}
