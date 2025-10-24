// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IOnwardIncentivesController
 * @notice Interface for chaining incentive controllers
 * @dev Allows hierarchical reward distribution where one controller
 *      can trigger rewards in another controller
 */
interface IOnwardIncentivesController {
    /**
     * @notice Called when a user's balance changes in an incentivized asset
     * @param asset The incentivized asset (e.g., YLP, sUSY, yNVDA)
     * @param user The user whose balance changed
     * @param userBalance The user's new balance
     * @param totalSupply The asset's total supply
     */
    function handleAction(address asset, address user, uint256 userBalance, uint256 totalSupply) external;
}
