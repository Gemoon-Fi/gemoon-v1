// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TokenConfig, FeeInfo} from "./IToken.sol";

/// @notice Creates the token of a new Meme for `GemoonController.deployToken`. The controller holds
///         it as a replaceable dependency (`setTokenDeployer`): new token code is a new deployer,
///         the controller stays as it is.
interface ITokenDeployer {
    /// @dev Constructor got the zero address as controller.
    error ZeroAddress();
    /// @dev `deployToken` called by anyone but the controller.
    error NotController();

    /// @notice GemoonController allowed to call `deployToken`, fixed at deployment.
    /// @return Controller proxy.
    function controller() external view returns (address);

    /// @notice Deploys the token of a new Meme and returns its address. The whole supply
    ///         (`INITIAL_SUPPLY_X18`, 18 decimals) is minted to the caller, the controller, which
    ///         puts it into the pool position.
    /// @dev Only the controller. The inputs are checked by the controller beforehand.
    /// @param config  Token metadata and admins, as completed by the controller.
    /// @param creator Caller of `GemoonController.deployToken`, reported by the token's `creator()`.
    /// @param feeInfo Swap fee split written into the token.
    /// @return token  Address of the new token.
    function deployToken(
        TokenConfig calldata config,
        address creator,
        FeeInfo calldata feeInfo
    ) external returns (address token);
}
