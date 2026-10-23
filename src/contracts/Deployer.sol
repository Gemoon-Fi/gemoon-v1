// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {GemoonToken, TokenConfig, FeeInfo} from "./Token.sol";

library Deployer {
    function deployToken(
        TokenConfig memory config,
        FeeInfo memory feeInfo
    ) external returns (address) {
        GemoonToken token = new GemoonToken(config, msg.sender, feeInfo);

        return address(token);
    }
}
