// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base04_TradePerpTestEnvironment} from "./base/Base04_TradePerpTestEnvironment.t.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {TradeOrchestrator} from "../src/trade/TradeOrchestrator.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestAction10_TradeOrchestratorPerps is Base04_TradePerpTestEnvironment {
    uint256 internal constant INITIAL_PRICE = 1_350e8;

    function setUp() public override {
        super.setUp();
        vm.warp(14 hours); // inside the configured trade session
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
            deadline: uint64(block.timestamp + 1 minutes)
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
            deadline: uint64(block.timestamp + 1 minutes)
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
            deadline: uint64(block.timestamp + 1 minutes)
        });
        vm.prank(perpTrader);
        tradeOrchestrator.openPosition(params, openUpdate);
        assertEq(yoloHook.getUserTradeCount(perpTrader), 1);
        DataTypes.TradePosition memory openedPosition = yoloHook.getUserTrade(perpTrader, 0);

        vm.warp(block.timestamp + 1);

        bytes[] memory liquidationUpdate = _buildPriceUpdate(perpAsset, 3_500e8); // massive move against shorts
        TradeOrchestrator.LiquidationParams memory liq =
            TradeOrchestrator.LiquidationParams({user: perpTrader, syntheticAsset: perpAsset, index: 0, deadline: 0});

        uint256 keeperBalanceBefore = IERC20(usy).balanceOf(perpKeeper);
        vm.prank(perpKeeper);
        tradeOrchestrator.liquidatePosition(liq, liquidationUpdate);

        assertEq(yoloHook.getUserTradeCount(perpTrader), 0, "position should be gone after liquidation");
        uint256 expectedReward = (openedPosition.collateralUsy * 500) / 10_000;
        assertEq(
            IERC20(usy).balanceOf(perpKeeper) - keeperBalanceBefore, expectedReward, "keeper earns liquidation reward"
        );
    }

    function test_Action10_Case04_EnforceCarryLeverageTrimsPosition() public {
        bytes[] memory openUpdate = _buildPriceUpdate(perpAsset, INITIAL_PRICE);
        TradeOrchestrator.OpenPositionParams memory params = TradeOrchestrator.OpenPositionParams({
            syntheticAsset: perpAsset,
            direction: DataTypes.TradeDirection.LONG,
            collateralUsy: 25_000e18,
            syntheticSize: _sizeForNotional(200_000e8, INITIAL_PRICE),
            leverageBps: 0,
            deadline: uint64(block.timestamp + 1 minutes)
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
}
