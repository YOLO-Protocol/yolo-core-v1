// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IStabilityTracker
 * @author alvin@yolo.wtf
 * @notice Interface for stability incentive tracking modules
 * @dev Implementers receive before/after swap data and calculate stability points
 *      This is a pluggable module that rewards traders who help maintain USY-USDC peg
 */
interface IStabilityTracker {
    /**
     * @notice Called before anchor pool swap executes
     * @dev Only called by YoloHook for anchor pool swaps when tracker is set
     * @param swapper Original trader address (not router/looper)
     * @param reserveUSDC USDC reserve before swap (native decimals - 6 or 18)
     * @param reserveUSY USY reserve before swap (18 decimals)
     */
    function beforeSwapUpdate(address swapper, uint256 reserveUSDC, uint256 reserveUSY) external;

    /**
     * @notice Called after anchor pool swap executes
     * @dev Only called by YoloHook for anchor pool swaps when tracker is set
     * @param swapper Original trader address (not router/looper)
     * @param reserveUSDC USDC reserve after swap (native decimals - 6 or 18)
     * @param reserveUSY USY reserve after swap (18 decimals)
     */
    function afterSwapUpdate(address swapper, uint256 reserveUSDC, uint256 reserveUSY) external;
}
