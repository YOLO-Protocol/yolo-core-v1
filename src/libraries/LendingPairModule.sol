// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DataTypes} from "./DataTypes.sol";
import {AppStorage} from "../core/YoloHookStorage.sol";

/**
 * @title LendingPairModule
 * @author alvin@yolo.wtf
 * @notice Library for configuring lending pairs in YOLO Protocol V1
 * @dev Externally linked library following Aave-style architecture
 *      Manages collateral-synthetic asset relationships with risk parameters
 *      Deposit/debt tokens are OPTIONAL (can be address(0))
 */
library LendingPairModule {
    // ============================================================
    // EVENTS
    // ============================================================

    /**
     * @notice Emitted when a new lending pair is configured
     * @param syntheticAsset The synthetic asset being borrowed
     * @param collateralAsset The collateral asset
     * @param pairId Unique identifier for the pair
     * @param ltv Loan-to-Value ratio
     */
    event LendingPairConfigured(
        address indexed syntheticAsset,
        address indexed collateralAsset,
        bytes32 indexed pairId,
        uint256 ltv,
        uint256 liquidationThreshold
    );

    /**
     * @notice Emitted when a lending pair is deactivated
     * @param pairId Unique identifier for the pair
     */
    event LendingPairDeactivated(bytes32 indexed pairId);

    /**
     * @notice Emitted when a lending pair is reactivated
     * @param pairId Unique identifier for the pair
     */
    event LendingPairReactivated(bytes32 indexed pairId);

    /**
     * @notice Emitted when risk parameters are updated
     * @param pairId Unique identifier for the pair
     * @param ltv New Loan-to-Value ratio
     * @param liquidationThreshold New liquidation threshold
     * @param liquidationBonus New liquidation bonus
     */
    event RiskParametersUpdated(
        bytes32 indexed pairId, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus
    );

    /**
     * @notice Emitted when borrow rate is updated
     * @param pairId Unique identifier for the pair
     * @param newBorrowRate New annual borrow rate
     */
    event BorrowRateUpdated(bytes32 indexed pairId, uint256 newBorrowRate);

    // ============================================================
    // ERRORS
    // ============================================================

    error LendingPairModule__InvalidAsset();
    error LendingPairModule__PairAlreadyExists();
    error LendingPairModule__PairNotFound();
    error LendingPairModule__InvalidLTV();
    error LendingPairModule__InvalidLiquidationThreshold();
    error LendingPairModule__InvalidLiquidationBonus();
    error LendingPairModule__CollateralNotWhitelisted();

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 private constant MAX_LTV = 9000; // 90% max LTV
    uint256 private constant MAX_LIQUIDATION_THRESHOLD = 9500; // 95% max threshold
    uint256 private constant MAX_LIQUIDATION_BONUS = 2000; // 20% max bonus
    uint256 private constant BASIS_POINTS = 10000;

    // ============================================================
    // STORAGE STRUCTURE
    // ============================================================

    /**
     * @notice Storage structure for lending pairs module
     * @dev Matches YoloHookStorage layout for library usage
     */
    struct LendingPairStorage {
        mapping(address => bool) _isYoloAsset;
        mapping(address => bool) _isWhitelistedCollateral;
        address[] _whitelistedCollaterals;
        mapping(bytes32 => DataTypes.PairConfiguration) _pairConfigs;
        mapping(address => address[]) _syntheticToCollaterals;
        mapping(address => address[]) _collateralToSynthetics;
    }

    // ============================================================
    // LENDING PAIR CONFIGURATION
    // ============================================================

    /**
     * @notice Configures a new lending pair
     * @dev Creates relationship between synthetic asset and collateral
     *      Deposit/debt tokens are OPTIONAL (pass address(0) to skip)
     * @param s Reference to AppStorage
     * @param syntheticAsset The synthetic asset being borrowed (e.g., yETH)
     * @param collateralAsset The collateral asset (e.g., USDC, WETH)
     * @param depositToken Optional receipt token for deposits (can be address(0))
     * @param debtToken Optional debt tracking token (can be address(0))
     * @param ltv Loan-to-Value ratio in basis points (e.g., 8000 = 80%)
     * @param liquidationThreshold Liquidation threshold in basis points (e.g., 8500 = 85%)
     * @param liquidationBonus Liquidation bonus in basis points (e.g., 500 = 5%)
     * @param borrowRate Annual borrow rate in basis points (e.g., 300 = 3%)
     * @return pairId Unique identifier for the pair
     */
    function configureLendingPair(
        AppStorage storage s,
        address syntheticAsset,
        address collateralAsset,
        address depositToken,
        address debtToken,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 borrowRate
    ) external returns (bytes32 pairId) {
        // Validation
        if (!s._isYoloAsset[syntheticAsset]) revert LendingPairModule__InvalidAsset();
        if (!s._isWhitelistedCollateral[collateralAsset]) {
            revert LendingPairModule__CollateralNotWhitelisted();
        }
        if (ltv > MAX_LTV) revert LendingPairModule__InvalidLTV();
        if (liquidationThreshold > MAX_LIQUIDATION_THRESHOLD || liquidationThreshold <= ltv) {
            revert LendingPairModule__InvalidLiquidationThreshold();
        }
        if (liquidationBonus > MAX_LIQUIDATION_BONUS) revert LendingPairModule__InvalidLiquidationBonus();

        // Generate pair ID
        pairId = keccak256(abi.encodePacked(syntheticAsset, collateralAsset));

        // Check if pair already exists
        if (s._pairConfigs[pairId].isActive) revert LendingPairModule__PairAlreadyExists();

        // Store configuration
        s._pairConfigs[pairId] = DataTypes.PairConfiguration({
            syntheticAsset: syntheticAsset,
            collateralAsset: collateralAsset,
            depositToken: depositToken, // Can be address(0)
            debtToken: debtToken, // Can be address(0)
            ltv: ltv,
            liquidationThreshold: liquidationThreshold,
            liquidationBonus: liquidationBonus,
            borrowRate: borrowRate,
            isActive: true,
            createdAt: block.timestamp
        });

        // Update mappings for enumeration
        s._syntheticToCollaterals[syntheticAsset].push(collateralAsset);
        s._collateralToSynthetics[collateralAsset].push(syntheticAsset);

        emit LendingPairConfigured(syntheticAsset, collateralAsset, pairId, ltv, liquidationThreshold);
    }

    // ============================================================
    // COLLATERAL MANAGEMENT
    // ============================================================

    /**
     * @notice Whitelists a collateral asset
     * @dev Only callable by assets admin via YoloHook
     * @param s Reference to AppStorage
     * @param collateralAsset Address of collateral to whitelist
     */
    function whitelistCollateral(AppStorage storage s, address collateralAsset) external {
        if (collateralAsset == address(0)) revert LendingPairModule__InvalidAsset();
        if (s._isWhitelistedCollateral[collateralAsset]) return; // Already whitelisted

        s._isWhitelistedCollateral[collateralAsset] = true;
        s._whitelistedCollaterals.push(collateralAsset);
    }

    /**
     * @notice Removes a collateral asset from whitelist
     * @dev Only callable by assets admin via YoloHook
     * @param s Reference to AppStorage
     * @param collateralAsset Address of collateral to remove
     */
    function removeCollateralWhitelist(AppStorage storage s, address collateralAsset) external {
        s._isWhitelistedCollateral[collateralAsset] = false;
        // Note: Does not remove from array to avoid gas-expensive operations
        // Array is for enumeration only, isWhitelisted mapping is source of truth
    }

    // ============================================================
    // PAIR MANAGEMENT
    // ============================================================

    /**
     * @notice Deactivates a lending pair
     * @dev Only callable by risk admin via YoloHook
     * @param s Reference to AppStorage
     * @param pairId Unique identifier for the pair
     */
    function deactivateLendingPair(AppStorage storage s, bytes32 pairId) external {
        if (!s._pairConfigs[pairId].isActive) revert LendingPairModule__PairNotFound();

        s._pairConfigs[pairId].isActive = false;
        emit LendingPairDeactivated(pairId);
    }

    /**
     * @notice Reactivates a lending pair
     * @dev Only callable by risk admin via YoloHook
     * @param s Reference to AppStorage
     * @param pairId Unique identifier for the pair
     */
    function reactivateLendingPair(AppStorage storage s, bytes32 pairId) external {
        if (s._pairConfigs[pairId].createdAt == 0) revert LendingPairModule__PairNotFound();

        s._pairConfigs[pairId].isActive = true;
        emit LendingPairReactivated(pairId);
    }

    /**
     * @notice Updates risk parameters for a lending pair
     * @dev Only callable by risk admin via YoloHook
     * @param s Reference to AppStorage
     * @param pairId Unique identifier for the pair
     * @param ltv New Loan-to-Value ratio
     * @param liquidationThreshold New liquidation threshold
     * @param liquidationBonus New liquidation bonus
     */
    function updateRiskParameters(
        AppStorage storage s,
        bytes32 pairId,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus
    ) external {
        if (s._pairConfigs[pairId].createdAt == 0) revert LendingPairModule__PairNotFound();
        if (ltv > MAX_LTV) revert LendingPairModule__InvalidLTV();
        if (liquidationThreshold > MAX_LIQUIDATION_THRESHOLD || liquidationThreshold <= ltv) {
            revert LendingPairModule__InvalidLiquidationThreshold();
        }
        if (liquidationBonus > MAX_LIQUIDATION_BONUS) revert LendingPairModule__InvalidLiquidationBonus();

        s._pairConfigs[pairId].ltv = ltv;
        s._pairConfigs[pairId].liquidationThreshold = liquidationThreshold;
        s._pairConfigs[pairId].liquidationBonus = liquidationBonus;

        emit RiskParametersUpdated(pairId, ltv, liquidationThreshold, liquidationBonus);
    }

    /**
     * @notice Updates borrow rate for a lending pair
     * @dev Only callable by risk admin via YoloHook
     * @param s Reference to AppStorage
     * @param pairId Unique identifier for the pair
     * @param newBorrowRate New annual borrow rate in basis points
     */
    function updateBorrowRate(AppStorage storage s, bytes32 pairId, uint256 newBorrowRate) external {
        if (s._pairConfigs[pairId].createdAt == 0) revert LendingPairModule__PairNotFound();

        s._pairConfigs[pairId].borrowRate = newBorrowRate;
        emit BorrowRateUpdated(pairId, newBorrowRate);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Returns configuration for a lending pair
     * @param s Reference to AppStorage
     * @param syntheticAsset The synthetic asset
     * @param collateralAsset The collateral asset
     * @return Configuration struct
     */
    function getPairConfiguration(AppStorage storage s, address syntheticAsset, address collateralAsset)
        external
        view
        returns (DataTypes.PairConfiguration memory)
    {
        bytes32 pairId = keccak256(abi.encodePacked(syntheticAsset, collateralAsset));
        return s._pairConfigs[pairId];
    }

    /**
     * @notice Returns all collaterals for a synthetic asset
     * @param s Reference to AppStorage
     * @param syntheticAsset The synthetic asset
     * @return Array of collateral addresses
     */
    function getCollateralsForSynthetic(AppStorage storage s, address syntheticAsset)
        external
        view
        returns (address[] memory)
    {
        return s._syntheticToCollaterals[syntheticAsset];
    }

    /**
     * @notice Returns all synthetic assets for a collateral
     * @param s Reference to AppStorage
     * @param collateralAsset The collateral asset
     * @return Array of synthetic asset addresses
     */
    function getSyntheticsForCollateral(AppStorage storage s, address collateralAsset)
        external
        view
        returns (address[] memory)
    {
        return s._collateralToSynthetics[collateralAsset];
    }

    /**
     * @notice Returns all whitelisted collaterals
     * @param s Reference to AppStorage
     * @return Array of collateral addresses
     */
    function getAllWhitelistedCollaterals(AppStorage storage s) external view returns (address[] memory) {
        return s._whitelistedCollaterals;
    }

    /**
     * @notice Checks if collateral is whitelisted
     * @param s Reference to AppStorage
     * @param collateralAsset Address to check
     * @return True if whitelisted
     */
    function isWhitelistedCollateral(AppStorage storage s, address collateralAsset) external view returns (bool) {
        return s._isWhitelistedCollateral[collateralAsset];
    }
}
