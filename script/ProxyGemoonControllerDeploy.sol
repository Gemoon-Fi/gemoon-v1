pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {LPManager} from "../src/contracts/LPManager.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@oz-upgrades/Upgrades.sol";

contract ProxyGemoonControllerDeploy is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address uniswapPositionManager = vm.envAddress(
            "UNISWAP_POSITION_MANAGER"
        );
        address nativeToken = vm.envAddress("NATIVE_TOKEN_ADDRESS");
        address lpManager = vm.envAddress("LP_MANAGER_PROXY_ADDRESS");
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

        address adminAddress = Upgrades.getAdminAddress(proxy);
        console.log("Proxy address: ", proxy);
        console.log("Proxy admin address: ", adminAddress);

        vm.stopBroadcast();
    }
}

contract ProxyGemoonControllerUpgrade is Script {
    function run() external {
        vm.startBroadcast();

        address uniswapPositionManager = vm.envAddress(
            "UNISWAP_POSITION_MANAGER"
        );
        address nativeToken = vm.envAddress("NATIVE_TOKEN_ADDRESS");
        address lpManager = vm.envAddress("LP_MANAGER_PROXY_ADDRESS");
        address uniswapFactory = vm.envAddress("UNISWAP_FACTORY");
        address proxyAddress = vm.envAddress("CONTROLLER_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("CONTROLLER_PROXY_ADMIN_ADDRESS");

        address lpManagerImpl = address(new GemoonController());

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxyAddress),
            lpManagerImpl,
            abi.encodeCall(
                GemoonController.reinitialize,
                (
                    lpManager,
                    uniswapFactory,
                    uniswapPositionManager,
                    nativeToken,
                    msg.sender
                )
            )
        );

        vm.stopBroadcast();
    }
}
