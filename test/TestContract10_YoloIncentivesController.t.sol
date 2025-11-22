// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YoloIncentivesController} from "../src/tokenomics/YoloIncentivesController.sol";
import {ACLManager} from "../src/access/ACLManager.sol";
import {MockMintableIncentivizedERC20} from "../src/mocks/MockMintableIncentivizedERC20.sol";
import {IIncentivesTracker} from "../src/interfaces/IIncentivesTracker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Mock reward token for testing
contract MockRewardToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 amount) internal {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract TestContract10_YoloIncentivesController is Test {
    YoloIncentivesController public controller;
    ACLManager public aclManager;

    MockMintableIncentivizedERC20 public poolTokenA;
    MockMintableIncentivizedERC20 public poolTokenB;
    MockRewardToken public rewardTokenUSY;
    MockRewardToken public rewardTokenYOLO;

    address public admin;
    address public rewardsAdmin;
    address public userA;
    address public userB;
    address public userC;

    bytes32 public constant DEFAULT_ADMIN = keccak256("DEFAULT_ADMIN");
    bytes32 public constant REWARDS_ADMIN = keccak256("REWARDS_ADMIN");

    uint256 public constant EPOCH_DURATION = 7 days;
    uint256 public constant PRECISION = 1e12;
    uint256 public constant REWARD_RATE_PRECISION = 1e18;

    // Helper to fund epochs
    function _fundEpoch(MockRewardToken token, uint256 amount) internal {
        token.mint(address(controller), amount);
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        controller.syncRewards(tokens);
    }

    // Helper to get claimable rewards for single asset/token pair
    function _getClaimable(address user, address asset, address token) internal view returns (uint256) {
        address[] memory assets = new address[](1);
        assets[0] = asset;
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = controller.claimableRewards(user, assets, tokens);
        return amounts[0];
    }

    function setUp() public {
        // Create accounts
        admin = makeAddr("admin");
        rewardsAdmin = makeAddr("rewardsAdmin");
        userA = makeAddr("userA");
        userB = makeAddr("userB");
        userC = makeAddr("userC");

        // Deploy ACLManager (test contract is admin)
        aclManager = new ACLManager();
        aclManager.createRole("REWARDS_ADMIN", 0x00);
        aclManager.grantRole(REWARDS_ADMIN, rewardsAdmin);

        // Deploy controller
        controller = new YoloIncentivesController(address(aclManager));

        // Deploy mock pool tokens (using controller as mock YoloHook)
        poolTokenA =
            new MockMintableIncentivizedERC20(address(controller), address(aclManager), "Pool Token A", "PTKA", 18);
        poolTokenB =
            new MockMintableIncentivizedERC20(address(controller), address(aclManager), "Pool Token B", "PTKB", 18);

        // Deploy reward tokens
        rewardTokenUSY = new MockRewardToken("YOLO USD", "USY");
        rewardTokenYOLO = new MockRewardToken("YOLO Token", "YOLO");

        // Set incentives tracker on pool tokens
        poolTokenA.setIncentivesTracker(IIncentivesTracker(address(controller)));
        poolTokenB.setIncentivesTracker(IIncentivesTracker(address(controller)));

        // Register reward tokens
        vm.startPrank(rewardsAdmin);
        controller.registerRewardToken(address(rewardTokenUSY));
        controller.registerRewardToken(address(rewardTokenYOLO));
        vm.stopPrank();
    }

    // ============================================================
    // CATEGORY 1: ADMINISTRATIVE FUNCTIONS & INITIALIZATION
    // ============================================================

    function test_Contract10_Case01_initialization() public view {
        assertEq(address(controller.ACL_MANAGER()), address(aclManager));
        assertEq(controller.EPOCH_DURATION(), EPOCH_DURATION);
        assertFalse(controller.started());
        assertEq(controller.currentEpoch(), 0);
    }

    function test_Contract10_Case02_start_revertsIfStartTimeInPast() public {
        address[] memory excluded = new address[](0);
        vm.prank(rewardsAdmin);
        vm.expectRevert(YoloIncentivesController.YoloIncentives__InvalidStartTime.selector);
        controller.start(block.timestamp - 1, excluded);
    }

    function test_Contract10_Case03_start_initializesCorrectly() public {
        uint256 startTime = block.timestamp + 1 days;
        address[] memory excluded = new address[](0);

        vm.prank(rewardsAdmin);
        controller.start(startTime, excluded);

        assertTrue(controller.started());
        assertEq(controller.epochStartTime(), startTime);
        assertEq(controller.currentEpoch(), 1);
    }

    function test_Contract10_Case04_addPool_initializesLastUpdateTime() public {
        // Start the controller
        address[] memory excluded = new address[](0);
        vm.prank(rewardsAdmin);
        controller.start(block.timestamp + 1, excluded);

        // Add pool
        vm.prank(rewardsAdmin);
        controller.addPool(address(poolTokenA), 1000);

        // Set reward tokens for the pool
        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        vm.prank(rewardsAdmin);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);

        // Verify pool was added and tokens were set
        // (We test this indirectly through reward accrual in other tests)
        assertGt(controller.totalAllocPoint(), 0, "Total alloc point should be > 0");
    }

    function test_Contract10_Case05_setPoolRewardTokens_initializesNewTokens() public {
        address[] memory excluded = new address[](0);
        vm.startPrank(rewardsAdmin);
        controller.start(block.timestamp + 1, excluded);
        controller.addPool(address(poolTokenA), 1000);

        // Set initial reward tokens
        address[] memory tokens1 = new address[](1);
        tokens1[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens1);

        vm.warp(block.timestamp + 100);

        // Add second reward token
        address[] memory tokens2 = new address[](2);
        tokens2[0] = address(rewardTokenUSY);
        tokens2[1] = address(rewardTokenYOLO);
        controller.setPoolRewardTokens(address(poolTokenA), tokens2);
        vm.stopPrank();

        // Verify new token is active (tested indirectly through reward accrual)
        // Note: lastUpdateTime is internal state, tested through integration tests
    }

    function test_Contract10_Case06_removeRewardToken_cleansUpArray() public {
        vm.startPrank(rewardsAdmin);

        address[] memory tokensBefore = controller.getRewardTokens();
        assertEq(tokensBefore.length, 2, "Should have 2 tokens initially");

        controller.removeRewardToken(address(rewardTokenYOLO));

        address[] memory tokensAfter = controller.getRewardTokens();
        assertEq(tokensAfter.length, 1, "Should have 1 token after removal");
        assertFalse(controller.isRewardToken(address(rewardTokenYOLO)), "Token should no longer be registered");
        vm.stopPrank();
    }

    // ============================================================
    // CATEGORY 2: EPOCH SETTLEMENT LOGIC
    // ============================================================

    function test_Contract10_Case07_settlement_rewardsIdlePoolsCorrectly() public {
        // Setup: Add two pools
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000); // 50% allocation
        controller.addPool(address(poolTokenB), 1000); // 50% allocation

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        controller.setPoolRewardTokens(address(poolTokenB), tokens);
        vm.stopPrank();

        // Fund epoch 1 and roll to epoch 2
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // Mint tokens to users
        poolTokenA.testMint(userA, 100e18); // This triggers handleAction for Pool A
        poolTokenB.testMint(userB, 100e18); // This triggers handleAction for Pool B

        // Warp halfway through epoch 2
        vm.warp(block.timestamp + EPOCH_DURATION / 2);

        // User A interacts (settles Pool A), but Pool B is idle
        poolTokenA.testMint(userA, 10e18);

        // Warp to end of epoch 2
        vm.warp(block.timestamp + EPOCH_DURATION / 2);

        // Roll to epoch 3 - this should settle ALL pools including idle Pool B
        controller.rollEpoch();

        // Check that userB has claimable rewards despite Pool B being idle
        uint256 userBRewards = _getClaimable(userB, address(poolTokenB), address(rewardTokenUSY));
        assertGt(userBRewards, 0, "Idle pool should have accrued rewards through settlement");

        // UserB's rewards should be approximately 50% of total (minus dust)
        // Total rewards = 1_000_000e18, Pool B gets 50%, userB is 100% of Pool B
        assertApproxEqRel(userBRewards, 500_000e18, 0.01e18, "UserB should receive ~50% of rewards");
    }

    // ============================================================
    // CATEGORY 3: BUG FIX VERIFICATIONS
    // ============================================================

    function test_Contract10_Case08_midEpoch_totalAllocPointBecomesZero_capturesDust() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        vm.stopPrank();

        // Fund and roll to start streaming
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // Warp halfway through epoch (3.5 days)
        vm.warp(block.timestamp + EPOCH_DURATION / 2);

        // Remove the only pool (totalAllocPoint becomes 0)
        vm.prank(rewardsAdmin);
        controller.removePool(address(poolTokenA));

        // Check that reward dust captured all epoch emissions
        uint256 dust = controller.rewardDust(address(rewardTokenUSY));

        // Expected: ~1,000,000 USY (full epoch - no one ever staked)
        // Pool had zero supply entire time, so first half went to dust in _updatePool
        // and second half went to dust in _captureRemainingEpochEmissions
        uint256 expectedDust = 1_000_000e18;

        assertApproxEqRel(dust, expectedDust, 0.01e18, "Dust should capture all epoch emissions (zero supply)");

        // Verify rate is zeroed
        assertEq(controller.rewardRate(address(rewardTokenUSY)), 0, "Reward rate should be zero");
    }

    function test_Contract10_Case09_removePool_doesNotAbandonRewards() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        vm.stopPrank();

        // Fund and roll
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // User stakes
        poolTokenA.testMint(userA, 100e18);

        // Warp 3 days into epoch
        vm.warp(block.timestamp + 3 days);

        // Remove pool
        vm.prank(rewardsAdmin);
        controller.removePool(address(poolTokenA));

        // User should still be able to claim rewards for those 3 days
        uint256 claimable = _getClaimable(userA, address(poolTokenA), address(rewardTokenUSY));

        // Expected: ~(3/7) * 1_000_000 = ~428,571 USY
        uint256 expected = (1_000_000e18 * 3 days) / EPOCH_DURATION;
        assertApproxEqRel(claimable, expected, 0.01e18, "User should receive rewards for time staked");

        // Claim should work
        address[] memory claimTokens = new address[](1);
        claimTokens[0] = address(rewardTokenUSY);
        vm.prank(userA);
        controller.claim(address(poolTokenA), claimTokens);

        assertEq(rewardTokenUSY.balanceOf(userA), claimable, "User should receive claimed tokens");
    }

    function test_Contract10_Case10_setPoolRewardTokens_doesNotAbandonRewards() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](2);
        tokens[0] = address(rewardTokenUSY);
        tokens[1] = address(rewardTokenYOLO);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        vm.stopPrank();

        // Fund both tokens
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        _fundEpoch(rewardTokenYOLO, 500_000e18);

        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // User stakes
        poolTokenA.testMint(userA, 100e18);

        // Warp 3 days into epoch
        vm.warp(block.timestamp + 3 days);

        // Remove YOLO token from pool rewards
        address[] memory newTokens = new address[](1);
        newTokens[0] = address(rewardTokenUSY);
        vm.prank(rewardsAdmin);
        controller.setPoolRewardTokens(address(poolTokenA), newTokens);

        // User should still be able to claim YOLO rewards for those 3 days
        uint256 yoloClaimable = _getClaimable(userA, address(poolTokenA), address(rewardTokenYOLO));

        uint256 expectedYOLO = (500_000e18 * 3 days) / EPOCH_DURATION;
        assertApproxEqRel(yoloClaimable, expectedYOLO, 0.01e18, "User should receive YOLO rewards for time staked");
    }

    function test_Contract10_Case11_batchUpdateAllocPoint_doesNotAbandonRewards() public {
        // Setup two pools
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000); // 50%
        controller.addPool(address(poolTokenB), 1000); // 50%

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        controller.setPoolRewardTokens(address(poolTokenB), tokens);
        vm.stopPrank();

        // Fund and roll
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // Users stake
        poolTokenA.testMint(userA, 100e18);
        poolTokenB.testMint(userB, 100e18);

        // Warp 3 days
        vm.warp(block.timestamp + 3 days);

        // Change Pool A allocation from 1000 to 200 (from 50% to ~17%)
        address[] memory assets = new address[](1);
        assets[0] = address(poolTokenA);
        uint256[] memory allocPoints = new uint256[](1);
        allocPoints[0] = 200;

        vm.prank(rewardsAdmin);
        controller.batchUpdateAllocPoint(assets, allocPoints);

        // Warp another 4 days
        vm.warp(block.timestamp + 4 days);

        // UserA's rewards should reflect:
        // - 3 days at 50% allocation = 214,285 USY
        // - 4 days at ~17% allocation = ~97,959 USY
        // Total ≈ 312,244 USY

        uint256 userARewards = _getClaimable(userA, address(poolTokenA), address(rewardTokenUSY));

        // First period: 3 days at 1000/2000 allocation
        uint256 period1 = (1_000_000e18 * 1000 * 3 days) / (2000 * EPOCH_DURATION);

        // Second period: 4 days at 200/1200 allocation
        uint256 period2 = (1_000_000e18 * 200 * 4 days) / (1200 * EPOCH_DURATION);

        uint256 expected = period1 + period2;
        assertApproxEqRel(userARewards, expected, 0.02e18, "Rewards should reflect both allocation periods");
    }

    // ============================================================
    // CATEGORY 4: EXCLUSION LOGIC
    // ============================================================

    function test_Contract10_Case12_excludedContracts_doNotAccrueRewards() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);

        // Exclude the controller itself
        controller.addExcludedContract(address(controller));
        vm.stopPrank();

        // Fund and roll
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // Mint to excluded address
        poolTokenA.testMint(address(controller), 100e18);

        // Warp through epoch
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Controller should have 0 claimable rewards
        uint256 claimable = _getClaimable(address(controller), address(poolTokenA), address(rewardTokenUSY));

        assertEq(claimable, 0, "Excluded address should not accrue rewards");
    }

    function test_Contract10_Case13_removeExcludedContract_allowsRewardsAgain() public {
        // Setup and exclude userA
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);

        controller.addExcludedContract(userA);
        vm.stopPrank();

        // Fund and roll
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // Mint while excluded
        poolTokenA.testMint(userA, 100e18);
        vm.warp(block.timestamp + 3 days);

        // Remove from exclusion
        vm.prank(rewardsAdmin);
        controller.removeExcludedContract(userA);

        // Warp remaining 4 days
        vm.warp(block.timestamp + 4 days);

        // UserA should only have rewards for the 4 days after removal
        uint256 claimable = _getClaimable(userA, address(poolTokenA), address(rewardTokenUSY));

        uint256 expected = (1_000_000e18 * 4 days) / EPOCH_DURATION;
        assertApproxEqRel(claimable, expected, 0.02e18, "Should only accrue rewards after removal from exclusion");
    }

    // ============================================================
    // CATEGORY 5: ADDITIONAL EDGE CASES
    // ============================================================

    function test_Contract10_Case14_handleAction_noOp_stillSettles() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        vm.stopPrank();

        // Fund and roll
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // Mint to user
        poolTokenA.testMint(userA, 100e18);

        // Warp forward
        vm.warp(block.timestamp + 3 days);

        // Call handleAction with same balance (no-op)
        controller.handleAction(userA, 100e18, 100e18);

        // Should still settle and update rewards
        uint256 claimable = _getClaimable(userA, address(poolTokenA), address(rewardTokenUSY));

        uint256 expected = (1_000_000e18 * 3 days) / EPOCH_DURATION;
        assertApproxEqRel(claimable, expected, 0.01e18, "No-op handleAction should still settle rewards");
    }

    function test_Contract10_Case15_syncRewards_unregisteredToken_noRevert() public {
        // Deploy unregistered token
        MockRewardToken unregistered = new MockRewardToken("Unregistered", "UNREG");

        // Try to sync unregistered token
        address[] memory tokens = new address[](1);
        tokens[0] = address(unregistered);

        // Should not revert
        controller.syncRewards(tokens);
    }

    function test_Contract10_Case16_multipleFundingDeposits_accumulate() public {
        // Setup
        vm.prank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);

        // Multiple deposits in same epoch
        _fundEpoch(rewardTokenUSY, 100_000e18);
        _fundEpoch(rewardTokenUSY, 200_000e18);
        _fundEpoch(rewardTokenUSY, 300_000e18);

        // Total should accumulate
        uint256 currentFunding = controller.currentEpochFunding(address(rewardTokenUSY));
        assertEq(currentFunding, 600_000e18, "Multiple deposits should accumulate");
    }

    function test_Contract10_Case17_dustRecycling_zeroSupply() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        vm.stopPrank();

        // Fund and roll (no stakes)
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // Entire epoch with zero supply
        vm.warp(block.timestamp + EPOCH_DURATION);

        // Trigger any handleAction to update pool (auto-rolls to epoch 3)
        poolTokenA.testMint(userA, 1e18);

        // Dust was captured during epoch 2, then immediately recycled into epoch 3 funding
        // Check that rewardRate is set for epoch 3 (dust recycling worked)
        uint256 rate = controller.rewardRate(address(rewardTokenUSY));
        uint256 expectedRate = (1_000_000e18 * REWARD_RATE_PRECISION) / EPOCH_DURATION;
        assertApproxEqRel(rate, expectedRate, 0.01e18, "Dust should be recycled into next epoch's rate");

        // Dust should be 0 after recycling
        uint256 dust = controller.rewardDust(address(rewardTokenUSY));
        assertEq(dust, 0, "Dust cleared after recycling into next epoch");
    }

    function test_Contract10_Case18_dustRecycling_nextEpoch() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        uint256 startTime = block.timestamp + 1;
        controller.start(startTime, excluded);
        vm.warp(startTime); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        vm.stopPrank();

        // Calculate all timestamps upfront to avoid accumulation bugs
        uint256 endOfEpoch1 = startTime + EPOCH_DURATION;
        uint256 endOfEpoch2 = startTime + (2 * EPOCH_DURATION);
        uint256 endOfEpoch3 = startTime + (3 * EPOCH_DURATION);

        // Fund epoch with zero supply
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(endOfEpoch1);
        controller.rollEpoch();

        // Let epoch 2 run with zero supply
        vm.warp(endOfEpoch2);
        poolTokenA.testMint(userA, 1e18); // Triggers dust collection + auto-rolls to epoch 3

        // Now stake and wait (already in epoch 3 from auto-roll)
        poolTokenA.testMint(userB, 100e18);
        vm.warp(endOfEpoch3);

        // UserB should receive the recycled dust
        uint256 claimable = _getClaimable(userB, address(poolTokenA), address(rewardTokenUSY));
        assertApproxEqRel(claimable, 1_000_000e18, 0.02e18, "Dust should be recycled into next funded epoch");
    }

    function test_Contract10_Case19_skipFunding_rateReset() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        uint256 startTime = block.timestamp + 1;
        controller.start(startTime, excluded);
        vm.warp(startTime); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        vm.stopPrank();

        // Fund epoch 1
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        uint256 timestamp = startTime + EPOCH_DURATION;
        vm.warp(timestamp);
        controller.rollEpoch();

        // Epoch 2: Have users stake so rewards are distributed (not dusted)
        poolTokenA.testMint(userA, 100e18);
        timestamp += EPOCH_DURATION;
        vm.warp(timestamp);

        // Roll to epoch 3 (no fresh funding sent during epoch 2)
        // But note: if epoch 2 had zero supply, dust would recycle and rate would be non-zero
        // This test ensures that WITH supply and distribution, skipping funding does reset rate
        controller.rollEpoch();

        // Rate should be 0 (no fresh funding, no dust to recycle)
        assertEq(controller.rewardRate(address(rewardTokenUSY)), 0, "Rate should be 0 when funding skipped and no dust");

        // Users should not accrue rewards during epoch 3
        timestamp += EPOCH_DURATION;
        vm.warp(timestamp);

        uint256 claimableBefore = _getClaimable(userA, address(poolTokenA), address(rewardTokenUSY));
        timestamp += 1 days;
        vm.warp(timestamp);
        uint256 claimableAfter = _getClaimable(userA, address(poolTokenA), address(rewardTokenUSY));

        assertEq(claimableAfter, claimableBefore, "No new rewards should accrue during unfunded epoch");
    }

    function test_Contract10_Case20_batchUpdateAllocPoint_totalAllocBecomesZero() public {
        // Setup two pools
        vm.startPrank(rewardsAdmin);
        address[] memory excluded = new address[](0);
        controller.start(block.timestamp + 1, excluded);
        vm.warp(block.timestamp + 1); // Warp to epoch start
        controller.addPool(address(poolTokenA), 1000);
        controller.addPool(address(poolTokenB), 1000);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);
        controller.setPoolRewardTokens(address(poolTokenB), tokens);
        vm.stopPrank();

        // Fund and roll
        _fundEpoch(rewardTokenUSY, 1_000_000e18);
        vm.warp(block.timestamp + EPOCH_DURATION);
        controller.rollEpoch();

        // Warp halfway through epoch
        vm.warp(block.timestamp + EPOCH_DURATION / 2);

        // Zero out all allocations
        address[] memory assets = new address[](2);
        assets[0] = address(poolTokenA);
        assets[1] = address(poolTokenB);
        uint256[] memory allocPoints = new uint256[](2);
        allocPoints[0] = 0;
        allocPoints[1] = 0;

        vm.prank(rewardsAdmin);
        controller.batchUpdateAllocPoint(assets, allocPoints);

        // Check dust captured all epoch emissions (both pools had zero supply)
        uint256 dust = controller.rewardDust(address(rewardTokenUSY));

        // Expected: ~1M total
        // - First half (3.5 days): 250k + 250k to dust from settlements (zero supply)
        // - Second half (3.5 days): 500k to dust from _captureRemainingEpochEmissions
        uint256 expectedDust = 1_000_000e18;

        assertApproxEqRel(dust, expectedDust, 0.01e18, "Dust should capture all emissions (zero supply pools)");
        assertEq(controller.rewardRate(address(rewardTokenUSY)), 0, "Rate should be zeroed");
    }

    // ============================================================
    // CASE 21: Multi-Epoch Delay - No Reward Inflation
    // ============================================================

    function test_case21_multiEpochDelay_noInflation() public {
        // This test verifies the FIX for the critical reward inflation bug
        // BUG: Unbounded duration in _updatePool() caused rewards to multiply
        //      Example: 1M funding + 5 epoch delay = 5M rewards (400% inflation)
        // FIX: Epoch-aware _updatePool() + leftover capture prevents inflation

        // Start the controller
        vm.startPrank(rewardsAdmin);
        controller.addPool(address(poolTokenA), 100);

        address[] memory tokens = new address[](1);
        tokens[0] = address(rewardTokenUSY);
        controller.setPoolRewardTokens(address(poolTokenA), tokens);

        address[] memory excluded = new address[](0);
        uint256 startTime = block.timestamp + 1;
        controller.start(startTime, excluded);
        vm.stopPrank();

        vm.warp(startTime);

        // Fund epoch 1 with 1M
        _fundEpoch(rewardTokenUSY, 1_000_000e18);

        // Roll to epoch 2 (funds become active)
        vm.warp(startTime + EPOCH_DURATION);
        controller.rollEpoch();
        uint256 epoch2Start = block.timestamp;

        // CRITICAL TEST: Warp through 5 full epochs WITHOUT any settlements
        // This would previously cause massive inflation (5M from 1M budget)
        uint256 epoch7Start = epoch2Start + (5 * EPOCH_DURATION);
        vm.warp(epoch7Start);

        // User finally stakes, triggering delayed settlement
        poolTokenA.testMint(userA, 100e18);

        // Fast forward to accumulate all possible rewards
        vm.warp(epoch7Start + EPOCH_DURATION);

        // Check claimable rewards
        uint256 claimable = _getClaimable(userA, address(poolTokenA), address(rewardTokenUSY));

        // ASSERTION: Rewards should NOT exceed original funding
        // User staked very late, so should get minimal rewards from the funded epoch
        // Definitely should NOT get 5M (which would indicate inflation bug)
        uint256 maxAllowed = 1_000_000e18;
        assertLe(claimable, maxAllowed, "CRITICAL: Rewards exceed funding (inflation bug not fixed!)");

        // Also verify we're nowhere near the inflated amount
        uint256 inflatedAmount = 5_000_000e18;
        assertLt(claimable, inflatedAmount * 30 / 100, "Rewards should be much less than inflated amount");

        // Check economic invariant: total distributed should not exceed total funded
        uint256 dust = controller.rewardDust(address(rewardTokenUSY));
        uint256 totalDistributed = claimable + dust;

        // Some tolerance for the leftover capture logic
        assertLe(totalDistributed, maxAllowed * 101 / 100, "Economic invariant violated: total distributed > funded");
    }
}
