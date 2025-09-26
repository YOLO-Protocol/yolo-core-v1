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
     * @dev ChefIncentivesController-style: values reflect the state AFTER the action.
     *      Invoked by IncentivizedERC20 on:
     *      - Transfer (for both sender and recipient)
     *      - Mint (for recipient)
     *      - Burn (for sender)
     * @param user The user whose balance changed
     * @param totalSupply The token total supply after the action
     * @param userBalance The user's balance after the action
     */
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external;
}
