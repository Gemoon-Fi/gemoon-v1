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
import {IProtocolFeeReceiver} from "../src/contracts/interfaces/IReferrals.sol";
import {Upgrades} from "@oz-upgrades/Upgrades.sol";

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

/// @dev Protocol recipient with code: records every `notifyFee`, can be told to reject it.
contract MockProtocolReceiver is IProtocolFeeReceiver {
    address public lastMeme;
    uint256 public lastAmount;
    uint256 public calls;
    bool public shouldRevert;

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function notifyFee(address meme, uint256 amount) external {
        require(!shouldRevert, "receiver: revert");
        lastMeme = meme;
        lastAmount = amount;
        ++calls;
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

    /// @dev Creator share of the default vault: 10%.
    uint16 constant CREATOR_SHARE_BPS = 1_000;

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
        vault.registerVault(address(meme), creator, CREATOR_SHARE_BPS, assets);
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
        vault.registerVault(address(meme), creator, CREATOR_SHARE_BPS, _assets6040());
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
        vault.registerVault(address(meme), creator, CREATOR_SHARE_BPS, _assets6040());
    }

    function test_RegisterVault_WeightsNotBps_Reverts() external {
        AssetConfig[] memory assets = _assets6040();
        assets[1].weightBps = 3_999;
        vm.prank(controller);
        vm.expectRevert(IVault.InvalidWeights.selector);
        vault.registerVault(address(meme), creator, CREATOR_SHARE_BPS, assets);
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
        vault.registerVault(address(meme), creator, CREATOR_SHARE_BPS, assets);
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
        vault.registerVault(address(meme), creator, CREATOR_SHARE_BPS, assets);
    }

    function test_RegisterVault_NoAssets_Reverts() external {
        vm.prank(controller);
        vm.expectRevert(IVault.InvalidAssetsLength.selector);
        vault.registerVault(address(meme), creator, CREATOR_SHARE_BPS, new AssetConfig[](0));
    }

    function test_RegisterVault_CreatorShare_StoredAndEmitted() external {
        AssetConfig[] memory assets = _assets6040();
        vm.expectEmit(address(vault));
        emit IVault.VaultRegistered(address(meme), creator, 2_500, assets);
        vm.prank(controller);
        vault.registerVault(address(meme), creator, 2_500, assets);
        assertEq(vault.creatorShareBpsOf(address(meme)), 2_500);
        assertEq(vault.vaultInfo(address(meme)).creatorShareBps, 2_500);
    }

    function test_RegisterVault_CreatorShareAboveBps_Reverts() external {
        vm.prank(controller);
        vm.expectRevert(
            abi.encodeWithSelector(IVault.InvalidCreatorShare.selector, 10_001)
        );
        vault.registerVault(address(meme), creator, 10_001, _assets6040());
    }

    function test_RegisterVault_CreatorShareAtCap_Stored() external {
        assertEq(vault.MAX_CREATOR_SHARE_BPS(), 5_000);
        vm.prank(controller);
        vault.registerVault(address(meme), creator, 5_000, _assets6040());
        assertEq(vault.creatorShareBpsOf(address(meme)), 5_000);
    }

    function test_RegisterVault_CreatorShareAboveCap_Reverts() external {
        vm.prank(controller);
        vm.expectRevert(abi.encodeWithSelector(IVault.InvalidCreatorShare.selector, 5_001));
        vault.registerVault(address(meme), creator, 5_001, _assets6040());
    }

    /// @dev Invariant: no vault is ever registered with a creator share above the cap, so the
    /// stakers always get at least half of the vault part.
    function testFuzz_RegisterVault_CreatorShare_RevertsAboveCap(uint16 shareBps) external {
        vm.prank(controller);
        if (shareBps > 5_000) {
            vm.expectRevert(abi.encodeWithSelector(IVault.InvalidCreatorShare.selector, shareBps));
            vault.registerVault(address(meme), creator, shareBps, _assets6040());
        } else {
            vault.registerVault(address(meme), creator, shareBps, _assets6040());
            assertEq(vault.creatorShareBpsOf(address(meme)), shareBps);
        }
    }

    function test_CreatorShareBpsOf_Unregistered_ReturnsZero() external view {
        assertEq(vault.creatorShareBpsOf(address(meme)), 0);
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

    function test_NotifyFees_ZeroCreatorShare_AllToStakers() external {
        vm.prank(controller);
        vault.registerVault(address(meme), creator, 0, _assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.pendingCreatorUSDG, 0);
        assertEq(info.pendingStakerUSDG, 100e6);
        assertEq(vault.pendingCreditOf(address(meme), alice), 100e6);
    }

    function test_NotifyFees_MaxCreatorShare_HalfToCreator() external {
        vm.prank(controller);
        vault.registerVault(address(meme), creator, 5_000, _assets6040());
        _stake(alice, 1_000e18);
        _notify(100e6);
        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.pendingCreatorUSDG, 50e6);
        assertEq(info.pendingStakerUSDG, 50e6);
        assertEq(vault.pendingCreditOf(address(meme), alice), 50e6);
    }

    function test_NotifyFees_ZeroCreatorShareNoStakers_AllToCreator() external {
        vm.prank(controller);
        vault.registerVault(address(meme), creator, 0, _assets6040());
        _notify(100e6);
        assertEq(vault.vaultInfo(address(meme)).pendingCreatorUSDG, 100e6);
    }

    function testFuzz_NotifyFees_AnyCreatorShare_SplitConserved(
        uint16 shareBps,
        uint256 amount,
        uint256 staked
    ) external {
        shareBps = uint16(bound(shareBps, 0, 5_000));
        amount = bound(amount, 1, 1e18);
        staked = bound(staked, 1, 1e30);
        vm.prank(controller);
        vault.registerVault(address(meme), creator, shareBps, _assets6040());
        _stake(alice, staked);
        _notify(amount);

        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.pendingCreatorUSDG + info.pendingStakerUSDG, amount, "conserved");
        if (info.pendingStakerUSDG != 0) {
            assertEq(info.pendingCreatorUSDG, (amount * shareBps) / 10_000, "creator share");
            // the only staker is credited all stakers' USDG, up to rounding down
            uint256 credit = vault.pendingCreditOf(address(meme), alice);
            assertLe(credit, info.pendingStakerUSDG, "credit <= stakers' part");
            assertApproxEqAbs(credit, info.pendingStakerUSDG, 1, "credit ~ stakers' part");
        } else {
            // too small to move the accumulator: everything to the creator
            assertEq(info.pendingCreatorUSDG, amount);
        }
        assertEq(vault.creatorShareBpsOf(address(meme)), shareBps, "immutable");
    }

    // ------------------------------------------------------------------ protocol split

    /// @dev EOA recipient, a third of every fee.
    function _setProtocol(address recipient, uint256 shareBps) internal {
        vm.startPrank(owner);
        vault.setProtocolRecipient(recipient);
        vault.setProtocolShare(shareBps);
        vm.stopPrank();
    }

    function test_ProtocolSplit_FreshVault_ShareZeroRecipientUnset() external view {
        assertEq(vault.protocolShareBps(), 0);
        assertEq(vault.protocolRecipient(), address(0));
    }

    function test_SetProtocolShare_Owner_SetsAndEmits() external {
        vm.expectEmit(address(vault));
        emit IVault.ProtocolShareUpdated(3_333);
        vm.prank(owner);
        vault.setProtocolShare(3_333);
        assertEq(vault.protocolShareBps(), 3_333);
    }

    function test_SetProtocolShare_AboveBps_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(IVault.InvalidProtocolShare.selector, 10_001)
        );
        vm.prank(owner);
        vault.setProtocolShare(10_001);
    }

    function test_SetProtocolShare_NotOwner_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        vm.prank(alice);
        vault.setProtocolShare(1);
    }

    function test_SetProtocolRecipient_Owner_SetsAndEmits() external {
        address recipient = makeAddr("protocol");
        vm.expectEmit(address(vault));
        emit IVault.ProtocolRecipientUpdated(recipient);
        vm.prank(owner);
        vault.setProtocolRecipient(recipient);
        assertEq(vault.protocolRecipient(), recipient);
    }

    function test_SetProtocolRecipient_Zero_Reverts() external {
        vm.expectRevert(IVault.ZeroAddress.selector);
        vm.prank(owner);
        vault.setProtocolRecipient(address(0));
    }

    function test_SetProtocolRecipient_NotOwner_Reverts() external {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice)
        );
        vm.prank(alice);
        vault.setProtocolRecipient(alice);
    }

    /// @dev The hook sends the whole fee: a third leaves to the protocol at once, the rest is
    /// credited (10% creator, 90% stakers) and only the rest is accounted.
    function test_NotifyFees_ProtocolShare_SendsShareAndCreditsRest() external {
        address recipient = makeAddr("protocol");
        _setProtocol(recipient, 3_333);
        _register(_assets6040());
        _stake(alice, 1_000e18);

        usdg.mint(address(vault), 100e6);
        vm.expectEmit(address(vault));
        emit IVault.FeesNotified(address(meme), 60_003_000, 6_667_000);
        vm.expectEmit(address(vault));
        emit IVault.ProtocolFeePaid(address(meme), recipient, 33_330_000);
        vm.prank(hook);
        vault.notifyFees(address(meme), 100e6);

        assertEq(usdg.balanceOf(recipient), 33_330_000, "a third to the protocol");
        assertEq(usdg.balanceOf(address(vault)), 66_670_000, "rest stays");
        assertEq(vault.accounted(address(usdg)), 66_670_000, "only the rest is accounted");
        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.pendingCreatorUSDG, 6_667_000, "10% of the rest to the creator");
        assertEq(info.pendingStakerUSDG, 60_003_000, "90% of the rest to the stakers");
    }

    /// @dev A non-zero share without a recipient would lose the protocol part: the whole notify
    /// reverts, so the hook keeps the fee accrued.
    function test_NotifyFees_ShareWithoutRecipient_Reverts() external {
        vm.prank(owner);
        vault.setProtocolShare(3_333);
        _register(_assets6040());
        usdg.mint(address(vault), 100e6);
        vm.expectRevert(IVault.ProtocolRecipientNotSet.selector);
        vm.prank(hook);
        vault.notifyFees(address(meme), 100e6);
    }

    /// @dev A protocol part rounding to zero needs no recipient.
    function test_NotifyFees_ShareRoundsToZeroWithoutRecipient_CreditsAll() external {
        vm.prank(owner);
        vault.setProtocolShare(1);
        _register(_assets6040());
        _notify(9_999);
        assertEq(vault.pendingUSDG(address(meme)), 9_999);
    }

    function test_NotifyFees_ContractRecipient_Notified() external {
        MockProtocolReceiver receiver = new MockProtocolReceiver();
        _setProtocol(address(receiver), 3_333);
        _register(_assets6040());
        _notify(100e6);

        assertEq(receiver.calls(), 1, "notified once");
        assertEq(receiver.lastMeme(), address(meme), "meme");
        assertEq(receiver.lastAmount(), 33_330_000, "amount sent");
        assertEq(usdg.balanceOf(address(receiver)), 33_330_000, "tokens before the notify");
    }

    /// @dev A rejecting recipient rolls the whole notify back, credit included.
    function test_NotifyFees_RecipientReverts_WholeNotifyReverts() external {
        MockProtocolReceiver receiver = new MockProtocolReceiver();
        receiver.setShouldRevert(true);
        _setProtocol(address(receiver), 3_333);
        _register(_assets6040());
        usdg.mint(address(vault), 100e6);

        vm.expectRevert("receiver: revert");
        vm.prank(hook);
        vault.notifyFees(address(meme), 100e6);
        assertEq(vault.pendingUSDG(address(meme)), 0, "nothing credited");
        assertEq(vault.accounted(address(usdg)), 0, "nothing accounted");
    }

    /// @dev 100% to the protocol: the Meme vault gets nothing.
    function test_NotifyFees_FullProtocolShare_NothingCredited() external {
        address recipient = makeAddr("protocol");
        _setProtocol(recipient, 10_000);
        _register(_assets6040());
        _notify(100e6);
        assertEq(usdg.balanceOf(recipient), 100e6);
        assertEq(vault.pendingUSDG(address(meme)), 0);
        assertEq(vault.accounted(address(usdg)), 0);
    }

    /// @dev The share is global and applies from the next notify on, to every Meme.
    function test_SetProtocolShare_Changed_AppliesToNextNotify() external {
        address recipient = makeAddr("protocol");
        _setProtocol(recipient, 3_333);
        _register(_assets6040());
        _notify(100e6);
        vm.prank(owner);
        vault.setProtocolShare(5_000);
        _notify(100e6);
        assertEq(usdg.balanceOf(recipient), 33_330_000 + 50e6);
        assertEq(vault.pendingUSDG(address(meme)), 66_670_000 + 50e6);
    }

    /// @dev Invariant of one notify: protocol + creator + stakers == amount, protocol part is
    /// amount * share / BPS rounded down, `accounted` grows by the rest only.
    function testFuzz_NotifyFees_AnyProtocolShare_SplitConserved(
        uint256 protocolShareBps,
        uint16 creatorShareBps,
        uint256 amount,
        uint256 staked
    ) external {
        protocolShareBps = bound(protocolShareBps, 0, 10_000);
        creatorShareBps = uint16(bound(creatorShareBps, 0, 5_000));
        amount = bound(amount, 1, 1e18);
        staked = bound(staked, 0, 1e30);
        address recipient = makeAddr("protocol");
        _setProtocol(recipient, protocolShareBps);
        vm.prank(controller);
        vault.registerVault(address(meme), creator, creatorShareBps, _assets6040());
        if (staked != 0) _stake(alice, staked);

        _notify(amount);

        uint256 toProtocol = (amount * protocolShareBps) / 10_000;
        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(usdg.balanceOf(recipient), toProtocol, "protocol part");
        assertEq(
            toProtocol + info.pendingCreatorUSDG + info.pendingStakerUSDG, amount, "conserved"
        );
        assertEq(vault.accounted(address(usdg)), amount - toProtocol, "accounted = rest");
        assertEq(usdg.balanceOf(address(vault)), vault.accounted(address(usdg)), "no leftover");
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

    // ------------------------------------------------------------------ hook replacement

    /// @dev Hooks are not upgradeable: after `setHook(new)` the pools of older Memes still pay
    /// through the old hook, so both must be able to notify fees.
    function test_SetHook_NewHook_OldHookStillNotifies() external {
        _register(_assets6040());
        address newHook = makeAddr("newHook");
        vm.prank(owner);
        vault.setHook(newHook);

        assertEq(vault.hook(), newHook, "hook of new Memes");
        assertTrue(vault.isHook(hook), "old hook allowed");
        assertTrue(vault.isHook(newHook), "new hook allowed");

        _notify(1e6); // from the old hook
        usdg.mint(address(vault), 2e6);
        vm.prank(newHook);
        vault.notifyFees(address(meme), 2e6);
        VaultInfo memory info = vault.vaultInfo(address(meme));
        assertEq(info.pendingStakerUSDG + info.pendingCreatorUSDG, 3e6, "both credited");
    }

    /// @dev Invariant: every hook ever set may notify fees, nobody else may.
    function testFuzz_SetHook_AnySequence_OnlySetHooksNotify(
        address[3] memory hooks,
        address stranger
    ) external {
        _register(_assets6040());
        // The ProxyAdmin is denied the fallback by the transparent proxy itself.
        address proxyAdmin = Upgrades.getAdminAddress(address(vault));
        vm.assume(stranger != proxyAdmin);
        vm.startPrank(owner);
        for (uint256 i; i < hooks.length; ++i) {
            vm.assume(hooks[i] != address(0) && hooks[i] != proxyAdmin);
            vault.setHook(hooks[i]);
        }
        vm.stopPrank();
        vm.assume(stranger != hook);
        for (uint256 i; i < hooks.length; ++i) vm.assume(stranger != hooks[i]);

        assertEq(vault.hook(), hooks[2], "last one is current");
        assertTrue(vault.isHook(hook), "initial hook kept");
        for (uint256 i; i < hooks.length; ++i) {
            assertTrue(vault.isHook(hooks[i]));
            usdg.mint(address(vault), 1);
            vm.prank(hooks[i]);
            vault.notifyFees(address(meme), 1);
        }
        assertFalse(vault.isHook(stranger));
        usdg.mint(address(vault), 1);
        vm.prank(stranger);
        vm.expectRevert(IVault.NotHook.selector);
        vault.notifyFees(address(meme), 1);
    }

    function test_SetHook_Zero_Reverts() external {
        vm.prank(owner);
        vm.expectRevert(IVault.ZeroAddress.selector);
        vault.setHook(address(0));
    }

    // ------------------------------------------------------------------ allowlist enumeration

    function _contains(address[] memory list, address asset) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == asset) return true;
        }
        return false;
    }

    function test_AllowedAssets_AfterSetup_ListsEveryAllowedAsset() external view {
        address[] memory list = vault.allowedAssets();
        assertEq(list.length, 3);
        assertTrue(_contains(list, address(aapl)), "aapl");
        assertTrue(_contains(list, address(wbtc)), "wbtc");
        assertTrue(_contains(list, address(usdg)), "usdg");
    }

    function test_SetAssetAllowed_Remove_DropsFromList() external {
        vm.prank(owner);
        vault.setAssetAllowed(address(wbtc), false);

        address[] memory list = vault.allowedAssets();
        assertEq(list.length, 2);
        assertFalse(_contains(list, address(wbtc)), "wbtc removed");
        assertFalse(vault.isAssetAllowed(address(wbtc)));
    }

    function test_SetAssetAllowed_AddTwice_NoDuplicate() external {
        vm.prank(owner);
        vault.setAssetAllowed(address(aapl), true);
        assertEq(vault.allowedAssets().length, 3);
    }

    function test_SetAssetAllowed_RemoveNotListed_NoOp() external {
        vm.prank(owner);
        vault.setAssetAllowed(address(meme), false);
        assertEq(vault.allowedAssets().length, 3);
        assertFalse(vault.isAssetAllowed(address(meme)));
    }

    function test_SetAssetAllowed_NotOwner_Reverts() external {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", alice));
        vault.setAssetAllowed(address(meme), true);
    }

    /// @dev Invariant: after any sequence of allow / disallow calls the list holds exactly the
    /// assets for which `isAssetAllowed` is true, each once.
    function testFuzz_SetAssetAllowed_ListMatchesMapping(uint256 seed, uint8 steps) external {
        address[4] memory candidates =
            [address(aapl), address(wbtc), address(usdg), makeAddr("tsla")];
        steps = uint8(bound(steps, 1, 40));

        vm.startPrank(owner);
        for (uint256 i; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            vault.setAssetAllowed(candidates[r % 4], (r >> 8) % 2 == 0);
        }
        vm.stopPrank();

        address[] memory list = vault.allowedAssets();
        uint256 allowedCount;
        for (uint256 i; i < candidates.length; ++i) {
            bool allowed = vault.isAssetAllowed(candidates[i]);
            if (allowed) ++allowedCount;
            assertEq(_contains(list, candidates[i]), allowed, "list == mapping");
        }
        assertEq(list.length, allowedCount, "no duplicates, nothing extra");
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

    // ------------------------------------------------------------------ conversion gas

    function _gasFor(uint256 swaps) internal view returns (uint256) {
        return vault.CONVERSION_BASE_GAS() + swaps * vault.CONVERSION_GAS_PER_SWAP();
    }

    function test_ConversionGasRequired_ThresholdOff_ReturnsZero() external {
        _register(_assets6040());
        assertEq(vault.conversionGasRequired(address(meme)), 0);
    }

    /// @dev Required before the threshold is reached too: a swap estimated now may land after
    /// other swaps filled the threshold.
    function test_ConversionGasRequired_BelowThreshold_ReturnsBudget() external {
        _register(_assets6040());
        _setThreshold(100e6);
        _notify(40e6);
        assertEq(vault.conversionGasRequired(address(meme)), _gasFor(2), "AAPL + WBTC");
    }

    function test_ConversionGasRequired_UsdgAsset_NoSwapCounted() external {
        _register(_assetsUsdgOnly());
        _setThreshold(100e6);
        assertEq(vault.conversionGasRequired(address(meme)), _gasFor(0));
    }

    /// @dev Pause and cooldown do not lower the requirement either: they can end between the gas
    /// estimate and the swap.
    function test_ConversionGasRequired_PausedOrCoolingDown_StillBudget() external {
        _register(_assets6040());
        _setThreshold(100e6);
        adapter.setShouldRevert(true);
        _notify(100e6); // conversion fails with a reason: cooldown starts
        assertEq(vault.conversionGasRequired(address(meme)), _gasFor(2), "cooling down");

        vm.prank(owner);
        vault.setPaused(true);
        assertEq(vault.conversionGasRequired(address(meme)), _gasFor(2), "paused");
    }

    function test_ConversionGasRequired_UnknownMeme_ReturnsZero() external {
        _setThreshold(1);
        assertEq(vault.conversionGasRequired(makeAddr("unknown")), 0);
    }

    /// @dev Invariants: the requirement never depends on the pending amount (so a gas estimate
    /// cannot go stale while other swaps fill the threshold), and whenever `notifyFees` does
    /// convert, the requirement was non-zero.
    function testFuzz_ConversionGasRequired_StaticAndCoversEveryConversion(
        uint256 threshold,
        uint256 pending,
        uint256 incoming
    ) external {
        threshold = bound(threshold, 1, 1e12);
        pending = bound(pending, 0, threshold - 1);
        incoming = bound(incoming, 1, 2e12);
        _register(_assets6040());
        _setThreshold(threshold);
        uint256 before = vault.conversionGasRequired(address(meme));
        if (pending != 0) _notify(pending);
        assertEq(vault.conversionGasRequired(address(meme)), before, "independent of pending");

        _notify(incoming);
        if (vault.vaultInfo(address(meme)).epoch == 1) {
            assertGt(before, 0, "every conversion was covered");
        }
        assertEq(before, _gasFor(2));
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

    address internal owner;

    /// @dev USDG credited to the Meme vault (the fee minus the protocol part).
    uint256 public ghostNotified;
    uint256 public ghostPaidOut;
    /// @dev Protocol part of every notify, `amount * share / BPS` at the time of the notify.
    uint256 public ghostProtocol;

    constructor(
        Vault vault_,
        MockToken usdg_,
        MockToken meme_,
        address hook_,
        address owner_
    ) {
        vault = vault_;
        usdg = usdg_;
        meme = meme_;
        hook = hook_;
        owner = owner_;
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
        uint256 toProtocol = (amount * vault.protocolShareBps()) / vault.BPS();
        usdg.mint(address(vault), amount);
        vm.prank(hook);
        vault.notifyFees(address(meme), amount);
        ghostNotified += amount - toProtocol;
        ghostProtocol += toProtocol;
    }

    /// @dev The owner changes the global protocol share at any time.
    function setProtocolShare(uint256 shareBps) external {
        shareBps = bound(shareBps, 0, vault.BPS());
        vm.prank(owner);
        vault.setProtocolShare(shareBps);
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
/// automatically inside `notifyFees` and manually through `convert`. The protocol share starts at
/// a third and the handler changes it at random.
contract VaultInvariantTest is VaultFixture {
    uint256 constant THRESHOLD = 5e14;
    VaultHandler handler;
    address protocol = makeAddr("protocol");

    function setUp() external {
        _deployVault();
        _register(_assetsUsdgOnly());
        vm.startPrank(owner);
        vault.setConversionThreshold(THRESHOLD);
        vault.setProtocolRecipient(protocol);
        vault.setProtocolShare(3_333);
        vm.stopPrank();
        handler = new VaultHandler(vault, usdg, meme, hook, owner);
        targetContract(address(handler));
    }

    /// @dev The protocol gets exactly its share of every notify, never a unit of the Meme vault.
    function invariant_ProtocolRecipient_GetsExactShareOfEveryNotify() external view {
        assertEq(usdg.balanceOf(protocol), handler.ghostProtocol());
    }

    function invariant_ProtocolShare_NeverAboveBps() external view {
        assertLe(vault.protocolShareBps(), vault.BPS());
    }

    function invariant_Pending_StaysBelowThreshold() external view {
        assertLt(vault.pendingUSDG(address(meme)), THRESHOLD);
    }

    function invariant_CreatorShare_Immutable() external view {
        assertEq(vault.creatorShareBpsOf(address(meme)), CREATOR_SHARE_BPS);
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
