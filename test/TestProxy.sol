// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console} from "forge-std/console.sol";
import "../src/contracts/LPManager.sol";
import "../src/contracts/Gemoon.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract TestProxy is Test {
    function testProxyLPManagerAdminRole() external {
        LPManager lpManagerImpl = new LPManager();

        address proxy = address(
            new TransparentUpgradeableProxy(
                address(lpManagerImpl), address(msg.sender), abi.encodeCall(LPManager.initialize, (50, msg.sender))
            )
        );

        // Default value of admin role is bytes32(0x00)
        bytes32 adminRole;

        console.logBytes32(adminRole);
        console.logAddress(msg.sender);
        console.logAddress(address(this));

        AccessControl proxyLPManager = AccessControl(proxy);
        assertEq(proxyLPManager.hasRole(adminRole, address(msg.sender)), true, "Caller should be admin of LP manager");
    }

    function testProxyLPManagerCorrectInitializeData() external {
        LPManager lpManagerImpl = new LPManager();

        address proxy = address(
            new TransparentUpgradeableProxy(
                address(lpManagerImpl), address(msg.sender), abi.encodeCall(LPManager.initialize, (50, msg.sender))
            )
        );

        assertEq(uint256(LPManager(proxy).creatorFeePercent()), 50, "Creator percent mismatch");
    }

    function testControllerOwner() external {
        GemoonController controllerImpl = new GemoonController();

        address proxy = address(
            new TransparentUpgradeableProxy(
                address(controllerImpl),
                msg.sender,
                abi.encodeCall(GemoonController.initialize, (address(1), address(2), address(4), msg.sender))
            )
        );

        assertEq(OwnableUpgradeable(proxy).owner(), msg.sender, "Owner mismatch");
    }

    function testControllerProxyChangeAdmin() external {
        GemoonController controllerImpl = new GemoonController();

        address proxy = address(
            new TransparentUpgradeableProxy(
                address(controllerImpl),
                msg.sender,
                abi.encodeCall(GemoonController.initialize, (address(1), address(2), address(4), msg.sender))
            )
        );

        address newOwner = address(0x1234);

        console.log("Current owner: ", OwnableUpgradeable(proxy).owner());
        console.log("MSG SENDER: ", msg.sender);

        OwnableUpgradeable(proxy).transferOwnership(newOwner);


        assertEq(OwnableUpgradeable(proxy).owner(), newOwner, "Owner mismatch");
    }
}
