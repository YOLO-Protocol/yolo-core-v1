// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AppStorage} from "../core/YoloHookStorage.sol";
import {CurveMath} from "./CurveMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/**
 * @title SwapModule
 * @author alvin@yolo.wtf
 * @notice Library for anchor pool swap logic (USY-USDC StableSwap)
 * @dev Handles delta calculations for beforeSwap and reserve updates for afterSwap
 *      Uses CurveMath for StableSwap invariant calculations
 */
library SwapModule {
    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 private constant PRECISION = 1e18;

    // ============================================================
    // ERRORS
    // ============================================================

    error SwapModule__InvalidAmount();
    error SwapModule__InsufficientLiquidity();
    error SwapModule__InsufficientOutput();

    // ============================================================
    // SWAP DELTA CALCULATION
    // ============================================================

    /**
     * @notice Calculate swap deltas for anchor pool
     * @dev Called from beforeSwap to determine token flows
     * @param s AppStorage reference
     * @param key PoolKey to determine token order
     * @param zeroForOne Direction of swap (true = token0 -> token1)
     * @param amountSpecified Input amount (exact input only, always negative in v4)
     * @return amountIn Input amount in native decimals
     * @return amountOut Output amount in native decimals
     * @return feeAmount Fee collected in output token (native decimals)
     */
    function calculateAnchorSwapDelta(AppStorage storage s, PoolKey memory key, bool zeroForOne, int256 amountSpecified)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut, uint256 feeAmount)
    {
        // V4 convention: exact input swaps have negative amountSpecified
        if (amountSpecified >= 0) revert SwapModule__InvalidAmount();

        // Convert to positive amount
        amountIn = uint256(-amountSpecified);

        // Determine token order: is token0 USY?
        bool isToken0USY = Currency.unwrap(key.currency0) == s.usy;

        // Get current reserves (NATIVE decimals: USY=18, USDC=6 or 18)
        uint256 reserveUSY = s.totalAnchorReserveUSY;
        uint256 reserveUSDC = s.totalAnchorReserveUSDC;

        // Sanity check
        if (reserveUSY == 0 || reserveUSDC == 0) revert SwapModule__InsufficientLiquidity();

        // Determine swap direction (USDC -> USY or USY -> USDC)
        bool usdcToUsy = zeroForOne ? !isToken0USY : isToken0USY;

        // Get reserves and scale factors (V0.5 pattern: lines 957-960)
        // rIn/rOut are in native decimals, sIn/sOut are scale factors
        uint256 rIn = usdcToUsy ? reserveUSDC : reserveUSY;
        uint256 rOut = usdcToUsy ? reserveUSY : reserveUSDC;
        uint256 sIn = usdcToUsy ? s.usdcScaleUp : 1;
        uint256 sOut = usdcToUsy ? 1 : s.usdcScaleUp;

        // Scale gross input to 18 decimals (V0.5 pattern: line 969)
        uint256 grossIn18 = amountIn * sIn;

        // Calculate fee and net input in 18 decimals (V0.5 pattern: line 970-971)
        uint256 fee18 = (grossIn18 * s.anchorSwapFeeBps) / 10000;
        uint256 netIn18 = grossIn18 - fee18;

        // Scale reserves to 18 decimals and calculate output with NET input (V0.5 pattern: line 972)
        uint256 amountOut18 = CurveMath.calculateSwapOutput(
            netIn18, // NET input in 18 decimals (after fee deduction)
            rIn * sIn, // reserve in, scaled to 18 decimals
            rOut * sOut, // reserve out, scaled to 18 decimals
            s.anchorAmplificationCoefficient
        );

        // Scale output and fee back to native decimals (V0.5 pattern: line 974-976)
        amountOut = amountOut18 / sOut;
        feeAmount = fee18 / sIn; // Fee is in input token decimals

        if (amountOut == 0) revert SwapModule__InsufficientOutput();

        return (amountIn, amountOut, feeAmount);
    }

    // ============================================================
    // RESERVE UPDATES
    // ============================================================

    /**
     * @notice Update anchor pool reserves after swap
     * @dev Called from afterSwap to update reserve tracking
     *      CRITICAL: Correct delta sign convention
     *      - delta < 0 means caller PAID → pool reserves INCREASE
     *      - delta > 0 means caller RECEIVED → pool reserves DECREASE
     *      IMPORTANT: Reserves are stored in NATIVE decimals (USY=18, USDC=6 or 18)
     *      Deltas are also in NATIVE decimals, so no conversion needed (V0.5 pattern: lines 988-993)
     * @param s AppStorage reference
     * @param key PoolKey to determine token order
     * @param delta BalanceDelta from swap (caller's perspective)
     */
    function updateAnchorReserves(AppStorage storage s, PoolKey memory key, BalanceDelta delta) internal {
        // Determine token order
        bool isToken0USY = Currency.unwrap(key.currency0) == s.usy;

        // Extract deltas (from caller's perspective, in NATIVE decimals)
        int128 delta0 = delta.amount0();
        int128 delta1 = delta.amount1();

        // Update reserves based on token order and delta signs
        // Both reserves and deltas are in NATIVE decimals, no conversion needed
        if (isToken0USY) {
            // token0 = USY (18 dec), token1 = USDC (6 or 18 dec)
            s.totalAnchorReserveUSY = _applyDelta(s.totalAnchorReserveUSY, delta0);
            s.totalAnchorReserveUSDC = _applyDelta(s.totalAnchorReserveUSDC, delta1);
        } else {
            // token0 = USDC (6 or 18 dec), token1 = USY (18 dec)
            s.totalAnchorReserveUSDC = _applyDelta(s.totalAnchorReserveUSDC, delta0);
            s.totalAnchorReserveUSY = _applyDelta(s.totalAnchorReserveUSY, delta1);
        }
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Apply delta to reserve (NATIVE decimals)
     * @dev CRITICAL: Correct sign convention
     *      - delta < 0: caller paid → pool receives → INCREASE reserve
     *      - delta > 0: caller received → pool gives → DECREASE reserve
     *      Works with NATIVE decimals (no conversion needed)
     * @param reserve Current reserve value (NATIVE decimals)
     * @param delta Delta from BalanceDelta (NATIVE decimals, caller's perspective)
     * @return newReserve Updated reserve value (NATIVE decimals)
     */
    function _applyDelta(uint256 reserve, int128 delta) private pure returns (uint256 newReserve) {
        if (delta < 0) {
            // Caller paid (negative) → pool receives → INCREASE reserve
            newReserve = reserve + uint128(-delta);
        } else {
            // Caller received (positive) → pool gives → DECREASE reserve
            newReserve = reserve - uint128(delta);
        }
        return newReserve;
    }
}
