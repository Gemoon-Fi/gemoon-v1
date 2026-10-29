// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AssetConfig} from "../src/contracts/interfaces/IVault.sol";
import {VaultFixture} from "./VaultTest.sol";

/// @dev Rounding of a dust stake next to whales on production-like numbers: USDG with 6 decimals,
/// Meme with 18, protocol share 25%, creator share 10% (fixture), conversion threshold 5 USDG,
/// fee of 1.25 USDG per swap (a $100 swap at 1.25%). Stakes: 800M, 100M and 1 Meme.
/// Reward assets at market-like prices: AAPL (18 decimals) at $200, WBTC (8 decimals) at $100k.
contract VaultPrecisionTest is VaultFixture {
    uint256 constant WHALE1_STAKE = 800_000_000e18;
    uint256 constant WHALE2_STAKE = 100_000_000e18;
    uint256 constant DUST_STAKE = 1e18;
    uint256 constant TOTAL_STAKE = WHALE1_STAKE + WHALE2_STAKE + DUST_STAKE;

    uint256 constant PROTOCOL_SHARE_BPS = 2_500;
    uint256 constant THRESHOLD = 5e6;
    /// @dev Fee of a $100 swap at 1.25%.
    uint256 constant SWAP_FEE = 1_250_000;
    /// @dev Swaps of SWAP_FEE that reach THRESHOLD: 6 x 937_500 = 5_625_000 USDG units.
    uint256 constant SWAPS_PER_EPOCH = 6;
    /// @dev Fee whose staker part gives the dust stake ~0.1 USDG unit (0.0000001 USDG).
    uint256 constant TENTH_UNIT_FEE = 133_333_335;

    /// @dev Adapter rates (`amountIn * rate / 1e18`): 1 USDG -> 0.005 AAPL, 1 USDG -> 1000 sat.
    uint256 constant AAPL_RATE = 5e27;
    uint256 constant WBTC_RATE = 1e15;

    address whale1 = makeAddr("whale1");
    address whale2 = makeAddr("whale2");
    address dust = makeAddr("dust");
    address protocol = makeAddr("protocol");

    function setUp() external {
        _deployVault();
        adapter.setRate(address(aapl), AAPL_RATE);
        adapter.setRate(address(wbtc), WBTC_RATE);
        vm.startPrank(owner);
        vault.setProtocolRecipient(protocol);
        vault.setProtocolShare(PROTOCOL_SHARE_BPS);
        vault.setConversionThreshold(THRESHOLD);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Parts of a fee with the same roundings as `notifyFees` / `_creditFees`.
    function _vaultPart(uint256 fee) internal pure returns (uint256) {
        return fee - (fee * PROTOCOL_SHARE_BPS) / 10_000;
    }

    function _creatorPart(uint256 fee) internal pure returns (uint256) {
        return (_vaultPart(fee) * CREATOR_SHARE_BPS) / 10_000;
    }

    function _stakerPart(uint256 fee) internal pure returns (uint256) {
        return _vaultPart(fee) - _creatorPart(fee);
    }

    function _stakeAll() internal {
        _stake(whale1, WHALE1_STAKE);
        _stake(whale2, WHALE2_STAKE);
        _stake(dust, DUST_STAKE);
    }

    function _swaps(uint256 count, uint256 fee) internal {
        for (uint256 i; i < count; ++i) _notify(fee);
    }

    function _claim(address account) internal {
        vm.prank(account);
        vault.claim(address(meme));
    }

    function _sumClaimable(uint256 index) internal view returns (uint256) {
        return
            _earned(whale1, index) +
            _earned(whale2, index) +
            _earned(dust, index) +
            _creatorAccrued(index);
    }

    // ------------------------------------------------------------------ USDG reward

    /// @dev 200 epochs = 1 200 swaps = 1 012.5 USDG to the stakers. The dust stake owns 1/900M of
    /// it, 1.12 units: 0.0056 unit per epoch, kept by the K accumulator across epochs.
    function test_Earned_DustStakeUsdgVault_ProRataAfterManyEpochs() external {
        _register(_assetsUsdgOnly());
        _stakeAll();

        uint256 epochs = 200;
        _swaps(epochs * SWAPS_PER_EPOCH, SWAP_FEE);
        assertEq(vault.vaultInfo(address(meme)).epoch, epochs, "one epoch per 6 swaps");
        assertEq(vault.pendingUSDG(address(meme)), 0, "last swap closed the epoch");

        uint256 toStakers = epochs * SWAPS_PER_EPOCH * _stakerPart(SWAP_FEE);
        uint256 dustExact = Math.mulDiv(toStakers, DUST_STAKE, TOTAL_STAKE);
        uint256 dustEarned = _earned(dust, 0);
        console.log("stakers' USDG, units:", toStakers);
        console.log("dust exact share, units:", dustExact);
        console.log("dust earned, units:", dustEarned);

        assertEq(dustExact, 1, "1/900M of 1012.5 USDG is 1.12 units");
        assertEq(dustEarned, 1, "dust gets its whole unit");
        assertApproxEqAbs(
            _earned(whale1, 0),
            Math.mulDiv(toStakers, WHALE1_STAKE, TOTAL_STAKE),
            2,
            "whale1 pro rata"
        );
        assertApproxEqAbs(
            _earned(whale2, 0),
            Math.mulDiv(toStakers, WHALE2_STAKE, TOTAL_STAKE),
            2,
            "whale2 pro rata"
        );
        assertLe(_sumClaimable(0), vault.accounted(address(usdg)), "no over-distribution");

        uint256 before = usdg.balanceOf(dust);
        _claim(dust);
        assertEq(usdg.balanceOf(dust) - before, 1, "dust claims 1 unit");
    }

    /// @dev The question "what if the share is 0.0000001 USDG": nothing is rounded per fee. The
    /// share stays in `accUsdPerShare` (1e36 per Meme wei) and becomes a whole unit at the tenth fee.
    function test_PendingCredit_DustShareTenthOfUnit_AccumulatesToWholeUnit() external {
        _register(_assetsUsdgOnly());
        _stakeAll();
        vm.prank(owner);
        vault.setConversionThreshold(0); // all ten fees stay in one epoch

        for (uint256 i = 1; i <= 10; ++i) {
            _notify(TENTH_UNIT_FEE);
            uint256 credit = vault.pendingCreditOf(address(meme), dust);
            console.log("fee", i, "dust credit, units:", credit);
            assertEq(credit, i < 10 ? 0 : 1, "0.1 unit per fee, whole unit at the tenth");
        }

        _convert();
        assertEq(_earned(dust, 0), 1, "converted at the epoch rate");
    }

    /// @dev Same fees, but the dust staker checkpoints (claims) after each one: the sub-unit
    /// credit is floored at every checkpoint, so it never reaches a unit. Only its own checkpoints
    /// do this, nobody can checkpoint another account.
    function test_Claim_DustShareTenthOfUnitClaimedEveryFee_FlooredToZero() external {
        _register(_assetsUsdgOnly());
        _stakeAll();
        vm.prank(owner);
        vault.setConversionThreshold(0);

        for (uint256 i; i < 10; ++i) {
            _notify(TENTH_UNIT_FEE);
            _claim(dust);
        }

        _convert();
        assertEq(_earned(dust, 0), 0, "every checkpoint floored 0.1 unit");
        assertEq(usdg.balanceOf(dust), 0);
        assertGt(_earned(whale1, 0), 0, "whales are not affected");
    }

    // ------------------------------------------------------------------ asset rewards

    /// @dev With 18-decimal AAPL the dust share keeps its precision across epochs: K stores asset
    /// per Meme wei scaled by 1e36. 8-decimal WBTC worth 2 025 sat per epoch to all stakers gives
    /// the dust 0.0000022 sat per epoch, zero after 200 epochs.
    function test_Earned_DustStakeAssetVault_AaplPreciseWbtcZero() external {
        _register(_assets6040());
        _stakeAll();

        uint256 epochs = 200;
        _swaps(epochs * SWAPS_PER_EPOCH, SWAP_FEE);
        assertEq(vault.vaultInfo(address(meme)).epoch, epochs);

        // Every epoch converts 5_625_000 USDG units: 60% to AAPL, 40% to WBTC, 10% of each output
        // to the creator (creator USDG / total).
        uint256 epochUsd = SWAPS_PER_EPOCH * _vaultPart(SWAP_FEE);
        uint256 epochCreatorUsd = SWAPS_PER_EPOCH * _creatorPart(SWAP_FEE);
        uint256 aaplIn = (epochUsd * 6_000) / 10_000;
        uint256 aaplOut = (aaplIn * AAPL_RATE) / 1e18;
        uint256 wbtcOut = ((epochUsd - aaplIn) * WBTC_RATE) / 1e18;
        uint256 aaplStakers = aaplOut - Math.mulDiv(aaplOut, epochCreatorUsd, epochUsd);
        uint256 wbtcStakers = wbtcOut - Math.mulDiv(wbtcOut, epochCreatorUsd, epochUsd);
        assertEq(wbtcStakers, 2_025, "2 025 sat per epoch to the stakers");

        uint256 dustAaplExact = Math.mulDiv(epochs * aaplStakers, DUST_STAKE, TOTAL_STAKE);
        uint256 dustAaplPerEpoch = Math.mulDiv(aaplStakers, DUST_STAKE, TOTAL_STAKE);
        uint256 dustAapl = _earned(dust, 0);
        console.log("dust AAPL exact, wei:", dustAaplExact);
        console.log("dust AAPL earned, wei:", dustAapl);
        console.log("dust WBTC earned, sat:", _earned(dust, 1));

        // The first epoch of the dust goes through its USDG credit (0.0056 unit, floored to 0),
        // every later one through K.
        assertLe(dustAapl, dustAaplExact, "never above pro rata");
        assertApproxEqAbs(dustAapl, dustAaplExact, dustAaplPerEpoch + 2, "loses the first epoch only");
        assertEq(_earned(dust, 1), 0, "0.00045 sat in total");
        assertLe(_sumClaimable(0), vault.accounted(address(aapl)), "AAPL not over-distributed");
        assertLe(_sumClaimable(1), vault.accounted(address(wbtc)), "WBTC not over-distributed");
    }

    /// @dev "Is the fractional part carried to the next epoch or lost?": carried. WBTC is the only
    /// asset, 5 063 sat per epoch to the stakers; two equal stakes of 1 Meme next to 316 454 Meme
    /// get 0.016 sat per epoch each. The one that never claims gets 1 sat after 64 epochs (its
    /// first epoch goes through the USDG credit and is floored, the next 63 through K). The one
    /// that claims after every epoch floors each 0.016 sat away and gets nothing.
    function test_Earned_DustStakeWbtc_SubSatoshiCarriedAcrossEpochsUnlessClaimed() external {
        AssetConfig[] memory assets = new AssetConfig[](1);
        assets[0] = AssetConfig({token: address(wbtc), weightBps: 10_000});
        _register(assets);
        address dustClaimer = makeAddr("dustClaimer");
        _stake(whale1, 316_454e18);
        _stake(dust, DUST_STAKE);
        _stake(dustClaimer, DUST_STAKE);

        for (uint256 e = 1; e <= 64; ++e) {
            _swaps(SWAPS_PER_EPOCH, SWAP_FEE);
            _claim(dustClaimer);
            if (e == 63) assertEq(_earned(dust, 0), 0, "0.99 sat after 63 epochs");
        }

        assertEq(vault.vaultInfo(address(meme)).epoch, 64);
        console.log("dust that never claims, sat:", _earned(dust, 0));
        console.log("dust that claims every epoch, sat:", wbtc.balanceOf(dustClaimer));
        assertEq(_earned(dust, 0), 1, "0.016 sat per epoch carried to 1 sat");
        assertEq(
            wbtc.balanceOf(dustClaimer) + _earned(dustClaimer, 0),
            0,
            "every claim floored its 0.016 sat"
        );
    }

    /// @dev Claiming every epoch: the dust credit of each epoch (0.0056 USDG unit) is floored in
    /// USDG before conversion, so even 18-decimal AAPL pays nothing. A holder that claims rarely
    /// gets it through K. The loss is below 1 USDG unit per claim.
    function test_Claim_DustStakeEveryEpoch_EachEpochFlooredInUsdg() external {
        _register(_assets6040());
        _stakeAll();

        for (uint256 e; e < 20; ++e) {
            _swaps(SWAPS_PER_EPOCH, SWAP_FEE);
            _claim(dust);
        }

        assertEq(vault.vaultInfo(address(meme)).epoch, 20);
        assertEq(aapl.balanceOf(dust), 0, "each epoch floored to 0 USDG units");
        assertEq(wbtc.balanceOf(dust), 0);
    }

    // ------------------------------------------------------------------ fuzz

    /// @dev Any two whale stakes up to the whole supply and a dust stake down to 1 wei, any fees:
    /// a staker that does not touch its stake never gets more than its exact pro-rata share and
    /// at most 2 USDG units less (the first epoch's credit floor and the K floor).
    function testFuzz_Earned_DustStakeAmongWhales_AtMostTwoUnitsBelowProRata(
        uint256 whale1Stake,
        uint256 whale2Stake,
        uint256 dustStake,
        uint256 seed,
        uint8 swaps
    ) external {
        whale1Stake = bound(whale1Stake, 1e18, 1_000_000_000e18);
        whale2Stake = bound(whale2Stake, 1e18, 1_000_000_000e18);
        dustStake = bound(dustStake, 1, 1e18);
        uint256 count = bound(swaps, 1, 60);
        uint256 total = whale1Stake + whale2Stake + dustStake;

        _register(_assetsUsdgOnly());
        _stake(whale1, whale1Stake);
        _stake(whale2, whale2Stake);
        _stake(dust, dustStake);

        uint256 toStakers;
        for (uint256 i; i < count; ++i) {
            uint256 fee = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1e12);
            _notify(fee);
            toStakers += _stakerPart(fee);
        }
        // Convert the open epoch too, so every credit is claimable.
        vm.prank(owner);
        vault.setConversionThreshold(0);
        if (vault.pendingUSDG(address(meme)) != 0) _convert();

        _assertProRata(dust, dustStake, toStakers, total);
        _assertProRata(whale1, whale1Stake, toStakers, total);
        _assertProRata(whale2, whale2Stake, toStakers, total);
        assertLe(_sumClaimable(0), vault.accounted(address(usdg)), "no over-distribution");
    }

    /// @dev The dust staker claims after every fee: it is still never paid above pro rata and
    /// loses less than 1 USDG unit per claim, the floor of its credit since the last one.
    function testFuzz_Claim_DustStakeEveryFee_NeverAboveProRata(
        uint256 dustStake,
        uint256 seed,
        uint8 swaps
    ) external {
        dustStake = bound(dustStake, 1, 1e18);
        uint256 count = bound(swaps, 1, 40);
        uint256 total = WHALE1_STAKE + WHALE2_STAKE + dustStake;

        _register(_assetsUsdgOnly());
        _stake(whale1, WHALE1_STAKE);
        _stake(whale2, WHALE2_STAKE);
        _stake(dust, dustStake);

        uint256 toStakers;
        for (uint256 i; i < count; ++i) {
            uint256 fee = bound(uint256(keccak256(abi.encode(seed, i))), 1, 1e12);
            _notify(fee);
            toStakers += _stakerPart(fee);
            _claim(dust);
        }
        vm.prank(owner);
        vault.setConversionThreshold(0);
        if (vault.pendingUSDG(address(meme)) != 0) _convert();
        _claim(dust);

        uint256 exact = Math.mulDiv(toStakers, dustStake, total);
        uint256 received = usdg.balanceOf(dust);
        assertLe(received, exact, "never above pro rata");
        assertGe(received + count + 1, exact, "below 1 unit lost per claim");
    }

    function _assertProRata(
        address account,
        uint256 stake,
        uint256 toStakers,
        uint256 total
    ) internal view {
        uint256 exact = Math.mulDiv(toStakers, stake, total);
        uint256 earned = _earned(account, 0);
        assertLe(earned, exact, "never above pro rata");
        assertApproxEqAbs(earned, exact, 2, "at most 2 units below pro rata");
    }
}
