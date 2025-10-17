// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base02_DeployYoloHook} from "./base/Base02_DeployYoloHook.t.sol";
import {YoloHook} from "../src/core/YoloHook.sol";
import {YoloHookStorage} from "../src/core/YoloHookStorage.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {IFlashBorrower} from "../src/interfaces/IFlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestAction05_FlashLoans
 * @notice Comprehensive test suite for flash loan operations
 * @dev Tests single and batch flash loans, fee calculations, and edge cases
 */
contract TestAction05_FlashLoans is Base02_DeployYoloHook {
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
    address public flashLoanUser = makeAddr("flashLoanUser");

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
        aclManager.grantRole(keccak256("ASSETS_ADMIN"), assetsAdmin);
        aclManager.grantRole(keccak256("RISK_ADMIN"), riskAdmin);

        // Deploy synthetic asset implementation
        syntheticAssetImpl = new YoloSyntheticAsset();

        // Set up oracle prices
        oracle.setAssetPrice(address(weth), 2000e8); // $2000 per ETH
        oracle.setAssetPrice(address(wbtc), 40000e8); // $40000 per BTC
        oracle.setAssetPrice(address(usdc), 1e8); // $1 per USDC
        oracle.setAssetPrice(usy, 1e8); // $1 per USY

        // Create synthetic assets
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

        // Set oracle prices for synthetic assets
        oracle.setAssetPrice(yETH, 2000e8); // $2000 per yETH
        oracle.setAssetPrice(yBTC, 40000e8); // $40000 per yBTC

        // Whitelist USDC as collateral
        vm.prank(assetsAdmin);
        yoloHook.whitelistCollateral(address(usdc));

        // Configure lending pairs
        vm.startPrank(assetsAdmin);
        yoloHook.configureLendingPair(
            yETH,
            address(usdc),
            address(0),
            address(0),
            8000, // 80% LTV
            8500,
            500,
            500,
            300,
            type(uint256).max,
            type(uint256).max,
            1e18,
            false,
            0
        );

        yoloHook.configureLendingPair(
            yBTC,
            address(usdc),
            address(0),
            address(0),
            8000,
            8500,
            500,
            500,
            300,
            type(uint256).max,
            type(uint256).max,
            1e8, // 8 decimals
            false,
            0
        );
        vm.stopPrank();

        // Fund test accounts
        usdc.mint(flashLoanUser, 1000000e6);
    }

    // ============================================================
    // TEST CASE 01: SINGLE ASSET FLASH LOAN SUCCESS
    // ============================================================

    function test_Action05_Case01_singleAssetFlashLoanSuccess() public {
        // Create flash borrower and fund it
        MockFlashBorrower flashBorrower = new MockFlashBorrower();
        _fundFlashBorrowerWithYETH(address(flashBorrower), 50e18);

        uint256 borrowAmount = 10e18;
        uint256 expectedFee = (borrowAmount * 9) / 10000; // 9 bps

        // Execute flash loan
        vm.prank(flashLoanUser);
        bool success = yoloHook.flashLoan(address(flashBorrower), yETH, borrowAmount, "");
        assertTrue(success, "Flash loan should succeed");

        // Verify callback was called (implicitly tested by successful repayment)
    }

    // ============================================================
    // TEST CASE 02: FLASH LOAN FEE CALCULATION
    // ============================================================

    function test_Action05_Case02_flashLoanFeeCalculation() public {
        uint256 borrowAmount = 100e18;
        uint256 expectedFee = (borrowAmount * 9) / 10000; // 9 bps = 0.09 yETH

        uint256 actualFee = yoloHook.previewFlashLoanFee(yETH, borrowAmount);
        assertEq(actualFee, expectedFee, "Fee calculation should match");
    }

    // ============================================================
    // TEST CASE 03: FLASH LOAN WITH ZERO AMOUNT REVERTS
    // ============================================================

    function test_Action05_Case03_flashLoanWithZeroAmountReverts() public {
        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        vm.prank(flashLoanUser);
        vm.expectRevert(); // FlashLoanModule__InvalidAmount
        yoloHook.flashLoan(address(flashBorrower), yETH, 0, "");
    }

    // ============================================================
    // TEST CASE 04: FLASH LOAN WITH INVALID ASSET REVERTS
    // ============================================================

    function test_Action05_Case04_flashLoanWithInvalidAssetReverts() public {
        MockFlashBorrower flashBorrower = new MockFlashBorrower();
        address fakeAsset = makeAddr("fakeAsset");

        vm.prank(flashLoanUser);
        vm.expectRevert(); // FlashLoanModule__InvalidAsset
        yoloHook.flashLoan(address(flashBorrower), fakeAsset, 10e18, "");
    }

    // ============================================================
    // TEST CASE 05: FLASH LOAN WITH INVALID BORROWER REVERTS
    // ============================================================

    function test_Action05_Case05_flashLoanWithInvalidBorrowerReverts() public {
        vm.prank(flashLoanUser);
        vm.expectRevert(); // FlashLoanModule__InvalidBorrower
        yoloHook.flashLoan(address(0), yETH, 10e18, "");
    }

    // ============================================================
    // TEST CASE 06: FLASH LOAN EXCEEDS CAP REVERTS
    // ============================================================

    function test_Action05_Case06_flashLoanExceedsCapReverts() public {
        // Set flash loan cap to 5 yETH
        vm.prank(riskAdmin);
        yoloHook.updateMaxFlashLoanAmount(yETH, 5e18);

        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        // Try to borrow 10 yETH (exceeds cap)
        vm.prank(flashLoanUser);
        vm.expectRevert(); // FlashLoanModule__ExceedsMaxFlashLoan
        yoloHook.flashLoan(address(flashBorrower), yETH, 10e18, "");
    }

    // ============================================================
    // TEST CASE 07: FLASH LOAN DISABLED (CAP = 0) REVERTS
    // ============================================================

    function test_Action05_Case07_flashLoanDisabledReverts() public {
        // Disable flash loans for yETH
        vm.prank(riskAdmin);
        yoloHook.updateMaxFlashLoanAmount(yETH, 0);

        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        // Try to borrow (should fail)
        vm.prank(flashLoanUser);
        vm.expectRevert(); // FlashLoanModule__FlashLoansDisabled
        yoloHook.flashLoan(address(flashBorrower), yETH, 1e18, "");
    }

    // ============================================================
    // TEST CASE 08: FLASH LOAN INSUFFICIENT REPAYMENT REVERTS
    // ============================================================

    function test_Action05_Case08_flashLoanInsufficientRepaymentReverts() public {
        // Create malicious borrower that doesn't repay
        MaliciousFlashBorrower maliciousBorrower = new MaliciousFlashBorrower();
        _fundFlashBorrowerWithYETH(address(maliciousBorrower), 50e18);

        vm.prank(flashLoanUser);
        vm.expectRevert(); // FlashLoanModule__InsufficientRepayment
        yoloHook.flashLoan(address(maliciousBorrower), yETH, 10e18, "");
    }

    // ============================================================
    // TEST CASE 09: BATCH FLASH LOAN SUCCESS
    // ============================================================

    function test_Action05_Case09_batchFlashLoanSuccess() public {
        // Create flash borrower and fund it
        MockFlashBorrower flashBorrower = new MockFlashBorrower();
        _fundFlashBorrowerWithYETH(address(flashBorrower), 50e18);
        _fundFlashBorrowerWithYBTC(address(flashBorrower), 5e8);

        uint256 borrowAmountYETH = 10e18;
        uint256 borrowAmountYBTC = 1e8;
        uint256 expectedFeeYETH = (borrowAmountYETH * 9) / 10000;
        uint256 expectedFeeYBTC = (borrowAmountYBTC * 9) / 10000;

        // Prepare batch arrays
        address[] memory tokens = new address[](2);
        tokens[0] = yETH;
        tokens[1] = yBTC;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = borrowAmountYETH;
        amounts[1] = borrowAmountYBTC;

        // Execute batch flash loan
        vm.prank(flashLoanUser);
        bool success = yoloHook.flashLoanBatch(address(flashBorrower), tokens, amounts, "");
        assertTrue(success, "Batch flash loan should succeed");
    }

    // ============================================================
    // TEST CASE 10: BATCH FLASH LOAN WITH EMPTY ARRAY REVERTS
    // ============================================================

    function test_Action05_Case10_batchFlashLoanWithEmptyArrayReverts() public {
        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);

        vm.prank(flashLoanUser);
        vm.expectRevert(); // FlashLoanModule__InvalidArrayLength
        yoloHook.flashLoanBatch(address(flashBorrower), tokens, amounts, "");
    }

    // ============================================================
    // TEST CASE 11: BATCH FLASH LOAN WITH MISMATCHED ARRAYS REVERTS
    // ============================================================

    function test_Action05_Case11_batchFlashLoanWithMismatchedArraysReverts() public {
        MockFlashBorrower flashBorrower = new MockFlashBorrower();

        address[] memory tokens = new address[](2);
        tokens[0] = yETH;
        tokens[1] = yBTC;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10e18;

        vm.prank(flashLoanUser);
        vm.expectRevert(); // FlashLoanModule__InvalidArrayLength
        yoloHook.flashLoanBatch(address(flashBorrower), tokens, amounts, "");
    }

    // ============================================================
    // TEST CASE 12: UPDATE FLASH LOAN FEE
    // ============================================================

    function test_Action05_Case12_updateFlashLoanFee() public {
        // Update fee to 20 bps
        vm.prank(riskAdmin);
        yoloHook.updateFlashLoanFee(20);

        // Verify new fee
        uint256 borrowAmount = 100e18;
        uint256 expectedFee = (borrowAmount * 20) / 10000; // 20 bps

        uint256 actualFee = yoloHook.previewFlashLoanFee(yETH, borrowAmount);
        assertEq(actualFee, expectedFee, "Fee should be updated to 20 bps");
    }

    // ============================================================
    // TEST CASE 13: ONLY RISK ADMIN CAN UPDATE FLASH LOAN FEE
    // ============================================================

    function test_Action05_Case13_onlyRiskAdminCanUpdateFlashLoanFee() public {
        vm.prank(flashLoanUser);
        vm.expectRevert(YoloHook.YoloHook__CallerNotAuthorized.selector);
        yoloHook.updateFlashLoanFee(20);
    }

    // ============================================================
    // TEST CASE 14: UPDATE MAX FLASH LOAN AMOUNT
    // ============================================================

    function test_Action05_Case14_updateMaxFlashLoanAmount() public {
        // Update max to 100 yETH
        vm.prank(riskAdmin);
        yoloHook.updateMaxFlashLoanAmount(yETH, 100e18);

        // Verify new max
        uint256 newMax = yoloHook.maxFlashLoan(yETH);
        assertEq(newMax, 100e18, "Max flash loan should be updated to 100 yETH");
    }

    // ============================================================
    // TEST CASE 15: ONLY RISK ADMIN CAN UPDATE MAX FLASH LOAN AMOUNT
    // ============================================================

    function test_Action05_Case15_onlyRiskAdminCanUpdateMaxFlashLoanAmount() public {
        vm.prank(flashLoanUser);
        vm.expectRevert(YoloHook.YoloHook__CallerNotAuthorized.selector);
        yoloHook.updateMaxFlashLoanAmount(yETH, 100e18);
    }

    // ============================================================
    // TEST CASE 16: MAX FLASH LOAN FOR INACTIVE ASSET RETURNS ZERO
    // ============================================================

    function test_Action05_Case16_maxFlashLoanForInactiveAssetReturnsZero() public {
        // Deactivate yETH
        vm.prank(assetsAdmin);
        yoloHook.deactivateSyntheticAsset(yETH);

        // Check max flash loan
        uint256 max = yoloHook.maxFlashLoan(yETH);
        assertEq(max, 0, "Inactive asset should have zero max flash loan");
    }

    // ============================================================
    // TEST CASE 17: MAX FLASH LOAN FOR NON-YOLO ASSET RETURNS ZERO
    // ============================================================

    function test_Action05_Case17_maxFlashLoanForNonYoloAssetReturnsZero() public {
        address fakeAsset = makeAddr("fakeAsset");

        uint256 max = yoloHook.maxFlashLoan(fakeAsset);
        assertEq(max, 0, "Non-YOLO asset should have zero max flash loan");
    }

    // ============================================================
    // TEST CASE 18: FLASH LOAN WITH CUSTOM DATA
    // ============================================================

    function test_Action05_Case18_flashLoanWithCustomData() public {
        // Create flash borrower that uses custom data
        DataAwareFlashBorrower dataBorrower = new DataAwareFlashBorrower();
        _fundFlashBorrowerWithYETH(address(dataBorrower), 50e18);

        bytes memory customData = abi.encode(uint256(12345), address(this));

        vm.prank(flashLoanUser);
        bool success = yoloHook.flashLoan(address(dataBorrower), yETH, 10e18, customData);
        assertTrue(success, "Flash loan with custom data should succeed");

        // Verify custom data was received
        assertEq(dataBorrower.receivedNumber(), 12345, "Custom number should match");
        assertEq(dataBorrower.receivedAddress(), address(this), "Custom address should match");
    }

    // ============================================================
    // TEST CASE 19: FLASH LOAN FEE SENT TO TREASURY
    // ============================================================

    function test_Action05_Case19_flashLoanFeeSentToTreasury() public {
        // Create flash borrower
        MockFlashBorrower flashBorrower = new MockFlashBorrower();
        _fundFlashBorrowerWithYETH(address(flashBorrower), 50e18);

        uint256 borrowAmount = 10e18;
        uint256 expectedFee = (borrowAmount * 9) / 10000;

        // Get treasury balance before
        uint256 treasuryBalanceBefore = YoloSyntheticAsset(yETH).balanceOf(treasury);

        // Execute flash loan
        vm.prank(flashLoanUser);
        yoloHook.flashLoan(address(flashBorrower), yETH, borrowAmount, "");

        // Verify treasury received fee
        uint256 treasuryBalanceAfter = YoloSyntheticAsset(yETH).balanceOf(treasury);
        assertEq(treasuryBalanceAfter - treasuryBalanceBefore, expectedFee, "Treasury should receive flash loan fee");
    }

    // ============================================================
    // TEST CASE 20: FLASH LOAN EVENT EMISSION
    // ============================================================

    function test_Action05_Case20_flashLoanEventEmission() public {
        // Create flash borrower
        MockFlashBorrower flashBorrower = new MockFlashBorrower();
        _fundFlashBorrowerWithYETH(address(flashBorrower), 50e18);

        uint256 borrowAmount = 10e18;

        // Prepare expected event data
        address[] memory expectedTokens = new address[](1);
        expectedTokens[0] = yETH;

        uint256[] memory expectedAmounts = new uint256[](1);
        expectedAmounts[0] = borrowAmount;

        uint256[] memory expectedFees = new uint256[](1);
        expectedFees[0] = (borrowAmount * 9) / 10000;

        // Expect FlashLoanExecuted event
        vm.expectEmit(true, true, false, true);
        emit YoloHookStorage.FlashLoanExecuted(
            address(flashBorrower), flashLoanUser, expectedTokens, expectedAmounts, expectedFees
        );

        // Execute flash loan
        vm.prank(flashLoanUser);
        yoloHook.flashLoan(address(flashBorrower), yETH, borrowAmount, "");
    }

    // ============================================================
    // HELPER FUNCTIONS
    // ============================================================

    function _fundFlashBorrowerWithYETH(address borrower, uint256 amount) internal {
        usdc.mint(borrower, 200000e6); // Generous amount for flash loan tests
        vm.startPrank(borrower);
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yETH, amount, address(usdc), 160000e6); // 50 yETH * $2000 = $100k, need $125k at 80% LTV
        YoloSyntheticAsset(yETH).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();
    }

    function _fundFlashBorrowerWithYBTC(address borrower, uint256 amount) internal {
        usdc.mint(borrower, 400000e6); // Generous amount for flash loan tests
        vm.startPrank(borrower);
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yBTC, amount, address(usdc), 320000e6); // 5 yBTC * $40k = $200k, need $250k at 80% LTV
        YoloSyntheticAsset(yBTC).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();
    }
}

// ============================================================
// MOCK CONTRACTS
// ============================================================

/**
 * @title MockFlashBorrower
 * @notice Standard flash borrower that repays correctly
 */
contract MockFlashBorrower is IFlashBorrower {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external {
        // Approve and transfer repayment
        IERC20(token).approve(msg.sender, amount + fee);
        IERC20(token).transfer(msg.sender, amount + fee);
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
            IERC20(tokens[i]).transfer(msg.sender, amounts[i] + fees[i]);
        }
    }
}

/**
 * @title MaliciousFlashBorrower
 * @notice Flash borrower that doesn't repay (for testing)
 */
contract MaliciousFlashBorrower is IFlashBorrower {
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external {
        // Don't repay - keep the tokens
    }

    function onBatchFlashLoan(
        address initiator,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external {
        // Don't repay - keep the tokens
    }
}

/**
 * @title DataAwareFlashBorrower
 * @notice Flash borrower that uses custom data
 */
contract DataAwareFlashBorrower is IFlashBorrower {
    uint256 public receivedNumber;
    address public receivedAddress;

    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external {
        // Decode custom data
        (receivedNumber, receivedAddress) = abi.decode(data, (uint256, address));

        // Approve and transfer repayment
        IERC20(token).approve(msg.sender, amount + fee);
        IERC20(token).transfer(msg.sender, amount + fee);
    }

    function onBatchFlashLoan(
        address initiator,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external {
        // Not implemented for this test
    }
}
