// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap-v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap-v4-core/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap-v4-core/types/PoolId.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";
import {TickMath} from "@uniswap-v4-core/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap-v4-periphery/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {ProjectToken} from "../src/contracts/ProjectToken.sol";

/// @notice Deploys `ProjectToken` directly (not through the controller), owned by the broadcaster,
///         creates a hookless Uniswap V4 token/pair pool and puts the whole supply into a
///         one-sided position above the start price. The broadcaster gets the position NFT.
/// @dev Env: PROJECT_TOKEN_NAME, PROJECT_TOKEN_SYMBOL, PROJECT_TOKEN_URI (optional),
/// PROJECT_POOL_FEE (LP fee in hundredths of a bip, default 10_000 = 1%),
/// PROJECT_TICK_SPACING (default 200), PROJECT_TOKENS_PER_PAIR (start price: whole tokens for one
/// whole pair token, default 50_000, i.e. a 20 000 pair-token market cap like the Memes),
/// USDG_ADDRESS (pair token), POOL_MANAGER, POSITION_MANAGER, PERMIT2.
contract DeployProjectToken is Script {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    function run() external returns (ProjectToken token, PoolKey memory key, uint256 positionId) {
        address pair = vm.envAddress("USDG_ADDRESS");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        IPositionManager posm = IPositionManager(vm.envAddress("POSITION_MANAGER"));
        IAllowanceTransfer permit2 = IAllowanceTransfer(vm.envAddress("PERMIT2"));
        uint24 fee = uint24(vm.envOr("PROJECT_POOL_FEE", uint256(10_000)));
        int24 spacing = int24(int256(vm.envOr("PROJECT_TICK_SPACING", uint256(200))));
        uint256 tokensPerPair = vm.envOr("PROJECT_TOKENS_PER_PAIR", uint256(50_000));

        vm.startBroadcast();
        (, address owner, ) = vm.readCallers();

        token = new ProjectToken(
            vm.envString("PROJECT_TOKEN_NAME"),
            vm.envString("PROJECT_TOKEN_SYMBOL"),
            vm.envOr("PROJECT_TOKEN_URI", string("")),
            owner
        );
        bool tokenIs0 = address(token) < pair;
        key = PoolKey({
            currency0: Currency.wrap(tokenIs0 ? address(token) : pair),
            currency1: Currency.wrap(tokenIs0 ? pair : address(token)),
            fee: fee,
            tickSpacing: spacing,
            hooks: IHooks(address(0))
        });

        // Start price in raw units, token1 per token0.
        uint256 tokenRaw = tokensPerPair * 10 ** token.decimals();
        uint256 pairRaw = 10 ** IERC20Metadata(pair).decimals();
        uint160 sqrtPriceX96 = tokenIs0
            ? _sqrtPriceX96(pairRaw, tokenRaw)
            : _sqrtPriceX96(tokenRaw, pairRaw);
        int24 tick = poolManager.initialize(key, sqrtPriceX96);

        // One-sided range holding only the token: strictly above the current tick when the token
        // is currency0, at or below it when the token is currency1.
        int24 tickLower;
        int24 tickUpper;
        int24 aligned = _floor(tick, spacing);
        if (tokenIs0) {
            tickLower = aligned + spacing;
            tickUpper = (TickMath.MAX_TICK / spacing) * spacing;
        } else {
            tickLower = (TickMath.MIN_TICK / spacing) * spacing;
            tickUpper = aligned;
        }

        uint256 amount = token.TOTAL_SUPPLY();
        IERC20(address(token)).approve(address(permit2), amount);
        permit2.approve(address(token), address(posm), amount.toUint160(), uint48(block.timestamp + 1 hours));

        positionId = posm.nextTokenId();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SETTLE), uint8(Actions.MINT_POSITION_FROM_DELTAS), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(Currency.wrap(address(token)), amount, true);
        params[1] = abi.encode(
            key,
            tickLower,
            tickUpper,
            tokenIs0 ? amount.toUint128() : 0,
            tokenIs0 ? 0 : amount.toUint128(),
            owner,
            bytes("")
        );
        params[2] = abi.encode(key.currency0, key.currency1, owner);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 1 hours);
        vm.stopBroadcast();

        require(posm.getPositionLiquidity(positionId) > 0, "position not minted");
        require(token.owner() == owner, "owner mismatch");

        console.log("TOKEN", address(token));
        console.log("OWNER", owner);
        console.log("POSITION_ID", positionId);
        console.log("POOL_ID");
        console.logBytes32(PoolId.unwrap(key.toId()));
        console.log("FEE", fee);
        console.logInt(tick);
        console.logInt(tickLower);
        console.logInt(tickUpper);
        console.log("TOKEN_LEFT_IN_WALLET", token.balanceOf(owner));
    }

    /// @dev sqrt(amount1 / amount0) in Q64.96. The ratio stays far below 2^64 for the defaults.
    function _sqrtPriceX96(uint256 amount1, uint256 amount0) private pure returns (uint160) {
        return Math.sqrt(Math.mulDiv(amount1, 1 << 192, amount0)).toUint160();
    }

    /// @dev Largest multiple of `spacing` not above `tick`.
    function _floor(int24 tick, int24 spacing) private pure returns (int24) {
        int24 q = tick / spacing;
        if (tick < 0 && tick % spacing != 0) q--;
        return q * spacing;
    }
}
