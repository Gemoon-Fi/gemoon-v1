pragma solidity ^0.8.21;

import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {LPManager} from "../src/contracts/LPManager.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@oz-upgrades/Upgrades.sol";

contract ProxyLPManagerDeploy is Script {
    function run() external {
        vm.startBroadcast();

        uint256 creatorPercent = vm.envUint("CREATOR_FEE_PERCENT");

        address lpManagerImpl = address(new LPManager());
        address proxy = address(
            new TransparentUpgradeableProxy(
                lpManagerImpl,
                msg.sender,
                abi.encodeCall(
                    LPManager.initialize,
                    (creatorPercent, msg.sender)
                )
            )
        );

        address adminAddress = Upgrades.getAdminAddress(proxy);
        console.log("Proxy address: ", proxy);
        console.log("Proxy admin address: ", adminAddress);

        vm.stopBroadcast();
    }
}

contract ProxyLPManagerUpgrade is Script {
    function run() external {
        vm.startBroadcast();

        address proxy = vm.envAddress("LP_MANAGER_PROXY_ADDRESS");
        address proxyAdmin = vm.envAddress("LP_MANAGER_PROXY_ADMIN_ADDRESS");

        address lpManagerImpl = address(new LPManager());

        uint256 creatorPercent = vm.envUint("CREATOR_FEE_PERCENT");

        ProxyAdmin(proxyAdmin).upgradeAndCall(
            ITransparentUpgradeableProxy(proxy),
            lpManagerImpl,
            abi.encodeCall(
                LPManager.reinitialize,
                (uint256(creatorPercent), msg.sender)
            )
        );

        vm.stopBroadcast();
    }
}
