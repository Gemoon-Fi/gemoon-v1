pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import {GemoonController} from "../src/contracts/Gemoon.sol";
import {LPManager} from "../src/contracts/LPManager.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@oz-upgrades/Upgrades.sol";
import "../src/contracts/deploy_collectors/UniswapDeployCollector.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "../src/contracts/interfaces/IPosition.sol";

contract DeployGemoon is Script {
    function setUp() public {}

    function run() public {
        vm.startBroadcast();

        address uniswapPositionManager = vm.envAddress("UNISWAP_POSITION_MANAGER");
        address nativeToken = vm.envAddress("NATIVE_TOKEN_ADDRESS");
        address uniswapFactory = vm.envAddress("UNISWAP_FACTORY");
        uint256 creatorPercent = vm.envUint("CREATOR_FEE_PERCENT");
        address operatorAddress = vm.envAddress("OPERATOR_ADDRESS");

        // ----- DEPLOY LP MANAGER -----
        address lpManagerImpl = address(new LPManager());
        address lpManagerProxy = address(
            new TransparentUpgradeableProxy(
                lpManagerImpl, msg.sender, abi.encodeCall(LPManager.initialize, (creatorPercent, operatorAddress))
            )
        );

        address lpManagerAdminAddress = Upgrades.getAdminAddress(lpManagerProxy);

        // ---- DEPLOY GEMOON CONTROLLER ----
        UniswapDeployCollector strategy = new UniswapDeployCollector(uniswapPositionManager, address(lpManagerProxy));

        GemoonController controller = new GemoonController();

        address controllerProxy = address(
            new TransparentUpgradeableProxy(
                address(controller),
                msg.sender,
                abi.encodeCall(
                    GemoonController.initialize, (address(lpManagerProxy), uniswapFactory, nativeToken, operatorAddress)
                )
            )
        );

        address controllerAdminAddress = Upgrades.getAdminAddress(controllerProxy);

        // ----- LOGS -----
        console.log("MSG SENDER: ", msg.sender);
        console.log("OPERATOR ADDRESS: ", operatorAddress);

        // ---- LP MANAGER ----
        console.log("LP Manager Proxy address: ", address(lpManagerProxy));
        console.log("LP Manager implementation address: ", address(lpManagerImpl));
        console.log("LP Manager Proxy admin address: ", address(lpManagerAdminAddress));
        console.log("Uniswap strategy address:", address(strategy));

        // ---- CONTROLLER ----
        console.log("Controller Proxy address: ", address(controllerProxy));
        console.log("Controller implementation address: ", address(controller));
        console.log("Controller Proxy admin address: ", address(controllerAdminAddress));
        console.log("CREATOR PERCENT: ", creatorPercent);
        console.log("UNISWAP POSITION MANAGER: ", uniswapPositionManager);
        console.log("NATIVE TOKEN: ", nativeToken);
        console.log("UNISWAP FACTORY: ", uniswapFactory);

        vm.stopBroadcast();
    }
}

contract ProxyLPManagerUpgrade is Script {
    function run() external {
        vm.startBroadcast();

        address multisigOwner = vm.envAddress("MULTISIG_OWNER_ADDRESS");
        address proxy = vm.envAddress("LP_MANAGER_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("LP_MANAGER_PROXY_ADMIN_ADDRESS");

        address lpManagerImpl = address(new LPManager());

        uint256 creatorPercent = vm.envUint("CREATOR_FEE_PERCENT");

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxy),
            lpManagerImpl,
            abi.encodeCall(LPManager.reinitialize, (uint256(creatorPercent), multisigOwner))
        );

        vm.stopBroadcast();
    }
}

contract ProxyGemoonControllerUpgrade is Script {
    function run() external {
        vm.startBroadcast();

        address multisigOwner = vm.envAddress("MULTISIG_OWNER_ADDRESS");
        address uniswapPositionManager = vm.envAddress("UNISWAP_POSITION_MANAGER");
        address nativeToken = vm.envAddress("NATIVE_TOKEN_ADDRESS");
        address lpManager = vm.envAddress("LP_MANAGER_PROXY_ADDRESS");
        address uniswapFactory = vm.envAddress("UNISWAP_FACTORY");
        address proxyAddress = vm.envAddress("CONTROLLER_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("CONTROLLER_PROXY_ADMIN_ADDRESS");

        address controllerImpl = address(new GemoonController());

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxyAddress),
            controllerImpl,
            abi.encodeCall(GemoonController.reinitialize, (lpManager, uniswapFactory, nativeToken, multisigOwner))
        );

        vm.stopBroadcast();
    }
}
