// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";

/**
 * @title MockRouter
 * @author alvin@yolo.wtf
 * @notice Mock external DEX aggregator for testing leverage loops
 * @dev Simulates external routers (Kyber, 1inch, Uniswap Universal Router) that convert any asset → USDC
 *
 *      ═══════════════════════════════════════════════════════════════════════
 *      ARCHITECTURE: External Router → USDC Gateway → YOLO Internal Routing
 *      ═══════════════════════════════════════════════════════════════════════
 *
 *      EXTERNAL WORLD (MockRouter simulates Kyber/1inch/etc):
 *        PT-tokens, LP tokens, wstETH, sUSDe, WETH, real assets, etc.
 *                     ↓
 *               [MockRouter]  ← External DEX aggregator (Kyber/1inch simulation)
 *                     ↓
 *                   USDC  ← Gateway to YOLO protocol
 *                     ↓
 *      YOLO PROTOCOL (Internal routing via YOLO router adapter):
 *               USDC ↔ USY (Anchor Pool - Curve StableSwap via UniswapV4RouterAdapter)
 *                     ↓
 *               USY ↔ yAssets (Synthetic Pools - Oracle-based via UniswapV4RouterAdapter)
 *
 *      ═══════════════════════════════════════════════════════════════════════
 *
 *      PURPOSE OF MOCKROUTER:
 *      - Simulates external DEX aggregators (Kyber/1inch) for EXTERNAL assets only
 *      - Converts external collateral (PT tokens, LP tokens, wstETH, etc.) ↔ USDC
 *      - Does NOT handle YOLO synthetic assets (yETH, yNVDA, etc.) - those are internal
 *      - Once we have USDC, YOLO internal routing (via Uniswap V4 router) takes over
 *
 *      LEVERAGE LOOP FLOW:
 *      1. User has: 100 sUSDe (external collateral)
 *      2. Flash loan: 0.16 yETH (YOLO synthetic)
 *      3. **YOLO Router (internal)**: yETH → USY → USDC (via UniswapV4RouterAdapter wrapping V4 actions)
 *      4. **MockRouter (external)**: USDC → sUSDe (external swap, oracle-based for testing)
 *      5. Now have: 500 sUSDe total (100 initial + 400 swapped)
 *      6. Deposit 500 sUSDe, borrow 0.16 yETH to repay flash loan
 *
 *      IN PRODUCTION:
 *      - MockRouter is replaced with Kyber/1inch adapter implementing IRouter
 *      - These real routers handle EXTERNAL assets only: WETH ↔ USDC, PT-USDe ↔ USDC, etc.
 *      - YOLO synthetic routing through UniswapV4RouterAdapter implementing IRouter, NOT external aggregators
 *
 *      IN TESTS:
 *      - MockRouter simulates external DEX aggregators (Kyber/1inch) - handles exotic assets ↔ USDC only
 *      - MockRouter needs pre-funding with tokens it will return (USDC, PT-USDe, etc.)
 *      - YOLO internal routing (USDC ↔ USY ↔ synthetics) handled by YOLO router adapter (implements IRouter)
 *        NOT by MockRouter - it's external to YOLO protocol
 *      - Router swap patterns for YOLO internal routing tested in TestAction03, TestAction07, etc.
 *
 *      Security:
 *      - Uses YoloOracle for accurate USD pricing (8 decimals)
 *      - No slippage on mock swaps (exact oracle prices)
 *      - Requires token approvals from caller
 *      - Atomic transfers (pull tokenIn, send USDC)
 */
contract MockRouter is IRouter {
    using SafeERC20 for IERC20;

    // ============================================================
    // IMMUTABLES
    // ============================================================

    /// @notice YoloOracle for price feeds
    /// @dev All prices in USD with 8 decimals (e.g., $1.00 = 1e8)
    IYoloOracle public immutable YOLO_ORACLE;

    /// @notice USDC address (gateway to YOLO protocol)
    /// @dev MockRouter always outputs USDC, then YOLO internal routing takes over
    address public immutable USDC;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Deploy MockRouter with oracle and USDC references
     * @param _yoloOracle Address of the YoloOracle contract
     * @param _usdc Address of the USDC token (gateway to YOLO protocol)
     */
    constructor(address _yoloOracle, address _usdc) {
        require(_yoloOracle != address(0) && _usdc != address(0), "MockRouter: zero address");
        YOLO_ORACLE = IYoloOracle(_yoloOracle);
        USDC = _usdc;
    }

    // ============================================================
    // SWAP FUNCTIONS
    // ============================================================

    /**
     * @notice Execute a token swap using oracle prices
     * @dev Supports bidirectional swaps:
     *      - USDC → tokenOut (for leveraging: buy more collateral)
     *      - tokenIn → USDC (for deleveraging: sell collateral)
     *
     *      Flow:
     *      1. Pull amountIn of tokenIn from msg.sender
     *      2. Get USD prices from oracle
     *      3. Calculate output:
     *         - If tokenOut is USDC: tokenIn → USD value → USDC
     *         - If tokenIn is USDC: USDC → USD value → tokenOut
     *      4. Transfer tokenOut to msg.sender
     *      5. Revert if amountOut < minAmountOut (slippage check)
     *
     *      Example 1: USDC → PT-USDe (USDC=$1.00, PT-USDe=$0.98) [LEVERAGE]
     *      - USD value = 400 USDC * $1.00 = $400
     *      - PT-USDe out = $400 / $0.98 = ~408 PT-USDe (discount bond)
     *
     *      Example 2: PT-USDe → USDC (PT-USDe=$0.98, USDC=$1.00) [DELEVERAGE]
     *      - USD value = 408 PT-USDe * $0.98 = $400
     *      - USDC out = $400 / $1.00 = 400 USDC
     *
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of tokenIn to swap (native decimals)
     * @param minAmountOut Minimum amount of tokenOut required (slippage protection)
     * @return amountOut Actual amount of tokenOut received
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut)
        external
        override
        returns (uint256 amountOut)
    {
        // Validation
        if (amountIn == 0) revert Router__SwapFailed();
        if (tokenIn == tokenOut) revert Router__InvalidPath();

        // Step 1: Pull tokenIn from caller
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        // Step 2: Calculate output amount
        if (tokenOut == USDC) {
            // Case 1: tokenIn → USDC
            amountOut = _calculateUSDCOutput(tokenIn, amountIn);
        } else if (tokenIn == USDC) {
            // Case 2: USDC → tokenOut
            amountOut = _calculateTokenOutput(tokenOut, amountIn);
        } else {
            // Case 3: tokenIn → tokenOut (route through USDC)
            uint256 usdcAmount = _calculateUSDCOutput(tokenIn, amountIn);
            amountOut = _calculateTokenOutput(tokenOut, usdcAmount);
        }

        // Step 3: Slippage check
        if (amountOut < minAmountOut) revert Router__InsufficientOutput();

        // Step 4: Transfer tokenOut to caller
        // Note: MockRouter must be pre-funded with tokenOut (cannot mint synthetics or route into V4 hook)
        IERC20(tokenOut).safeTransfer(msg.sender, amountOut);

        // Step 5: Emit event
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut, msg.sender);
    }

    /**
     * @notice Get quote for a swap (view function)
     * @dev Returns estimated output using oracle prices
     *
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of tokenIn to swap
     * @return amountOut Estimated amount of tokenOut
     */
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        override
        returns (uint256 amountOut)
    {
        if (tokenIn == tokenOut) return amountIn;

        if (tokenOut == USDC) {
            return _calculateUSDCOutput(tokenIn, amountIn);
        } else if (tokenIn == USDC) {
            return _calculateTokenOutput(tokenOut, amountIn);
        } else {
            uint256 usdcAmount = _calculateUSDCOutput(tokenIn, amountIn);
            return _calculateTokenOutput(tokenOut, usdcAmount);
        }
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Calculate USDC output from tokenIn using oracle prices
     * @dev Conversion: tokenIn → USD value → USDC amount
     *
     *      Formula:
     *      1. tokenInValueUSD = (amountIn * tokenInPriceX8) / (10 ** tokenInDecimals)
     *      2. usdcAmount = (tokenInValueUSD * 1e6) / usdcPriceX8
     *
     *      Example: 0.16 yETH → USDC (yETH=$2500, USDC=$1.00)
     *      - tokenInValueUSD = (0.16e18 * 2500e8) / 1e18 = 400e8
     *      - usdcAmount = (400e8 * 1e6) / 1e8 = 400e6 = 400 USDC
     *
     * @param tokenIn Input token address
     * @param amountIn Amount of tokenIn (native decimals)
     * @return usdcAmount Amount of USDC output (6 decimals)
     */
    function _calculateUSDCOutput(address tokenIn, uint256 amountIn) internal view returns (uint256 usdcAmount) {
        // Get oracle prices (8 decimals - e.g., $1.00 = 1e8)
        uint256 tokenInPriceX8 = YOLO_ORACLE.getAssetPrice(tokenIn);
        uint256 usdcPriceX8 = YOLO_ORACLE.getAssetPrice(USDC); // Typically $1.00 = 1e8

        // Get tokenIn decimals
        uint8 tokenInDecimals = _getDecimals(tokenIn);

        // Step 1: tokenIn → USD value (8 decimals)
        uint256 tokenInValueUSD = (amountIn * tokenInPriceX8) / (10 ** tokenInDecimals);

        // Step 2: USD value → USDC amount (6 decimals)
        usdcAmount = (tokenInValueUSD * 1e6) / usdcPriceX8;
    }

    /**
     * @notice Calculate token output from USDC using oracle prices
     * @dev Conversion: USDC → USD value → token amount
     *
     *      Formula:
     *      1. usdcValueUSD = (usdcAmount * usdcPriceX8) / 1e6
     *      2. tokenAmount = (usdcValueUSD * (10 ** tokenDecimals)) / tokenPriceX8
     *
     *      Example: 400 USDC → PT-USDe (USDC=$1.00, PT-USDe=$0.98)
     *      - usdcValueUSD = (400e6 * 1e8) / 1e6 = 400e8
     *      - tokenAmount = (400e8 * 1e18) / 0.98e8 = ~408e18 PT-USDe (discount bond)
     *
     * @param tokenOut Output token address
     * @param usdcAmount Amount of USDC input (6 decimals)
     * @return tokenAmount Amount of tokenOut output (native decimals)
     */
    function _calculateTokenOutput(address tokenOut, uint256 usdcAmount) internal view returns (uint256 tokenAmount) {
        // Get oracle prices (8 decimals)
        uint256 usdcPriceX8 = YOLO_ORACLE.getAssetPrice(USDC); // Typically $1.00 = 1e8
        uint256 tokenPriceX8 = YOLO_ORACLE.getAssetPrice(tokenOut);

        // Get tokenOut decimals
        uint8 tokenDecimals = _getDecimals(tokenOut);

        // Step 1: USDC → USD value (8 decimals)
        uint256 usdcValueUSD = (usdcAmount * usdcPriceX8) / 1e6;

        // Step 2: USD value → token amount (native decimals)
        tokenAmount = (usdcValueUSD * (10 ** tokenDecimals)) / tokenPriceX8;
    }

    /**
     * @notice Get decimals for a token
     * @dev Assumes all tokens have decimals() function
     * @param token Token address
     * @return Number of decimals
     */
    function _getDecimals(address token) internal view returns (uint8) {
        // Using low-level call to avoid importing IERC20Metadata
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!success) return 18; // Default to 18 if call fails
        return abi.decode(data, (uint8));
    }
}
