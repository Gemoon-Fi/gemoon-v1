pragma solidity ^0.8.20;

library TimeMath {
    function getTimeElapsed(
        uint256 startTime,
        uint256 endTime
    ) internal pure returns (uint256) {
        require(
            endTime >= startTime,
            "End time must be greater than or equal to start time"
        );
        return endTime - startTime;
    }

    function getPercentageElapsed(
        uint256 startTime,
        uint256 endTime,
        uint256 totalTime
    ) internal pure returns (uint256) {
        if (totalTime == 0 || endTime <= startTime) {
            return 0;
        }
        uint256 elapsedTime = getTimeElapsed(startTime, endTime);
        return (elapsedTime * 10000) / totalTime;
    }
}
