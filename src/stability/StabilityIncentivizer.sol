// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IStabilityTracker} from "../interfaces/IStabilityTracker.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title StabilityIncentivizer
 * @author alvin@yolo.wtf
 * @notice Rewards traders who help maintain the USY-USDC peg at 1:1
 * @dev Implements IStabilityTracker with snapshot-based epoch rewards
 *      Uses net distance improvement scoring with multi-token support
 *
 * INTEGRATOR NOTES:
 * 1. TreasuryForwarder sends funds directly via ERC20 transfer (no hooks/callbacks)
 * 2. Automatic epoch rollover occurs when epoch duration passes, triggered by:
 *    - beforeSwapUpdate() / afterSwapUpdate() (swap operations)
 *    - claimReward() / claimAllRewards() (claiming operations)
 *    - Manual rollEpoch() calls (permissionless, anyone can trigger)
 * 3. Rewards are automatically synced on:
 *    - rollEpoch() (syncs all tokens before allocation)
 *    - claimReward() (syncs that specific token)
 *    - claimAllRewards() (syncs all tokens)
 *    - Manual syncRewards(tokens[]) calls (permissionless, anyone can trigger)
 * 4. registerRewardToken() automatically syncs existing balance to current epoch
 * 5. Unclaimed rewards from previous epochs do NOT affect new epoch funding calculations
 * 6. For retroactive token registration: existing balance is allocated to CURRENT epoch
 */
contract StabilityIncentivizer is IStabilityTracker, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Target peg price in 8 decimals (1.00000000 = $1.00)
    uint256 public constant PEG_PRICE = 1_00000000;

    /// @notice Price precision (8 decimals)
    uint256 public constant PRICE_PRECISION = 1e8;

    /// @notice Minimum epoch duration (1 day)
    uint256 public constant MIN_EPOCH_DURATION = 1 days;

    /// @notice Maximum epoch duration (30 days)
    uint256 public constant MAX_EPOCH_DURATION = 30 days;

    // ============================================================
    // IMMUTABLES
    // ============================================================

    /// @notice YoloHook address (only authorized caller for swap updates)
    address public immutable YOLO_HOOK;

    /// @notice ACL Manager for role-based access control
    IACLManager public immutable ACL_MANAGER;

    /// @notice USDC decimals (6 or 18 depending on chain)
    uint8 public immutable USDC_DECIMALS;

    /// @notice Role hash for rewards admin
    bytes32 private constant REWARDS_ADMIN = keccak256("REWARDS_ADMIN");

    // ============================================================
    // STATE VARIABLES - EPOCH MANAGEMENT
    // ============================================================

    /// @notice Current epoch number (increments on rollover)
    uint256 public currentEpoch;

    /// @notice Epoch duration in seconds (default: 7 days)
    uint256 public epochDuration;

    /// @notice Timestamp when current epoch started
    uint256 public epochStartTime;

    /// @notice Paused state
    bool public paused;

    // ============================================================
    // STATE VARIABLES - POINTS TRACKING
    // ============================================================

    /// @notice User stability points per epoch (can be negative)
    /// @dev epoch => user => points (int256 because points can be negative)
    mapping(uint256 => mapping(address => int256)) public userPointsPerEpoch;

    /// @notice Total positive points accumulated in epoch
    /// @dev epoch => total positive points (sum of all users with points > 0)
    mapping(uint256 => uint256) public totalPositivePointsPerEpoch;

    /// @notice Pending swap data (before reserves stored temporarily)
    struct PendingSwap {
        uint256 reserveUSDCBefore;
        uint256 reserveUSYBefore;
        bool isPending;
    }

    /// @notice Temporary storage for before-swap data
    /// @dev swapper => pending swap data
    mapping(address => PendingSwap) private _pendingSwaps;

    // ============================================================
    // STATE VARIABLES - REWARD TOKENS
    // ============================================================

    /// @notice Registered reward tokens
    address[] public rewardTokens;

    /// @notice Check if token is registered
    mapping(address => bool) public isRewardToken;

    /// @notice Current epoch funding (not yet allocated to an epoch)
    /// @dev token => amount
    mapping(address => uint256) public currentEpochFunding;

    /// @notice Total rewards allocated per epoch per token
    /// @dev epoch => token => amount
    mapping(uint256 => mapping(address => uint256)) public epochRewards;

    /// @notice Total claimed per epoch per token
    /// @dev epoch => token => amount
    mapping(uint256 => mapping(address => uint256)) public epochClaimed;

    /// @notice User claimed status per epoch per token
    /// @dev epoch => user => token => claimed
    mapping(uint256 => mapping(address => mapping(address => bool))) public hasClaimed;

    /// @notice Accounted balance = currentEpochFunding + ∑epochRewards - ∑epochClaimed
    /// @dev Internal accounting to detect new transfers
    mapping(address => uint256) public accountedBalance;

    // ============================================================
    // ERRORS
    // ============================================================

    error StabilityIncentivizer__Unauthorized();
    error StabilityIncentivizer__Paused();
    error StabilityIncentivizer__NoPendingSwap();
    error StabilityIncentivizer__EpochNotFinished();
    error StabilityIncentivizer__EpochNotEnded();
    error StabilityIncentivizer__InvalidDuration();
    error StabilityIncentivizer__TokenNotRegistered();
    error StabilityIncentivizer__TokenAlreadyRegistered();
    error StabilityIncentivizer__AlreadyClaimed();
    error StabilityIncentivizer__NoPositivePoints();
    error StabilityIncentivizer__NoPointsInEpoch();
    error StabilityIncentivizer__InvalidAddress();

    // ============================================================
    // EVENTS
    // ============================================================

    event StabilityPointsEarned(
        address indexed swapper,
        uint256 indexed epoch,
        int256 points,
        uint256 priceBefore,
        uint256 priceAfter,
        uint256 reserveUSDC,
        uint256 reserveUSY
    );
    event EpochAdvanced(uint256 indexed newEpoch, uint256 startTime);
    event RewardTokenRegistered(address indexed token);
    event RewardSynced(uint256 indexed epoch, address indexed token, uint256 amount);
    event EpochRewardsAllocated(uint256 indexed epoch, address indexed token, uint256 amount);
    event RewardsClaimed(address indexed user, uint256 indexed epoch, address indexed token, uint256 amount);
    event EpochDurationUpdated(uint256 newDuration);
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyYoloHook() {
        if (msg.sender != YOLO_HOOK) revert StabilityIncentivizer__Unauthorized();
        _;
    }

    modifier onlyRewardsAdmin() {
        if (
            !ACL_MANAGER.hasRole(REWARDS_ADMIN, msg.sender) && !ACL_MANAGER.hasRole(0x00, msg.sender) // DEFAULT_ADMIN
        ) {
            revert StabilityIncentivizer__Unauthorized();
        }
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert StabilityIncentivizer__Paused();
        _;
    }

    modifier checkEpoch() {
        if (block.timestamp >= epochStartTime + epochDuration) {
            _rollEpoch();
        }
        _;
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize StabilityIncentivizer
     * @param _yoloHook YoloHook address (only authorized caller)
     * @param _aclManager ACL Manager for role-based access control
     * @param _usdcDecimals USDC decimals (6 or 18)
     * @param _epochDuration Initial epoch duration in seconds
     */
    constructor(address _yoloHook, address _aclManager, uint8 _usdcDecimals, uint256 _epochDuration) {
        if (_yoloHook == address(0)) revert StabilityIncentivizer__InvalidAddress();
        if (_aclManager == address(0)) revert StabilityIncentivizer__InvalidAddress();
        if (_epochDuration < MIN_EPOCH_DURATION || _epochDuration > MAX_EPOCH_DURATION) {
            revert StabilityIncentivizer__InvalidDuration();
        }

        YOLO_HOOK = _yoloHook;
        ACL_MANAGER = IACLManager(_aclManager);
        USDC_DECIMALS = _usdcDecimals;
        epochDuration = _epochDuration;
        epochStartTime = block.timestamp;
        currentEpoch = 1;
    }

    // ============================================================
    // ISTABILITYTRACKER IMPLEMENTATION
    // ============================================================

    /**
     * @notice Called before anchor pool swap executes
     * @dev Stores reserve snapshot for later point calculation
     *      Automatically rolls epoch if duration has passed
     * @param swapper Original trader address
     * @param reserveUSDC USDC reserve before swap (native decimals - 6 or 18)
     * @param reserveUSY USY reserve before swap (18 decimals)
     */
    function beforeSwapUpdate(address swapper, uint256 reserveUSDC, uint256 reserveUSY)
        external
        override
        onlyYoloHook
        whenNotPaused
        checkEpoch
    {
        _pendingSwaps[swapper] =
            PendingSwap({reserveUSDCBefore: reserveUSDC, reserveUSYBefore: reserveUSY, isPending: true});
    }

    /**
     * @notice Called after anchor pool swap executes
     * @dev Calculates price movement and awards/deducts points
     *      Automatically rolls epoch if duration has passed
     * @param swapper Original trader address
     * @param reserveUSDC USDC reserve after swap (native decimals - 6 or 18)
     * @param reserveUSY USY reserve after swap (18 decimals)
     */
    function afterSwapUpdate(address swapper, uint256 reserveUSDC, uint256 reserveUSY)
        external
        override
        onlyYoloHook
        whenNotPaused
        checkEpoch
    {
        // Retrieve before-swap data
        PendingSwap memory pending = _pendingSwaps[swapper];
        if (!pending.isPending) revert StabilityIncentivizer__NoPendingSwap();

        // Calculate prices (8 decimals)
        uint256 priceBefore = _calculateUSYPrice(pending.reserveUSDCBefore, pending.reserveUSYBefore);
        uint256 priceAfter = _calculateUSYPrice(reserveUSDC, reserveUSY);

        // Calculate points (net distance improvement)
        int256 points = _calculatePoints(priceBefore, priceAfter);

        // Update user points for current epoch
        int256 oldPoints = userPointsPerEpoch[currentEpoch][swapper];
        int256 newPoints = oldPoints + points;
        userPointsPerEpoch[currentEpoch][swapper] = newPoints;

        // Update total positive points
        _updateTotalPositivePoints(currentEpoch, swapper, oldPoints, newPoints);

        // Clear pending swap
        delete _pendingSwaps[swapper];

        // Emit event
        emit StabilityPointsEarned(swapper, currentEpoch, points, priceBefore, priceAfter, reserveUSDC, reserveUSY);
    }

    // ============================================================
    // PRICE CALCULATION
    // ============================================================

    /**
     * @notice Calculate USY price in USDC (8 decimals)
     * @dev Uses StableSwap reserves, normalizes USDC to 18 decimals first
     *      Simplified formula: price = (USDC / USY) * 1e8
     * @param reserveUSDC USDC reserve (native decimals - 6 or 18)
     * @param reserveUSY USY reserve (18 decimals)
     * @return price USY price in USDC (8 decimals, e.g., 100000000 = $1.00)
     */
    function _calculateUSYPrice(uint256 reserveUSDC, uint256 reserveUSY) internal view returns (uint256 price) {
        // Normalize USDC to 18 decimals
        uint256 reserveUSDC18 = USDC_DECIMALS == 6 ? reserveUSDC * 1e12 : reserveUSDC;

        // price = (USDC / USY) * 1e8
        // = (reserveUSDC18 * 1e8) / reserveUSY
        price = (reserveUSDC18 * PRICE_PRECISION) / reserveUSY;
    }

    /**
     * @notice Calculate stability points from price movement
     * @dev Net distance improvement: distanceBefore - distanceAfter
     *      Positive = moved closer to peg, Negative = moved away from peg
     * @param priceBefore Price before swap (8 decimals)
     * @param priceAfter Price after swap (8 decimals)
     * @return points Stability points (can be negative)
     */
    function _calculatePoints(uint256 priceBefore, uint256 priceAfter) internal pure returns (int256 points) {
        // Calculate absolute distances from peg
        uint256 distanceBefore = priceBefore > PEG_PRICE ? priceBefore - PEG_PRICE : PEG_PRICE - priceBefore;

        uint256 distanceAfter = priceAfter > PEG_PRICE ? priceAfter - PEG_PRICE : PEG_PRICE - priceAfter;

        // Net improvement (positive = closer to peg, negative = further)
        points = SafeCast.toInt256(distanceBefore) - SafeCast.toInt256(distanceAfter);
    }

    /**
     * @notice Update total positive points when user's points change
     * @dev Recalculates total by adjusting for user's contribution
     * @param epoch Epoch number
     * @param user User address
     * @param oldPoints User's old points
     * @param newPoints User's new points
     */
    function _updateTotalPositivePoints(uint256 epoch, address user, int256 oldPoints, int256 newPoints) internal {
        uint256 total = totalPositivePointsPerEpoch[epoch];

        // Remove old contribution if it was positive
        if (oldPoints > 0) {
            total -= SafeCast.toUint256(oldPoints);
        }

        // Add new contribution if it's positive
        if (newPoints > 0) {
            total += SafeCast.toUint256(newPoints);
        }

        totalPositivePointsPerEpoch[epoch] = total;
    }

    // ============================================================
    // REWARD TOKEN MANAGEMENT
    // ============================================================

    /**
     * @notice Register a new reward token
     * @dev Only rewards admin can register tokens
     *      Automatically syncs existing balance to current epoch funding via _syncSingleReward
     *      IMPORTANT: Any balance already in the contract will be allocated to the CURRENT epoch
     * @param token Token address to register
     */
    function registerRewardToken(address token) external onlyRewardsAdmin {
        if (token == address(0)) revert StabilityIncentivizer__InvalidAddress();
        if (isRewardToken[token]) revert StabilityIncentivizer__TokenAlreadyRegistered();

        isRewardToken[token] = true;
        rewardTokens.push(token);

        // Use _syncSingleReward for uniform handling of balance detection
        // This handles edge cases and ensures consistent accounting
        _syncSingleReward(token);

        emit RewardTokenRegistered(token);
    }

    /**
     * @notice Sync reward token balances (permissionless)
     * @dev Compares actual balance vs accounted balance, books the delta
     * @param tokens Array of token addresses to sync
     */
    function syncRewards(address[] calldata tokens) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            _syncSingleReward(tokens[i]);
        }
    }

    /**
     * @notice Sync a single reward token
     * @dev Internal function to sync one token
     * @param token Token address to sync
     */
    function _syncSingleReward(address token) internal {
        if (!isRewardToken[token]) revert StabilityIncentivizer__TokenNotRegistered();

        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        uint256 accounted = accountedBalance[token];

        if (actualBalance > accounted) {
            uint256 newFunding = actualBalance - accounted;
            currentEpochFunding[token] += newFunding;
            accountedBalance[token] = actualBalance;
            emit RewardSynced(currentEpoch, token, newFunding);
        }
    }

    // ============================================================
    // EPOCH MANAGEMENT
    // ============================================================

    /**
     * @notice Advance to next epoch and allocate rewards
     * @dev Anyone can call once epoch duration has passed
     *      Automatically syncs all reward tokens before allocation
     */
    function rollEpoch() external {
        if (block.timestamp < epochStartTime + epochDuration) {
            revert StabilityIncentivizer__EpochNotFinished();
        }
        _rollEpoch();
    }

    /**
     * @notice Internal epoch rollover logic
     * @dev Called by rollEpoch() or checkEpoch modifier
     */
    function _rollEpoch() internal {
        // 1. Sync all reward tokens to capture any pending transfers
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _syncSingleReward(rewardTokens[i]);
        }

        // 2. Allocate current funding to this epoch
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            uint256 funding = currentEpochFunding[token];

            if (funding > 0) {
                epochRewards[currentEpoch][token] = funding;
                currentEpochFunding[token] = 0;
                emit EpochRewardsAllocated(currentEpoch, token, funding);
            }
        }

        // 3. Advance epoch
        currentEpoch++;
        epochStartTime = block.timestamp;

        emit EpochAdvanced(currentEpoch, epochStartTime);
    }

    // ============================================================
    // CLAIMING
    // ============================================================

    /**
     * @notice Claim rewards for a specific token and epoch
     * @dev Automatically syncs the token before claiming to capture any pending funding
     *      Automatically rolls epoch if duration has passed
     * @param epoch Epoch number to claim from
     * @param token Reward token address
     */
    function claimReward(uint256 epoch, address token) external nonReentrant checkEpoch {
        // Automatically sync this token to capture any new funding
        _syncSingleReward(token);

        if (epoch >= currentEpoch) revert StabilityIncentivizer__EpochNotEnded();
        if (!isRewardToken[token]) revert StabilityIncentivizer__TokenNotRegistered();
        if (hasClaimed[epoch][msg.sender][token]) revert StabilityIncentivizer__AlreadyClaimed();

        int256 userPoints = userPointsPerEpoch[epoch][msg.sender];
        if (userPoints <= 0) revert StabilityIncentivizer__NoPositivePoints();

        uint256 totalRewards = epochRewards[epoch][token];
        uint256 totalPoints = totalPositivePointsPerEpoch[epoch];

        if (totalPoints == 0) revert StabilityIncentivizer__NoPointsInEpoch();

        // Calculate user's share: (userPoints / totalPoints) * totalRewards
        uint256 userReward = (SafeCast.toUint256(userPoints) * totalRewards) / totalPoints;

        if (userReward == 0) return; // No rewards to claim

        // Mark as claimed
        hasClaimed[epoch][msg.sender][token] = true;
        epochClaimed[epoch][token] += userReward;

        // Update accounted balance (claimed rewards leave the contract)
        accountedBalance[token] -= userReward;

        // Transfer rewards (using SafeERC20)
        IERC20(token).safeTransfer(msg.sender, userReward);

        emit RewardsClaimed(msg.sender, epoch, token, userReward);
    }

    /**
     * @notice Claim all available tokens for a specific epoch
     * @dev Automatically syncs all tokens before claiming to capture any pending funding
     *      Automatically rolls epoch if duration has passed
     *      Uses nonReentrant guard to prevent reentrancy attacks via malicious reward tokens
     * @param epoch Epoch number to claim from
     */
    function claimAllRewards(uint256 epoch) external nonReentrant checkEpoch {
        if (epoch >= currentEpoch) revert StabilityIncentivizer__EpochNotEnded();

        // Sync all reward tokens before claiming
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _syncSingleReward(rewardTokens[i]);
        }

        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address token = rewardTokens[i];
            if (!hasClaimed[epoch][msg.sender][token]) {
                // Call internal version without reentrancy guard
                _claimRewardInternal(epoch, token, msg.sender);
            }
        }
    }

    /**
     * @notice Internal claim function (without reentrancy guard)
     * @param epoch Epoch number
     * @param token Token address
     * @param user User address
     */
    function _claimRewardInternal(uint256 epoch, address token, address user) internal {
        if (hasClaimed[epoch][user][token]) return;

        int256 userPoints = userPointsPerEpoch[epoch][user];
        if (userPoints <= 0) return;

        uint256 totalRewards = epochRewards[epoch][token];
        uint256 totalPoints = totalPositivePointsPerEpoch[epoch];

        if (totalPoints == 0) return;

        uint256 userReward = (SafeCast.toUint256(userPoints) * totalRewards) / totalPoints;

        if (userReward == 0) return;

        hasClaimed[epoch][user][token] = true;
        epochClaimed[epoch][token] += userReward;
        accountedBalance[token] -= userReward;

        IERC20(token).safeTransfer(user, userReward);

        emit RewardsClaimed(user, epoch, token, userReward);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get claimable reward amount for user
     * @param user User address
     * @param epoch Epoch number
     * @param token Reward token
     * @return amount Claimable amount
     */
    function getClaimableReward(address user, uint256 epoch, address token) external view returns (uint256 amount) {
        if (epoch >= currentEpoch) return 0; // Epoch not finished
        if (hasClaimed[epoch][user][token]) return 0; // Already claimed

        int256 userPoints = userPointsPerEpoch[epoch][user];
        if (userPoints <= 0) return 0; // No positive points

        uint256 totalRewards = epochRewards[epoch][token];
        uint256 totalPoints = totalPositivePointsPerEpoch[epoch];

        if (totalPoints == 0) return 0;

        return (SafeCast.toUint256(userPoints) * totalRewards) / totalPoints;
    }

    /**
     * @notice Get projected rewards for current epoch (if it ended now)
     * @param user User address
     * @param token Reward token
     * @return amount Projected amount
     */
    function getProjectedReward(address user, address token) external view returns (uint256 amount) {
        int256 userPoints = userPointsPerEpoch[currentEpoch][user];
        if (userPoints <= 0) return 0;

        uint256 totalPoints = totalPositivePointsPerEpoch[currentEpoch];
        if (totalPoints == 0) return 0;

        uint256 projectedRewards = currentEpochFunding[token];
        return (SafeCast.toUint256(userPoints) * projectedRewards) / totalPoints;
    }

    /**
     * @notice Get all registered reward tokens
     * @return tokens Array of reward token addresses
     */
    function getRewardTokens() external view returns (address[] memory tokens) {
        return rewardTokens;
    }

    /**
     * @notice Get number of registered reward tokens
     * @return count Number of tokens
     */
    function getRewardTokenCount() external view returns (uint256 count) {
        return rewardTokens.length;
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Update epoch duration
     * @dev Only rewards admin, takes effect from next epoch
     * @param newDuration New duration in seconds
     */
    function setEpochDuration(uint256 newDuration) external onlyRewardsAdmin {
        if (newDuration < MIN_EPOCH_DURATION || newDuration > MAX_EPOCH_DURATION) {
            revert StabilityIncentivizer__InvalidDuration();
        }
        epochDuration = newDuration;
        emit EpochDurationUpdated(newDuration);
    }

    /**
     * @notice Pause the contract
     * @dev Only rewards admin can pause
     */
    function pause() external onlyRewardsAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the contract
     * @dev Only rewards admin can unpause
     */
    function unpause() external onlyRewardsAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }
}
