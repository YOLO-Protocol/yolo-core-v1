// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IIncentivesTracker} from "../interfaces/IIncentivesTracker.sol";
import {IOnwardIncentivesController} from "../interfaces/IOnwardIncentivesController.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title YoloIncentivesController
 * @author alvin@yolo.wtf
 * @notice Hybrid reward distribution system combining allocation points, streaming rewards, and epoch-based funding
 * @dev Combines ChefIncentivesController's allocation system with MultiFeeDistribution's streaming and
 *      StabilityIncentivizer's epoch funding model. Supports multiple reward tokens with per-pool active token lists.
 *
 * KEY FEATURES:
 * - Allocation Points: Weighted distribution across pools (YLP, sUSY, synthetic assets)
 * - 7-Day Epochs: Funds received in epoch N stream during epoch N+1 (1-epoch delay)
 * - Streaming Rewards: Continuous per-second accrual based on user's pool share
 * - Multi-Token Support: Multiple reward tokens (USY, yNVDA, yTSLA, etc.)
 * - Per-Pool Active Tokens: Gas optimization - each pool only tracks 2-10 active tokens
 * - Exclusion List: Prevents contracts from earning rewards (StabilityIncentivizer, etc.)
 * - Auto-Rollover: Automatic epoch advancement in claim/handleAction operations
 * - Onward Incentives: Support for chaining incentive controllers
 *
 * CRITICAL GAS OPTIMIZATION:
 * Each pool has its own activeRewardTokens array (subset of global rewardTokens).
 * This prevents handleAction from looping through 100+ global tokens on every transfer.
 * Admin must call setPoolRewardTokens() to configure which tokens are active per pool.
 */
contract YoloIncentivesController is IIncentivesTracker, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Epoch duration (7 days)
    uint256 public constant EPOCH_DURATION = 7 days;

    /// @notice Precision for reward calculations (1e12)
    uint256 private constant PRECISION = 1e12;

    /// @notice Precision for reward rate calculations (1e18)
    /// @dev Prevents integer division rounding to zero in rewardRate
    uint256 private constant REWARD_RATE_PRECISION = 1e18;

    // ============================================================
    // IMMUTABLES
    // ============================================================

    /// @notice ACL Manager for role-based access control
    IACLManager public immutable ACL_MANAGER;

    /// @notice Role hash for rewards admin
    bytes32 private constant REWARDS_ADMIN = keccak256("REWARDS_ADMIN");

    /// @notice Role hash for default admin (fallback)
    bytes32 private constant DEFAULT_ADMIN = 0x00;

    // ============================================================
    // STATE VARIABLES - EPOCH MANAGEMENT
    // ============================================================

    /// @notice Current epoch number
    uint256 public currentEpoch;

    /// @notice Timestamp when current epoch started
    uint256 public epochStartTime;

    /// @notice Whether the contract has been started
    bool public started;

    // ============================================================
    // STATE VARIABLES - POOL MANAGEMENT
    // ============================================================

    /// @notice Per-reward-token state (independent timestamps prevent zero-reward bug)
    struct RewardState {
        uint256 lastUpdateTime; // Last time this specific token was updated
        uint256 accRewardPerShare; // Accumulated rewards per share (1e12 precision)
    }

    /// @notice Pool information
    struct PoolInfo {
        uint256 totalSupply; // Total supply EXCLUDING excluded contracts
        uint256 totalSupplyRaw; // Raw total supply from ERC20 (includes excluded)
        uint256 allocPoint; // Allocation points for this pool
        address[] activeRewardTokens; // Tokens active for THIS pool (gas optimization)
        mapping(address => RewardState) rewardState; // Per-token state
        IOnwardIncentivesController onwardIncentives; // Optional chained controller
    }

    /// @notice Pool info by asset address
    mapping(address => PoolInfo) public poolInfo;

    /// @notice Array of all registered asset addresses (for settlement)
    /// @dev Critical for epoch settlement - must update ALL pools on epoch roll
    address[] private registeredAssets;

    /// @notice Total allocation points across all pools
    uint256 public totalAllocPoint;

    // ============================================================
    // STATE VARIABLES - USER TRACKING
    // ============================================================

    /// @notice User information per pool
    struct UserInfo {
        uint256 amount; // User's balance in the pool
        mapping(address => uint256) rewardDebt; // Per reward token
    }

    /// @notice User info: asset => user => UserInfo
    mapping(address => mapping(address => UserInfo)) public userInfo;

    /// @notice User claimable rewards: user => token => amount
    mapping(address => mapping(address => uint256)) public userBaseClaimable;

    // ============================================================
    // STATE VARIABLES - REWARD TOKENS
    // ============================================================

    /// @notice Registered reward tokens
    address[] public rewardTokens;

    /// @notice Check if token is registered
    mapping(address => bool) public isRewardToken;

    // ============================================================
    // STATE VARIABLES - EPOCH FUNDING
    // ============================================================

    /// @notice Current epoch funding (not yet allocated): token => amount
    mapping(address => uint256) public currentEpochFunding;

    /// @notice Total rewards allocated per epoch per token: epoch => token => amount
    mapping(uint256 => mapping(address => uint256)) public epochRewards;

    /// @notice Reward rate per second: token => rate
    mapping(address => uint256) public rewardRate;

    /// @notice Accounted balance for sync detection: token => balance
    mapping(address => uint256) public accountedBalance;

    /// @notice Undistributed rewards to be carried over to next epoch: token => amount
    /// @dev Captures rewards that couldn't be distributed (e.g., pool had 0 supply)
    mapping(address => uint256) public rewardDust;

    // ============================================================
    // STATE VARIABLES - EXCLUSION LIST
    // ============================================================

    /// @notice Addresses excluded from earning rewards (global across all pools)
    mapping(address => bool) public isExcludedFromRewards;

    /// @notice Array of excluded contract addresses
    address[] public excludedContracts;

    // ============================================================
    // ERRORS
    // ============================================================

    error YoloIncentives__Unauthorized();
    error YoloIncentives__NotStarted();
    error YoloIncentives__AlreadyStarted();
    error YoloIncentives__InvalidAddress();
    error YoloIncentives__InvalidAllocPoint();
    error YoloIncentives__PoolNotRegistered();
    error YoloIncentives__PoolAlreadyRegistered();
    error YoloIncentives__TokenNotRegistered();
    error YoloIncentives__TokenAlreadyRegistered();
    error YoloIncentives__EpochNotFinished();
    error YoloIncentives__InvalidStartTime();
    error YoloIncentives__AlreadyExcluded();
    error YoloIncentives__NotExcluded();
    error YoloIncentives__NoRewards();

    // ============================================================
    // EVENTS
    // ============================================================

    event Started(uint256 indexed epoch, uint256 startTime, address[] excludedContracts);
    event PoolAdded(address indexed asset, uint256 allocPoint);
    event PoolRemoved(address indexed asset);
    event AllocPointUpdated(address indexed asset, uint256 oldAllocPoint, uint256 newAllocPoint);
    event RewardTokenRegistered(address indexed token);
    event RewardTokenRemoved(address indexed token);
    event PoolRewardTokensUpdated(address indexed asset, address[] tokens);
    event OnwardIncentivesSet(address indexed asset, address indexed controller);
    event ContractExcluded(address indexed contractAddress);
    event ContractIncluded(address indexed contractAddress);
    event RewardSynced(address indexed token, uint256 amount, uint256 indexed epoch);
    event EpochRolled(uint256 indexed newEpoch, uint256 startTime);
    event EpochRewardsAllocated(uint256 indexed epoch, address indexed token, uint256 amount, uint256 rewardRate);
    event RewardClaimed(address indexed user, address indexed asset, address indexed token, uint256 amount);
    event BalanceUpdated(address indexed asset, address indexed user, uint256 userBalance, uint256 totalSupply);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyRewardsAdmin() {
        if (!ACL_MANAGER.hasRole(REWARDS_ADMIN, msg.sender) && !ACL_MANAGER.hasRole(DEFAULT_ADMIN, msg.sender)) {
            revert YoloIncentives__Unauthorized();
        }
        _;
    }

    modifier checkEpoch() {
        if (started && block.timestamp >= epochStartTime + EPOCH_DURATION) {
            _rollEpoch();
        }
        _;
    }

    modifier whenStarted() {
        if (!started) revert YoloIncentives__NotStarted();
        _;
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Constructor
     * @param aclManager ACL Manager address
     */
    constructor(address aclManager) {
        if (aclManager == address(0)) revert YoloIncentives__InvalidAddress();
        ACL_MANAGER = IACLManager(aclManager);
    }

    // ============================================================
    // ADMIN - LIFECYCLE MANAGEMENT
    // ============================================================

    /**
     * @notice Initialize and start the first epoch
     * @dev One-time only. Allows setting exact epoch start time (e.g., Monday 12am GMT)
     *      Also initializes the global exclusion list for contracts that shouldn't earn rewards
     * @param firstEpochStartTime Timestamp when first epoch starts (must be in future)
     * @param _excludedContracts Initial list of contracts to exclude from rewards
     */
    function start(uint256 firstEpochStartTime, address[] calldata _excludedContracts) external onlyRewardsAdmin {
        if (started) revert YoloIncentives__AlreadyStarted();
        if (firstEpochStartTime <= block.timestamp) revert YoloIncentives__InvalidStartTime();

        started = true;
        currentEpoch = 1;
        epochStartTime = firstEpochStartTime;

        // Initialize exclusion list
        uint256 len = _excludedContracts.length;
        for (uint256 i = 0; i < len; i++) {
            address contractAddr = _excludedContracts[i];
            if (contractAddr == address(0)) revert YoloIncentives__InvalidAddress();
            if (!isExcludedFromRewards[contractAddr]) {
                isExcludedFromRewards[contractAddr] = true;
                excludedContracts.push(contractAddr);
            }
        }

        emit Started(currentEpoch, epochStartTime, _excludedContracts);
    }

    // ============================================================
    // ADMIN - POOL MANAGEMENT
    // ============================================================

    /**
     * @notice Register a pool (asset) for rewards
     * @param asset Asset address (e.g., YLP, sUSY, yNVDA)
     * @param allocPoint Allocation points for weighted distribution
     */
    function addPool(address asset, uint256 allocPoint) external onlyRewardsAdmin {
        if (asset == address(0)) revert YoloIncentives__InvalidAddress();
        if (poolInfo[asset].allocPoint > 0) revert YoloIncentives__PoolAlreadyRegistered();

        poolInfo[asset].allocPoint = allocPoint;
        totalAllocPoint += allocPoint;

        // Add to registered assets array for settlement
        registeredAssets.push(asset);

        // CRITICAL: Initialize lastUpdateTime to prevent "from genesis" bug
        // If activeRewardTokens are added later via setPoolRewardTokens, they will be initialized there
        // But initialize any that might already exist (edge case)
        PoolInfo storage pool = poolInfo[asset];
        uint256 tokenCount = pool.activeRewardTokens.length;
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = pool.activeRewardTokens[i];
            if (pool.rewardState[token].lastUpdateTime == 0) {
                pool.rewardState[token].lastUpdateTime = block.timestamp;
            }
        }

        emit PoolAdded(asset, allocPoint);
    }

    /**
     * @notice Update allocation points (effective immediately)
     * @param assets Array of asset addresses
     * @param allocPoints Array of new allocation points
     */
    function batchUpdateAllocPoint(address[] calldata assets, uint256[] calldata allocPoints)
        external
        onlyRewardsAdmin
    {
        uint256 len = assets.length;
        require(len == allocPoints.length, "Length mismatch");

        // PHASE 1: Settle all pools FIRST with unchanged allocPoints
        // This ensures all settlements use the same totalAllocPoint denominator
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            uint256 oldAllocPoint = poolInfo[asset].allocPoint;
            if (oldAllocPoint == 0) revert YoloIncentives__PoolNotRegistered();

            PoolInfo storage pool = poolInfo[asset];
            uint256 tokenCount = pool.activeRewardTokens.length;
            for (uint256 j = 0; j < tokenCount; j++) {
                address token = pool.activeRewardTokens[j];
                _updatePool(asset, token);
            }
        }

        // PHASE 2: Update allocPoints after all settlements complete
        for (uint256 i = 0; i < len; i++) {
            address asset = assets[i];
            PoolInfo storage pool = poolInfo[asset];
            uint256 oldAllocPoint = pool.allocPoint;
            uint256 newAllocPoint = allocPoints[i];

            // Update totals
            totalAllocPoint = totalAllocPoint - oldAllocPoint + newAllocPoint;
            pool.allocPoint = newAllocPoint;

            emit AllocPointUpdated(asset, oldAllocPoint, newAllocPoint);
        }

        // CRITICAL: If all pools now have 0 allocation, capture remaining epoch emissions to prevent fund locking
        if (totalAllocPoint == 0) {
            _captureRemainingEpochEmissions();
        }
    }

    /**
     * @notice Remove a pool from incentives (effective next epoch)
     * @param asset Asset address
     */
    function removePool(address asset) external onlyRewardsAdmin {
        uint256 allocPoint = poolInfo[asset].allocPoint;
        if (allocPoint == 0) revert YoloIncentives__PoolNotRegistered();

        // CRITICAL: Settle all active tokens BEFORE removal to lock in final rewards
        // Otherwise, users lose rewards accrued since last interaction
        PoolInfo storage pool = poolInfo[asset];
        uint256 tokenCount = pool.activeRewardTokens.length;
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = pool.activeRewardTokens[i];
            _updatePool(asset, token);
        }

        totalAllocPoint -= allocPoint;
        poolInfo[asset].allocPoint = 0;

        // CRITICAL: If this was the last pool, capture remaining epoch emissions to prevent fund locking
        if (totalAllocPoint == 0) {
            _captureRemainingEpochEmissions();
        }

        // Remove from registeredAssets array using swap-and-pop
        uint256 len = registeredAssets.length;
        for (uint256 i = 0; i < len; i++) {
            if (registeredAssets[i] == asset) {
                registeredAssets[i] = registeredAssets[len - 1];
                registeredAssets.pop();
                break;
            }
        }

        emit PoolRemoved(asset);
    }

    /**
     * @notice Set onward incentives for a pool
     * @param asset Asset address
     * @param controller Onward incentives controller address
     */
    function setOnwardIncentives(address asset, address controller) external onlyRewardsAdmin {
        if (poolInfo[asset].allocPoint == 0) revert YoloIncentives__PoolNotRegistered();

        poolInfo[asset].onwardIncentives = IOnwardIncentivesController(controller);

        emit OnwardIncentivesSet(asset, controller);
    }

    /**
     * @notice Configure which reward tokens are active for a specific pool (gas optimization)
     * @param asset Asset address
     * @param tokens Array of active reward token addresses
     */
    function setPoolRewardTokens(address asset, address[] calldata tokens) external onlyRewardsAdmin {
        if (poolInfo[asset].allocPoint == 0) revert YoloIncentives__PoolNotRegistered();

        // Verify all tokens are registered
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (!isRewardToken[tokens[i]]) revert YoloIncentives__TokenNotRegistered();
        }

        PoolInfo storage pool = poolInfo[asset];

        // CRITICAL: Settle OLD active tokens BEFORE replacement to lock in final rewards
        // Otherwise, rewards for removed tokens are abandoned
        uint256 oldTokenCount = pool.activeRewardTokens.length;
        for (uint256 i = 0; i < oldTokenCount; i++) {
            address oldToken = pool.activeRewardTokens[i];
            _updatePool(asset, oldToken);
        }

        // Replace active tokens array
        pool.activeRewardTokens = tokens;

        // CRITICAL: Initialize lastUpdateTime for newly added tokens to prevent "from genesis" bug
        for (uint256 i = 0; i < len; i++) {
            address token = tokens[i];
            if (pool.rewardState[token].lastUpdateTime == 0) {
                pool.rewardState[token].lastUpdateTime = block.timestamp;
            }
        }

        emit PoolRewardTokensUpdated(asset, tokens);
    }

    // ============================================================
    // ADMIN - REWARD TOKEN MANAGEMENT
    // ============================================================

    /**
     * @notice Register a new reward token
     * @param token Reward token address
     */
    function registerRewardToken(address token) external onlyRewardsAdmin {
        if (token == address(0)) revert YoloIncentives__InvalidAddress();
        if (isRewardToken[token]) revert YoloIncentives__TokenAlreadyRegistered();

        isRewardToken[token] = true;
        rewardTokens.push(token);

        // Sync existing balance to current epoch funding
        _syncSingleReward(token);

        emit RewardTokenRegistered(token);
    }

    /**
     * @notice Remove a reward token (effective next epoch)
     * @param token Reward token address
     */
    function removeRewardToken(address token) external onlyRewardsAdmin {
        if (!isRewardToken[token]) revert YoloIncentives__TokenNotRegistered();

        isRewardToken[token] = false;

        // CRITICAL: Remove from rewardTokens array using swap-and-pop
        // Otherwise, _rollEpoch still iterates over the removed token
        uint256 len = rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            if (rewardTokens[i] == token) {
                rewardTokens[i] = rewardTokens[len - 1];
                rewardTokens.pop();
                break;
            }
        }

        emit RewardTokenRemoved(token);
    }

    // ============================================================
    // ADMIN - EXCLUSION MANAGEMENT
    // ============================================================

    /**
     * @notice Add contract to global exclusion list
     * @param contractAddress Contract address to exclude
     */
    function addExcludedContract(address contractAddress) external onlyRewardsAdmin {
        if (contractAddress == address(0)) revert YoloIncentives__InvalidAddress();
        if (isExcludedFromRewards[contractAddress]) revert YoloIncentives__AlreadyExcluded();

        isExcludedFromRewards[contractAddress] = true;
        excludedContracts.push(contractAddress);

        emit ContractExcluded(contractAddress);
    }

    /**
     * @notice Remove contract from global exclusion list
     * @param contractAddress Contract address to include
     */
    function removeExcludedContract(address contractAddress) external onlyRewardsAdmin {
        if (!isExcludedFromRewards[contractAddress]) revert YoloIncentives__NotExcluded();

        isExcludedFromRewards[contractAddress] = false;

        // Remove from array using swap-and-pop to prevent gas leak
        uint256 len = excludedContracts.length;
        for (uint256 i = 0; i < len; i++) {
            if (excludedContracts[i] == contractAddress) {
                excludedContracts[i] = excludedContracts[len - 1];
                excludedContracts.pop();
                break;
            }
        }

        // CRITICAL: Reinitialize user state for all pools where they have a balance
        // Without this, users who were excluded remain invisible to the reward system
        uint256 assetCount = registeredAssets.length;
        for (uint256 i = 0; i < assetCount; i++) {
            address asset = registeredAssets[i];
            PoolInfo storage pool = poolInfo[asset];

            // Check if contract has a balance in this asset
            uint256 balance = IERC20(asset).balanceOf(contractAddress);
            if (balance > 0 && pool.allocPoint > 0) {
                UserInfo storage userInf = userInfo[asset][contractAddress];

                // Update pool and set user state for all active reward tokens
                uint256 tokenCount = pool.activeRewardTokens.length;
                for (uint256 j = 0; j < tokenCount; j++) {
                    address token = pool.activeRewardTokens[j];

                    // Update pool to current state
                    _updatePool(asset, token);

                    // Initialize reward debt (no retroactive rewards)
                    RewardState storage state = pool.rewardState[token];
                    userInf.rewardDebt[token] = (balance * state.accRewardPerShare) / PRECISION;
                }

                // Set user amount
                userInf.amount = balance;

                // Refresh pool supply accounting based on actual ERC20 totals
                uint256 totalSupplyRaw = IERC20(asset).totalSupply();
                pool.totalSupplyRaw = totalSupplyRaw;
                pool.totalSupply = _calculateAdjustedSupply(asset, totalSupplyRaw);
            }
        }

        emit ContractIncluded(contractAddress);
    }

    // ============================================================
    // EPOCH & FUNDING SYSTEM
    // ============================================================

    /**
     * @notice Sync rewards (detect new funding from treasury)
     * @param tokens Array of token addresses to sync
     */
    function syncRewards(address[] calldata tokens) external checkEpoch {
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            _syncSingleReward(tokens[i]);
        }
    }

    /**
     * @notice Internal function to sync single reward token
     * @param token Token address
     */
    function _syncSingleReward(address token) internal {
        if (!isRewardToken[token]) return;

        uint256 actualBalance = IERC20(token).balanceOf(address(this));
        uint256 accounted = accountedBalance[token];

        if (actualBalance > accounted) {
            uint256 newFunding = actualBalance - accounted;
            currentEpochFunding[token] += newFunding;
            accountedBalance[token] = actualBalance;

            emit RewardSynced(token, newFunding, currentEpoch);
        }
    }

    /**
     * @notice Roll to next epoch (permissionless after 7 days)
     */
    function rollEpoch() external {
        if (!started) revert YoloIncentives__NotStarted();
        if (block.timestamp < epochStartTime + EPOCH_DURATION) {
            revert YoloIncentives__EpochNotFinished();
        }

        _rollEpoch();
    }

    /**
     * @notice Capture remaining epoch emissions when totalAllocPoint drops to 0
     * @dev Called when removePool or setPoolAllocPoint causes totalAllocPoint to become 0.
     *      Prevents fund locking by converting unrewarded emissions into dust.
     */
    function _captureRemainingEpochEmissions() internal {
        // Only capture if we're still mid-epoch
        if (block.timestamp >= epochStartTime + EPOCH_DURATION) {
            return;
        }

        uint256 remainingTime = epochStartTime + EPOCH_DURATION - block.timestamp;

        uint256 tokenCount = rewardTokens.length;
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = rewardTokens[i];
            uint256 rate = rewardRate[token];

            if (rate > 0) {
                // Calculate unrewarded emissions for remaining epoch time
                uint256 leftover = (rate * remainingTime) / REWARD_RATE_PRECISION;

                // Add to dust (will be recycled in next epoch)
                rewardDust[token] += leftover;

                // Zero the rate (no pools to distribute to)
                rewardRate[token] = 0;
            }
        }
    }

    /**
     * @notice Internal function to roll epoch
     */
    function _rollEpoch() internal {
        // STEP 1: Sync all rewards before settling
        uint256 tokenCount = rewardTokens.length;
        for (uint256 i = 0; i < tokenCount; i++) {
            _syncSingleReward(rewardTokens[i]);
        }

        // STEP 2: CRITICAL SETTLEMENT - Update ALL pools to lock in rewards at current rates
        // This prevents the "idle pools + rate change = broken math" bug
        // Must settle BEFORE changing rewardRate for next epoch
        uint256 assetCount = registeredAssets.length;
        for (uint256 i = 0; i < assetCount; i++) {
            address asset = registeredAssets[i];
            PoolInfo storage pool = poolInfo[asset];

            // Settle each active token for this pool
            uint256 poolTokenCount = pool.activeRewardTokens.length;
            for (uint256 j = 0; j < poolTokenCount; j++) {
                address token = pool.activeRewardTokens[j];
                _updatePool(asset, token); // Settles rewards at current epoch's rate (epoch-aware)
            }
        }

        // STEP 2.5: Handle multi-epoch gaps
        // Detect if multiple epochs passed without rollover
        uint256 epochsPassed = (block.timestamp - epochStartTime) / EPOCH_DURATION;

        if (epochsPassed > 1) {
            // CRITICAL: Capture leftover emissions from current epoch BEFORE zeroing rates
            // The current epoch had a rewardRate set, but we're about to skip to a future epoch
            // Any unstreamed portion should go to dust for recycling
            for (uint256 i = 0; i < tokenCount; i++) {
                address token = rewardTokens[i];
                uint256 rate = rewardRate[token];

                if (rate > 0) {
                    // Calculate the current epoch's end time
                    uint256 currentEpochEnd = epochStartTime + EPOCH_DURATION;

                    // Find the latest lastUpdateTime across all pools for this token
                    // to determine how much of the epoch was NOT settled by Step 2
                    uint256 latestUpdate = epochStartTime;
                    for (uint256 j = 0; j < assetCount; j++) {
                        address asset = registeredAssets[j];
                        PoolInfo storage pool = poolInfo[asset];
                        RewardState storage state = pool.rewardState[token];

                        // Check if this pool tracks this token
                        bool hasToken = false;
                        for (uint256 k = 0; k < pool.activeRewardTokens.length; k++) {
                            if (pool.activeRewardTokens[k] == token) {
                                hasToken = true;
                                break;
                            }
                        }

                        if (hasToken && state.lastUpdateTime > latestUpdate && state.lastUpdateTime <= currentEpochEnd)
                        {
                            latestUpdate = state.lastUpdateTime;
                        }
                    }

                    // Calculate leftover: time from latest settlement to epoch end
                    if (latestUpdate < currentEpochEnd) {
                        uint256 leftoverDuration = currentEpochEnd - latestUpdate;
                        // rewardRate represents total per-second emissions across all pools
                        uint256 leftover = (leftoverDuration * rate) / REWARD_RATE_PRECISION;

                        // Add to dust for recycling in next epoch
                        rewardDust[token] += leftover;
                    }
                }
            }

            // Now advance epoch markers for skipped epochs
            // Intermediate epochs (e.g., epoch 3, 4) had no funding, so nothing to capture for them
            uint256 epochsToSkip = epochsPassed - 1;
            epochStartTime += EPOCH_DURATION * epochsToSkip;
            currentEpoch += epochsToSkip;

            // Zero all rates to prevent stale rate leakage
            for (uint256 i = 0; i < tokenCount; i++) {
                rewardRate[rewardTokens[i]] = 0;
            }

            // Update all pool reward states to new epoch start
            for (uint256 i = 0; i < assetCount; i++) {
                address asset = registeredAssets[i];
                PoolInfo storage pool = poolInfo[asset];
                uint256 poolTokenCount = pool.activeRewardTokens.length;

                for (uint256 j = 0; j < poolTokenCount; j++) {
                    address token = pool.activeRewardTokens[j];
                    RewardState storage state = pool.rewardState[token];

                    // Reset lastUpdateTime to new epoch start
                    if (state.lastUpdateTime < epochStartTime) {
                        state.lastUpdateTime = epochStartTime;
                    }
                }
            }
        }

        // STEP 3: Allocate funding and set new rates for next epoch
        for (uint256 i = 0; i < tokenCount; i++) {
            address token = rewardTokens[i];

            // Recycle dust from previous epoch
            uint256 dust = rewardDust[token];
            if (dust > 0) {
                currentEpochFunding[token] += dust;
                rewardDust[token] = 0;
            }

            uint256 funding = currentEpochFunding[token];

            // CRITICAL: If no pools exist (totalAllocPoint == 0), divert all funding to dust
            // Cannot distribute rewards when no pools are active - funds would be stuck forever
            if (totalAllocPoint == 0) {
                if (funding > 0) {
                    rewardDust[token] += funding;
                    currentEpochFunding[token] = 0;
                }
                rewardRate[token] = 0;
            } else if (funding > 0) {
                epochRewards[currentEpoch][token] = funding;
                // Use REWARD_RATE_PRECISION to prevent integer division truncation
                rewardRate[token] = (funding * REWARD_RATE_PRECISION) / EPOCH_DURATION;
                currentEpochFunding[token] = 0;

                emit EpochRewardsAllocated(currentEpoch, token, funding, rewardRate[token]);
            } else {
                // CRITICAL: Reset rate to 0 if no funding (prevents infinite rewards from past epochs)
                rewardRate[token] = 0;
            }
        }

        // STEP 4: Advance epoch
        currentEpoch++;
        epochStartTime = block.timestamp;

        emit EpochRolled(currentEpoch, epochStartTime);
    }

    // ============================================================
    // STREAMING DISTRIBUTION LOGIC
    // ============================================================

    /**
     * @notice Update pool's accumulated rewards per share for a specific token
     * @param asset Asset address
     * @param rewardToken Reward token address
     */
    function _updatePool(address asset, address rewardToken) internal {
        PoolInfo storage pool = poolInfo[asset];
        RewardState storage state = pool.rewardState[rewardToken];

        if (block.timestamp <= state.lastUpdateTime) return;

        // Handle case where all pools are removed (prevent division by zero)
        if (totalAllocPoint == 0) {
            state.lastUpdateTime = block.timestamp;
            return;
        }

        // CRITICAL FIX: Cap calculation to current epoch boundary to prevent reward inflation
        // Issue: Unbounded duration across multiple epochs causes inflated rewards
        // Example: 1M epoch budget with 2-epoch delay → 2M rewards (100% inflation)
        // Solution: Only calculate rewards for current epoch, capped at epoch end
        uint256 epochEndTime = epochStartTime + EPOCH_DURATION;
        uint256 calculationTime = block.timestamp > epochEndTime ? epochEndTime : block.timestamp;

        // Calculate duration for reward calculation
        uint256 duration;

        // If lastUpdateTime is from previous epoch, only count from current epoch start
        // This prevents multi-epoch accumulation when settlements are delayed
        if (state.lastUpdateTime < epochStartTime) {
            duration = calculationTime - epochStartTime;
        } else {
            duration = calculationTime - state.lastUpdateTime;
        }

        // CRITICAL: Calculate reward BEFORE checking lpSupply
        // Each token uses its OWN lastUpdateTime to prevent zero-reward bug
        uint256 reward =
            (duration * rewardRate[rewardToken] * pool.allocPoint) / totalAllocPoint / REWARD_RATE_PRECISION;

        uint256 lpSupply = pool.totalSupply; // Excludes excluded contracts

        if (lpSupply == 0) {
            // Pool has no stakers - add reward to dust for recycling next epoch
            rewardDust[rewardToken] += reward;
            state.lastUpdateTime = calculationTime;
            return;
        }

        state.accRewardPerShare += (reward * PRECISION) / lpSupply;
        state.lastUpdateTime = calculationTime;
    }

    // ============================================================
    // HANDLEACTION HOOK (IncentivesTracker Interface)
    // ============================================================

    /**
     * @notice Called when user balance changes in incentivized asset
     * @param user User address
     * @param totalSupply Asset's total supply
     * @param userBalance User's new balance
     */
    function handleAction(address user, uint256 totalSupply, uint256 userBalance)
        external
        override
        whenStarted
        checkEpoch
    {
        address asset = msg.sender; // msg.sender is the token calling this
        PoolInfo storage pool = poolInfo[asset];

        if (pool.allocPoint == 0) return; // Pool not registered

        // Skip excluded contracts (prevents recursive rewards)
        if (isExcludedFromRewards[user]) {
            // Still call onward incentives
            if (address(pool.onwardIncentives) != address(0)) {
                pool.onwardIncentives.handleAction(asset, user, userBalance, totalSupply);
            }
            return;
        }

        UserInfo storage userInf = userInfo[asset][user];
        uint256 oldAmount = userInf.amount;

        // Loop through ACTIVE tokens for this pool (gas optimization)
        uint256 activeTokenCount = pool.activeRewardTokens.length;

        for (uint256 i = 0; i < activeTokenCount; i++) {
            address token = pool.activeRewardTokens[i];

            _updatePool(asset, token);

            RewardState storage state = pool.rewardState[token];

            // Calculate pending rewards
            if (oldAmount > 0) {
                uint256 pending = (oldAmount * state.accRewardPerShare) / PRECISION - userInf.rewardDebt[token];
                if (pending > 0) {
                    userBaseClaimable[user][token] += pending;
                }
            }

            // Update reward debt
            userInf.rewardDebt[token] = (userBalance * state.accRewardPerShare) / PRECISION;
        }

        // Update user amount
        userInf.amount = userBalance;

        // Update supply accounting
        pool.totalSupplyRaw = totalSupply;
        pool.totalSupply = _calculateAdjustedSupply(asset, totalSupply);

        // Call onward incentives
        if (address(pool.onwardIncentives) != address(0)) {
            pool.onwardIncentives.handleAction(asset, user, userBalance, totalSupply);
        }

        emit BalanceUpdated(asset, user, userBalance, totalSupply);
    }

    /**
     * @notice Calculate adjusted supply (excluding excluded contracts)
     * @param asset Asset address
     * @param totalSupplyRaw Raw total supply from ERC20
     * @return Adjusted supply excluding excluded contracts
     */
    function _calculateAdjustedSupply(address asset, uint256 totalSupplyRaw) internal view returns (uint256) {
        uint256 excludedBalance = 0;

        // Subtract balances of excluded contracts
        uint256 len = excludedContracts.length;
        for (uint256 i = 0; i < len; i++) {
            address excluded = excludedContracts[i];
            if (isExcludedFromRewards[excluded]) {
                excludedBalance += IERC20(asset).balanceOf(excluded);
            }
        }

        return totalSupplyRaw > excludedBalance ? totalSupplyRaw - excludedBalance : 0;
    }

    // ============================================================
    // CLAIMING SYSTEM
    // ============================================================

    /**
     * @notice Claim rewards for a single asset across specific tokens
     * @param asset Asset address
     * @param tokens Array of reward tokens to claim
     */
    function claim(address asset, address[] calldata tokens) external nonReentrant whenStarted checkEpoch {
        uint256 len = tokens.length;
        for (uint256 i = 0; i < len; i++) {
            _updatePool(asset, tokens[i]);
            _claimReward(msg.sender, asset, tokens[i]);
        }
    }

    /**
     * @notice Claim rewards for multiple assets and tokens
     * @param assets Array of asset addresses
     * @param tokens Array of reward tokens to claim
     */
    function claimBatch(address[] calldata assets, address[] calldata tokens)
        external
        nonReentrant
        whenStarted
        checkEpoch
    {
        uint256 assetLen = assets.length;
        uint256 tokenLen = tokens.length;

        for (uint256 i = 0; i < assetLen; i++) {
            for (uint256 j = 0; j < tokenLen; j++) {
                _updatePool(assets[i], tokens[j]);
                _claimReward(msg.sender, assets[i], tokens[j]);
            }
        }
    }

    /**
     * @notice Claim all rewards from all assets and all tokens
     */
    function claimAll() external nonReentrant whenStarted checkEpoch {
        // This is a convenience function - users would need to track their assets off-chain
        // For gas efficiency, recommend using claim() or claimBatch() with specific assets/tokens
        revert("Use claim() or claimBatch()");
    }

    /**
     * @notice Internal function to claim rewards
     * @param user User address
     * @param asset Asset address
     * @param token Reward token address
     */
    function _claimReward(address user, address asset, address token) internal {
        UserInfo storage userInf = userInfo[asset][user];
        PoolInfo storage pool = poolInfo[asset];
        RewardState storage state = pool.rewardState[token];

        uint256 pending = (userInf.amount * state.accRewardPerShare) / PRECISION - userInf.rewardDebt[token];
        pending += userBaseClaimable[user][token];

        if (pending > 0) {
            userBaseClaimable[user][token] = 0;
            userInf.rewardDebt[token] = (userInf.amount * state.accRewardPerShare) / PRECISION;

            // Update accounted balance
            accountedBalance[token] -= pending;

            // Transfer reward
            IERC20(token).safeTransfer(user, pending);

            emit RewardClaimed(user, asset, token, pending);
        }
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get claimable rewards for user
     * @param user User address
     * @param assets Array of asset addresses
     * @param tokens Array of reward tokens
     * @return amounts Array of claimable amounts
     */
    function claimableRewards(address user, address[] calldata assets, address[] calldata tokens)
        external
        view
        returns (uint256[] memory amounts)
    {
        uint256 totalCount = assets.length * tokens.length;
        amounts = new uint256[](totalCount);
        uint256 index = 0;

        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i];
            UserInfo storage userInf = userInfo[asset][user];
            PoolInfo storage pool = poolInfo[asset];

            for (uint256 j = 0; j < tokens.length; j++) {
                address token = tokens[j];
                RewardState storage state = pool.rewardState[token];

                // Calculate pending with simulated update (epoch-aware)
                uint256 accRewardPerShare = state.accRewardPerShare;

                if (block.timestamp > state.lastUpdateTime && pool.totalSupply > 0 && totalAllocPoint > 0) {
                    // Cap calculation to current epoch boundary (matches _updatePool logic)
                    uint256 epochEndTime = epochStartTime + EPOCH_DURATION;
                    uint256 calculationTime = block.timestamp > epochEndTime ? epochEndTime : block.timestamp;

                    uint256 duration;
                    if (state.lastUpdateTime < epochStartTime) {
                        duration = calculationTime - epochStartTime;
                    } else {
                        duration = calculationTime - state.lastUpdateTime;
                    }

                    uint256 reward =
                        (duration * rewardRate[token] * pool.allocPoint) / totalAllocPoint / REWARD_RATE_PRECISION;
                    accRewardPerShare += (reward * PRECISION) / pool.totalSupply;
                }

                uint256 pending = (userInf.amount * accRewardPerShare) / PRECISION - userInf.rewardDebt[token];
                pending += userBaseClaimable[user][token];

                amounts[index] = pending;
                index++;
            }
        }
    }

    /**
     * @notice Get current reward rates
     * @return tokens Array of reward token addresses
     * @return rates Array of reward rates (per second)
     */
    function getRewardRates() external view returns (address[] memory tokens, uint256[] memory rates) {
        uint256 len = rewardTokens.length;
        tokens = new address[](len);
        rates = new uint256[](len);

        for (uint256 i = 0; i < len; i++) {
            tokens[i] = rewardTokens[i];
            rates[i] = rewardRate[rewardTokens[i]];
        }
    }

    /**
     * @notice Get all registered reward tokens
     * @return Array of reward token addresses
     */
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    /**
     * @notice Get pool's active reward tokens
     * @param asset Asset address
     * @return Array of active reward token addresses for this pool
     */
    function getPoolActiveTokens(address asset) external view returns (address[] memory) {
        return poolInfo[asset].activeRewardTokens;
    }

    /**
     * @notice Get all excluded contracts
     * @return Array of excluded contract addresses
     */
    function getExcludedContracts() external view returns (address[] memory) {
        return excludedContracts;
    }

    /**
     * @notice Get all registered assets (pools)
     * @return Array of registered asset addresses
     */
    function getRegisteredAssets() external view returns (address[] memory) {
        return registeredAssets;
    }
}
