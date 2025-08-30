pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "../src/contracts/fortune_wheel/Spin.sol";

contract FortuneWheelDeploy is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        Spin fortuneWheel = new Spin();

        console.log("FortuneWheel address: ", address(fortuneWheel));

        vm.stopBroadcast();
    }
}
