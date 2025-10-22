// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IACLManager} from "../interfaces/IACLManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TreasuryForwarder
 * @author alvin@yolo.wtf
 * @notice Distributes protocol treasury tokens to multiple destinations
 * @dev ACL-controlled contract for flexible treasury allocation
 *      - Supports multiple reward tokens (USY, yNVDA, yTSLA, etc.)
 *      - Configurable distribution percentages per reward
 *      - Public distribution callable by anyone (permissionless)
 *      - Emergency withdrawal by REWARDS_ADMIN
 */
contract TreasuryForwarder {
    using SafeERC20 for IERC20;

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Role for managing rewards and distributions
    bytes32 public constant REWARDS_ADMIN = keccak256("REWARDS_ADMIN");

    /// @notice Basis points divisor (10000 = 100%)
    uint256 public constant BPS_DIVISOR = 10000;

    // ============================================================
    // STRUCTS
    // ============================================================

    /// @notice Distribution recipient configuration
    struct Recipient {
        address destination; // Recipient address
        uint256 allocPoints; // Allocation points (basis points, max 10000)
    }

    /// @notice Reward token distribution configuration
    struct RewardDistribution {
        Recipient[] recipients; // Array of recipients
        uint256 totalAllocPoints; // Sum of all allocPoints (must equal 10000)
    }

    // ============================================================
    // STATE VARIABLES
    // ============================================================

    /// @notice ACL Manager for role-based access control
    IACLManager public immutable ACL_MANAGER;

    /// @notice Array of registered reward tokens
    address[] public registeredRewards;

    /// @notice Mapping to check if token is registered as reward
    mapping(address => bool) public isReward;

    /// @notice Mapping from reward token to its distribution configuration
    mapping(address => RewardDistribution) private _distributions;

    // ============================================================
    // EVENTS
    // ============================================================

    event RewardRegistered(address indexed rewardToken);
    event RewardDropped(address indexed rewardToken);
    event RecipientsUpdated(address indexed rewardToken, Recipient[] recipients);
    event Distributed(address indexed rewardToken, uint256 totalAmount);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);

    // ============================================================
    // ERRORS
    // ============================================================

    error TreasuryForwarder__Unauthorized();
    error TreasuryForwarder__InvalidAddress();
    error TreasuryForwarder__RewardAlreadyRegistered();
    error TreasuryForwarder__RewardNotRegistered();
    error TreasuryForwarder__InvalidAllocation();

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyRewardsAdmin() {
        if (!ACL_MANAGER.hasRole(REWARDS_ADMIN, msg.sender)) {
            revert TreasuryForwarder__Unauthorized();
        }
        _;
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor(address _aclManager) {
        if (_aclManager == address(0)) revert TreasuryForwarder__InvalidAddress();
        ACL_MANAGER = IACLManager(_aclManager);
    }

    // ============================================================
    // REWARDS ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Register a new reward token for distribution
     * @dev Only REWARDS_ADMIN can call
     * @param rewardToken Address of the reward token
     */
    function registerReward(address rewardToken) external onlyRewardsAdmin {
        if (rewardToken == address(0)) revert TreasuryForwarder__InvalidAddress();
        if (isReward[rewardToken]) revert TreasuryForwarder__RewardAlreadyRegistered();

        isReward[rewardToken] = true;
        registeredRewards.push(rewardToken);

        emit RewardRegistered(rewardToken);
    }

    /**
     * @notice Drop a reward token from distribution
     * @dev Only REWARDS_ADMIN can call. Clears distribution config and removes from array
     * @param rewardToken Address of the reward token to drop
     */
    function dropReward(address rewardToken) external onlyRewardsAdmin {
        if (!isReward[rewardToken]) revert TreasuryForwarder__RewardNotRegistered();

        // Mark as not a reward
        isReward[rewardToken] = false;

        // Clear distribution configuration
        delete _distributions[rewardToken];

        // Remove from registeredRewards array
        uint256 length = registeredRewards.length;
        for (uint256 i = 0; i < length; i++) {
            if (registeredRewards[i] == rewardToken) {
                registeredRewards[i] = registeredRewards[length - 1];
                registeredRewards.pop();
                break;
            }
        }

        emit RewardDropped(rewardToken);
    }

    /**
     * @notice Set distribution recipients for a reward token
     * @dev Only REWARDS_ADMIN can call. Total allocPoints must equal 10000 (100%)
     * @param rewardToken Address of the reward token
     * @param recipients Array of recipients with allocation points
     */
    function setRecipients(address rewardToken, Recipient[] calldata recipients) external onlyRewardsAdmin {
        if (!isReward[rewardToken]) revert TreasuryForwarder__RewardNotRegistered();
        if (recipients.length == 0) revert TreasuryForwarder__InvalidAllocation();

        // Validate total allocation = 100%
        uint256 totalAlloc = 0;
        for (uint256 i = 0; i < recipients.length; i++) {
            if (recipients[i].destination == address(0)) revert TreasuryForwarder__InvalidAddress();
            totalAlloc += recipients[i].allocPoints;
        }

        if (totalAlloc != BPS_DIVISOR) revert TreasuryForwarder__InvalidAllocation();

        // Clear existing recipients
        delete _distributions[rewardToken];

        // Set new recipients
        RewardDistribution storage dist = _distributions[rewardToken];
        for (uint256 i = 0; i < recipients.length; i++) {
            dist.recipients.push(recipients[i]);
        }
        dist.totalAllocPoints = totalAlloc;

        emit RecipientsUpdated(rewardToken, recipients);
    }

    /**
     * @notice Emergency withdraw any token
     * @dev Only REWARDS_ADMIN can call. Uses SafeERC20 for proper return value handling
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRewardsAdmin {
        if (token == address(0)) revert TreasuryForwarder__InvalidAddress();
        if (to == address(0)) revert TreasuryForwarder__InvalidAddress();

        IERC20(token).safeTransfer(to, amount);

        emit EmergencyWithdrawal(token, to, amount);
    }

    // ============================================================
    // PUBLIC DISTRIBUTION FUNCTIONS
    // ============================================================

    /**
     * @notice Distribute all registered reward tokens to configured recipients
     * @dev Callable by anyone (permissionless)
     *      Iterates through all registered rewards and distributes each
     */
    function distribute() external {
        uint256 length = registeredRewards.length;
        for (uint256 i = 0; i < length; i++) {
            _distributeSingle(registeredRewards[i]);
        }
    }

    /**
     * @notice Distribute a single reward token to configured recipients
     * @dev Callable by anyone (permissionless)
     * @param rewardToken Address of the reward token to distribute
     */
    function distributeSingleAsset(address rewardToken) external {
        if (!isReward[rewardToken]) revert TreasuryForwarder__RewardNotRegistered();
        _distributeSingle(rewardToken);
    }

    // ============================================================
    // INTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice Internal function to distribute a single reward token
     * @dev Uses SafeERC20 for safe transfers. Sends any dust to the last recipient.
     * @param rewardToken Address of the reward token
     */
    function _distributeSingle(address rewardToken) internal {
        RewardDistribution storage dist = _distributions[rewardToken];

        // Skip if no recipients configured
        if (dist.recipients.length == 0) return;

        // Get balance
        uint256 balance = IERC20(rewardToken).balanceOf(address(this));
        if (balance == 0) return;

        uint256 distributed = 0;

        // Distribute to each recipient (except last)
        for (uint256 i = 0; i < dist.recipients.length - 1; i++) {
            Recipient memory recipient = dist.recipients[i];
            uint256 amount = (balance * recipient.allocPoints) / BPS_DIVISOR;

            if (amount > 0) {
                IERC20(rewardToken).safeTransfer(recipient.destination, amount);
                distributed += amount;
            }
        }

        // Send remainder (including dust) to last recipient
        uint256 remaining = balance - distributed;
        if (remaining > 0) {
            Recipient memory lastRecipient = dist.recipients[dist.recipients.length - 1];
            IERC20(rewardToken).safeTransfer(lastRecipient.destination, remaining);
        }

        emit Distributed(rewardToken, balance);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get all registered reward tokens
     * @return Array of reward token addresses
     */
    function getAllRegisteredRewards() external view returns (address[] memory) {
        return registeredRewards;
    }

    /**
     * @notice Get distribution recipients for a reward token
     * @param rewardToken Address of the reward token
     * @return Array of recipients
     */
    function getRecipients(address rewardToken) external view returns (Recipient[] memory) {
        return _distributions[rewardToken].recipients;
    }

    /**
     * @notice Get total allocation points for a reward token
     * @param rewardToken Address of the reward token
     * @return Total allocation points (should be 10000 if configured)
     */
    function getTotalAllocPoints(address rewardToken) external view returns (uint256) {
        return _distributions[rewardToken].totalAllocPoints;
    }
}
