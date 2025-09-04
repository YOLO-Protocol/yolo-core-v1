// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IIncentivesTracker.sol";

/**
 * @title MockIncentivesController
 * @author alvin@yolo.wtf
 * @notice Mock implementation of IIncentivesTracker for testing
 * @dev Tracks all handleAction calls for verification in tests
 */
contract MockIncentivesController is IIncentivesTracker {
    struct ActionRecord {
        address user;
        uint256 totalSupply;
        uint256 userBalance;
        uint256 timestamp;
    }

    // Track all handleAction calls
    mapping(address => ActionRecord[]) public userActions;
    mapping(address => uint256) public userActionCount;

    // Track unique users
    address[] public users;
    mapping(address => bool) public isUser;

    // Total action count
    uint256 public totalActionCount;

    event ActionRecorded(address indexed user, uint256 totalSupply, uint256 userBalance, uint256 timestamp);

    /**
     * @notice Records user action for incentive tracking
     * @param user The user whose balance is changing
     * @param totalSupply The total supply before the action
     * @param userBalance The user's balance before the action
     */
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external override {
        ActionRecord memory action =
            ActionRecord({user: user, totalSupply: totalSupply, userBalance: userBalance, timestamp: block.timestamp});

        userActions[user].push(action);
        userActionCount[user]++;
        totalActionCount++;

        // Track unique users
        if (!isUser[user]) {
            users.push(user);
            isUser[user] = true;
        }

        emit ActionRecorded(user, totalSupply, userBalance, block.timestamp);
    }

    // ============ Helper Functions for Testing ============

    /**
     * @notice Gets the last action for a user
     * @param user The user to query
     * @return The last action record
     */
    function getLastAction(address user) external view returns (ActionRecord memory) {
        uint256 count = userActionCount[user];
        require(count > 0, "No actions for user");
        return userActions[user][count - 1];
    }

    /**
     * @notice Gets a specific action for a user
     * @param user The user to query
     * @param index The action index
     * @return The action record
     */
    function getAction(address user, uint256 index) external view returns (ActionRecord memory) {
        require(index < userActionCount[user], "Index out of bounds");
        return userActions[user][index];
    }

    /**
     * @notice Gets all actions for a user
     * @param user The user to query
     * @return Array of action records
     */
    function getAllActions(address user) external view returns (ActionRecord[] memory) {
        return userActions[user];
    }

    /**
     * @notice Gets the total number of unique users
     * @return The number of unique users
     */
    function getUserCount() external view returns (uint256) {
        return users.length;
    }

    /**
     * @notice Resets all tracking data (for testing)
     */
    function reset() external {
        for (uint256 i = 0; i < users.length; i++) {
            delete userActions[users[i]];
            delete userActionCount[users[i]];
            delete isUser[users[i]];
        }
        delete users;
        totalActionCount = 0;
    }
}
