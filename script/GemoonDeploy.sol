pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";

contract GemoonDeploy is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        GemoonController controller = new GemoonController(40, 60, address(0x0));

        vm.stopBroadcast();
    }
}
