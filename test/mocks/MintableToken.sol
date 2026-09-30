// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice ERC20 with configurable decimals and open minting, for tests only.
contract MintableToken is ERC20 {
    uint8 private immutable i_decimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        i_decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
