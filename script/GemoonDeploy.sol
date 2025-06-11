pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {LPManager} from "../src/contracts/LPManager.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

contract GemoonDeploy is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address uniswapPositionManager = vm.envAddress(
            "UNISWAP_POSITION_MANAGER"
        );
        address nativeToken = vm.envAddress("NATIVE_TOKEN_ADDRESS");
        address lpManager = vm.envAddress("LP_MANAGER");
        address uniswapFactory = vm.envAddress("UNISWAP_FACTORY");

        GemoonController controller = new GemoonController(
            60,
            40,
            lpManager,
            uniswapFactory,
            uniswapPositionManager,
            nativeToken
        );

        // Grant CONTROLLER_ROLE to the controller address
        AccessControl(lpManager).grantRole(
            keccak256("CONTROLLER_ROLE"),
            address(controller)
        );

        vm.stopBroadcast();
    }
}
