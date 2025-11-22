// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StabilityIncentivizer} from "../src/stability/StabilityIncentivizer.sol";
import {ACLManager} from "../src/access/ACLManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Mock reward token for testing
contract MockRewardToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock YoloHook for testing IStabilityTracker callbacks
// Simulates the real YoloHook behavior: beforeSwapUpdate -> swap execution -> afterSwapUpdate
contract MockYoloHook {
    StabilityIncentivizer public incentivizer;

    // Simulated anchor pool reserves (matches YoloHookStorage structure)
    uint256 public totalAnchorReserveUSY;
    uint256 public totalAnchorReserveUSDC;

    function setIncentivizer(address _incentivizer) external {
        incentivizer = StabilityIncentivizer(_incentivizer);
    }

    function setReserves(uint256 _usdcReserve, uint256 _usyReserve) external {
        totalAnchorReserveUSDC = _usdcReserve;
        totalAnchorReserveUSY = _usyReserve;
    }

    /// @notice Simulate a swap that changes reserves
    /// @dev Mimics real YoloHook: beforeSwapUpdate(sender, oldReserves) -> swap -> afterSwapUpdate(sender, newReserves)
    function simulateSwap(address swapper, uint256 usdcBefore, uint256 usyBefore, uint256 usdcAfter, uint256 usyAfter)
        external
    {
        // Set initial reserves
        totalAnchorReserveUSDC = usdcBefore;
        totalAnchorReserveUSY = usyBefore;

        // Call beforeSwapUpdate with current reserves (like real YoloHook does)
        if (address(incentivizer) != address(0)) {
            incentivizer.beforeSwapUpdate(swapper, totalAnchorReserveUSDC, totalAnchorReserveUSY);
        }

        // Execute swap (update reserves)
        totalAnchorReserveUSDC = usdcAfter;
        totalAnchorReserveUSY = usyAfter;

        // Call afterSwapUpdate with new reserves (like real YoloHook does)
        if (address(incentivizer) != address(0)) {
            incentivizer.afterSwapUpdate(swapper, totalAnchorReserveUSDC, totalAnchorReserveUSY);
        }
    }
}

contract TestContract09_StabilityIncentivizer is Test {
    StabilityIncentivizer public incentivizer;
    ACLManager public aclManager;
    MockYoloHook public yoloHook;

    MockRewardToken public usy;
    MockRewardToken public usdc;
    MockRewardToken public rewardToken1;
    MockRewardToken public rewardToken2;

    address public rewardsAdmin;
    address public trader1;
    address public trader2;
    address public trader3;

    bytes32 public constant REWARDS_ADMIN = keccak256("REWARDS_ADMIN");

    uint256 public constant EPOCH_DURATION = 7 days;
    uint8 public constant USDC_DECIMALS = 6;

    // Helper function to safely transfer tokens in tests
    function _safeTransfer(MockRewardToken token, address to, uint256 amount) internal {
        require(token.transfer(to, amount), "Transfer failed");
    }

    function setUp() public {
        // Create accounts
        rewardsAdmin = makeAddr("rewardsAdmin");
        trader1 = makeAddr("trader1");
        trader2 = makeAddr("trader2");
        trader3 = makeAddr("trader3");

        // Deploy ACLManager
        aclManager = new ACLManager();
        aclManager.createRole("REWARDS_ADMIN", 0x00);
        aclManager.grantRole(REWARDS_ADMIN, rewardsAdmin);

        // Deploy mock YoloHook
        yoloHook = new MockYoloHook();

        // Deploy StabilityIncentivizer
        incentivizer = new StabilityIncentivizer(address(yoloHook), address(aclManager), USDC_DECIMALS, EPOCH_DURATION);

        // Link YoloHook to incentivizer
        yoloHook.setIncentivizer(address(incentivizer));

        // Deploy mock tokens
        usy = new MockRewardToken("YOLO USD", "USY");
        usdc = new MockRewardToken("USD Coin", "USDC");
        rewardToken1 = new MockRewardToken("Reward Token 1", "RWD1");
        rewardToken2 = new MockRewardToken("Reward Token 2", "RWD2");

        // Register reward tokens
        vm.startPrank(rewardsAdmin);
        incentivizer.registerRewardToken(address(rewardToken1));
        incentivizer.registerRewardToken(address(rewardToken2));
        vm.stopPrank();
    }

    // ============================================================
    // INITIALIZATION TESTS
    // ============================================================

    function test_Contract09_Case01_initialization() public view {
        assertEq(incentivizer.YOLO_HOOK(), address(yoloHook));
        assertEq(address(incentivizer.ACL_MANAGER()), address(aclManager));
        assertEq(incentivizer.USDC_DECIMALS(), USDC_DECIMALS);
        assertEq(incentivizer.epochDuration(), EPOCH_DURATION);
        assertEq(incentivizer.currentEpoch(), 1);
        assertFalse(incentivizer.paused());
    }

    function test_Contract09_Case02_constants() public view {
        assertEq(incentivizer.PEG_PRICE(), 1_00000000); // $1.00 in 8 decimals
        assertEq(incentivizer.PRICE_PRECISION(), 1e8);
        assertEq(incentivizer.MIN_EPOCH_DURATION(), 1 days);
        assertEq(incentivizer.MAX_EPOCH_DURATION(), 30 days);
    }

    // ============================================================
    // REWARD TOKEN MANAGEMENT TESTS
    // ============================================================

    function test_Contract09_Case03_registerRewardToken() public {
        MockRewardToken newToken = new MockRewardToken("New Token", "NEW");

        vm.prank(rewardsAdmin);
        incentivizer.registerRewardToken(address(newToken));

        assertTrue(incentivizer.isRewardToken(address(newToken)));
        assertEq(incentivizer.getRewardTokenCount(), 3);
    }

    function test_Contract09_Case04_registerRewardTokenRevertsIfNotAdmin() public {
        MockRewardToken newToken = new MockRewardToken("New Token", "NEW");

        vm.prank(trader1);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__Unauthorized.selector);
        incentivizer.registerRewardToken(address(newToken));
    }

    function test_Contract09_Case05_registerRewardTokenRevertsIfAlreadyRegistered() public {
        vm.prank(rewardsAdmin);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__TokenAlreadyRegistered.selector);
        incentivizer.registerRewardToken(address(rewardToken1));
    }

    function test_Contract09_Case06_registerRewardTokenWithExistingBalance() public {
        MockRewardToken newToken = new MockRewardToken("New Token", "NEW");

        // Send tokens to incentivizer BEFORE registering
        _safeTransfer(newToken, address(incentivizer), 1000e18);

        vm.prank(rewardsAdmin);
        incentivizer.registerRewardToken(address(newToken));

        // Should have synced the existing balance to current epoch funding
        assertEq(incentivizer.currentEpochFunding(address(newToken)), 1000e18);
    }

    // ============================================================
    // SWAP TRACKING TESTS (PRICE CALCULATION & POINTS)
    // ============================================================

    function test_Contract09_Case07_swapMovingTowardPeg_positivePoints() public {
        // Setup: Price starts at 1.10 (above peg), swap moves it to 1.05 (closer to peg)
        uint256 usdcBefore = 1_100_000e6; // 1.1M USDC (6 decimals)
        uint256 usyBefore = 1_000_000e18; // 1M USY (18 decimals)
        uint256 usdcAfter = 1_050_000e6; // 1.05M USDC
        uint256 usyAfter = 1_000_000e18; // 1M USY

        // Expected: distanceBefore = 0.10, distanceAfter = 0.05, points = +0.05 (5_000_000 in 8 decimals)
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, usdcBefore, usyBefore, usdcAfter, usyAfter);

        int256 points = incentivizer.userPointsPerEpoch(1, trader1);
        assertEq(points, 5_000_000); // +0.05 improvement
        assertEq(incentivizer.totalPositivePointsPerEpoch(1), 5_000_000);
    }

    function test_Contract09_Case08_swapMovingAwayFromPeg_negativePoints() public {
        // Setup: Price starts at 1.00 (at peg), swap moves it to 1.10 (away from peg)
        uint256 usdcBefore = 1_000_000e6; // 1M USDC
        uint256 usyBefore = 1_000_000e18; // 1M USY
        uint256 usdcAfter = 1_100_000e6; // 1.1M USDC
        uint256 usyAfter = 1_000_000e18; // 1M USY

        // Expected: distanceBefore = 0.00, distanceAfter = 0.10, points = -0.10 (negative)
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, usdcBefore, usyBefore, usdcAfter, usyAfter);

        int256 points = incentivizer.userPointsPerEpoch(1, trader1);
        assertEq(points, -10_000_000); // -0.10 degradation
        assertEq(incentivizer.totalPositivePointsPerEpoch(1), 0); // Negative points don't count
    }

    function test_Contract09_Case09_multipleSwapsSameUser() public {
        // First swap: 1.10 -> 1.05 (+0.05 points)
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // Second swap: 1.05 -> 1.02 (+0.03 points)
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_050_000e6, 1_000_000e18, 1_020_000e6, 1_000_000e18);

        // Total points should accumulate
        int256 points = incentivizer.userPointsPerEpoch(1, trader1);
        assertEq(points, 8_000_000); // +0.05 + 0.03 = 0.08
        assertEq(incentivizer.totalPositivePointsPerEpoch(1), 8_000_000);
    }

    function test_Contract09_Case10_userPointsCanGoBelowZero() public {
        // First swap: earn positive points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        assertEq(incentivizer.userPointsPerEpoch(1, trader1), 5_000_000);

        // Second swap: lose more points than gained
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_000_000e6, 1_000_000e18, 1_200_000e6, 1_000_000e18);

        int256 finalPoints = incentivizer.userPointsPerEpoch(1, trader1);
        assertLt(finalPoints, 0); // Should be negative
        assertEq(incentivizer.totalPositivePointsPerEpoch(1), 0); // No positive points
    }

    function test_Contract09_Case11_totalPositivePointsOnlyCountsPositive() public {
        // trader1: earn positive points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // trader2: earn negative points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader2, 1_000_000e6, 1_000_000e18, 1_100_000e6, 1_000_000e18);

        // trader3: earn positive points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader3, 1_080_000e6, 1_000_000e18, 1_040_000e6, 1_000_000e18);

        assertEq(incentivizer.userPointsPerEpoch(1, trader1), 5_000_000);
        assertEq(incentivizer.userPointsPerEpoch(1, trader2), -10_000_000);
        assertEq(incentivizer.userPointsPerEpoch(1, trader3), 4_000_000);

        // Total should only count trader1 + trader3
        assertEq(incentivizer.totalPositivePointsPerEpoch(1), 9_000_000);
    }

    // ============================================================
    // REWARD SYNCING TESTS
    // ============================================================

    function test_Contract09_Case12_syncRewardsDetectsNewFunding() public {
        // Send tokens to incentivizer
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);

        // Sync should detect the new balance
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        incentivizer.syncRewards(tokens);

        assertEq(incentivizer.currentEpochFunding(address(rewardToken1)), 1000e18);
        assertEq(incentivizer.accountedBalance(address(rewardToken1)), 1000e18);
    }

    function test_Contract09_Case13_syncRewardsMultipleTokens() public {
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        _safeTransfer(rewardToken2, address(incentivizer), 2000e18);

        address[] memory tokens = new address[](2);
        tokens[0] = address(rewardToken1);
        tokens[1] = address(rewardToken2);
        incentivizer.syncRewards(tokens);

        assertEq(incentivizer.currentEpochFunding(address(rewardToken1)), 1000e18);
        assertEq(incentivizer.currentEpochFunding(address(rewardToken2)), 2000e18);
    }

    function test_Contract09_Case14_syncRewardsPermissionless() public {
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);

        // Anyone can call syncRewards
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);

        vm.prank(trader1);
        incentivizer.syncRewards(tokens);

        assertEq(incentivizer.currentEpochFunding(address(rewardToken1)), 1000e18);
    }

    // ============================================================
    // EPOCH ROLLOVER TESTS
    // ============================================================

    function test_Contract09_Case15_rollEpochRevertsIfNotFinished() public {
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__EpochNotFinished.selector);
        incentivizer.rollEpoch();
    }

    function test_Contract09_Case16_rollEpochAdvancesEpoch() public {
        // Wait for epoch to finish
        vm.warp(block.timestamp + EPOCH_DURATION);

        incentivizer.rollEpoch();

        assertEq(incentivizer.currentEpoch(), 2);
        assertEq(incentivizer.epochStartTime(), block.timestamp);
    }

    function test_Contract09_Case17_rollEpochAllocatesRewards() public {
        // Send rewards
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        _safeTransfer(rewardToken2, address(incentivizer), 2000e18);

        // Sync rewards
        address[] memory tokens = new address[](2);
        tokens[0] = address(rewardToken1);
        tokens[1] = address(rewardToken2);
        incentivizer.syncRewards(tokens);

        // Wait and roll epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // Check that rewards were allocated to epoch 1
        assertEq(incentivizer.epochRewards(1, address(rewardToken1)), 1000e18);
        assertEq(incentivizer.epochRewards(1, address(rewardToken2)), 2000e18);

        // Current funding should be reset
        assertEq(incentivizer.currentEpochFunding(address(rewardToken1)), 0);
        assertEq(incentivizer.currentEpochFunding(address(rewardToken2)), 0);
    }

    function test_Contract09_Case18_rollEpochAutoSyncsBeforeAllocation() public {
        // Send tokens WITHOUT manual sync
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);

        // Roll epoch should auto-sync
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // Should still allocate correctly
        assertEq(incentivizer.epochRewards(1, address(rewardToken1)), 1000e18);
    }

    // ============================================================
    // CLAIMING TESTS
    // ============================================================

    function test_Contract09_Case19_claimRewardBasic() public {
        // Setup: trader1 earns points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // Send rewards and roll epoch
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // trader1 should be able to claim 100% of rewards
        uint256 balanceBefore = rewardToken1.balanceOf(trader1);

        vm.prank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));

        uint256 balanceAfter = rewardToken1.balanceOf(trader1);
        assertEq(balanceAfter - balanceBefore, 1000e18);
        assertTrue(incentivizer.hasClaimed(1, trader1, address(rewardToken1)));
    }

    function test_Contract09_Case20_claimRewardProportional() public {
        // trader1: 5M points (from 1.10 -> 1.05)
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // trader2: 3M points (from 1.06 -> 1.03)
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader2, 1_060_000e6, 1_000_000e18, 1_030_000e6, 1_000_000e18);

        // Total: 8M points, trader1 = 62.5%, trader2 = 37.5%

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // trader1 claims
        vm.prank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));

        // trader2 claims
        vm.prank(trader2);
        incentivizer.claimReward(1, address(rewardToken1));

        // Check proportional distribution
        assertEq(rewardToken1.balanceOf(trader1), 625e18); // 62.5%
        assertEq(rewardToken1.balanceOf(trader2), 375e18); // 37.5%
    }

    function test_Contract09_Case21_claimRewardRevertsIfEpochNotEnded() public {
        vm.prank(trader1);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__EpochNotEnded.selector);
        incentivizer.claimReward(1, address(rewardToken1));
    }

    function test_Contract09_Case22_claimRewardRevertsIfAlreadyClaimed() public {
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        vm.prank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));

        // Try to claim again
        vm.prank(trader1);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__AlreadyClaimed.selector);
        incentivizer.claimReward(1, address(rewardToken1));
    }

    function test_Contract09_Case23_claimRewardRevertsIfNoPositivePoints() public {
        // trader1 has negative points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_000_000e6, 1_000_000e18, 1_100_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        vm.prank(trader1);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__NoPositivePoints.selector);
        incentivizer.claimReward(1, address(rewardToken1));
    }

    function test_Contract09_Case24_claimAllRewards() public {
        // trader1 earns points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // Send both reward tokens
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        _safeTransfer(rewardToken2, address(incentivizer), 2000e18);

        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // Claim all at once
        vm.prank(trader1);
        incentivizer.claimAllRewards(1);

        assertEq(rewardToken1.balanceOf(trader1), 1000e18);
        assertEq(rewardToken2.balanceOf(trader1), 2000e18);
        assertTrue(incentivizer.hasClaimed(1, trader1, address(rewardToken1)));
        assertTrue(incentivizer.hasClaimed(1, trader1, address(rewardToken2)));
    }

    function test_Contract09_Case25_claimAutoSyncsTokens() public {
        // trader1 earns points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // Roll epoch
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // Send NEW funding AFTER epoch rolled (shouldn't affect epoch 1)
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);

        // Claim should auto-sync but NOT affect epoch 1 rewards (returns early with userReward = 0)
        uint256 balanceBefore = rewardToken1.balanceOf(trader1);
        vm.prank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));

        // Balance should be unchanged (no rewards in epoch 1)
        assertEq(rewardToken1.balanceOf(trader1), balanceBefore);

        // hasClaimed should still be false since claim returned early
        assertFalse(incentivizer.hasClaimed(1, trader1, address(rewardToken1)));

        // But current epoch funding should be updated via auto-sync
        assertEq(incentivizer.currentEpochFunding(address(rewardToken1)), 1000e18);
    }

    // ============================================================
    // VIEW FUNCTION TESTS
    // ============================================================

    function test_Contract09_Case26_getClaimableReward() public {
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        uint256 claimable = incentivizer.getClaimableReward(trader1, 1, address(rewardToken1));
        assertEq(claimable, 1000e18);
    }

    function test_Contract09_Case27_getClaimableRewardReturnsZeroIfClaimed() public {
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        vm.prank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));

        uint256 claimable = incentivizer.getClaimableReward(trader1, 1, address(rewardToken1));
        assertEq(claimable, 0);
    }

    function test_Contract09_Case28_getProjectedReward() public {
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        incentivizer.syncRewards(tokens);

        // Projected reward should show what trader1 would get if epoch ended now
        uint256 projected = incentivizer.getProjectedReward(trader1, address(rewardToken1));
        assertEq(projected, 1000e18); // 100% since only trader
    }

    function test_Contract09_Case29_getProjectedRewardProportional() public {
        // trader1: 5M points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // trader2: 3M points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader2, 1_060_000e6, 1_000_000e18, 1_030_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        incentivizer.syncRewards(tokens);

        uint256 projected1 = incentivizer.getProjectedReward(trader1, address(rewardToken1));
        uint256 projected2 = incentivizer.getProjectedReward(trader2, address(rewardToken1));

        assertEq(projected1, 625e18); // 62.5%
        assertEq(projected2, 375e18); // 37.5%
    }

    // ============================================================
    // ADMIN FUNCTION TESTS
    // ============================================================

    function test_Contract09_Case30_setEpochDuration() public {
        vm.prank(rewardsAdmin);
        incentivizer.setEpochDuration(14 days);

        assertEq(incentivizer.epochDuration(), 14 days);
    }

    function test_Contract09_Case31_setEpochDurationRevertsIfTooShort() public {
        vm.prank(rewardsAdmin);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__InvalidDuration.selector);
        incentivizer.setEpochDuration(12 hours);
    }

    function test_Contract09_Case32_setEpochDurationRevertsIfTooLong() public {
        vm.prank(rewardsAdmin);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__InvalidDuration.selector);
        incentivizer.setEpochDuration(31 days);
    }

    function test_Contract09_Case33_pauseAndUnpause() public {
        vm.startPrank(rewardsAdmin);

        incentivizer.pause();
        assertTrue(incentivizer.paused());

        incentivizer.unpause();
        assertFalse(incentivizer.paused());

        vm.stopPrank();
    }

    function test_Contract09_Case34_swapRevertsWhenPaused() public {
        vm.prank(rewardsAdmin);
        incentivizer.pause();

        vm.prank(address(yoloHook));
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__Paused.selector);
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);
    }

    // ============================================================
    // EDGE CASE TESTS
    // ============================================================

    function test_Contract09_Case35_unclaimedRewardsDoNotAffectNewEpoch() public {
        // Epoch 1: trader1 earns, rewards allocated
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // Epoch 2: send MORE rewards WITHOUT trader1 claiming epoch 1
        _safeTransfer(rewardToken1, address(incentivizer), 500e18);
        vm.warp(incentivizer.epochStartTime() + EPOCH_DURATION); // Warp from new epochStartTime
        incentivizer.rollEpoch();

        // Epoch 2 should only have 500e18, not affected by unclaimed 1000e18
        assertEq(incentivizer.epochRewards(2, address(rewardToken1)), 500e18);
        assertEq(incentivizer.epochRewards(1, address(rewardToken1)), 1000e18);
    }

    function test_Contract09_Case36_multipleEpochsClaiming() public {
        // Epoch 1
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // Epoch 2
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_080_000e6, 1_000_000e18, 1_040_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 2000e18);
        vm.warp(incentivizer.epochStartTime() + EPOCH_DURATION); // Warp from new epochStartTime
        incentivizer.rollEpoch();

        // Claim both epochs
        vm.startPrank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));
        incentivizer.claimReward(2, address(rewardToken1));
        vm.stopPrank();

        assertEq(rewardToken1.balanceOf(trader1), 3000e18); // 1000 + 2000
    }

    function test_Contract09_Case37_zeroRewardsEpoch() public {
        // Epoch with points but no rewards
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // Roll WITHOUT sending rewards
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // Should succeed but return early (userReward = 0)
        uint256 balanceBefore = rewardToken1.balanceOf(trader1);
        vm.prank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));

        // Balance should remain unchanged
        assertEq(rewardToken1.balanceOf(trader1), balanceBefore);

        // Now send rewards AFTER epoch ended - should go to currentEpochFunding (epoch 2)
        _safeTransfer(rewardToken1, address(incentivizer), 500e18);
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardToken1);
        incentivizer.syncRewards(tokens);

        // New funding should be in epoch 2's funding, not epoch 1's rewards
        assertEq(incentivizer.currentEpochFunding(address(rewardToken1)), 500e18);
        assertEq(incentivizer.epochRewards(1, address(rewardToken1)), 0);
    }

    function test_Contract09_Case38_beforeSwapWithoutAfterSwap() public {
        // Call beforeSwapUpdate but never afterSwapUpdate
        vm.prank(address(yoloHook));
        incentivizer.beforeSwapUpdate(trader1, 1_100_000e6, 1_000_000e18);

        // Try another swap - should revert because previous swap not completed
        vm.prank(address(yoloHook));
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__NoPendingSwap.selector);
        incentivizer.afterSwapUpdate(trader2, 1_050_000e6, 1_000_000e18);
    }

    function test_Contract09_Case39_onlyYoloHookCanCallTrackerFunctions() public {
        vm.prank(trader1);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__Unauthorized.selector);
        incentivizer.beforeSwapUpdate(trader1, 1_100_000e6, 1_000_000e18);

        vm.prank(trader1);
        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__Unauthorized.selector);
        incentivizer.afterSwapUpdate(trader1, 1_050_000e6, 1_000_000e18);
    }

    function test_Contract09_Case40_defaultAdminCanCallRewardsAdminFunctions() public {
        // address(this) is DEFAULT_ADMIN
        MockRewardToken newToken = new MockRewardToken("New Token", "NEW");

        // Should not revert
        incentivizer.registerRewardToken(address(newToken));
        incentivizer.setEpochDuration(14 days);
        incentivizer.pause();
        incentivizer.unpause();

        assertTrue(incentivizer.isRewardToken(address(newToken)));
    }

    // ============================================================
    // ADDITIONAL TESTS (ACCOUNTING & EDGE CASES)
    // ============================================================

    function test_Contract09_Case41_accountedBalanceShrinksAfterClaims() public {
        // trader1 earns points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        // Send rewards and roll epoch
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        // Check accountedBalance before claim
        uint256 accountedBefore = incentivizer.accountedBalance(address(rewardToken1));
        assertEq(accountedBefore, 1000e18); // All rewards are accounted

        // trader1 claims
        vm.prank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));

        // accountedBalance should shrink by claimed amount
        uint256 accountedAfter = incentivizer.accountedBalance(address(rewardToken1));
        assertEq(accountedAfter, 0); // All claimed, nothing left accounted
        assertEq(accountedBefore - accountedAfter, 1000e18);
    }

    function test_Contract09_Case42_accountedBalanceTracksMultipleClaims() public {
        // trader1: 5M points, trader2: 3M points
        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader1, 1_100_000e6, 1_000_000e18, 1_050_000e6, 1_000_000e18);

        vm.prank(address(yoloHook));
        yoloHook.simulateSwap(trader2, 1_060_000e6, 1_000_000e18, 1_030_000e6, 1_000_000e18);

        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        uint256 accountedInitial = incentivizer.accountedBalance(address(rewardToken1));
        assertEq(accountedInitial, 1000e18);

        // trader1 claims (62.5%)
        vm.prank(trader1);
        incentivizer.claimReward(1, address(rewardToken1));

        uint256 accountedAfterTrader1 = incentivizer.accountedBalance(address(rewardToken1));
        assertEq(accountedAfterTrader1, 375e18); // 1000 - 625 = 375 left

        // trader2 claims (37.5%)
        vm.prank(trader2);
        incentivizer.claimReward(1, address(rewardToken1));

        uint256 accountedFinal = incentivizer.accountedBalance(address(rewardToken1));
        assertEq(accountedFinal, 0); // All claimed
    }

    function test_Contract09_Case43_syncRewardsRevertsForUnregisteredToken() public {
        MockRewardToken unregisteredToken = new MockRewardToken("Unregistered", "UNREG");

        address[] memory tokens = new address[](1);
        tokens[0] = address(unregisteredToken);

        vm.expectRevert(StabilityIncentivizer.StabilityIncentivizer__TokenNotRegistered.selector);
        incentivizer.syncRewards(tokens);
    }

    function test_Contract09_Case44_accountedBalanceStaysConsistentAcrossEpochs() public {
        // Epoch 1: Send 1000, allocate to epoch 1
        _safeTransfer(rewardToken1, address(incentivizer), 1000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        incentivizer.rollEpoch();

        assertEq(incentivizer.accountedBalance(address(rewardToken1)), 1000e18);

        // Epoch 2: Send 500 more
        _safeTransfer(rewardToken1, address(incentivizer), 500e18);
        vm.warp(incentivizer.epochStartTime() + EPOCH_DURATION); // Warp from new epochStartTime
        incentivizer.rollEpoch();

        // accountedBalance should track both epochs
        assertEq(incentivizer.accountedBalance(address(rewardToken1)), 1500e18);

        // Epoch 1 has 1000, epoch 2 has 500
        assertEq(incentivizer.epochRewards(1, address(rewardToken1)), 1000e18);
        assertEq(incentivizer.epochRewards(2, address(rewardToken1)), 500e18);
    }
}
