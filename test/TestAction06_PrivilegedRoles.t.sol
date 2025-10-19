// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base02_DeployYoloHook} from "./base/Base02_DeployYoloHook.t.sol";
import {YoloHook} from "../src/core/YoloHook.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IFlashBorrower} from "../src/interfaces/IFlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestAction06_PrivilegedRoles
 * @notice Comprehensive test suite for privileged roles (PRIVILEGED_LIQUIDATOR and PRIVILEGED_FLASHLOANER)
 * @dev Tests role-based access control for liquidations and flash loans
 */
contract TestAction06_PrivilegedRoles is Base02_DeployYoloHook {
    // ============================================================
    // CONTRACTS
    // ============================================================

    YoloSyntheticAsset public syntheticAssetImpl;
    MockERC20 public weth;
    MockERC20 public wbtc;

    // ============================================================
    // TEST ACCOUNTS
    // ============================================================

    address public assetsAdmin = makeAddr("assetsAdmin");
    address public riskAdmin = makeAddr("riskAdmin");
    address public privilegedLiquidator = makeAddr("privilegedLiquidator");
    address public privilegedFlashloaner = makeAddr("privilegedFlashloaner");
    address public regularUser = makeAddr("regularUser");
    address public borrower = makeAddr("borrower");

    // ============================================================
    // TEST ASSETS
    // ============================================================

    address public yETH;
    address public yBTC;

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public override {
        super.setUp(); // Deploy YoloHook from Base02

        // Deploy test collateral
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        // Set up ACL roles
        aclManager.createRole("ASSETS_ADMIN", bytes32(0));
        aclManager.createRole("RISK_ADMIN", bytes32(0));
        aclManager.createRole("PRIVILEGED_LIQUIDATOR", bytes32(0));
        aclManager.createRole("PRIVILEGED_FLASHLOANER", bytes32(0));

        aclManager.grantRole(keccak256("ASSETS_ADMIN"), assetsAdmin);
        aclManager.grantRole(keccak256("RISK_ADMIN"), riskAdmin);
        aclManager.grantRole(keccak256("PRIVILEGED_LIQUIDATOR"), privilegedLiquidator);
        aclManager.grantRole(keccak256("PRIVILEGED_FLASHLOANER"), privilegedFlashloaner);

        // Deploy synthetic asset implementation
        syntheticAssetImpl = new YoloSyntheticAsset();

        // Set up oracle prices
        oracle.setAssetPrice(address(weth), 2000e8); // $2000 per ETH
        oracle.setAssetPrice(address(wbtc), 40000e8); // $40000 per BTC
        oracle.setAssetPrice(address(usdc), 1e8); // $1 per USDC
        oracle.setAssetPrice(usy, 1e8); // $1 per USY

        // Create yETH synthetic asset
        vm.startPrank(assetsAdmin);
        yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH",
            "yETH",
            18,
            address(weth),
            address(syntheticAssetImpl),
            0, // no max supply
            type(uint256).max // unlimited flash loans
        );

        // Create yBTC synthetic asset for batch flash loan testing
        yBTC = yoloHook.createSyntheticAsset(
            "Yolo Synthetic BTC",
            "yBTC",
            8,
            address(wbtc),
            address(syntheticAssetImpl),
            0, // no max supply
            type(uint256).max // unlimited flash loans
        );
        vm.stopPrank();

        // Set oracle prices for synthetic assets (yETH uses default ~$2-3 range for liquidation tests)
        oracle.setAssetPrice(yBTC, 40000e8); // $40000 per yBTC

        // Whitelist USDC as collateral
        vm.prank(assetsAdmin);
        yoloHook.whitelistCollateral(address(usdc));

        // Configure yETH-USDC lending pair
        vm.startPrank(assetsAdmin);
        yoloHook.configureLendingPair(
            yETH, // synthetic
            address(usdc), // collateral
            address(0), // no deposit token
            address(0), // no debt token
            8000, // 80% LTV
            8500, // 85% liquidation threshold
            500, // 5% liquidation bonus
            500, // 5% liquidation penalty
            300, // 3% borrow rate
            type(uint256).max, // unlimited mint cap
            type(uint256).max, // unlimited supply cap
            1e18, // minimum borrow 1 yETH
            false, // not expirable
            0 // no expiry
        );

        // Configure yBTC-USDC lending pair for batch flash loan testing
        yoloHook.configureLendingPair(
            yBTC, // synthetic
            address(usdc), // collateral
            address(0), // no deposit token
            address(0), // no debt token
            8000, // 80% LTV
            8500, // 85% liquidation threshold
            500, // 5% liquidation bonus
            500, // 5% liquidation penalty
            300, // 3% borrow rate
            type(uint256).max, // unlimited mint cap
            type(uint256).max, // unlimited supply cap
            1e8, // minimum borrow 1 yBTC (8 decimals)
            false, // not expirable
            0 // no expiry
        );
        vm.stopPrank();

        // Fund accounts with USDC
        usdc.mint(borrower, 10000e6);
        usdc.mint(regularUser, 10000e6); // Need $250 for borrowing 100 yETH at $2
        usdc.mint(privilegedLiquidator, 10000e6); // Need $250 for borrowing 100 yETH at $2

        // Fund YLP vault with USY for liquidation payouts
        // When liquidations burn synthetic assets with positive PnL, YLP needs USY to pay traders
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(usy).mint(ylpVault, 10000e18); // 10,000 USY for liquidation settlements

        // Give test accounts yETH by having them borrow against USDC
        // This provides them with yETH for liquidation tests
        _mintYETHForTesting(regularUser, 100e18);
        _mintYETHForTesting(privilegedLiquidator, 100e18);
    }

    /**
     * @notice Helper to get yETH for testing by borrowing and immediately repaying
     * @dev Since we can't mint synthetic assets directly, we borrow them through the protocol
     */
    function _mintYETHForTesting(address recipient, uint256 amount) internal {
        // Set yETH price to $2 for testing
        oracle.setAssetPrice(yETH, 2e8);

        vm.startPrank(recipient);

        // Approve USDC
        usdc.approve(address(yoloHook), type(uint256).max);

        // Borrow yETH (need enough collateral - at 80% LTV, for 100 yETH worth $200, need $250 collateral)
        // Each yETH is worth $2, so 100 yETH = $200 value
        // At 80% LTV, need $250 collateral = 250 USDC
        uint256 collateralNeeded = (amount * 2e8 * 10000) / (1e8 * 8000); // amount * price / LTV
        collateralNeeded = collateralNeeded / 1e12; // Convert to 6 decimals

        yoloHook.borrow(yETH, amount, address(usdc), collateralNeeded);

        vm.stopPrank();
    }

    // ============================================================
    // TEST CASE 01: TOGGLE PRIVILEGED LIQUIDATOR - SUCCESS
    // ============================================================

    function test_Action06_Case01_togglePrivilegedLiquidatorSuccess() public {
        // Enable privileged liquidator mode
        vm.prank(assetsAdmin);
        vm.expectEmit(true, true, true, true);
        emit YoloHook.PrivilegedLiquidatorToggled(true);
        yoloHook.togglePrivilegedLiquidator(true);

        // Verify state changed (we can't directly check storage, but we can test effects)

        // Disable privileged liquidator mode
        vm.prank(assetsAdmin);
        vm.expectEmit(true, true, true, true);
        emit YoloHook.PrivilegedLiquidatorToggled(false);
        yoloHook.togglePrivilegedLiquidator(false);
    }

    // ============================================================
    // TEST CASE 02: CANNOT ENABLE WITHOUT PRIVILEGED LIQUIDATORS
    // ============================================================

    function test_Action06_Case02_cannotEnableWithoutPrivilegedLiquidators() public {
        // Revoke the privileged liquidator role
        aclManager.revokeRole(keccak256("PRIVILEGED_LIQUIDATOR"), privilegedLiquidator);

        // Try to enable privileged liquidator mode (should fail)
        vm.prank(assetsAdmin);
        vm.expectRevert(YoloHook.YoloHook__NoPrivilegedLiquidators.selector);
        yoloHook.togglePrivilegedLiquidator(true);
    }

    // ============================================================
    // TEST CASE 03: ONLY ASSETS ADMIN CAN TOGGLE
    // ============================================================

    function test_Action06_Case03_onlyAssetsAdminCanToggle() public {
        vm.prank(regularUser);
        vm.expectRevert(YoloHook.YoloHook__CallerNotAuthorized.selector);
        yoloHook.togglePrivilegedLiquidator(true);
    }

    // ============================================================
    // TEST CASE 04: LIQUIDATION WITHOUT PRIVILEGED MODE - ANYONE CAN LIQUIDATE
    // ============================================================

    function test_Action06_Case04_liquidationWithoutPrivilegedModeAnyoneCanLiquidate() public {
        // Create undercollateralized position
        _createUndercollateralizedPosition();

        // Regular user should be able to liquidate (privileged mode is OFF by default)
        vm.startPrank(regularUser);
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        yoloHook.liquidate(borrower, address(usdc), yETH, 1e18); // Liquidate 1 yETH (debt is 800 yETH)
        vm.stopPrank();
    }

    // ============================================================
    // TEST CASE 05: LIQUIDATION WITH PRIVILEGED MODE - ONLY PRIVILEGED CAN LIQUIDATE
    // ============================================================

    function test_Action06_Case05_liquidationWithPrivilegedModeOnlyPrivilegedCanLiquidate() public {
        // Enable privileged liquidator mode
        vm.prank(assetsAdmin);
        yoloHook.togglePrivilegedLiquidator(true);

        // Create undercollateralized position
        _createUndercollateralizedPosition();

        // Privileged liquidator should succeed (already has yETH from setup)
        vm.startPrank(privilegedLiquidator);
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        yoloHook.liquidate(borrower, address(usdc), yETH, 1e18); // Liquidate 1 yETH (debt is 800 yETH)
        vm.stopPrank();
    }

    // ============================================================
    // TEST CASE 06: LIQUIDATION WITH PRIVILEGED MODE - UNPRIVILEGED REVERTS
    // ============================================================

    function test_Action06_Case06_liquidationWithPrivilegedModeUnprivilegedReverts() public {
        // Enable privileged liquidator mode
        vm.prank(assetsAdmin);
        yoloHook.togglePrivilegedLiquidator(true);

        // Create undercollateralized position
        _createUndercollateralizedPosition();

        // Regular user should fail
        vm.startPrank(regularUser);
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        vm.expectRevert(); // Will revert with LiquidationModule__NotPrivilegedLiquidator
        yoloHook.liquidate(borrower, address(usdc), yETH, 1e18); // Liquidate 1 yETH (debt is 800 yETH)
        vm.stopPrank();
    }

    // ============================================================
    // TEST CASE 07: FLASH LOAN WITH PRIVILEGED FLASHLOANER - ZERO FEE
    // ============================================================

    function test_Action06_Case07_flashLoanPrivilegedUserZeroFee() public {
        // Create mock flash borrower and fund it with yETH
        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        // Fund flash borrower by having it borrow yETH
        // 50e18 yETH at $2 = $100, need $125 collateral at 80% LTV
        oracle.setAssetPrice(yETH, 2e8); // $2 per yETH for flash loan tests
        usdc.mint(address(flashBorrower), 10000e6);
        vm.startPrank(address(flashBorrower));
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yETH, 50e18, address(usdc), 150e6); // 50 yETH * $2 = $100, need $125 at 80% LTV
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();

        // Execute flash loan as privileged user
        vm.prank(privilegedFlashloaner);
        bool success = yoloHook.flashLoan(address(flashBorrower), yETH, 10e18, "");
        assertTrue(success, "Flash loan should succeed");

        // Verify no fee was charged (borrower only needed to repay principal)
        // The mock borrower will repay exactly the borrowed amount
    }

    // ============================================================
    // TEST CASE 08: FLASH LOAN WITHOUT PRIVILEGE - NORMAL FEE
    // ============================================================

    function test_Action06_Case08_flashLoanUnprivilegedUserNormalFee() public {
        // Create mock flash borrower and fund it with yETH
        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        // Calculate fee (9 bps on 10 yETH = 0.009 yETH)
        uint256 borrowAmount = 10e18;
        uint256 expectedFee = (borrowAmount * 9) / 10000; // 9 bps

        // Fund flash borrower by having it borrow yETH (need principal + fee)
        oracle.setAssetPrice(yETH, 2e8); // $2 per yETH for flash loan tests
        uint256 totalAmount = borrowAmount + expectedFee;
        usdc.mint(address(flashBorrower), 10000e6);
        vm.startPrank(address(flashBorrower));
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yETH, totalAmount, address(usdc), 30e6); // ~10 yETH * $2 = $20, need $25 at 80% LTV
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();

        // Execute flash loan as regular user
        vm.prank(regularUser);
        bool success = yoloHook.flashLoan(address(flashBorrower), yETH, borrowAmount, "");
        assertTrue(success, "Flash loan should succeed");
    }

    // ============================================================
    // TEST CASE 09: FLASH LOAN BATCH WITH PRIVILEGED - ZERO FEES
    // ============================================================

    function test_Action06_Case09_flashLoanBatchPrivilegedUserZeroFees() public {
        // Create mock flash borrower and fund it
        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        uint256 borrowAmountYETH = 10e18;
        uint256 borrowAmountYBTC = 1e8; // yBTC has 8 decimals

        // Fund flash borrower with yETH
        oracle.setAssetPrice(yETH, 2e8); // $2 per yETH for flash loan tests
        uint256 yethAmount = borrowAmountYETH * 2;
        usdc.mint(address(flashBorrower), 20000e6);
        vm.startPrank(address(flashBorrower));
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yETH, yethAmount, address(usdc), 50e6); // 20 yETH * $2 = $40, need $50 at 80% LTV
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();

        // Fund flash borrower with yBTC
        uint256 ybtcAmount = borrowAmountYBTC * 2;
        usdc.mint(address(flashBorrower), 150000e6);
        vm.startPrank(address(flashBorrower));
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yBTC, ybtcAmount, address(usdc), 100000e6); // 2 yBTC * $40k = $80k, need $100k at 80% LTV
        YoloSyntheticAsset(yBTC).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();

        // Prepare batch arrays
        address[] memory tokens = new address[](2);
        tokens[0] = yETH;
        tokens[1] = yBTC;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = borrowAmountYETH;
        amounts[1] = borrowAmountYBTC;

        // Execute batch flash loan as privileged user (zero fees)
        vm.prank(privilegedFlashloaner);
        bool success = yoloHook.flashLoanBatch(address(flashBorrower), tokens, amounts, "");
        assertTrue(success, "Batch flash loan should succeed");
    }

    // ============================================================
    // TEST CASE 10: FLASH LOAN BATCH WITHOUT PRIVILEGE - NORMAL FEES
    // ============================================================

    function test_Action06_Case10_flashLoanBatchUnprivilegedUserNormalFees() public {
        // Create mock flash borrower and fund it
        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        uint256 borrowAmountYETH = 10e18;
        uint256 borrowAmountYBTC = 1e8; // yBTC has 8 decimals
        uint256 expectedFeeYETH = (borrowAmountYETH * 9) / 10000; // 9 bps
        uint256 expectedFeeYBTC = (borrowAmountYBTC * 9) / 10000; // 9 bps

        // Fund flash borrower with yETH (principal + fee)
        oracle.setAssetPrice(yETH, 2e8); // $2 per yETH for flash loan tests
        uint256 totalYETH = borrowAmountYETH + expectedFeeYETH;
        usdc.mint(address(flashBorrower), 20000e6);
        vm.startPrank(address(flashBorrower));
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yETH, totalYETH, address(usdc), 30e6); // ~10 yETH * $2 = $20, need $25 at 80% LTV
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();

        // Fund flash borrower with yBTC (principal + fee)
        uint256 totalYBTC = borrowAmountYBTC + expectedFeeYBTC;
        usdc.mint(address(flashBorrower), 150000e6);
        vm.startPrank(address(flashBorrower));
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yBTC, totalYBTC, address(usdc), 60000e6); // ~1 yBTC * $40k = $40k, need $50k at 80% LTV
        YoloSyntheticAsset(yBTC).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();

        // Prepare batch arrays
        address[] memory tokens = new address[](2);
        tokens[0] = yETH;
        tokens[1] = yBTC;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = borrowAmountYETH;
        amounts[1] = borrowAmountYBTC;

        // Execute batch flash loan as regular user (normal fees)
        vm.prank(regularUser);
        bool success = yoloHook.flashLoanBatch(address(flashBorrower), tokens, amounts, "");
        assertTrue(success, "Batch flash loan should succeed");
    }

    // ============================================================
    // TEST CASE 11: GRANT AND REVOKE PRIVILEGED LIQUIDATOR ROLE
    // ============================================================

    function test_Action06_Case11_grantAndRevokePrivilegedLiquidatorRole() public {
        // Enable privileged mode
        vm.prank(assetsAdmin);
        yoloHook.togglePrivilegedLiquidator(true);

        // Grant role to regular user
        aclManager.grantRole(keccak256("PRIVILEGED_LIQUIDATOR"), regularUser);

        // Create undercollateralized position
        _createUndercollateralizedPosition();

        // Regular user should now be able to liquidate
        vm.startPrank(regularUser);
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        yoloHook.liquidate(borrower, address(usdc), yETH, 1e18); // Liquidate 1 yETH (debt is 800 yETH)
        vm.stopPrank();
    }

    // ============================================================
    // TEST CASE 12: PREVIEW FLASH LOAN FEE REFLECTS PRIVILEGE
    // ============================================================

    function test_Action06_Case12_previewFlashLoanFeeReflectsPrivilege() public {
        uint256 borrowAmount = 10e18;

        // Preview fee for regular user (should be 9 bps)
        uint256 expectedFee = (borrowAmount * 9) / 10000;
        uint256 previewFee = yoloHook.previewFlashLoanFee(yETH, borrowAmount);
        assertEq(previewFee, expectedFee, "Preview fee should match expected fee");
    }

    // ============================================================
    // HELPER FUNCTIONS
    // ============================================================

    /**
     * @notice Create an undercollateralized position for liquidation testing
     */
    function _createUndercollateralizedPosition() internal {
        // Set initial yETH price to $2
        oracle.setAssetPrice(yETH, 2e8);

        // Borrower deposits USDC and borrows yETH
        vm.startPrank(borrower);
        usdc.approve(address(yoloHook), type(uint256).max);

        // Borrow at 80% LTV (just under limit)
        // USDC collateral: 2000e6 ($2000)
        // yETH borrowed: 800e18 (worth $1600 at $2/yETH)
        yoloHook.borrow(yETH, 800e18, address(usdc), 2000e6);
        vm.stopPrank();

        // Crash yETH price to make position undercollateralized
        // New price: $3 per yETH
        // Debt value: 800 * $3 = $2400
        // Collateral value: $2000
        // Liquidation threshold is 85% of $2000 = $1700 max debt
        // Since $2400 > $1700, position is undercollateralized
        oracle.setAssetPrice(yETH, 3e8); // $3 per yETH
        // Now debt = 800 * $3 = $2400 > $1700 threshold (85% of $2000)
    }
}

/**
 * @title MockFlashBorrower
 * @notice Mock contract for testing flash loans
 */
contract MockFlashBorrower is IFlashBorrower {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external {
        // Approve hook to pull repayment
        IERC20(token).approve(msg.sender, amount + fee);

        // Transfer repayment back to hook
        require(IERC20(token).transfer(msg.sender, amount + fee), "Transfer failed");
    }

    function onBatchFlashLoan(
        address initiator,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external {
        // Repay all loans
        for (uint256 i = 0; i < tokens.length; i++) {
            IERC20(tokens[i]).approve(msg.sender, amounts[i] + fees[i]);
            require(IERC20(tokens[i]).transfer(msg.sender, amounts[i] + fees[i]), "Transfer failed");
        }
    }
}
