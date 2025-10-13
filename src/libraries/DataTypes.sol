// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IYoloOracle} from "../interfaces/IYoloOracle.sol";

/**
 * @title DataTypes
 * @author alvin@yolo.wtf
 * @notice Library containing all data structures used in YOLO Protocol V1
 * @dev Follows Aave-style architecture with centralized type definitions
 *      for maintainability and consistency across modules
 */
library DataTypes {
    // ============================================================
    // ASSET CONFIGURATION
    // ============================================================

    /**
     * @notice Configuration for synthetic assets (yETH, yNVDA, yGOLD, etc.)
     * @param syntheticToken Address of the synthetic asset token (UUPS proxy)
     * @param underlyingAsset Reference asset for price oracle (e.g., WETH for yETH)
     * @param oracleSource Price feed source for the underlying asset
     * @param maxSupply Maximum supply cap (0 = unlimited)
     * @param isActive Whether the asset is active for trading
     * @param createdAt Timestamp when asset was created
     */
    struct AssetConfiguration {
        address syntheticToken;
        address underlyingAsset;
        address oracleSource;
        uint256 maxSupply;
        bool isActive;
        uint256 createdAt;
    }

    // ============================================================
    // LENDING PAIR CONFIGURATION
    // ============================================================

    /**
     * @notice Configuration for lending pairs (collateral-synthetic relationships)
     * @param syntheticAsset The synthetic asset being borrowed (e.g., yETH)
     * @param collateralAsset The collateral asset (e.g., USDC, WETH)
     * @param depositToken Optional receipt token for deposits (can be address(0))
     * @param debtToken Optional debt tracking token (can be address(0))
     * @param ltv Loan-to-Value ratio (in basis points, e.g., 8000 = 80%)
     * @param liquidationThreshold Liquidation threshold (in basis points, e.g., 8500 = 85%)
     * @param liquidationBonus Liquidation bonus (in basis points, e.g., 500 = 5%)
     * @param borrowRate Annual borrow rate (in basis points, e.g., 300 = 3%)
     * @param isActive Whether the pair is active
     * @param createdAt Timestamp when pair was created
     */
    struct PairConfiguration {
        address syntheticAsset;
        address collateralAsset;
        address depositToken;
        address debtToken;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 borrowRate;
        bool isActive;
        uint256 createdAt;
    }

    // ============================================================
    // USER POSITION
    // ============================================================

    /**
     * @notice User position data for a specific lending pair
     * @param collateralAmount Amount of collateral deposited
     * @param debtAmount Amount of synthetic asset borrowed
     * @param lastUpdateTimestamp Last time position was updated
     * @param accumulatedInterest Accumulated interest since last update
     */
    struct UserPosition {
        uint256 collateralAmount;
        uint256 debtAmount;
        uint256 lastUpdateTimestamp;
        uint256 accumulatedInterest;
    }

    // ============================================================
    // POOL CONFIGURATION (For Future Implementation)
    // ============================================================

    /**
     * @notice Configuration for Uniswap V4 pools
     * @dev Placeholder for future pool creation implementation
     * @param poolKey The Uniswap V4 pool key
     * @param isAnchorPool True for USY-USDC anchor pool, false for synthetic pools
     * @param amplificationParameter For anchor pool Curve math (A parameter)
     * @param swapFee Swap fee in basis points
     * @param isActive Whether the pool is active
     */
    struct PoolConfiguration {
        bytes32 poolKey;
        bool isAnchorPool;
        uint256 amplificationParameter;
        uint256 swapFee;
        bool isActive;
    }
}
