// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from
    "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PausableUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {GmoonReferrals} from "../src/contracts/Referrals.sol";
import {IReferrals} from "../src/contracts/interfaces/IReferrals.sol";
import {MintableToken} from "./mocks/MintableToken.sol";

/// @dev Shared deployment of a Referrals proxy with a mock pair token; this test plays the hook
/// and the controller through pranks.
abstract contract ReferralsBase is Test {
    uint256 constant REF_SHARE = 1_000; // 10% of the protocol fee

    MintableToken usdg;
    GmoonReferrals referrals;

    address owner = makeAddr("owner");
    address controller = makeAddr("controller");
    address hook = makeAddr("hook");
    address alice = makeAddr("alice"); // referrer
    address bob = makeAddr("bob"); // referred creator
    address carol = makeAddr("carol"); // creator without a referrer
    address meme = makeAddr("meme");
    address meme2 = makeAddr("meme2");

    function _deploy() internal {
        usdg = new MintableToken("USDG", 6);
        GmoonReferrals implementation = new GmoonReferrals();
        referrals = GmoonReferrals(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    makeAddr("proxyAdminOwner"),
                    abi.encodeCall(
                        GmoonReferrals.initialize,
                        (owner, address(usdg), controller, hook, REF_SHARE)
                    )
                )
            )
        );
    }

    /// @dev alice registers "alice", bob binds to it, bob deploys `meme`.
    function _referBob() internal {
        vm.prank(alice);
        referrals.registerCode("alice");
        vm.prank(bob);
        referrals.useCode("alice");
        vm.prank(controller);
        referrals.registerToken(meme, bob);
    }

    /// @dev What the hook does on a payout: transfer, then notify.
    function _fee(address meme_, uint256 amount) internal {
        usdg.mint(address(referrals), amount);
        vm.prank(hook);
        referrals.notifyFee(meme_, amount);
    }
}

contract ReferralsTest is ReferralsBase {
    function setUp() external {
        _deploy();
    }

    // ------------------------------------------------------------------ initialize

    function test_Initialize_Valid_StoresConfig() external view {
        assertEq(referrals.owner(), owner);
        assertEq(referrals.pairToken(), address(usdg));
        assertEq(referrals.controller(), controller);
        assertEq(referrals.hook(), hook);
        assertEq(referrals.refShareBips(), REF_SHARE);
        assertEq(referrals.getVersion(), 1);
    }

    function test_Initialize_Twice_Reverts() external {
        vm.expectRevert();
        referrals.initialize(owner, address(usdg), controller, hook, REF_SHARE);
    }

    function test_Initialize_Implementation_Reverts() external {
        GmoonReferrals implementation = new GmoonReferrals();
        vm.expectRevert();
        implementation.initialize(owner, address(usdg), controller, hook, REF_SHARE);
    }

    function test_Initialize_RefShareAboveBips_Reverts() external {
        GmoonReferrals implementation = new GmoonReferrals();
        vm.expectRevert(abi.encodeWithSelector(IReferrals.InvalidRefShare.selector, 10_001));
        new TransparentUpgradeableProxy(
            address(implementation),
            address(this),
            abi.encodeCall(
                GmoonReferrals.initialize, (owner, address(usdg), address(0), address(0), 10_001)
            )
        );
    }

    function test_Initialize_ZeroControllerAndHook_LeftUnset() external {
        GmoonReferrals implementation = new GmoonReferrals();
        GmoonReferrals r = GmoonReferrals(
            address(
                new TransparentUpgradeableProxy(
                    address(implementation),
                    address(this),
                    abi.encodeCall(
                        GmoonReferrals.initialize,
                        (owner, address(usdg), address(0), address(0), REF_SHARE)
                    )
                )
            )
        );
        assertEq(r.controller(), address(0));
        assertEq(r.hook(), address(0));
    }

    // ------------------------------------------------------------------ codes

    function test_RegisterCode_Valid_StoresOwner() external {
        vm.prank(alice);
        referrals.registerCode("alice_01-x");
        assertEq(referrals.codeOwner("alice_01-x"), alice);
        assertEq(referrals.codeOwnerByHash(keccak256("alice_01-x")), alice);
    }

    function test_RegisterCode_Taken_Reverts() external {
        vm.prank(alice);
        referrals.registerCode("alice");
        vm.expectRevert(abi.encodeWithSelector(IReferrals.CodeTaken.selector, keccak256("alice")));
        vm.prank(bob);
        referrals.registerCode("alice");
    }

    function test_RegisterCode_SeveralPerReferrer_AllOwned() external {
        vm.startPrank(alice);
        referrals.registerCode("a1");
        referrals.registerCode("a2");
        vm.stopPrank();
        assertEq(referrals.codeOwner("a1"), alice);
        assertEq(referrals.codeOwner("a2"), alice);
    }

    function test_RegisterCode_Empty_Reverts() external {
        vm.expectRevert(IReferrals.InvalidCode.selector);
        vm.prank(alice);
        referrals.registerCode("");
    }

    function test_RegisterCode_TooLong_Reverts() external {
        vm.expectRevert(IReferrals.InvalidCode.selector);
        vm.prank(alice);
        referrals.registerCode("abcdefghijklmnopqrstuvwxyz0123456"); // 33
    }

    function test_RegisterCode_MaxLength_Succeeds() external {
        vm.prank(alice);
        referrals.registerCode("abcdefghijklmnopqrstuvwxyz012345"); // 32
        assertEq(referrals.codeOwner("abcdefghijklmnopqrstuvwxyz012345"), alice);
    }

    function test_RegisterCode_Uppercase_Reverts() external {
        vm.expectRevert(IReferrals.InvalidCode.selector);
        vm.prank(alice);
        referrals.registerCode("Alice");
    }

    function test_RegisterCode_Space_Reverts() external {
        vm.expectRevert(IReferrals.InvalidCode.selector);
        vm.prank(alice);
        referrals.registerCode("al ice");
    }

    /// @dev Every byte outside `[a-z0-9_-]` is rejected.
    function testFuzz_RegisterCode_InvalidChar_Reverts(uint8 c) external {
        bool ok = (c >= 0x61 && c <= 0x7a) || (c >= 0x30 && c <= 0x39) || c == 0x5f || c == 0x2d;
        vm.assume(!ok);
        bytes memory code = abi.encodePacked("ab", bytes1(c), "cd");
        vm.expectRevert(IReferrals.InvalidCode.selector);
        vm.prank(alice);
        referrals.registerCode(string(code));
    }

    // ------------------------------------------------------------------ useCode

    function test_UseCode_Valid_SetsReferrer() external {
        vm.prank(alice);
        referrals.registerCode("alice");
        vm.expectEmit(address(referrals));
        emit IReferrals.ReferrerSet(bob, alice, keccak256("alice"));
        vm.prank(bob);
        referrals.useCode("alice");
        assertEq(referrals.referrerOf(bob), alice);
    }

    /// @dev One code brings any number of users; each of their Memes earns the code owner.
    function test_UseCode_ManyUsersOneCode_AllReferredBySameReferrer() external {
        vm.prank(alice);
        referrals.registerCode("alice");

        address[] memory users = new address[](3);
        users[0] = bob;
        users[1] = carol;
        users[2] = makeAddr("dave");
        for (uint256 i; i < users.length; ++i) {
            vm.prank(users[i]);
            referrals.useCode("alice");
            assertEq(referrals.referrerOf(users[i]), alice);

            address m = address(uint160(0x2000 + i));
            vm.prank(controller);
            referrals.registerToken(m, users[i]);
            _fee(m, 1_000);
        }

        assertEq(referrals.pendingOf(alice), 300, "10% of every referred Meme's fee");
    }

    function test_UseCode_Unknown_Reverts() external {
        vm.expectRevert(abi.encodeWithSelector(IReferrals.CodeNotFound.selector, keccak256("nope")));
        vm.prank(bob);
        referrals.useCode("nope");
    }

    function test_UseCode_Own_Reverts() external {
        vm.startPrank(alice);
        referrals.registerCode("alice");
        vm.expectRevert(IReferrals.SelfReferral.selector);
        referrals.useCode("alice");
        vm.stopPrank();
    }

    function test_UseCode_Twice_Reverts() external {
        vm.prank(alice);
        referrals.registerCode("alice");
        vm.prank(carol);
        referrals.registerCode("carol");
        vm.startPrank(bob);
        referrals.useCode("alice");
        vm.expectRevert(abi.encodeWithSelector(IReferrals.ReferrerAlreadySet.selector, bob, alice));
        referrals.useCode("carol");
        vm.stopPrank();
        assertEq(referrals.referrerOf(bob), alice, "referrer unchanged");
    }

    // ------------------------------------------------------------------ registerToken

    function test_RegisterToken_NotController_Reverts() external {
        vm.expectRevert(IReferrals.NotController.selector);
        referrals.registerToken(meme, bob);
    }

    function test_RegisterToken_ReferredCreator_StoresReferrer() external {
        vm.prank(alice);
        referrals.registerCode("alice");
        vm.prank(bob);
        referrals.useCode("alice");
        vm.expectEmit(address(referrals));
        emit IReferrals.TokenRegistered(meme, bob, alice);
        vm.prank(controller);
        referrals.registerToken(meme, bob);
        assertEq(referrals.memeReferrer(meme), alice);
    }

    function test_RegisterToken_CreatorWithoutReferrer_NoReferrer() external {
        vm.prank(controller);
        referrals.registerToken(meme, carol);
        assertEq(referrals.memeReferrer(meme), address(0));
    }

    /// @dev Binding after the deployment does not attribute Memes deployed before it.
    function test_RegisterToken_ReferrerBoundLater_OldMemeStaysUnattributed() external {
        vm.prank(controller);
        referrals.registerToken(meme, bob);
        vm.prank(alice);
        referrals.registerCode("alice");
        vm.prank(bob);
        referrals.useCode("alice");
        vm.prank(controller);
        referrals.registerToken(meme2, bob);

        assertEq(referrals.memeReferrer(meme), address(0), "old meme");
        assertEq(referrals.memeReferrer(meme2), alice, "new meme");
    }

    // ------------------------------------------------------------------ notifyFee

    function test_NotifyFee_NotHook_Reverts() external {
        vm.expectRevert(IReferrals.NotHook.selector);
        referrals.notifyFee(meme, 1);
    }

    function test_NotifyFee_ReferredMeme_CreditsRefShare() external {
        _referBob();
        usdg.mint(address(referrals), 1_000_000);
        vm.expectEmit(address(referrals));
        emit IReferrals.FeeReceived(meme, alice, 1_000_000, 100_000);
        vm.prank(hook);
        referrals.notifyFee(meme, 1_000_000);

        assertEq(referrals.pendingOf(alice), 100_000, "10% to referrer");
        assertEq(referrals.earnedOf(alice), 100_000);
        assertEq(referrals.totalPending(), 100_000);
        assertEq(referrals.protocolBalance(), 900_000, "rest to protocol");
    }

    function test_NotifyFee_MemeWithoutReferrer_AllToProtocol() external {
        vm.prank(controller);
        referrals.registerToken(meme, carol);
        _fee(meme, 1_000_000);
        assertEq(referrals.totalPending(), 0);
        assertEq(referrals.protocolBalance(), 1_000_000);
    }

    /// @dev Unknown Meme (e.g. deployed before referrals were wired) must not block the payout.
    function test_NotifyFee_UnregisteredMeme_NoRevertAllToProtocol() external {
        _fee(makeAddr("unknown"), 500);
        assertEq(referrals.protocolBalance(), 500);
    }

    function test_NotifyFee_WithoutTransfer_Reverts() external {
        _referBob();
        vm.expectRevert(abi.encodeWithSelector(IReferrals.BalanceTooLow.selector, 0, 100));
        vm.prank(hook);
        referrals.notifyFee(meme, 1_000);
    }

    function test_NotifyFee_SameTransferReportedTwice_RevertsOnceDebtExceedsBalance() external {
        _referBob();
        usdg.mint(address(referrals), 100);
        vm.startPrank(hook);
        // 1000 reported, only 100 arrived: credit 100 is covered by the balance...
        referrals.notifyFee(meme, 1_000);
        // ...the second credit is not.
        vm.expectRevert(abi.encodeWithSelector(IReferrals.BalanceTooLow.selector, 100, 200));
        referrals.notifyFee(meme, 1_000);
        vm.stopPrank();
    }

    function test_NotifyFee_DustBelowShare_NothingCredited() external {
        _referBob();
        _fee(meme, 9); // 9 * 10% = 0.9 -> 0
        assertEq(referrals.pendingOf(alice), 0);
        assertEq(referrals.protocolBalance(), 9);
    }

    function test_NotifyFee_ZeroRefShare_AllToProtocol() external {
        _referBob();
        vm.prank(owner);
        referrals.setRefShare(0);
        _fee(meme, 1_000);
        assertEq(referrals.pendingOf(alice), 0);
        assertEq(referrals.protocolBalance(), 1_000);
    }

    function test_NotifyFee_FullRefShare_AllToReferrer() external {
        _referBob();
        vm.prank(owner);
        referrals.setRefShare(10_000);
        _fee(meme, 1_000);
        assertEq(referrals.pendingOf(alice), 1_000);
        assertEq(referrals.protocolBalance(), 0);
    }

    function test_NotifyFee_RefShareChanged_AppliesToNewFeesOnly() external {
        _referBob();
        _fee(meme, 1_000); // 10% -> 100
        vm.prank(owner);
        referrals.setRefShare(5_000);
        _fee(meme, 1_000); // 50% -> 500
        assertEq(referrals.pendingOf(alice), 600);
    }

    // ------------------------------------------------------------------ claim / distribute

    function test_Claim_Pending_PaysAndResets() external {
        _referBob();
        _fee(meme, 1_000_000);

        vm.prank(alice);
        uint256 paid = referrals.claim();

        assertEq(paid, 100_000);
        assertEq(usdg.balanceOf(alice), 100_000);
        assertEq(referrals.pendingOf(alice), 0);
        assertEq(referrals.totalPending(), 0);
        assertEq(referrals.earnedOf(alice), 100_000, "earned kept");
        assertEq(referrals.protocolBalance(), 900_000, "protocol part untouched");
    }

    function test_Claim_Nothing_Reverts() external {
        vm.expectRevert(IReferrals.NothingToClaim.selector);
        vm.prank(alice);
        referrals.claim();
    }

    function test_Claim_Twice_SecondReverts() external {
        _referBob();
        _fee(meme, 1_000_000);
        vm.startPrank(alice);
        referrals.claim();
        vm.expectRevert(IReferrals.NothingToClaim.selector);
        referrals.claim();
        vm.stopPrank();
    }

    function test_Distribute_SeveralReferrers_PaysEach() external {
        _referBob();
        // carol refers dave, dave deploys meme2
        address dave = makeAddr("dave");
        vm.prank(carol);
        referrals.registerCode("carol");
        vm.prank(dave);
        referrals.useCode("carol");
        vm.prank(controller);
        referrals.registerToken(meme2, dave);

        _fee(meme, 1_000);
        _fee(meme2, 3_000);

        address[] memory list = new address[](4);
        list[0] = alice;
        list[1] = carol;
        list[2] = alice; // duplicate: skipped
        list[3] = makeAddr("nobody"); // nothing credited: skipped
        vm.prank(makeAddr("keeper"));
        uint256 total = referrals.distribute(list);

        assertEq(total, 400);
        assertEq(usdg.balanceOf(alice), 100);
        assertEq(usdg.balanceOf(carol), 300);
        assertEq(referrals.totalPending(), 0);
        assertEq(referrals.protocolBalance(), 3_600);
    }

    function test_Distribute_Empty_ReturnsZero() external {
        assertEq(referrals.distribute(new address[](0)), 0);
    }

    // ------------------------------------------------------------------ pause

    function test_SetPaused_NotOwner_Reverts() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        referrals.setPaused(true);
    }

    function test_SetPaused_Twice_NoOp() external {
        vm.startPrank(owner);
        referrals.setPaused(true);
        referrals.setPaused(true);
        assertTrue(referrals.paused());
        referrals.setPaused(false);
        referrals.setPaused(false);
        vm.stopPrank();
        assertFalse(referrals.paused());
    }

    function test_Claim_Paused_Reverts() external {
        _referBob();
        _fee(meme, 1_000_000);
        vm.prank(owner);
        referrals.setPaused(true);
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        vm.prank(alice);
        referrals.claim();
    }

    function test_Distribute_Paused_Reverts() external {
        _referBob();
        _fee(meme, 1_000_000);
        vm.prank(owner);
        referrals.setPaused(true);
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        referrals.distribute(list);
    }

    /// @dev While paused: fees still credit, the protocol part is still withdrawable and leaves the
    /// referral debt untouched; after unpause the referrer gets everything credited meanwhile.
    function test_Paused_CreditAndProtocolWithdrawKeepWorking_ClaimAfterUnpause() external {
        _referBob();
        vm.prank(owner);
        referrals.setPaused(true);

        _fee(meme, 1_000_000);
        assertEq(referrals.pendingOf(alice), 100_000, "credited while paused");

        address treasury = makeAddr("treasury");
        vm.prank(owner);
        referrals.withdrawProtocolFees(treasury);
        assertEq(usdg.balanceOf(treasury), 900_000, "protocol withdraws while paused");
        assertEq(usdg.balanceOf(address(referrals)), 100_000, "debt kept");

        vm.prank(owner);
        referrals.setPaused(false);
        vm.prank(alice);
        referrals.claim();
        assertEq(usdg.balanceOf(alice), 100_000);
    }

    // ------------------------------------------------------------------ protocol withdrawal

    function test_WithdrawProtocolFees_Owner_SendsBalanceMinusDebt() external {
        _referBob();
        _fee(meme, 1_000_000);
        usdg.mint(address(referrals), 5); // sent directly: protocol's

        address treasury = makeAddr("treasury");
        vm.prank(owner);
        uint256 sent = referrals.withdrawProtocolFees(treasury);

        assertEq(sent, 900_005);
        assertEq(usdg.balanceOf(treasury), 900_005);
        assertEq(usdg.balanceOf(address(referrals)), 100_000, "referral debt stays");
        assertEq(referrals.protocolBalance(), 0);

        // the referrer still gets paid in full
        vm.prank(alice);
        referrals.claim();
        assertEq(usdg.balanceOf(alice), 100_000);
    }

    function test_WithdrawProtocolFees_NotOwner_Reverts() external {
        _fee(meme, 1_000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        referrals.withdrawProtocolFees(alice);
    }

    function test_WithdrawProtocolFees_Nothing_Reverts() external {
        vm.expectRevert(IReferrals.NothingToClaim.selector);
        vm.prank(owner);
        referrals.withdrawProtocolFees(owner);
    }

    function test_WithdrawProtocolFees_ZeroTo_Reverts() external {
        _fee(meme, 1_000);
        vm.expectRevert(IReferrals.ZeroAddress.selector);
        vm.prank(owner);
        referrals.withdrawProtocolFees(address(0));
    }

    function test_RescueERC20_OtherToken_Sends() external {
        MintableToken other = new MintableToken("OTH", 18);
        other.mint(address(referrals), 7);
        vm.prank(owner);
        referrals.rescueERC20(address(other), owner, 7);
        assertEq(other.balanceOf(owner), 7);
    }

    function test_RescueERC20_PairToken_Reverts() external {
        _fee(meme, 1_000);
        vm.expectRevert(IReferrals.PairTokenRescue.selector);
        vm.prank(owner);
        referrals.rescueERC20(address(usdg), owner, 1);
    }

    function test_RescueERC20_NotOwner_Reverts() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        referrals.rescueERC20(address(usdg), alice, 1);
    }

    // ------------------------------------------------------------------ admin

    function test_SetRefShare_AboveBips_Reverts() external {
        vm.expectRevert(abi.encodeWithSelector(IReferrals.InvalidRefShare.selector, 10_001));
        vm.prank(owner);
        referrals.setRefShare(10_001);
    }

    function test_SetRefShare_NotOwner_Reverts() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        referrals.setRefShare(1);
    }

    function test_SetHook_Zero_Reverts() external {
        vm.expectRevert(IReferrals.ZeroAddress.selector);
        vm.prank(owner);
        referrals.setHook(address(0));
    }

    function test_SetController_Zero_Reverts() external {
        vm.expectRevert(IReferrals.ZeroAddress.selector);
        vm.prank(owner);
        referrals.setController(address(0));
    }

    function test_SetHook_NotOwner_Reverts() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        referrals.setHook(alice);
    }

    function test_SetHook_NewHook_OldHookRejected() external {
        address newHook = makeAddr("newHook");
        vm.prank(owner);
        referrals.setHook(newHook);
        vm.expectRevert(IReferrals.NotHook.selector);
        vm.prank(hook);
        referrals.notifyFee(meme, 0);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Credit = amount * share / BIPS, the rest is the protocol's, nothing is lost.
    function testFuzz_NotifyFee_SplitsExactly(uint128 amount, uint16 share) external {
        uint256 refShare = bound(share, 0, 10_000);
        _referBob();
        vm.prank(owner);
        referrals.setRefShare(refShare);

        _fee(meme, amount);

        uint256 expected = (uint256(amount) * refShare) / 10_000;
        assertEq(referrals.pendingOf(alice), expected, "referrer");
        assertEq(referrals.protocolBalance(), uint256(amount) - expected, "protocol");
        assertEq(
            referrals.pendingOf(alice) + referrals.protocolBalance(),
            usdg.balanceOf(address(referrals)),
            "conservation"
        );
    }

    /// @dev Withdrawals in any order pay everyone exactly their part and empty the contract.
    function testFuzz_ClaimAndWithdraw_AnyOrder_EmptiesContract(
        uint96 a,
        uint96 b,
        bool protocolFirst
    ) external {
        _referBob();
        _fee(meme, a);
        _fee(makeAddr("unknown"), b);
        uint256 refPart = (uint256(a) * REF_SHARE) / 10_000;
        uint256 protocolPart = uint256(a) + b - refPart;
        address treasury = makeAddr("treasury");

        if (protocolFirst && protocolPart != 0) {
            vm.prank(owner);
            referrals.withdrawProtocolFees(treasury);
        }
        if (refPart != 0) {
            vm.prank(alice);
            referrals.claim();
        }
        if (!protocolFirst && protocolPart != 0) {
            vm.prank(owner);
            referrals.withdrawProtocolFees(treasury);
        }

        assertEq(usdg.balanceOf(alice), refPart);
        assertEq(usdg.balanceOf(treasury), protocolPart);
        assertEq(usdg.balanceOf(address(referrals)), 0);
        assertEq(referrals.totalPending(), 0);
    }
}

// ------------------------------------------------------------------ invariant

/// @dev Random sequence of codes, bindings, deployments, fees, claims, distributions and
/// protocol withdrawals.
contract ReferralsHandler is Test {
    GmoonReferrals immutable referrals;
    MintableToken immutable usdg;
    address immutable owner;
    address immutable controller;
    address immutable hook;

    address[] public actors;
    address[] public memes;
    uint256 public totalIn;
    uint256 public totalOut;
    mapping(address => uint256) public paidTo;

    constructor(
        GmoonReferrals referrals_,
        MintableToken usdg_,
        address owner_,
        address controller_,
        address hook_
    ) {
        referrals = referrals_;
        usdg = usdg_;
        owner = owner_;
        controller = controller_;
        hook = hook_;
        for (uint256 i; i < 5; ++i) {
            address actor = makeAddr(string.concat("actor", vm.toString(i)));
            actors.push(actor);
            vm.prank(actor);
            referrals.registerCode(string.concat("code", vm.toString(i)));
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function useCode(uint256 userSeed, uint256 codeSeed) external {
        address user = actors[userSeed % actors.length];
        uint256 code = codeSeed % actors.length;
        if (actors[code] == user || referrals.referrerOf(user) != address(0)) return;
        vm.prank(user);
        referrals.useCode(string.concat("code", vm.toString(code)));
    }

    function deployMeme(uint256 creatorSeed) external {
        address m = address(uint160(0x1000 + memes.length));
        memes.push(m);
        vm.prank(controller);
        referrals.registerToken(m, actors[creatorSeed % actors.length]);
    }

    function fee(uint256 memeSeed, uint256 amount) external {
        if (memes.length == 0) return;
        amount = bound(amount, 0, 1e30);
        usdg.mint(address(referrals), amount);
        totalIn += amount;
        vm.prank(hook);
        referrals.notifyFee(memes[memeSeed % memes.length], amount);
    }

    function claim(uint256 seed) external {
        address a = actors[seed % actors.length];
        uint256 pending = referrals.pendingOf(a);
        if (pending == 0 || referrals.paused()) return;
        vm.prank(a);
        referrals.claim();
        paidTo[a] += pending;
        totalOut += pending;
    }

    function distribute(uint256 seed) external {
        if (referrals.paused()) return;
        address[] memory list = new address[](2);
        list[0] = actors[seed % actors.length];
        list[1] = actors[(seed / 7) % actors.length];
        uint256 before = usdg.balanceOf(address(referrals));
        uint256 p0 = referrals.pendingOf(list[0]);
        uint256 p1 = list[1] == list[0] ? 0 : referrals.pendingOf(list[1]);
        referrals.distribute(list);
        paidTo[list[0]] += p0;
        paidTo[list[1]] += p1;
        totalOut += before - usdg.balanceOf(address(referrals));
    }

    function withdrawProtocol() external {
        uint256 amount = referrals.protocolBalance();
        if (amount == 0) return;
        vm.prank(owner);
        referrals.withdrawProtocolFees(owner);
        totalOut += amount;
    }

    function setRefShare(uint256 share) external {
        vm.prank(owner);
        referrals.setRefShare(bound(share, 0, 10_000));
    }

    function setPaused(bool paused_) external {
        vm.prank(owner);
        referrals.setPaused(paused_);
    }
}

/// @notice Invariants:
///  I1 balance >= totalPending (every referrer can always be paid);
///  I2 totalPending == sum of pendingOf over all referrers;
///  I3 balance == totalIn - totalOut (no token created or lost);
///  I4 earnedOf(r) == pendingOf(r) + paid to r (credits are never lost or double-paid).
contract ReferralsInvariantTest is ReferralsBase {
    ReferralsHandler handler;

    function setUp() external {
        _deploy();
        handler = new ReferralsHandler(referrals, usdg, owner, controller, hook);
        targetContract(address(handler));
    }

    function invariant_BalanceCoversReferralDebt() external view {
        assertGe(usdg.balanceOf(address(referrals)), referrals.totalPending());
    }

    function invariant_TotalPendingIsSumOfPending() external view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += referrals.pendingOf(handler.actors(i));
        }
        assertEq(referrals.totalPending(), sum);
    }

    function invariant_Conservation() external view {
        assertEq(usdg.balanceOf(address(referrals)), handler.totalIn() - handler.totalOut());
    }

    function invariant_EarnedEqualsPendingPlusPaid() external view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address a = handler.actors(i);
            assertEq(referrals.earnedOf(a), referrals.pendingOf(a) + handler.paidTo(a));
        }
    }
}
