// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {ILPManager} from "./interfaces/ILPManager.sol";
import {INonfungiblePositionManager} from "@uniswap-v3-periphery/interfaces/INonfungiblePositionManager.sol";
import "./interfaces/IGemoon.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IGemoon.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract LPManager is ILPManager, AccessControl {
    bytes32 public constant CONTROLLER_ROLE = keccak256("CONTROLLER_ROLE");

    INonfungiblePositionManager public positionManager;

    mapping(address => DeploymentInfo[]) public deployments;

    constructor(address positionManager_) {
        require(
            positionManager_ != address(0),
            "Position manager address cannot be zero"
        );

        positionManager = INonfungiblePositionManager(positionManager_);
        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
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

    function showDeploymentsForCreator(
        address creator
    ) external view returns (DeploymentInfo[] memory) {
        return deployments[creator];
    }

    function claimRewards(
        address token
    ) external override onlyRole(CONTROLLER_ROLE) returns (uint256 amount) {}

    function showRewardsForCreator(
        address creator
    ) external view override returns (uint256 amount) {}

    function addNewPosition(
        DeploymentInfo memory deployment
    ) external override onlyRole(CONTROLLER_ROLE) {
        deployments[deployment.creatorAdmin].push(deployment);
    }
}
