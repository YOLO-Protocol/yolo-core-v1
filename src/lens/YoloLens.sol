// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IYoloHook} from "../interfaces/IYoloHook.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {InterestRateMath} from "../libraries/InterestRateMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title YoloLens
 * @author alvin@yolo.wtf
 * @notice View aggregator contract for YOLO Protocol frontend data queries
 * @dev Provides gas-efficient batch queries and position enumeration
 *      - All heavy iteration logic lives here (not in YoloHook)
 *      - Returns aggregated data in single calls to minimize RPC requests
 *      - Similar to Compound Lens or Aave Data Provider pattern
 *      - Read-only contract, no state modifications
 */
contract YoloLens {
    // ============================================================
    // STRUCTS FOR AGGREGATED DATA
    // ============================================================

    /// @notice Protocol-wide statistics
    struct ProtocolStats {
        uint256 totalSyntheticAssets; // Total number of synthetic assets
        uint256 totalCollateralTypes; // Total number of whitelisted collaterals
        uint256 totalLendingPairs; // Total active lending pairs
        uint256 totalAnchorLiquidityUSY; // Total USY in anchor pool
        uint256 totalAnchorLiquidityUSDC; // Total USDC in anchor pool (18 decimals normalized)
        uint256 anchorAmplification; // Anchor pool amplification coefficient
        uint256 anchorSwapFeeBps; // Anchor swap fee in basis points
        uint256 syntheticSwapFeeBps; // Synthetic swap fee in basis points
        uint256 flashLoanFeeBps; // Flash loan fee in basis points
        bool isPaused; // Protocol pause state
    }

    /// @notice Synthetic asset information
    struct AssetInfo {
        address assetAddress; // Synthetic asset address
        string name; // Asset name (e.g., "YOLO NVIDIA")
        string symbol; // Asset symbol (e.g., "yNVDA")
        uint8 decimals; // Token decimals
        address oracleSource; // Oracle source address
        uint256 currentPrice; // Current oracle price (18 decimals)
        uint256 totalSupply; // Current total supply
        uint256 maxSupply; // Maximum supply cap (0 = unlimited)
        uint256 maxFlashLoanAmount; // Max flash loan amount
        bool isActive; // Whether asset is active
        uint256 createdAt; // Creation timestamp
        uint256 numActivePairs; // Number of active lending pairs
    }

    /// @notice Collateral asset information
    struct CollateralInfo {
        address collateralAddress; // Collateral asset address
        string name; // Collateral name
        string symbol; // Collateral symbol
        uint8 decimals; // Token decimals
        uint256 numActivePairs; // Number of active lending pairs using this collateral
    }

    /// @notice Lending pair detailed information
    struct PairInfo {
        bytes32 pairId; // keccak256(syntheticAsset, collateralAsset)
        address syntheticAsset; // Synthetic asset address
        address collateralAsset; // Collateral asset address
        string syntheticSymbol; // Synthetic symbol (e.g., "yNVDA")
        string collateralSymbol; // Collateral symbol (e.g., "USDC")
        uint256 ltv; // Loan-to-value (basis points)
        uint256 liquidationThreshold; // Liquidation threshold (basis points)
        uint256 liquidationBonus; // Liquidation bonus (basis points)
        uint256 liquidationPenalty; // Liquidation penalty (basis points)
        uint256 borrowRate; // Borrow rate (basis points)
        uint256 liquidityIndexRay; // Current liquidity index (RAY precision)
        uint256 minimumBorrowAmount; // Minimum borrow amount
        bool isExpirable; // Whether positions expire
        uint256 expirePeriod; // Expiry period in seconds
        bool isActive; // Whether pair is active
        uint256 createdAt; // Creation timestamp
        uint256 currentPrice; // Current synthetic asset price (18 decimals)
    }

    /// @notice User position with computed values
    struct PositionInfo {
        address user; // Position owner
        bytes32 pairId; // Lending pair identifier
        address syntheticAsset; // Borrowed synthetic asset
        address collateralAsset; // Deposited collateral
        string syntheticSymbol; // Synthetic symbol
        string collateralSymbol; // Collateral symbol
        uint256 collateralAmount; // Deposited collateral (native decimals)
        uint256 collateralValue; // Collateral value in USD (18 decimals)
        uint256 borrowedAmount; // Principal borrowed (18 decimals)
        uint256 totalDebt; // Total debt including interest (18 decimals)
        uint256 debtValue; // Debt value in USD (18 decimals)
        uint256 healthFactor; // Health factor (18 decimals, <1e18 = liquidatable)
        uint256 availableToBorrow; // Additional borrow capacity (18 decimals)
        uint256 interestRate; // Position interest rate (basis points)
        uint256 expiryTimestamp; // Position expiry (0 if non-expirable)
        bool isExpired; // Whether position is expired
        bool isLiquidatable; // Whether position can be liquidated
    }

    /// @notice User portfolio summary
    struct UserPortfolio {
        address user; // User address
        uint256 numPositions; // Total number of positions
        uint256 totalCollateralValue; // Total collateral value (18 decimals)
        uint256 totalDebtValue; // Total debt value (18 decimals)
        uint256 averageHealthFactor; // Weighted average health factor
        uint256 numLiquidatablePositions; // Number of liquidatable positions
        PositionInfo[] positions; // All user positions
    }

    // ============================================================
    // ERRORS
    // ============================================================

    error YoloLens__PositionNotFound();
    error YoloLens__MustProvideUserList();

    // ============================================================
    // IMMUTABLE STATE
    // ============================================================

    /// @notice YoloHook contract address
    IYoloHook public immutable YOLO_HOOK;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize YoloLens with YoloHook address
     * @param _yoloHook Address of the YoloHook contract
     */
    constructor(address _yoloHook) {
        YOLO_HOOK = IYoloHook(_yoloHook);
    }

    // ============================================================
    // PROTOCOL-LEVEL QUERIES
    // ============================================================

    /**
     * @notice Get protocol-wide statistics
     * @return stats Protocol statistics struct
     */
    function getProtocolStats() external view returns (ProtocolStats memory stats) {
        stats.totalSyntheticAssets = YOLO_HOOK.getAllSyntheticAssets().length;
        stats.totalCollateralTypes = YOLO_HOOK.getAllWhitelistedCollaterals().length;

        // Count total active lending pairs
        address[] memory synthetics = YOLO_HOOK.getAllSyntheticAssets();
        for (uint256 i = 0; i < synthetics.length; i++) {
            address[] memory collaterals = YOLO_HOOK.getSyntheticCollaterals(synthetics[i]);
            stats.totalLendingPairs += collaterals.length;
        }

        // Get anchor pool liquidity (normalized to 18 decimals)
        (stats.totalAnchorLiquidityUSY, stats.totalAnchorLiquidityUSDC) = YOLO_HOOK.getAnchorReservesNormalized18();

        stats.anchorAmplification = YOLO_HOOK.getAnchorAmplification();
        stats.anchorSwapFeeBps = YOLO_HOOK.getAnchorSwapFeeBps();
        stats.syntheticSwapFeeBps = YOLO_HOOK.getSyntheticSwapFeeBps();
        stats.flashLoanFeeBps = YOLO_HOOK.getFlashLoanFeeBps();
        stats.isPaused = YOLO_HOOK.paused();
    }

    /**
     * @notice Get all synthetic assets with detailed information
     * @return assets Array of asset information structs
     */
    function getAllSyntheticAssets() external view returns (AssetInfo[] memory assets) {
        address[] memory assetAddresses = YOLO_HOOK.getAllSyntheticAssets();
        assets = new AssetInfo[](assetAddresses.length);

        IYoloOracle oracle = YOLO_HOOK.yoloOracle();

        for (uint256 i = 0; i < assetAddresses.length; i++) {
            address asset = assetAddresses[i];
            DataTypes.AssetConfiguration memory config = YOLO_HOOK.getAssetConfiguration(asset);

            IERC20Metadata token = IERC20Metadata(asset);

            assets[i] = AssetInfo({
                assetAddress: asset,
                name: token.name(),
                symbol: token.symbol(),
                decimals: token.decimals(),
                oracleSource: config.oracleSource,
                currentPrice: oracle.getAssetPrice(asset) * 1e10, // Scale 8 decimals to 18
                totalSupply: token.totalSupply(),
                maxSupply: config.maxSupply,
                maxFlashLoanAmount: config.maxFlashLoanAmount,
                isActive: config.isActive,
                createdAt: config.createdAt,
                numActivePairs: YOLO_HOOK.getSyntheticCollaterals(asset).length
            });
        }
    }

    /**
     * @notice Get all whitelisted collaterals with information
     * @return collaterals Array of collateral information structs
     */
    function getAllCollaterals() external view returns (CollateralInfo[] memory collaterals) {
        address[] memory collateralAddresses = YOLO_HOOK.getAllWhitelistedCollaterals();
        collaterals = new CollateralInfo[](collateralAddresses.length);

        for (uint256 i = 0; i < collateralAddresses.length; i++) {
            address collateral = collateralAddresses[i];
            IERC20Metadata token = IERC20Metadata(collateral);

            collaterals[i] = CollateralInfo({
                collateralAddress: collateral,
                name: token.name(),
                symbol: token.symbol(),
                decimals: token.decimals(),
                numActivePairs: YOLO_HOOK.getCollateralSynthetics(collateral).length
            });
        }
    }

    /**
     * @notice Get all lending pairs with detailed information
     * @return pairs Array of pair information structs
     */
    function getAllLendingPairs() external view returns (PairInfo[] memory pairs) {
        // Count total pairs first
        address[] memory synthetics = YOLO_HOOK.getAllSyntheticAssets();
        uint256 totalPairs = 0;
        for (uint256 i = 0; i < synthetics.length; i++) {
            totalPairs += YOLO_HOOK.getSyntheticCollaterals(synthetics[i]).length;
        }

        pairs = new PairInfo[](totalPairs);
        uint256 index = 0;

        IYoloOracle oracle = YOLO_HOOK.yoloOracle();

        for (uint256 i = 0; i < synthetics.length; i++) {
            address synthetic = synthetics[i];
            address[] memory collaterals = YOLO_HOOK.getSyntheticCollaterals(synthetic);

            for (uint256 j = 0; j < collaterals.length; j++) {
                address collateral = collaterals[j];
                bytes32 pairId = keccak256(abi.encodePacked(synthetic, collateral));

                DataTypes.PairConfiguration memory config = YOLO_HOOK.getPairConfiguration(synthetic, collateral);

                pairs[index] = PairInfo({
                    pairId: pairId,
                    syntheticAsset: synthetic,
                    collateralAsset: collateral,
                    syntheticSymbol: IERC20Metadata(synthetic).symbol(),
                    collateralSymbol: IERC20Metadata(collateral).symbol(),
                    ltv: config.ltv,
                    liquidationThreshold: config.liquidationThreshold,
                    liquidationBonus: config.liquidationBonus,
                    liquidationPenalty: config.liquidationPenalty,
                    borrowRate: config.borrowRate,
                    liquidityIndexRay: config.liquidityIndexRay,
                    minimumBorrowAmount: config.minimumBorrowAmount,
                    isExpirable: config.isExpirable,
                    expirePeriod: config.expirePeriod,
                    isActive: config.isActive,
                    createdAt: config.createdAt,
                    currentPrice: oracle.getAssetPrice(synthetic) * 1e10 // Scale 8 decimals to 18
                });

                index++;
            }
        }
    }

    // ============================================================
    // USER-SPECIFIC QUERIES
    // ============================================================

    /**
     * @notice Get all positions for a specific user
     * @param user Address of the user
     * @return positions Array of position information structs
     */
    function getUserPositions(address user) public view returns (PositionInfo[] memory positions) {
        DataTypes.UserPositionKey[] memory keys = YOLO_HOOK.getUserPositionKeys(user);
        positions = new PositionInfo[](keys.length);

        for (uint256 i = 0; i < keys.length; i++) {
            positions[i] = _buildPositionInfo(user, keys[i]);
        }
    }

    /**
     * @notice Internal helper to build position information for a single position
     * @dev Extracted to avoid stack too deep errors
     * @param user Address of the user
     * @param key Position key (synthetic + collateral pair)
     * @return Position information struct
     */
    function _buildPositionInfo(address user, DataTypes.UserPositionKey memory key)
        internal
        view
        returns (PositionInfo memory)
    {
        bytes32 pairId = keccak256(abi.encodePacked(key.yoloAsset, key.collateral));
        IYoloOracle oracle = YOLO_HOOK.yoloOracle();

        DataTypes.UserPosition memory position = YOLO_HOOK.getUserPosition(user, key.collateral, key.yoloAsset);
        DataTypes.PairConfiguration memory pairConfig = YOLO_HOOK.getPairConfiguration(key.yoloAsset, key.collateral);

        // Get current prices (oracle returns 8 decimals)
        uint256 syntheticPriceX8 = oracle.getAssetPrice(key.yoloAsset);
        uint256 collateralPriceX8 = oracle.getAssetPrice(key.collateral);

        // Scale prices to 18 decimals (multiply by 1e10)
        uint256 syntheticPrice18 = syntheticPriceX8 * 1e10;
        uint256 collateralPrice18 = collateralPriceX8 * 1e10;

        // Calculate actual debt (principal + interest)
        uint256 totalDebt = YOLO_HOOK.getPositionDebt(user, key.collateral, key.yoloAsset);

        // Calculate borrowed amount (current principal with accrued interest)
        uint256 borrowedAmount = InterestRateMath.calculateCurrentPrincipal(
            position.normalizedPrincipalRay, position.userLiquidityIndexRay, pairConfig.liquidityIndexRay
        );

        // Calculate collateral value in USD (18 decimals)
        // First normalize collateral amount to 18 decimals, then multiply by price
        uint256 collateralAmount18 =
            (position.collateralSuppliedAmount * 1e18) / (10 ** IERC20Metadata(key.collateral).decimals());
        uint256 collateralValueUSD = (collateralAmount18 * collateralPrice18) / 1e18;

        // Calculate debt value in USD (18 decimals)
        uint256 debtValueUSD = (totalDebt * syntheticPrice18) / 1e18;

        // Calculate health factor
        uint256 healthFactor = 0;
        if (debtValueUSD > 0) {
            uint256 maxBorrowValueUSD = (collateralValueUSD * pairConfig.liquidationThreshold) / 10000;
            healthFactor = (maxBorrowValueUSD * 1e18) / debtValueUSD;
        }

        // Calculate available to borrow (in synthetic asset units)
        uint256 availableToBorrow = 0;
        if (healthFactor > 1e18) {
            uint256 maxValueUSD = (collateralValueUSD * pairConfig.ltv) / 10000;
            if (maxValueUSD > debtValueUSD) {
                uint256 availableValueUSD = maxValueUSD - debtValueUSD;
                // Convert USD value to synthetic asset amount
                availableToBorrow = (availableValueUSD * 1e18) / syntheticPrice18;
            }
        }

        // Check if expired
        bool isExpired = pairConfig.isExpirable && block.timestamp > position.expiryTimestamp;

        // Check if liquidatable
        bool isLiquidatable = isExpired || (healthFactor > 0 && healthFactor < 1e18);

        return PositionInfo({
            user: user,
            pairId: pairId,
            syntheticAsset: key.yoloAsset,
            collateralAsset: key.collateral,
            syntheticSymbol: IERC20Metadata(key.yoloAsset).symbol(),
            collateralSymbol: IERC20Metadata(key.collateral).symbol(),
            collateralAmount: position.collateralSuppliedAmount,
            collateralValue: collateralValueUSD,
            borrowedAmount: borrowedAmount,
            totalDebt: totalDebt,
            debtValue: debtValueUSD,
            healthFactor: healthFactor,
            availableToBorrow: availableToBorrow,
            interestRate: position.storedInterestRate,
            expiryTimestamp: position.expiryTimestamp,
            isExpired: isExpired,
            isLiquidatable: isLiquidatable
        });
    }

    /**
     * @notice Get complete user portfolio with aggregated statistics
     * @param user Address of the user
     * @return portfolio User portfolio struct with all positions and summary
     */
    function getUserPortfolio(address user) external view returns (UserPortfolio memory portfolio) {
        PositionInfo[] memory positions = getUserPositions(user);

        portfolio.user = user;
        portfolio.numPositions = positions.length;
        portfolio.positions = positions;

        uint256 totalWeightedHealth = 0;
        uint256 totalDebtForWeighting = 0;

        for (uint256 i = 0; i < positions.length; i++) {
            portfolio.totalCollateralValue += positions[i].collateralValue;
            portfolio.totalDebtValue += positions[i].debtValue;

            if (positions[i].isLiquidatable) {
                portfolio.numLiquidatablePositions++;
            }

            // Calculate weighted average health factor
            if (positions[i].debtValue > 0 && positions[i].healthFactor > 0) {
                totalWeightedHealth += positions[i].healthFactor * positions[i].debtValue;
                totalDebtForWeighting += positions[i].debtValue;
            }
        }

        if (totalDebtForWeighting > 0) {
            portfolio.averageHealthFactor = totalWeightedHealth / totalDebtForWeighting;
        }
    }

    /**
     * @notice Get all liquidatable positions across the protocol
     * @dev WARNING: Gas-intensive function, should be called off-chain
     * @param users Array of user addresses to check (pass empty array to check all known users)
     * @return liquidatablePositions Array of liquidatable position information
     */
    function getLiquidatablePositions(address[] memory users)
        external
        view
        returns (PositionInfo[] memory liquidatablePositions)
    {
        // If no users provided, we'd need a way to enumerate all users
        // For now, require callers to provide user list
        if (users.length == 0) revert YoloLens__MustProvideUserList();

        // First pass: count liquidatable positions
        uint256 count = 0;
        for (uint256 i = 0; i < users.length; i++) {
            PositionInfo[] memory positions = getUserPositions(users[i]);
            for (uint256 j = 0; j < positions.length; j++) {
                if (positions[j].isLiquidatable) {
                    count++;
                }
            }
        }

        // Second pass: collect liquidatable positions
        liquidatablePositions = new PositionInfo[](count);
        uint256 index = 0;

        for (uint256 i = 0; i < users.length; i++) {
            PositionInfo[] memory positions = getUserPositions(users[i]);
            for (uint256 j = 0; j < positions.length; j++) {
                if (positions[j].isLiquidatable) {
                    liquidatablePositions[index] = positions[j];
                    index++;
                }
            }
        }
    }

    /**
     * @notice Get specific position information
     * @param user Address of the user
     * @param syntheticAsset Address of the synthetic asset
     * @param collateralAsset Address of the collateral asset
     * @return position Position information struct
     */
    function getPosition(address user, address syntheticAsset, address collateralAsset)
        external
        view
        returns (PositionInfo memory position)
    {
        PositionInfo[] memory positions = getUserPositions(user);

        for (uint256 i = 0; i < positions.length; i++) {
            if (positions[i].syntheticAsset == syntheticAsset && positions[i].collateralAsset == collateralAsset) {
                return positions[i];
            }
        }

        revert YoloLens__PositionNotFound();
    }
}
