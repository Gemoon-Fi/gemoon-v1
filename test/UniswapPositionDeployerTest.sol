// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "../src/contracts/deploy_collectors/UniswapDeployCollector.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract UniswapPositionDeployerTest is Test {
    function testCheckDeployerOwner() external {
        address uniswapPosManager = address(0x1);
        address lpManager = address(0x2);
        UniswapDeployCollector collector = new UniswapDeployCollector(
            uniswapPosManager,
            lpManager
        );

        assertEq(
            Ownable(collector).owner(),
            lpManager,
            "lpManager must be owner of this contract"
        );
    }

    function testClaimRewardNotFromLPManager_Revert() external {
        UniswapDeployCollector collector = new UniswapDeployCollector(
            address(0x1),
            address(0x2)
        );

        vm.expectRevert();
        collector.collectRewards(address(0x3), address(0x4));
    }
}
