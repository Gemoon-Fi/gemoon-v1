// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GemoonToken} from "../../src/contracts/Token.sol";
import {TokenConfig, FeeInfo} from "../../src/contracts/interfaces/IToken.sol";
import {ITokenDeployer} from "../../src/contracts/interfaces/ITokenDeployer.sol";

/// @dev Next version of the Meme token code: GemoonToken plus a marker function.
contract GemoonTokenV2Mock is GemoonToken {
    constructor(
        TokenConfig memory config,
        address creator_,
        FeeInfo memory feeInfo_,
        address supplyRecipient_
    ) GemoonToken(config, creator_, feeInfo_, supplyRecipient_) {}

    function tokenVersion() external pure returns (uint256) {
        return 2;
    }
}

/// @dev TokenDeployer of `GemoonTokenV2Mock`, same rules as `TokenDeployer`.
contract TokenDeployerV2Mock is ITokenDeployer {
    address public immutable controller;

    constructor(address controller_) {
        controller = controller_;
    }

    function deployToken(TokenConfig calldata config, address creator, FeeInfo calldata feeInfo)
        external
        returns (address)
    {
        if (msg.sender != controller) revert NotController();
        return address(new GemoonTokenV2Mock(config, creator, feeInfo, msg.sender));
    }
}

/// @dev Plain ERC20 minting `toCaller` to `caller` and `toOther` to `other`.
contract SplitSupplyToken is ERC20 {
    constructor(address caller, uint256 toCaller, address other, uint256 toOther)
        ERC20("Split", "SPLIT")
    {
        if (toCaller != 0) _mint(caller, toCaller);
        if (toOther != 0) _mint(other, toOther);
    }
}

/// @dev Token code that does not hand the controller exactly the whole supply, or does: the
/// controller must accept only the latter.
contract SplitSupplyTokenDeployer is ITokenDeployer {
    address public immutable controller;
    uint256 internal immutable i_toCaller;
    address internal immutable i_other;
    uint256 internal immutable i_toOther;

    constructor(address controller_, uint256 toCaller, address other, uint256 toOther) {
        controller = controller_;
        i_toCaller = toCaller;
        i_other = other;
        i_toOther = toOther;
    }

    function deployToken(TokenConfig calldata, address, FeeInfo calldata)
        external
        returns (address)
    {
        if (msg.sender != controller) revert NotController();
        return address(new SplitSupplyToken(msg.sender, i_toCaller, i_other, i_toOther));
    }
}
