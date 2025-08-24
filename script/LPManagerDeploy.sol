pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {LPManager} from "../src/contracts/LPManager.sol";

contract LPManagerDeploy is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address manager = vm.envAddress("UNISWAP_POSITION_MANAGER");

        uint256 creatorPercent = 50;

        LPManager controller = new LPManager(manager, creatorPercent);

        vm.stopBroadcast();
    }
}
