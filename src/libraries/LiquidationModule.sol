// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DataTypes} from "./DataTypes.sol";
import {AppStorage} from "../core/YoloHookStorage.sol";
import {InterestRateMath} from "./InterestRateMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYoloSyntheticAsset} from "../interfaces/IYoloSyntheticAsset.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";

/**
 * @title LiquidationModule
 * @author alvin@yolo.wtf
 * @notice Library for handling liquidations in YOLO Protocol V1
 * @dev Externally linked library with flash liquidation support
 *      Follows exact pattern from reference implementation
 */
library LiquidationModule {
    using SafeERC20 for IERC20;

    // ============================================================
    // EVENTS
    // ============================================================

    /**
     * @notice Emitted when a position is liquidated
     */
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateral,
        address yoloAsset,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    /**
     * @notice Emitted when a flash liquidation occurs
     */
    event FlashLiquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed receiver,
        address collateral,
        address yoloAsset,
        uint256 debtRepaid,
        uint256 collateralSeized
    );

    // ============================================================
    // ERRORS
    // ============================================================

    error LiquidationModule__PositionIsSolvent();
    error LiquidationModule__InvalidPosition();
    error LiquidationModule__InsufficientRepayment();
    error LiquidationModule__InvalidLiquidator();
    error LiquidationModule__NotPrivilegedLiquidator();

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 internal constant RAY = 1e27;
    uint256 internal constant PRECISION_DIVISOR = 10000;

    // ============================================================
    // FLASH LIQUIDATION
    // ============================================================

    /**
     * @notice Flash liquidate an undercollateralized or expired position
     * @dev Exact pattern from reference implementation
     * @param s Reference to AppStorage
     * @param user User being liquidated
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param repayAmount Amount of debt to repay
     * @param receiver Address to receive collateral for flash liquidation
     * @param params Custom callback data
     */
    function flashLiquidate(
        AppStorage storage s,
        address user,
        address collateral,
        address yoloAsset,
        uint256 repayAmount,
        address receiver,
        bytes calldata params
    ) external {
        // Check privileged liquidator restriction
        if (s.onlyPrivilegedLiquidator) {
            if (!IACLManager(s.ACL_MANAGER).hasRole(keccak256("PRIVILEGED_LIQUIDATOR"), msg.sender)) {
                revert LiquidationModule__NotPrivilegedLiquidator();
            }
        }

        // Get position and config
        DataTypes.UserPosition storage position = s.positions[user][collateral][yoloAsset];
        bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
        DataTypes.PairConfiguration storage config = s._pairConfigs[pairId];

        // Validate liquidation conditions - CRITICAL: use pair's current borrowRate, not user's stored rate
        _updateGlobalLiquidityIndex(s, config, config.borrowRate);

        bool isExpired =
            config.isExpirable && position.expiryTimestamp > 0 && block.timestamp >= position.expiryTimestamp;

        if (!isExpired && _isSolvent(s, position, collateral, yoloAsset, config.ltv)) {
            revert LiquidationModule__PositionIsSolvent();
        }

        // Calculate seizure amount
        uint256 collateralToSeize =
            _calculateCollateralSeizure(s, collateral, yoloAsset, repayAmount, config.liquidationPenalty);

        // Record initial balance
        uint256 initialBalance = IYoloSyntheticAsset(yoloAsset).balanceOf(address(this));

        // Transfer collateral to receiver for flash liquidation
        IERC20(collateral).safeTransfer(receiver, collateralToSeize);

        // Execute callback
        IFlashLiquidationReceiver(receiver)
            .executeFlashLiquidation(collateral, collateralToSeize, yoloAsset, repayAmount, params);

        // Verify repayment
        uint256 finalBalance = IYoloSyntheticAsset(yoloAsset).balanceOf(address(this));
        if (finalBalance < initialBalance + repayAmount) revert LiquidationModule__InsufficientRepayment();

        // Process liquidation
        _executeLiquidation(s, position, config, collateral, yoloAsset, repayAmount, user, isExpired);

        emit FlashLiquidated(msg.sender, user, receiver, collateral, yoloAsset, repayAmount, collateralToSeize);
    }

    /**
     * @notice Standard liquidation (non-flash)
     * @dev Liquidator must have synthetic assets to repay
     * @param s Reference to AppStorage
     * @param user User being liquidated
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param repayAmount Amount of debt to repay
     */
    function liquidate(AppStorage storage s, address user, address collateral, address yoloAsset, uint256 repayAmount)
        external
    {
        // Check privileged liquidator restriction
        if (s.onlyPrivilegedLiquidator) {
            if (!IACLManager(s.ACL_MANAGER).hasRole(keccak256("PRIVILEGED_LIQUIDATOR"), msg.sender)) {
                revert LiquidationModule__NotPrivilegedLiquidator();
            }
        }

        // Get position and config
        DataTypes.UserPosition storage position = s.positions[user][collateral][yoloAsset];
        bytes32 pairId = keccak256(abi.encodePacked(yoloAsset, collateral));
        DataTypes.PairConfiguration storage config = s._pairConfigs[pairId];

        // Validate liquidation conditions - CRITICAL: use pair's current borrowRate, not user's stored rate
        _updateGlobalLiquidityIndex(s, config, config.borrowRate);

        bool isExpired =
            config.isExpirable && position.expiryTimestamp > 0 && block.timestamp >= position.expiryTimestamp;

        if (!isExpired && _isSolvent(s, position, collateral, yoloAsset, config.ltv)) {
            revert LiquidationModule__PositionIsSolvent();
        }

        // Calculate seizure amount
        uint256 collateralToSeize =
            _calculateCollateralSeizure(s, collateral, yoloAsset, repayAmount, config.liquidationPenalty);

        // Burn repayment from liquidator
        IYoloSyntheticAsset(yoloAsset).burn(msg.sender, repayAmount);

        // Process liquidation
        _executeLiquidation(s, position, config, collateral, yoloAsset, repayAmount, user, isExpired);

        // Transfer seized collateral to liquidator
        IERC20(collateral).safeTransfer(msg.sender, collateralToSeize);

        emit Liquidated(msg.sender, user, collateral, yoloAsset, repayAmount, collateralToSeize);
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Calculate collateral to seize for liquidation
     * @param s Reference to AppStorage
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param repayAmount Amount being repaid
     * @param liquidationPenalty Penalty in basis points
     * @return Collateral amount to seize
     */
    function _calculateCollateralSeizure(
        AppStorage storage s,
        address collateral,
        address yoloAsset,
        uint256 repayAmount,
        uint256 liquidationPenalty
    ) internal view returns (uint256) {
        // Get oracle prices
        uint256 collateralPrice = s.yoloOracle.getAssetPrice(collateral);
        uint256 yoloAssetPrice = s.yoloOracle.getAssetPrice(yoloAsset);

        // Calculate value of debt being repaid
        uint256 repayValueUSD = (repayAmount * yoloAssetPrice) / 10 ** IERC20Metadata(yoloAsset).decimals();

        // Add liquidation penalty
        uint256 totalValueUSD = (repayValueUSD * (PRECISION_DIVISOR + liquidationPenalty)) / PRECISION_DIVISOR;

        // Convert to collateral amount
        return (totalValueUSD * 10 ** IERC20Metadata(collateral).decimals()) / collateralPrice;
    }

    /**
     * @notice Execute liquidation logic
     * @param s Reference to AppStorage
     * @param position Reference to user position
     * @param config Reference to pair configuration
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param repayAmount Amount being repaid
     * @param user User being liquidated
     * @param isExpired Whether position is expired
     */
    function _executeLiquidation(
        AppStorage storage s,
        DataTypes.UserPosition storage position,
        DataTypes.PairConfiguration storage config,
        address collateral,
        address yoloAsset,
        uint256 repayAmount,
        address user,
        bool isExpired
    ) internal {
        // Calculate current debt: (18 decimals * 27) / 27 = 18 decimals
        uint256 actualDebt = InterestRateMath.divUp(position.normalizedDebtRay * config.liquidityIndexRay, RAY);

        // Calculate principal with correct RAY division
        uint256 currentPrincipal = InterestRateMath.calculateCurrentPrincipal(
            position.normalizedPrincipalRay, position.userLiquidityIndexRay, config.liquidityIndexRay
        );
        uint256 interestAccrued = actualDebt - currentPrincipal;

        // Split payment: interest first, then principal
        (uint256 interestPaid, uint256 principalPaid) =
            InterestRateMath.splitRepayment(repayAmount, interestAccrued, currentPrincipal);

        // Process interest payment to treasury
        if (interestPaid > 0) {
            IYoloSyntheticAsset(yoloAsset).mint(s.treasury, interestPaid);
        }

        // Update position
        uint256 newDebt = actualDebt - (interestPaid + principalPaid);
        uint256 newPrincipal = currentPrincipal - principalPaid;

        position.normalizedDebtRay = (newDebt * RAY) / config.liquidityIndexRay;
        position.normalizedPrincipalRay = (newPrincipal * RAY) / config.liquidityIndexRay;
        position.userLiquidityIndexRay = config.liquidityIndexRay;
        position.lastUpdatedTimeStamp = block.timestamp;

        // Update collateral
        uint256 collateralSeized =
            _calculateCollateralSeizure(s, collateral, yoloAsset, repayAmount, config.liquidationPenalty);
        position.collateralSuppliedAmount -= collateralSeized;
    }

    /**
     * @notice Update global liquidity index
     * @param s Reference to AppStorage
     * @param config Reference to pair configuration
     * @param rate Interest rate in basis points
     */
    function _updateGlobalLiquidityIndex(
        AppStorage storage s,
        DataTypes.PairConfiguration storage config,
        uint256 rate
    ) internal {
        uint256 timeDelta = block.timestamp - config.lastUpdateTimestamp;
        if (timeDelta == 0) return;

        config.liquidityIndexRay = InterestRateMath.calculateLinearInterest(config.liquidityIndexRay, rate, timeDelta);
        config.lastUpdateTimestamp = block.timestamp;
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
}

/**
 * @title IFlashLiquidationReceiver
 * @notice Interface for flash liquidation callback
 */
interface IFlashLiquidationReceiver {
    /**
     * @notice Called by LiquidationModule during flash liquidation
     * @param collateral Collateral asset received
     * @param collateralAmount Amount of collateral received
     * @param debtAsset Debt asset to repay
     * @param debtAmount Amount of debt to repay
     * @param params Custom callback data
     */
    function executeFlashLiquidation(
        address collateral,
        uint256 collateralAmount,
        address debtAsset,
        uint256 debtAmount,
        bytes calldata params
    ) external;
}
