// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IGemoon.sol";
import "./Deployer.sol";
import "./interfaces/IToken.sol";
import "./interfaces/ILPManager.sol";
import "./utils/Admin.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract GemoonController is Ownable, IGemoonController {
    error UserNotFound();

    uint256 public _maxCreatorRewardPercent;
    uint256 public _maxDeployerRewardPercent;
    mapping(address => DeploymentInfo[]) public _deployers;
    ILPManager public _lpManager;

    constructor(
        uint256 maxCreatorReward_,
        uint256 maxDeployerReward_,
        address lpManager_
    ) {
        require(
            maxCreatorReward_ <= 100,
            "Max creator reward percent must be <= 100"
        );
        require(
            maxDeployerReward_ <= 100,
            "Max deployer reward percent must be <= 100"
        );

        _maxCreatorRewardPercent = maxCreatorReward_;
        _maxDeployerRewardPercent = maxDeployerReward_;
        _lpManager = ILPManager(lpManager_);
    }

    /// @dev Configuration for deploying a token.
    /// @notice Entry point for deploying a token.
    function deployToken(
        DeployConfig memory config
    ) external payable override returns (address) {
        TokenConfig memory tokenConfig = config.tokenConfig;

        address[] memory newAdmins = new address[](
            tokenConfig.admins.length + 2
        );
        for (uint256 i = 0; i < tokenConfig.admins.length; i++) {
            newAdmins[i] = tokenConfig.admins[i];
        }

        if (config.rewardsConfig.creatorAddress == address(0)) {
            config.rewardsConfig.creatorAddress = address(this);
        }

        if (config.rewardsConfig.rewardRecipient == address(0)) {
            config.rewardsConfig.rewardRecipient = address(this);
        }

        newAdmins[tokenConfig.admins.length] = address(this);
        newAdmins[tokenConfig.admins.length + 1] = address(msg.sender);
        tokenConfig.admins = newAdmins;

        address deployedToken = Deployer.deployToken(tokenConfig);

        // TODO: assign position id to deploy info
        _deployers[address(msg.sender)].push(DeploymentInfo(deployedToken, 0));

        emit TokenCreated(
            deployedToken,
            config.rewardsConfig.creatorAddress,
            config.rewardsConfig.rewardRecipient,
            0,
            config.tokenConfig.name,
            config.tokenConfig.symbol,
            0
        );

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
    ) external view override returns (DeploymentInfo[] memory) {
        if (_deployers[user].length == 0) {
            revert UserNotFound();
        }

        return _deployers[user];
    }

    function changeAdmin(
        address token,
        address oldAdmin,
        address newAdmin
    ) external override {
        Admin(token).replaceAdmin(newAdmin, oldAdmin);
    }

    function claimRewards(address token) external override {}

    function MAX_CREATOR_REWARD() external view override returns (uint256) {
        return _maxCreatorRewardPercent;
    }

    function MAX_DEPLOYER_REWARD() external view override returns (uint256) {
        return _maxDeployerRewardPercent;
    }

    receive() external payable {}

    fallback() external payable {}

    function balance() external view onlyOwner returns (uint256) {
        return address(this).balance;
    }

    function withdraw(address recipient, uint256 amount) external onlyOwner {
        payable(recipient).transfer(amount);
    }

    function withdrawERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyOwner {
        IERC20 erc20 = IERC20(token);

        uint256 _balance = erc20.balanceOf(address(this));
        require(
            _balance >= amount,
            "Insufficient balance to withdraw the specified amount"
        );

        erc20.transfer(to, amount);
    }
}
