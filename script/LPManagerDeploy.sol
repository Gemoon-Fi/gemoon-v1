pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {LPManager} from "../src/contracts/LPManager.sol";

contract GemoonDeploy is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        LPManager controller = new LPManager(address(0x0), address(0x0));

        vm.stopBroadcast();
    }
}
