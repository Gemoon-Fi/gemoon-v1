// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import "../src/contracts/LPManager.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "../src/contracts/interfaces/IPosition.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PositionFeeCollectorStub is IFeeCollector {
    constructor() {}

    function collectRewards(address, /*creator*/ address /*pool*/ )
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return (100, 100);
    }
}

contract UniPoolStub {
    address public token0;
    address public token1;

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
    }
}

contract StubERC20OnlyTransferToken {
    mapping(address => uint256) balances;

    constructor() {}

    function setBalanceFor(address addrFor, uint256 balance) public {
        balances[addrFor] = balance;
    }

    function balanceOf(address account) external view returns (uint256) {
        return balances[account];
    }

    function transfer(address to, uint256 value) external returns (bool) {
        balances[to] += value;
        return true;
    }
}

contract LpManagerTest is Test {
    function testCheckAdminAfterInitialization_Sucess() external {
        LPManager lpm = new LPManager();
        lpm.initialize(50, msg.sender);

        assertTrue(
            AccessControl(address(lpm)).hasRole(lpm.DEFAULT_ADMIN_ROLE(), msg.sender),
            "msg sender is not contract admin"
        );
    }

    function testDoubleInitializationWillBeFailed() external {
        LPManager lpm = new LPManager();

        lpm.initialize(50, address(this));
        vm.expectRevert();
        lpm.initialize(50, address(this));
    }

    function testGrantControllerRole_AndAddNewPosition_Success() external {
        LPManager lpm = new LPManager();

        lpm.initialize(50, address(this));

        AccessControlUpgradeable(address(lpm)).grantRole(lpm.CONTROLLER_ROLE(), address(this));

        assertTrue(
            AccessControl(address(lpm)).hasRole(lpm.DEFAULT_ADMIN_ROLE(), address(this)),
            "test contract is not contract admin"
        );

        assertTrue(
            AccessControlUpgradeable(address(lpm)).hasRole(lpm.CONTROLLER_ROLE(), address(this)),
            "no CONTROLLER_ROLE for msg.sender"
        );

        lpm.addNewPosition(
            DeploymentInfo({
                token0: address(0x1),
                token1: address(0x2),
                lowerTick: 1,
                upperTick: 2,
                positionId: 3,
                poolId: address(0x4),
                rewardRecipient: address(0x5),
                creatorAdmin: address(0x5),
                feeCollector: IFeeCollector(address(0x6))
            })
        );

        PositionID posHash = positionID(address(0x4), address(0x5));
        (,,,,, address poolId,,,) = lpm.deployments(posHash);

        assertEq(poolId, address(0x4), "pool address must be stored in LPManager deployments");
    }

    function testCreatorCanClaimRewards_SuccessBecauseInitiatorIsProtocolAdmin() external {
        LPManager lpm = new LPManager();

        lpm.initialize(50, address(this));

        AccessControlUpgradeable(address(lpm)).grantRole(lpm.CONTROLLER_ROLE(), address(this));

        address adminOfPosition = address(0x5);

        address token0 = address(new StubERC20OnlyTransferToken());
        address token1 = address(new StubERC20OnlyTransferToken());

        UniPoolStub uniPool = new UniPoolStub(token0, token1);

        lpm.addNewPosition(
            DeploymentInfo({
                token0: token0,
                token1: token1,
                lowerTick: 1,
                upperTick: 2,
                positionId: 3,
                poolId: address(uniPool),
                rewardRecipient: adminOfPosition,
                creatorAdmin: adminOfPosition,
                feeCollector: IFeeCollector(new PositionFeeCollectorStub())
            })
        );

        PositionID posHash = positionID(address(uniPool), address(adminOfPosition));
        (,,,,, address poolId,,,) = lpm.deployments(posHash);

        assertEq(poolId, address(uniPool), "pool address must be stored in LPManager deployments");

        (uint256 amount0, uint256 amount1) = lpm.claimRewards(adminOfPosition, address(uniPool));

        assertEq(IERC20(token0).balanceOf(adminOfPosition), 50, "invalid balance");

        assertEq(amount0, 50, "amount0 must be half of full claimed fee");
        assertEq(amount1, 50, "amount1 must be half of full claimed fee");
    }

    function testCreatorCanClaimRewards_FailAccessToClaimRewards() external {
        address protocolAdmin = address(0x123);
        LPManager lpm = new LPManager();
        lpm.initialize(50, protocolAdmin);

        address adminOfPosition = address(0x5);

        address token0 = address(new StubERC20OnlyTransferToken());
        address token1 = address(new StubERC20OnlyTransferToken());

        UniPoolStub uniPool = new UniPoolStub(token0, token1);

        vm.expectRevert();
        lpm.claimRewards(adminOfPosition, address(uniPool));
    }

    function testCreatorCanClaimRewards_FailBecauseCreatorAndPoolAddressesIsInvalid() external {
        LPManager lpm = new LPManager();
        lpm.initialize(50, address(this));

        // creator address is invalid
        vm.expectRevert();
        lpm.claimRewards(address(0x0), address(0x0));

        // pool address is invalid
        vm.expectRevert();
        lpm.claimRewards(address(0x1), address(0x0));
    }

    function testShowRewards_Success() external {
        LPManager lpm = new LPManager();

        lpm.initialize(50, address(this));

        AccessControlUpgradeable(address(lpm)).grantRole(lpm.CONTROLLER_ROLE(), address(this));

        address adminOfPosition = address(0x5);

        address token0 = address(new StubERC20OnlyTransferToken());
        address token1 = address(new StubERC20OnlyTransferToken());

        UniPoolStub uniPool = new UniPoolStub(token0, token1);

        lpm.addNewPosition(
            DeploymentInfo({
                token0: token0,
                token1: token1,
                lowerTick: 1,
                upperTick: 2,
                positionId: 3,
                poolId: address(uniPool),
                rewardRecipient: adminOfPosition,
                creatorAdmin: adminOfPosition,
                feeCollector: IFeeCollector(new PositionFeeCollectorStub())
            })
        );

        PositionID posHash = positionID(address(uniPool), address(adminOfPosition));
        (,,,,, address poolId,,,) = lpm.deployments(posHash);

        assertEq(poolId, address(uniPool), "pool address must be stored in LPManager deployments");

        lpm.claimRewards(adminOfPosition, address(uniPool));

        uint256 rewardForToken0 = lpm.showRewards(token0);
        uint256 rewardForToken1 = lpm.showRewards(token0);

        assertEq(rewardForToken0, 50, "invalid reward");
        assertEq(rewardForToken1, 50, "invalid reward");

        lpm.withdrawRewards(token0, address(0x0));
        lpm.withdrawRewards(token1, address(0x0));

        assertEq(IERC20(token0).balanceOf(address(this)), 50, "invalid token0 balance");
        assertEq(IERC20(token1).balanceOf(address(this)), 50, "invalid token1 balance");
    }

    function testClaimRewards_WithdrawToSpecifiedAddress() external {
        LPManager lpm = new LPManager();

        lpm.initialize(50, address(this));

        AccessControlUpgradeable(address(lpm)).grantRole(lpm.CONTROLLER_ROLE(), address(this));

        address adminOfPosition = address(0x5);

        address token0 = address(new StubERC20OnlyTransferToken());
        address token1 = address(new StubERC20OnlyTransferToken());

        UniPoolStub uniPool = new UniPoolStub(token0, token1);

        lpm.addNewPosition(
            DeploymentInfo({
                token0: token0,
                token1: token1,
                lowerTick: 1,
                upperTick: 2,
                positionId: 3,
                poolId: address(uniPool),
                rewardRecipient: adminOfPosition,
                creatorAdmin: adminOfPosition,
                feeCollector: IFeeCollector(new PositionFeeCollectorStub())
            })
        );

        PositionID posHash = positionID(address(uniPool), address(adminOfPosition));
        (,,,,, address poolId,,,) = lpm.deployments(posHash);

        assertEq(poolId, address(uniPool), "pool address must be stored in LPManager deployments");

        lpm.claimRewards(adminOfPosition, address(uniPool));

        uint256 rewardForToken0 = lpm.showRewards(token0);
        uint256 rewardForToken1 = lpm.showRewards(token0);

        assertEq(rewardForToken0, 50, "invalid rewards amount");
        assertEq(rewardForToken1, 50, "invalid rewards amount");

        address rewardsRecipient = address(0x1337);

        lpm.withdrawRewards(token0, rewardsRecipient);
        lpm.withdrawRewards(token1, rewardsRecipient);

        assertEq(IERC20(token0).balanceOf(rewardsRecipient), 50, "invalid token0 balance");
        assertEq(IERC20(token1).balanceOf(rewardsRecipient), 50, "invalid token1 balance");
    }

    function testShowRewards_FailBecauseNotProtocolAdminInitiateRewardsWithdrawal() external {
        LPManager lpm = new LPManager();

        lpm.initialize(50, address(this));

        AccessControlUpgradeable(address(lpm)).grantRole(lpm.CONTROLLER_ROLE(), address(this));

        address adminOfPosition = address(0x5);

        address token0 = address(new StubERC20OnlyTransferToken());
        address token1 = address(new StubERC20OnlyTransferToken());

        UniPoolStub uniPool = new UniPoolStub(token0, token1);

        lpm.addNewPosition(
            DeploymentInfo({
                token0: token0,
                token1: token1,
                lowerTick: 1,
                upperTick: 2,
                positionId: 3,
                poolId: address(uniPool),
                rewardRecipient: adminOfPosition,
                creatorAdmin: adminOfPosition,
                feeCollector: IFeeCollector(new PositionFeeCollectorStub())
            })
        );

        PositionID posHash = positionID(address(uniPool), address(adminOfPosition));
        (,,,,, address poolId,,,) = lpm.deployments(posHash);

        assertEq(poolId, address(uniPool), "pool address must be stored in LPManager deployments");

        lpm.claimRewards(adminOfPosition, address(uniPool));

        uint256 rewardForToken0 = lpm.showRewards(token0);
        uint256 rewardForToken1 = lpm.showRewards(token0);

        assertEq(rewardForToken0, 50, "invalid reward");
        assertEq(rewardForToken1, 50, "invalid reward");

        // replace the protocol admin
        vm.prank(address(0x123));
        vm.expectRevert();
        lpm.withdrawRewards(token0, address(0x0));
    }
}
