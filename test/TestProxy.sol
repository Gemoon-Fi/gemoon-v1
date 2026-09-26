// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "forge-std/Script.sol";
import "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console} from "forge-std/console.sol";
import "../src/contracts/Gemoon.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";

contract TestProxy is Test {
    function testControllerOwner() external {
        GemoonController controllerImpl = new GemoonController();

        address proxy = address(
            new TransparentUpgradeableProxy(
                address(controllerImpl),
                msg.sender,
                abi.encodeCall(GemoonController.initialize, (address(2), address(4), msg.sender))
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
                abi.encodeCall(GemoonController.initialize, (address(2), address(4), msg.sender))
            )
        );

        address newOwner = address(0x1234);

        console.log("Current owner: ", OwnableUpgradeable(proxy).owner());
        console.log("MSG SENDER: ", msg.sender);

        vm.prank(msg.sender);
        OwnableUpgradeable(proxy).transferOwnership(newOwner);


        assertEq(OwnableUpgradeable(proxy).owner(), newOwner, "Owner mismatch");
    }
}
