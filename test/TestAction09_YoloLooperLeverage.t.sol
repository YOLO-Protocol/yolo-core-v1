// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base03_DeployComprehensiveTestEnvironment} from "./base/Base03_DeployComprehensiveTestEnvironment.t.sol";
import {YoloLooper} from "../src/looper/YoloLooper.sol";
import {MockRouter} from "../src/mocks/MockRouter.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/**
 * @title TestAction09_YoloLooperLeverage
 * @notice Comprehensive end-to-end tests for YoloLooper leverage/deleverage functionality
 * @dev Tests leverage loops, slippage protection, access control, and full lifecycle
 *
 *      Test Architecture:
 *      - Extends Base03 for full synthetic/collateral environment
 *      - Deploys two IRouter adapters: external (collateral↔USDC) and internal (synthetic↔USY)
 *      - Validates leverage calculations match looper's internal math
 *      - Covers happy path, partial/full deleverage, slippage, and authorization
 */
contract TestAction09_YoloLooperLeverage is Base03_DeployComprehensiveTestEnvironment {
    // ============================================================
    // CONTRACTS
    // ============================================================

    YoloLooper public looper;
    MockRouter public externalRouter; // Handles collateral ↔ USDC (Kyber/1inch simulation)
    MockRouter public yoloRouter; // Handles synthetic ↔ USY ↔ USDC (internal routing)

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 constant PRECISION_DIVISOR = 10_000; // Basis points
    uint256 constant RAY = 1e27;

    // Test accounts
    address public borrower1 = makeAddr("borrower1");
    address public borrower2 = makeAddr("borrower2");

    // ============================================================
    // EVENTS
    // ============================================================

    event LeverageExecuted(
        address indexed user,
        address indexed collateral,
        address indexed synthetic,
        uint256 initialCollateral,
        uint256 flashLoanAmount,
        uint256 totalCollateral,
        uint256 totalDebt
    );

    event DeleverageExecuted(
        address indexed user,
        address indexed collateral,
        address indexed synthetic,
        uint256 repayAmount,
        uint256 collateralFreed,
        uint256 remainingDebt,
        uint256 remainingCollateral
    );

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public override {
        super.setUp();

        // Deploy external router (collateral ↔ USDC)
        externalRouter = new MockRouter(address(yoloOracleReal), address(usdc));

        // Deploy YOLO router (synthetic ↔ USY ↔ USDC)
        yoloRouter = new MockRouter(address(yoloOracleReal), address(usdc));

        // Reconstruct anchor pool key
        PoolKey memory anchorPoolKey = PoolKey({
            currency0: Currency.wrap(address(usdc) < address(usy) ? address(usdc) : address(usy)),
            currency1: Currency.wrap(address(usdc) > address(usy) ? address(usdc) : address(usy)),
            fee: 0, // No fee in V4 pool
            tickSpacing: 60,
            hooks: IHooks(address(yoloHook))
        });

        // Deploy YoloLooper
        looper = new YoloLooper(
            address(yoloHook),
            address(yoloOracleReal),
            address(externalRouter),
            address(yoloRouter),
            address(usdc),
            address(usy),
            anchorPoolKey
        );

        // Create and grant looper necessary roles
        bytes32 LOOPER_ROLE = yoloHook.LOOPER_ROLE();
        bytes32 PRIVILEGED_FLASHLOANER_ROLE = yoloHook.PRIVILEGED_FLASHLOANER_ROLE();

        // Create roles if they don't exist
        aclManager.createRole("LOOPER", bytes32(0));
        aclManager.createRole("PRIVILEGED_FLASHLOANER", bytes32(0));

        // Grant roles to looper
        aclManager.grantRole(LOOPER_ROLE, address(looper));
        aclManager.grantRole(PRIVILEGED_FLASHLOANER_ROLE, address(looper));

        // Fund routers with necessary tokens
        _fundRouters();
    }

    // ============================================================
    // HELPER FUNCTIONS
    // ============================================================

    /**
     * @notice Fund routers with tokens for swaps
     */
    function _fundRouters() internal {
        // Fund external router with USDC and collateral tokens
        deal(address(usdc), address(externalRouter), 10_000_000e6); // 10M USDC
        deal(address(ptUsde), address(externalRouter), 10_000_000e18); // 10M PT-USDe
        deal(address(sUsde), address(externalRouter), 10_000_000e18); // 10M sUSDe

        // Fund YOLO router with USDC and synthetics
        deal(address(usdc), address(yoloRouter), 10_000_000e6); // 10M USDC
        deal(address(usy), address(yoloRouter), 10_000_000e18); // 10M USY

        // Mint synthetics to YOLO router (using yoloHook as minter)
        vm.startPrank(address(yoloHook));
        YoloSyntheticAsset(yNVDA).mint(address(yoloRouter), 10_000e18); // 10k yNVDA
        YoloSyntheticAsset(yETH).mint(address(yoloRouter), 10_000e18); // 10k yETH
        vm.stopPrank();
    }

    /**
     * @notice Calculate flash loan amount for leverage (mirrors looper's internal calculation)
     * @param collateral Collateral asset address
     * @param synthetic Synthetic asset address
     * @param collateralAmount Initial collateral amount
     * @param targetLeverage Target leverage ratio (18 decimals: 2x = 2e18, 3x = 3e18, etc.)
     * @return flashLoanAmount Amount to flash loan
     */
    function _calculateFlashLoanAmount(
        address collateral,
        address synthetic,
        uint256 collateralAmount,
        uint256 targetLeverage
    ) internal view returns (uint256) {
        // Get oracle prices (8 decimals)
        uint256 collateralPrice = yoloOracleReal.getAssetPrice(collateral);
        uint256 syntheticPrice = yoloOracleReal.getAssetPrice(synthetic);

        // Get decimals
        uint8 collateralDecimals = IERC20Metadata(collateral).decimals();
        uint8 syntheticDecimals = IERC20Metadata(synthetic).decimals();

        // Calculate collateral value in USD (8 decimals)
        uint256 collateralValueUSD = (collateralAmount * collateralPrice) / (10 ** collateralDecimals);

        // Calculate target synthetic amount using 18-decimal leverage
        // targetLeverage is 18 decimals (e.g., 3e18 = 3x)
        // Formula: flashLoan = collateralValue * (targetLeverage - 1e18) / 1e18
        uint256 targetSyntheticValueUSD = (collateralValueUSD * (targetLeverage - 1e18)) / 1e18;

        // Convert to synthetic amount
        uint256 flashLoanAmount = (targetSyntheticValueUSD * (10 ** syntheticDecimals)) / syntheticPrice;

        return flashLoanAmount;
    }

    /**
     * @notice Calculate expected collateral delta from leverage
     * @param synthetic Synthetic asset address
     * @param collateral Collateral asset address
     * @param flashLoanAmount Amount of synthetic being flash loaned
     * @return expectedDelta Expected additional collateral from swaps
     */
    function _calculateExpectedCollateralDelta(address synthetic, address collateral, uint256 flashLoanAmount)
        internal
        view
        returns (uint256)
    {
        // Simulate the swap path: synthetic → USDC → collateral

        // Step 1: synthetic → USDC (via YOLO router)
        uint256 syntheticPrice = yoloOracleReal.getAssetPrice(synthetic);
        uint8 syntheticDecimals = IERC20Metadata(synthetic).decimals();
        uint256 syntheticValueUSD = (flashLoanAmount * syntheticPrice) / (10 ** syntheticDecimals);
        uint256 usdcFromSynthetic = (syntheticValueUSD * 1e6) / 1e8; // USDC has 6 decimals

        // Step 2: USDC → collateral (via external router)
        uint256 collateralPrice = yoloOracleReal.getAssetPrice(collateral);
        uint8 collateralDecimals = IERC20Metadata(collateral).decimals();
        uint256 usdcValueUSD = (usdcFromSynthetic * 1e8) / 1e6;
        uint256 collateralOut = (usdcValueUSD * (10 ** collateralDecimals)) / collateralPrice;

        return collateralOut;
    }

    /**
     * @notice Calculate collateral to withdraw when deleveraging
     */
    function _calculateFreedCollateral(
        address collateral,
        address synthetic,
        uint256 repayAmount,
        uint256 currentCollateral,
        uint256 currentDebt
    ) internal view returns (uint256) {
        if (repayAmount == 0 || repayAmount >= currentDebt) {
            // Full repayment - return all collateral
            return currentCollateral;
        }

        // Partial repayment - proportional reduction
        uint256 freedCollateral = (currentCollateral * repayAmount) / currentDebt;

        // Apply safety margin (keep extra 5% collateral)
        uint256 safetyMargin = (freedCollateral * 500) / PRECISION_DIVISOR; // 5%
        return freedCollateral > safetyMargin ? freedCollateral - safetyMargin : 0;
    }

    // ============================================================
    // TEST CASES
    // ============================================================

    /**
     * @notice Test Case 1: Happy-path leverage with exotic collateral
     */
    function test_Action09_Case01_leverageHappyPath() public {
        // Setup: Use PT-USDe (exotic) as collateral, yNVDA as synthetic
        uint256 initialCollateral = 10_000e18; // 10k PT-USDe
        uint256 targetLeverage = 3e18; // 3x leverage (18 decimals)

        // Fund borrower1 with collateral
        deal(address(ptUsde), borrower1, initialCollateral);

        // Calculate expected flash loan amount
        uint256 expectedFlashLoan = _calculateFlashLoanAmount(address(ptUsde), yNVDA, initialCollateral, targetLeverage);

        // Calculate expected collateral delta
        uint256 expectedCollateralDelta = _calculateExpectedCollateralDelta(yNVDA, address(ptUsde), expectedFlashLoan);

        // Execute leverage
        vm.startPrank(borrower1);
        IERC20(ptUsde).approve(address(looper), initialCollateral);

        looper.leverage(
            address(ptUsde),
            yNVDA,
            initialCollateral,
            targetLeverage,
            0 // minCollateralOut (no slippage protection for happy path)
        );
        vm.stopPrank();

        // Verify position
        DataTypes.UserPosition memory position = yoloHook.getUserPosition(borrower1, address(ptUsde), yNVDA);

        // Check collateral (should be initial + delta)
        assertApproxEqRel(
            position.collateralSuppliedAmount,
            initialCollateral + expectedCollateralDelta,
            1e16, // 1% tolerance for rounding
            "Collateral should match expected"
        );

        // Check debt (flash loan amount only - fee is 0 for PRIVILEGED_FLASHLOANER_ROLE)
        uint256 expectedDebt = expectedFlashLoan;
        uint256 actualDebt = yoloHook.getPositionDebt(borrower1, address(ptUsde), yNVDA);
        assertApproxEqRel(actualDebt, expectedDebt, 1e16, "Debt should match flash loan (no fee for privileged)");

        // Check borrower's collateral balance depleted
        assertEq(IERC20(ptUsde).balanceOf(borrower1), 0, "User's collateral should be fully deposited");

        // Check looper doesn't retain any tokens
        assertEq(IERC20(ptUsde).balanceOf(address(looper)), 0, "Looper shouldn't retain collateral");
        assertEq(IERC20(yNVDA).balanceOf(address(looper)), 0, "Looper shouldn't retain synthetic");
    }

    /**
     * @notice Test Case 2: Partial deleverage
     */
    function test_Action09_Case02_partialDeleverage() public {
        // First establish leveraged position
        uint256 initialCollateral = 10_000e18; // 10k PT-USDe
        uint256 targetLeverage = 25e17; // 2.5x leverage (18 decimals)

        deal(address(ptUsde), borrower1, initialCollateral);

        vm.startPrank(borrower1);
        IERC20(ptUsde).approve(address(looper), initialCollateral);
        looper.leverage(address(ptUsde), yNVDA, initialCollateral, targetLeverage, 0);

        // Get initial position state
        uint256 initialDebt = yoloHook.getPositionDebt(borrower1, address(ptUsde), yNVDA);
        DataTypes.UserPosition memory positionBefore = yoloHook.getUserPosition(borrower1, address(ptUsde), yNVDA);

        // Deleverage 50% of the debt
        uint256 repayAmount = initialDebt / 2;

        looper.deleverage(
            address(ptUsde),
            yNVDA,
            repayAmount,
            0 // minCollateralFreed (no slippage protection)
        );
        vm.stopPrank();

        // Verify position after deleverage
        uint256 debtAfter = yoloHook.getPositionDebt(borrower1, address(ptUsde), yNVDA);
        DataTypes.UserPosition memory positionAfter = yoloHook.getUserPosition(borrower1, address(ptUsde), yNVDA);

        // Debt should decrease by at least repayAmount (could be more if excess synthetic was used)
        assertLe(debtAfter, initialDebt - repayAmount, "Debt should decrease by at least repay amount");

        // Collateral should decrease slightly (only what was needed for flash loan repayment)
        assertLt(
            positionAfter.collateralSuppliedAmount,
            positionBefore.collateralSuppliedAmount,
            "Collateral should decrease"
        );

        // User shouldn't receive collateral in wallet (it stays in position for optimal leverage)
        assertEq(IERC20(ptUsde).balanceOf(borrower1), 0, "User shouldn't receive collateral (stays in position)");

        // User shouldn't have synthetic in wallet either (excess used to repay more debt)
        assertEq(IERC20(yNVDA).balanceOf(borrower1), 0, "User shouldn't have synthetic (used for debt)");
    }

    /**
     * @notice Test Case 3: Full deleverage
     */
    function test_Action09_Case03_fullDeleverage() public {
        // Establish leveraged position
        uint256 initialCollateral = 5_000e18; // 5k PT-USDe
        uint256 targetLeverage = 2e18; // 2x leverage (18 decimals)

        deal(address(ptUsde), borrower1, initialCollateral);

        vm.startPrank(borrower1);
        IERC20(ptUsde).approve(address(looper), initialCollateral);
        looper.leverage(address(ptUsde), yNVDA, initialCollateral, targetLeverage, 0);

        // Record total collateral in position
        DataTypes.UserPosition memory positionBefore = yoloHook.getUserPosition(borrower1, address(ptUsde), yNVDA);
        uint256 totalCollateral = positionBefore.collateralSuppliedAmount;

        // Full deleverage (repayAmount = 0 means full repayment)
        looper.deleverage(address(ptUsde), yNVDA, 0, 0);
        vm.stopPrank();

        // Verify position cleared
        DataTypes.UserPosition memory positionAfter = yoloHook.getUserPosition(borrower1, address(ptUsde), yNVDA);
        assertEq(positionAfter.normalizedDebtRay, 0, "Debt should be fully repaid");
        assertEq(positionAfter.collateralSuppliedAmount, 0, "Collateral should be fully withdrawn");

        // Borrower should recover approximately the same USD value as initial collateral
        // User receives collateral + excess synthetic from the 2% buffer
        uint256 recoveredCollateral = IERC20(ptUsde).balanceOf(borrower1);
        uint256 recoveredSynthetic = IERC20(yNVDA).balanceOf(borrower1);

        // Calculate USD values using oracle prices
        uint256 collateralPrice = yoloOracleReal.getAssetPrice(address(ptUsde));
        uint256 syntheticPrice = yoloOracleReal.getAssetPrice(yNVDA);

        // Initial value in USD
        uint256 initialValueUSD = (initialCollateral * collateralPrice) / 1e18;

        // Recovered value in USD (collateral + synthetic)
        uint256 recoveredCollateralValueUSD = (recoveredCollateral * collateralPrice) / 1e18;
        uint256 recoveredSyntheticValueUSD = (recoveredSynthetic * syntheticPrice) / 1e18;
        uint256 totalRecoveredValueUSD = recoveredCollateralValueUSD + recoveredSyntheticValueUSD;

        // Should recover ~100% of initial value (allowing 1% tolerance for swaps/rounding)
        assertApproxEqRel(totalRecoveredValueUSD, initialValueUSD, 1e16, "Should recover ~99-100% of initial USD value");
    }

    /**
     * @notice Test Case 4: Leverage slippage guard
     */
    function test_Action09_Case04_leverageSlippageProtection() public {
        uint256 initialCollateral = 10_000e18;
        uint256 targetLeverage = 3e18; // 3x (18 decimals)

        deal(address(ptUsde), borrower1, initialCollateral);

        // Calculate expected collateral output
        uint256 expectedFlashLoan = _calculateFlashLoanAmount(address(ptUsde), yNVDA, initialCollateral, targetLeverage);
        uint256 expectedCollateralDelta = _calculateExpectedCollateralDelta(yNVDA, address(ptUsde), expectedFlashLoan);

        vm.startPrank(borrower1);
        IERC20(ptUsde).approve(address(looper), initialCollateral);

        // Set minCollateralOut just above achievable amount
        uint256 minCollateralOut = expectedCollateralDelta + 1000e18; // Impossible to achieve

        // Should revert with slippage error from router (router checks minOut first)
        vm.expectRevert(); // Router__InsufficientOutput from MockRouter
        looper.leverage(address(ptUsde), yNVDA, initialCollateral, targetLeverage, minCollateralOut);
        vm.stopPrank();
    }

    /**
     * @notice Test Case 5: Unauthorized looper (no LOOPER_ROLE)
     */
    function test_Action09_Case05_unauthorizedLooper() public {
        // Deploy a new looper without granting roles
        YoloLooper unauthorizedLooper = new YoloLooper(
            address(yoloHook),
            address(yoloOracleReal),
            address(externalRouter),
            address(yoloRouter),
            address(usdc),
            address(usy),
            PoolKey({
                currency0: Currency.wrap(address(usdc) < address(usy) ? address(usdc) : address(usy)),
                currency1: Currency.wrap(address(usdc) > address(usy) ? address(usdc) : address(usy)),
                fee: 0,
                tickSpacing: 60,
                hooks: IHooks(address(yoloHook))
            })
        );

        uint256 initialCollateral = 1_000e18;
        deal(address(ptUsde), borrower1, initialCollateral);

        vm.startPrank(borrower1);
        IERC20(ptUsde).approve(address(unauthorizedLooper), initialCollateral);

        // Should revert when trying to borrow on behalf
        vm.expectRevert(); // YoloHook__CallerNotAuthorized
        unauthorizedLooper.leverage(
            address(ptUsde),
            yNVDA,
            initialCollateral,
            2e18, // 2x leverage (18 decimals)
            0
        );
        vm.stopPrank();
    }

    /**
     * @notice Test Case 6: Deleverage slippage guard
     */
    function test_Action09_Case06_deleverageSlippageProtection() public {
        // First establish a leveraged position
        uint256 initialCollateral = 10_000e18;
        uint256 targetLeverage = 25e17; // 2.5x (18 decimals)

        deal(address(ptUsde), borrower1, initialCollateral);

        vm.startPrank(borrower1);
        IERC20(ptUsde).approve(address(looper), initialCollateral);
        looper.leverage(address(ptUsde), yNVDA, initialCollateral, targetLeverage, 0);

        // Get current position
        uint256 currentDebt = yoloHook.getPositionDebt(borrower1, address(ptUsde), yNVDA);
        DataTypes.UserPosition memory position = yoloHook.getUserPosition(borrower1, address(ptUsde), yNVDA);

        // Calculate expected freed collateral for partial repay
        uint256 repayAmount = currentDebt / 2;
        uint256 expectedFreed = _calculateFreedCollateral(
            address(ptUsde), yNVDA, repayAmount, position.collateralSuppliedAmount, currentDebt
        );

        // Debug: Let's see what the actual max freed would be
        // This is what the production code would calculate
        uint256 debtAfterRepay = currentDebt - repayAmount;
        uint256 syntheticPrice = yoloOracleReal.getAssetPrice(yNVDA);
        uint256 collateralPrice = yoloOracleReal.getAssetPrice(address(ptUsde));
        uint256 debtValueUSD = (debtAfterRepay * syntheticPrice) / 1e18; // 18 decimals
        uint256 requiredValueUSD = (debtValueUSD * 10000) / 7500; // 75% LTV
        uint256 requiredCollateral = (requiredValueUSD * 1e18) / collateralPrice; // 18 decimals
        uint256 safetyBuffer = (requiredCollateral * 1005) / 1000; // 0.5% buffer
        uint256 actualMaxFreed =
            position.collateralSuppliedAmount > safetyBuffer ? position.collateralSuppliedAmount - safetyBuffer : 0;

        // Set minCollateralFreed above what's actually possible
        uint256 minCollateralFreed = actualMaxFreed + 1000e18;

        // Should revert with slippage error
        vm.expectRevert(YoloLooper.YoloLooper__SlippageExceeded.selector);
        looper.deleverage(address(ptUsde), yNVDA, repayAmount, minCollateralFreed);
        vm.stopPrank();
    }

    /**
     * @notice Test Case 7: Multiple leverage operations
     */
    function test_Action09_Case07_multipleLeverageOperations() public {
        // Test that a user can leverage, partially deleverage, then leverage again
        uint256 initialCollateral = 5_000e18;

        deal(address(ptUsde), borrower1, initialCollateral * 2); // Extra for second leverage

        vm.startPrank(borrower1);
        IERC20(ptUsde).approve(address(looper), initialCollateral * 2);

        // First leverage to 2x
        looper.leverage(address(ptUsde), yNVDA, initialCollateral, 2e18, 0);

        // Partial deleverage
        uint256 debt1 = yoloHook.getPositionDebt(borrower1, address(ptUsde), yNVDA);
        looper.deleverage(address(ptUsde), yNVDA, debt1 / 3, 0);

        // Add more leverage
        looper.leverage(address(ptUsde), yNVDA, initialCollateral, 15e17, 0); // 1.5x on new collateral (18 decimals)

        vm.stopPrank();

        // Verify final position is valid
        DataTypes.UserPosition memory finalPosition = yoloHook.getUserPosition(borrower1, address(ptUsde), yNVDA);
        assertGt(finalPosition.collateralSuppliedAmount, initialCollateral * 2, "Should have leveraged position");
        assertGt(finalPosition.normalizedDebtRay, 0, "Should have outstanding debt");
    }

    /**
     * @notice Test Case 8: Leverage with different collateral/synthetic pairs
     */
    function test_Action09_Case08_differentAssetPairs() public {
        // Test 1: sUSDe collateral with yETH synthetic
        uint256 collateral1 = 5_000e18;
        deal(address(sUsde), borrower1, collateral1);

        vm.startPrank(borrower1);
        IERC20(sUsde).approve(address(looper), collateral1);
        looper.leverage(address(sUsde), yETH, collateral1, 2e18, 0); // 2x leverage
        vm.stopPrank();

        DataTypes.UserPosition memory position1 = yoloHook.getUserPosition(borrower1, address(sUsde), yETH);
        assertGt(position1.collateralSuppliedAmount, collateral1, "Should have leveraged sUSDe position");

        // Test 2: PT-USDe collateral with yETH synthetic (different pair)
        uint256 collateral2 = 10_000e18;
        deal(address(ptUsde), borrower2, collateral2);

        vm.startPrank(borrower2);
        IERC20(ptUsde).approve(address(looper), collateral2);
        looper.leverage(address(ptUsde), yETH, collateral2, 3e18, 0); // 3x leverage
        vm.stopPrank();

        DataTypes.UserPosition memory position2 = yoloHook.getUserPosition(borrower2, address(ptUsde), yETH);
        assertGt(position2.collateralSuppliedAmount, collateral2, "Should have leveraged PT-USDe position");
    }
}
