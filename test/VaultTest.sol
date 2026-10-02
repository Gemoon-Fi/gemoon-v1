// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Vault} from "../src/contracts/vault/Vault.sol";
import {
    IVault,
    AssetConfig,
    VaultInfo
} from "../src/contracts/interfaces/IVault.sol";
import {ISwapAdapter} from "../src/contracts/interfaces/ISwapAdapter.sol";

contract MockToken is ERC20 {
    uint8 private immutable i_decimals;

    constructor(
        string memory symbol_,
        uint8 decimals_
    ) ERC20(symbol_, symbol_) {
        i_decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return i_decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Keeps the input and mints `amountIn * rate / 1e18` of the output to the recipient.
/// `shouldRevert` simulates a failing swap (slippage, missing route, stale oracle).
contract MockSwapAdapter is ISwapAdapter {
    mapping(address => uint256) public rate;
    bool public shouldRevert;
    bool public revertEmpty;

    function setRate(address tokenOut, uint256 rate_) external {
        rate[tokenOut] = rate_;
    }

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    /// @dev Reverts without data, like an out-of-gas or a bare `revert()`.
    function setRevertEmpty(bool revertEmpty_) external {
        revertEmpty = revertEmpty_;
    }

    function swap(
        address,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut) {
        require(!shouldRevert, "adapter: revert");
        if (revertEmpty) {
            assembly {
                revert(0, 0)
            }
        }
        amountOut = (amountIn * rate[tokenOut]) / 1e18;
        MockToken(tokenOut).mint(recipient, amountOut);
    }
}

abstract contract VaultFixture is Test {
    Vault vault;
    MockToken usdg;
    MockToken meme;
    MockToken aapl;
    MockToken wbtc;
    MockSwapAdapter adapter;

    address owner = makeAddr("owner");
    address proxyAdminOwner = makeAddr("proxyAdminOwner");
    address controller = makeAddr("controller");
    address hook = makeAddr("hook");
    address creator = makeAddr("creator");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function _deployVault() internal {
        usdg = new MockToken("USDG", 6);
        meme = new MockToken("MEME", 18);
        aapl = new MockToken("AAPL", 18);
        wbtc = new MockToken("WBTC", 8);
        adapter = new MockSwapAdapter();
        adapter.setRate(address(aapl), 2e30); // 1 USDG (1e6) -> 2 AAPL (2e18)
        adapter.setRate(address(wbtc), 1e20); // 1 USDG (1e6) -> 1e8 units

        vault = Vault(
            address(
                new TransparentUpgradeableProxy(
                    address(new Vault()),
                    proxyAdminOwner,
                    abi.encodeCall(Vault.initialize, (owner, address(usdg)))
                )
            )
        );
        vm.startPrank(owner);
        vault.setController(controller);
        vault.setHook(hook);
        vault.setSwapAdapter(address(adapter));
        vault.setAssetAllowed(address(aapl), true);
        vault.setAssetAllowed(address(wbtc), true);
        vault.setAssetAllowed(address(usdg), true);
        vm.stopPrank();
    }

    function _assets6040() internal view returns (AssetConfig[] memory assets) {
        assets = new AssetConfig[](2);
        assets[0] = AssetConfig({token: address(aapl), weightBps: 6_000});
        assets[1] = AssetConfig({token: address(wbtc), weightBps: 4_000});
    }

    function _assetsUsdgOnly()
        internal
        view
        returns (AssetConfig[] memory assets)
    {
        assets = new AssetConfig[](1);
        assets[0] = AssetConfig({token: address(usdg), weightBps: 10_000});
    }

    function _register(AssetConfig[] memory assets) internal {
        vm.prank(controller);
        vault.registerVault(address(meme), creator, assets);
    }

    function _notify(uint256 amount) internal {
        usdg.mint(address(vault), amount);
        vm.prank(hook);
        vault.notifyFees(address(meme), amount);
    }

    function _convert() internal returns (uint256[] memory) {
        return vault.convertFees(address(meme));
    }

    function _stake(address account, uint256 amount) internal {
        meme.mint(account, amount);
        vm.startPrank(account);
        meme.approve(address(vault), amount);
        vault.stake(address(meme), amount);
        vm.stopPrank();
    }

    function _earned(
        address account,
        uint256 index
    ) internal view returns (uint256) {
        (, uint256[] memory amounts) = vault.earned(address(meme), account);
        return amounts[index];
    }

    function _creatorAccrued(uint256 index) internal view returns (uint256) {
        (, uint256[] memory amounts) = vault.creatorAccrued(address(meme));
        return amounts[index];
    }
}

contract VaultTest is VaultFixture {
    function setUp() external {
        _deployVault();
    }

    // ------------------------------------------------------------------ registration

    function test_RegisterVault_NotController_Reverts() external {
        vm.expectRevert(IVault.NotController.selector);
        vault.registerVault(address(meme), creator, _assets6040());
    }

    function test_RegisterVault_Valid_StoresConfig() external {
        _register(_assets6040());
        assertTrue(vault.isRegistered(address(meme)));
        assertEq(vault.creatorOf(address(meme)), creator);
        AssetConfig[] memory assets = vault.getAssets(address(meme));
        assertEq(assets.length, 2);
        assertEq(assets[0].token, address(aapl));
        assertEq(assets[1].weightBps, 4_000);
    }

    function test_RegisterVault_Twice_Reverts() external {
        _register(_assets6040());
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.VaultAlreadyRegistered.selector,
                address(meme)
            )
        );
        vault.registerVault(address(meme), creator, _assets6040());
    }

    function test_RegisterVault_WeightsNotBps_Reverts() external {
        AssetConfig[] memory assets = _assets6040();
        assets[1].weightBps = 3_999;
        vm.prank(controller);
        vm.expectRevert(IVault.InvalidWeights.selector);
        vault.registerVault(address(meme), creator, assets);
    }

    function test_RegisterVault_AssetNotAllowed_Reverts() external {
        AssetConfig[] memory assets = _assets6040();
        assets[0].token = address(meme);
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.AssetNotAllowed.selector,
                address(meme)
            )
        );
        vault.registerVault(address(meme), creator, assets);
    }

    function test_RegisterVault_DuplicateAsset_Reverts() external {
        AssetConfig[] memory assets = _assets6040();
        assets[1].token = address(aapl);
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.DuplicateAsset.selector,
                address(aapl)
            )
        );
        vault.registerVault(address(meme), creator, assets);
    }

    function test_RegisterVault_NoAssets_Reverts() external {
        vm.prank(controller);
        vm.expectRevert(IVault.InvalidAssetsLength.selector);
        vault.registerVault(address(meme), creator, new AssetConfig[](0));
    }

    // ------------------------------------------------------------------ fee intake

    function test_NotifyFees_NotHook_Reverts() external {
        _register(_assets6040());
        usdg.mint(address(vault), 1e6);
        vm.expectRevert(IVault.NotHook.selector);
        vault.notifyFees(address(meme), 1e6);
    }

    function test_NotifyFees_UnregisteredMeme_Reverts() external {
        vm.prank(hook);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.VaultNotRegistered.selector,
                address(meme)
            )
        );
        vault.notifyFees(address(meme), 1e6);
    }

    function test_NotifyFees_WithoutTransfer_Reverts() external {
        _register(_assets6040());
        vm.prank(hook);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.UnaccountedBalanceTooLow.selector,
                0,
                1e6
            )
        );
        vault.notifyFees(address(meme), 1e6);
    }

    function test_NotifyFees_SameTransferTwice_Reverts() external {
        _register(_assets6040());
        _notify(1e6);
        vm.prank(hook);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.UnaccountedBalanceTooLow.selector,
                0,
                1e6
            )
        );
        vault.notifyFees(address(meme), 1e6);
    }

    function test_NotifyFees_NoStakers_AllToCreator() external {
        _register(_assets6040());
        _notify(100e6);
        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.pendingCreatorUSDG, 100e6);
        assertEq(info.pendingStakerUSDG, 0);
    }

    function test_NotifyFees_WithStakers_TenPercentToCreator() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.pendingCreatorUSDG, 10e6);
        assertEq(info.pendingStakerUSDG, 90e6);
        assertEq(vault.pendingCreditOf(address(meme), alice), 90e6);
    }

    // ------------------------------------------------------------------ conversion

    function test_ConvertFees_Nothing_Reverts() external {
        _register(_assets6040());
        vm.expectRevert(IVault.NothingToConvert.selector);
        vault.convertFees(address(meme));
    }

    function test_ConvertFees_NotRegistered_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.VaultNotRegistered.selector,
                address(meme)
            )
        );
        vault.convertFees(address(meme));
    }

    function test_ConvertFees_SplitsByWeight() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        uint256[] memory out = _convert();

        assertEq(out[0], 120e18, "60 USDG -> 120 AAPL");
        assertEq(out[1], 40e8, "40 USDG -> 40 WBTC units of 1e8");
        assertEq(_creatorAccrued(0), 12e18, "10% AAPL to creator");
        assertEq(_creatorAccrued(1), 4e8, "10% WBTC to creator");
        assertEq(_earned(alice, 0), 108e18);
        assertEq(_earned(alice, 1), 36e8);
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(vault.vaultInfo(address(meme)).epoch, 1);
    }

    function test_ConvertFees_UsdgAsAsset_NoSwap() external {
        _register(_assetsUsdgOnly());
        _stake(alice, 1e18);
        _notify(100e6);
        uint256[] memory out = _convert();
        assertEq(out[0], 100e6);
        assertEq(_earned(alice, 0), 90e6);
    }

    // ------------------------------------------------------------------ staking rewards

    function test_Stake_AfterFees_EarnsNothingFromPriorFees() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        _stake(bob, 1_000e18); // joins after the fee arrived, same epoch
        _convert();

        assertEq(_earned(alice, 0), 108e18);
        assertEq(_earned(bob, 0), 0, "bob was not staked when the fee arrived");
    }

    function test_Earned_TwoStakers_ProRata() external {
        _register(_assets6040());
        _stake(alice, 3_000e18);
        _stake(bob, 1_000e18);
        _notify(100e6);
        _convert();

        assertEq(_earned(alice, 0), 81e18, "3/4 of 108");
        assertEq(_earned(bob, 0), 27e18, "1/4 of 108");
    }

    function test_Earned_StakeChangesWithinEpoch_UsesEpochRate() external {
        _register(_assetsUsdgOnly());
        _stake(alice, 1_000e18);
        _notify(100e6); // alice: 90
        _stake(bob, 1_000e18);
        _notify(100e6); // alice: 45, bob: 45
        vm.prank(alice);
        vault.unstake(address(meme), 1_000e18);
        _notify(100e6); // bob: 90
        _convert();

        assertEq(_earned(alice, 0), 135e6);
        assertEq(_earned(bob, 0), 135e6);
        assertEq(_creatorAccrued(0), 30e6);
    }

    function test_Earned_SeveralEpochs_Accumulates() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        for (uint256 i; i < 3; ++i) {
            _notify(100e6);
            _convert();
        }
        assertEq(_earned(alice, 0), 3 * 108e18);
        assertEq(_earned(alice, 1), 3 * 36e8);
    }

    function test_Earned_BeforeConversion_OnlyPendingCredit() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        assertEq(_earned(alice, 0), 0);
        assertEq(vault.pendingCreditOf(address(meme), alice), 90e6);
    }

    function test_NotifyFees_AllUnstaked_GoesToCreator() external {
        _register(_assetsUsdgOnly());
        _stake(alice, 1_000e18);
        vm.prank(alice);
        vault.unstake(address(meme), 1_000e18);
        _notify(100e6);
        _convert();
        assertEq(_creatorAccrued(0), 100e6);
        assertEq(_earned(alice, 0), 0);
    }

    // ------------------------------------------------------------------ claims

    function test_Claim_AfterConversion_TransfersRewards() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        _convert();

        vm.prank(alice);
        vault.claim(address(meme));
        assertEq(aapl.balanceOf(alice), 108e18);
        assertEq(wbtc.balanceOf(alice), 36e8);
        assertEq(_earned(alice, 0), 0);
    }

    function test_Claim_SubsetOfAssets_LeavesOthers() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        _convert();

        address[] memory only = new address[](1);
        only[0] = address(wbtc);
        vm.prank(alice);
        vault.claim(address(meme), only);
        assertEq(wbtc.balanceOf(alice), 36e8);
        assertEq(aapl.balanceOf(alice), 0);
        assertEq(_earned(alice, 0), 108e18);
    }

    function test_Claim_UnknownAsset_Reverts() external {
        _register(_assets6040());
        address[] memory only = new address[](1);
        only[0] = address(usdg);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.AssetNotInVault.selector,
                address(meme),
                address(usdg)
            )
        );
        vault.claim(address(meme), only);
    }

    function test_Exit_UnstakesAndClaims() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        _convert();

        vm.prank(alice);
        vault.exit(address(meme));
        assertEq(meme.balanceOf(alice), 1_000e18);
        assertEq(aapl.balanceOf(alice), 108e18);
        assertEq(vault.totalStaked(address(meme)), 0);
    }

    function test_ClaimCreatorRewards_PaysCreator() external {
        _register(_assets6040());
        _notify(100e6);
        _convert();
        vault.claimCreatorRewards(address(meme));
        assertEq(aapl.balanceOf(creator), 120e18);
        assertEq(wbtc.balanceOf(creator), 40e8);
    }

    // ------------------------------------------------------------------ unstake / pause

    function test_Unstake_MoreThanStaked_Reverts() external {
        _register(_assets6040());
        _stake(alice, 1e18);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.InsufficientStake.selector,
                1e18,
                2e18
            )
        );
        vault.unstake(address(meme), 2e18);
    }

    function test_Unstake_WhilePaused_Succeeds() external {
        _register(_assets6040());
        _stake(alice, 1e18);
        vm.prank(owner);
        vault.setPaused(true);

        vm.prank(alice);
        vault.unstake(address(meme), 1e18);
        assertEq(meme.balanceOf(alice), 1e18);
    }

    function test_Claim_WhilePaused_Reverts() external {
        _register(_assets6040());
        vm.prank(owner);
        vault.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.claim(address(meme));
    }

    function test_NotifyFees_WhilePaused_Succeeds() external {
        _register(_assets6040());
        vm.prank(owner);
        vault.setPaused(true);
        _notify(100e6);
        assertEq(vault.pendingUSDG(address(meme)), 100e6);
    }

    // ------------------------------------------------------------------ creator role / admin

    function test_TransferCreator_TwoStep_MovesRewards() external {
        _register(_assets6040());
        _notify(100e6);
        _convert();

        address newCreator = makeAddr("newCreator");
        vm.prank(creator);
        vault.transferCreator(address(meme), newCreator);
        assertEq(vault.creatorOf(address(meme)), creator);

        vm.prank(newCreator);
        vault.acceptCreator(address(meme));
        assertEq(vault.creatorOf(address(meme)), newCreator);

        vault.claimCreatorRewards(address(meme));
        assertEq(aapl.balanceOf(newCreator), 120e18);
    }

    function test_TransferCreator_NotCreator_Reverts() external {
        _register(_assets6040());
        vm.prank(alice);
        vm.expectRevert(IVault.NotCreator.selector);
        vault.transferCreator(address(meme), alice);
    }

    function test_AcceptCreator_NotPending_Reverts() external {
        _register(_assets6040());
        vm.prank(alice);
        vm.expectRevert(IVault.NotPendingCreator.selector);
        vault.acceptCreator(address(meme));
    }

    function test_RescueERC20_OnlySurplus() external {
        _register(_assets6040());
        _stake(alice, 1_000e18);
        meme.mint(address(vault), 5e18); // sent by mistake

        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.RescueExceedsSurplus.selector,
                address(meme),
                5e18,
                6e18
            )
        );
        vault.rescueERC20(address(meme), owner, 6e18);

        vm.prank(owner);
        vault.rescueERC20(address(meme), owner, 5e18);
        assertEq(meme.balanceOf(owner), 5e18);
    }

    function test_Setters_NotOwner_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vm.prank(alice);
        vault.setHook(alice);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Rewards of both stakers plus the creator share never exceed what was converted,
    /// and each staker gets its pro-rata share of fees that arrived while staked.
    function testFuzz_Earned_TwoStakers_NeverExceedsConverted(
        uint96 stakeA,
        uint96 stakeB,
        uint64 fee1,
        uint64 fee2
    ) external {
        vm.assume(stakeA > 0 && stakeB > 0 && fee1 > 0 && fee2 > 0);
        _register(_assetsUsdgOnly());

        _stake(alice, stakeA);
        _notify(fee1);
        _stake(bob, stakeB);
        _notify(fee2);
        uint256[] memory out = _convert();

        uint256 a = _earned(alice, 0);
        uint256 b = _earned(bob, 0);
        uint256 c = _creatorAccrued(0);
        assertLe(a + b + c, out[0], "over-distribution");
        assertEq(out[0], uint256(fee1) + fee2);

        // Expected pro-rata share of bob, 1 wei of rounding per step at most.
        uint256 s2 = fee2 - (uint256(fee2) * 1_000) / 10_000;
        uint256 expectedB = (s2 * stakeB) / (uint256(stakeA) + stakeB);
        assertApproxEqAbs(b, expectedB, 2, "bob share");
        assertLe(b, s2, "bob earns only fees after his stake");
        assertApproxEqAbs(a + b + c, out[0], 4, "rounding dust");

        vm.prank(alice);
        vault.claim(address(meme));
        vm.prank(bob);
        vault.claim(address(meme));
        vault.claimCreatorRewards(address(meme));
        assertEq(
            vault.accounted(address(usdg)),
            out[0] - a - b - c,
            "only dust stays accounted"
        );
        assertEq(
            usdg.balanceOf(address(vault)),
            vault.accounted(address(usdg))
        );
    }

    function testFuzz_ConvertFees_WeightsSumToInput(
        uint64 fee,
        uint16 weight
    ) external {
        vm.assume(fee > 0);
        weight = uint16(bound(weight, 1, 9_999));
        AssetConfig[] memory assets = new AssetConfig[](2);
        assets[0] = AssetConfig({token: address(usdg), weightBps: weight});
        assets[1] = AssetConfig({
            token: address(aapl),
            weightBps: 10_000 - weight
        });
        _register(assets);
        _notify(fee);
        uint256[] memory out = _convert();
        uint256 aaplIn = fee - (uint256(fee) * weight) / 10_000;
        assertEq(out[0], (uint256(fee) * weight) / 10_000);
        assertEq(out[1], (aaplIn * 2e30) / 1e18);
        assertEq(
            usdg.balanceOf(address(vault)),
            out[0],
            "only the USDG leg stays"
        );
    }
    // ------------------------------------------------------------------ automatic conversion

    function _setThreshold(uint256 threshold) internal {
        vm.prank(owner);
        vault.setConversionThreshold(threshold);
    }

    function test_SetConversionThreshold_NotOwner_Reverts() external {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                Ownable.OwnableUnauthorizedAccount.selector,
                alice
            )
        );
        vault.setConversionThreshold(1);
    }

    function test_SetConversionThreshold_Owner_SetsAndEmits() external {
        vm.expectEmit(true, true, true, true);
        emit IVault.ConversionThresholdUpdated(100e6);
        _setThreshold(100e6);
        assertEq(vault.conversionThreshold(), 100e6);
    }

    function test_ConvertFees_AnyCaller_Succeeds() external {
        _register(_assets6040());
        _notify(100e6);
        vm.prank(alice);
        vault.convertFees(address(meme));
        assertEq(vault.vaultInfo(address(meme)).epoch, 1);
    }

    function test_ConvertFees_BelowThreshold_Reverts() external {
        _register(_assets6040());
        _setThreshold(100e6);
        _notify(99e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.BelowConversionThreshold.selector,
                99e6,
                100e6
            )
        );
        vault.convertFees(address(meme));
    }

    function test_ConvertFees_AdapterReverts_Bubbles() external {
        _register(_assets6040());
        _notify(100e6);
        adapter.setShouldRevert(true);
        vm.expectRevert(bytes("adapter: revert"));
        vault.convertFees(address(meme));
    }

    function test_ConvertFees_ZeroOutput_Reverts() external {
        _register(_assets6040());
        _notify(100e6);
        adapter.setRate(address(aapl), 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IVault.ZeroSwapOutput.selector,
                address(aapl)
            )
        );
        vault.convertFees(address(meme));
    }

    function test_NotifyFees_BelowThreshold_KeepsEpochOpen() external {
        _register(_assets6040());
        _setThreshold(100e6);
        _stake(alice, 1_000e18);
        _notify(60e6);
        assertEq(vault.vaultInfo(address(meme)).epoch, 0);
        assertEq(vault.pendingUSDG(address(meme)), 60e6);
        assertEq(usdg.balanceOf(address(vault)), 60e6);
    }

    function test_NotifyFees_ReachesThreshold_ConvertsInSameTx() external {
        _register(_assets6040());
        _setThreshold(100e6);
        _stake(alice, 1_000e18);
        _notify(60e6);
        _notify(40e6);

        assertEq(vault.vaultInfo(address(meme)).epoch, 1);
        assertEq(vault.pendingUSDG(address(meme)), 0);
        assertEq(usdg.balanceOf(address(vault)), 0);
        assertEq(_earned(alice, 0), 108e18, "90% of 120 AAPL");
        assertEq(_earned(alice, 1), 36e8, "90% of 40 WBTC");
        assertEq(_creatorAccrued(0), 12e18);
        assertEq(_creatorAccrued(1), 4e8);
    }

    function test_NotifyFees_AboveThreshold_ConvertsWholePending() external {
        _register(_assets6040());
        _setThreshold(100e6);
        _notify(1_000e6);
        assertEq(vault.vaultInfo(address(meme)).epoch, 1);
        assertEq(vault.pendingUSDG(address(meme)), 0);
        assertEq(
            _creatorAccrued(0),
            1_200e18,
            "nobody stakes: all AAPL to the creator"
        );
    }

    function test_NotifyFees_ThresholdZero_NeverConvertsAutomatically()
        external
    {
        _register(_assets6040());
        _notify(1_000e6);
        assertEq(vault.vaultInfo(address(meme)).epoch, 0);
        assertEq(vault.pendingUSDG(address(meme)), 1_000e6);
    }

    function test_NotifyFees_Paused_SkipsConversion() external {
        _register(_assets6040());
        _setThreshold(100e6);
        vm.prank(owner);
        vault.setPaused(true);

        _notify(100e6);
        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.epoch, 0);
        assertEq(vault.pendingUSDG(address(meme)), 100e6);
        assertEq(info.lastConversionFailure, 0, "a skip is not a failure");

        vm.prank(owner);
        vault.setPaused(false);
        vault.convertFees(address(meme));
        assertEq(vault.vaultInfo(address(meme)).epoch, 1);
    }

    function test_NotifyFees_ConversionReverts_KeepsCreditAndStartsCooldown()
        external
    {
        _register(_assets6040());
        _setThreshold(100e6);
        _stake(alice, 1_000e18);
        adapter.setShouldRevert(true);

        usdg.mint(address(vault), 100e6);
        vm.expectEmit(true, false, false, false);
        emit IVault.ConversionFailed(address(meme), "");
        vm.prank(hook);
        vault.notifyFees(address(meme), 100e6);

        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.epoch, 0);
        assertEq(info.pendingStakerUSDG, 90e6);
        assertEq(info.pendingCreatorUSDG, 10e6);
        assertEq(info.lastConversionFailure, block.timestamp);
        assertEq(vault.accounted(address(usdg)), 100e6);
        assertEq(usdg.balanceOf(address(vault)), 100e6);
        assertEq(vault.pendingCreditOf(address(meme), alice), 90e6);
    }

    function test_NotifyFees_WithinCooldown_DoesNotRetry() external {
        _register(_assets6040());
        _setThreshold(100e6);
        adapter.setShouldRevert(true);
        _notify(100e6);
        adapter.setShouldRevert(false);

        vm.warp(block.timestamp + vault.CONVERSION_COOLDOWN() - 1);
        _notify(1e6);
        assertEq(vault.vaultInfo(address(meme)).epoch, 0, "still cooling down");
        assertEq(vault.pendingUSDG(address(meme)), 101e6);

        vm.warp(block.timestamp + 1);
        _notify(1e6);
        assertEq(
            vault.vaultInfo(address(meme)).epoch,
            1,
            "retried after the cooldown"
        );
        assertEq(vault.pendingUSDG(address(meme)), 0);
    }

    function test_NotifyFees_ConversionRevertsWithoutData_NoCooldown()
        external
    {
        _register(_assets6040());
        _setThreshold(100e6);
        adapter.setRevertEmpty(true);

        usdg.mint(address(vault), 100e6);
        vm.expectEmit(true, false, false, true);
        emit IVault.ConversionFailed(address(meme), "");
        vm.prank(hook);
        vault.notifyFees(address(meme), 100e6);

        assertEq(vault.vaultInfo(address(meme)).epoch, 0);
        assertEq(vault.pendingUSDG(address(meme)), 100e6);
        assertEq(
            vault.vaultInfo(address(meme)).lastConversionFailure,
            0,
            "no cooldown"
        );

        // The very next notification retries and succeeds once the adapter works again.
        adapter.setRevertEmpty(false);
        _notify(1e6);
        assertEq(vault.vaultInfo(address(meme)).epoch, 1);
    }

    function test_ConvertFees_Manual_IgnoresCooldown() external {
        _register(_assets6040());
        _setThreshold(100e6);
        adapter.setShouldRevert(true);
        _notify(100e6);
        adapter.setShouldRevert(false);

        vault.convertFees(address(meme));
        assertEq(vault.vaultInfo(address(meme)).epoch, 1);
    }

    function test_NotifyFees_FailedThenFixed_ConvertsAccumulatedEpochAtOnce()
        external
    {
        _register(_assets6040());
        _setThreshold(100e6);
        _stake(alice, 1_000e18);
        adapter.setShouldRevert(true);
        _notify(100e6);
        _notify(100e6); // within the cooldown: no attempt
        adapter.setShouldRevert(false);
        vm.warp(block.timestamp + vault.CONVERSION_COOLDOWN());
        _notify(100e6);

        assertEq(vault.vaultInfo(address(meme)).epoch, 1);
        assertEq(
            _earned(alice, 0),
            324e18,
            "90% of 360 AAPL bought with 300 USDG"
        );
    }

    /// @dev With a working adapter the pending USDG of a vault never stays at or above the
    /// threshold after a notification, an epoch closes exactly when it is crossed, and the vault
    /// balance always covers what it accounts.
    function testFuzz_NotifyFees_AutoConversion_ClosesEpochExactlyAtThreshold(
        uint64 threshold,
        uint64[8] calldata fees
    ) external {
        threshold = uint64(bound(threshold, 1, type(uint64).max));
        _register(_assets6040());
        _setThreshold(threshold);
        _stake(alice, 1_000e18);

        uint64 epochs;
        for (uint256 i; i < fees.length; ++i) {
            uint256 fee = bound(fees[i], 1, type(uint64).max);
            uint256 pendingBefore = vault.pendingUSDG(address(meme));
            _notify(fee);
            if (pendingBefore + fee >= threshold) ++epochs;

            assertLt(vault.pendingUSDG(address(meme)), threshold);
            assertEq(vault.vaultInfo(address(meme)).epoch, epochs);
            assertGe(
                usdg.balanceOf(address(vault)),
                vault.accounted(address(usdg))
            );
            assertGe(
                aapl.balanceOf(address(vault)),
                vault.accounted(address(aapl))
            );
            assertGe(
                wbtc.balanceOf(address(vault)),
                vault.accounted(address(wbtc))
            );
        }
    }
}

// ---------------------------------------------------------------------- invariants

contract VaultHandler is Test {
    Vault internal vault;
    MockToken internal usdg;
    MockToken internal meme;
    address internal hook;
    address[] public actors;

    uint256 public ghostNotified;
    uint256 public ghostPaidOut;

    constructor(Vault vault_, MockToken usdg_, MockToken meme_, address hook_) {
        vault = vault_;
        usdg = usdg_;
        meme = meme_;
        hook = hook_;
        for (uint256 i; i < 4; ++i) {
            actors.push(
                makeAddr(string(abi.encodePacked("actor", vm.toString(i))))
            );
        }
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function stake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 1e30);
        meme.mint(actor, amount);
        vm.startPrank(actor);
        meme.approve(address(vault), amount);
        vault.stake(address(meme), amount);
        vm.stopPrank();
    }

    function unstake(uint256 actorSeed, uint256 amount) external {
        address actor = actors[actorSeed % actors.length];
        uint256 staked = vault.stakedOf(address(meme), actor);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);
        vm.prank(actor);
        vault.unstake(address(meme), amount);
    }

    function notify(uint256 amount) external {
        amount = bound(amount, 1, 1e15);
        usdg.mint(address(vault), amount);
        vm.prank(hook);
        vault.notifyFees(address(meme), amount);
        ghostNotified += amount;
    }

    function convert() external {
        uint256 pending = vault.pendingUSDG(address(meme));
        if (pending == 0 || pending < vault.conversionThreshold()) return;
        vault.convertFees(address(meme));
    }

    function claim(uint256 actorSeed) external {
        address actor = actors[actorSeed % actors.length];
        uint256 before = usdg.balanceOf(actor);
        vm.prank(actor);
        vault.claim(address(meme));
        ghostPaidOut += usdg.balanceOf(actor) - before;
    }

    function claimCreator() external {
        address creator = vault.creatorOf(address(meme));
        uint256 before = usdg.balanceOf(creator);
        vault.claimCreatorRewards(address(meme));
        ghostPaidOut += usdg.balanceOf(creator) - before;
    }
}

/// @dev Single USDG-denominated asset, so every payout is comparable to what was notified.
/// The threshold sits in the middle of the handler's fee range, so epochs close both
/// automatically inside `notifyFees` and manually through `convert`.
contract VaultInvariantTest is VaultFixture {
    uint256 constant THRESHOLD = 5e14;
    VaultHandler handler;

    function setUp() external {
        _deployVault();
        _register(_assetsUsdgOnly());
        vm.prank(owner);
        vault.setConversionThreshold(THRESHOLD);
        handler = new VaultHandler(vault, usdg, meme, hook);
        targetContract(address(handler));
    }

    function invariant_Pending_StaysBelowThreshold() external view {
        assertLt(vault.pendingUSDG(address(meme)), THRESHOLD);
    }

    function invariant_TotalStaked_EqualsSumOfStakes() external view {
        uint256 sum;
        for (uint256 i; i < handler.actorsLength(); ++i) {
            sum += vault.stakedOf(address(meme), handler.actors(i));
        }
        assertEq(vault.totalStaked(address(meme)), sum);
    }

    function invariant_Balances_CoverAccounted() external view {
        assertGe(
            usdg.balanceOf(address(vault)),
            vault.accounted(address(usdg))
        );
        assertGe(
            meme.balanceOf(address(vault)),
            vault.accounted(address(meme))
        );
        assertEq(
            meme.balanceOf(address(vault)),
            vault.totalStaked(address(meme))
        );
    }

    function invariant_Claimable_NeverExceedsNotified() external view {
        uint256 claimable = vault.pendingUSDG(address(meme)) +
            handler.ghostPaidOut();
        for (uint256 i; i < handler.actorsLength(); ++i) {
            (, uint256[] memory amounts) = vault.earned(
                address(meme),
                handler.actors(i)
            );
            claimable += amounts[0];
        }
        (, uint256[] memory creatorAmounts) = vault.creatorAccrued(
            address(meme)
        );
        claimable += creatorAmounts[0];
        assertLe(claimable, handler.ghostNotified());
    }

    function invariant_Accounted_CoversClaimable() external view {
        uint256 owed = vault.pendingUSDG(address(meme));
        for (uint256 i; i < handler.actorsLength(); ++i) {
            (, uint256[] memory amounts) = vault.earned(
                address(meme),
                handler.actors(i)
            );
            owed += amounts[0];
        }
        (, uint256[] memory creatorAmounts) = vault.creatorAccrued(
            address(meme)
        );
        owed += creatorAmounts[0];
        assertLe(owed, vault.accounted(address(usdg)));
    }
}
