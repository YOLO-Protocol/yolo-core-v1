// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IIncentivesTracker
 * @author alvin@yolo.wtf
 * @notice Interface for the incentives tracking system
 * @dev Handles reward accrual and distribution for incentivized tokens
 */
interface IIncentivesTracker {
    /**
     * @notice Called when a user's balance changes to update reward accrual
     * @dev This is the core function called by IncentivizedERC20 tokens on:
     *      - Transfer (for both sender and recipient)
     *      - Mint (for recipient)
     *      - Burn (for sender)
     * @param user The user whose balance is changing
     * @param totalSupply The total supply of the token before the action
     * @param userBalance The user's balance before the action
     */
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external;
}
