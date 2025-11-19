// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {DataTypes} from "./DataTypes.sol";
import {AppStorage} from "../core/YoloHookStorage.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title TradeModule
 * @author alvin@yolo.wtf
 * @notice Handles leveraged trading storage mutations and invariant checks
 */
library TradeModule {
    uint256 private constant PRICE_SCALE = 1e8;
    uint32 private constant SECONDS_PER_DAY = 86_400;
    uint32 private constant BPS_DENOMINATOR = 10_000;

    // ============================================================
    // ERRORS
    // ============================================================

    error TradeModule__InvalidAsset();
    error TradeModule__InvalidAction();
    error TradeModule__InvalidIndex();
    error TradeModule__SnapshotMismatch();
    error TradeModule__TimestampNotIncreasing();
    error TradeModule__MarketClosed();
    error TradeModule__LeverageTooHigh();
    error TradeModule__InvalidDelta();
    error TradeModule__OpenInterestExceeded();
    error TradeModule__PerpDisabled();
    error TradeModule__UnauthorizedOperator();
    error TradeModule__PriceRequired();
    error TradeModule__DirectionMismatch();

    // ============================================================
    // EXTERNAL ENTRYPOINT
    // ============================================================

    /**
     * @notice Unified entrypoint for leveraged trade mutations
     * @param s AppStorage reference
     * @param update Sanitized update parameters
     * @param caller Msg.sender of the hook call (used for orchestrator pinning)
     * @return indexUsed Position index used for the mutation (after swap-and-pop)
     * @return collateralDelta Echoed collateral delta for events
     * @return syntheticDelta Echoed synthetic delta for events
     */
    function updateTradePosition(AppStorage storage s, DataTypes.TradeUpdate calldata update, address caller)
        external
        returns (uint256 indexUsed, int256 collateralDelta, int256 syntheticDelta)
    {
        if (update.user == address(0) || update.syntheticAsset == address(0)) {
            revert TradeModule__InvalidAsset();
        }
        if (!s._isYoloAsset[update.syntheticAsset]) {
            revert TradeModule__InvalidAsset();
        }
        if (update.settledAt == 0) {
            revert TradeModule__TimestampNotIncreasing();
        }

        DataTypes.PerpConfiguration memory perpConfig = s._assetConfigs[update.syntheticAsset].perpConfig;
        bool isOpenAction = update.action == DataTypes.TradeUpdateAction.OPEN;
        if (isOpenAction && !perpConfig.enabled) {
            revert TradeModule__PerpDisabled();
        }

        _enforceMarketState(perpConfig.marketState, update.action);

        DataTypes.TradePosition[] storage positions = s.tradePositions[update.user];
        DataTypes.TradeAssetState storage assetState = s.tradeAssetState[update.syntheticAsset];

        if (isOpenAction) {
            indexUsed = _openPosition(positions, assetState, perpConfig, update, caller);
        } else if (update.action == DataTypes.TradeUpdateAction.TOP_UP) {
            indexUsed = _topUpPosition(positions, perpConfig, update, caller);
        } else if (update.action == DataTypes.TradeUpdateAction.PARTIAL_CLOSE) {
            indexUsed = _partialClosePosition(positions, assetState, perpConfig, update, caller);
        } else if (
            update.action == DataTypes.TradeUpdateAction.CLOSE || update.action == DataTypes.TradeUpdateAction.LIQUIDATE
        ) {
            indexUsed = _closePosition(positions, assetState, perpConfig, update, caller);
        } else {
            revert TradeModule__InvalidAction();
        }

        return (indexUsed, update.collateralDelta, update.syntheticDelta);
    }

    // ============================================================
    // ACTION HANDLERS
    // ============================================================

    function _openPosition(
        DataTypes.TradePosition[] storage positions,
        DataTypes.TradeAssetState storage assetState,
        DataTypes.PerpConfiguration memory perpConfig,
        DataTypes.TradeUpdate calldata update,
        address caller
    ) private returns (uint256) {
        if (update.index != positions.length) {
            revert TradeModule__InvalidIndex();
        }
        uint256 collateralAdded = _requirePositiveDelta(update.collateralDelta);
        uint256 sizeAdded = _requirePositiveDelta(update.syntheticDelta);
        uint256 entryPrice = update.executionPriceX8;
        if (entryPrice == 0) revert TradeModule__PriceRequired();

        uint256 notionalUsd = _notionalUsd(sizeAdded, entryPrice);
        _adjustOpenInterest(assetState, perpConfig, update.direction, notionalUsd, true);

        uint32 leverageBps = _computeLeverage(collateralAdded, notionalUsd);
        _enforceSessionLeverage(perpConfig, leverageBps);

        DataTypes.TradePosition memory position = DataTypes.TradePosition({
            user: update.user,
            tradeOrchestrator: caller,
            syntheticAsset: update.syntheticAsset,
            direction: update.direction,
            leverageBps: leverageBps,
            collateralUsy: collateralAdded,
            syntheticAssetPositionSize: sizeAdded,
            entryPriceX8: entryPrice,
            openedAt: update.settledAt,
            lastSettledAt: update.settledAt
        });

        positions.push(position);
        return positions.length - 1;
    }

    function _topUpPosition(
        DataTypes.TradePosition[] storage positions,
        DataTypes.PerpConfiguration memory perpConfig,
        DataTypes.TradeUpdate calldata update,
        address caller
    ) private returns (uint256) {
        DataTypes.TradePosition storage position = _loadExistingPosition(positions, update, caller);

        uint256 collateralAdded = _requirePositiveDelta(update.collateralDelta);
        if (update.syntheticDelta != 0) {
            revert TradeModule__InvalidDelta();
        }
        position.collateralUsy += collateralAdded;

        uint32 leverageBps = _recomputeLeverage(position, update.executionPriceX8);
        if (leverageBps != 0) {
            _enforceSessionLeverage(perpConfig, leverageBps);
            position.leverageBps = leverageBps;
        }

        position.lastSettledAt = update.settledAt;
        return update.index;
    }

    function _partialClosePosition(
        DataTypes.TradePosition[] storage positions,
        DataTypes.TradeAssetState storage assetState,
        DataTypes.PerpConfiguration memory perpConfig,
        DataTypes.TradeUpdate calldata update,
        address caller
    ) private returns (uint256) {
        DataTypes.TradePosition storage position = _loadExistingPosition(positions, update, caller);
        if (update.syntheticDelta >= 0) {
            revert TradeModule__InvalidDelta();
        }
        uint256 sizeReduction = SignedMath.abs(update.syntheticDelta);
        if (sizeReduction == 0 || sizeReduction >= position.syntheticAssetPositionSize) {
            revert TradeModule__InvalidDelta();
        }

        if (update.collateralDelta > 0) {
            revert TradeModule__InvalidDelta();
        }
        uint256 collateralReduction = SignedMath.abs(update.collateralDelta);
        if (collateralReduction > position.collateralUsy) {
            revert TradeModule__InvalidDelta();
        }

        uint256 notionalToRemove = _notionalUsd(sizeReduction, position.entryPriceX8);
        _adjustOpenInterest(assetState, perpConfig, position.direction, notionalToRemove, false);

        position.syntheticAssetPositionSize -= sizeReduction;
        position.collateralUsy -= collateralReduction;

        uint32 leverageBps = _recomputeLeverage(position, update.executionPriceX8);
        if (leverageBps != 0) {
            _enforceSessionLeverage(perpConfig, leverageBps);
            position.leverageBps = leverageBps;
        }

        position.lastSettledAt = update.settledAt;
        return update.index;
    }

    function _closePosition(
        DataTypes.TradePosition[] storage positions,
        DataTypes.TradeAssetState storage assetState,
        DataTypes.PerpConfiguration memory perpConfig,
        DataTypes.TradeUpdate calldata update,
        address caller
    ) private returns (uint256) {
        DataTypes.TradePosition storage position = _loadExistingPosition(positions, update, caller);
        uint256 size = position.syntheticAssetPositionSize;
        if (size == 0) revert TradeModule__InvalidDelta();
        if (update.syntheticDelta != -SafeCast.toInt256(size)) {
            revert TradeModule__InvalidDelta();
        }
        uint256 collateral = position.collateralUsy;
        if (collateral == 0) revert TradeModule__InvalidDelta();
        if (update.collateralDelta > 0) revert TradeModule__InvalidDelta();
        uint256 collateralReduction = SignedMath.abs(update.collateralDelta);
        if (collateralReduction != collateral) {
            revert TradeModule__InvalidDelta();
        }

        uint256 notionalToRemove = _notionalUsd(size, position.entryPriceX8);
        _adjustOpenInterest(assetState, perpConfig, position.direction, notionalToRemove, false);

        uint256 closingIndex = update.index;
        uint256 lastIndex = positions.length - 1;
        if (closingIndex != lastIndex) {
            positions[closingIndex] = positions[lastIndex];
        }
        positions.pop();

        return closingIndex;
    }

    // ============================================================
    // HELPERS
    // ============================================================

    function _loadExistingPosition(
        DataTypes.TradePosition[] storage positions,
        DataTypes.TradeUpdate calldata update,
        address caller
    ) private view returns (DataTypes.TradePosition storage position) {
        if (update.index >= positions.length) {
            revert TradeModule__InvalidIndex();
        }

        position = positions[update.index];
        if (position.syntheticAsset != update.syntheticAsset || position.user != update.user) {
            revert TradeModule__InvalidAsset();
        }
        if (position.direction != update.direction) {
            revert TradeModule__DirectionMismatch();
        }
        if (update.settledAt <= position.lastSettledAt) {
            revert TradeModule__TimestampNotIncreasing();
        }
        if (
            position.tradeOrchestrator != address(0) && caller != position.tradeOrchestrator
                && update.action != DataTypes.TradeUpdateAction.LIQUIDATE
        ) {
            revert TradeModule__UnauthorizedOperator();
        }
        if (
            position.collateralUsy != update.expectedCollateralUsy
                || position.syntheticAssetPositionSize != update.expectedSyntheticSize
        ) {
            revert TradeModule__SnapshotMismatch();
        }
    }

    function _enforceMarketState(DataTypes.TradeMarketState marketState, DataTypes.TradeUpdateAction action)
        private
        pure
    {
        if (marketState == DataTypes.TradeMarketState.OFFLINE && action != DataTypes.TradeUpdateAction.LIQUIDATE) {
            revert TradeModule__MarketClosed();
        }
        if (marketState == DataTypes.TradeMarketState.CLOSE_ONLY && action == DataTypes.TradeUpdateAction.OPEN) {
            revert TradeModule__MarketClosed();
        }
    }

    function _enforceSessionLeverage(DataTypes.PerpConfiguration memory config, uint32 leverageBps) private view {
        if (leverageBps == 0) return;
        uint32 cap = _currentLeverageCap(config);
        if (cap != 0 && leverageBps > cap) {
            revert TradeModule__LeverageTooHigh();
        }
    }

    function _currentLeverageCap(DataTypes.PerpConfiguration memory config) private view returns (uint32) {
        if (config.maxLeverageBpsDay == 0 && config.maxLeverageBpsCarryOvernight == 0) {
            return 0;
        }

        bool inSession = _isTradeSessionActive(config);
        if (inSession) {
            return config.maxLeverageBpsDay != 0 ? config.maxLeverageBpsDay : config.maxLeverageBpsCarryOvernight;
        }
        return config.maxLeverageBpsCarryOvernight != 0 ? config.maxLeverageBpsCarryOvernight : config.maxLeverageBpsDay;
    }

    function _isTradeSessionActive(DataTypes.PerpConfiguration memory config) private view returns (bool) {
        if (config.tradeSessionStart == 0 && config.tradeSessionEnd == 0) {
            return true;
        }
        if (config.tradeSessionStart == config.tradeSessionEnd) {
            return true;
        }
        uint32 secondsToday = uint32(block.timestamp % SECONDS_PER_DAY);
        if (config.tradeSessionEnd > config.tradeSessionStart) {
            return secondsToday >= config.tradeSessionStart && secondsToday < config.tradeSessionEnd;
        }
        // Window wraps past midnight
        return secondsToday >= config.tradeSessionStart || secondsToday < config.tradeSessionEnd;
    }

    function _adjustOpenInterest(
        DataTypes.TradeAssetState storage state,
        DataTypes.PerpConfiguration memory config,
        DataTypes.TradeDirection direction,
        uint256 notionalUsd,
        bool increase
    ) private {
        if (notionalUsd == 0) return;

        uint256 newLong = state.totalLongOpenInterestUsd;
        uint256 newShort = state.totalShortOpenInterestUsd;

        if (direction == DataTypes.TradeDirection.LONG) {
            if (increase) {
                newLong += notionalUsd;
            } else {
                if (notionalUsd > newLong) revert TradeModule__OpenInterestExceeded();
                newLong -= notionalUsd;
            }
        } else {
            if (increase) {
                newShort += notionalUsd;
            } else {
                if (notionalUsd > newShort) revert TradeModule__OpenInterestExceeded();
                newShort -= notionalUsd;
            }
        }

        uint256 totalOI = newLong + newShort;
        if (config.maxOpenInterestUsd != 0 && totalOI > config.maxOpenInterestUsd) {
            revert TradeModule__OpenInterestExceeded();
        }
        if (config.maxLongOpenInterestUsd != 0 && newLong > config.maxLongOpenInterestUsd) {
            revert TradeModule__OpenInterestExceeded();
        }
        if (config.maxShortOpenInterestUsd != 0 && newShort > config.maxShortOpenInterestUsd) {
            revert TradeModule__OpenInterestExceeded();
        }

        state.totalLongOpenInterestUsd = newLong;
        state.totalShortOpenInterestUsd = newShort;
    }

    function _computeLeverage(uint256 collateralUsy, uint256 notionalUsd) private pure returns (uint32) {
        if (collateralUsy == 0) revert TradeModule__InvalidDelta();
        if (notionalUsd == 0) return 0;

        uint256 leverageTimesBps = (notionalUsd * BPS_DENOMINATOR) / collateralUsy;
        if (leverageTimesBps > type(uint32).max) {
            revert TradeModule__LeverageTooHigh();
        }
        return SafeCast.toUint32(leverageTimesBps);
    }

    function _recomputeLeverage(DataTypes.TradePosition storage position, uint256 priceX8)
        private
        view
        returns (uint32)
    {
        if (priceX8 == 0) revert TradeModule__PriceRequired();
        uint256 notional = _notionalUsd(position.syntheticAssetPositionSize, priceX8);
        if (position.collateralUsy == 0 || notional == 0) {
            return 0;
        }
        return _computeLeverage(position.collateralUsy, notional);
    }

    function _requirePositiveDelta(int256 delta) private pure returns (uint256) {
        if (delta <= 0) revert TradeModule__InvalidDelta();
        return SafeCast.toUint256(delta);
    }

    function _notionalUsd(uint256 amount, uint256 priceX8) private pure returns (uint256) {
        if (amount == 0 || priceX8 == 0) {
            return 0;
        }
        return Math.mulDiv(amount, priceX8, PRICE_SCALE);
    }
}
