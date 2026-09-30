// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPositionManager} from "@uniswap-v4-periphery/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap-v4-periphery/libraries/Actions.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap-v4-core/types/PoolKey.sol";
import {Currency} from "@uniswap-v4-core/types/Currency.sol";

/// @title Initial liquidity position of a Meme.
/// @notice Mints Meme tokens held by the calling contract into a one-sided Uniswap V4 position.
/// @dev Internal library: the code is inlined into the caller, nothing is deployed separately.
/// The caller must hold `amount` of the Meme. The PositionManager pulls tokens through Permit2,
/// so `mint` grants a one-off ERC20 -> Permit2 -> PositionManager allowance that the settlement
/// consumes in full in the same transaction; nothing is left approved afterwards.
///
/// Flow inside `modifyLiquidities`:
///  1. SETTLE                    the whole `amount` is paid into the PoolManager as a credit,
///  2. MINT_POSITION_FROM_DELTAS the PositionManager turns that credit into liquidity for the
///                               range (it computes the liquidity, the caller carries no math),
///  3. TAKE_PAIR                 rounding dust that did not fit into the position goes back.
library PositionDeployer {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    struct MintParams {
        IPositionManager positionManager;
        IAllowanceTransfer permit2;
        /// @dev Pool the position is minted into, must already be initialized.
        PoolKey poolKey;
        /// @dev Meme token, one side of `poolKey`.
        address deployedToken;
        /// @dev Meme amount to put into the position.
        uint256 amount;
        /// @dev Range, must not contain the current price (the position is one-sided).
        int24 tickLower;
        int24 tickUpper;
        /// @dev Owner of the position NFT.
        address recipient;
    }

    struct Position {
        uint256 tokenId;
        uint128 liquidity;
    }

    error InsufficientBalance(uint256 balance, uint256 required);
    error PositionNotMinted(uint256 tokenId);

    /// @notice Mints `params.amount` of the Meme into [tickLower, tickUpper] and returns the
    ///         NFT id and the liquidity the PositionManager recorded for it.
    /// @dev Reverts if the caller holds less than `amount` or if the PositionManager recorded no
    /// liquidity for the expected token id (e.g. the range contains the current price).
    function mint(MintParams memory params) internal returns (Position memory position) {
        uint256 balance = IERC20(params.deployedToken).balanceOf(address(this));
        if (balance < params.amount) revert InsufficientBalance(balance, params.amount);

        bool memeIsCurrency0 = Currency.unwrap(params.poolKey.currency0) == params.deployedToken;
        uint128 amountMax = params.amount.toUint128();

        _approveViaPermit2(
            params.deployedToken, params.amount, params.permit2, address(params.positionManager)
        );

        uint256 tokenId = params.positionManager.nextTokenId();

        bytes memory actions = abi.encodePacked(
            uint8(Actions.SETTLE), uint8(Actions.MINT_POSITION_FROM_DELTAS), uint8(Actions.TAKE_PAIR)
        );
        bytes[] memory actionParams = new bytes[](3);
        // payerIsUser = true: the PositionManager pulls from this contract through Permit2.
        actionParams[0] = abi.encode(Currency.wrap(params.deployedToken), params.amount, true);
        actionParams[1] = abi.encode(
            params.poolKey,
            params.tickLower,
            params.tickUpper,
            memeIsCurrency0 ? amountMax : 0,
            memeIsCurrency0 ? 0 : amountMax,
            params.recipient,
            bytes("")
        );
        actionParams[2] =
            abi.encode(params.poolKey.currency0, params.poolKey.currency1, address(this));

        params.positionManager.modifyLiquidities(abi.encode(actions, actionParams), block.timestamp);

        uint128 minted = params.positionManager.getPositionLiquidity(tokenId);
        if (minted == 0) revert PositionNotMinted(tokenId);

        position = Position({tokenId: tokenId, liquidity: minted});
    }

    /// @dev Standard two-step Permit2 approval: ERC20 -> Permit2, then Permit2 -> spender. The
    /// Permit2 allowance expires with the current block and is decremented by the transfer.
    function _approveViaPermit2(
        address token,
        uint256 amount,
        IAllowanceTransfer permit2,
        address spender
    ) private {
        IERC20(token).forceApprove(address(permit2), amount);
        permit2.approve(token, spender, amount.toUint160(), uint48(block.timestamp));
    }
}
