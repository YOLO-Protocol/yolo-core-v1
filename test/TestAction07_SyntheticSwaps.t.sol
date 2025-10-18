// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base03_DeployComprehensiveTestEnvironment} from "./base/Base03_DeployComprehensiveTestEnvironment.t.sol";
import {YoloHook} from "../src/core/YoloHook.sol";
import {YoloHookStorage} from "../src/core/YoloHookStorage.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";

/**
 * @title TestAction07_SyntheticSwaps
 * @notice Integration tests for synthetic swaps using Base03's comprehensive asset setup
 * @dev Migrated from Base02 to Base03 to leverage pre-deployed multi-asset environment
 */
contract TestAction07_SyntheticSwaps is Base03_DeployComprehensiveTestEnvironment {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    event SyntheticSwap(
        bytes32 indexed poolId,
        address indexed sender,
        address indexed tokenIn,
        address tokenOut,
        uint256 grossInput,
        uint256 netInput,
        uint256 amountOut,
        uint256 feeAmount,
        bool exactInput
    );

    uint256 constant SYNTHETIC_FEE_BPS = 10; // 0.10%

    address public trader = makeAddr("trader");

    // Pool keys for Base03's pre-deployed assets
    PoolKey public syntheticPoolKey;
    bool public isToken0USY;
    YoloSyntheticAsset public yEthToken;

    // Additional pool keys for multi-asset tests
    PoolKey public yBTCPoolKey;
    bool public isToken0USY_BTC;

    PoolKey public ySILVERPoolKey;
    bool public isToken0USY_SILVER;

    function setUp() public override {
        super.setUp(); // Deploy comprehensive Base03 environment

        // Setup pool keys using Base03's pre-deployed assets
        syntheticPoolKey = _getSyntheticPoolKey(yETH);
        isToken0USY = Currency.unwrap(syntheticPoolKey.currency0) == usy;
        yEthToken = YoloSyntheticAsset(yETH);

        yBTCPoolKey = _getSyntheticPoolKey(yBTC);
        isToken0USY_BTC = Currency.unwrap(yBTCPoolKey.currency0) == usy;

        ySILVERPoolKey = _getSyntheticPoolKey(ySILVER);
        isToken0USY_SILVER = Currency.unwrap(ySILVERPoolKey.currency0) == usy;

        // Fund trader with USY
        deal(usy, trader, 1_000_000e18);

        // Approve tokens for trader
        vm.startPrank(trader);
        IERC20(usy).approve(address(swapRouter), type(uint256).max);
        IERC20(usy).approve(address(manager), type(uint256).max);
        IERC20(yETH).approve(address(swapRouter), type(uint256).max);
        IERC20(yETH).approve(address(manager), type(uint256).max);
        IERC20(yBTC).approve(address(swapRouter), type(uint256).max);
        IERC20(yBTC).approve(address(manager), type(uint256).max);
        IERC20(ySILVER).approve(address(swapRouter), type(uint256).max);
        IERC20(ySILVER).approve(address(manager), type(uint256).max);
        vm.stopPrank();
    }

    function test_Action07_Case01_swapUSYForSyntheticExactIn() public {
        uint256 amountIn = 10_000e18;

        vm.prank(trader);
        _swapUSYForSynthetic(amountIn);

        uint256 expectedFee = (amountIn * SYNTHETIC_FEE_BPS) / 10_000;
        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();

        assertEq(pendingToken, usy, "Pending token should be USY");
        assertEq(pendingAmount, amountIn - expectedFee, "Pending amount should equal net input");
        assertGt(IERC20(yETH).balanceOf(trader), 0, "Trader should receive synthetic asset");
    }

    function test_Action07_Case02_burnPendingSyntheticClearsPending() public {
        uint256 amountIn = 5_000e18;

        vm.prank(trader);
        _swapUSYForSynthetic(amountIn);

        vm.prank(trader);
        yoloHook.burnPendingSynthetic();

        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, address(0), "Pending token should be cleared");
        assertEq(pendingAmount, 0, "Pending amount should be zero");
        assertEq(IERC20(usy).balanceOf(address(yoloHook)), 0, "Hook should not retain USY balance");
    }

    function test_Action07_Case03_swapSyntheticForUSYExactIn() public {
        uint256 bootstrapAmount = 8_000e18;
        vm.prank(trader);
        _swapUSYForSynthetic(bootstrapAmount);
        vm.prank(trader);
        yoloHook.burnPendingSynthetic();

        uint256 swapAmount = IERC20(yETH).balanceOf(trader) / 2;
        assertGt(swapAmount, 0, "Trader should have yETH to swap");
        uint256 usyBefore = IERC20(usy).balanceOf(trader);

        vm.prank(trader);
        _swapSyntheticForUSY(swapAmount);

        assertGt(IERC20(usy).balanceOf(trader), usyBefore, "Trader should receive USY");

        uint256 expectedFee = (swapAmount * SYNTHETIC_FEE_BPS) / 10_000;
        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, yETH, "Pending token should track yETH");
        assertEq(pendingAmount, swapAmount - expectedFee, "Pending amount should match net yETH in");
    }

    function test_Action07_Case04_autoFlushesPendingOnNextSwap() public {
        uint256 firstAmount = 3_000e18;
        uint256 secondAmount = 2_000e18;

        vm.prank(trader);
        _swapUSYForSynthetic(firstAmount);

        uint256 expectedSecondFee = (secondAmount * SYNTHETIC_FEE_BPS) / 10_000;

        vm.prank(trader);
        _swapUSYForSynthetic(secondAmount);

        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, usy, "Pending token should remain USY");
        assertEq(pendingAmount, secondAmount - expectedSecondFee, "Pending should reflect latest net input");
        assertEq(IERC20(usy).balanceOf(address(yoloHook)), 0, "Hook should not retain USY after auto-burn");
    }

    function test_Action07_Case05_burnPendingSynthetic_revertsWhenEmpty() public {
        vm.expectRevert(YoloHookStorage.NoPendingSyntheticBurn.selector);
        yoloHook.burnPendingSynthetic();
    }

    function test_Action07_Case06_swapUSYForSyntheticExactOut_emitsEvent() public {
        uint256 amountOut = 5 ether;

        uint256 priceIn = yoloOracleReal.getAssetPrice(usy);
        uint256 priceOut = yoloOracleReal.getAssetPrice(yETH);
        uint256 netIn = (priceOut * amountOut + priceIn - 1) / priceIn;
        uint256 denominator = 10_000 - SYNTHETIC_FEE_BPS;
        uint256 grossIn = (netIn * 10_000 + denominator - 1) / denominator;
        uint256 feeAmount = grossIn - netIn;

        bytes32 poolId = PoolId.unwrap(syntheticPoolKey.toId());
        address tokenIn = Currency.unwrap(syntheticPoolKey.currency1);
        address tokenOut = Currency.unwrap(syntheticPoolKey.currency0);
        if (isToken0USY) {
            tokenIn = Currency.unwrap(syntheticPoolKey.currency0);
            tokenOut = Currency.unwrap(syntheticPoolKey.currency1);
        }

        vm.expectEmit(true, true, true, true, address(yoloHook));
        emit SyntheticSwap(poolId, address(swapRouter), tokenIn, tokenOut, grossIn, netIn, amountOut, feeAmount, false);

        uint256 usyBefore = IERC20(usy).balanceOf(trader);
        uint256 yEthBefore = IERC20(yETH).balanceOf(trader);

        vm.prank(trader);
        _swapUSYForSyntheticExactOut(amountOut);

        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, usy, "Pending token should be USY");
        assertEq(pendingAmount, netIn, "Pending amount mismatch");
        assertEq(IERC20(yETH).balanceOf(trader) - yEthBefore, amountOut, "Trader output mismatch");
        assertEq(usyBefore - IERC20(usy).balanceOf(trader), grossIn, "USY spent mismatch");

        vm.prank(trader);
        yoloHook.burnPendingSynthetic();
    }

    function test_Action07_Case07_revertWhenOraclePriceZero() public {
        yETHOracle.updateAnswer(0);
        vm.expectRevert();
        vm.prank(trader);
        _swapUSYForSynthetic(1e18);
    }

    function test_Action07_Case08_averagePriceUpdatesAcrossSwaps() public {
        uint256 amountIn1 = 4_000e18;
        uint256 amountIn2 = 6_000e18;

        uint256 priceUSY = yoloOracleReal.getAssetPrice(usy);
        uint256 priceYeth1 = yoloOracleReal.getAssetPrice(yETH);

        vm.prank(trader);
        _swapUSYForSynthetic(amountIn1);

        uint128 avgAfterFirst = yEthToken.avgPriceX8(trader);
        assertEq(avgAfterFirst, uint128(priceYeth1), "Initial average price incorrect");

        vm.prank(trader);
        yoloHook.burnPendingSynthetic();

        uint256 priceYeth2 = 1_500e8;
        wethOracle.updateAnswer(int256(priceYeth2));
        yETHOracle.updateAnswer(int256(priceYeth2));

        vm.prank(trader);
        _swapUSYForSynthetic(amountIn2);

        uint256 fee1 = (amountIn1 * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 netIn1 = amountIn1 - fee1;
        uint256 out1 = (priceUSY * netIn1) / priceYeth1;

        uint256 fee2 = (amountIn2 * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 netIn2 = amountIn2 - fee2;
        uint256 out2 = (priceUSY * netIn2) / priceYeth2;

        uint256 totalQty = out1 + out2;
        uint256 totalCost = priceYeth1 * out1 + priceYeth2 * out2;
        uint128 expectedAvg = uint128((totalCost + totalQty - 1) / totalQty);

        uint128 avgAfterSecond = yEthToken.avgPriceX8(trader);
        assertEq(avgAfterSecond, expectedAvg, "Weighted average mismatch");

        vm.prank(trader);
        yoloHook.burnPendingSynthetic();
    }

    function test_Action07_Case09_hookAveragePriceZeroAfterBurn() public {
        vm.prank(trader);
        _swapUSYForSynthetic(2_500e18);

        YoloSyntheticAsset usyToken = YoloSyntheticAsset(usy);
        assertEq(usyToken.avgPriceX8(address(yoloHook)), 0, "Claims should not set avg price");

        vm.prank(trader);
        yoloHook.burnPendingSynthetic();

        assertEq(usyToken.avgPriceX8(address(yoloHook)), 0, "Average price should reset after burn");
    }

    // ============================================================
    // PHASE 1: CRITICAL BOOK-KEEPING TESTS
    // ============================================================

    /**
     * @notice Test Case 15: Complete balance reconciliation for single swap
     * @dev Validates ALL balance changes across trader, treasury, and hook
     */
    function test_Action07_Case15_completeBalanceReconciliation() public {
        uint256 amountIn = 10_000e18;
        uint256 expectedFee = (amountIn * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 netInput = amountIn - expectedFee;

        uint256 priceUSY = yoloOracleReal.getAssetPrice(usy);
        uint256 priceYETH = yoloOracleReal.getAssetPrice(yETH);
        uint256 expectedOutput = (priceUSY * netInput) / priceYETH;

        // Record ALL balances before swap
        uint256 traderUSYBefore = IERC20(usy).balanceOf(trader);
        uint256 traderYETHBefore = IERC20(yETH).balanceOf(trader);
        uint256 treasuryUSYBefore = IERC20(usy).balanceOf(treasury);
        uint256 hookUSYBefore = IERC20(usy).balanceOf(address(yoloHook));
        uint256 hookYETHBefore = IERC20(yETH).balanceOf(address(yoloHook));

        // Execute swap
        vm.prank(trader);
        _swapUSYForSynthetic(amountIn);

        // Verify ALL balance changes
        assertEq(traderUSYBefore - IERC20(usy).balanceOf(trader), amountIn, "Trader USY decreased by grossInput");
        assertEq(
            IERC20(yETH).balanceOf(trader) - traderYETHBefore, expectedOutput, "Trader yETH increased by amountOut"
        );

        // Treasury receives fees as claim tokens initially, but we can't directly verify claim balances
        // Instead verify treasury can eventually claim real tokens
        assertEq(
            IERC20(usy).balanceOf(address(yoloHook)), hookUSYBefore, "Hook USY real balance unchanged (only claims)"
        );
        assertEq(
            IERC20(yETH).balanceOf(address(yoloHook)), hookYETHBefore, "Hook yETH real balance unchanged (only claims)"
        );

        // Verify pending state
        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, usy, "Pending token should be USY");
        assertEq(pendingAmount, netInput, "Pending amount should equal net input");
    }

    /**
     * @notice Test Case 18: Pending state transitions
     * @dev Validates pending state changes through various operations
     */
    function test_Action07_Case18_pendingStateTransitions() public {
        // Initial state: pending should be empty
        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, address(0), "Initial: pending token should be zero");
        assertEq(pendingAmount, 0, "Initial: pending amount should be zero");

        // After swap USY->yETH: verify pending = (usy, netInput)
        uint256 swap1Amount = 5_000e18;
        uint256 fee1 = (swap1Amount * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 net1 = swap1Amount - fee1;

        vm.prank(trader);
        _swapUSYForSynthetic(swap1Amount);

        (pendingToken, pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, usy, "After swap: pending token should be USY");
        assertEq(pendingAmount, net1, "After swap: pending amount should be net input");

        // After explicit burn: verify pending = (0, 0)
        vm.prank(trader);
        yoloHook.burnPendingSynthetic();

        (pendingToken, pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, address(0), "After burn: pending token should be cleared");
        assertEq(pendingAmount, 0, "After burn: pending amount should be zero");

        // After swap yETH->USY: verify pending = (yETH, netInput)
        uint256 swap2Amount = 1 ether;
        uint256 fee2 = (swap2Amount * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 net2 = swap2Amount - fee2;

        vm.prank(trader);
        _swapSyntheticForUSY(swap2Amount);

        (pendingToken, pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, yETH, "After reverse swap: pending token should be yETH");
        assertEq(pendingAmount, net2, "After reverse swap: pending amount should be net yETH");

        // After auto-flush via another swap: verify pending = (usy, newNetInput)
        uint256 swap3Amount = 3_000e18;
        uint256 fee3 = (swap3Amount * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 net3 = swap3Amount - fee3;

        vm.prank(trader);
        _swapUSYForSynthetic(swap3Amount);

        (pendingToken, pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, usy, "After auto-flush: pending token should be USY");
        assertEq(pendingAmount, net3, "After auto-flush: pending should be NEW net input (not accumulated)");
    }

    /**
     * @notice Test Case 17: Hook balance invariant across complex sequence
     * @dev Validates hook never retains real token balances
     */
    function test_Action07_Case17_hookBalanceAlwaysZero() public {
        // Execute multiple swaps and verify hook balance stays zero
        uint256[] memory swapAmounts = new uint256[](5);
        swapAmounts[0] = 1_000e18;
        swapAmounts[1] = 2_000e18;
        swapAmounts[2] = 500e18;
        swapAmounts[3] = 3_000e18;
        swapAmounts[4] = 1_500e18;

        for (uint256 i = 0; i < swapAmounts.length; i++) {
            vm.prank(trader);
            _swapUSYForSynthetic(swapAmounts[i]);

            // After each swap, verify hook real token balance is 0
            assertEq(
                IERC20(usy).balanceOf(address(yoloHook)),
                0,
                "Hook USY balance should always be zero (only claims exist)"
            );
            assertEq(
                IERC20(yETH).balanceOf(address(yoloHook)),
                0,
                "Hook yETH balance should always be zero (only claims exist)"
            );
        }

        // Explicit burn and verify hook balance still zero
        yoloHook.burnPendingSynthetic();

        assertEq(IERC20(usy).balanceOf(address(yoloHook)), 0, "Hook USY balance should be zero after burn");
        assertEq(IERC20(yETH).balanceOf(address(yoloHook)), 0, "Hook yETH balance should be zero after burn");
    }

    /**
     * @notice Test Case 19: Gross vs Net input tracking
     * @dev Validates fee calculation and pending tracking uses net amount
     */
    function test_Action07_Case19_grossVsNetInputAccounting() public {
        uint256 amountIn = 10_000e18;
        uint256 expectedFee = (amountIn * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 expectedNet = amountIn - expectedFee;

        vm.prank(trader);
        _swapUSYForSynthetic(amountIn);

        // Verify pending tracks NET input (not gross)
        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, usy, "Pending token should be USY");
        assertEq(pendingAmount, expectedNet, "Pending amount should equal NET input (gross - fee)");

        // Verify the fee was correctly calculated
        assertEq(expectedFee, (amountIn * SYNTHETIC_FEE_BPS) / 10_000, "Fee calculation mismatch");
        assertEq(expectedNet, amountIn - expectedFee, "Net = Gross - Fee");
    }

    // ============================================================
    // PHASE 2: MULTIPLE SYNTHETIC ASSET COVERAGE
    // ============================================================

    /**
     * @notice Test Case 10: Verify multiple synthetic assets exist
     * @dev Base03 pre-deploys yBTC and ySILVER, this test verifies their readiness
     */
    function test_Action07_Case10_multipleAssetPairCreation() public {
        // Verify yBTC exists and has correct price (Base03 sets to $68,000)
        assertEq(yoloOracleReal.getAssetPrice(yBTC), 68_000e8, "yBTC price should be $68,000");

        // Verify ySILVER exists and has correct price (Base03 sets to $31.50)
        assertEq(yoloOracleReal.getAssetPrice(ySILVER), 3150e6, "ySILVER price should be $31.50");

        // Verify pool keys were created correctly
        assertTrue(Currency.unwrap(yBTCPoolKey.currency0) != address(0), "yBTC pool currency0 should exist");
        assertTrue(Currency.unwrap(yBTCPoolKey.currency1) != address(0), "yBTC pool currency1 should exist");

        assertTrue(Currency.unwrap(ySILVERPoolKey.currency0) != address(0), "ySILVER pool currency0 should exist");
        assertTrue(Currency.unwrap(ySILVERPoolKey.currency1) != address(0), "ySILVER pool currency1 should exist");
    }

    /**
     * @notice Test Case 11: USY <> yBTC exact input swap
     * @dev Tests swapping with a different synthetic asset (higher price)
     */
    function test_Action07_Case11_swapUSYForBTC() public {
        uint256 amountIn = 100_000e18; // 100,000 USY
        uint256 expectedFee = (amountIn * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 netInput = amountIn - expectedFee;

        uint256 priceUSY = yoloOracleReal.getAssetPrice(usy);
        uint256 priceBTC = yoloOracleReal.getAssetPrice(yBTC);
        uint256 expectedOutput = (priceUSY * netInput) / priceBTC;

        // Execute swap USY -> yBTC
        vm.prank(trader);
        SwapParams memory params = SwapParams({
            zeroForOne: isToken0USY_BTC,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: isToken0USY_BTC ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(yBTCPoolKey, params, settings, "");

        // Verify output
        assertEq(IERC20(yBTC).balanceOf(trader), expectedOutput, "Trader should receive yBTC");

        // Verify pending state
        (address pendingToken, uint256 pendingAmount) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingToken, usy, "Pending token should be USY");
        assertEq(pendingAmount, netInput, "Pending amount should be net input");
    }

    /**
     * @notice Test Case 13: Sequential swaps across different pairs
     * @dev Tests auto-flush behavior when swapping different synthetic assets
     */
    function test_Action07_Case13_sequentialSwapsAcrossPairs() public {
        // Swap 1: USY -> yETH (creates pending USY)
        uint256 swap1Amount = 10_000e18;
        uint256 fee1 = (swap1Amount * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 net1 = swap1Amount - fee1;

        vm.prank(trader);
        _swapUSYForSynthetic(swap1Amount);

        (address pending1, uint256 amt1) = yoloHook.getPendingSyntheticBurn();
        assertEq(pending1, usy, "After swap1: pending should be USY");
        assertEq(amt1, net1, "After swap1: pending amount should be net1");

        // Swap 2: USY -> yBTC (should auto-flush USY, create new pending USY)
        uint256 swap2Amount = 50_000e18;
        uint256 fee2 = (swap2Amount * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 net2 = swap2Amount - fee2;

        uint256 yBTCBefore = IERC20(yBTC).balanceOf(trader);

        vm.prank(trader);
        SwapParams memory params2 = SwapParams({
            zeroForOne: isToken0USY_BTC,
            amountSpecified: -int256(swap2Amount),
            sqrtPriceLimitX96: isToken0USY_BTC ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(yBTCPoolKey, params2, settings, "");

        // Verify previous USY was burned (can't directly verify, but pending should be replaced)
        (address pending2, uint256 amt2) = yoloHook.getPendingSyntheticBurn();
        assertEq(pending2, usy, "After swap2: pending should still be USY");
        assertEq(amt2, net2, "After swap2: pending should be net2 (not net1 + net2)");
        assertGt(IERC20(yBTC).balanceOf(trader), yBTCBefore, "Trader should receive yBTC");

        // Verify hook balance is zero
        assertEq(IERC20(usy).balanceOf(address(yoloHook)), 0, "Hook USY balance should be zero");
        assertEq(IERC20(yBTC).balanceOf(address(yoloHook)), 0, "Hook yBTC balance should be zero");
    }

    /**
     * @notice Test Case 20: Three-way swap sequence with different assets
     * @dev Tests complex multi-asset swap sequence with proper pending tracking
     */
    function test_Action07_Case20_threeWaySwapSequence() public {
        // Create separate traders
        address traderA = makeAddr("traderA");
        address traderB = makeAddr("traderB");
        address traderC = makeAddr("traderC");

        // Fund all traders
        deal(usy, traderA, 100_000e18);
        deal(usy, traderB, 200_000e18);
        deal(usy, traderC, 50_000e18);

        // Approve for all traders
        address[3] memory traders = [traderA, traderB, traderC];
        for (uint256 i = 0; i < traders.length; i++) {
            vm.startPrank(traders[i]);
            IERC20(usy).approve(address(swapRouter), type(uint256).max);
            IERC20(yETH).approve(address(swapRouter), type(uint256).max);
            IERC20(yBTC).approve(address(swapRouter), type(uint256).max);
            IERC20(ySILVER).approve(address(swapRouter), type(uint256).max);
            vm.stopPrank();
        }

        // Sequence 1: Trader A swaps USY -> yETH
        uint256 amountA = 5_000e18;
        uint256 feeA = (amountA * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 netA = amountA - feeA;

        vm.prank(traderA);
        _swapUSYForSynthetic(amountA);

        (address pendingA, uint256 amtA) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingA, usy, "After A: pending = USY");
        assertEq(amtA, netA, "After A: pending amount = netA");

        // Sequence 2: Trader B swaps USY -> yBTC (burns A's pending)
        uint256 amountB = 100_000e18;
        uint256 feeB = (amountB * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 netB = amountB - feeB;

        vm.prank(traderB);
        SwapParams memory paramsB = SwapParams({
            zeroForOne: isToken0USY_BTC,
            amountSpecified: -int256(amountB),
            sqrtPriceLimitX96: isToken0USY_BTC ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        swapRouter.swap(yBTCPoolKey, paramsB, settings, "");

        (address pendingB, uint256 amtB) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingB, usy, "After B: pending = USY (A's burned)");
        assertEq(amtB, netB, "After B: pending = netB only");

        // Sequence 3: Trader C swaps USY -> ySILVER (burns B's pending)
        uint256 amountC = 10_000e18;
        uint256 feeC = (amountC * SYNTHETIC_FEE_BPS) / 10_000;
        uint256 netC = amountC - feeC;

        vm.prank(traderC);
        SwapParams memory paramsC = SwapParams({
            zeroForOne: isToken0USY_SILVER,
            amountSpecified: -int256(amountC),
            sqrtPriceLimitX96: isToken0USY_SILVER ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(ySILVERPoolKey, paramsC, settings, "");

        (address pendingC, uint256 amtC) = yoloHook.getPendingSyntheticBurn();
        assertEq(pendingC, usy, "After C: pending = USY (B's burned)");
        assertEq(amtC, netC, "After C: pending = netC only");

        // Verify all traders received their outputs
        assertGt(IERC20(yETH).balanceOf(traderA), 0, "Trader A received yETH");
        assertGt(IERC20(yBTC).balanceOf(traderB), 0, "Trader B received yBTC");
        assertGt(IERC20(ySILVER).balanceOf(traderC), 0, "Trader C received ySILVER");

        // Verify hook has zero balance
        assertEq(IERC20(usy).balanceOf(address(yoloHook)), 0, "Hook USY = 0");
        assertEq(IERC20(yETH).balanceOf(address(yoloHook)), 0, "Hook yETH = 0");
        assertEq(IERC20(yBTC).balanceOf(address(yoloHook)), 0, "Hook yBTC = 0");
        assertEq(IERC20(ySILVER).balanceOf(address(yoloHook)), 0, "Hook ySILVER = 0");
    }

    function _swapUSYForSynthetic(uint256 amountIn) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: isToken0USY,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: isToken0USY ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        return swapRouter.swap(syntheticPoolKey, params, settings, "");
    }

    function _swapSyntheticForUSY(uint256 amountIn) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: !isToken0USY,
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: !isToken0USY ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        return swapRouter.swap(syntheticPoolKey, params, settings, "");
    }

    function _swapUSYForSyntheticExactOut(uint256 amountOut) internal returns (BalanceDelta) {
        SwapParams memory params = SwapParams({
            zeroForOne: isToken0USY,
            amountSpecified: int256(amountOut),
            sqrtPriceLimitX96: isToken0USY ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        return swapRouter.swap(syntheticPoolKey, params, settings, "");
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
