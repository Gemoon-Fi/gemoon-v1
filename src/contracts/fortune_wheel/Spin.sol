// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Spin is Ownable {
    constructor() Ownable(msg.sender) {}

    uint256 private spinCount = 0;

    function spin() external payable {
        spinCount += 1;
    }

    function getSpinCount() external view onlyOwner returns (uint256) {
        return spinCount;
    }

    function withdraw() external onlyOwner {
        payable(owner()).transfer(address(this).balance);
    }
}
