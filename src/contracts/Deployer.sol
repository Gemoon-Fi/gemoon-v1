// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.20;

import {GemoonToken, TokenConfig} from "./Token.sol";

library Deployer {
	function deployToken(TokenConfig memory config) external returns(address) {
		GemoonToken token = new GemoonToken(config);

		return address(token);
	}
}
