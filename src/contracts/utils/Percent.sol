// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

library Percent {
    uint256 constant PRECISION = 1e18;

    function toPercent(uint256 percent) internal pure returns (uint256) {
        return percent * 1e16;
    }

    function mulPercent(uint256 value, uint256 percent) internal pure returns (uint256) {
        return value * toPercent(percent) / PRECISION;
    }

    function subPercent(uint256 value, uint256 percent) internal pure returns (uint256) {
        return value - mulPercent(value, percent);
    }

    function addPercent(uint256 value, uint256 percent) internal pure returns (uint256) {
        return value + mulPercent(value, percent);
    }

    function percentOf(uint256 value, uint256 percent) internal pure returns (uint256) {
        return mulPercent(value, percent);
    }
}
