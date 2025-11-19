// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {IYoloHook} from "../interfaces/IYoloHook.sol";
import {IYLPVault} from "../interfaces/IYLPVault.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "../interfaces/IYoloSyntheticAsset.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

/**
 * @title TradeOrchestrator
 * @author alvin@yolo.wtf
 * @notice User-executed leveraged trading periphery that validates price payloads,
 *         collects fees, and mutates YoloHook leveraged state via a single entrypoint.
 * @dev UUPS-upgradeable periphery: constructor hardwires core dependencies (proxy safe),
 *      owns per-asset risk configuration, tracks virtual exposure, and translates
 *      user actions into YoloHook trade upserts plus YLP settlement transfers.
 */
contract TradeOrchestrator is ReentrancyGuard, UUPSUpgradeable {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant PRICE_DECIMALS = 1e8;
    uint256 private constant FUNDING_SCALE = 1e18;
    uint256 private constant FUNDING_RATE_SCALE = 1e8; // 1e-8 precision per hour
    int256 private constant MAX_PRICE_EXPO = 38;
    uint256 private constant SECONDS_PER_YEAR = 365 days;
    uint256 private constant SECONDS_PER_HOUR = 1 hours;

    bytes32 public constant TRADE_KEEPER_ROLE = keccak256("TRADE_KEEPER_ROLE");
    bytes32 public constant TRADE_ADMIN_ROLE = keccak256("TRADE_ADMIN_ROLE");
    bytes32 private constant DEFAULT_ADMIN_ROLE = 0x00;

    // ============================================================
    // ERRORS
    // ============================================================

    error TradeOrchestrator__CallerNotAuthorized();
    error TradeOrchestrator__InvalidAddress();
    error TradeOrchestrator__InactiveAsset();
    error TradeOrchestrator__DeadlineExpired();
    error TradeOrchestrator__InvalidAmount();
    error TradeOrchestrator__InvalidPrice();
    error TradeOrchestrator__MaxDeviationExceeded();
    error TradeOrchestrator__LeverageTooHigh();
    error TradeOrchestrator__TradeSessionActive();
    error TradeOrchestrator__CarryCapUnavailable();
    error TradeOrchestrator__PositionNotFound();
    error TradeOrchestrator__NotLiquidatable();
    error TradeOrchestrator__InsufficientUpdateFee();
    error TradeOrchestrator__MarketClosed();
    error TradeOrchestrator__InsufficientCollateral();
    error TradeOrchestrator__CollateralTooSmall();
    error TradeOrchestrator__TreasuryNotSet();
    error TradeOrchestrator__InvalidFee();

    // ============================================================
    // STRUCTS
    // ============================================================

    struct TradeAssetConfig {
        bytes32 pythPriceId;
        uint32 maxPriceAgeSec;
        uint16 maxDeviationBps;
        uint16 longSpreadBps;
        uint16 shortSpreadBps;
        uint32 fundingFactorPerHour;
        uint16 fixedBorrowBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationRewardBps;
        uint16 openFeeBps;
        uint16 closeFeeBps;
        uint16 overnightUnwindFeeBps;
        uint256 minCollateralUsy;
        bool feesEnabled;
        bool isActive;
    }

    struct AssetState {
        int256 fundingAccumulator;
        uint64 lastFundingAccrual;
        uint256 longOpenInterestUsd;
        uint256 shortOpenInterestUsd;
    }

    struct PositionAccounting {
        int256 entryFundingIndex;
        uint64 lastPricePublishTime;
        uint64 lastBorrowTimestamp;
        uint16 borrowRateBps;
        uint256 pendingBorrowUsy;
        int256 pendingFundingUsy;
        uint256 entryPriceIndex;
    }

    struct PositionScalingContext {
        uint256 previousIndex;
        uint256 currentIndex;
        uint256 scaledSize;
        uint256 scaledEntryPriceX8;
    }

    struct OpenPositionParams {
        address syntheticAsset;
        DataTypes.TradeDirection direction;
        uint256 collateralUsy;
        uint256 syntheticSize;
        uint32 leverageBps;
        uint64 deadline;
    }

    struct AdjustCollateralParams {
        address syntheticAsset;
        uint256 index;
        uint256 collateralDelta;
        uint64 deadline;
    }

    struct ClosePositionParams {
        address syntheticAsset;
        uint256 index;
        uint256 syntheticSize;
        uint64 deadline;
    }

    struct LiquidationParams {
        address user;
        address syntheticAsset;
        uint256 index;
        uint64 deadline;
    }

    struct PriceInfo {
        uint256 priceX8;
        uint64 publishTime;
    }

    struct CloseExecutionParams {
        address trader;
        address caller;
        address syntheticAsset;
        uint256 index;
        uint256 sizeToClose;
        PriceInfo priceInfo;
        TradeAssetConfig config;
        bool liquidation;
        address rewardReceiver;
        uint16 unwindFeeBps;
        address unwindFeeRecipient;
    }

    // ============================================================
    // STATE
    // ============================================================

    IACLManager public immutable aclManager;
    IYoloHook public immutable yoloHook;
    IYLPVault public immutable ylpVault;
    IPyth public immutable pyth;
    IERC20 public immutable usy;

    mapping(address => TradeAssetConfig) public tradeAssetConfigs;
    mapping(address => AssetState) public assetStates;
    mapping(address => mapping(uint256 => PositionAccounting)) public positionAccounting;

    // ============================================================
    // EVENTS
    // ============================================================

    event TradeAssetConfigured(
        address indexed syntheticAsset,
        bytes32 pythPriceId,
        uint32 maxPriceAgeSec,
        uint16 maxDeviationBps,
        uint16 longSpreadBps,
        uint16 shortSpreadBps,
        uint32 fundingFactorPerHour,
        uint16 fixedBorrowBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationRewardBps,
        uint16 openFeeBps,
        uint16 closeFeeBps,
        uint16 overnightUnwindFeeBps,
        uint256 minCollateralUsy,
        bool feesEnabled,
        bool isActive
    );
    event TradeOpened(
        address indexed user,
        address indexed syntheticAsset,
        uint256 index,
        uint256 notionalUsd,
        uint256 collateralUsy,
        uint256 priceX8,
        uint32 leverageBps
    );
    event TradeAdjusted(address indexed user, address indexed syntheticAsset, uint256 index, uint256 collateralDelta);
    event TradeClosed(
        address indexed user,
        address indexed syntheticAsset,
        uint256 index,
        uint256 syntheticClosed,
        int256 pnlUsy,
        uint256 collateralReleased
    );
    event TradeLiquidated(
        address indexed user, address indexed syntheticAsset, uint256 index, address liquidator, int256 pnlUsy
    );
    event OvernightUnwound(
        address indexed user,
        address indexed syntheticAsset,
        uint256 index,
        uint256 sizeReduced,
        uint256 unwindFeePaid,
        address keeper
    );
    event FundingApplied(address indexed syntheticAsset, int256 fundingAccumulator, uint64 lastAccrued);
    event AutoDeleveraged(address indexed user, address indexed syntheticAsset, uint256 index, uint256 reducedSize);
    event ShortfallRealized(address indexed user, address indexed syntheticAsset, uint256 shortfallUsy);

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyTradeKeeper() {
        if (!aclManager.hasRole(TRADE_KEEPER_ROLE, msg.sender)) {
            revert TradeOrchestrator__CallerNotAuthorized();
        }
        _;
    }

    modifier onlyTradeAdmin() {
        if (!aclManager.hasRole(TRADE_ADMIN_ROLE, msg.sender) && !aclManager.hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert TradeOrchestrator__CallerNotAuthorized();
        }
        _;
    }

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor(IACLManager aclManager_, IYoloHook yoloHook_, IYLPVault ylpVault_, IPyth pyth_) {
        if (
            address(aclManager_) == address(0) || address(yoloHook_) == address(0) || address(ylpVault_) == address(0)
                || address(pyth_) == address(0)
        ) {
            revert TradeOrchestrator__InvalidAddress();
        }
        aclManager = aclManager_;
        yoloHook = yoloHook_;
        ylpVault = ylpVault_;
        pyth = pyth_;
        usy = IERC20(yoloHook_.usy());
        _disableInitializers();
    }

    // ============================================================
    // ADMIN CONFIG
    // ============================================================

    function configureTradeAsset(address syntheticAsset, TradeAssetConfig calldata config) external onlyTradeAdmin {
        if (!yoloHook.isYoloAsset(syntheticAsset)) revert TradeOrchestrator__InactiveAsset();
        if (config.openFeeBps > BPS_DENOMINATOR || config.closeFeeBps > BPS_DENOMINATOR) {
            revert TradeOrchestrator__InvalidFee();
        }
        if (config.fixedBorrowBps > BPS_DENOMINATOR) revert TradeOrchestrator__InvalidFee();
        if (config.fundingFactorPerHour > FUNDING_RATE_SCALE) revert TradeOrchestrator__InvalidFee();
        if (config.liquidationRewardBps > BPS_DENOMINATOR) revert TradeOrchestrator__InvalidFee();
        if (config.longSpreadBps > BPS_DENOMINATOR) revert TradeOrchestrator__InvalidFee();
        if (config.shortSpreadBps >= BPS_DENOMINATOR) revert TradeOrchestrator__InvalidFee();
        if (config.overnightUnwindFeeBps > BPS_DENOMINATOR) revert TradeOrchestrator__InvalidFee();
        tradeAssetConfigs[syntheticAsset] = config;

        AssetState storage state = assetStates[syntheticAsset];
        if (state.lastFundingAccrual == 0) {
            state.lastFundingAccrual = SafeCast.toUint64(block.timestamp);
        }

        emit TradeAssetConfigured(
            syntheticAsset,
            config.pythPriceId,
            config.maxPriceAgeSec,
            config.maxDeviationBps,
            config.longSpreadBps,
            config.shortSpreadBps,
            config.fundingFactorPerHour,
            config.fixedBorrowBps,
            config.liquidationThresholdBps,
            config.liquidationRewardBps,
            config.openFeeBps,
            config.closeFeeBps,
            config.overnightUnwindFeeBps,
            config.minCollateralUsy,
            config.feesEnabled,
            config.isActive
        );
    }

    // ============================================================
    // USER ACTIONS
    // ============================================================

    function openPosition(OpenPositionParams calldata params, bytes[] calldata priceUpdateData)
        external
        payable
        nonReentrant
    {
        _enforceDeadline(params.deadline);
        TradeAssetConfig memory config = _loadConfig(params.syntheticAsset);
        PriceInfo memory priceInfo;
        uint256 feePaid;
        (priceInfo, feePaid) = _consumePriceUpdate(config, priceUpdateData);
        _enforceDeviation(params.syntheticAsset, config.maxDeviationBps, priceInfo.priceX8);

        uint256 collateral = params.collateralUsy;
        uint256 size = params.syntheticSize;
        if (collateral == 0 || size == 0) revert TradeOrchestrator__InvalidAmount();

        AssetState storage state = assetStates[params.syntheticAsset];
        _applyFundingInternal(params.syntheticAsset, state, config);

        uint256 executionPrice =
            _applyDirectionalSpread(priceInfo.priceX8, config, params.direction == DataTypes.TradeDirection.LONG);
        priceInfo.priceX8 = executionPrice;
        uint256 notionalUsd = _notionalUsd(size, executionPrice);
        uint256 openFee = config.feesEnabled && config.openFeeBps != 0
            ? _mulDivUp(notionalUsd, config.openFeeBps, BPS_DENOMINATOR)
            : 0;
        if (collateral <= openFee) revert TradeOrchestrator__InsufficientCollateral();

        usy.safeTransferFrom(msg.sender, address(this), params.collateralUsy);
        if (openFee > 0) {
            usy.safeTransfer(_getTreasury(), openFee);
        }
        collateral -= openFee;
        if (config.minCollateralUsy != 0 && collateral < config.minCollateralUsy) {
            revert TradeOrchestrator__CollateralTooSmall();
        }

        uint32 leverageBps = params.leverageBps == 0 ? _computeLeverage(collateral, notionalUsd) : params.leverageBps;
        _enforceLeverage(params.syntheticAsset, leverageBps);

        _updateExposure(state, params.direction, notionalUsd, true);

        DataTypes.TradeUpdate memory update = DataTypes.TradeUpdate({
            user: msg.sender,
            syntheticAsset: params.syntheticAsset,
            action: DataTypes.TradeUpdateAction.OPEN,
            direction: params.direction,
            leverageBps: leverageBps,
            index: yoloHook.getUserTradeCount(msg.sender),
            expectedCollateralUsy: 0,
            expectedSyntheticSize: 0,
            collateralDelta: SafeCast.toInt256(collateral),
            syntheticDelta: SafeCast.toInt256(size),
            executionPriceX8: priceInfo.priceX8,
            settledAt: SafeCast.toUint64(block.timestamp)
        });

        (uint256 newIndex,,) = yoloHook.updateTradePosition(update);
        positionAccounting[msg.sender][newIndex] = PositionAccounting({
            entryFundingIndex: state.fundingAccumulator,
            lastPricePublishTime: priceInfo.publishTime,
            lastBorrowTimestamp: SafeCast.toUint64(block.timestamp),
            borrowRateBps: config.fixedBorrowBps,
            pendingBorrowUsy: 0,
            pendingFundingUsy: 0,
            entryPriceIndex: _getPriceIndex(params.syntheticAsset)
        });

        emit TradeOpened(
            msg.sender, params.syntheticAsset, newIndex, notionalUsd, collateral, priceInfo.priceX8, leverageBps
        );
        _refundSurplus(feePaid);
    }

    function topUpCollateral(AdjustCollateralParams calldata params) external nonReentrant {
        _enforceDeadline(params.deadline);
        TradeAssetConfig memory config = _loadConfig(params.syntheticAsset);
        AssetState storage state = assetStates[params.syntheticAsset];
        _applyFundingInternal(params.syntheticAsset, state, config);

        uint256 tradeCount = yoloHook.getUserTradeCount(msg.sender);
        if (params.index >= tradeCount) revert TradeOrchestrator__PositionNotFound();
        DataTypes.TradePosition memory position = yoloHook.getUserTrade(msg.sender, params.index);
        uint256 baseSize = position.syntheticAssetPositionSize;
        if (position.syntheticAsset != params.syntheticAsset) revert TradeOrchestrator__PositionNotFound();
        PositionAccounting storage meta = positionAccounting[msg.sender][params.index];
        PositionScalingContext memory scaling = _applyCorporateActionScaling(params.syntheticAsset, position, meta);
        position.syntheticAssetPositionSize = scaling.scaledSize;
        position.entryPriceX8 = scaling.scaledEntryPriceX8;

        usy.safeTransferFrom(msg.sender, address(this), params.collateralDelta);

        DataTypes.TradeUpdate memory update = DataTypes.TradeUpdate({
            user: msg.sender,
            syntheticAsset: params.syntheticAsset,
            action: DataTypes.TradeUpdateAction.TOP_UP,
            direction: position.direction,
            leverageBps: position.leverageBps,
            index: params.index,
            expectedCollateralUsy: position.collateralUsy,
            expectedSyntheticSize: baseSize,
            collateralDelta: SafeCast.toInt256(params.collateralDelta),
            syntheticDelta: 0,
            executionPriceX8: position.entryPriceX8,
            settledAt: SafeCast.toUint64(block.timestamp)
        });

        (, int256 collateralDelta,) = yoloHook.updateTradePosition(update);
        meta.lastPricePublishTime = SafeCast.toUint64(block.timestamp);

        emit TradeAdjusted(msg.sender, params.syntheticAsset, params.index, SafeCast.toUint256(collateralDelta));
    }

    function closePosition(ClosePositionParams calldata params, bytes[] calldata priceUpdateData)
        external
        payable
        nonReentrant
    {
        _enforceDeadline(params.deadline);
        TradeAssetConfig memory config = _loadConfig(params.syntheticAsset);
        PriceInfo memory priceInfo;
        uint256 feePaid;
        (priceInfo, feePaid) = _consumePriceUpdate(config, priceUpdateData);
        _enforceDeviation(params.syntheticAsset, config.maxDeviationBps, priceInfo.priceX8);

        _executeClose(
            CloseExecutionParams({
                trader: msg.sender,
                caller: msg.sender,
                syntheticAsset: params.syntheticAsset,
                index: params.index,
                sizeToClose: params.syntheticSize,
                priceInfo: priceInfo,
                config: config,
                liquidation: false,
                rewardReceiver: address(0),
                unwindFeeBps: 0,
                unwindFeeRecipient: address(0)
            })
        );
        _refundSurplus(feePaid);
    }

    function liquidatePosition(LiquidationParams calldata params, bytes[] calldata priceUpdateData)
        external
        payable
        nonReentrant
        onlyTradeKeeper
    {
        _enforceDeadline(params.deadline);
        TradeAssetConfig memory config = _loadConfig(params.syntheticAsset);
        PriceInfo memory priceInfo;
        uint256 feePaid;
        (priceInfo, feePaid) = _consumePriceUpdate(config, priceUpdateData);
        _enforceDeviation(params.syntheticAsset, config.maxDeviationBps, priceInfo.priceX8);
        AssetState storage state = assetStates[params.syntheticAsset];
        _applyFundingInternal(params.syntheticAsset, state, config);
        _enforceLiquidatable(params, priceInfo, config, state);
        _executeClose(
            CloseExecutionParams({
                trader: params.user,
                caller: msg.sender,
                syntheticAsset: params.syntheticAsset,
                index: params.index,
                sizeToClose: 0,
                priceInfo: priceInfo,
                config: config,
                liquidation: true,
                rewardReceiver: msg.sender,
                unwindFeeBps: 0,
                unwindFeeRecipient: address(0)
            })
        );
        _refundSurplus(feePaid);
    }

    // ============================================================
    // KEEPER / ADMIN FUNCTIONS
    // ============================================================

    function applyFunding(address syntheticAsset) external onlyTradeKeeper {
        TradeAssetConfig memory config = _loadConfig(syntheticAsset);
        AssetState storage state = assetStates[syntheticAsset];
        _applyFundingInternal(syntheticAsset, state, config);
    }

    function adminAutoDeleverage(
        address user,
        address syntheticAsset,
        uint256 index,
        uint256 targetNotionalUsd,
        bytes[] calldata priceUpdateData
    ) external payable nonReentrant onlyTradeAdmin {
        TradeAssetConfig memory config = _loadConfig(syntheticAsset);
        PriceInfo memory priceInfo;
        uint256 feePaid;
        (priceInfo, feePaid) = _consumePriceUpdate(config, priceUpdateData);
        _enforceDeviation(syntheticAsset, config.maxDeviationBps, priceInfo.priceX8);

        uint256 tradeCount = yoloHook.getUserTradeCount(user);
        if (index >= tradeCount) revert TradeOrchestrator__PositionNotFound();
        DataTypes.TradePosition memory position = yoloHook.getUserTrade(user, index);
        PositionAccounting storage meta = positionAccounting[user][index];
        PositionScalingContext memory scaling = _applyCorporateActionScaling(syntheticAsset, position, meta);
        position.syntheticAssetPositionSize = scaling.scaledSize;
        position.entryPriceX8 = scaling.scaledEntryPriceX8;
        uint256 currentNotional = _notionalUsd(position.syntheticAssetPositionSize, priceInfo.priceX8);
        if (currentNotional <= targetNotionalUsd) {
            _refundSurplus(feePaid);
            return;
        }

        uint256 portion = currentNotional - targetNotionalUsd;
        uint256 sizeToClose = Math.min(
            position.syntheticAssetPositionSize, (position.syntheticAssetPositionSize * portion) / currentNotional
        );

        if (sizeToClose == 0) {
            _refundSurplus(feePaid);
            return;
        }

        _executeClose(
            CloseExecutionParams({
                trader: user,
                caller: msg.sender,
                syntheticAsset: syntheticAsset,
                index: index,
                sizeToClose: sizeToClose,
                priceInfo: priceInfo,
                config: config,
                liquidation: false,
                rewardReceiver: address(0),
                unwindFeeBps: 0,
                unwindFeeRecipient: address(0)
            })
        );
        emit AutoDeleveraged(user, syntheticAsset, index, sizeToClose);
        _refundSurplus(feePaid);
    }

    function enforceCarryLeverage(LiquidationParams calldata params, bytes[] calldata priceUpdateData)
        external
        payable
        nonReentrant
        onlyTradeKeeper
    {
        _enforceDeadline(params.deadline);
        DataTypes.AssetConfiguration memory assetCfg = yoloHook.getAssetConfiguration(params.syntheticAsset);
        if (_isTradeSessionActive(assetCfg.perpConfig)) {
            revert TradeOrchestrator__TradeSessionActive();
        }
        if (assetCfg.perpConfig.maxLeverageBpsCarryOvernight == 0) {
            revert TradeOrchestrator__CarryCapUnavailable();
        }

        TradeAssetConfig memory config = _loadConfig(params.syntheticAsset);
        PriceInfo memory priceInfo;
        uint256 feePaid;
        (priceInfo, feePaid) = _consumePriceUpdate(config, priceUpdateData);
        _enforceDeviation(params.syntheticAsset, config.maxDeviationBps, priceInfo.priceX8);

        AssetState storage state = assetStates[params.syntheticAsset];
        _applyFundingInternal(params.syntheticAsset, state, config);

        uint256 tradeCount = yoloHook.getUserTradeCount(params.user);
        if (params.index >= tradeCount) revert TradeOrchestrator__PositionNotFound();
        DataTypes.TradePosition memory position = yoloHook.getUserTrade(params.user, params.index);
        if (position.syntheticAsset != params.syntheticAsset) revert TradeOrchestrator__PositionNotFound();
        PositionAccounting storage meta = positionAccounting[params.user][params.index];
        PositionScalingContext memory scaling = _applyCorporateActionScaling(params.syntheticAsset, position, meta);
        position.syntheticAssetPositionSize = scaling.scaledSize;
        position.entryPriceX8 = scaling.scaledEntryPriceX8;

        if (position.syntheticAssetPositionSize == 0 || position.collateralUsy == 0) {
            _refundSurplus(feePaid);
            return;
        }

        uint256 notionalUsd = _notionalUsd(position.syntheticAssetPositionSize, priceInfo.priceX8);
        if (notionalUsd == 0) {
            _refundSurplus(feePaid);
            return;
        }

        uint256 borrowFee = _previewPendingBorrow(meta, notionalUsd);
        int256 fundingFee = _previewPendingFunding(meta, state, position, notionalUsd);
        int256 equity = SafeCast.toInt256(position.collateralUsy);
        equity += _unrealizedPnl(position, priceInfo.priceX8, position.syntheticAssetPositionSize);
        equity -= SafeCast.toInt256(borrowFee);
        equity -= fundingFee;
        if (equity <= 0) {
            _refundSurplus(feePaid);
            return;
        }

        uint256 equityUsd = SafeCast.toUint256(equity);
        uint256 carryCap = assetCfg.perpConfig.maxLeverageBpsCarryOvernight;
        uint256 allowedNotional = Math.mulDiv(equityUsd, carryCap, BPS_DENOMINATOR);
        if (allowedNotional >= notionalUsd) {
            _refundSurplus(feePaid);
            return;
        }

        uint256 reductionNotional = notionalUsd - allowedNotional;
        uint256 sizeToCloseScaled = _mulDivUp(reductionNotional, position.syntheticAssetPositionSize, notionalUsd);
        if (sizeToCloseScaled > position.syntheticAssetPositionSize) {
            sizeToCloseScaled = position.syntheticAssetPositionSize;
        }

        address unwindRecipient = address(0);
        if (config.overnightUnwindFeeBps != 0) {
            unwindRecipient = _getTreasury();
        }

        (uint256 closedSize, uint256 unwindFeePaid) = _executeClose(
            CloseExecutionParams({
                trader: params.user,
                caller: msg.sender,
                syntheticAsset: params.syntheticAsset,
                index: params.index,
                sizeToClose: sizeToCloseScaled,
                priceInfo: priceInfo,
                config: config,
                liquidation: false,
                rewardReceiver: address(0),
                unwindFeeBps: config.overnightUnwindFeeBps,
                unwindFeeRecipient: unwindRecipient
            })
        );

        emit OvernightUnwound(params.user, params.syntheticAsset, params.index, closedSize, unwindFeePaid, msg.sender);
        _refundSurplus(feePaid);
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    function _executeClose(CloseExecutionParams memory params)
        private
        returns (uint256 sizeToCloseScaled, uint256 unwindFeePaid)
    {
        uint256 tradeCount = yoloHook.getUserTradeCount(params.trader);
        if (params.index >= tradeCount) revert TradeOrchestrator__PositionNotFound();
        DataTypes.TradePosition memory position = yoloHook.getUserTrade(params.trader, params.index);
        if (position.syntheticAsset != params.syntheticAsset) revert TradeOrchestrator__PositionNotFound();

        AssetState storage state = assetStates[params.syntheticAsset];
        _applyFundingInternal(params.syntheticAsset, state, params.config);

        uint256 baseSize = position.syntheticAssetPositionSize;
        PositionAccounting storage meta = positionAccounting[params.trader][params.index];
        PositionScalingContext memory scaling = _applyCorporateActionScaling(params.syntheticAsset, position, meta);
        position.syntheticAssetPositionSize = scaling.scaledSize;
        position.entryPriceX8 = scaling.scaledEntryPriceX8;

        sizeToCloseScaled = params.sizeToClose == 0 ? position.syntheticAssetPositionSize : params.sizeToClose;
        if (sizeToCloseScaled == 0 || sizeToCloseScaled > position.syntheticAssetPositionSize) {
            revert TradeOrchestrator__InvalidAmount();
        }
        uint256 sizeToCloseBase;
        sizeToCloseBase = sizeToCloseScaled == position.syntheticAssetPositionSize
            ? baseSize
            : Math.min(_mulDivUp(sizeToCloseScaled, scaling.previousIndex, scaling.currentIndex), baseSize);
        if (sizeToCloseBase == 0) revert TradeOrchestrator__InvalidAmount();

        bool applyLongSpread = position.direction == DataTypes.TradeDirection.SHORT;
        uint256 executionPrice = _applyDirectionalSpread(params.priceInfo.priceX8, params.config, applyLongSpread);
        uint256 entryNotionalUsd = _notionalUsd(sizeToCloseScaled, position.entryPriceX8);
        uint256 collateralPortion = (position.collateralUsy * sizeToCloseScaled) / position.syntheticAssetPositionSize;

        (int256 pnlUsy, uint256 borrowFee, int256 fundingFee) =
            _computeSettlement(position, meta, state, sizeToCloseScaled, executionPrice);

        DataTypes.TradeUpdateAction action;
        if (sizeToCloseScaled == position.syntheticAssetPositionSize) {
            action = params.liquidation ? DataTypes.TradeUpdateAction.LIQUIDATE : DataTypes.TradeUpdateAction.CLOSE;
        } else {
            action = DataTypes.TradeUpdateAction.PARTIAL_CLOSE;
        }

        DataTypes.TradeUpdate memory update = DataTypes.TradeUpdate({
            user: params.trader,
            syntheticAsset: params.syntheticAsset,
            action: action,
            direction: position.direction,
            leverageBps: position.leverageBps,
            index: params.index,
            expectedCollateralUsy: position.collateralUsy,
            expectedSyntheticSize: baseSize,
            collateralDelta: -SafeCast.toInt256(collateralPortion),
            syntheticDelta: -SafeCast.toInt256(sizeToCloseBase),
            executionPriceX8: executionPrice,
            settledAt: SafeCast.toUint64(block.timestamp)
        });

        yoloHook.updateTradePosition(update);
        _postCloseBookkeeping(params.trader, params.index, tradeCount, action);
        _updateExposure(state, position.direction, entryNotionalUsd, false);

        int256 netPnl = pnlUsy - SafeCast.toInt256(borrowFee);
        netPnl -= fundingFee;

        if (netPnl < 0) {
            uint256 loss = SafeCast.toUint256(-netPnl);
            uint256 covered = Math.min(loss, collateralPortion);
            if (covered > 0) {
                collateralPortion -= covered;
                usy.safeTransfer(address(ylpVault), covered);
            }
            uint256 shortfall = loss - covered;
            if (shortfall > 0) {
                emit ShortfallRealized(params.trader, params.syntheticAsset, shortfall);
            }
            netPnl = covered == 0 ? int256(0) : -SafeCast.toInt256(covered);
        }

        if (params.liquidation) {
            uint256 reward = params.config.liquidationRewardBps == 0
                ? 0
                : Math.mulDiv(collateralPortion, params.config.liquidationRewardBps, BPS_DENOMINATOR);
            if (reward > 0 && params.rewardReceiver != address(0)) {
                usy.safeTransfer(params.rewardReceiver, reward);
            }
            uint256 remainder = collateralPortion > reward ? collateralPortion - reward : 0;
            if (remainder > 0) {
                usy.safeTransfer(address(ylpVault), remainder);
            }
            emit TradeLiquidated(params.trader, params.syntheticAsset, params.index, params.caller, netPnl);
        } else {
            if (collateralPortion > 0 && params.config.feesEnabled && params.config.closeFeeBps != 0) {
                uint256 closeFee = _mulDivUp(collateralPortion, params.config.closeFeeBps, BPS_DENOMINATOR);
                if (closeFee > collateralPortion) {
                    closeFee = collateralPortion;
                }
                if (closeFee > 0) {
                    collateralPortion -= closeFee;
                    usy.safeTransfer(_getTreasury(), closeFee);
                }
            }
            if (collateralPortion > 0 && params.unwindFeeBps != 0 && params.unwindFeeRecipient != address(0)) {
                uint256 unwindFee = _mulDivUp(collateralPortion, params.unwindFeeBps, BPS_DENOMINATOR);
                if (unwindFee > collateralPortion) {
                    unwindFee = collateralPortion;
                }
                if (unwindFee > 0) {
                    collateralPortion -= unwindFee;
                    usy.safeTransfer(params.unwindFeeRecipient, unwindFee);
                    unwindFeePaid = unwindFee;
                }
            }
            if (collateralPortion > 0) {
                usy.safeTransfer(params.trader, collateralPortion);
            }
            emit TradeClosed(
                params.trader, params.syntheticAsset, params.index, sizeToCloseScaled, netPnl, collateralPortion
            );
        }

        yoloHook.settlePnLFromPerps(params.trader, params.syntheticAsset, netPnl);
        return (sizeToCloseScaled, unwindFeePaid);
    }

    function _loadConfig(address syntheticAsset) private view returns (TradeAssetConfig memory config) {
        config = tradeAssetConfigs[syntheticAsset];
        if (config.pythPriceId == bytes32(0) || !config.isActive) {
            revert TradeOrchestrator__InactiveAsset();
        }
    }

    function _enforceLiquidatable(
        LiquidationParams calldata params,
        PriceInfo memory priceInfo,
        TradeAssetConfig memory config,
        AssetState storage state
    ) private view {
        uint256 tradeCount = yoloHook.getUserTradeCount(params.user);
        if (params.index >= tradeCount) revert TradeOrchestrator__PositionNotFound();
        DataTypes.TradePosition memory position = yoloHook.getUserTrade(params.user, params.index);
        if (position.syntheticAsset != params.syntheticAsset) revert TradeOrchestrator__PositionNotFound();
        PositionAccounting storage meta = positionAccounting[params.user][params.index];
        PositionScalingContext memory scaling = _applyCorporateActionScaling(params.syntheticAsset, position, meta);
        position.syntheticAssetPositionSize = scaling.scaledSize;
        position.entryPriceX8 = scaling.scaledEntryPriceX8;

        if (position.syntheticAssetPositionSize == 0 || position.collateralUsy == 0) {
            revert TradeOrchestrator__NotLiquidatable();
        }
        if (config.liquidationThresholdBps == 0) {
            revert TradeOrchestrator__NotLiquidatable();
        }

        uint256 notionalUsd = _notionalUsd(position.syntheticAssetPositionSize, priceInfo.priceX8);
        if (notionalUsd == 0) revert TradeOrchestrator__NotLiquidatable();
        uint256 borrowFee = _previewPendingBorrow(meta, notionalUsd);
        int256 fundingFee = _previewPendingFunding(meta, state, position, notionalUsd);
        int256 equity = SafeCast.toInt256(position.collateralUsy);
        equity += _unrealizedPnl(position, priceInfo.priceX8, position.syntheticAssetPositionSize);
        equity -= SafeCast.toInt256(borrowFee);
        equity -= fundingFee;
        if (equity <= 0) {
            return;
        }
        uint256 equityRatioBps = Math.mulDiv(SafeCast.toUint256(equity), BPS_DENOMINATOR, notionalUsd);
        if (equityRatioBps >= config.liquidationThresholdBps) {
            revert TradeOrchestrator__NotLiquidatable();
        }
    }

    function _enforceDeadline(uint64 deadline) private view {
        if (deadline != 0 && block.timestamp > deadline) {
            revert TradeOrchestrator__DeadlineExpired();
        }
    }

    function _enforceDeviation(address asset, uint16 maxDeviationBps, uint256 fastPrice) private view {
        if (maxDeviationBps == 0) return;
        IYoloOracle anchorOracle = yoloHook.yoloOracle();
        if (address(anchorOracle) == address(0)) return;
        uint256 anchorPrice = anchorOracle.getAssetPrice(asset);
        if (anchorPrice == 0) return;
        uint256 diff = fastPrice > anchorPrice ? fastPrice - anchorPrice : anchorPrice - fastPrice;
        if (diff * BPS_DENOMINATOR > anchorPrice * maxDeviationBps) {
            revert TradeOrchestrator__MaxDeviationExceeded();
        }
    }

    function _computeLeverage(uint256 collateralUsy, uint256 notionalUsd) private pure returns (uint32) {
        if (collateralUsy == 0 || notionalUsd == 0) {
            return 0;
        }
        uint256 leverage = (notionalUsd * BPS_DENOMINATOR) / collateralUsy;
        return SafeCast.toUint32(leverage);
    }

    function _enforceLeverage(address syntheticAsset, uint32 leverageBps) private view {
        DataTypes.AssetConfiguration memory cfg = yoloHook.getAssetConfiguration(syntheticAsset);
        if (!cfg.perpConfig.enabled) revert TradeOrchestrator__MarketClosed();
        if (cfg.perpConfig.marketState != DataTypes.TradeMarketState.OPEN) {
            revert TradeOrchestrator__MarketClosed();
        }
        uint32 cap = _currentLeverageCap(cfg.perpConfig);
        if (cap != 0 && leverageBps > cap) {
            revert TradeOrchestrator__LeverageTooHigh();
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
        uint32 secondsToday = uint32(block.timestamp % 86_400);
        if (config.tradeSessionEnd > config.tradeSessionStart) {
            return secondsToday >= config.tradeSessionStart && secondsToday < config.tradeSessionEnd;
        }
        return secondsToday >= config.tradeSessionStart || secondsToday < config.tradeSessionEnd;
    }

    function _consumePriceUpdate(TradeAssetConfig memory config, bytes[] calldata priceUpdateData)
        private
        returns (PriceInfo memory info, uint256 feePaid)
    {
        feePaid = pyth.getUpdateFee(priceUpdateData);
        if (msg.value < feePaid) revert TradeOrchestrator__InsufficientUpdateFee();
        pyth.updatePriceFeeds{value: feePaid}(priceUpdateData);

        uint32 maxAge = config.maxPriceAgeSec == 0 ? 1 : config.maxPriceAgeSec;
        PythStructs.Price memory price = pyth.getPriceNoOlderThan(config.pythPriceId, maxAge);
        if (price.price <= 0) revert TradeOrchestrator__InvalidPrice();
        info.priceX8 = _scalePrice(price);
        info.publishTime = SafeCast.toUint64(price.publishTime);
    }

    function _applyCorporateActionScaling(
        address syntheticAsset,
        DataTypes.TradePosition memory position,
        PositionAccounting storage meta
    ) private view returns (PositionScalingContext memory ctx) {
        ctx.currentIndex = _getPriceIndex(syntheticAsset);
        uint256 storedIndex = meta.entryPriceIndex == 0 ? ctx.currentIndex : meta.entryPriceIndex;
        ctx.previousIndex = storedIndex;
        if (ctx.currentIndex == storedIndex) {
            ctx.scaledSize = position.syntheticAssetPositionSize;
            ctx.scaledEntryPriceX8 = position.entryPriceX8;
        } else {
            ctx.scaledSize = _mulDivUp(position.syntheticAssetPositionSize, ctx.currentIndex, storedIndex);
            ctx.scaledEntryPriceX8 = Math.mulDiv(position.entryPriceX8, storedIndex, ctx.currentIndex);
        }
    }

    function _applyDirectionalSpread(uint256 basePriceX8, TradeAssetConfig memory config, bool longExposure)
        private
        pure
        returns (uint256)
    {
        if (longExposure) {
            if (config.longSpreadBps == 0) return basePriceX8;
            return Math.mulDiv(basePriceX8, BPS_DENOMINATOR + config.longSpreadBps, BPS_DENOMINATOR);
        }
        if (config.shortSpreadBps == 0) return basePriceX8;
        return Math.mulDiv(basePriceX8, BPS_DENOMINATOR - config.shortSpreadBps, BPS_DENOMINATOR);
    }

    function _scalePrice(PythStructs.Price memory price) private pure returns (uint256) {
        int256 value = int256(price.price);
        if (value <= 0) revert TradeOrchestrator__InvalidPrice();
        int256 expo = int256(price.expo) + 8;
        if (expo > MAX_PRICE_EXPO || expo < -MAX_PRICE_EXPO) {
            revert TradeOrchestrator__InvalidPrice();
        }
        if (expo > 0) {
            uint32 exponent = SafeCast.toUint32(SafeCast.toUint256(expo));
            value *= int256(10 ** exponent);
        } else if (expo < 0) {
            uint32 exponent = SafeCast.toUint32(SafeCast.toUint256(-expo));
            value /= int256(10 ** exponent);
        }
        return SafeCast.toUint256(value);
    }

    function _refundSurplus(uint256 feePaid) private {
        if (msg.value <= feePaid) return;
        (bool success,) = msg.sender.call{value: msg.value - feePaid}("");
        require(success, "refund failed");
    }

    function _notionalUsd(uint256 amount, uint256 priceX8) private pure returns (uint256) {
        return Math.mulDiv(amount, priceX8, PRICE_DECIMALS);
    }

    function _updateExposure(
        AssetState storage state,
        DataTypes.TradeDirection direction,
        uint256 notionalUsd,
        bool increase
    ) private {
        if (notionalUsd == 0) return;
        if (direction == DataTypes.TradeDirection.LONG) {
            state.longOpenInterestUsd = increase
                ? state.longOpenInterestUsd + notionalUsd
                : state.longOpenInterestUsd - Math.min(notionalUsd, state.longOpenInterestUsd);
        } else {
            state.shortOpenInterestUsd = increase
                ? state.shortOpenInterestUsd + notionalUsd
                : state.shortOpenInterestUsd - Math.min(notionalUsd, state.shortOpenInterestUsd);
        }
    }

    function _applyFundingInternal(address syntheticAsset, AssetState storage state, TradeAssetConfig memory config)
        private
    {
        uint256 last = state.lastFundingAccrual;
        if (block.timestamp <= last) return;
        if (config.fundingFactorPerHour == 0) {
            state.lastFundingAccrual = SafeCast.toUint64(block.timestamp);
            return;
        }
        uint256 longOi = state.longOpenInterestUsd;
        uint256 shortOi = state.shortOpenInterestUsd;
        if (longOi == shortOi) {
            state.lastFundingAccrual = SafeCast.toUint64(block.timestamp);
            return;
        }
        uint256 totalOi = longOi + shortOi;
        if (totalOi == 0) {
            state.lastFundingAccrual = SafeCast.toUint64(block.timestamp);
            return;
        }
        int256 imbalance = SafeCast.toInt256(longOi) - SafeCast.toInt256(shortOi);
        int256 fundingScaleInt = SafeCast.toInt256(FUNDING_RATE_SCALE);
        int256 skewRatio = (imbalance * fundingScaleInt) / SafeCast.toInt256(totalOi);
        if (skewRatio > fundingScaleInt) {
            skewRatio = fundingScaleInt;
        } else if (skewRatio < -fundingScaleInt) {
            skewRatio = -fundingScaleInt;
        }
        int256 ratePerHour = (skewRatio * SafeCast.toInt256(uint256(config.fundingFactorPerHour))) / fundingScaleInt;
        int256 delta = (ratePerHour * SafeCast.toInt256(block.timestamp - last) * SafeCast.toInt256(FUNDING_SCALE))
            / (SafeCast.toInt256(SECONDS_PER_HOUR) * fundingScaleInt);
        state.fundingAccumulator += delta;
        state.lastFundingAccrual = SafeCast.toUint64(block.timestamp);
        emit FundingApplied(syntheticAsset, state.fundingAccumulator, state.lastFundingAccrual);
    }

    function _collectAccruedFees(
        DataTypes.TradePosition memory position,
        PositionAccounting storage meta,
        AssetState storage state,
        uint256 priceX8,
        uint256 sizeToClose
    ) private returns (uint256 borrowFee, int256 fundingFee) {
        uint256 totalSize = position.syntheticAssetPositionSize;
        if (totalSize == 0) {
            return (0, 0);
        }
        uint256 totalNotionalUsd = _notionalUsd(totalSize, priceX8);
        uint256 pendingBorrow = _accrueBorrow(meta, totalNotionalUsd);
        if (pendingBorrow != 0) {
            if (sizeToClose == totalSize) {
                borrowFee = pendingBorrow;
                meta.pendingBorrowUsy = 0;
            } else {
                borrowFee = _mulDivUp(pendingBorrow, sizeToClose, totalSize);
                meta.pendingBorrowUsy = pendingBorrow - borrowFee;
            }
        }

        int256 pendingFunding = _accrueFunding(meta, state, position, totalNotionalUsd);
        if (pendingFunding != 0) {
            if (sizeToClose == totalSize) {
                fundingFee = pendingFunding;
                meta.pendingFundingUsy = 0;
            } else {
                fundingFee = _roundChargeUp(pendingFunding * SafeCast.toInt256(sizeToClose), totalSize);
                meta.pendingFundingUsy = pendingFunding - fundingFee;
            }
        }
    }

    function _accrueBorrow(PositionAccounting storage meta, uint256 positionNotionalUsd) private returns (uint256) {
        uint256 pending = meta.pendingBorrowUsy;
        if (
            positionNotionalUsd != 0 && meta.borrowRateBps != 0 && meta.lastBorrowTimestamp != 0
                && block.timestamp > meta.lastBorrowTimestamp
        ) {
            uint256 elapsed = block.timestamp - meta.lastBorrowTimestamp;
            uint256 newFee = _accruedBorrowFee(positionNotionalUsd, meta.borrowRateBps, elapsed);
            if (newFee != 0) {
                pending += newFee;
            }
        }
        if (meta.lastBorrowTimestamp != 0) {
            meta.lastBorrowTimestamp = SafeCast.toUint64(block.timestamp);
        }
        meta.pendingBorrowUsy = pending;
        return pending;
    }

    function _accrueFunding(
        PositionAccounting storage meta,
        AssetState storage state,
        DataTypes.TradePosition memory position,
        uint256 totalNotionalUsd
    ) private returns (int256) {
        int256 pending = meta.pendingFundingUsy;
        int256 fundingDelta = state.fundingAccumulator - meta.entryFundingIndex;
        if (fundingDelta != 0 && totalNotionalUsd != 0) {
            int256 signedExposure = position.direction == DataTypes.TradeDirection.LONG
                ? SafeCast.toInt256(totalNotionalUsd)
                : -SafeCast.toInt256(totalNotionalUsd);
            pending += _roundChargeUp(fundingDelta * signedExposure, FUNDING_SCALE);
        }
        meta.pendingFundingUsy = pending;
        meta.entryFundingIndex = state.fundingAccumulator;
        return pending;
    }

    function _accruedBorrowFee(uint256 notionalUsd, uint16 rateBps, uint256 elapsedSeconds)
        private
        pure
        returns (uint256)
    {
        if (notionalUsd == 0 || rateBps == 0 || elapsedSeconds == 0) {
            return 0;
        }
        uint256 annualized = _mulDivUp(notionalUsd, rateBps, BPS_DENOMINATOR);
        return _mulDivUp(annualized, elapsedSeconds, SECONDS_PER_YEAR);
    }

    function _unrealizedPnl(DataTypes.TradePosition memory position, uint256 priceX8, uint256 size)
        private
        pure
        returns (int256)
    {
        if (size == 0) {
            return 0;
        }
        int256 priceDelta = position.direction == DataTypes.TradeDirection.LONG
            ? SafeCast.toInt256(priceX8) - SafeCast.toInt256(position.entryPriceX8)
            : SafeCast.toInt256(position.entryPriceX8) - SafeCast.toInt256(priceX8);
        return (SafeCast.toInt256(size) * priceDelta) / SafeCast.toInt256(PRICE_DECIMALS);
    }

    function _previewPendingBorrow(PositionAccounting storage meta, uint256 positionNotionalUsd)
        private
        view
        returns (uint256)
    {
        uint256 pending = meta.pendingBorrowUsy;
        if (
            positionNotionalUsd == 0 || meta.borrowRateBps == 0 || meta.lastBorrowTimestamp == 0
                || block.timestamp <= meta.lastBorrowTimestamp
        ) {
            return pending;
        }
        uint256 elapsed = block.timestamp - meta.lastBorrowTimestamp;
        uint256 newFee = _accruedBorrowFee(positionNotionalUsd, meta.borrowRateBps, elapsed);
        return pending + newFee;
    }

    function _previewPendingFunding(
        PositionAccounting storage meta,
        AssetState storage state,
        DataTypes.TradePosition memory position,
        uint256 totalNotionalUsd
    ) private view returns (int256) {
        int256 pending = meta.pendingFundingUsy;
        if (totalNotionalUsd == 0) {
            return pending;
        }
        int256 delta = state.fundingAccumulator - meta.entryFundingIndex;
        if (delta == 0) {
            return pending;
        }
        int256 signedExposure = position.direction == DataTypes.TradeDirection.LONG
            ? SafeCast.toInt256(totalNotionalUsd)
            : -SafeCast.toInt256(totalNotionalUsd);
        return pending + _roundChargeUp(delta * signedExposure, FUNDING_SCALE);
    }

    function _computeSettlement(
        DataTypes.TradePosition memory position,
        PositionAccounting storage meta,
        AssetState storage state,
        uint256 syntheticSize,
        uint256 priceX8
    ) private returns (int256 pnlUsy, uint256 borrowFee, int256 fundingFee) {
        pnlUsy = _unrealizedPnl(position, priceX8, syntheticSize);
        (borrowFee, fundingFee) = _collectAccruedFees(position, meta, state, priceX8, syntheticSize);
    }

    function _postCloseBookkeeping(
        address user,
        uint256 index,
        uint256 lengthBefore,
        DataTypes.TradeUpdateAction action
    ) private {
        if (action == DataTypes.TradeUpdateAction.CLOSE || action == DataTypes.TradeUpdateAction.LIQUIDATE) {
            uint256 lastIndex = lengthBefore - 1;
            if (index != lastIndex) {
                positionAccounting[user][index] = positionAccounting[user][lastIndex];
            }
            delete positionAccounting[user][lastIndex];
        } else {
            positionAccounting[user][index].lastPricePublishTime = SafeCast.toUint64(block.timestamp);
        }
    }

    function _roundChargeUp(int256 numerator, uint256 denominator) private pure returns (int256) {
        if (numerator == 0) {
            return 0;
        }
        assert(denominator != 0);
        uint256 absNumerator = SignedMath.abs(numerator);
        if (numerator > 0) {
            uint256 quotient = absNumerator / denominator;
            if (absNumerator % denominator != 0) {
                quotient += 1;
            }
            return SafeCast.toInt256(quotient);
        } else {
            uint256 quotient = absNumerator / denominator;
            return -SafeCast.toInt256(quotient);
        }
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 denominator) private pure returns (uint256) {
        if (a == 0 || b == 0) {
            return 0;
        }
        assert(denominator != 0);
        uint256 result = Math.mulDiv(a, b, denominator);
        if (mulmod(a, b, denominator) != 0) {
            result += 1;
        }
        return result;
    }

    function _getPriceIndex(address syntheticAsset) private view returns (uint256) {
        return IYoloSyntheticAsset(syntheticAsset).liquidityIndex();
    }

    function _getTreasury() private view returns (address) {
        address treasury = yoloHook.treasury();
        if (treasury == address(0)) revert TradeOrchestrator__TreasuryNotSet();
        return treasury;
    }

    // ============================================================
    // UPGRADE AUTHORIZATION
    // ============================================================

    /**
     * @dev Only TRADE_ADMIN_ROLE or DEFAULT_ADMIN_ROLE may authorize upgrades
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyTradeAdmin {}
}
