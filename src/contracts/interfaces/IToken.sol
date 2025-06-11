// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

uint8 constant DECIMALS = 18;

struct TokenConfig {
    string imgUrl;
    string description; //TODO: change to metadata
    string name;
    string symbol;
    address[] admins;
}

interface IGemoonToken is IERC20 {
    function imageAddress() external view returns (string memory);

    function updateImage(string memory addr) external;

    function description() external view returns (string memory);

    function changeDescription(string memory desc_) external;

    function showAdmins() external view returns (address[] memory);

    event UpdateImage(string newAddress);

    event UpdateDescription(string newDescription);
}
