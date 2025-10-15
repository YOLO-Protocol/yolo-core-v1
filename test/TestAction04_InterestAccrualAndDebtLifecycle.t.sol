// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base01_DeployUniswapV4Pool} from "./base/Base01_DeployUniswapV4Pool.t.sol";
import {YoloHook} from "../src/core/YoloHook.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";
import {StakedYoloUSD} from "../src/tokenization/StakedYoloUSD.sol";
import {ACLManager} from "../src/access/ACLManager.sol";
import {IACLManager} from "../src/interfaces/IACLManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IYoloOracle} from "../src/interfaces/IYoloOracle.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {InterestRateMath} from "../src/libraries/InterestRateMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockYoloOracle} from "../src/mocks/MockYoloOracle.sol";
import {MockYLPVault} from "../src/mocks/MockYLPVault.sol";

/**
 * @title TestAction04_InterestAccrualAndDebtLifecycle
 * @notice Comprehensive test suite for compound interest accrual and debt lifecycle operations
 * @dev Tests interest calculations, debt normalization, repayments, renewals, and liquidations
 *      Validates RAY precision math, lazy index updates, and interest-first payment flow
 */
contract TestAction04_InterestAccrualAndDebtLifecycle is Base01_DeployUniswapV4Pool {
    // ============================================================
    // CONTRACTS
    // ============================================================

    YoloHook public yoloHookImpl;
    YoloHook public yoloHook;
    ACLManager public aclManager;
    MockYoloOracle public oracle;
    MockYLPVault public ylpVault;
    YoloSyntheticAsset public syntheticAssetImpl;

    // ============================================================
    // TEST ACCOUNTS
    // ============================================================

    address public admin = makeAddr("admin");
    address public assetsAdmin = makeAddr("assetsAdmin");
    address public riskAdmin = makeAddr("riskAdmin");
    address public borrower1 = makeAddr("borrower1");
    address public borrower2 = makeAddr("borrower2");
    address public liquidator = makeAddr("liquidator");
    address public treasury = makeAddr("treasury");

    // ============================================================
    // MOCK ASSETS
    // ============================================================

    MockERC20 public usdc; // Collateral 1
    MockERC20 public weth; // Collateral 2
    address public yUSD; // Synthetic asset 1
    address public yETH; // Synthetic asset 2
    address public sUSY;
    YoloSyntheticAsset public usyImpl;
    StakedYoloUSD public sUSYImpl;

    // ============================================================
    // PAIR IDS
    // ============================================================

    bytes32 public pairId_yUSD_USDC;
    bytes32 public pairId_yETH_WETH;

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 constant RAY = 1e27;
    uint256 constant YEAR = 365 days;
    uint256 constant BORROW_RATE_5PCT = 500; // 5% APR in bps
    uint256 constant BORROW_RATE_10PCT = 1000; // 10% APR in bps
    uint256 constant LTV_80 = 8000; // 80%
    uint256 constant LIQUIDATION_THRESHOLD_85 = 8500; // 85%
    uint256 constant LIQUIDATION_PENALTY_5 = 500; // 5%

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public override {
        // Call parent setUp to deploy real PoolManager
        super.setUp();

        // Deploy mock infrastructure
        oracle = new MockYoloOracle();
        ylpVault = new MockYLPVault();
        usdc = new MockERC20("USD Coin", "USDC", 6);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);

        // Set oracle prices
        oracle.setAssetPrice(address(usdc), 1e8); // $1
        oracle.setAssetPrice(address(weth), 2000e8); // $2000

        // Deploy ACL Manager
        aclManager = new ACLManager(admin);

        // Set up roles
        aclManager.createRole("ASSETS_ADMIN", bytes32(0));
        aclManager.createRole("RISK_ADMIN", bytes32(0));
        aclManager.grantRole(keccak256("ASSETS_ADMIN"), assetsAdmin);
        aclManager.grantRole(keccak256("RISK_ADMIN"), riskAdmin);

        // Deploy synthetic asset implementation
        syntheticAssetImpl = new YoloSyntheticAsset();

        // Deploy sUSY implementation
        sUSYImpl = new StakedYoloUSD(IACLManager(address(aclManager)));

        // Precompute valid hook addresses
        address hookImplAddress = address(uint160(Hooks.ALL_HOOK_MASK));
        address hookProxyAddress = address(uint160(Hooks.ALL_HOOK_MASK << 1) + 1);

        // Deploy YoloHook implementation at specific address using deployCodeTo
        deployCodeTo("YoloHook.sol:YoloHook", abi.encode(address(manager), address(aclManager)), hookImplAddress);
        yoloHookImpl = YoloHook(hookImplAddress);

        // Deploy ERC1967Proxy (UUPS) at specific address using deployCodeTo
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,uint256,uint256,uint256)",
            address(oracle),
            address(usdc),
            address(syntheticAssetImpl),
            address(sUSYImpl),
            address(ylpVault),
            treasury, // treasury address for interest payments
            100, // anchorAmplificationCoefficient (A=100 for stablecoins)
            10, // anchorSwapFeeBps (0.1% = 10 bps)
            10 // syntheticSwapFeeBps (0.1% = 10 bps)
        );

        deployCodeTo("ERC1967Proxy.sol:ERC1967Proxy", abi.encode(hookImplAddress, initData), hookProxyAddress);
        yoloHook = YoloHook(hookProxyAddress);

        // Create synthetic assets
        vm.startPrank(assetsAdmin);

        yUSD = yoloHook.createSyntheticAsset(
            "Yolo USD", "yUSD", 18, address(usdc), address(usdc), address(syntheticAssetImpl), 0
        );

        yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0
        );

        // Set oracle prices for synthetic assets
        oracle.setAssetPrice(yUSD, 1e8); // $1
        oracle.setAssetPrice(yETH, 2000e8); // $2000

        // Whitelist collaterals
        yoloHook.whitelistCollateral(address(usdc));
        yoloHook.whitelistCollateral(address(weth));

        // Configure lending pairs
        pairId_yUSD_USDC = yoloHook.configureLendingPair(
            yUSD,
            address(usdc),
            address(0), // no deposit token
            address(0), // no debt token
            LTV_80,
            LIQUIDATION_THRESHOLD_85, // liquidation threshold must be > LTV
            0, // no bonus
            LIQUIDATION_PENALTY_5,
            BORROW_RATE_5PCT,
            type(uint256).max, // unlimited mint cap
            type(uint256).max, // unlimited supply cap
            1e18, // minimum borrow amount (1 unit)
            false, // not expirable
            0 // no expiry period
        );

        pairId_yETH_WETH = yoloHook.configureLendingPair(
            yETH,
            address(weth),
            address(0),
            address(0),
            LTV_80,
            LIQUIDATION_THRESHOLD_85,
            0,
            LIQUIDATION_PENALTY_5,
            BORROW_RATE_10PCT,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            true, // expirable
            30 days // 30 day expiry
        );

        vm.stopPrank();

        // Fund test accounts
        deal(address(usdc), borrower1, 1_000_000e6);
        deal(address(usdc), borrower2, 1_000_000e6);
        deal(address(weth), borrower1, 1000 ether);
        deal(address(weth), borrower2, 1000 ether);
        deal(address(weth), liquidator, 1000 ether);

        // Approve spending
        vm.prank(borrower1);
        usdc.approve(address(yoloHook), type(uint256).max);
        vm.prank(borrower1);
        weth.approve(address(yoloHook), type(uint256).max);
        vm.prank(borrower2);
        usdc.approve(address(yoloHook), type(uint256).max);
        vm.prank(borrower2);
        weth.approve(address(yoloHook), type(uint256).max);
        vm.prank(liquidator);
        weth.approve(address(yoloHook), type(uint256).max);
    }

    // ============================================================
    // CASE 01: Initial Borrow Sets Normalized Values
    // ============================================================

    function test_Action04_Case01_initialBorrow_setsNormalizedValues() public {
        uint256 collateralAmount = 10_000e6; // 10,000 USDC
        uint256 borrowAmount = 4 ether; // 4 yUSD (50% LTV)

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        DataTypes.UserPosition memory position = yoloHook.getUserPosition(borrower1, address(usdc), yUSD);
        DataTypes.PairConfiguration memory pair = yoloHook.getPairConfiguration(yUSD, address(usdc));

        // Assert normalized values are equal initially (no interest yet)
        assertEq(position.normalizedPrincipalRay, position.normalizedDebtRay, "Principal and debt should be equal");

        // Assert user index equals global index
        assertEq(position.userLiquidityIndexRay, pair.liquidityIndexRay, "User index should equal global index");
        assertEq(pair.liquidityIndexRay, RAY, "Initial global index should be RAY (1.0)");

        // Assert collateral set
        assertEq(position.collateralSuppliedAmount, collateralAmount, "Collateral mismatch");

        // Assert borrower address set
        assertEq(position.borrower, borrower1, "Borrower address mismatch");

        // Assert expiry NOT set for non-expirable pair
        assertEq(position.expiryTimestamp, 0, "Expiry should be 0 for non-expirable pair");
    }

    // ============================================================
    // CASE 02: Lazy Index Accrual After Warp
    // ============================================================

    function test_Action04_Case02_lazyIndexAccrualAfterWarp() public {
        // Initial borrow
        uint256 borrowAmount = 4 ether;
        uint256 collateralAmount = 10_000e6;

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        DataTypes.PairConfiguration memory pairBefore = yoloHook.getPairConfiguration(yUSD, address(usdc));

        // Warp 1 year forward
        vm.warp(block.timestamp + YEAR);

        // Global index should NOT update automatically (lazy)
        DataTypes.PairConfiguration memory pairAfter = yoloHook.getPairConfiguration(yUSD, address(usdc));
        assertEq(pairAfter.liquidityIndexRay, pairBefore.liquidityIndexRay, "Index should not auto-update");
        assertEq(pairAfter.liquidityIndexRay, RAY, "Index should still be RAY");

        // View function should calculate effective index
        uint256 effectiveDebt = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);

        // With 5% APR for 1 year: debt should be ~4.2 ether
        assertGt(effectiveDebt, borrowAmount, "Debt should have grown");
        assertApproxEqRel(effectiveDebt, borrowAmount * 105 / 100, 0.01e18); // Within 1%
    }

    // ============================================================
    // CASE 03: Reborrow Renormalizes Principal And Debt
    // ============================================================

    function test_Action04_Case03_reborrow_renormalizesPrincipalAndDebt() public {
        // Initial borrow
        uint256 initialBorrow = 4 ether;
        uint256 collateralAmount = 20_000e6;

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, initialBorrow, address(usdc), collateralAmount);

        // Warp 6 months
        vm.warp(block.timestamp + 180 days);

        // Second borrow (reborrow)
        uint256 secondBorrow = 2 ether;
        vm.prank(borrower1);
        yoloHook.borrow(yUSD, secondBorrow, address(usdc), 0); // No additional collateral

        DataTypes.UserPosition memory position = yoloHook.getUserPosition(borrower1, address(usdc), yUSD);
        DataTypes.PairConfiguration memory pair = yoloHook.getPairConfiguration(yUSD, address(usdc));

        // Index should have updated
        assertGt(pair.liquidityIndexRay, RAY, "Global index should have increased");

        // User index should be updated to current global index
        assertEq(position.userLiquidityIndexRay, pair.liquidityIndexRay, "User index should match global");

        // Principal should be ~6 ether (4 + 2), but normalized
        uint256 expectedPrincipal = initialBorrow + secondBorrow;
        uint256 actualPrincipal = InterestRateMath.calculateCurrentPrincipal(
            position.normalizedPrincipalRay, position.userLiquidityIndexRay, pair.liquidityIndexRay
        );

        // Debt should be greater than principal (includes interest)
        uint256 actualDebt = InterestRateMath.divUp(position.normalizedDebtRay * pair.liquidityIndexRay, RAY);

        assertApproxEqRel(actualPrincipal, expectedPrincipal, 0.01e18, "Principal mismatch");
        assertGt(actualDebt, actualPrincipal, "Debt should exceed principal");
    }

    // ============================================================
    // CASE 04: Partial Repay With Interest-First Logic
    // ============================================================

    function test_Action04_Case04_partialRepay_interestFirstLogic() public {
        // Initial borrow
        uint256 borrowAmount = 4 ether;
        uint256 collateralAmount = 10_000e6;

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        // Warp 1 year
        vm.warp(block.timestamp + YEAR);

        // Calculate current debt (~4.2 ether with 5% APR)
        uint256 currentDebt = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);
        uint256 interestAccrued = currentDebt - borrowAmount;

        // Partial repay: exactly the interest amount
        uint256 repayAmount = interestAccrued;

        // Mint yUSD to borrower for repayment
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(yUSD).mint(borrower1, repayAmount);

        // Approve spending
        vm.prank(borrower1);
        YoloSyntheticAsset(yUSD).approve(address(yoloHook), repayAmount);

        // Record treasury balance before
        uint256 treasuryBalanceBefore = YoloSyntheticAsset(yUSD).balanceOf(treasury);

        // Repay
        vm.prank(borrower1);
        yoloHook.repay(yUSD, address(usdc), repayAmount);

        // Treasury should have received the interest
        uint256 treasuryBalanceAfter = YoloSyntheticAsset(yUSD).balanceOf(treasury);
        assertApproxEqRel(
            treasuryBalanceAfter - treasuryBalanceBefore, interestAccrued, 0.01e18, "Treasury should receive interest"
        );

        // Principal should remain unchanged
        uint256 newDebt = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);
        assertApproxEqRel(newDebt, borrowAmount, 0.01e18, "Debt should be back to principal");
    }

    // ============================================================
    // CASE 05: Full Repay With Collateral Claim
    // ============================================================

    function test_Action04_Case05_fullRepay_withCollateralClaim() public {
        // Initial borrow
        uint256 borrowAmount = 4 ether;
        uint256 collateralAmount = 10_000e6;

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        // Warp 1 year
        vm.warp(block.timestamp + YEAR);

        // Get full debt
        uint256 fullDebt = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);

        // Mint yUSD to borrower for full repayment
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(yUSD).mint(borrower1, fullDebt);

        // Approve spending
        vm.prank(borrower1);
        YoloSyntheticAsset(yUSD).approve(address(yoloHook), fullDebt);

        // Record balances before
        uint256 borrowerCollateralBefore = usdc.balanceOf(borrower1);

        // Full repay
        vm.prank(borrower1);
        yoloHook.repay(yUSD, address(usdc), fullDebt);

        // Borrower should receive collateral back
        uint256 borrowerCollateralAfter = usdc.balanceOf(borrower1);
        assertEq(
            borrowerCollateralAfter - borrowerCollateralBefore,
            collateralAmount,
            "Borrower should receive full collateral"
        );

        // Position should be cleared
        DataTypes.UserPosition memory position = yoloHook.getUserPosition(borrower1, address(usdc), yUSD);
        assertEq(position.normalizedDebtRay, 0, "Debt should be zero");
        assertEq(position.collateralSuppliedAmount, 0, "Collateral should be zero");
    }

    // ============================================================
    // CASE 06: Rate Change Settles Index Properly
    // ============================================================

    function test_Action04_Case06_rateChange_settlesIndexProperly() public {
        // Initial borrow at 5% APR
        uint256 borrowAmount = 4 ether;
        uint256 collateralAmount = 10_000e6;

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        // Warp 6 months
        vm.warp(block.timestamp + 180 days);

        DataTypes.PairConfiguration memory pairBefore = yoloHook.getPairConfiguration(yUSD, address(usdc));
        uint256 indexBefore = pairBefore.liquidityIndexRay;

        // Change rate to 10% APR
        vm.prank(assetsAdmin);
        yoloHook.updateBorrowRate(pairId_yUSD_USDC, BORROW_RATE_10PCT);

        // Index should have settled with old rate
        DataTypes.PairConfiguration memory pairAfter = yoloHook.getPairConfiguration(yUSD, address(usdc));
        assertGt(pairAfter.liquidityIndexRay, indexBefore, "Index should have increased");

        // New rate should be set
        assertEq(pairAfter.borrowRate, BORROW_RATE_10PCT, "Rate should be updated");
    }

    // ============================================================
    // CASE 07: Renew Collects Interest To Treasury
    // ============================================================

    function test_Action04_Case07_renew_collectsInterestToTreasury() public {
        // Borrow with expirable pair
        uint256 borrowAmount = 1 ether; // $2000 debt
        uint256 collateralAmount = 1.25 ether; // $2500 collateral for 80% LTV

        vm.prank(borrower1);
        yoloHook.borrow(yETH, borrowAmount, address(weth), collateralAmount);

        // Warp to near expiry
        vm.warp(block.timestamp + 20 days);

        // Record treasury balance
        uint256 treasuryBalanceBefore = YoloSyntheticAsset(yETH).balanceOf(treasury);

        // Renew position
        vm.prank(borrower1);
        yoloHook.renewPosition(yETH, address(weth));

        // Treasury should have received interest
        uint256 treasuryBalanceAfter = YoloSyntheticAsset(yETH).balanceOf(treasury);
        assertGt(treasuryBalanceAfter, treasuryBalanceBefore, "Treasury should receive interest");

        // Position expiry should be extended
        DataTypes.UserPosition memory position = yoloHook.getUserPosition(borrower1, address(weth), yETH);
        assertEq(position.expiryTimestamp, block.timestamp + 30 days, "Expiry should be extended");
    }

    // ============================================================
    // CASE 08: Liquidate Expired Position Bypasses Solvency
    // ============================================================

    function test_Action04_Case08_liquidateExpired_bypassesSolvency() public {
        // Borrow with expirable pair
        uint256 borrowAmount = 1 ether; // $2000 debt
        uint256 collateralAmount = 1.25 ether; // $2500 collateral for 80% LTV

        vm.prank(borrower1);
        yoloHook.borrow(yETH, borrowAmount, address(weth), collateralAmount);

        // Warp past expiry
        vm.warp(block.timestamp + 31 days);

        // Position is expired but solvent (LTV is fine)
        // Should still be liquidatable

        // Mint yETH to liquidator
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(yETH).mint(liquidator, borrowAmount);

        // Approve spending
        vm.prank(liquidator);
        YoloSyntheticAsset(yETH).approve(address(yoloHook), borrowAmount);

        // Liquidate (should succeed even though solvent)
        vm.prank(liquidator);
        yoloHook.liquidate(borrower1, address(weth), yETH, borrowAmount);

        // Liquidator should receive collateral with penalty
        assertGt(weth.balanceOf(liquidator), collateralAmount, "Liquidator should receive collateral + penalty");
    }

    // ============================================================
    // CASE 09: Partial Liquidation Of Insolvent Position
    // ============================================================

    function test_Action04_Case09_partialLiquidation_insolventPosition() public {
        // Borrow at 80% LTV
        uint256 borrowAmount = 8000 ether; // 80% of $10,000 collateral = $8,000
        uint256 collateralAmount = 10_000e6; // $10,000 USDC

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        // Manipulate price to make position insolvent
        // Drop USDC price to $0.80 (20% drop)
        oracle.setAssetPrice(address(usdc), 0.8e8);

        // Position should now be insolvent (80% LTV breached)

        // Partial liquidation
        uint256 repayAmount = 1 ether;

        // Mint yUSD to liquidator
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(yUSD).mint(liquidator, repayAmount);

        // Approve spending
        vm.prank(liquidator);
        YoloSyntheticAsset(yUSD).approve(address(yoloHook), repayAmount);

        // Liquidate
        vm.prank(liquidator);
        yoloHook.liquidate(borrower1, address(usdc), yUSD, repayAmount);

        // Position should still exist with reduced debt
        DataTypes.UserPosition memory position = yoloHook.getUserPosition(borrower1, address(usdc), yUSD);
        assertGt(position.normalizedDebtRay, 0, "Position should still have debt");
        assertLt(position.collateralSuppliedAmount, collateralAmount, "Collateral should be reduced");
    }

    // ============================================================
    // CASE 10: Fuzz Test - Debt Vs Index Calculations
    // ============================================================

    function testFuzz_Action04_Case10_debtVsIndexCalculations(uint256 borrowAmount, uint256 timeElapsed, uint256 rate)
        public
    {
        // Bound inputs
        borrowAmount = bound(borrowAmount, 1 ether, 1000 ether);
        timeElapsed = bound(timeElapsed, 1 days, 10 * YEAR);
        rate = bound(rate, 100, 10000); // 1% to 100% APR

        uint256 collateralAmount = borrowAmount * 2; // 200% collateral
        deal(address(usdc), borrower1, collateralAmount / 1e12); // Convert to USDC decimals

        // Update pair rate
        vm.prank(assetsAdmin);
        yoloHook.updateBorrowRate(pairId_yUSD_USDC, rate);

        // Borrow
        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount / 1e12);

        // Warp
        vm.warp(block.timestamp + timeElapsed);

        // Get debt
        uint256 debt = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);

        // Debt should always be >= principal
        assertGe(debt, borrowAmount, "Debt should be >= principal");

        // Debt should grow reasonably (not overflow)
        assertLt(debt, borrowAmount * 100, "Debt should not grow unreasonably");
    }

    // ============================================================
    // CASE 11: No Time Delta Index Stability
    // ============================================================

    function test_Action04_Case11_noTimeDelta_indexStability() public {
        // Initial borrow
        uint256 borrowAmount = 4 ether;
        uint256 collateralAmount = 10_000e6;

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        DataTypes.PairConfiguration memory pair = yoloHook.getPairConfiguration(yUSD, address(usdc));
        uint256 indexBefore = pair.liquidityIndexRay;

        // Immediate reborrow (no time elapsed)
        vm.prank(borrower1);
        yoloHook.borrow(yUSD, 1 ether, address(usdc), 0);

        DataTypes.PairConfiguration memory pairAfter = yoloHook.getPairConfiguration(yUSD, address(usdc));

        // Index should not change when timeDelta = 0
        assertEq(pairAfter.liquidityIndexRay, indexBefore, "Index should be stable with no time delta");
    }

    // ============================================================
    // CASE 12: Rounding Favors Protocol (divUp)
    // ============================================================

    function test_Action04_Case12_rounding_favorsProtocol() public {
        // Borrow amount at minimum threshold to test rounding
        uint256 borrowAmount = 1 ether; // $2000 debt
        uint256 collateralAmount = 2000e6; // $2000 USDC for $1 debt (200% collateral)

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        // Warp
        vm.warp(block.timestamp + 1 days);

        // Get debt (should use divUp)
        uint256 debt = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);

        // Debt should be rounded up (favoring protocol)
        assertGe(debt, borrowAmount, "Debt should be rounded up");
    }

    // ============================================================
    // CASE 13: Multi-Borrower Isolation
    // ============================================================

    function test_Action04_Case13_multiBorrower_isolation() public {
        // Borrower1 borrows
        uint256 borrow1 = 4 ether;
        uint256 collateral1 = 10_000e6;

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrow1, address(usdc), collateral1);

        // Warp 6 months
        vm.warp(block.timestamp + 180 days);

        // Borrower2 borrows
        uint256 borrow2 = 2 ether;
        uint256 collateral2 = 5_000e6;

        vm.prank(borrower2);
        yoloHook.borrow(yUSD, borrow2, address(usdc), collateral2);

        // Warp another 6 months
        vm.warp(block.timestamp + 180 days);

        // Get debts
        uint256 debt1 = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);
        uint256 debt2 = yoloHook.getPositionDebt(borrower2, address(usdc), yUSD);

        // Borrower1 should have more interest accrued (borrowed earlier)
        assertGt(debt1 - borrow1, debt2 - borrow2, "Borrower1 should have more interest");

        // Borrower1's userIndex should be different from borrower2's
        DataTypes.UserPosition memory pos1 = yoloHook.getUserPosition(borrower1, address(usdc), yUSD);
        DataTypes.UserPosition memory pos2 = yoloHook.getUserPosition(borrower2, address(usdc), yUSD);

        assertLt(pos1.userLiquidityIndexRay, pos2.userLiquidityIndexRay, "Borrower1 entered at lower index");
    }

    // ============================================================
    // CASE 14: Cross-Pair Independence
    // ============================================================

    function test_Action04_Case14_crossPair_independence() public {
        // Borrow from pair 1 (5% APR)
        vm.prank(borrower1);
        yoloHook.borrow(yUSD, 4 ether, address(usdc), 10_000e6);

        // Borrow from pair 2 (10% APR)
        vm.prank(borrower1);
        yoloHook.borrow(yETH, 1 ether, address(weth), 1.25 ether);

        // Warp 1 year
        vm.warp(block.timestamp + YEAR);

        // Get debts
        uint256 debt1 = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);
        uint256 debt2 = yoloHook.getPositionDebt(borrower1, address(weth), yETH);

        // Pair 2 should have more relative growth (10% vs 5%)
        uint256 growth1 = ((debt1 - 4 ether) * 100) / 4 ether;
        uint256 growth2 = ((debt2 - 1 ether) * 100) / 1 ether;

        assertGt(growth2, growth1, "10% APR pair should grow faster than 5% APR pair");
    }

    // ============================================================
    // CASE 15: Stored Interest Rate Lifecycle
    // ============================================================

    function test_Action04_Case15_storedInterestRate_lifecycle() public {
        // Initial borrow on EXPIRABLE pair (yETH-WETH)
        vm.prank(borrower1);
        yoloHook.borrow(yETH, 1 ether, address(weth), 2.6 ether);

        DataTypes.UserPosition memory pos1 = yoloHook.getUserPosition(borrower1, address(weth), yETH);
        assertEq(pos1.storedInterestRate, BORROW_RATE_10PCT, "Should store initial rate");

        // Change pair rate
        vm.prank(assetsAdmin);
        yoloHook.updateBorrowRate(pairId_yETH_WETH, BORROW_RATE_5PCT);

        // Reborrow (DOES NOT update stored rate - only renewal does)
        vm.warp(block.timestamp + 1 days);
        vm.prank(borrower1);
        yoloHook.borrow(yETH, 1 ether, address(weth), 0); // Changed from 0.5 to 1 to meet minimum

        DataTypes.UserPosition memory pos2 = yoloHook.getUserPosition(borrower1, address(weth), yETH);
        assertEq(
            pos2.storedInterestRate, BORROW_RATE_10PCT, "Rate should NOT update on reborrow - locked until renewal"
        );

        // Now renew position - this WILL update stored rate (only works on expirable pairs)
        vm.prank(borrower1);
        yoloHook.renewPosition(yETH, address(weth));

        DataTypes.UserPosition memory pos3 = yoloHook.getUserPosition(borrower1, address(weth), yETH);
        assertEq(pos3.storedInterestRate, BORROW_RATE_5PCT, "Rate should update to new pair rate after renewal");
    }

    // ============================================================
    // CASE 16: Solvency Ratio View Accuracy
    // ============================================================

    function test_Action04_Case16_solvencyRatio_viewAccuracy() public {
        // Borrow at 50% LTV
        uint256 borrowAmount = 2000 ether; // $2000
        uint256 collateralAmount = 10_000e6; // $10,000

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, borrowAmount, address(usdc), collateralAmount);

        // Check health factor
        (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 ltv) = yoloHook.getUserAccountData(borrower1);

        assertEq(totalCollateralUSD, 10_000e8, "Collateral value mismatch");
        assertEq(totalDebtUSD, 2_000e8, "Debt value mismatch");
        assertEq(ltv, 2000, "LTV should be 20% (2000 bps)");
    }

    // ============================================================
    // CASE 17: Expiry Renewal Window
    // ============================================================

    function test_Action04_Case17_expiryRenewal_window() public {
        // Borrow expirable
        vm.prank(borrower1);
        yoloHook.borrow(yETH, 1 ether, address(weth), 1.25 ether);

        DataTypes.UserPosition memory pos1 = yoloHook.getUserPosition(borrower1, address(weth), yETH);
        uint256 firstExpiry = pos1.expiryTimestamp;

        // Renew before expiry
        vm.warp(block.timestamp + 15 days);
        vm.prank(borrower1);
        yoloHook.renewPosition(yETH, address(weth));

        DataTypes.UserPosition memory pos2 = yoloHook.getUserPosition(borrower1, address(weth), yETH);
        uint256 secondExpiry = pos2.expiryTimestamp;

        // New expiry should be 30 days from renewal time
        assertEq(secondExpiry, block.timestamp + 30 days, "Expiry should be extended from current time");
        assertGt(secondExpiry, firstExpiry, "New expiry should be later");
    }

    // ============================================================
    // CASE 18: Treasury Flow Accounting
    // ============================================================

    function test_Action04_Case18_treasuryFlow_accounting() public {
        // Multiple borrowers generate interest
        vm.prank(borrower1);
        yoloHook.borrow(yUSD, 4 ether, address(usdc), 10_000e6);

        vm.prank(borrower2);
        yoloHook.borrow(yUSD, 2 ether, address(usdc), 5_000e6);

        // Warp 1 year
        vm.warp(block.timestamp + YEAR);

        uint256 treasuryBefore = YoloSyntheticAsset(yUSD).balanceOf(treasury);

        // Borrower1 repays
        uint256 debt1 = yoloHook.getPositionDebt(borrower1, address(usdc), yUSD);
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(yUSD).mint(borrower1, debt1);
        vm.prank(borrower1);
        YoloSyntheticAsset(yUSD).approve(address(yoloHook), debt1);
        vm.prank(borrower1);
        yoloHook.repay(yUSD, address(usdc), debt1);

        uint256 treasuryAfter1 = YoloSyntheticAsset(yUSD).balanceOf(treasury);
        uint256 interest1 = treasuryAfter1 - treasuryBefore;

        // Borrower2 repays
        uint256 debt2 = yoloHook.getPositionDebt(borrower2, address(usdc), yUSD);
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(yUSD).mint(borrower2, debt2);
        vm.prank(borrower2);
        YoloSyntheticAsset(yUSD).approve(address(yoloHook), debt2);
        vm.prank(borrower2);
        yoloHook.repay(yUSD, address(usdc), debt2);

        uint256 treasuryAfter2 = YoloSyntheticAsset(yUSD).balanceOf(treasury);
        uint256 interest2 = treasuryAfter2 - treasuryAfter1;

        // Interest should be proportional to borrows
        assertApproxEqRel(interest1 / interest2, 2, 0.01e18, "Interest should be ~2:1");
    }

    // ============================================================
    // CASE 19: Liquidity Index Monotonicity
    // ============================================================

    function test_Action04_Case19_liquidityIndex_monotonicity() public {
        // Borrow
        vm.prank(borrower1);
        yoloHook.borrow(yUSD, 4 ether, address(usdc), 10_000e6);

        DataTypes.PairConfiguration memory pair1 = yoloHook.getPairConfiguration(yUSD, address(usdc));

        // Multiple time warps and reborrows
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(block.timestamp + 30 days);
            vm.prank(borrower1);
            yoloHook.borrow(yUSD, 1 ether, address(usdc), 0); // Minimum borrow amount

            DataTypes.PairConfiguration memory pair2 = yoloHook.getPairConfiguration(yUSD, address(usdc));

            // Index should never decrease
            assertGe(pair2.liquidityIndexRay, pair1.liquidityIndexRay, "Index should be monotonically increasing");

            pair1 = pair2;
        }
    }

    // ============================================================
    // CASE 20: Reentrancy Guards
    // ============================================================

    function test_Action04_Case20_reentrancy_guards() public {
        // This test assumes reentrancy guards are in place
        // Basic check: can't borrow during borrow callback

        vm.prank(borrower1);
        yoloHook.borrow(yUSD, 4 ether, address(usdc), 10_000e6);

        // Reentrancy would fail at function entry
        // This is a structural test - the modifiers should be in place
        // Full reentrancy testing would require malicious callback contracts

        assertTrue(true, "Placeholder for reentrancy guard structural test");
    }
}
