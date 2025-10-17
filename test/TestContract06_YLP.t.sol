// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base02_DeployYoloHook} from "./base/Base02_DeployYoloHook.t.sol";
import {YLP} from "../src/tokenization/YLP.sol";
import {IYLPVault} from "../src/interfaces/IYLPVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestContract06_YLP
 * @notice Comprehensive unit tests for YLP vault functionality
 */
contract TestContract06_YLP is Base02_DeployYoloHook {
    YLP public ylp;
    address public solver;
    address public riskAdmin;
    address public user1;
    address public user2;

    function setUp() public virtual override {
        super.setUp();
        ylp = YLP(ylpVault);

        // Setup test accounts
        solver = makeAddr("solver");
        riskAdmin = makeAddr("riskAdmin");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");

        // Create roles first, then grant them
        aclManager.createRole("YLP_SOLVER", bytes32(0));
        aclManager.createRole("RISK_ADMIN", bytes32(0));
        aclManager.grantRole(ylp.YLP_SOLVER_ROLE(), solver);
        aclManager.grantRole(ylp.RISK_ADMIN_ROLE(), riskAdmin);

        // Set minBlockLag to 0 for easier testing
        vm.prank(riskAdmin);
        ylp.setMinBlockLag(0);

        // Mint USY to users for testing
        deal(usy, user1, 10_000e18);
        deal(usy, user2, 10_000e18);
    }

    // ============================================================
    // INITIALIZATION TESTS
    // ============================================================

    function test_Contract06_Case01_initialization() public view {
        assertEq(address(ylp.asset()), usy, "Asset should be USY");
        assertEq(ylp.name(), "YOLO Counterparty LP Token");
        assertEq(ylp.symbol(), "YLP");
        assertEq(ylp.decimals(), 18);
    }

    // ============================================================
    // ADMIN FUNCTION TESTS
    // ============================================================

    function test_Contract06_Case02_setMinDepositAmount() public {
        vm.prank(riskAdmin);
        ylp.setMinDepositAmount(100e18);

        // Try depositing below minimum
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 50e18);
        vm.expectRevert(YLP.YLP__DepositBelowMinimum.selector);
        ylp.requestDeposit(50e18, 0, 500);
        vm.stopPrank();
    }

    function test_Contract06_Case03_setMaxDepositAmount() public {
        vm.prank(riskAdmin);
        ylp.setMaxDepositAmount(1000e18);

        // Try depositing above maximum
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 2000e18);
        vm.expectRevert(YLP.YLP__DepositAboveMaximum.selector);
        ylp.requestDeposit(2000e18, 0, 500);
        vm.stopPrank();
    }

    function test_Contract06_Case04_setWithdrawalFeeBps() public {
        vm.prank(riskAdmin);
        ylp.setWithdrawalFeeBps(50); // 0.5% fee

        // Fee is applied during executeWithdrawals
        // Will be tested in withdrawal execution tests
    }

    function test_Contract06_Case05_setRiskParameters() public {
        vm.startPrank(riskAdmin);
        ylp.setMaxAbsPnLBps(5000); // 50%
        ylp.setMaxRateChangeBps(2000); // 20%
        ylp.setAutoPauseLossBps(4000); // 40%
        ylp.setMinEpochBlocks(10);
        ylp.setMinBlockLag(2);
        ylp.setMaxBatchSize(128);
        vm.stopPrank();
    }

    function test_Contract06_Case06_setDepositsPaused() public {
        vm.prank(riskAdmin);
        ylp.setDepositsPaused(true);

        // Try depositing while paused
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        vm.expectRevert(YLP.YLP__DepositsPaused.selector);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();

        // Withdrawals should still work
        // (will be tested in withdrawal tests)
    }

    function test_Contract06_Case07_adminFunctionsRevertIfNotRiskAdmin() public {
        vm.startPrank(user1);
        vm.expectRevert(YLP.YLP__CallerNotAuthorized.selector);
        ylp.setMinDepositAmount(100e18);

        vm.expectRevert(YLP.YLP__CallerNotAuthorized.selector);
        ylp.setMaxAbsPnLBps(5000);
        vm.stopPrank();
    }

    // ============================================================
    // DEPOSIT REQUEST TESTS
    // ============================================================

    function test_Contract06_Case08_requestDeposit() public {
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);

        vm.expectEmit(true, true, false, true);
        emit IYLPVault.DepositRequested(0, user1, 1000e18, 900e18, block.number);

        uint256 requestId = ylp.requestDeposit(1000e18, 900e18, 500); // 5% max slippage

        assertEq(requestId, 0, "First request ID should be 0");

        IYLPVault.DepositRequest memory req = ylp.getDepositRequest(requestId);
        assertEq(req.user, user1);
        assertEq(req.usyAmount, 1000e18);
        assertEq(req.minYLPShares, 900e18);
        assertEq(req.maxSlippageBps, 500);
        assertEq(req.requestBlock, block.number);
        assertFalse(req.executed);

        vm.stopPrank();
    }

    function test_Contract06_Case09_requestDepositRevertIfZeroAmount() public {
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        vm.expectRevert(YLP.YLP__ZeroAmount.selector);
        ylp.requestDeposit(0, 0, 500);
        vm.stopPrank();
    }

    function test_Contract06_Case10_requestDepositTransfersUSYToVault() public {
        uint256 vaultBalanceBefore = IERC20(usy).balanceOf(address(ylp));
        uint256 user1BalanceBefore = IERC20(usy).balanceOf(user1);

        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();

        assertEq(IERC20(usy).balanceOf(address(ylp)), vaultBalanceBefore + 1000e18);
        assertEq(IERC20(usy).balanceOf(user1), user1BalanceBefore - 1000e18);
    }

    // ============================================================
    // WITHDRAWAL REQUEST TESTS
    // ============================================================

    function test_Contract06_Case11_requestWithdrawalWorksWhenDepositsPaused() public {
        // First, get some YLP shares by depositing and executing
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();

        // Seal epoch and execute
        vm.roll(block.number + 10);
        vm.startPrank(solver);
        ylp.sealEpoch(0, block.number);
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 0;
        ylp.executeDeposits(requestIds);
        vm.stopPrank();

        // Pause deposits
        vm.prank(riskAdmin);
        ylp.setDepositsPaused(true);

        // Withdrawal should still work
        uint256 shares = ylp.balanceOf(user1);
        vm.startPrank(user1);
        ylp.approve(address(ylp), shares);
        uint256 requestId = ylp.requestWithdrawal(shares, 0, 500);
        assertEq(requestId, 0, "First withdrawal request ID should be 0");
        vm.stopPrank();
    }

    function test_Contract06_Case12_requestWithdrawalRevertIfZeroAmount() public {
        vm.startPrank(user1);
        vm.expectRevert(YLP.YLP__ZeroAmount.selector);
        ylp.requestWithdrawal(0, 0, 500);
        vm.stopPrank();
    }

    // ============================================================
    // SEAL EPOCH TESTS
    // ============================================================

    function test_Contract06_Case13_sealEpochFirstEpoch() public {
        // Add some USY to vault
        deal(usy, address(ylp), 10_000e18);

        vm.roll(block.number + 10);

        vm.startPrank(solver);
        vm.expectEmit(true, false, false, false);
        emit IYLPVault.EpochSealed(1, 10_000e18, 1e27, block.number, 0, block.timestamp, solver);

        (uint256 epochId, uint256 navUSY, uint256 pricePerShareRay) = ylp.sealEpoch(0, block.number);

        assertEq(epochId, 1);
        assertEq(navUSY, 10_000e18); // balance + 0 unrealizedPnL
        assertEq(pricePerShareRay, 1e27); // 1:1 ratio (no supply yet)
        vm.stopPrank();

        // Check snapshot
        (uint256 snapEpochId, uint256 snapNavUSY, uint256 snapPpsRay, uint256 snapTimestamp) = ylp.getLastSnapshot();
        assertEq(snapEpochId, 1);
        assertEq(snapNavUSY, 10_000e18);
        assertEq(snapPpsRay, 1e27);
    }

    function test_Contract06_Case14_sealEpochWithPositiveUnrealizedPnL() public {
        deal(usy, address(ylp), 10_000e18);
        vm.roll(block.number + 10);

        vm.prank(solver);
        (uint256 epochId, uint256 navUSY, uint256 pricePerShareRay) = ylp.sealEpoch(1000e18, block.number); // +1000 USY unrealized profit

        assertEq(navUSY, 11_000e18); // 10_000 + 1000
        assertEq(pricePerShareRay, 1e27); // No shares yet
    }

    function test_Contract06_Case15_sealEpochWithNegativeUnrealizedPnL() public {
        deal(usy, address(ylp), 10_000e18);
        vm.roll(block.number + 10);

        vm.prank(solver);
        (uint256 epochId, uint256 navUSY, uint256 pricePerShareRay) = ylp.sealEpoch(-1000e18, block.number); // -1000 USY unrealized loss

        assertEq(navUSY, 9_000e18); // 10_000 - 1000
    }

    function test_Contract06_Case16_sealEpochRevertIfNegativeNAV() public {
        deal(usy, address(ylp), 100e18);
        vm.roll(block.number + 10);

        // Set maxAbsPnLBps to 100% to allow testing edge case
        vm.prank(riskAdmin);
        ylp.setMaxAbsPnLBps(10000); // 100% - allow full balance loss

        // With balance = 100e18 and maxAbsPnLBps = 100%:
        // Max allowed |PnL| = 100e18
        // Use unrealizedPnL = -100e18 → NAV = 0 (triggers NegativeNAV check: navSigned <= 0)
        vm.prank(solver);
        vm.expectRevert(YLP.YLP__NegativeNAV.selector);
        ylp.sealEpoch(-100e18, block.number); // 100 - 100 = 0 (zero NAV triggers revert)
    }

    function test_Contract06_Case17_sealEpochRevertIfPnLExceedsBounds() public {
        deal(usy, address(ylp), 10_000e18);
        vm.roll(block.number + 10);

        // Default maxAbsPnLBps is 4000 (40%)
        // Max allowed PnL = 10_000 * 0.4 = 4000

        vm.prank(solver);
        vm.expectRevert(YLP.YLP__PnLExceedsBounds.selector);
        ylp.sealEpoch(5000e18, block.number); // Exceeds 40%
    }

    function test_Contract06_Case18_sealEpochRevertIfPnLChangedTooFast() public {
        deal(usy, address(ylp), 10_000e18);

        // Seal first epoch with +1000 PnL
        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(1000e18, block.number);

        // Try to seal second epoch with +3000 PnL (change of 2000)
        // Default maxRateChangeBps is 1500 (15%)
        // Max allowed change = 10_000 * 0.15 = 1500
        vm.roll(block.number + 20);
        vm.prank(solver);
        vm.expectRevert(YLP.YLP__PnLChangedTooFast.selector);
        ylp.sealEpoch(3000e18, block.number); // Change of 2000 exceeds 1500
    }

    function test_Contract06_Case19_sealEpochAutoPauseOnExtremeLoss() public {
        deal(usy, address(ylp), 10_000e18);
        vm.roll(block.number + 10);

        // Default autoPauseLossBps is 3500 (35%)
        // Threshold = -3500 USY
        vm.prank(solver);
        ylp.sealEpoch(-3600e18, block.number); // Exceeds auto-pause threshold

        // Deposits should be paused
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        vm.expectRevert(YLP.YLP__DepositsPaused.selector);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();
    }

    function test_Contract06_Case20_sealEpochRevertIfNotSolver() public {
        vm.prank(user1);
        vm.expectRevert(YLP.YLP__NotYLPSolver.selector);
        ylp.sealEpoch(0, block.number);
    }

    function test_Contract06_Case21_sealEpochRevertIfSnapshotTooOld() public {
        deal(usy, address(ylp), 10_000e18);
        vm.roll(block.number + 10);

        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        // Try to seal with same or earlier block
        vm.roll(block.number + 5);
        vm.prank(solver);
        vm.expectRevert(YLP.YLP__SnapshotTooOld.selector);
        ylp.sealEpoch(0, block.number - 7); // Earlier than previous snapshot
    }

    // ============================================================
    // EXECUTE DEPOSITS TESTS
    // ============================================================

    function test_Contract06_Case22_executeDepositsSingleRequest() public {
        // User requests deposit
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();

        // Seal epoch
        deal(usy, address(ylp), 1000e18);
        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        // Execute deposit
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 0;

        vm.prank(solver);
        vm.expectEmit(true, true, false, true);
        emit IYLPVault.DepositExecuted(0, user1, 1000e18, 1000e18);
        ylp.executeDeposits(requestIds);

        // Verify shares minted
        assertEq(ylp.balanceOf(user1), 1000e18);

        // Verify request marked as executed
        IYLPVault.DepositRequest memory req = ylp.getDepositRequest(0);
        assertTrue(req.executed);
    }

    function test_Contract06_Case23_executeDepositsMultipleRequests() public {
        // User1 and User2 request deposits
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();

        vm.startPrank(user2);
        IERC20(usy).approve(address(ylp), 2000e18);
        ylp.requestDeposit(2000e18, 0, 500);
        vm.stopPrank();

        // Seal epoch
        deal(usy, address(ylp), 3000e18);
        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        // Execute deposits
        uint256[] memory requestIds = new uint256[](2);
        requestIds[0] = 0;
        requestIds[1] = 1;

        vm.prank(solver);
        ylp.executeDeposits(requestIds);

        assertEq(ylp.balanceOf(user1), 1000e18);
        assertEq(ylp.balanceOf(user2), 2000e18);
    }

    function test_Contract06_Case24_executeDepositsRefundOnSlippageTooHigh() public {
        // User requests deposit with strict slippage
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        ylp.requestDeposit(1000e18, 1000e18, 10); // Expects exactly 1000 shares, max 0.1% slippage
        vm.stopPrank();

        // Create existing position to make PPS > 1
        // Mint 2000 shares to make PPS = 2 (need NAV = 2000, supply = 1000 to get PPS = 2)
        deal(usy, address(ylp), 2000e18); // NAV will be 2000
        vm.prank(address(yoloHook));
        ylp.mint(address(this), 1000e18); // Supply = 1000

        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number); // NAV = 3000 (2000 existing + 1000 from request), Supply = 1000, PPS = 3

        // With PPS = 3:
        // User depositing 1000 USY would get: 1000 / 3 = 333.33 shares
        // User expects 1000 shares (minYLPShares = 1000)
        // Slippage: (1000 - 333) / 1000 = 66.7% > 0.1% max → REFUND

        // Execute deposit - should refund due to slippage
        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 0;

        uint256 user1BalanceBefore = IERC20(usy).balanceOf(user1);

        vm.prank(solver);
        vm.expectEmit(true, true, false, true);
        emit IYLPVault.DepositRefunded(0, user1, 1000e18, "Slippage or zero shares");
        ylp.executeDeposits(requestIds);

        // Verify USY refunded
        assertEq(IERC20(usy).balanceOf(user1), user1BalanceBefore + 1000e18);
        assertEq(ylp.balanceOf(user1), 0);
    }

    function test_Contract06_Case25_executeDepositsRevertIfNotSealed() public {
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();

        uint256[] memory requestIds = new uint256[](1);
        requestIds[0] = 0;

        vm.prank(solver);
        vm.expectRevert(YLP.YLP__EpochNotSealed.selector);
        ylp.executeDeposits(requestIds);
    }

    function test_Contract06_Case26_executeDepositsRevertIfBatchTooLarge() public {
        // Set max batch size to 2
        vm.prank(riskAdmin);
        ylp.setMaxBatchSize(2);

        // Try to execute 3 requests
        uint256[] memory requestIds = new uint256[](3);
        requestIds[0] = 0;
        requestIds[1] = 1;
        requestIds[2] = 2;

        deal(usy, address(ylp), 1000e18);
        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        vm.prank(solver);
        vm.expectRevert(YLP.YLP__BatchSizeTooLarge.selector);
        ylp.executeDeposits(requestIds);
    }

    // ============================================================
    // EXECUTE WITHDRAWALS TESTS
    // ============================================================

    function test_Contract06_Case27_executeWithdrawalsSingleRequest() public {
        // Setup: User deposits and gets shares
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();

        deal(usy, address(ylp), 1000e18);
        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        // User requests withdrawal
        vm.roll(block.number + 20);
        uint256 shares = ylp.balanceOf(user1);
        vm.startPrank(user1);
        ylp.approve(address(ylp), shares);
        ylp.requestWithdrawal(shares, 0, 500);
        vm.stopPrank();

        // Seal next epoch
        vm.roll(block.number + 30);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        // Execute withdrawal
        uint256[] memory withdrawalIds = new uint256[](1);
        withdrawalIds[0] = 0;

        uint256 user1BalanceBefore = IERC20(usy).balanceOf(user1);

        vm.prank(solver);
        vm.expectEmit(true, true, false, false);
        emit IYLPVault.WithdrawalExecuted(0, user1, shares, 1000e18, 0);
        ylp.executeWithdrawals(withdrawalIds);

        // Verify USY returned
        assertEq(IERC20(usy).balanceOf(user1), user1BalanceBefore + 1000e18);
        assertEq(ylp.balanceOf(user1), 0);
    }

    function test_Contract06_Case28_executeWithdrawalsWithFee() public {
        // Setup: User deposits
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        ylp.requestDeposit(1000e18, 0, 500);
        vm.stopPrank();

        deal(usy, address(ylp), 1000e18);
        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        uint256[] memory depositIds = new uint256[](1);
        depositIds[0] = 0;
        vm.prank(solver);
        ylp.executeDeposits(depositIds);

        // Set withdrawal fee to 1%
        vm.prank(riskAdmin);
        ylp.setWithdrawalFeeBps(100); // 1%

        // User requests withdrawal
        vm.roll(block.number + 20);
        uint256 shares = ylp.balanceOf(user1);
        vm.startPrank(user1);
        ylp.approve(address(ylp), shares);
        ylp.requestWithdrawal(shares, 0, 500);
        vm.stopPrank();

        // Seal next epoch
        vm.roll(block.number + 30);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        // Execute withdrawal
        uint256[] memory withdrawalIds = new uint256[](1);
        withdrawalIds[0] = 0;

        uint256 user1BalanceBefore = IERC20(usy).balanceOf(user1);

        vm.prank(solver);
        ylp.executeWithdrawals(withdrawalIds);

        // Verify USY returned minus 1% fee
        uint256 expectedUSY = 1000e18 * 99 / 100; // 990 USY
        assertEq(IERC20(usy).balanceOf(user1), user1BalanceBefore + expectedUSY);
    }

    // ============================================================
    // SETTLEMENT TESTS
    // ============================================================

    function test_Contract06_Case29_settlePnLPositivePnL() public {
        // Fund vault
        deal(usy, address(ylp), 10_000e18);

        uint256 user1BalanceBefore = IERC20(usy).balanceOf(user1);

        // Hook settles positive PnL (user profit, YLP pays)
        vm.prank(address(yoloHook));
        ylp.settlePnL(user1, address(0x1), 1000e18);

        assertEq(IERC20(usy).balanceOf(user1), user1BalanceBefore + 1000e18);
        assertEq(IERC20(usy).balanceOf(address(ylp)), 9_000e18);
    }

    function test_Contract06_Case30_settlePnLNegativePnL() public {
        // Fund vault
        deal(usy, address(ylp), 10_000e18);

        uint256 vaultBalanceBefore = IERC20(usy).balanceOf(address(ylp));

        // Hook settles negative PnL (user loss, YLP receives)
        // USY already minted to vault by hook before calling settlePnL
        deal(usy, address(ylp), 11_000e18);

        vm.prank(address(yoloHook));
        ylp.settlePnL(user1, address(0x1), -1000e18);

        // No transfer happens, just event emitted
        assertEq(IERC20(usy).balanceOf(address(ylp)), 11_000e18);
    }

    function test_Contract06_Case31_settlePnLRevertIfNotHook() public {
        vm.prank(user1);
        vm.expectRevert(YLP.YLP__CallerNotAuthorized.selector);
        ylp.settlePnL(user1, address(0x1), 1000e18);
    }

    function test_Contract06_Case32_settlePnLRevertIfInsufficientUSY() public {
        deal(usy, address(ylp), 500e18);

        vm.prank(address(yoloHook));
        vm.expectRevert(YLP.YLP__InsufficientUSY.selector);
        ylp.settlePnL(user1, address(0x1), 1000e18);
    }

    // ============================================================
    // ERC4626 VIEW FUNCTION TESTS
    // ============================================================

    function test_Contract06_Case33_erc4626Asset() public view {
        assertEq(ylp.asset(), usy);
    }

    function test_Contract06_Case34_erc4626TotalAssets() public {
        deal(usy, address(ylp), 5000e18);
        assertEq(ylp.totalAssets(), 5000e18);
    }

    function test_Contract06_Case35_erc4626ConvertToShares() public {
        // Setup: Create initial position
        deal(usy, address(ylp), 1000e18);
        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number); // PPS = 1e27

        assertEq(ylp.convertToShares(1000e18), 1000e18);
    }

    function test_Contract06_Case36_erc4626ConvertToAssets() public {
        deal(usy, address(ylp), 1000e18);
        vm.roll(block.number + 10);
        vm.prank(solver);
        ylp.sealEpoch(0, block.number);

        assertEq(ylp.convertToAssets(1000e18), 1000e18);
    }

    function test_Contract06_Case37_erc4626DirectDepositReverts() public {
        vm.startPrank(user1);
        IERC20(usy).approve(address(ylp), 1000e18);
        vm.expectRevert(YLP.YLP__QueueOnly.selector);
        ylp.deposit(1000e18, user1);
        vm.stopPrank();
    }

    function test_Contract06_Case38_erc4626DirectWithdrawReverts() public {
        vm.prank(user1);
        vm.expectRevert(YLP.YLP__QueueOnly.selector);
        ylp.withdraw(1000e18, user1, user1);
    }
}
