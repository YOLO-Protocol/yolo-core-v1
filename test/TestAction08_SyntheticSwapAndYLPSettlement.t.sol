// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base03_DeployComprehensiveTestEnvironment} from "./base/Base03_DeployComprehensiveTestEnvironment.t.sol";
import {YLP} from "../src/tokenization/YLP.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

/**
 * @title TestAction08_SyntheticSwapAndYLPSettlement
 * @notice Comprehensive integration tests for synthetic swap lifecycle with YLP settlement
 * @dev Tests the complete flow: swap → price change → settlement → YLP NAV impact
 */
contract TestAction08_SyntheticSwapAndYLPSettlement is Base03_DeployComprehensiveTestEnvironment {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    uint256 constant SYNTHETIC_FEE_BPS = 10; // 0.10%

    // Test accounts
    address public solver;
    address public lpProvider;
    address public trader1;
    address public trader2;
    address public trader3;

    // Pool keys
    PoolKey public yETHPoolKey;
    bool public isToken0USY_ETH;

    PoolKey public yBTCPoolKey;
    bool public isToken0USY_BTC;

    // YLP instance
    YLP public ylp;

    function setUp() public override {
        super.setUp();

        // Setup test accounts
        solver = makeAddr("solver");
        lpProvider = makeAddr("lpProvider");
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");
        trader3 = makeAddr("trader3");

        // Setup YLP
        ylp = YLP(ylpVault);

        // Create and grant YLP_SOLVER role
        bytes32 ylpSolverRole = ylp.YLP_SOLVER_ROLE();
        aclManager.createRole("YLP_SOLVER", bytes32(0));
        aclManager.grantRole(ylpSolverRole, solver);

        // Set minBlockLag to 0 for easier testing (address(this) has RISK_ADMIN from Base03)
        ylp.setMinBlockLag(0);

        // Setup pool keys
        yETHPoolKey = _getSyntheticPoolKey(yETH);
        isToken0USY_ETH = Currency.unwrap(yETHPoolKey.currency0) == usy;

        yBTCPoolKey = _getSyntheticPoolKey(yBTC);
        isToken0USY_BTC = Currency.unwrap(yBTCPoolKey.currency0) == usy;

        // Fund test accounts (trader1 needs 800K for auto-pause test)
        deal(usy, lpProvider, 1_000_000e18);
        deal(usy, trader1, 1_000_000e18);
        deal(usy, trader2, 500_000e18);
        deal(usy, trader3, 500_000e18);

        // Approve tokens
        _approveTokens();
    }

    // ============================================================
    // SETUP HELPERS
    // ============================================================

    function _approveTokens() internal {
        address[4] memory accounts = [lpProvider, trader1, trader2, trader3];
        for (uint256 i = 0; i < accounts.length; i++) {
            vm.startPrank(accounts[i]);
            IERC20(usy).approve(address(swapRouter), type(uint256).max);
            IERC20(usy).approve(address(ylp), type(uint256).max);
            IERC20(yETH).approve(address(swapRouter), type(uint256).max);
            IERC20(yBTC).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ============================================================
    // TEST CASE 01: Basic Settlement - Trader Profit
    // ============================================================

    /**
     * @notice Test basic settlement when trader makes a profit
     * @dev Scenario:
     *      1. LP provides 100K USY to YLP
     *      2. Trader buys yETH at $3,200
     *      3. Price rises to $3,700
     *      4. Trader sells yETH
     *      5. YLP pays trader profit and NAV decreases
     */
    function test_Action08_Case01_traderProfitYLPLoss() public {
        // Step 1: LP provides liquidity to YLP
        uint256 lpDeposit = 100_000e18;
        uint256 preFundedUSY = 1_000_000e18; // Base03 pre-funds YLP with 1M USY
        vm.prank(lpProvider);
        ylp.requestDeposit(lpDeposit, 0, 500);

        // Seal first epoch
        vm.roll(block.number + 10);
        vm.prank(solver);
        (uint256 epochId, uint256 navBefore,) = ylp.sealEpoch(0, block.number);
        assertEq(navBefore, preFundedUSY + lpDeposit, "Initial NAV should equal pre-funding + deposit");

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        uint256 ylpSharesBefore = ylp.balanceOf(lpProvider);
        assertEq(ylpSharesBefore, lpDeposit, "LP should receive shares 1:1 on first deposit");

        // Step 2: Trader buys yETH at current price
        uint256 initialPrice = yoloOracleReal.getAssetPrice(yETH);
        uint256 amountIn = 10_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, amountIn);

        // Burn pending to complete the mint
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 yethBalance = IERC20(yETH).balanceOf(trader1);
        assertGt(yethBalance, 0, "Trader should have yETH");

        // Step 3: Price rises to $3,700
        uint256 newPrice = 3700e8;
        wethOracle.updateAnswer(SafeCast.toInt256(newPrice));
        yETHOracle.updateAnswer(SafeCast.toInt256(newPrice));

        // Verify unrealized PnL calculation
        YoloSyntheticAsset yethToken = YoloSyntheticAsset(yETH);
        uint128 avgCost = yethToken.avgPriceX8(trader1);
        assertEq(avgCost, SafeCast.toUint128(initialPrice), "Average cost should match entry price");

        // Unrealized profit = (newPrice - initialPrice) * qty
        uint256 expectedProfit = ((newPrice - initialPrice) * yethBalance) / 1e8;

        // Step 4: Trader sells yETH
        uint256 usyBefore = IERC20(usy).balanceOf(trader1);
        uint256 ylpUSYBefore = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader1);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, yethBalance);

        // Burn pending to trigger settlement
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        // Step 5: Verify settlement
        uint256 usyAfter = IERC20(usy).balanceOf(trader1);
        uint256 ylpUSYAfter = IERC20(usy).balanceOf(address(ylp));

        // Trader should receive more USY than they paid (profit)
        assertGt(usyAfter, usyBefore, "Trader should receive USY from swap");

        // YLP should have LESS USY (paid out profit)
        assertLt(ylpUSYAfter, ylpUSYBefore, "YLP should pay out trader profit");

        // Calculate actual profit realized
        uint256 netUSYReceived = usyAfter - usyBefore;
        uint256 ylpLoss = ylpUSYBefore - ylpUSYAfter;

        // YLP loss should approximately equal trader gain (within fee margin)
        assertApproxEqAbs(ylpLoss, expectedProfit, 100e18, "YLP loss should match trader profit");

        // Step 6: Seal next epoch and verify NAV decreased
        vm.roll(block.number + 20);
        vm.prank(solver);
        (uint256 epochId2, uint256 navAfter,) = ylp.sealEpoch(0, block.number);

        assertLt(navAfter, navBefore, "YLP NAV should decrease after paying trader profit");
        assertEq(navAfter, ylpUSYAfter, "NAV should equal USY balance");
    }

    // ============================================================
    // TEST CASE 02: Basic Settlement - Trader Loss
    // ============================================================

    /**
     * @notice Test basic settlement when trader makes a loss
     * @dev Scenario:
     *      1. LP provides 100K USY to YLP
     *      2. Trader buys yETH at $3,200
     *      3. Price drops to $2,700
     *      4. Trader sells yETH at a loss
     *      5. YLP receives trader's loss and NAV increases
     */
    function test_Action08_Case02_traderLossYLPGain() public {
        // Step 1: LP provides liquidity
        uint256 lpDeposit = 100_000e18;
        vm.prank(lpProvider);
        ylp.requestDeposit(lpDeposit, 0, 500);

        vm.roll(block.number + 10);
        vm.prank(solver);
        (uint256 epochId, uint256 navBefore,) = ylp.sealEpoch(0, block.number);

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        // Step 2: Trader buys yETH at current price
        uint256 initialPrice = yoloOracleReal.getAssetPrice(yETH);
        uint256 amountIn = 20_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, amountIn);

        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 yethBalance = IERC20(yETH).balanceOf(trader1);
        assertGt(yethBalance, 0, "Trader should have yETH");

        // Step 3: Price drops to $2,700
        uint256 newPrice = 2700e8;
        wethOracle.updateAnswer(SafeCast.toInt256(newPrice));
        yETHOracle.updateAnswer(SafeCast.toInt256(newPrice));

        // Verify unrealized loss
        YoloSyntheticAsset yethToken = YoloSyntheticAsset(yETH);
        uint128 avgCost = yethToken.avgPriceX8(trader1);
        assertEq(avgCost, SafeCast.toUint128(initialPrice), "Average cost should match entry price");

        // Unrealized loss = (initialPrice - newPrice) * qty
        int256 expectedLoss = SafeCast.toInt256((initialPrice - newPrice) * yethBalance) / 1e8;

        // Step 4: Trader sells at a loss
        uint256 ylpUSYBefore = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader1);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, yethBalance);

        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        // Step 5: Verify YLP gained USY
        uint256 ylpUSYAfter = IERC20(usy).balanceOf(address(ylp));

        // YLP should have MORE USY (received trader's loss)
        assertGt(ylpUSYAfter, ylpUSYBefore, "YLP should receive trader's loss");

        uint256 ylpGain = ylpUSYAfter - ylpUSYBefore;

        // YLP gain should approximately equal trader loss (within rounding)
        assertApproxEqAbs(ylpGain, SafeCast.toUint256(expectedLoss), 100e18, "YLP gain should match trader loss");

        // Step 6: Verify NAV increased
        vm.roll(block.number + 20);
        vm.prank(solver);
        (uint256 epochId2, uint256 navAfter,) = ylp.sealEpoch(0, block.number);

        assertGt(navAfter, navBefore, "YLP NAV should increase after receiving trader loss");
    }

    // ============================================================
    // TEST CASE 03: Multiple Traders With Different Entry Prices
    // ============================================================

    /**
     * @notice Test YLP settlement with multiple traders at different entry prices
     * @dev Scenario:
     *      1. Trader1 buys yETH at $3,200
     *      2. Price rises to $3,500
     *      3. Trader2 buys yETH at $3,500
     *      4. Price rises to $3,800
     *      5. Both traders sell
     *      6. YLP settles different PnL for each trader
     */
    function test_Action08_Case03_multipleTradersSettlement() public {
        // Setup: LP provides liquidity
        uint256 lpDeposit = 200_000e18;
        vm.prank(lpProvider);
        ylp.requestDeposit(lpDeposit, 0, 500);

        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        // Step 1: Trader1 buys at current price
        uint256 price1 = yoloOracleReal.getAssetPrice(yETH);
        uint256 trader1AmountIn = 10_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, trader1AmountIn);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 trader1YETH = IERC20(yETH).balanceOf(trader1);

        // Step 2: Price rises to $3,500
        uint256 price2 = 3500e8;
        wethOracle.updateAnswer(SafeCast.toInt256(price2));
        yETHOracle.updateAnswer(SafeCast.toInt256(price2));

        // Step 3: Trader2 buys at $3,500
        uint256 trader2AmountIn = 11_000e18;
        vm.prank(trader2);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, trader2AmountIn);
        vm.prank(trader2);
        yoloHook.burnPendingSynthetic();

        uint256 trader2YETH = IERC20(yETH).balanceOf(trader2);

        // Verify different average costs
        YoloSyntheticAsset yethToken = YoloSyntheticAsset(yETH);
        uint128 trader1AvgCost = yethToken.avgPriceX8(trader1);
        uint128 trader2AvgCost = yethToken.avgPriceX8(trader2);
        assertEq(trader1AvgCost, SafeCast.toUint128(price1), "Trader1 avg cost should match entry price");
        assertEq(trader2AvgCost, SafeCast.toUint128(price2), "Trader2 avg cost should be $3,500");

        // Step 4: Price rises to $3,800
        uint256 price3 = 3800e8;
        wethOracle.updateAnswer(SafeCast.toInt256(price3));
        yETHOracle.updateAnswer(SafeCast.toInt256(price3));

        // Calculate expected profits
        uint256 expectedProfit1 = ((price3 - price1) * trader1YETH) / 1e8;
        uint256 expectedProfit2 = ((price3 - price2) * trader2YETH) / 1e8;

        // Step 5: Both traders sell
        uint256 ylpUSYBefore = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader1);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, trader1YETH);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        vm.prank(trader2);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, trader2YETH);
        vm.prank(trader2);
        yoloHook.burnPendingSynthetic();

        // Step 6: Verify YLP paid out both profits
        uint256 ylpUSYAfter = IERC20(usy).balanceOf(address(ylp));
        uint256 totalYLPLoss = ylpUSYBefore - ylpUSYAfter;

        uint256 totalExpectedProfit = expectedProfit1 + expectedProfit2;
        assertApproxEqAbs(totalYLPLoss, totalExpectedProfit, 200e18, "Total YLP loss should match sum of profits");

        // Verify NAV reflects total loss
        vm.roll(block.number + 20);
        vm.prank(solver);
        (uint256 epochId, uint256 navAfter,) = ylp.sealEpoch(0, block.number);
        assertEq(navAfter, ylpUSYAfter, "NAV should equal remaining USY");
    }

    // ============================================================
    // TEST CASE 04: Unrealized PnL In Epoch Sealing
    // ============================================================

    /**
     * @notice Test YLP epoch sealing with unrealized PnL
     * @dev Scenario:
     *      1. Trader opens position
     *      2. Price changes but position not closed
     *      3. Solver seals epoch with unrealized PnL
     *      4. NAV reflects unrealized PnL
     *      5. Trader closes position
     *      6. NAV updates with realized PnL
     */
    function test_Action08_Case04_unrealizedPnLInEpochSealing() public {
        // Setup: LP provides liquidity
        uint256 lpDeposit = 100_000e18;
        uint256 preFundedUSY = 1_000_000e18; // Base03 pre-funds YLP with 1M USY
        vm.prank(lpProvider);
        ylp.requestDeposit(lpDeposit, 0, 500);

        vm.roll(block.number + 10);
        vm.prank(solver);
        (uint256 epoch1, uint256 nav1,) = ylp.sealEpoch(0, block.number);
        assertEq(nav1, preFundedUSY + lpDeposit, "Initial NAV should include pre-funding");

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        // Step 1: Trader opens position at current price
        uint256 initialPrice = yoloOracleReal.getAssetPrice(yETH);
        uint256 amountIn = 20_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, amountIn);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 yethBalance = IERC20(yETH).balanceOf(trader1);

        // Step 2: Price rises to $3,800 (unrealized profit for trader)
        uint256 newPrice = 3800e8;
        wethOracle.updateAnswer(SafeCast.toInt256(newPrice));
        yETHOracle.updateAnswer(SafeCast.toInt256(newPrice));

        // Calculate unrealized PnL from YLP's perspective (negative = loss)
        int256 unrealizedPnL = -SafeCast.toInt256(((newPrice - initialPrice) * yethBalance) / 1e8);

        // Step 3: Solver seals epoch with unrealized loss
        vm.roll(block.number + 20);
        vm.prank(solver);
        (uint256 epoch2, uint256 nav2,) = ylp.sealEpoch(unrealizedPnL, block.number);

        // NAV should reflect unrealized loss
        uint256 ylpUSYBalance = IERC20(usy).balanceOf(address(ylp));
        int256 expectedNAV = SafeCast.toInt256(ylpUSYBalance) + unrealizedPnL;
        assertEq(SafeCast.toInt256(nav2), expectedNAV, "NAV should include unrealized PnL");

        // Step 4: Trader closes position (realize the PnL)
        uint256 ylpUSYBefore = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader1);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, yethBalance);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 ylpUSYAfter = IERC20(usy).balanceOf(address(ylp));

        // Step 5: Verify realized PnL matches unrealized
        uint256 realizedLoss = ylpUSYBefore - ylpUSYAfter;
        assertApproxEqAbs(
            realizedLoss, SafeCast.toUint256(-unrealizedPnL), 100e18, "Realized loss should match unrealized"
        );

        // Step 6: Seal final epoch with no unrealized PnL
        vm.roll(block.number + 30);
        vm.prank(solver);
        (uint256 epoch3, uint256 nav3,) = ylp.sealEpoch(0, block.number);

        // NAV should now reflect only actual USY balance
        assertEq(nav3, ylpUSYAfter, "Final NAV should equal USY balance");
    }

    // ============================================================
    // TEST CASE 05: Price Volatility With Multiple Assets
    // ============================================================

    /**
     * @notice Test YLP settlement with multiple synthetic assets and price volatility
     * @dev Scenario:
     *      1. Trader1 buys yETH, Trader2 buys yBTC
     *      2. yETH price increases, yBTC price decreases
     *      3. Both traders close positions
     *      4. YLP settles mixed PnL (pays yETH profit, receives yBTC loss)
     */
    function test_Action08_Case05_multiAssetPriceVolatility() public {
        // Setup: LP provides liquidity
        uint256 lpDeposit = 500_000e18;
        vm.prank(lpProvider);
        ylp.requestDeposit(lpDeposit, 0, 500);

        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        uint256 ylpUSYInitial = IERC20(usy).balanceOf(address(ylp));

        // Step 1: Trader1 buys yETH at current price
        uint256 initialETHPrice = yoloOracleReal.getAssetPrice(yETH);
        uint256 trader1AmountIn = 20_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, trader1AmountIn);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 trader1YETH = IERC20(yETH).balanceOf(trader1);

        // Step 2: Trader2 buys yBTC at current price
        uint256 initialBTCPrice = yoloOracleReal.getAssetPrice(yBTC);
        uint256 trader2AmountIn = 100_000e18;
        vm.prank(trader2);
        _swapUSYForSynthetic(yBTCPoolKey, isToken0USY_BTC, trader2AmountIn);
        vm.prank(trader2);
        yoloHook.burnPendingSynthetic();

        uint256 trader2YBTC = IERC20(yBTC).balanceOf(trader2);

        // Step 3: yETH price increases to $3,700 (+15.6%)
        uint256 newETHPrice = 3700e8;
        wethOracle.updateAnswer(SafeCast.toInt256(newETHPrice));
        yETHOracle.updateAnswer(SafeCast.toInt256(newETHPrice));

        // Step 4: yBTC price decreases to $61,200 (-10%)
        uint256 newBTCPrice = 61_200e8;
        wbtcOracle.updateAnswer(SafeCast.toInt256(newBTCPrice));
        yBTCOracle.updateAnswer(SafeCast.toInt256(newBTCPrice));

        // Calculate expected PnL
        uint256 expectedETHProfit = ((newETHPrice - initialETHPrice) * trader1YETH) / 1e8;
        uint256 expectedBTCLoss = ((initialBTCPrice - newBTCPrice) * trader2YBTC) / 1e8;

        // Step 5: Both traders close positions
        uint256 ylpUSYBefore = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader1);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, trader1YETH);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        vm.prank(trader2);
        _swapSyntheticForUSY(yBTCPoolKey, isToken0USY_BTC, trader2YBTC);
        vm.prank(trader2);
        yoloHook.burnPendingSynthetic();

        uint256 ylpUSYAfter = IERC20(usy).balanceOf(address(ylp));

        // Step 6: Verify net PnL
        // YLP pays ETH profit but receives BTC loss
        // Net = BTCLoss - ETHProfit
        if (expectedBTCLoss > expectedETHProfit) {
            // YLP net gain
            uint256 netGain = expectedBTCLoss - expectedETHProfit;
            assertGt(ylpUSYAfter, ylpUSYBefore, "YLP should have net gain");
            assertApproxEqAbs(ylpUSYAfter - ylpUSYBefore, netGain, 200e18, "Net gain should match expected");
        } else {
            // YLP net loss
            uint256 netLoss = expectedETHProfit - expectedBTCLoss;
            assertLt(ylpUSYAfter, ylpUSYBefore, "YLP should have net loss");
            assertApproxEqAbs(ylpUSYBefore - ylpUSYAfter, netLoss, 200e18, "Net loss should match expected");
        }
    }

    // ============================================================
    // TEST CASE 06: Large Price Movement And Auto-Pause
    // ============================================================

    /**
     * @notice Test YLP auto-pause mechanism on extreme losses
     * @dev Scenario:
     *      1. Trader opens large position
     *      2. Price moves dramatically in trader's favor
     *      3. Solver seals epoch with extreme unrealized loss
     *      4. YLP auto-pauses deposits
     *      5. Withdrawals still work (withdraw-only mode)
     */
    function test_Action08_Case06_extremePriceMoveAutoPause() public {
        // Setup: LP provides large liquidity
        uint256 lpDeposit = 1_000_000e18;
        uint256 preFundedUSY = 1_000_000e18; // Base03 pre-funds YLP with 1M USY
        uint256 totalNAV = preFundedUSY + lpDeposit; // 2M total
        vm.prank(lpProvider);
        ylp.requestDeposit(lpDeposit, 0, 500);

        // Increase rate limit to allow extreme price move without triggering rate-of-change guard
        ylp.setMaxRateChangeBps(5000); // 50% - allows testing auto-pause

        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        // Step 1: Trader opens large position at current price
        uint256 initialPrice = yoloOracleReal.getAssetPrice(yETH);
        uint256 amountIn = 800_000e18; // 40% of total 2M NAV (1M pre-funded + 1M deposited)
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, amountIn);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 yethBalance = IERC20(yETH).balanceOf(trader1);

        // Step 2: Extreme price movement (+100%)
        uint256 newPrice = initialPrice * 2;
        wethOracle.updateAnswer(SafeCast.toInt256(newPrice));
        yETHOracle.updateAnswer(SafeCast.toInt256(newPrice));

        // Calculate unrealized loss (>35% triggers auto-pause)
        int256 unrealizedPnL = -SafeCast.toInt256(((newPrice - initialPrice) * yethBalance) / 1e8);
        uint256 ylpUSY = IERC20(usy).balanceOf(address(ylp));
        uint256 lossPercent = (SafeCast.toUint256(-unrealizedPnL) * 10000) / ylpUSY;

        // Loss should exceed 35% threshold (3500 bps)
        assertGt(lossPercent, 3500, "Loss should exceed auto-pause threshold");

        // Step 3: Seal epoch - should auto-pause
        vm.roll(block.number + 20);
        vm.prank(solver);
        ylp.sealEpoch(unrealizedPnL, block.number);

        // Step 4: Verify deposits are paused
        vm.startPrank(trader2);
        IERC20(usy).approve(address(ylp), 10_000e18);
        vm.expectRevert(YLP.YLP__DepositsPaused.selector);
        ylp.requestDeposit(10_000e18, 0, 500);
        vm.stopPrank();

        // Step 5: Verify withdrawals still work
        uint256 lpShares = ylp.balanceOf(lpProvider);
        vm.startPrank(lpProvider);
        ylp.approve(address(ylp), lpShares);
        uint256 withdrawRequestId = ylp.requestWithdrawal(lpShares / 2, 0, 500);
        vm.stopPrank();

        assertEq(withdrawRequestId, 0, "Withdrawal request should succeed during pause");
    }

    // ============================================================
    // TEST CASE 07: Sequential Trades With Price Discovery
    // ============================================================

    /**
     * @notice Test multiple sequential trades with evolving prices
     * @dev Scenario:
     *      1. Trader1 opens at $3,200
     *      2. Price moves to $3,500, Trader1 closes (profit)
     *      3. Trader2 opens at $3,500
     *      4. Price drops to $3,000, Trader2 closes (loss)
     *      5. Verify YLP NAV tracks both settlements correctly
     */
    function test_Action08_Case07_sequentialTradesWithPriceDiscovery() public {
        // Setup: LP provides liquidity
        uint256 lpDeposit = 200_000e18;
        vm.prank(lpProvider);
        ylp.requestDeposit(lpDeposit, 0, 500);

        vm.roll(block.number + 10);
        vm.prank(solver);
        (, uint256 navInitial,) = ylp.sealEpoch(0, block.number);

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        // Trade 1: Trader1 opens at current price
        uint256 price1 = yoloOracleReal.getAssetPrice(yETH);
        uint256 trade1Amount = 20_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, trade1Amount);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 trader1YETH = IERC20(yETH).balanceOf(trader1);

        // Price moves up to $3,500
        uint256 price2 = 3500e8;
        wethOracle.updateAnswer(SafeCast.toInt256(price2));
        yETHOracle.updateAnswer(SafeCast.toInt256(price2));

        // Trader1 closes (profit)
        uint256 ylpUSYBeforeTrade1 = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader1);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, trader1YETH);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 ylpUSYAfterTrade1 = IERC20(usy).balanceOf(address(ylp));
        uint256 ylpLoss1 = ylpUSYBeforeTrade1 - ylpUSYAfterTrade1;

        // Trade 2: Trader2 opens at $3,500
        uint256 trade2Amount = 22_000e18;
        vm.prank(trader2);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, trade2Amount);
        vm.prank(trader2);
        yoloHook.burnPendingSynthetic();

        uint256 trader2YETH = IERC20(yETH).balanceOf(trader2);

        // Price drops to $3,000
        uint256 price3 = 3000e8;
        wethOracle.updateAnswer(SafeCast.toInt256(price3));
        yETHOracle.updateAnswer(SafeCast.toInt256(price3));

        // Trader2 closes (loss)
        uint256 ylpUSYBeforeTrade2 = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader2);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, trader2YETH);
        vm.prank(trader2);
        yoloHook.burnPendingSynthetic();

        uint256 ylpUSYAfterTrade2 = IERC20(usy).balanceOf(address(ylp));
        uint256 ylpGain2 = ylpUSYAfterTrade2 - ylpUSYBeforeTrade2;

        // Verify net PnL
        if (ylpGain2 > ylpLoss1) {
            // YLP net gain
            assertGt(ylpUSYAfterTrade2, ylpUSYBeforeTrade1, "YLP should have net gain");
        } else {
            // YLP net loss
            assertLt(ylpUSYAfterTrade2, ylpUSYBeforeTrade1, "YLP should have net loss or break-even");
        }

        // Seal final epoch
        vm.roll(block.number + 30);
        vm.prank(solver);
        (, uint256 navFinal,) = ylp.sealEpoch(0, block.number);

        assertEq(navFinal, ylpUSYAfterTrade2, "Final NAV should match USY balance");
    }

    // ============================================================
    // TEST CASE 08: Partial Position Close
    // ============================================================

    /**
     * @notice Test partial position closure with YLP settlement
     * @dev Scenario:
     *      1. Trader opens position
     *      2. Price rises
     *      3. Trader closes 50% of position (partial profit)
     *      4. Price rises more
     *      5. Trader closes remaining 50%
     *      6. Verify YLP settles both partial closes correctly
     */
    function test_Action08_Case08_partialPositionClose() public {
        // Setup: LP provides liquidity
        uint256 lpDeposit = 150_000e18;
        vm.prank(lpProvider);
        ylp.requestDeposit(lpDeposit, 0, 500);

        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        // Step 1: Trader opens position at current price
        uint256 initialPrice = yoloOracleReal.getAssetPrice(yETH);
        uint256 amountIn = 20_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, amountIn);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 totalYETH = IERC20(yETH).balanceOf(trader1);

        // Step 2: Price rises to $3,800
        uint256 price2 = 3800e8;
        wethOracle.updateAnswer(SafeCast.toInt256(price2));
        yETHOracle.updateAnswer(SafeCast.toInt256(price2));

        // Step 3: Close 50% of position
        uint256 firstClose = totalYETH / 2;
        uint256 ylpUSYBefore1 = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader1);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, firstClose);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 ylpUSYAfter1 = IERC20(usy).balanceOf(address(ylp));
        uint256 ylpLoss1 = ylpUSYBefore1 - ylpUSYAfter1;

        // Expected profit from first close
        uint256 expectedProfit1 = ((price2 - initialPrice) * firstClose) / 1e8;
        assertApproxEqAbs(ylpLoss1, expectedProfit1, 50e18, "First partial close profit");

        // Step 4: Price rises to $4,400
        uint256 price3 = 4400e8;
        wethOracle.updateAnswer(SafeCast.toInt256(price3));
        yETHOracle.updateAnswer(SafeCast.toInt256(price3));

        // Step 5: Close remaining 50%
        uint256 secondClose = IERC20(yETH).balanceOf(trader1);
        uint256 ylpUSYBefore2 = IERC20(usy).balanceOf(address(ylp));

        vm.prank(trader1);
        _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, secondClose);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 ylpUSYAfter2 = IERC20(usy).balanceOf(address(ylp));
        uint256 ylpLoss2 = ylpUSYBefore2 - ylpUSYAfter2;

        // Expected profit from second close
        uint256 expectedProfit2 = ((price3 - initialPrice) * secondClose) / 1e8;
        assertApproxEqAbs(ylpLoss2, expectedProfit2, 50e18, "Second partial close profit");

        // Step 6: Verify total YLP loss
        uint256 totalYLPLoss = ylpUSYBefore1 - ylpUSYAfter2;
        uint256 totalExpectedLoss = expectedProfit1 + expectedProfit2;
        assertApproxEqAbs(totalYLPLoss, totalExpectedLoss, 100e18, "Total YLP loss from both closes");
    }

    // ============================================================
    // PHASE 1: PNL FUZZING - MULTI-ASSET CHAOS
    // ============================================================

    /**
     * @notice Fuzz: Multi-asset random sequences with alternating profit/loss
     * @dev Randomly selects between yETH and yBTC, applies random price movements,
     *      and verifies cumulative NAV changes match settlement outcomes
     * @param seed Random seed for deterministic randomness
     */
    function testFuzz_Action08_Case09_MultiAssetChaos(uint256 seed) public {
        // Bound to reasonable number of trades for gas limits
        uint8 numTrades = uint8((seed % 8) + 3); // 3-10 trades

        uint256 ylpUSYInitial = IERC20(usy).balanceOf(address(ylp));
        int256 cumulativePnL = 0;

        for (uint256 i = 0; i < numTrades; i++) {
            // Pseudo-random asset selection (0 = yETH, 1 = yBTC)
            uint256 assetChoice = uint256(keccak256(abi.encode(seed, i, "asset"))) % 2;

            // Random trade size: 5K to 80K USY
            uint256 tradeSize = ((uint256(keccak256(abi.encode(seed, i, "size"))) % 75_000e18) + 5_000e18);

            // Select asset and pool
            address synthetic = assetChoice == 0 ? yETH : yBTC;
            PoolKey memory poolKey = assetChoice == 0 ? yETHPoolKey : yBTCPoolKey;
            bool isToken0USY = assetChoice == 0 ? isToken0USY_ETH : isToken0USY_BTC;

            // Open position
            vm.prank(trader1);
            _swapUSYForSynthetic(poolKey, isToken0USY, tradeSize);
            vm.prank(trader1);
            yoloHook.burnPendingSynthetic();

            uint256 syntheticBalance = IERC20(synthetic).balanceOf(trader1);
            if (syntheticBalance == 0) continue; // Skip if swap failed

            uint256 entryPrice = yoloOracleReal.getAssetPrice(synthetic);

            // Random price change: -80% to +200% (extreme stress test)
            int256 priceChangeBps = SafeCast.toInt256(uint256(keccak256(abi.encode(seed, i, "price"))) % 28000) - 8000;
            uint256 newPrice = SafeCast.toUint256(
                SafeCast.toInt256(entryPrice) + (SafeCast.toInt256(entryPrice) * priceChangeBps) / 10000
            );

            // Apply price change with safety bounds
            if (newPrice > 100 && newPrice < 500000e8) {
                if (assetChoice == 0) {
                    wethOracle.updateAnswer(SafeCast.toInt256(newPrice));
                    yETHOracle.updateAnswer(SafeCast.toInt256(newPrice));
                } else {
                    wbtcOracle.updateAnswer(SafeCast.toInt256(newPrice));
                    yBTCOracle.updateAnswer(SafeCast.toInt256(newPrice));
                }

                // Calculate expected PnL
                int256 pnl = (SafeCast.toInt256(newPrice) - SafeCast.toInt256(entryPrice))
                    * SafeCast.toInt256(syntheticBalance) / 1e8;
                cumulativePnL += pnl;

                // Close position
                vm.prank(trader1);
                _swapSyntheticForUSY(poolKey, isToken0USY, syntheticBalance);
                vm.prank(trader1);
                yoloHook.burnPendingSynthetic();
            }
        }

        uint256 ylpUSYFinal = IERC20(usy).balanceOf(address(ylp));
        int256 actualYLPChange = SafeCast.toInt256(ylpUSYFinal) - SafeCast.toInt256(ylpUSYInitial);

        // INVARIANT: YLP change should be opposite of cumulative trader PnL
        // Allow tolerance proportional to number of trades and trade sizes
        // casting uint8 to uint256 is safe (no truncation possible)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 tolerance = uint256(numTrades) * 200e18;
        assertApproxEqAbs(actualYLPChange, -cumulativePnL, tolerance, "Multi-asset cumulative PnL mismatch");
    }

    /**
     * @notice Fuzz: Partial close chaos with multiple random partial closes
     * @dev Opens position, then performs 2-5 partial closes with random percentages,
     *      verifying cost basis remains consistent throughout
     * @param seed Random seed
     */
    function testFuzz_Action08_Case10_PartialCloseChaos(uint256 seed) public {
        // Number of partial closes: 2-5
        uint8 numPartialCloses = uint8((seed % 4) + 2);

        // Open large position
        uint256 initialAmount = 50_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, initialAmount);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 totalYETH = IERC20(yETH).balanceOf(trader1);
        if (totalYETH == 0) return; // Skip if initial swap failed

        uint256 entryPrice = yoloOracleReal.getAssetPrice(yETH);
        YoloSyntheticAsset yethToken = YoloSyntheticAsset(yETH);

        // Price rises for profit scenario
        uint256 newPrice = 4200e8;
        wethOracle.updateAnswer(SafeCast.toInt256(newPrice));
        yETHOracle.updateAnswer(SafeCast.toInt256(newPrice));

        uint256 remainingBalance = totalYETH;
        uint256 ylpUSYBefore = IERC20(usy).balanceOf(address(ylp));
        uint256 totalExpectedProfit = 0;

        // Perform multiple partial closes
        for (uint256 i = 0; i < numPartialCloses && remainingBalance > 100; i++) {
            // Random percentage: 10% to 40% of remaining
            uint256 closePercent = (uint256(keccak256(abi.encode(seed, i, "percent"))) % 31) + 10;
            uint256 closeAmount = (remainingBalance * closePercent) / 100;

            if (closeAmount == 0) closeAmount = remainingBalance; // Close all if too small

            // Calculate expected profit for this partial close
            uint256 expectedProfit = ((newPrice - entryPrice) * closeAmount) / 1e8;
            totalExpectedProfit += expectedProfit;

            // Execute partial close
            vm.prank(trader1);
            _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, closeAmount);
            vm.prank(trader1);
            yoloHook.burnPendingSynthetic();

            remainingBalance = yethToken.balanceOf(trader1);

            // INVARIANT: Cost basis must remain unchanged after partial close
            if (remainingBalance > 0) {
                uint128 avgCostAfterClose = yethToken.avgPriceX8(trader1);
                assertEq(avgCostAfterClose, SafeCast.toUint128(entryPrice), "Cost basis changed during partial close");
            }
        }

        uint256 ylpUSYAfter = IERC20(usy).balanceOf(address(ylp));
        uint256 actualYLPLoss = ylpUSYBefore - ylpUSYAfter;

        // Verify total YLP loss matches cumulative partial close profits
        assertApproxEqAbs(actualYLPLoss, totalExpectedProfit, 200e18, "Partial close cumulative profit mismatch");
    }

    /**
     * @notice Fuzz: Zero-sum settlement verification with simultaneous opposite positions
     * @dev Trader1 profits while Trader2 loses on same asset, verifies net settlement is zero-sum
     * @param ethPriceChangeBps Price change for yETH in basis points (-5000 to +10000)
     * @param btcPriceChangeBps Price change for yBTC in basis points (-5000 to +10000)
     */
    function testFuzz_Action08_Case11_ZeroSumSettlement(int16 ethPriceChangeBps, int16 btcPriceChangeBps) public {
        // Constrain price changes to reasonable bounds
        vm.assume(ethPriceChangeBps >= -5000 && ethPriceChangeBps <= 10000);
        vm.assume(btcPriceChangeBps >= -5000 && btcPriceChangeBps <= 10000);

        uint256 ylpUSYInitial = IERC20(usy).balanceOf(address(ylp));

        // Trader1 opens yETH position
        uint256 trader1AmountETH = 30_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, trader1AmountETH);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();
        uint256 trader1YETH = IERC20(yETH).balanceOf(trader1);
        uint256 ethEntryPrice = yoloOracleReal.getAssetPrice(yETH);

        // Trader2 opens yBTC position
        uint256 trader2AmountBTC = 80_000e18;
        vm.prank(trader2);
        _swapUSYForSynthetic(yBTCPoolKey, isToken0USY_BTC, trader2AmountBTC);
        vm.prank(trader2);
        yoloHook.burnPendingSynthetic();
        uint256 trader2YBTC = IERC20(yBTC).balanceOf(trader2);
        uint256 btcEntryPrice = yoloOracleReal.getAssetPrice(yBTC);

        // Apply fuzzed price changes
        uint256 newETHPrice = SafeCast.toUint256(
            SafeCast.toInt256(ethEntryPrice) + (SafeCast.toInt256(ethEntryPrice) * ethPriceChangeBps) / 10000
        );
        uint256 newBTCPrice = SafeCast.toUint256(
            SafeCast.toInt256(btcEntryPrice) + (SafeCast.toInt256(btcEntryPrice) * btcPriceChangeBps) / 10000
        );

        if (newETHPrice > 0 && newETHPrice < 20000e8) {
            wethOracle.updateAnswer(SafeCast.toInt256(newETHPrice));
            yETHOracle.updateAnswer(SafeCast.toInt256(newETHPrice));
        }

        if (newBTCPrice > 0 && newBTCPrice < 300000e8) {
            wbtcOracle.updateAnswer(SafeCast.toInt256(newBTCPrice));
            yBTCOracle.updateAnswer(SafeCast.toInt256(newBTCPrice));
        }

        // Calculate expected PnL for both traders
        int256 trader1PnL =
            (SafeCast.toInt256(newETHPrice) - SafeCast.toInt256(ethEntryPrice)) * SafeCast.toInt256(trader1YETH) / 1e8;
        int256 trader2PnL =
            (SafeCast.toInt256(newBTCPrice) - SafeCast.toInt256(btcEntryPrice)) * SafeCast.toInt256(trader2YBTC) / 1e8;
        int256 totalTraderPnL = trader1PnL + trader2PnL;

        // Close both positions
        if (trader1YETH > 0) {
            vm.prank(trader1);
            _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, trader1YETH);
            vm.prank(trader1);
            yoloHook.burnPendingSynthetic();
        }

        if (trader2YBTC > 0) {
            vm.prank(trader2);
            _swapSyntheticForUSY(yBTCPoolKey, isToken0USY_BTC, trader2YBTC);
            vm.prank(trader2);
            yoloHook.burnPendingSynthetic();
        }

        uint256 ylpUSYFinal = IERC20(usy).balanceOf(address(ylp));
        int256 ylpPnL = SafeCast.toInt256(ylpUSYFinal) - SafeCast.toInt256(ylpUSYInitial);

        // INVARIANT: Zero-sum - YLP's PnL should be opposite of total trader PnL
        assertApproxEqAbs(ylpPnL, -totalTraderPnL, 300e18, "Zero-sum settlement violated");
    }

    /**
     * @notice Fuzz: Extreme price shock scenarios (-80% to +200%)
     * @dev Tests protocol resilience under catastrophic price movements
     * @param priceShockBps Price shock in basis points (-8000 to +20000)
     */
    function testFuzz_Action08_Case12_ExtremePriceShocks(int16 priceShockBps) public {
        // Constrain to extreme but not impossible ranges
        vm.assume(priceShockBps >= -8000 && priceShockBps <= 20000); // -80% to +200%

        uint256 ylpUSYBefore = IERC20(usy).balanceOf(address(ylp));

        // Open position
        uint256 tradeAmount = 40_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, tradeAmount);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 yethBalance = IERC20(yETH).balanceOf(trader1);
        if (yethBalance == 0) return;

        uint256 entryPrice = yoloOracleReal.getAssetPrice(yETH);

        // Apply extreme price shock
        uint256 shockedPrice =
            SafeCast.toUint256(SafeCast.toInt256(entryPrice) + (SafeCast.toInt256(entryPrice) * priceShockBps) / 10000);

        // Safety bounds
        if (shockedPrice > 100 && shockedPrice < 50000e8) {
            wethOracle.updateAnswer(SafeCast.toInt256(shockedPrice));
            yETHOracle.updateAnswer(SafeCast.toInt256(shockedPrice));

            // Close position
            vm.prank(trader1);
            _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, yethBalance);
            vm.prank(trader1);
            yoloHook.burnPendingSynthetic();

            uint256 ylpUSYAfter = IERC20(usy).balanceOf(address(ylp));

            // INVARIANT: NAV must never go negative even under extreme shocks
            assertGt(ylpUSYAfter, 0, "YLP balance went to zero after extreme shock");

            // Calculate expected PnL
            int256 expectedPnL = (SafeCast.toInt256(shockedPrice) - SafeCast.toInt256(entryPrice))
                * SafeCast.toInt256(yethBalance) / 1e8;
            int256 actualYLPChange = SafeCast.toInt256(ylpUSYAfter) - SafeCast.toInt256(ylpUSYBefore);

            // Verify settlement occurred correctly
            assertApproxEqAbs(actualYLPChange, -expectedPnL, 300e18, "Extreme shock settlement mismatch");
        }
    }

    /**
     * @notice Fuzz: Alternating profit/loss sequence on same position
     * @dev Opens position, makes profit, adds more, makes loss, verifies cost basis tracking
     * @param seed Random seed for price movements
     */
    function testFuzz_Action08_Case13_AlternatingPnLSequence(uint256 seed) public {
        uint256 ylpUSYInitial = IERC20(usy).balanceOf(address(ylp));

        // First trade: Open position
        uint256 firstTrade = 20_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, firstTrade);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 balance1 = IERC20(yETH).balanceOf(trader1);
        if (balance1 == 0) return;
        uint256 price1 = yoloOracleReal.getAssetPrice(yETH);

        // Price moves up (profit zone)
        uint256 price2 = price1 + (price1 * (uint256(keccak256(abi.encode(seed, "up"))) % 2000)) / 10000; // +0-20%
        wethOracle.updateAnswer(SafeCast.toInt256(price2));
        yETHOracle.updateAnswer(SafeCast.toInt256(price2));

        // Add to position at higher price
        uint256 secondTrade = 15_000e18;
        vm.prank(trader1);
        _swapUSYForSynthetic(yETHPoolKey, isToken0USY_ETH, secondTrade);
        vm.prank(trader1);
        yoloHook.burnPendingSynthetic();

        uint256 balance2 = IERC20(yETH).balanceOf(trader1);
        YoloSyntheticAsset yethToken = YoloSyntheticAsset(yETH);
        uint128 avgCost2 = yethToken.avgPriceX8(trader1);

        // Weighted average cost should be between price1 and price2
        assertGe(avgCost2, SafeCast.toUint128(price1), "Avg cost below first entry");
        assertLe(avgCost2, SafeCast.toUint128(price2), "Avg cost above second entry");

        // Price crashes (loss zone)
        uint256 price3 = price1 - (price1 * (uint256(keccak256(abi.encode(seed, "down"))) % 3000)) / 10000; // -0-30%
        if (price3 > 100) {
            wethOracle.updateAnswer(SafeCast.toInt256(price3));
            yETHOracle.updateAnswer(SafeCast.toInt256(price3));

            // Close entire position at loss
            vm.prank(trader1);
            _swapSyntheticForUSY(yETHPoolKey, isToken0USY_ETH, balance2);
            vm.prank(trader1);
            yoloHook.burnPendingSynthetic();

            uint256 ylpUSYFinal = IERC20(usy).balanceOf(address(ylp));
            int256 actualYLPChange = SafeCast.toInt256(ylpUSYFinal) - SafeCast.toInt256(ylpUSYInitial);

            // Calculate expected PnL based on weighted average cost
            int256 expectedPnL =
                (SafeCast.toInt256(price3) - SafeCast.toInt256(uint256(avgCost2))) * SafeCast.toInt256(balance2) / 1e8;

            // Verify YLP captured the opposite of trader's PnL
            assertApproxEqAbs(actualYLPChange, -expectedPnL, 200e18, "Alternating PnL settlement mismatch");
        }
    }

    // ============================================================
    // HELPER FUNCTIONS
    // ============================================================

    function _swapUSYForSynthetic(PoolKey memory poolKey, bool isUSYToken0, uint256 amountIn)
        internal
        returns (BalanceDelta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: isUSYToken0,
            amountSpecified: -SafeCast.toInt256(amountIn),
            sqrtPriceLimitX96: isUSYToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        return swapRouter.swap(poolKey, params, settings, "");
    }

    function _swapSyntheticForUSY(PoolKey memory poolKey, bool isUSYToken0, uint256 amountIn)
        internal
        returns (BalanceDelta)
    {
        SwapParams memory params = SwapParams({
            zeroForOne: !isUSYToken0,
            amountSpecified: -SafeCast.toInt256(amountIn),
            sqrtPriceLimitX96: !isUSYToken0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        return swapRouter.swap(poolKey, params, settings, "");
    }

    function _getSyntheticPoolKey(address syntheticAsset) internal view returns (PoolKey memory) {
        address token0 = usy < syntheticAsset ? usy : syntheticAsset;
        address token1 = usy < syntheticAsset ? syntheticAsset : usy;

        return PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: 1,
            hooks: IHooks(address(yoloHook))
        });
    }
}
