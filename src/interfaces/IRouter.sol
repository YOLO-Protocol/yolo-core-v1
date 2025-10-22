// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title IRouter
 * @author alvin@yolo.wtf
 * @notice Interface for swap router used by YoloLooper
 * @dev This interface can be implemented by:
 *      - Our own router implementation (direct Uniswap V4 integration)
 *      - External DEX aggregators (1inch, Paraswap, etc.)
 *      - Simple mock router for testing
 *
 *      Implementation must handle:
 *      - Token approvals (caller must approve tokenIn before calling)
 *      - Slippage protection (revert if amountOut < minAmountOut)
 *      - Token transfers (pull tokenIn, send tokenOut to caller)
 */
interface IRouter {
    // ============================================================
    // EVENTS
    // ============================================================

    /**
     * @notice Emitted when a swap is executed
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of tokenIn spent
     * @param amountOut Amount of tokenOut received
     * @param recipient Address that received tokenOut
     */
    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    // ============================================================
    // ERRORS
    // ============================================================

    error Router__InsufficientOutput();
    error Router__InvalidPath();
    error Router__SwapFailed();

    // ============================================================
    // SWAP FUNCTIONS
    // ============================================================

    /**
     * @notice Execute a token swap
     * @dev Implementation must:
     *      1. Pull amountIn of tokenIn from msg.sender (requires prior approval)
     *      2. Execute swap via optimal route
     *      3. Transfer amountOut of tokenOut to msg.sender
     *      4. Revert if amountOut < minAmountOut
     *
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of tokenIn to swap
     * @param minAmountOut Minimum amount of tokenOut required (slippage protection)
     * @return amountOut Actual amount of tokenOut received
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);

    /**
     * @notice Get quote for a swap (view function)
     * @dev Returns estimated output amount for given input
     *      Does not account for slippage or price impact in real execution
     *
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of tokenIn to swap
     * @return amountOut Estimated amount of tokenOut
     */
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 amountOut);
}
