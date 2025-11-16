// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

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
     * @param oracleSource Price feed source for the synthetic asset (registered with YoloOracle)
     * @param maxSupply Maximum supply cap (0 = unlimited)
     * @param maxFlashLoanAmount Maximum amount that can be flash loaned (0 = unlimited)
     * @param isActive Whether the asset is active for trading
     * @param createdAt Timestamp when asset was created
     * @param perpConfig Optional leveraged-trading configuration (default disabled)
     */
    struct AssetConfiguration {
        address syntheticToken;
        address oracleSource;
        uint256 maxSupply;
        uint256 maxFlashLoanAmount;
        bool isActive;
        uint256 createdAt;
        PerpConfiguration perpConfig;
    }

    // ============================================================
    // LENDING PAIR CONFIGURATION
    // ============================================================

    /**
     * @notice Configuration for lending pairs (collateral-synthetic relationships)
     * @dev Structure supports compound interest via liquidity index pattern
     * @param syntheticAsset The synthetic asset being borrowed (e.g., yETH)
     * @param collateralAsset The collateral asset (e.g., USDC, WETH)
     * @param depositToken Optional receipt token for deposits (can be address(0))
     * @param debtToken Optional debt tracking token (can be address(0))
     * @param ltv Loan-to-Value ratio (in basis points, e.g., 8000 = 80%)
     * @param liquidationThreshold Liquidation threshold (in basis points, e.g., 8500 = 85%)
     * @param liquidationBonus Liquidation bonus (in basis points, e.g., 500 = 5%)
     * @param liquidationPenalty Liquidation penalty for seized collateral (in basis points)
     * @param borrowRate Annual borrow rate (in basis points, e.g., 300 = 3%)
     * @param liquidityIndexRay Global liquidity index for compound interest (RAY precision - 27 decimals)
     * @param lastUpdateTimestamp Last time the liquidity index was updated
     * @param maxMintableCap Maximum mintable cap for the synthetic asset
     * @param maxSupplyCap Maximum supply cap for the collateral asset
     * @param minimumBorrowAmount Minimum borrow amount per transaction (in synthetic asset decimals, 0 = no minimum)
     * @param isExpirable Whether positions expire
     * @param expirePeriod Expiry period in seconds
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
        uint256 liquidationPenalty;
        uint256 borrowRate;
        uint256 liquidityIndexRay;
        uint256 lastUpdateTimestamp;
        uint256 maxMintableCap;
        uint256 maxSupplyCap;
        uint256 minimumBorrowAmount;
        bool isExpirable;
        uint256 expirePeriod;
        bool isActive;
        uint256 createdAt;
    }

    // ============================================================
    // USER POSITION
    // ============================================================

    /**
     * @notice Key structure for enumerating user positions
     * @param collateral Collateral asset address
     * @param yoloAsset Synthetic asset address
     */
    struct UserPositionKey {
        address collateral;
        address yoloAsset;
    }

    /**
     * @notice User position data for a specific lending pair
     * @dev Tracks both principal and total debt separately for accurate interest calculations
     * @param borrower Address of the borrower
     * @param collateral Collateral asset address
     * @param yoloAsset Synthetic asset address
     * @param collateralSuppliedAmount Amount of collateral deposited (native decimals)
     * @param normalizedPrincipalRay Principal normalized by user's entry index (stored as 18 decimal value, computed using RAY precision)
     * @param normalizedDebtRay Total debt (principal + interest) normalized by user's entry index (stored as 18 decimal value, computed using RAY precision)
     * @param userLiquidityIndexRay User's entry liquidity index (RAY precision)
     * @param storedInterestRate Interest rate at position creation/renewal (basis points)
     * @param lastUpdatedTimeStamp Last time position was updated
     * @param expiryTimestamp Position expiry timestamp (0 if non-expirable)
     */
    struct UserPosition {
        address borrower;
        address collateral;
        address yoloAsset;
        uint256 collateralSuppliedAmount;
        uint256 normalizedPrincipalRay;
        uint256 normalizedDebtRay;
        uint256 userLiquidityIndexRay;
        uint256 storedInterestRate;
        uint256 lastUpdatedTimeStamp;
        uint256 expiryTimestamp;
    }

    // ============================================================
    // POOL CONFIGURATION
    // ============================================================

    /**
     * @notice Configuration for Uniswap V4 pools (both anchor and synthetic)
     * @param poolKey The full Uniswap V4 pool key (contains currencies, fee, tickSpacing, hooks)
     * @param isAnchorPool True for USY-USDC anchor pool (Curve StableSwap)
     * @param isSyntheticPool True for USY-yAsset synthetic pools (oracle-based)
     * @param token0 Address of token0 (for convenience)
     * @param token1 Address of token1 (for convenience)
     * @param createdAt Timestamp when pool was created
     */
    struct PoolConfiguration {
        PoolKey poolKey;
        bool isAnchorPool;
        bool isSyntheticPool;
        address token0;
        address token1;
        uint256 createdAt;
    }

    // ============================================================
    // UNLOCK CALLBACK DATA
    // ============================================================

    /**
     * @notice Enum for unlock callback action types
     * @dev Extensible for future operations (swaps, flash loans, etc.)
     */
    enum UnlockAction {
        ADD_LIQUIDITY, // 0: Add liquidity to anchor pool
        REMOVE_LIQUIDITY, // 1: Remove liquidity from anchor pool
        SWAP, // 2: Synthetic swap follow-up actions (pending burn)
        FLASH_LOAN // 3: Flash loan operations (reserved)
    }

    /**
     * @notice Generic callback data structure for PoolManager unlock callbacks
     * @param action Action type enum
     * @param data Encoded action-specific data
     */
    struct CallbackData {
        UnlockAction action;
        bytes data;
    }

    /**
     * @notice Data for add liquidity unlock callback
     * @param sender Address initiating the add (msg.sender)
     * @param receiver Address to receive sUSY tokens
     * @param maxUsyIn Maximum USY to deposit (18 decimals)
     * @param maxUsdcIn Maximum USDC to deposit (native decimals)
     * @param minSUSY Minimum sUSY to receive (slippage protection)
     */
    struct AddLiquidityData {
        address sender;
        address receiver;
        uint256 maxUsyIn;
        uint256 maxUsdcIn;
        uint256 minSUSY;
    }

    /**
     * @notice Data for remove liquidity unlock callback
     * @param sender Address initiating the removal (msg.sender, sUSY holder)
     * @param receiver Address to receive USY + USDC
     * @param sUSYAmount Amount of sUSY to burn (18 decimals)
     * @param minUsyOut Minimum USY to receive (18 decimals)
     * @param minUsdcOut Minimum USDC to receive (native decimals)
     */
    struct RemoveLiquidityData {
        address sender;
        address receiver;
        uint256 sUSYAmount;
        uint256 minUsyOut;
        uint256 minUsdcOut;
    }

    // ============================================================
    // LEVERAGED TRADING
    // ============================================================

    /**
     * @notice Direction enum for leveraged trades
     */
    enum TradeDirection {
        LONG,
        SHORT
    }

    /**
     * @notice Market state enum for leveraged trading
     */
    enum TradeMarketState {
        OPEN,
        CLOSE_ONLY,
        OFFLINE
    }

    /**
     * @notice Action enum for the unified trade update entrypoint
     */
    enum TradeUpdateAction {
        OPEN,
        CLOSE,
        PARTIAL_CLOSE,
        TOP_UP,
        LIQUIDATE
    }

    /**
     * @notice Minimal state tracked on-chain for leveraged trades
     * @dev Full funding/borrow math lives in TradeOrchestrator modules
     * @param user Address that owns the position
     * @param direction LONG or SHORT
     * @param leverageBps Leverage multiplier in basis points (5_000 = 5x)
     * @param collateralUsy Collateral currently locked in USY
     * @param syntheticAssetPositionSize Current size of the synthetic asset exposure (in asset decimals)
     * @param entryPriceX8 Entry price stored with 8 decimals
     * @param openedAt Timestamp when trade was opened
     * @param lastSettledAt Timestamp of the last orchestrator settlement (partial close, rebalance, etc.)
     */
    struct TradePosition {
        address user;
        address tradeOrchestrator;
        address syntheticAsset;
        TradeDirection direction;
        uint32 leverageBps;
        uint256 collateralUsy;
        uint256 syntheticAssetPositionSize;
        uint256 entryPriceX8;
        uint64 openedAt;
        uint64 lastSettledAt;
    }

    /**
     * @notice Aggregated per-asset trading state
     * @param totalLongOpenInterestUsd Sum of long notional exposure
     * @param totalShortOpenInterestUsd Sum of short notional exposure
     */
    struct TradeAssetState {
        uint256 totalLongOpenInterestUsd;
        uint256 totalShortOpenInterestUsd;
    }

    /**
     * @notice Per-asset configuration for leveraged trading
     * @param enabled Whether perp-style trading is enabled for this synthetic
     * @param maxOpenInterestUsd Total OI cap (USD notional)
     * @param maxLongOpenInterestUsd Directional long cap
     * @param maxShortOpenInterestUsd Directional short cap
     * @param maxLeverageBpsDay Max leverage during day session (basis points)
     * @param maxLeverageBpsNight Max leverage during night session (basis points)
     * @param daySessionStart UTC seconds since midnight when day leverage applies
     * @param daySessionEnd UTC seconds since midnight when day leverage ends
     * @param marketState Circuit breaker enum (open / close-only / offline)
     */
    struct PerpConfiguration {
        bool enabled;
        uint256 maxOpenInterestUsd;
        uint256 maxLongOpenInterestUsd;
        uint256 maxShortOpenInterestUsd;
        uint32 maxLeverageBpsDay;
        uint32 maxLeverageBpsNight;
        uint32 daySessionStart;
        uint32 daySessionEnd;
        TradeMarketState marketState;
    }

    /**
     * @notice Input struct for updateTradePosition entrypoint
     * @param user Position owner
     * @param syntheticAsset Traded asset
     * @param action Requested action enum
     * @param direction Expected direction (LONG/SHORT)
     * @param leverageBps Requested leverage (only checked for open/top-up)
     * @param index Position index in the user's array
     * @param expectedCollateralUsy Optimistic collateral snapshot
     * @param expectedSyntheticSize Optimistic synthetic exposure snapshot
     * @param collateralDelta Signed delta applied to collateral
     * @param syntheticDelta Signed delta applied to synthetic size
     * @param executionPriceX8 Oracle price used for this action
     * @param settledAt Timestamp asserted by orchestrator
     */
    struct TradeUpdate {
        address user;
        address syntheticAsset;
        TradeUpdateAction action;
        TradeDirection direction;
        uint32 leverageBps;
        uint256 index;
        uint256 expectedCollateralUsy;
        uint256 expectedSyntheticSize;
        int256 collateralDelta;
        int256 syntheticDelta;
        uint256 executionPriceX8;
        uint64 settledAt;
    }
}
