// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import "../src/contracts/utils/TimeMath.sol";

contract TestTimeMath is Test {
    function testGetTimeElapsed() external view {
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 100;

        uint256 elapsedTime = TimeMath.getTimeElapsed(startTime, endTime);

        console.logUint(elapsedTime);

        assertEq(elapsedTime, 100, "Elapsed time should be 100 seconds");
    }

    function testGetTimeElapsed_one_minute() external view {
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + 60;

        uint256 elapsedTime = TimeMath.getTimeElapsed(startTime, endTime);

        console.logUint(elapsedTime);

        assertEq(elapsedTime, 60, "Elapsed time should be 60 seconds");
    }

    function testGetPercentageTimeElapsed() external view {
        uint256 total = 1 minutes;
        uint256 startTime = block.timestamp;
        uint256 endTime = block.timestamp;

        uint256 elapsedPercent_0 = TimeMath.getPercentageElapsed(
            startTime,
            endTime,
            total
        );

        uint256 elapsedPercent_1 = TimeMath.getPercentageElapsed(
            startTime,
            endTime + 20,
            total
        );

        uint256 elapsedPercent_2 = TimeMath.getPercentageElapsed(
            startTime,
            endTime + 50,
            total
        );

        uint256 elapsedPercent_3 = TimeMath.getPercentageElapsed(
            startTime,
            endTime + 1 minutes,
            total
        );

        assertEq(elapsedPercent_0, 0, "Elapsed time should be 0%");
        assertEq(elapsedPercent_1, 3333, "Elapsed time should be 0%");
        assertEq(elapsedPercent_2, 8333, "Elapsed time should be 0%");
        assertEq(elapsedPercent_3, 10000, "Elapsed time should be 0%");
    }
}
