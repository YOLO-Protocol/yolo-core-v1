// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title StableMath
 * @author alvin@yolo.wtf
 * @notice Library for StableSwap invariant calculations
 * @dev Implements Newton's method for solving the StableSwap invariant
 *      Used for USY-USDC anchor pool with low-slippage swaps
 *
 * StableSwap Invariant:
 *   A * n^n * sum(x_i) + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
 *
 * Where:
 *   A = amplification coefficient (higher = flatter curve)
 *   n = number of coins (2 for our case)
 *   D = invariant (constant sum in amplified proportion)
 *   x_i = balance of coin i
 */
library StableMath {
    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Precision for all calculations (18 decimals)
    uint256 private constant PRECISION = 1e18;

    /// @notice Number of coins in the pool
    uint256 private constant N_COINS = 2;

    /// @notice Amplification coefficient precision (no scaling)
    uint256 private constant A_PRECISION = 1;

    /// @notice Maximum iterations for Newton's method
    uint256 private constant MAX_ITERATIONS = 255;

    /// @notice Convergence threshold (1 wei)
    uint256 private constant CONVERGENCE_THRESHOLD = 1;

    // ============================================================
    // ERRORS
    // ============================================================

    error StableMath__ConvergenceFailure();
    error StableMath__InvalidReserves();
    error StableMath__InvalidAmount();

    // ============================================================
    // D INVARIANT CALCULATION
    // ============================================================

    /**
     * @notice Calculate D invariant using Newton's method
     * @dev Iteratively solves: A * n^n * S + D = A * D * n^n + D^(n+1) / (n^n * prod(x_i))
     * @param xp Array of balances [reserve0, reserve1] in 18 decimals
     * @param A Amplification coefficient
     * @return D The invariant value
     */
    function getD(uint256[2] memory xp, uint256 A) internal pure returns (uint256) {
        // Validation
        if (xp[0] == 0 || xp[1] == 0) revert StableMath__InvalidReserves();

        uint256 S = xp[0] + xp[1]; // Sum of balances
        if (S == 0) return 0;

        uint256 Dprev = 0;
        uint256 D = S; // Initial guess

        // Ann = A * n^n (where n = 2)
        // For n=2: n^n = 4
        uint256 Ann = A * N_COINS * N_COINS / A_PRECISION;

        // Newton iteration
        for (uint256 i = 0; i < MAX_ITERATIONS;) {
            // D_P = D^3 / (4 * x0 * x1)
            // Split calculation to avoid overflow
            uint256 D_P = D;
            D_P = (D_P * D) / (xp[0] * N_COINS); // D^2 / (2 * x0)
            D_P = (D_P * D) / (xp[1] * N_COINS); // D^3 / (4 * x0 * x1)

            Dprev = D;

            // Numerator: (Ann * S + D_P * N_COINS) * D
            // Denominator: (Ann - 1) * D + (N_COINS + 1) * D_P
            D = ((Ann * S + D_P * N_COINS) * D) / ((Ann - A_PRECISION) * D + (N_COINS + 1) * D_P);

            // Check convergence
            if (D > Dprev) {
                if (D - Dprev <= CONVERGENCE_THRESHOLD) break;
            } else {
                if (Dprev - D <= CONVERGENCE_THRESHOLD) break;
            }

            unchecked {
                ++i;
            }
        }

        // Sanity check - D should be close to S for balanced pools
        if (D == 0) revert StableMath__ConvergenceFailure();

        return D;
    }

    // ============================================================
    // Y CALCULATION
    // ============================================================

    /**
     * @notice Calculate y given x using Newton's method
     * @dev Solves for output balance given input balance and invariant D
     * @param x New balance of input token (after deposit)
     * @param D Invariant calculated from current reserves
     * @param A Amplification coefficient
     * @return y New balance of output token
     */
    function getY(uint256 x, uint256 D, uint256 A) internal pure returns (uint256) {
        // Validation
        if (x == 0) revert StableMath__InvalidAmount();
        if (D == 0) revert StableMath__InvalidReserves();

        // Ann = A * n^n
        uint256 Ann = A * N_COINS * N_COINS / A_PRECISION;

        // c = D^3 / (n^n * x * Ann)
        // For n=2: c = D^3 / (4 * x * Ann)
        uint256 c = D;
        c = (c * D) / (x * N_COINS); // D^2 / (2x)
        c = (c * D) / (N_COINS * Ann); // D^3 / (4 * x * Ann)

        // b = x + D/Ann
        uint256 b = x + (D / Ann);

        uint256 yPrev = 0;
        uint256 y = D; // Initial guess

        // Newton iteration: y = (y^2 + c) / (2y + b - D)
        for (uint256 i = 0; i < MAX_ITERATIONS;) {
            yPrev = y;

            // y = (y^2 + c) / (2y + b - D)
            y = (y * y + c) / (2 * y + b - D);

            // Check convergence
            if (y > yPrev) {
                if (y - yPrev <= CONVERGENCE_THRESHOLD) break;
            } else {
                if (yPrev - y <= CONVERGENCE_THRESHOLD) break;
            }

            unchecked {
                ++i;
            }
        }

        if (y == 0) revert StableMath__ConvergenceFailure();

        return y;
    }

    // ============================================================
    // SWAP CALCULATION
    // ============================================================

    /**
     * @notice Calculate swap output amount
     * @dev Computes output for exact input swap using StableSwap curve
     * @param amountIn Input amount (18 decimals)
     * @param reserveIn Current reserve of input token (18 decimals)
     * @param reserveOut Current reserve of output token (18 decimals)
     * @param A Amplification coefficient
     * @return amountOut Output amount before fees (18 decimals)
     */
    function calculateSwapOutput(uint256 amountIn, uint256 reserveIn, uint256 reserveOut, uint256 A)
        internal
        pure
        returns (uint256 amountOut)
    {
        if (amountIn == 0) revert StableMath__InvalidAmount();
        if (reserveIn == 0 || reserveOut == 0) revert StableMath__InvalidReserves();

        // 1. Calculate current D invariant
        uint256[2] memory xp;
        xp[0] = reserveIn;
        xp[1] = reserveOut;
        uint256 D = getD(xp, A);

        // 2. Calculate new input balance after swap
        uint256 newReserveIn = reserveIn + amountIn;

        // 3. Calculate new output balance using getY
        uint256 newReserveOut = getY(newReserveIn, D, A);

        // 4. Calculate output amount (difference in reserves)
        if (newReserveOut >= reserveOut) revert StableMath__InvalidAmount();
        amountOut = reserveOut - newReserveOut;

        return amountOut;
    }

    // ============================================================
    // FEE CALCULATION
    // ============================================================

    /**
     * @notice Apply trading fee to output amount
     * @param amountOut Output amount before fee
     * @param feeBps Fee in basis points (e.g., 4 = 0.04%)
     * @return amountAfterFee Output amount after deducting fee
     * @return feeAmount Fee amount deducted
     */
    function applyFee(uint256 amountOut, uint256 feeBps)
        internal
        pure
        returns (uint256 amountAfterFee, uint256 feeAmount)
    {
        if (feeBps == 0) {
            return (amountOut, 0);
        }

        // Fee is deducted from output
        feeAmount = (amountOut * feeBps) / 10000;
        amountAfterFee = amountOut - feeAmount;

        return (amountAfterFee, feeAmount);
    }
}
