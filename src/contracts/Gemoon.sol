// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IGemoon.sol";
import "./Deployer.sol";
import "./interfaces/IToken.sol";

contract GemoonController is Ownable, IGemoonController {
    uint256 private _maxCreatorRewardPercent;
    uint256 private _maxDeployerRewardPercent;

    constructor(uint256 maxCreatorReward_, uint256 maxDeployerReward_) {
        _maxCreatorRewardPercent = maxCreatorReward_;
        _maxDeployerRewardPercent = maxDeployerReward_;
    }

    function deployToken(
        DeployConfig memory config
    ) external payable override returns (address) {
        TokenConfig memory tc = config.tokenConfig;

        address[] memory newAdmins = new address[](tc.admins.length + 2);
        for (uint256 i = 0; i < tc.admins.length; i++) {
            newAdmins[i] = tc.admins[i];
        }

        newAdmins[tc.admins.length] = address(this);
        newAdmins[tc.admins.length + 1] = address(msg.sender);
        tc.admins = newAdmins;

        address deployedToken = Deployer.deployToken(tc);

        return deployedToken;
    }

    function deployTokenWithCustomTeamRewardRecipient(
        DeployConfig memory config,
        address teamRewardRecipient
    )
        external
        payable
        override
        returns (address tokenAddress, uint256 positionId)
    {}

    function getTokensDeployedByUser(
        address user
    ) external view override returns (DeploymentInfo[] memory) {}

    function changeAdmin(
        address oldAdmin,
        address newAdmin
    ) external override {}

    function claimRewards(address token) external override {}

    function MAX_CREATOR_REWARD() external pure override returns (uint256) {}

    function MAX_DEPLOYER_REWARD() external pure override returns (uint256) {}
}
