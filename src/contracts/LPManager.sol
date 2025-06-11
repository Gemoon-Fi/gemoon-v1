// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {ILPManager} from "./interfaces/ILPManager.sol";
import {INonfungiblePositionManager} from "@uniswap-v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IGemoon.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IGemoon.sol";

contract LPManager is ILPManager, Ownable {
    INonfungiblePositionManager public positionManager;

    mapping(address => DeploymentInfo[]) private _deployments;

    constructor(address positionManager_) {
        require(
            positionManager_ != address(0),
            "Position manager address cannot be zero"
        );

        positionManager = INonfungiblePositionManager(positionManager_);
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

    function claimRewards(
        address token
    ) external override onlyOwner returns (uint256 amount) {}

    function showRewardsForCreator(
        address creator
    ) external view override returns (uint256 amount) {}

    function addNewPosition(
        DeploymentInfo memory deployment
    ) external override onlyOwner {
        _deployments[deployment.creatorAdmin].push(deployment);
    }
}
