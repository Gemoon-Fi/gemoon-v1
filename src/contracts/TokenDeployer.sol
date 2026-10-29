// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity 0.8.26;

import {GemoonToken} from "./Token.sol";
import {TokenConfig, FeeInfo} from "./interfaces/IToken.sol";
import {ITokenDeployer} from "./interfaces/ITokenDeployer.sol";

/// @title Meme token deployer.
/// @notice Creates the token of every new Meme for `GemoonController.deployToken` and returns its
///         address, nothing else. The controller calls it through `ITokenDeployer`, so new token
///         code needs only a new TokenDeployer and `GemoonController.setTokenDeployer`, not a new
///         controller implementation. Memes deployed before keep their code.
/// @dev Not upgradeable, no owner, no storage: the controller it serves is immutable. Only that
/// controller can deploy, so every token created here is a Meme of the controller.
contract TokenDeployer is ITokenDeployer {
    /// @dev GemoonController proxy, the only caller of `deployToken`.
    address private immutable i_controller;

    /// @param controller_ GemoonController proxy this deployer serves.
    constructor(address controller_) {
        if (controller_ == address(0)) revert ZeroAddress();
        i_controller = controller_;
    }

    /// @inheritdoc ITokenDeployer
    function controller() external view returns (address) {
        return i_controller;
    }

    /// @inheritdoc ITokenDeployer
    function deployToken(
        TokenConfig calldata config,
        address creator,
        FeeInfo calldata feeInfo
    ) external returns (address) {
        if (msg.sender != i_controller) revert NotController();
        return address(new GemoonToken(config, creator, feeInfo, msg.sender));
    }
}
