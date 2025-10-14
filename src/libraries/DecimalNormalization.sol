// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title DecimalNormalization
 * @author alvin@yolo.wtf
 * @notice Helper library for consistent decimal conversions
 * @dev Single source of truth for normalization logic
 *      All conversions to/from 18 decimals for internal calculations
 */
library DecimalNormalization {
    // ============================================================
    // ERRORS
    // ============================================================

    error InvalidDecimals();

    // ============================================================
    // NORMALIZATION FUNCTIONS
    // ============================================================

    /**
     * @notice Normalize amount to 18 decimals
     * @dev Scales up if decimals < 18, reverts if decimals > 18
     * @param amount Amount in native decimals
     * @param decimals Native decimals (must be <= 18)
     * @return amount18 Amount in 18 decimals
     */
    function to18(uint256 amount, uint8 decimals) internal pure returns (uint256 amount18) {
        if (decimals > 18) revert InvalidDecimals();

        if (decimals == 18) {
            return amount;
        } else {
            // Scale up: multiply by 10^(18 - decimals)
            return amount * (10 ** (18 - decimals));
        }
    }

    /**
     * @notice Convert from 18 decimals to native decimals
     * @dev Scales down if decimals < 18, reverts if decimals > 18
     *      Rounds down to favor pool (conservative for user outputs)
     * @param amount18 Amount in 18 decimals
     * @param decimals Target decimals (must be <= 18)
     * @return amount Amount in native decimals (rounded down)
     */
    function from18(uint256 amount18, uint8 decimals) internal pure returns (uint256 amount) {
        if (decimals > 18) revert InvalidDecimals();

        if (decimals == 18) {
            return amount18;
        } else {
            // Scale down: divide by 10^(18 - decimals)
            // Rounds down automatically (Solidity default)
            return amount18 / (10 ** (18 - decimals));
        }
    }
}
