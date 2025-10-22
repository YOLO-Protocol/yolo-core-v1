// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title InterestRateMath
 * @author alvin@yolo.wtf
 * @notice Mathematical functions for compound interest calculations using Aave-style liquidity index
 * @dev Uses 27 decimal precision (RAY) for maximum accuracy with lazy index updates
 */
library InterestRateMath {
    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 internal constant RAY = 1e27;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    // ============================================================
    // ERRORS
    // ============================================================

    error InterestRateMath__Overflow();

    // ============================================================
    // CORE INTEREST CALCULATIONS
    // ============================================================

    /**
     * @notice Calculate new liquidity index with compound interest
     * @dev Lazy updates only when positions change (no automatic accrual)
     * @param currentLiquidityIndexRay Current index value (27 decimals)
     * @param rateBps Interest rate in basis points (e.g., 500 = 5%)
     * @param timeDelta Time elapsed in seconds
     * @return newLiquidityIndexRay Updated index value
     */
    function calculateLinearInterest(uint256 currentLiquidityIndexRay, uint256 rateBps, uint256 timeDelta)
        internal
        pure
        returns (uint256 newLiquidityIndexRay)
    {
        if (timeDelta == 0) return currentLiquidityIndexRay;

        // Convert rate to per-second RAY precision
        // rateBps = 500 (5%) -> ratePerSecondRay = (500 * RAY) / (10000 * SECONDS_PER_YEAR)
        uint256 ratePerSecondRay = (rateBps * RAY) / (10000 * SECONDS_PER_YEAR);

        // Calculate linear factor keeping RAY precision
        uint256 linearFactorRay = ratePerSecondRay * timeDelta;

        // Apply compound growth: newIndex = currentIndex * (1 + rate * time)
        // newIndex = currentIndex + (currentIndex * linearFactorRay) / RAY
        return currentLiquidityIndexRay + (currentLiquidityIndexRay * linearFactorRay) / RAY;
    }

    /**
     * @notice Calculate actual debt from normalized (scaled) debt
     * @dev Always use divUp for user obligations (protocol-favorable rounding)
     * @param scaledDebtRay User's stored debt amount (27 decimals)
     * @param currentLiquidityIndexRay Current global index (27 decimals)
     * @return actualDebt Real debt amount with compound interest (18 decimals)
     */
    function calculateActualDebt(uint256 scaledDebtRay, uint256 currentLiquidityIndexRay)
        internal
        pure
        returns (uint256 actualDebt)
    {
        if (scaledDebtRay == 0 || currentLiquidityIndexRay == 0) return 0;
        // Use divUp for debt calculations - round against user
        return divUp(scaledDebtRay * currentLiquidityIndexRay, RAY);
    }

    /**
     * @notice Calculate normalized (scaled) debt from actual debt
     * @dev Store debt in normalized form to accrue interest automatically
     * @param actualDebt Real debt amount (18 decimals)
     * @param liquidityIndexRay Current index (27 decimals)
     * @return scaledDebtRay Normalized debt amount (27 decimals)
     */
    function calculateScaledDebt(uint256 actualDebt, uint256 liquidityIndexRay)
        internal
        pure
        returns (uint256 scaledDebtRay)
    {
        if (actualDebt == 0 || liquidityIndexRay == 0) return 0;
        return (actualDebt * RAY) / liquidityIndexRay;
    }

    /**
     * @notice Calculate effective index for view functions (no storage writes)
     * @dev Used in views to project current interest without updating storage
     * @param currentLiquidityIndexRay Current stored index
     * @param rateBps Interest rate in basis points
     * @param timeDelta Time since last update
     * @return effectiveIndexRay Projected index value
     */
    function calculateEffectiveIndex(uint256 currentLiquidityIndexRay, uint256 rateBps, uint256 timeDelta)
        internal
        pure
        returns (uint256 effectiveIndexRay)
    {
        return calculateLinearInterest(currentLiquidityIndexRay, rateBps, timeDelta);
    }

    /**
     * @notice Helper function for ceiling division (rounds up)
     * @dev Protocol always rounds against user (protocol-favorable rounding)
     * @param a Numerator
     * @param b Denominator
     * @return Result rounded up
     */
    function divUp(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /**
     * @notice Calculate principal from normalized principal
     * @dev Principal does NOT grow with index - only debt grows
     *      currentLiquidityIndexRay is intentionally unused because principal is constant by design
     * @param normalizedPrincipalRay Stored principal (18 decimals)
     * @param userLiquidityIndexRay User's entry index when position was created/updated (27 decimals)
     * @param currentLiquidityIndexRay Current global index (UNUSED - kept for interface consistency)
     * @return currentPrincipal Actual principal amount (18 decimals)
     */
    function calculateCurrentPrincipal(
        uint256 normalizedPrincipalRay,
        uint256 userLiquidityIndexRay,
        uint256 /* currentLiquidityIndexRay */ // Unused: principal doesn't grow with index
    )
        internal
        pure
        returns (uint256 currentPrincipal)
    {
        if (normalizedPrincipalRay == 0 || userLiquidityIndexRay == 0) return 0;
        // Principal is constant - multiply by user's STORED index and divide by RAY
        // normalizedPrincipal was stored as: (actual * RAY) / userIndex
        // So we recover: (normalized * userIndex) / RAY = actual
        // (18 decimals * 27 decimals) / 27 decimals = 18 decimals
        return (normalizedPrincipalRay * userLiquidityIndexRay) / RAY;
    }

    /**
     * @notice Split repayment between interest and principal
     * @dev Interest paid first, then principal (standard repayment waterfall)
     * @param repayAmount Total amount to repay
     * @param interestAccrued Total interest owed
     * @param currentPrincipal Current principal balance
     * @return interestPaid Amount applied to interest
     * @return principalPaid Amount applied to principal
     */
    function splitRepayment(uint256 repayAmount, uint256 interestAccrued, uint256 currentPrincipal)
        internal
        pure
        returns (uint256 interestPaid, uint256 principalPaid)
    {
        // Pay interest first
        interestPaid = repayAmount < interestAccrued ? repayAmount : interestAccrued;
        principalPaid = repayAmount - interestPaid;

        // Cap principal payment at outstanding principal
        if (principalPaid > currentPrincipal) {
            principalPaid = currentPrincipal;
        }
    }
}
