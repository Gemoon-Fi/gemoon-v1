pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {LPManager} from "../src/contracts/LPManager.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

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

        GemoonController controller = new GemoonController();

        address proxy = address(
            new TransparentUpgradeableProxy(
                address(controller),
                msg.sender,
                abi.encodeCall(
                    GemoonController.initialize,
                    (
                        lpManager,
                        uniswapFactory,
                        uniswapPositionManager,
                        nativeToken,
                        msg.sender
                    )
                )
            )
        );

        // Grant CONTROLLER_ROLE to the controller address
        AccessControlUpgradeable(lpManager).grantRole(
            keccak256("CONTROLLER_ROLE"),
            address(controller)
        );

        console.log("Controller proxy: ", proxy);

        vm.stopBroadcast();
    }
}
