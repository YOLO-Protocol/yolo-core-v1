// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {AppStorage} from "../core/YoloHookStorage.sol";
import {DataTypes} from "./DataTypes.sol";
import {StableMath} from "./StableMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SwapModule
 * @author alvin@yolo.wtf
 * @notice Library for anchor pool swap logic (USY-USDC StableSwap)
 * @dev Handles delta calculations for beforeSwap and reserve updates for afterSwap
 *      Uses StableMath for StableSwap invariant calculations
 */
library SwapModule {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;

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

    struct AnchorSwapResult {
        bytes4 selector;
        BeforeSwapDelta delta;
        uint24 lpFeeOverride;
        int128 delta0;
        int128 delta1;
        uint256 feeAmount;
    }

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
     * @return feeAmount Fee collected in input token (native decimals)
     */
    function calculateAnchorSwapDelta(
        AppStorage storage s,
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified
    ) internal view returns (uint256 amountIn, uint256 amountOut, uint256 feeAmount) {
        // V4 convention: exact input swaps have negative amountSpecified
        if (amountSpecified >= 0) revert SwapModule__InvalidAmount();

        // Convert to positive amount
        amountIn = SafeCast.toUint256(-amountSpecified);

        // Determine token order: is token0 USY?
        bool isToken0USY = Currency.unwrap(key.currency0) == s.usy;

        // Get current reserves (NATIVE decimals: USY=18, USDC=6 or 18)
        uint256 reserveUSY = s.totalAnchorReserveUSY;
        uint256 reserveUSDC = s.totalAnchorReserveUSDC;

        // Sanity check
        if (reserveUSY == 0 || reserveUSDC == 0) revert SwapModule__InsufficientLiquidity();

        // Determine swap direction (USDC -> USY or USY -> USDC)
        bool usdcToUsy = zeroForOne ? !isToken0USY : isToken0USY;

        // Get reserves and scale factors for decimal normalization
        // rIn/rOut are in native decimals, sIn/sOut are scale factors
        uint256 rIn = usdcToUsy ? reserveUSDC : reserveUSY;
        uint256 rOut = usdcToUsy ? reserveUSY : reserveUSDC;
        uint256 sIn = usdcToUsy ? s.USDC_SCALE_UP : 1;
        uint256 sOut = usdcToUsy ? 1 : s.USDC_SCALE_UP;

        // Scale gross input to 18 decimals
        uint256 grossIn18 = amountIn * sIn;

        // Calculate fee and net input in 18 decimals
        uint256 fee18 = (grossIn18 * s.anchorSwapFeeBps) / 10000;
        uint256 netIn18 = grossIn18 - fee18;

        // Scale reserves to 18 decimals and calculate output with NET input
        uint256 amountOut18 = StableMath.calculateSwapOutput(
            netIn18, // NET input in 18 decimals (after fee deduction)
            rIn * sIn, // reserve in, scaled to 18 decimals
            rOut * sOut, // reserve out, scaled to 18 decimals
            s.anchorAmplificationCoefficient
        );

        // Scale output and fee back to native decimals
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
     *      Deltas are also in NATIVE decimals, so no conversion needed
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
            newReserve = reserve + SafeCast.toUint128(SafeCast.toUint256(-delta));
        } else {
            // Caller received (positive) → pool gives → DECREASE reserve
            newReserve = reserve - SafeCast.toUint128(SafeCast.toUint256(delta));
        }
        return newReserve;
    }

    // ============================================================
    // SWAP PREVIEW
    // ============================================================

    /**
     * @notice Preview anchor pool swap output
     * @dev Simulates a swap without executing it
     *      Extracted from YoloHook for code size reduction
     * @param s AppStorage reference
     * @param anchorPoolKey Anchor pool ID
     * @param zeroForOne Direction of swap (true = token0 -> token1)
     * @param amountIn Input amount (in native decimals)
     * @return amountOut Output amount (in 18 decimals normalized)
     * @return feeAmount Fee amount (in 18 decimals normalized)
     */
    function previewAnchorSwap(AppStorage storage s, bytes32 anchorPoolKey, bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        DataTypes.PoolConfiguration memory poolConfig = s._poolConfigs[anchorPoolKey];

        // Calculate swap delta
        (uint256 calculatedAmountIn, uint256 calculatedAmountOut, uint256 calculatedFeeAmount) =
            calculateAnchorSwapDelta(s, poolConfig.poolKey, zeroForOne, -SafeCast.toInt256(amountIn));

        // Scale outputs to 18 decimals for consistency
        // Determine if output is USDC (needs scaling) or USY (already 18 decimals)
        bool isToken0USY = Currency.unwrap(poolConfig.poolKey.currency0) == s.usy;
        bool outputIsUSY = zeroForOne ? !isToken0USY : isToken0USY;

        // Scale USDC output to 18 decimals
        if (!outputIsUSY && s.usdcDecimals != 18) {
            calculatedAmountOut = calculatedAmountOut * s.USDC_SCALE_UP;
            calculatedFeeAmount = calculatedFeeAmount * s.USDC_SCALE_UP;
        }

        return (calculatedAmountOut, calculatedFeeAmount);
    }

    // ============================================================
    // SWAP EXECUTION
    // ============================================================

    /**
     * @notice Handle anchor pool swap execution
     * @dev Performs full swap settlement with PoolManager and reserve updates
     * @param s AppStorage reference
     * @param poolManager PoolManager instance
     * @param key PoolKey identifying the anchor pool
     * @param params Swap parameters
     * @return result Struct containing swap deltas, selector, and fee information for event emission
     */
    function executeAnchorSwap(
        AppStorage storage s,
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata params
    ) external returns (AnchorSwapResult memory result) {
        (uint256 grossIn, uint256 amountOut, uint256 feeAmount) =
            calculateAnchorSwapDelta(s, key, params.zeroForOne, params.amountSpecified);

        uint256 netIn = grossIn - feeAmount;

        bool isToken0USY = Currency.unwrap(key.currency0) == s.usy;
        bool usdcToUsy = params.zeroForOne ? !isToken0USY : isToken0USY;

        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = params.zeroForOne ? key.currency1 : key.currency0;

        // Settle token flows via PoolManager
        if (netIn > 0) {
            currencyIn.take(poolManager, address(this), netIn, true);
        }
        if (feeAmount > 0) {
            currencyIn.take(poolManager, address(this), feeAmount, false);
        }
        if (amountOut > 0) {
            currencyOut.settle(poolManager, address(this), amountOut, true);
        }

        // Update anchor pool reserves
        if (usdcToUsy) {
            s.totalAnchorReserveUSDC += netIn;
            s.totalAnchorReserveUSY -= amountOut;
            s._pendingRehypoUSDC = netIn;
        } else {
            s.totalAnchorReserveUSY += netIn;
            s.totalAnchorReserveUSDC -= amountOut;
            s._pendingDehypoUSDC = amountOut;
        }

        // Distribute anchor swap fees
        if (feeAmount > 0) {
            // Split fee based on governance parameter
            uint256 feeToTreasury = (feeAmount * s.anchorFeeTreasuryShareBps) / 10_000;
            uint256 feeToLPs = feeAmount - feeToTreasury;

            // Add LP portion to reserves (auto-compound, increases sUSY value)
            if (usdcToUsy) {
                s.totalAnchorReserveUSDC += feeToLPs;
            } else {
                s.totalAnchorReserveUSY += feeToLPs;
            }

            // Transfer treasury portion (skip if treasury not set)
            if (feeToTreasury > 0 && s.treasury != address(0)) {
                IERC20(Currency.unwrap(currencyIn)).transfer(s.treasury, feeToTreasury);
            }
        }

        bool exactIn = params.amountSpecified < 0;
        int128 delta0;
        int128 delta1;

        if (params.zeroForOne) {
            if (exactIn) {
                delta0 = SafeCast.toInt128(SafeCast.toInt256(grossIn));
                delta1 = -SafeCast.toInt128(SafeCast.toInt256(amountOut));
            } else {
                delta0 = -SafeCast.toInt128(SafeCast.toInt256(amountOut));
                delta1 = SafeCast.toInt128(SafeCast.toInt256(grossIn));
            }
        } else {
            if (exactIn) {
                delta0 = -SafeCast.toInt128(SafeCast.toInt256(amountOut));
                delta1 = SafeCast.toInt128(SafeCast.toInt256(grossIn));
            } else {
                delta0 = SafeCast.toInt128(SafeCast.toInt256(grossIn));
                delta1 = -SafeCast.toInt128(SafeCast.toInt256(amountOut));
            }
        }

        int128 deltaSpecified = params.zeroForOne ? delta0 : delta1;
        int128 deltaUnspecified = params.zeroForOne ? delta1 : delta0;
        result.selector = IHooks.beforeSwap.selector;
        result.delta = toBeforeSwapDelta(deltaSpecified, deltaUnspecified);
        result.lpFeeOverride = 0;
        result.delta0 = delta0;
        result.delta1 = delta1;
        result.feeAmount = feeAmount;
    }

    function afterSwapCleanup(AppStorage storage s) external {
        s._pendingRehypoUSDC = 0;
        s._pendingDehypoUSDC = 0;
    }
}
