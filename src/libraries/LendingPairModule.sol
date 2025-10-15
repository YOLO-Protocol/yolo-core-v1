// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DataTypes} from "./DataTypes.sol";
import {AppStorage} from "../core/YoloHookStorage.sol";
import {InterestRateMath} from "./InterestRateMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYoloSyntheticAsset} from "../interfaces/IYoloSyntheticAsset.sol";

/**
 * @title LendingPairModule
 * @author alvin@yolo.wtf
 * @notice Library for managing lending pairs and CDP operations in YOLO Protocol V1
 * @dev Externally linked library following Aave-style architecture
 *      Manages collateral-synthetic asset relationships with compound interest
 *      Deposit/debt tokens are OPTIONAL (can be address(0))
 */
library LendingPairModule {
    using SafeERC20 for IERC20;
    using InterestRateMath for uint256;

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

    /**
     * @notice Emitted when minimum borrow amount is updated
     * @param pairId Unique identifier for the pair
     * @param newMinimumBorrowAmount New minimum borrow amount
     */
    event MinimumBorrowAmountUpdated(bytes32 indexed pairId, uint256 newMinimumBorrowAmount);

    /**
     * @notice Emitted when pair caps are updated
     * @param pairId Unique identifier for the pair
     * @param newMaxMintableCap New maximum mintable cap
     * @param newMaxSupplyCap New maximum supply cap
     */
    event PairCapsUpdated(bytes32 indexed pairId, uint256 newMaxMintableCap, uint256 newMaxSupplyCap);

    /**
     * @notice Emitted when liquidation penalty is updated
     * @param pairId Unique identifier for the pair
     * @param newLiquidationPenalty New liquidation penalty
     */
    event LiquidationPenaltyUpdated(bytes32 indexed pairId, uint256 newLiquidationPenalty);

    /**
     * @notice Emitted when pair expiry settings are updated
     * @param pairId Unique identifier for the pair
     * @param isExpirable Whether positions expire
     * @param expirePeriod Expiry period in seconds
     */
    event PairExpiryUpdated(bytes32 indexed pairId, bool isExpirable, uint256 expirePeriod);

    /**
     * @notice Emitted when a borrow occurs
     */
    event Borrowed(
        address indexed user,
        address indexed collateral,
        uint256 collateralAmount,
        address indexed yoloAsset,
        uint256 borrowAmount
    );

    /**
     * @notice Emitted when a repayment occurs
     */
    event Repaid(
        address indexed user,
        address indexed collateral,
        address indexed yoloAsset,
        uint256 repayAmount,
        uint256 interestPaid,
        uint256 principalPaid
    );

    /**
     * @notice Emitted when a position is renewed
     */
    event PositionRenewed(
        address indexed user, address indexed collateral, address indexed yoloAsset, uint256 interestPaid
    );

    function getPositionDebt(AppStorage storage s, address user, address collateral, address yoloAsset)
        external
        view
        returns (uint256)
    {
        DataTypes.UserPosition storage position = s.positions[user][collateral][yoloAsset];
        bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
        DataTypes.PairConfiguration storage config = s._pairConfigs[pairId];

        uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
        uint256 effectiveIndex =
            InterestRateMath.calculateEffectiveIndex(config.liquidityIndexRay, config.borrowRate, timeDelta);

        return InterestRateMath.calculateActualDebt(position.normalizedDebtRay, effectiveIndex);
    }

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
    error LendingPairModule__InsufficientAmount();
    error LendingPairModule__NotYoloAsset();
    error LendingPairModule__InvalidPair();
    error LendingPairModule__YoloAssetPaused();
    error LendingPairModule__CollateralPaused();
    error LendingPairModule__InvalidPosition();
    error LendingPairModule__NotSolvent();
    error LendingPairModule__ExceedsYoloAssetMintCap();
    error LendingPairModule__ExceedsCollateralCap();
    error LendingPairModule__NoDebt();
    error LendingPairModule__RepayExceedsDebt();

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 internal constant RAY = 1e27;
    uint256 internal constant PRECISION_DIVISOR = 10000;
    // Note: Minimum borrow amount is now per-pair (see PairConfiguration.minimumBorrowAmount)

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
     * @param liquidationPenalty Liquidation penalty in basis points (e.g., 500 = 5%)
     * @param borrowRate Annual borrow rate in basis points (e.g., 300 = 3%)
     * @param maxMintableCap Maximum mintable cap for synthetic asset
     * @param maxSupplyCap Maximum supply cap for collateral
     * @param minimumBorrowAmount Minimum borrow amount (in synthetic asset decimals, 0 = no minimum)
     * @param isExpirable Whether positions expire
     * @param expirePeriod Expiry period in seconds
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
        uint256 liquidationPenalty,
        uint256 borrowRate,
        uint256 maxMintableCap,
        uint256 maxSupplyCap,
        uint256 minimumBorrowAmount,
        bool isExpirable,
        uint256 expirePeriod
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
            liquidationPenalty: liquidationPenalty,
            borrowRate: borrowRate,
            liquidityIndexRay: RAY, // Initialize to 1.0 in RAY precision
            lastUpdateTimestamp: block.timestamp,
            maxMintableCap: maxMintableCap,
            maxSupplyCap: maxSupplyCap,
            minimumBorrowAmount: minimumBorrowAmount, // Per-pair minimum (0 = no minimum)
            isExpirable: isExpirable,
            expirePeriod: expirePeriod,
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

        DataTypes.PairConfiguration storage pairConfig = s._pairConfigs[pairId];

        // CRITICAL: Update global index with OLD rate first before changing to new rate
        _updateGlobalLiquidityIndex(s, pairConfig, pairConfig.borrowRate);

        // Now update to new rate
        pairConfig.borrowRate = newBorrowRate;
        emit BorrowRateUpdated(pairId, newBorrowRate);
    }

    /**
     * @notice Updates minimum borrow amount for a lending pair
     * @dev Only callable by risk admin via YoloHook
     *      Allows admins to adjust minimums per asset economics (e.g., lower for high-value assets like yBRK.A)
     * @param s Reference to AppStorage
     * @param pairId Unique identifier for the pair
     * @param newMinimumBorrowAmount New minimum borrow amount (in synthetic asset decimals, 0 = no minimum)
     */
    function updateMinimumBorrowAmount(AppStorage storage s, bytes32 pairId, uint256 newMinimumBorrowAmount) external {
        if (s._pairConfigs[pairId].createdAt == 0) revert LendingPairModule__PairNotFound();

        s._pairConfigs[pairId].minimumBorrowAmount = newMinimumBorrowAmount;

        emit MinimumBorrowAmountUpdated(pairId, newMinimumBorrowAmount);
    }

    /**
     * @notice Updates caps for a lending pair
     * @dev Only callable by risk admin via YoloHook
     *      Allows dynamic adjustment of supply/mint caps without recreating pair
     *      0 = paused (for both maxMintableCap and maxSupplyCap)
     * @param s Reference to AppStorage
     * @param pairId Unique identifier for the pair
     * @param newMaxMintableCap New maximum mintable cap (0 = pause minting)
     * @param newMaxSupplyCap New maximum supply cap (0 = pause collateral deposits)
     */
    function updatePairCaps(AppStorage storage s, bytes32 pairId, uint256 newMaxMintableCap, uint256 newMaxSupplyCap)
        external
    {
        if (s._pairConfigs[pairId].createdAt == 0) revert LendingPairModule__PairNotFound();

        s._pairConfigs[pairId].maxMintableCap = newMaxMintableCap;
        s._pairConfigs[pairId].maxSupplyCap = newMaxSupplyCap;

        emit PairCapsUpdated(pairId, newMaxMintableCap, newMaxSupplyCap);
    }

    /**
     * @notice Updates liquidation penalty for a lending pair
     * @dev Only callable by risk admin via YoloHook
     * @param s Reference to AppStorage
     * @param pairId Unique identifier for the pair
     * @param newLiquidationPenalty New liquidation penalty in basis points
     */
    function updateLiquidationPenalty(AppStorage storage s, bytes32 pairId, uint256 newLiquidationPenalty) external {
        if (s._pairConfigs[pairId].createdAt == 0) revert LendingPairModule__PairNotFound();

        s._pairConfigs[pairId].liquidationPenalty = newLiquidationPenalty;

        emit LiquidationPenaltyUpdated(pairId, newLiquidationPenalty);
    }

    /**
     * @notice Updates expiry settings for a lending pair
     * @dev Only callable by assets admin via YoloHook
     * @param s Reference to AppStorage
     * @param pairId Unique identifier for the pair
     * @param isExpirable Whether positions should expire
     * @param expirePeriod Expiry period in seconds (ignored if isExpirable = false)
     */
    function updatePairExpiry(AppStorage storage s, bytes32 pairId, bool isExpirable, uint256 expirePeriod) external {
        if (s._pairConfigs[pairId].createdAt == 0) revert LendingPairModule__PairNotFound();

        s._pairConfigs[pairId].isExpirable = isExpirable;
        s._pairConfigs[pairId].expirePeriod = expirePeriod;

        emit PairExpiryUpdated(pairId, isExpirable, expirePeriod);
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

    // ============================================================
    // CDP OPERATIONS
    // ============================================================

    /**
     * @notice Borrow synthetic assets against collateral
     * @dev Exact pattern from reference implementation with compound interest support
     * @param s Reference to AppStorage
     * @param yoloAsset Synthetic asset to borrow
     * @param borrowAmount Amount to borrow (18 decimals)
     * @param collateral Collateral asset
     * @param collateralAmount Amount of collateral to deposit (can be 0 for existing positions)
     */
    function borrowSyntheticAsset(
        AppStorage storage s,
        address yoloAsset,
        uint256 borrowAmount,
        address collateral,
        uint256 collateralAmount
    ) external {
        // Early validation
        if (borrowAmount == 0) revert LendingPairModule__InsufficientAmount();
        if (!s._isYoloAsset[yoloAsset]) revert LendingPairModule__NotYoloAsset();
        if (!s._isWhitelistedCollateral[collateral]) revert LendingPairModule__CollateralNotWhitelisted();

        bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
        DataTypes.PairConfiguration storage pairConfig = s._pairConfigs[pairId];
        if (pairConfig.collateralAsset == address(0)) revert LendingPairModule__InvalidPair();

        // Per-pair minimum check (0 = no minimum)
        if (pairConfig.minimumBorrowAmount > 0 && borrowAmount < pairConfig.minimumBorrowAmount) {
            revert LendingPairModule__InsufficientAmount();
        }

        if (pairConfig.maxMintableCap == 0) revert LendingPairModule__YoloAssetPaused();
        if (pairConfig.maxSupplyCap == 0) revert LendingPairModule__CollateralPaused();

        // Transfer collateral first if provided
        if (collateralAmount > 0) {
            IERC20(collateral).safeTransferFrom(msg.sender, address(this), collateralAmount);
        }

        // Update global liquidity index
        _updateGlobalLiquidityIndex(s, pairConfig, pairConfig.borrowRate);

        DataTypes.UserPosition storage position = s.positions[msg.sender][collateral][yoloAsset];

        if (position.borrower == address(0)) {
            // NEW POSITION
            _initializeNewPosition(s, position, msg.sender, collateral, yoloAsset, pairConfig.borrowRate);

            position.userLiquidityIndexRay = pairConfig.liquidityIndexRay;
            position.normalizedPrincipalRay = (borrowAmount * RAY) / pairConfig.liquidityIndexRay;
            position.normalizedDebtRay = position.normalizedPrincipalRay;

            if (pairConfig.isExpirable) {
                position.expiryTimestamp = block.timestamp + pairConfig.expirePeriod;
            }
        } else {
            // EXISTING POSITION - exact reference pattern
            // Debt: normalizedDebt is 18 decimals, multiply by index (27) and divide by RAY (27) = 18 decimals
            uint256 currentDebt = InterestRateMath.divUp(position.normalizedDebtRay * pairConfig.liquidityIndexRay, RAY);

            // Principal: uses helper function with correct index tracking
            uint256 currentPrincipal = InterestRateMath.calculateCurrentPrincipal(
                position.normalizedPrincipalRay, position.userLiquidityIndexRay, pairConfig.liquidityIndexRay
            );

            // Add new borrow to both principal and debt
            uint256 newPrincipal = currentPrincipal + borrowAmount;
            uint256 newDebt = currentDebt + borrowAmount;

            // Re-normalize: (18 decimals * 27) / 27 = 18 decimals stored
            position.normalizedPrincipalRay = (newPrincipal * RAY) / pairConfig.liquidityIndexRay;
            position.normalizedDebtRay = (newDebt * RAY) / pairConfig.liquidityIndexRay;
            position.userLiquidityIndexRay = pairConfig.liquidityIndexRay; // Update user's index
            position.lastUpdatedTimeStamp = block.timestamp;
        }

        // Update collateral
        position.collateralSuppliedAmount += collateralAmount;

        // Final checks
        if (!_isSolvent(s, position, collateral, yoloAsset, pairConfig.ltv)) {
            revert LendingPairModule__NotSolvent();
        }
        if (IYoloSyntheticAsset(yoloAsset).totalSupply() + borrowAmount > pairConfig.maxMintableCap) {
            revert LendingPairModule__ExceedsYoloAssetMintCap();
        }
        if (IERC20(collateral).balanceOf(address(this)) > pairConfig.maxSupplyCap) {
            revert LendingPairModule__ExceedsCollateralCap();
        }

        // Mint
        IYoloSyntheticAsset(yoloAsset).mint(msg.sender, borrowAmount);
        emit Borrowed(msg.sender, collateral, collateralAmount, yoloAsset, borrowAmount);
    }

    /**
     * @notice Repay borrowed synthetic assets
     * @dev Exact pattern from reference implementation with interest-first payment
     * @param s Reference to AppStorage
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset to repay
     * @param repayAmount Amount to repay (0 = full repayment)
     * @param claimCollateral Whether to claim collateral if fully repaid
     */
    function repaySyntheticAsset(
        AppStorage storage s,
        address collateral,
        address yoloAsset,
        uint256 repayAmount,
        bool claimCollateral
    ) external {
        DataTypes.UserPosition storage position = s.positions[msg.sender][collateral][yoloAsset];
        if (position.borrower != msg.sender) revert LendingPairModule__InvalidPosition();

        bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
        DataTypes.PairConfiguration storage pairConfig = s._pairConfigs[pairId];

        // Calculate effective index WITHOUT writing
        uint256 timeDelta = block.timestamp - pairConfig.lastUpdateTimestamp;
        uint256 effectiveIndexRay = InterestRateMath.calculateEffectiveIndex(
            pairConfig.liquidityIndexRay, position.storedInterestRate, timeDelta
        );

        // Calculate actual debt
        uint256 actualDebt = InterestRateMath.divUp(position.normalizedDebtRay * effectiveIndexRay, RAY);
        if (actualDebt == 0) revert LendingPairModule__NoDebt();

        uint256 actualRepayAmount = repayAmount == 0 ? actualDebt : repayAmount;
        if (actualRepayAmount > actualDebt) revert LendingPairModule__RepayExceedsDebt();

        // NOW update global index
        if (timeDelta > 0) {
            pairConfig.liquidityIndexRay = effectiveIndexRay;
            pairConfig.lastUpdateTimestamp = block.timestamp;
        }

        // Process repayment
        (uint256 interestPaid, uint256 principalPaid) =
            _processRepayment(s, position, pairConfig, yoloAsset, actualRepayAmount, actualDebt);

        // Handle full repayment if applicable
        if (position.normalizedDebtRay == 0 && claimCollateral) {
            uint256 collateralToReturn = position.collateralSuppliedAmount;
            position.collateralSuppliedAmount = 0;
            IERC20(collateral).safeTransfer(msg.sender, collateralToReturn);
        }

        emit Repaid(msg.sender, collateral, yoloAsset, actualRepayAmount, interestPaid, principalPaid);
    }

    /**
     * @notice Renew position with new interest rate
     * @dev Exact pattern from reference - requires interest payment to treasury
     * @param s Reference to AppStorage
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     */
    function renewPosition(AppStorage storage s, address collateral, address yoloAsset) external {
        DataTypes.UserPosition storage position = s.positions[msg.sender][collateral][yoloAsset];
        if (position.borrower != msg.sender) revert LendingPairModule__InvalidPosition();

        bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
        DataTypes.PairConfiguration storage pairConfig = s._pairConfigs[pairId];

        // renewPosition only works on expirable pairs
        if (!pairConfig.isExpirable) revert LendingPairModule__InvalidPosition();
        if (position.expiryTimestamp == 0) revert LendingPairModule__InvalidPosition();

        // Calculate effective index
        uint256 timeDelta = block.timestamp - pairConfig.lastUpdateTimestamp;
        uint256 effectiveIndexRay = InterestRateMath.calculateEffectiveIndex(
            pairConfig.liquidityIndexRay, position.storedInterestRate, timeDelta
        );

        // Calculate interest owed
        uint256 actualDebt = InterestRateMath.divUp(position.normalizedDebtRay * effectiveIndexRay, RAY);
        uint256 currentPrincipal = InterestRateMath.calculateCurrentPrincipal(
            position.normalizedPrincipalRay, position.userLiquidityIndexRay, pairConfig.liquidityIndexRay
        );
        uint256 interestAccrued = actualDebt > currentPrincipal ? actualDebt - currentPrincipal : 0;

        // PAY interest to treasury
        if (interestAccrued > 0) {
            IYoloSyntheticAsset(yoloAsset).burn(msg.sender, interestAccrued);
            IYoloSyntheticAsset(yoloAsset).mint(s.treasury, interestAccrued);
        }

        // Update global index
        if (timeDelta > 0) {
            pairConfig.liquidityIndexRay = effectiveIndexRay;
            pairConfig.lastUpdateTimestamp = block.timestamp;
        }

        // Reset position to zero-interest state
        position.normalizedDebtRay = (currentPrincipal * RAY) / pairConfig.liquidityIndexRay;
        position.normalizedPrincipalRay = (currentPrincipal * RAY) / pairConfig.liquidityIndexRay;
        position.userLiquidityIndexRay = pairConfig.liquidityIndexRay;
        position.storedInterestRate = pairConfig.borrowRate;
        position.lastUpdatedTimeStamp = block.timestamp;

        // Extend expiry
        if (pairConfig.isExpirable) {
            position.expiryTimestamp = block.timestamp + pairConfig.expirePeriod;
        }

        emit PositionRenewed(msg.sender, collateral, yoloAsset, interestAccrued);
    }

    /**
     * @notice Deposit additional collateral to existing position
     * @param s Reference to AppStorage
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param amount Amount to deposit
     */
    function depositCollateral(AppStorage storage s, address collateral, address yoloAsset, uint256 amount) external {
        if (amount == 0) revert LendingPairModule__InsufficientAmount();

        DataTypes.UserPosition storage position = s.positions[msg.sender][collateral][yoloAsset];
        if (position.borrower != msg.sender) revert LendingPairModule__InvalidPosition();

        IERC20(collateral).safeTransferFrom(msg.sender, address(this), amount);
        position.collateralSuppliedAmount += amount;
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Initialize new position
     * @param s Reference to AppStorage
     * @param position Reference to position storage
     * @param borrower Borrower address
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param interestRate Interest rate in basis points
     */
    function _initializeNewPosition(
        AppStorage storage s,
        DataTypes.UserPosition storage position,
        address borrower,
        address collateral,
        address yoloAsset,
        uint256 interestRate
    ) internal {
        position.borrower = borrower;
        position.collateral = collateral;
        position.yoloAsset = yoloAsset;
        position.lastUpdatedTimeStamp = block.timestamp;
        position.storedInterestRate = interestRate;

        // Push to user's position keys
        DataTypes.UserPositionKey memory key = DataTypes.UserPositionKey({collateral: collateral, yoloAsset: yoloAsset});
        s.userPositionKeys[borrower].push(key);
    }

    /**
     * @notice Update global liquidity index with compound interest
     * @param s Reference to AppStorage
     * @param config Reference to pair configuration
     * @param rate Interest rate in basis points
     */
    function _updateGlobalLiquidityIndex(AppStorage storage s, DataTypes.PairConfiguration storage config, uint256 rate)
        internal
    {
        uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
        if (timeDelta == 0) return;

        config.liquidityIndexRay = InterestRateMath.calculateLinearInterest(config.liquidityIndexRay, rate, timeDelta);
        config.lastUpdateTimestamp = block.timestamp;
    }

    /**
     * @notice Process repayment with interest-first payment logic
     * @dev Exact pattern from reference implementation
     * @param s Reference to AppStorage
     * @param position Reference to user position
     * @param pairConfig Reference to pair configuration
     * @param yoloAsset Synthetic asset address
     * @param repayAmount Amount to repay
     * @param actualDebt Current actual debt
     * @return interestPaid Amount of interest paid
     * @return principalPaid Amount of principal paid
     */
    function _processRepayment(
        AppStorage storage s,
        DataTypes.UserPosition storage position,
        DataTypes.PairConfiguration storage pairConfig,
        address yoloAsset,
        uint256 repayAmount,
        uint256 actualDebt
    ) private returns (uint256 interestPaid, uint256 principalPaid) {
        // Calculate principal using LATEST global index with correct RAY division
        uint256 currentPrincipal = InterestRateMath.calculateCurrentPrincipal(
            position.normalizedPrincipalRay, position.userLiquidityIndexRay, pairConfig.liquidityIndexRay
        );
        uint256 interestAccrued = actualDebt - currentPrincipal;

        // Split payment using InterestRateMath
        (interestPaid, principalPaid) = InterestRateMath.splitRepayment(repayAmount, interestAccrued, currentPrincipal);

        uint256 totalRepaid = interestPaid + principalPaid;

        // Process payments
        if (interestPaid > 0) {
            IYoloSyntheticAsset(yoloAsset).burn(msg.sender, interestPaid);
            IYoloSyntheticAsset(yoloAsset).mint(s.treasury, interestPaid); // Interest to treasury
        }

        if (principalPaid > 0) {
            IYoloSyntheticAsset(yoloAsset).burn(msg.sender, principalPaid);
        }

        // Update normalized values
        uint256 newDebt = actualDebt - totalRepaid;
        uint256 newPrincipal = currentPrincipal - principalPaid;

        // Re-normalize with LATEST global index
        position.normalizedDebtRay = (newDebt * RAY) / pairConfig.liquidityIndexRay;
        position.normalizedPrincipalRay = (newPrincipal * RAY) / pairConfig.liquidityIndexRay;
        position.userLiquidityIndexRay = pairConfig.liquidityIndexRay;
        position.lastUpdatedTimeStamp = block.timestamp;
    }

    /**
     * @notice Check if position is solvent
     * @param s Reference to AppStorage
     * @param position Reference to user position
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param ltv Loan-to-value ratio in basis points
     * @return True if solvent
     */
    function _isSolvent(
        AppStorage storage s,
        DataTypes.UserPosition storage position,
        address collateral,
        address yoloAsset,
        uint256 ltv
    ) internal view returns (bool) {
        // Get oracle prices
        uint256 collateralPrice = s.yoloOracle.getAssetPrice(collateral);
        uint256 yoloAssetPrice = s.yoloOracle.getAssetPrice(yoloAsset);

        // Calculate collateral value
        uint256 collateralValueUSD =
            (position.collateralSuppliedAmount * collateralPrice) / 10 ** IERC20Metadata(collateral).decimals();

        // Calculate debt value with compound interest
        bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
        DataTypes.PairConfiguration storage config = s._pairConfigs[pairId];
        // Debt calculation: (18 decimals * 27) / 27 = 18 decimals
        uint256 actualDebt = InterestRateMath.divUp(position.normalizedDebtRay * config.liquidityIndexRay, RAY);
        uint256 debtValueUSD = (actualDebt * yoloAssetPrice) / 10 ** IERC20Metadata(yoloAsset).decimals();

        // Check LTV
        return (debtValueUSD * PRECISION_DIVISOR) <= (collateralValueUSD * ltv);
    }

    /**
     * @notice Get solvency ratio for a position
     * @param s Reference to AppStorage
     * @param user User address
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @return ratio Solvency ratio (collateral value / debt value) * PRECISION_DIVISOR
     */
    function getSolvencyRatio(AppStorage storage s, address user, address collateral, address yoloAsset)
        external
        view
        returns (uint256 ratio)
    {
        DataTypes.UserPosition storage position = s.positions[user][collateral][yoloAsset];
        if (position.borrower == address(0)) return type(uint256).max;

        bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
        DataTypes.PairConfiguration storage config = s._pairConfigs[pairId];

        // Calculate effective index for view
        uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
        uint256 effectiveIndexRay =
            InterestRateMath.calculateEffectiveIndex(config.liquidityIndexRay, position.storedInterestRate, timeDelta);

        // Get actual debt: (18 decimals * 27) / 27 = 18 decimals
        uint256 actualDebt = InterestRateMath.divUp(position.normalizedDebtRay * effectiveIndexRay, RAY);

        if (actualDebt == 0) return type(uint256).max;

        // Calculate ratio
        uint256 collateralPrice = s.yoloOracle.getAssetPrice(collateral);
        uint256 yoloAssetPrice = s.yoloOracle.getAssetPrice(yoloAsset);

        uint256 collateralValueUSD = (position.collateralSuppliedAmount * collateralPrice);
        uint256 debtValueUSD = (actualDebt * yoloAssetPrice);

        return (collateralValueUSD * PRECISION_DIVISOR) / debtValueUSD;
    }

    /**
     * @notice Get user account data across all positions
     * @dev Extracted from YoloHook for code size reduction
     *      Aggregates all collateral and debt values across different positions
     * @param s Reference to AppStorage
     * @param user User address
     * @return totalCollateralUSD Total collateral value (8 decimals)
     * @return totalDebtUSD Total debt value (8 decimals)
     * @return ltv Current LTV in basis points
     */
    function getUserAccountData(AppStorage storage s, address user)
        external
        view
        returns (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 ltv)
    {
        DataTypes.UserPositionKey[] storage positionKeys = s.userPositionKeys[user];

        for (uint256 i = 0; i < positionKeys.length; i++) {
            address collateral = positionKeys[i].collateral;
            address yoloAsset = positionKeys[i].yoloAsset;

            DataTypes.UserPosition storage position = s.positions[user][collateral][yoloAsset];
            if (position.collateralSuppliedAmount == 0) continue;

            // Get prices
            uint256 collateralPrice = s.yoloOracle.getAssetPrice(collateral);
            uint256 yoloAssetPrice = s.yoloOracle.getAssetPrice(yoloAsset);

            // Calculate collateral value
            uint256 collateralDecimals = IERC20Metadata(collateral).decimals();
            totalCollateralUSD += (position.collateralSuppliedAmount * collateralPrice) / (10 ** collateralDecimals);

            // Calculate debt value with accrued interest
            bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
            DataTypes.PairConfiguration storage config = s._pairConfigs[pairId];
            uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
            uint256 effectiveIndex =
                InterestRateMath.calculateEffectiveIndex(config.liquidityIndexRay, config.borrowRate, timeDelta);
            uint256 debt = InterestRateMath.calculateActualDebt(position.normalizedDebtRay, effectiveIndex);

            uint256 yoloAssetDecimals = IERC20Metadata(yoloAsset).decimals();
            totalDebtUSD += (debt * yoloAssetPrice) / (10 ** yoloAssetDecimals);
        }

        // Calculate LTV
        if (totalCollateralUSD > 0) {
            ltv = (totalDebtUSD * 10000) / totalCollateralUSD;
        }
    }
}
