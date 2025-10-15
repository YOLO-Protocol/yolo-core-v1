// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base02_DeployYoloHook} from "./base/Base02_DeployYoloHook.t.sol";
import {YoloHook} from "../src/core/YoloHook.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestAction02_AnchorPoolLiquidity
 * @notice Integration tests for anchor pool LP operations via PoolManager
 * @dev Tests addLiquidity/removeLiquidity with PoolManager unlock callbacks
 *      Verifies settle/take pattern, reserve updates, and sUSY mint/burn
 */
contract TestAction02_AnchorPoolLiquidity is Base02_DeployYoloHook {
    // ============================================================
    // TEST ACCOUNTS
    // ============================================================

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // ============================================================
    // EVENTS (for expectEmit)
    // ============================================================

    event LiquidityAdded(
        address indexed sender,
        address indexed receiver,
        uint256 usyAmount,
        uint256 usdcAmount,
        uint256 sUSYMinted,
        bool isBootstrap
    );

    event LiquidityRemoved(
        address indexed sender, address indexed receiver, uint256 sUSYBurned, uint256 usyAmount, uint256 usdcAmount
    );

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public override {
        super.setUp(); // Deploy YoloHook from Base02

        // Mint test tokens to users
        usdc.mint(user1, 10000e6); // 10K USDC
        usdc.mint(user2, 10000e6);

        // Give users USY using deal (bypasses mint restrictions for testing)
        deal(usy, user1, 10000e18);
        deal(usy, user2, 10000e18);

        // Approve YoloHook
        vm.startPrank(user1);
        usdc.approve(address(yoloHook), type(uint256).max);
        IERC20(usy).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(yoloHook), type(uint256).max);
        IERC20(usy).approve(address(yoloHook), type(uint256).max);
        vm.stopPrank();
    }

    // ============================================================
    // BOOTSTRAP LIQUIDITY TESTS
    // ============================================================

    function test_Action02_Case01_bootstrapEqualAmounts() public {
        uint256 usyIn = 1000e18;
        uint256 usdcIn = 1000e6;

        // Expect LiquidityAdded event
        uint256 expectedSUSY = 2000e18 - yoloHook.MINIMUM_LIQUIDITY();
        vm.expectEmit(true, true, false, true);
        emit LiquidityAdded(user1, user1, usyIn, usdcIn, expectedSUSY, true);

        vm.prank(user1);
        (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) = yoloHook.addLiquidity(usyIn, usdcIn, 0, user1);

        // Should enforce 1:1 ratio (both amounts used)
        assertEq(usyUsed, usyIn, "All USY should be used");
        assertEq(usdcUsed, usdcIn, "All USDC should be used");

        // Verify sUSY minted matches expected
        assertEq(sUSYMinted, expectedSUSY, "Should mint correct sUSY");

        // Check reserves updated
        (uint256 reserveUSY, uint256 reserveUSDC) = yoloHook.getAnchorReserves();
        assertEq(reserveUSY, usyIn, "USY reserve should be updated");
        assertEq(reserveUSDC, usdcIn, "USDC reserve should be updated");

        // Check sUSY balance
        assertEq(IERC20(sUSY).balanceOf(user1), expectedSUSY, "User should receive sUSY");

        // Check MINIMUM_LIQUIDITY locked
        assertEq(IERC20(sUSY).balanceOf(address(1)), yoloHook.MINIMUM_LIQUIDITY(), "MINIMUM_LIQUIDITY should be locked");
    }

    function test_Action02_Case02_bootstrapUsdcLimiting() public {
        uint256 usyIn = 2000e18;
        uint256 usdcIn = 1000e6; // USDC is limiting factor

        vm.prank(user1);
        (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) = yoloHook.addLiquidity(usyIn, usdcIn, 0, user1);

        // Should take min (1000 from each)
        assertEq(usyUsed, 1000e18, "Should use 1000 USY (matching USDC)");
        assertEq(usdcUsed, 1000e6, "Should use all USDC");

        uint256 expectedSUSY = 2000e18 - yoloHook.MINIMUM_LIQUIDITY();
        assertEq(sUSYMinted, expectedSUSY, "Should mint based on minimum");
    }

    function test_Action02_Case03_bootstrapUsyLimiting() public {
        uint256 usyIn = 1000e18; // USY is limiting factor
        uint256 usdcIn = 2000e6;

        vm.prank(user1);
        (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) = yoloHook.addLiquidity(usyIn, usdcIn, 0, user1);

        // Should take min (1000 from each)
        assertEq(usyUsed, 1000e18, "Should use all USY");
        assertEq(usdcUsed, 1000e6, "Should use 1000 USDC (matching USY)");

        uint256 expectedSUSY = 2000e18 - yoloHook.MINIMUM_LIQUIDITY();
        assertEq(sUSYMinted, expectedSUSY, "Should mint based on minimum");
    }

    function test_Action02_Case04_bootstrapInsufficientValueReverts() public {
        // Try to add less than MINIMUM_LIQUIDITY worth
        vm.prank(user1);
        vm.expectRevert();
        yoloHook.addLiquidity(100, 100, 0, user1); // Tiny amounts
    }

    function test_Action02_Case05_bootstrapSlippageProtectionReverts() public {
        vm.prank(user1);
        vm.expectRevert();
        yoloHook.addLiquidity(1000e18, 1000e6, 3000e18, user1); // Expect too much sUSY
    }

    // ============================================================
    // SUBSEQUENT LIQUIDITY TESTS (MIN-SHARE)
    // ============================================================

    function test_Action02_Case06_addLiquiditySecondProviderMaintainsRatio() public {
        // Bootstrap
        vm.prank(user1);
        yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Expect LiquidityAdded event (non-bootstrap)
        vm.expectEmit(true, true, false, false);
        emit LiquidityAdded(user2, user2, 500e18, 500e6, 0, false);

        // Second provider adds proportionally
        vm.prank(user2);
        (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) = yoloHook.addLiquidity(500e18, 500e6, 0, user2);

        assertEq(usyUsed, 500e18, "Should use all USY");
        assertEq(usdcUsed, 500e6, "Should use all USDC");

        // Min-share: (500 * totalSupply) / 1000 = (500 * 1999000) / 1000 ≈ 999500
        assertGt(sUSYMinted, 0, "Should mint sUSY");

        // Check total reserves
        (uint256 reserveUSY, uint256 reserveUSDC) = yoloHook.getAnchorReserves();
        assertEq(reserveUSY, 1500e18, "Total USY reserve should be 1500");
        assertEq(reserveUSDC, 1500e6, "Total USDC reserve should be 1500");
    }

    function test_Action02_Case07_addLiquidityImbalancedDepositWithinTolerance() public {
        // Bootstrap
        vm.prank(user1);
        yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Try slightly imbalanced (within 1%)
        vm.prank(user2);
        (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) = yoloHook.addLiquidity(500e18, 505e6, 0, user2); // 1% more USDC

        // Should adjust to maintain ratio
        assertGt(usyUsed, 0, "Should use some USY");
        assertGt(usdcUsed, 0, "Should use some USDC");
        assertGt(sUSYMinted, 0, "Should mint sUSY");
    }

    function test_Action02_Case08_addLiquidityExcessiveImbalanceAutoAdjusts() public {
        // Bootstrap
        vm.prank(user1);
        yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Try very imbalanced (> 1%) - should auto-adjust to optimal ratio
        vm.prank(user2);
        (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) = yoloHook.addLiquidity(500e18, 600e6, 0, user2); // 20% more USDC provided

        // Min-share formula should only use optimal amounts to maintain ratio
        assertEq(usyUsed, 500e18, "Should use all USY");
        assertEq(usdcUsed, 500e6, "Should only use 500 USDC to maintain ratio");
        assertGt(sUSYMinted, 0, "Should mint sUSY");

        // Verify user2 still has 100 USDC left (didn't use the extra 100)
        assertEq(usdc.balanceOf(user2), 9500e6, "Should have unused USDC");
    }

    // ============================================================
    // REMOVE LIQUIDITY TESTS
    // ============================================================

    function test_Action02_Case09_removeLiquidityProportionalRedemption() public {
        // Bootstrap
        vm.prank(user1);
        (,, uint256 sUSYMinted) = yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Remove half
        uint256 sUSYToBurn = sUSYMinted / 2;

        // Expect LiquidityRemoved event (check sender, receiver, and sUSYBurned exactly; not amounts)
        vm.expectEmit(true, true, false, false);
        emit LiquidityRemoved(user1, user1, sUSYToBurn, 0, 0);

        vm.prank(user1);
        (uint256 usyOut, uint256 usdcOut) = yoloHook.removeLiquidity(sUSYToBurn, 0, 0, user1);

        // Should get proportional amounts
        assertApproxEqRel(usyOut, 500e18, 0.01e18, "Should receive ~500 USY");
        assertApproxEqRel(usdcOut, 500e6, 0.01e18, "Should receive ~500 USDC");

        // Check reserves decreased
        (uint256 reserveUSY, uint256 reserveUSDC) = yoloHook.getAnchorReserves();
        assertApproxEqRel(reserveUSY, 500e18, 0.01e18, "USY reserve should decrease");
        assertApproxEqRel(reserveUSDC, 500e6, 0.01e18, "USDC reserve should decrease");

        // Check sUSY burned
        uint256 remainingSUSY = IERC20(sUSY).balanceOf(user1);
        assertApproxEqRel(remainingSUSY, sUSYMinted - sUSYToBurn, 0.01e18, "sUSY should be burned");
    }

    function test_Action02_Case10_removeLiquidityFullRemoval() public {
        // Bootstrap
        vm.prank(user1);
        (,, uint256 sUSYMinted) = yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Remove all
        vm.prank(user1);
        (uint256 usyOut, uint256 usdcOut) = yoloHook.removeLiquidity(sUSYMinted, 0, 0, user1);

        // Should get almost all back (slightly less due to rounding)
        assertApproxEqRel(usyOut, 1000e18, 0.01e18, "Should receive ~1000 USY");
        assertApproxEqRel(usdcOut, 1000e6, 0.01e18, "Should receive ~1000 USDC");

        // sUSY balance should be 0
        assertEq(IERC20(sUSY).balanceOf(user1), 0, "User should have no sUSY left");
    }

    function test_Action02_Case11_removeLiquiditySlippageProtectionReverts() public {
        // Bootstrap
        vm.prank(user1);
        (,, uint256 sUSYMinted) = yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Try to remove with unrealistic expectations
        vm.prank(user1);
        vm.expectRevert();
        yoloHook.removeLiquidity(sUSYMinted / 2, 600e18, 600e6, user1); // Expect too much
    }

    function test_Action02_Case12_removeLiquidityInsufficientBalanceReverts() public {
        // Bootstrap
        vm.prank(user1);
        yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // User2 tries to remove without sUSY
        vm.prank(user2);
        vm.expectRevert();
        yoloHook.removeLiquidity(100e18, 0, 0, user2);
    }

    // ============================================================
    // MULTI-USER SCENARIOS
    // ============================================================

    function test_Action02_Case13_multiUserAddAndRemove() public {
        // User1 bootstraps
        vm.prank(user1);
        (,, uint256 user1SUSY) = yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // User2 adds
        vm.prank(user2);
        (,, uint256 user2SUSY) = yoloHook.addLiquidity(500e18, 500e6, 0, user2);

        // Both should have sUSY
        assertGt(user1SUSY, 0, "User1 should have sUSY");
        assertGt(user2SUSY, 0, "User2 should have sUSY");

        // User1 removes half
        vm.prank(user1);
        yoloHook.removeLiquidity(user1SUSY / 2, 0, 0, user1);

        // User2's sUSY should still be valid
        assertEq(IERC20(sUSY).balanceOf(user2), user2SUSY, "User2 sUSY unchanged");

        // User2 removes all
        vm.prank(user2);
        yoloHook.removeLiquidity(user2SUSY, 0, 0, user2);

        assertEq(IERC20(sUSY).balanceOf(user2), 0, "User2 should have no sUSY");
    }

    // ============================================================
    // PREVIEW CONSISTENCY TESTS
    // ============================================================

    function test_Action02_Case14_previewMatchesBootstrap() public {
        uint256 usyIn = 1000e18;
        uint256 usdcIn = 1000e6;

        // Preview
        uint256 previewSUSY = yoloHook.previewAddLiquidity(usyIn, 1000e18); // USDC normalized to 18

        // Execute
        vm.prank(user1);
        (,, uint256 actualSUSY) = yoloHook.addLiquidity(usyIn, usdcIn, 0, user1);

        // Should match
        assertEq(previewSUSY, actualSUSY, "Preview should match execution");
    }

    function test_Action02_Case15_previewMatchesSubsequentAdd() public {
        // Bootstrap
        vm.prank(user1);
        yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Preview second add
        uint256 previewSUSY = yoloHook.previewAddLiquidity(500e18, 500e18); // Normalized

        // Execute
        vm.prank(user2);
        (,, uint256 actualSUSY) = yoloHook.addLiquidity(500e18, 500e6, 0, user2);

        // Should match (within rounding)
        assertApproxEqRel(previewSUSY, actualSUSY, 0.001e18, "Preview should match execution");
    }

    function test_Action02_Case16_previewMatchesRemove() public {
        // Bootstrap
        vm.prank(user1);
        (,, uint256 sUSYMinted) = yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Preview removal
        (uint256 previewUSY, uint256 previewUSDC) = yoloHook.previewRemoveLiquidity(sUSYMinted / 2);

        // Execute
        vm.prank(user1);
        (uint256 actualUSY, uint256 actualUSDC) = yoloHook.removeLiquidity(sUSYMinted / 2, 0, 0, user1);

        // Should match (normalized, so compare 18-decimal values)
        assertApproxEqRel(previewUSY, actualUSY, 0.001e18, "Preview USY should match");

        // For USDC, convert actual to 18 decimals for comparison
        uint256 actualUSDC18 = actualUSDC * 1e12;
        assertApproxEqRel(previewUSDC, actualUSDC18, 0.001e18, "Preview USDC should match");
    }

    // ============================================================
    // SECURITY & EDGE CASE TESTS
    // ============================================================

    function test_Action02_Case17_unlockCallbackOnlyPoolManager() public {
        // Attempt to call unlockCallback directly (not from PoolManager)
        bytes memory fakeData = abi.encode(
            DataTypes.CallbackData({
                action: DataTypes.UnlockAction.ADD_LIQUIDITY,
                data: abi.encode(
                    DataTypes.AddLiquidityData({
                        sender: user1,
                        receiver: user1,
                        maxUsyIn: 1000e18,
                        maxUsdcIn: 1000e6,
                        minSUSY: 0
                    })
                )
            })
        );

        vm.prank(user1);
        vm.expectRevert(YoloHook.YoloHook__CallerNotAuthorized.selector);
        yoloHook.unlockCallback(fakeData);
    }

    function test_Action02_Case18_previewHandlesImbalancedInputs() public {
        // Bootstrap first
        vm.prank(user1);
        yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Preview with extreme input imbalance (10:1 ratio)
        uint256 previewSUSY = yoloHook.previewAddLiquidity(10000e18, 1000e18); // 10x USY vs USDC (normalized)

        // Preview should return a valid amount because it auto-adjusts to optimal ratio
        // Pool has 1000 USY + 1000 USDC (1000e18 normalized), totalSupply = 2000e18 - MINIMUM_LIQUIDITY
        // USDC is limiting: uses 1000 USDC normalized + 1000 USY to maintain 1:1
        // Expected: min((1000*supply)/1000, (1000*supply)/1000) = supply = ~2000e18
        uint256 expectedSUSY = 2000e18 - yoloHook.MINIMUM_LIQUIDITY(); // Matches current totalSupply
        assertApproxEqRel(previewSUSY, expectedSUSY, 0.01e18, "Preview should auto-adjust to optimal amounts");

        // Verify preview matches execution
        vm.prank(user2);
        (,, uint256 actualSUSY) = yoloHook.addLiquidity(10000e18, 1000e6, 0, user2);
        assertApproxEqRel(previewSUSY, actualSUSY, 0.01e18, "Preview should match execution");
    }

    function test_Action02_Case19_usdc18DecimalsNormalization() public {
        // Note: Full end-to-end test with 18-decimal USDC is covered in TestContract05_StakedYoloUSD
        // This test verifies the normalization logic works correctly in the preview functions

        // Scenario: Bootstrap with 6-decimal USDC
        vm.prank(user1);
        yoloHook.addLiquidity(1000e18, 1000e6, 0, user1);

        // Verify normalized reserves
        (uint256 reserveUSY18, uint256 reserveUSDC18) = yoloHook.getAnchorReservesNormalized18();
        assertEq(reserveUSY18, 1000e18, "USY should be 1000e18");
        assertEq(reserveUSDC18, 1000e18, "USDC should be normalized to 1000e18 (from 1000e6)");

        // Verify preview uses normalized values correctly
        uint256 previewSUSY = yoloHook.previewAddLiquidity(500e18, 500e18); // Both normalized to 18

        vm.prank(user2);
        (,, uint256 actualSUSY) = yoloHook.addLiquidity(500e18, 500e6, 0, user2); // USDC in native 6 decimals

        // Preview (using 18-decimal USDC input) should match execution (using 6-decimal USDC input)
        assertApproxEqRel(previewSUSY, actualSUSY, 0.01e18, "Preview with normalized input should match execution");
    }
}
