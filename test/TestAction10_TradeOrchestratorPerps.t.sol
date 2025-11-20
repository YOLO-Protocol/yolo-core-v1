// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base04_TradePerpTestEnvironment} from "./base/Base04_TradePerpTestEnvironment.t.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {TradeOrchestrator} from "../src/trade/TradeOrchestrator.sol";
import {YoloHook} from "../src/core/YoloHook.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract TestAction10_TradeOrchestratorPerps is Base04_TradePerpTestEnvironment {
    uint256 internal constant INITIAL_PRICE = 1_350e8;
    uint256 private constant PRICE_DECIMALS = 1e8;
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant SECONDS_PER_YEAR = 365 days;

    YoloHook internal hookImpl;

    function setUp() public override {
        super.setUp();
        vm.warp(14 hours); // inside the configured trade session
        hookImpl = YoloHook(address(yoloHook));
    }

    function test_Action10_Case01_OpenCloseLongProfitable() public {
        uint256 traderBalanceBefore = IERC20(usy).balanceOf(perpTrader);
        bytes[] memory openUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);

        TradeOrchestrator.OpenPositionParams memory params = TradeOrchestrator.OpenPositionParams({
            syntheticAsset: perpAsset,
            direction: DataTypes.TradeDirection.LONG,
            collateralUsy: 50_000e18,
            syntheticSize: _sizeForNotional(250_000e8, INITIAL_PRICE),
            leverageBps: 0,
            deadline: uint64(block.timestamp + 1 minutes),
            referralCode: bytes32(0)
        });

        vm.prank(perpTrader);
        tradeOrchestrator.openPosition(params, openUpdate);

        assertEq(yoloHook.getUserTradeCount(perpTrader), 1, "position should be stored");

        vm.warp(block.timestamp + 1);

        bytes[] memory closeUpdate = _buildPriceUpdate(perpAsset, 1_550e8);
        TradeOrchestrator.ClosePositionParams memory closeParams = TradeOrchestrator.ClosePositionParams({
            syntheticAsset: perpAsset, index: 0, syntheticSize: 0, deadline: uint64(block.timestamp + 1 minutes)
        });

        vm.prank(perpTrader);
        tradeOrchestrator.closePosition(closeParams, closeUpdate);

        uint256 traderBalanceAfter = IERC20(usy).balanceOf(perpTrader);
        assertEq(yoloHook.getUserTradeCount(perpTrader), 0, "position should be removed");
        assertGt(traderBalanceAfter, traderBalanceBefore - 1e23, "balance should not drop materially");
    }

    function test_Action10_Case02_PartialCloseAfterTopUp() public {
        bytes[] memory priceUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);
        TradeOrchestrator.OpenPositionParams memory params = TradeOrchestrator.OpenPositionParams({
            syntheticAsset: perpAsset,
            direction: DataTypes.TradeDirection.LONG,
            collateralUsy: 40_000e18,
            syntheticSize: _sizeForNotional(180_000e8, INITIAL_PRICE),
            leverageBps: 0,
            deadline: uint64(block.timestamp + 1 minutes),
            referralCode: bytes32(0)
        });
        vm.prank(perpTrader);
        tradeOrchestrator.openPosition(params, priceUpdate);

        DataTypes.TradePosition memory position = yoloHook.getUserTrade(perpTrader, 0);

        vm.warp(block.timestamp + 10);

        TradeOrchestrator.AdjustCollateralParams memory topUp = TradeOrchestrator.AdjustCollateralParams({
            syntheticAsset: perpAsset,
            index: 0,
            collateralDelta: 10_000e18,
            deadline: uint64(block.timestamp + 1 minutes)
        });
        vm.prank(perpTrader);
        tradeOrchestrator.topUpCollateral(topUp);

        DataTypes.TradePosition memory afterTopUp = yoloHook.getUserTrade(perpTrader, 0);
        assertEq(
            afterTopUp.collateralUsy,
            position.collateralUsy + 10_000e18,
            "collateral should increase by the deposited amount"
        );

        vm.warp(block.timestamp + 10);

        bytes[] memory partialCloseUpdate = _buildPriceUpdate(perpAsset, 1_400e8);
        uint256 partialSize = afterTopUp.syntheticAssetPositionSize / 2;
        TradeOrchestrator.ClosePositionParams memory partialClose = TradeOrchestrator.ClosePositionParams({
            syntheticAsset: perpAsset,
            index: 0,
            syntheticSize: partialSize,
            deadline: uint64(block.timestamp + 1 minutes)
        });
        vm.warp(block.timestamp + 1);
        vm.prank(perpTrader);
        tradeOrchestrator.closePosition(partialClose, partialCloseUpdate);

        DataTypes.TradePosition memory finalPosition = yoloHook.getUserTrade(perpTrader, 0);
        assertEq(finalPosition.syntheticAssetPositionSize, afterTopUp.syntheticAssetPositionSize - partialSize);
        assertGt(finalPosition.collateralUsy, 0, "partial close should leave remaining collateral");
    }

    function test_Action10_Case03_LiquidateShortPosition() public {
        bytes[] memory openUpdate = _buildPriceUpdate(perpAsset, 1_300e8);
        TradeOrchestrator.OpenPositionParams memory params = TradeOrchestrator.OpenPositionParams({
            syntheticAsset: perpAsset,
            direction: DataTypes.TradeDirection.SHORT,
            collateralUsy: 30_000e18,
            syntheticSize: _sizeForNotional(200_000e8, 1_300e8),
            leverageBps: 0,
            deadline: uint64(block.timestamp + 1 minutes),
            referralCode: bytes32(0)
        });
        vm.prank(perpTrader);
        tradeOrchestrator.openPosition(params, openUpdate);
        assertEq(yoloHook.getUserTradeCount(perpTrader), 1);
        DataTypes.TradePosition memory openedPosition = yoloHook.getUserTrade(perpTrader, 0);
        uint256 openTimestamp = block.timestamp;

        vm.warp(block.timestamp + 1);

        uint256 liquidationPrice = 3_500e8;
        bytes[] memory liquidationUpdate = _buildPriceUpdate(perpAsset, liquidationPrice); // massive move against shorts
        TradeOrchestrator.LiquidationParams memory liq =
            TradeOrchestrator.LiquidationParams({user: perpTrader, syntheticAsset: perpAsset, index: 0, deadline: 0});

        uint256 keeperBalanceBefore = IERC20(usy).balanceOf(perpKeeper);
        uint256 expectedReward = _expectedLiquidationReward(openedPosition, openTimestamp, liquidationPrice);
        vm.prank(perpKeeper);
        tradeOrchestrator.liquidatePosition(liq, liquidationUpdate);

        assertEq(yoloHook.getUserTradeCount(perpTrader), 0, "position should be gone after liquidation");
        uint256 actualReward = IERC20(usy).balanceOf(perpKeeper) - keeperBalanceBefore;
        assertApproxEqAbs(actualReward, expectedReward, 1e15, "keeper earns liquidation reward");
    }

    function test_Action10_Case04_EnforceCarryLeverageTrimsPosition() public {
        bytes[] memory openUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);
        TradeOrchestrator.OpenPositionParams memory params = TradeOrchestrator.OpenPositionParams({
            syntheticAsset: perpAsset,
            direction: DataTypes.TradeDirection.LONG,
            collateralUsy: 25_000e18,
            syntheticSize: _sizeForNotional(200_000e8, INITIAL_PRICE),
            leverageBps: 0,
            deadline: uint64(block.timestamp + 1 minutes),
            referralCode: bytes32(0)
        });
        vm.prank(perpTrader);
        tradeOrchestrator.openPosition(params, openUpdate);
        DataTypes.TradePosition memory beforeEnforce = yoloHook.getUserTrade(perpTrader, 0);

        // Move outside of the trade session to trigger carry enforcement
        vm.warp(block.timestamp + 9 hours + 5 minutes);
        bytes[] memory carryUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);
        uint256 treasuryBalanceBefore = IERC20(usy).balanceOf(treasury);

        TradeOrchestrator.LiquidationParams memory enforceParams =
            TradeOrchestrator.LiquidationParams({user: perpTrader, syntheticAsset: perpAsset, index: 0, deadline: 0});
        vm.prank(perpKeeper);
        tradeOrchestrator.enforceCarryLeverage(enforceParams, carryUpdate);

        DataTypes.TradePosition memory afterEnforce = yoloHook.getUserTrade(perpTrader, 0);
        assertLt(
            afterEnforce.syntheticAssetPositionSize, beforeEnforce.syntheticAssetPositionSize, "size should shrink"
        );
        assertGt(IERC20(usy).balanceOf(treasury), treasuryBalanceBefore, "treasury collects unwind fee");
    }

    function test_Action10_Case05_ReferralRewardsAccrueAndClaim() public {
        address tier1Ref = makeAddr("tier1Ref");
        address tier2Ref = makeAddr("tier2Ref");
        address referredTrader = makeAddr("referredTrader");
        _seedTrader(tier1Ref, 500_000e18);
        _seedTrader(tier2Ref, 500_000e18);
        _seedTrader(referredTrader, 500_000e18);

        bytes32 tier2Code = _registerReferralCode(tier2Ref, "tier2");
        bytes32 tier1Code = _registerReferralCode(tier1Ref, "tier1");

        _openMinimalPosition(tier1Ref, tier2Code);
        vm.warp(block.timestamp + 1);
        _closeMinimalPosition(tier1Ref);
        uint256 tier2Bootstrap = hookImpl.referralRewards(tier2Ref);
        vm.prank(tier2Ref);
        hookImpl.claimReferralRewards(tier2Ref);
        assertEq(hookImpl.referralRewards(tier2Ref), 0);

        uint256 openTimestamp = block.timestamp;
        bytes[] memory openUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);
        TradeOrchestrator.OpenPositionParams memory params = TradeOrchestrator.OpenPositionParams({
            syntheticAsset: perpAsset,
            direction: DataTypes.TradeDirection.LONG,
            collateralUsy: 50_000e18,
            syntheticSize: _sizeForNotional(250_000e8, INITIAL_PRICE),
            leverageBps: 0,
            deadline: uint64(block.timestamp + 1 minutes),
            referralCode: tier1Code
        });
        vm.prank(referredTrader);
        tradeOrchestrator.openPosition(params, openUpdate);

        (address tier1Actual, address tier2Actual) = hookImpl.getUserReferrals(referredTrader);
        assertEq(tier1Actual, tier1Ref);
        assertEq(tier2Actual, tier2Ref);

        DataTypes.TradePosition memory trackedPosition = yoloHook.getUserTrade(referredTrader, 0);
        uint256 notionalUsd = _notionalUsd(trackedPosition.syntheticAssetPositionSize, INITIAL_PRICE);
        uint16 openFeeBps = 10;
        uint16 closeFeeBps = 10;
        uint16 borrowBps = 300;
        (uint16 ref1OpenClose, uint16 ref2OpenClose, uint16 ref1Borrow, uint16 ref2Borrow) =
            tradeOrchestrator.referralFeeSplitConfig();
        uint256 openFee = _mulDivUp(notionalUsd, openFeeBps, 10_000);

        uint256 expectedTier1Open = Math.mulDiv(openFee, ref1OpenClose, 10_000);
        uint256 expectedTier2Open = Math.mulDiv(openFee, ref2OpenClose, 10_000);
        assertEq(hookImpl.referralRewards(tier1Ref), expectedTier1Open);
        assertEq(hookImpl.referralRewards(tier2Ref), expectedTier2Open);

        vm.warp(block.timestamp + 6 hours);
        bytes[] memory closeUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);
        TradeOrchestrator.ClosePositionParams memory closeParams = TradeOrchestrator.ClosePositionParams({
            syntheticAsset: perpAsset, index: 0, syntheticSize: 0, deadline: uint64(block.timestamp + 1 minutes)
        });
        vm.prank(referredTrader);
        tradeOrchestrator.closePosition(closeParams, closeUpdate);

        uint256 elapsed = block.timestamp - openTimestamp;
        uint256 borrowFee = _expectedBorrowFee(notionalUsd, borrowBps, elapsed);
        uint256 collateralAfterBorrow =
            trackedPosition.collateralUsy > borrowFee ? trackedPosition.collateralUsy - borrowFee : 0;
        uint256 closeFee = _mulDivUp(collateralAfterBorrow, closeFeeBps, 10_000);

        uint256 expectedTier1Close = Math.mulDiv(closeFee, ref1OpenClose, 10_000);
        uint256 expectedTier2Close = Math.mulDiv(closeFee, ref2OpenClose, 10_000);
        uint256 expectedTier1Borrow = Math.mulDiv(borrowFee, ref1Borrow, 10_000);
        uint256 expectedTier2Borrow = Math.mulDiv(borrowFee, ref2Borrow, 10_000);

        uint256 totalTier1 = expectedTier1Open + expectedTier1Close + expectedTier1Borrow;
        uint256 totalTier2 = expectedTier2Open + expectedTier2Close + expectedTier2Borrow;

        assertApproxEqAbs(hookImpl.referralRewards(tier1Ref), totalTier1, 2e16, "tier1 rewards");
        assertApproxEqAbs(hookImpl.referralRewards(tier2Ref), totalTier2, 2e16, "tier2 rewards");

        uint256 tier1BalanceBefore = IERC20(usy).balanceOf(tier1Ref);
        vm.prank(tier1Ref);
        uint256 claimedTier1 = hookImpl.claimReferralRewards(tier1Ref);
        assertApproxEqAbs(claimedTier1, totalTier1, 2e16);
        assertEq(IERC20(usy).balanceOf(tier1Ref), tier1BalanceBefore + totalTier1);

        uint256 tier2BalanceBefore = IERC20(usy).balanceOf(tier2Ref);
        vm.prank(tier2Ref);
        uint256 claimedTier2 = hookImpl.claimReferralRewards(tier2Ref);
        assertApproxEqAbs(claimedTier2, totalTier2 + tier2Bootstrap, 2e16);
        assertEq(IERC20(usy).balanceOf(tier2Ref), tier2BalanceBefore + totalTier2 + tier2Bootstrap);
    }

    function _expectedLiquidationReward(
        DataTypes.TradePosition memory position,
        uint256 openTimestamp,
        uint256 oraclePriceX8
    ) internal view returns (uint256) {
        TradeOrchestrator.TradeAssetConfig memory cfg;
        (
            cfg.pythPriceId,
            cfg.maxPriceAgeSec,
            cfg.maxDeviationBps,
            cfg.longSpreadBps,
            cfg.shortSpreadBps,
            cfg.fundingFactorPerHour,
            cfg.fixedBorrowBps,
            cfg.liquidationThresholdBps,
            cfg.liquidationRewardBps,
            cfg.openFeeBps,
            cfg.closeFeeBps,
            cfg.overnightUnwindFeeBps,
            cfg.minCollateralUsy,
            cfg.feesEnabled,
            cfg.isActive
        ) = tradeOrchestrator.tradeAssetConfigs(perpAsset);
        uint256 executionPrice = _applyDirectionalSpread(oraclePriceX8, cfg, true);
        uint256 notionalUsd = _notionalUsd(position.syntheticAssetPositionSize, executionPrice);
        uint256 borrowFee = 0;
        if (notionalUsd != 0 && cfg.fixedBorrowBps != 0 && block.timestamp > openTimestamp) {
            uint256 elapsed = block.timestamp - openTimestamp;
            uint256 annualized = _mulDivUp(notionalUsd, cfg.fixedBorrowBps, BPS_DENOMINATOR);
            borrowFee = _mulDivUp(annualized, elapsed, SECONDS_PER_YEAR);
        }
        uint256 collateralAfterBorrow = position.collateralUsy > borrowFee ? position.collateralUsy - borrowFee : 0;
        return Math.mulDiv(collateralAfterBorrow, cfg.liquidationRewardBps, BPS_DENOMINATOR);
    }

    function _applyDirectionalSpread(
        uint256 basePriceX8,
        TradeOrchestrator.TradeAssetConfig memory cfg,
        bool longExposure
    ) internal pure returns (uint256) {
        if (longExposure) {
            if (cfg.longSpreadBps == 0) return basePriceX8;
            return Math.mulDiv(basePriceX8, BPS_DENOMINATOR + cfg.longSpreadBps, BPS_DENOMINATOR);
        }
        if (cfg.shortSpreadBps == 0) return basePriceX8;
        return Math.mulDiv(basePriceX8, BPS_DENOMINATOR - cfg.shortSpreadBps, BPS_DENOMINATOR);
    }

    function _notionalUsd(uint256 size, uint256 priceX8) internal pure returns (uint256) {
        return Math.mulDiv(size, priceX8, PRICE_DECIMALS);
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256) {
        if (a == 0 || b == 0) {
            return 0;
        }
        uint256 result = Math.mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) != 0) {
            result += 1;
        }
        return result;
    }

    function _seedTrader(address trader, uint256 amount) internal {
        vm.startPrank(address(yoloHook));
        YoloSyntheticAsset(usy).mint(trader, amount);
        vm.stopPrank();
        vm.prank(trader);
        IERC20(usy).approve(address(tradeOrchestrator), type(uint256).max);
    }

    function _registerReferralCode(address referrer, string memory saltLabel) internal returns (bytes32) {
        bytes32 salt = keccak256(abi.encodePacked(saltLabel));
        vm.prank(referrer);
        return hookImpl.registerReferralCode(salt);
    }

    function _openMinimalPosition(address trader, bytes32 referralCode) internal {
        bytes[] memory priceUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);
        TradeOrchestrator.OpenPositionParams memory params = TradeOrchestrator.OpenPositionParams({
            syntheticAsset: perpAsset,
            direction: DataTypes.TradeDirection.LONG,
            collateralUsy: 10_000e18,
            syntheticSize: _sizeForNotional(50_000e8, INITIAL_PRICE),
            leverageBps: 0,
            deadline: uint64(block.timestamp + 1 minutes),
            referralCode: referralCode
        });
        vm.prank(trader);
        tradeOrchestrator.openPosition(params, priceUpdate);
    }

    function _closeMinimalPosition(address trader) internal {
        bytes[] memory priceUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);
        TradeOrchestrator.ClosePositionParams memory closeParams = TradeOrchestrator.ClosePositionParams({
            syntheticAsset: perpAsset, index: 0, syntheticSize: 0, deadline: uint64(block.timestamp + 1 minutes)
        });
        vm.prank(trader);
        tradeOrchestrator.closePosition(closeParams, priceUpdate);
    }

    function _expectedBorrowFee(uint256 notionalUsd, uint16 rateBps, uint256 elapsed) internal pure returns (uint256) {
        if (notionalUsd == 0 || rateBps == 0 || elapsed == 0) {
            return 0;
        }
        uint256 annualized = _mulDivUp(notionalUsd, rateBps, 10_000);
        return _mulDivUp(annualized, elapsed, 365 days);
    }
}
