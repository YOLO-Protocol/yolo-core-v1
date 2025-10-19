// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MintableIncentivizedERC20Upgradeable} from "../tokenization/base/MintableIncentivizedERC20Upgradeable.sol";
import {EIP712BaseUpgradeable} from "../tokenization/base/EIP712BaseUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYLPVault} from "../interfaces/IYLPVault.sol";
import {IYoloHook} from "../interfaces/IYoloHook.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title YLP (YOLO Counterparty LP Token)
 * @author alvin@yolo.wtf
 * @notice ERC4626 vault token with incentivized rewards, serving as LP counterparty to traders
 * @dev Combines:
 *      - MintableIncentivizedERC20: Reward distribution mechanism
 *      - EIP712: Gasless permit support
 *      - UUPS: Upgradeable proxy pattern
 *      - ERC4626: Standard vault interface for composability
 *      - IYLPVault: Settlement interface with YoloHook
 */
contract YLP is
    MintableIncentivizedERC20Upgradeable,
    EIP712BaseUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IERC4626,
    IYLPVault
{
    // ============================================================
    // ERRORS
    // ============================================================

    error YLP__CallerNotAuthorized();
    error YLP__ZeroAddress();
    error YLP__ZeroAmount();
    error YLP__SlippageTooHigh();
    error YLP__InvalidRequestId();
    error YLP__RequestAlreadyExecuted();
    error YLP__NotYLPSolver();
    error YLP__DepositBelowMinimum();
    error YLP__DepositAboveMaximum();
    error YLP__WithdrawalBelowMinimum();
    error YLP__InvalidFeeBps();
    error YLP__EpochNotSealed();
    error YLP__QueueOnly();
    error YLP__DepositsPaused();
    error YLP__InsufficientUSY();
    error YLP__USYTransferFailed();
    error YLP__BatchSizeTooLarge();
    error YLP__NegativeNAV();
    error YLP__PnLExceedsBounds();
    error YLP__PnLChangedTooFast();
    error YLP__SnapshotTooOld();
    error YLP__SealTooSoon();
    error YLP__EpochTooShort();
    error YLP__RequestTooRecent();

    // ============================================================
    // ROLES
    // ============================================================
    bytes32 public constant YLP_SOLVER_ROLE = keccak256("YLP_SOLVER");
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN");

    // ============================================================
    // MODIFIERS
    // ============================================================
    modifier onlyRiskAdmin() {
        if (!ACL_MANAGER.hasRole(RISK_ADMIN_ROLE, msg.sender)) revert YLP__CallerNotAuthorized();
        _;
    }

    modifier onlyYlpSolver() {
        if (!ACL_MANAGER.hasRole(YLP_SOLVER_ROLE, msg.sender)) revert YLP__NotYLPSolver();
        _;
    }

    modifier whenEpochSealed() {
        if (!_getYLPStorage().lastSnapshot.isSealed) revert YLP__EpochNotSealed();
        _;
    }

    modifier onlyHookCaller() {
        if (msg.sender != _getYLPStorage().yoloHook) revert YLP__CallerNotAuthorized();
        _;
    }

    // ============================================================
    // STORAGE
    // ============================================================

    /**
     * @notice Epoch snapshot for fair NAV-based execution
     * @dev Sealed once per epoch by solver, read by executeDeposits/executeWithdrawals
     */
    struct EpochSnapshot {
        uint256 epochId; // Epoch identifier (monotonically increasing)
        uint256 navUSY; // Total NAV in USY terms (18 decimals)
        uint256 pricePerShareRay; // Price per YLP share in RAY precision (27 decimals)
        uint256 snapshotBlock; // Snapshot L2 block anchor
        int256 unrealizedPnL; // Unrealized PnL from YLP's perspective (positive = profit, negative = loss)
        uint256 timestamp; // Block timestamp when sealed
        bool isSealed; // Whether this epoch has been sealed
    }

    /// @dev Prevent storage collision with inherited contracts
    /// @custom:storage-location erc7201:yolo.storage.YLP
    struct YLPStorage {
        // Core references
        address yoloHook; // YoloHook address (authorized to settle PnL)
        IERC20 usy; // Underlying asset (USY stablecoin)
        // Admin configurable limits (dust attack prevention & risk management)
        uint256 minDepositAmount; // Minimum USY deposit amount
        uint256 maxDepositAmount; // Maximum USY deposit amount
        uint256 minWithdrawalAmount; // Minimum YLP shares withdrawal amount
        uint256 withdrawalFeeBps; // Withdrawal fee in basis points (e.g., 50 = 0.5%)
        // NAV tracking (live, for internal use only - NOT used by execution)
        int256 unrealizedPnL; // (Reserved) Unrealized P&L from all synthetic positions (USY terms)
        // Utilization tracking
        mapping(address asset => uint256 exposure) assetExposure; // Per-asset exposure (absolute PnL)
        address[] trackedAssets; // List of assets with non-zero exposure
        uint256 totalExposure; // Sum of all absolute exposures
        // Risk parameters
        uint256 maxAbsPnLBps; // e.g. 4000 = 40%
        uint256 maxRateChangeBps; // e.g. 1500 = 15%
        uint256 autoPauseLossBps; // e.g. 3500 = 35%
        uint256 minEpochBlocks; // min spacing between snapshot blocks
        uint256 minBlockLag; // min blocks after snapshotBlock to seal
        uint256 maxBatchSize; // max batch size for execute operations (gas DoS protection)
        bool depositsPaused; // emergency pause for deposits
        // Epoch snapshots (sealed NAV for fair execution)
        uint256 currentEpochId; // Current epoch counter
        EpochSnapshot lastSnapshot; // Last sealed epoch snapshot
        mapping(uint256 => EpochSnapshot) epochSnapshots; // Historical snapshots by epochId
        // Queue system
        uint256 nextDepositRequestId; // Counter for deposit requests
        uint256 nextWithdrawalRequestId; // Counter for withdrawal requests
        mapping(uint256 => IYLPVault.DepositRequest) depositRequests; // Deposit request queue
        mapping(uint256 => IYLPVault.WithdrawalRequest) withdrawalRequests; // Withdrawal request queue
        mapping(uint256 => uint256) depositRequestEpoch; // Map requestId → epochId submitted
        mapping(uint256 => uint256) withdrawalRequestEpoch; // Map requestId → epochId submitted
        // Epoch configuration (TBD: time-based vs block-based)
        uint256 epochLength; // Epoch duration (blocks or seconds - TBD)
        // Buffer management (Phase 2)
        // Emergency state (Phase 4)
    }

    // keccak256(abi.encode(uint256(keccak256("yolo.storage.YLP")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant YLP_STORAGE_LOCATION = 0x271b8ac420666628e5786bb2df3d5fafad452e28986ab2f9779686587418590b;

    function _getYLPStorage() private pure returns (YLPStorage storage $) {
        assembly {
            $.slot := YLP_STORAGE_LOCATION
        }
    }

    // ============================================================
    // INITIALIZER
    // ============================================================

    /**
     * @notice Initialize the YLP vault
     * @param _yoloHook YoloHook address
     * @param _usy USY token address (underlying asset)
     * @param _aclManager ACL manager address for access control
     */
    function initialize(address _yoloHook, address _usy, address _aclManager) external initializer {
        if (_yoloHook == address(0) || _usy == address(0)) revert YLP__ZeroAddress();

        // Initialize base contracts
        __MintableIncentivizedERC20_init(_yoloHook, _aclManager, "YOLO Counterparty LP Token", "YLP", 18);
        __EIP712Base_init("YLP");
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        // Initialize YLP storage
        YLPStorage storage $ = _getYLPStorage();
        $.yoloHook = _yoloHook;
        $.usy = IERC20(_usy);
        $.currentEpochId = 0;
        $.maxAbsPnLBps = 4000; // 40%
        $.maxRateChangeBps = 1500; // 15%
        $.autoPauseLossBps = 3500; // 35%
        $.minEpochBlocks = 1;
        $.minBlockLag = 1;
        $.maxBatchSize = 256; // Default max batch size
        $.depositsPaused = false;
        $.lastSnapshot = EpochSnapshot({
            epochId: 0,
            navUSY: 0,
            pricePerShareRay: 1e27,
            snapshotBlock: 0,
            unrealizedPnL: 0,
            timestamp: block.timestamp,
            isSealed: false
        });
    }

    // ============================================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================================

    /**
     * @dev Only YoloHook can upgrade (which checks ASSETS_ADMIN via its own auth)
     */
    function _authorizeUpgrade(address newImplementation) internal override {
        if (msg.sender != _getYLPStorage().yoloHook) revert YLP__CallerNotAuthorized();
    }

    // ============================================================
    // ERC4626 INTERFACE
    // ============================================================

    /// @inheritdoc IERC4626
    function asset() external view override returns (address) {
        return address(_getYLPStorage().usy);
    }

    /// @inheritdoc IERC4626
    function totalAssets() external view override returns (uint256) {
        // ERC4626 semantics: return underlying held (USY balance)
        YLPStorage storage $ = _getYLPStorage();
        return $.usy.balanceOf(address(this));
    }

    /// @inheritdoc IERC4626
    function convertToShares(uint256 assets) external view override returns (uint256) {
        (,, uint256 ppsRay,) = this.getLastSnapshot();
        if (ppsRay == 0) return 0;
        return (assets * 1e27) / ppsRay;
    }

    /// @inheritdoc IERC4626
    function convertToAssets(uint256 shares) external view override returns (uint256) {
        (,, uint256 ppsRay,) = this.getLastSnapshot();
        if (ppsRay == 0) return 0;
        return (shares * ppsRay) / 1e27;
    }

    /// @inheritdoc IERC4626
    function maxDeposit(address) external view override returns (uint256) {
        YLPStorage storage $ = _getYLPStorage();
        uint256 maxAmt = $.maxDepositAmount;
        return maxAmt == 0 ? type(uint256).max : maxAmt;
    }

    /// @inheritdoc IERC4626
    function maxMint(address) external view override returns (uint256) {
        // Route to queue; instantaneous mint disabled
        return 0;
    }

    /// @inheritdoc IERC4626
    function maxWithdraw(address owner) external view override returns (uint256) {
        // Route to queue; instantaneous withdraw disabled
        return 0;
    }

    /// @inheritdoc IERC4626
    function maxRedeem(address owner) external view override returns (uint256) {
        // Route to queue; instantaneous redeem disabled
        return 0;
    }

    /// @inheritdoc IERC4626
    function previewDeposit(uint256 assets) external view override returns (uint256) {
        (,, uint256 ppsRay,) = this.getLastSnapshot();
        if (ppsRay == 0) return 0;
        return (assets * 1e27) / ppsRay;
    }

    /// @inheritdoc IERC4626
    function previewMint(uint256 shares) external view override returns (uint256) {
        (,, uint256 ppsRay,) = this.getLastSnapshot();
        if (ppsRay == 0) return 0;
        return (shares * ppsRay) / 1e27;
    }

    /// @inheritdoc IERC4626
    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        (,, uint256 ppsRay,) = this.getLastSnapshot();
        if (ppsRay == 0) return 0;
        return (assets * 1e27) / ppsRay;
    }

    /// @inheritdoc IERC4626
    function previewRedeem(uint256 shares) external view override returns (uint256) {
        (,, uint256 ppsRay,) = this.getLastSnapshot();
        if (ppsRay == 0) return 0;
        return (shares * ppsRay) / 1e27;
    }

    /// @inheritdoc IERC4626
    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        // Queue-only architecture
        revert YLP__QueueOnly();
    }

    /// @inheritdoc IERC4626
    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        revert YLP__QueueOnly();
    }

    /// @inheritdoc IERC4626
    function withdraw(uint256 assets, address receiver, address owner) external override returns (uint256 shares) {
        revert YLP__QueueOnly();
    }

    /// @inheritdoc IERC4626
    function redeem(uint256 shares, address receiver, address owner) external override returns (uint256 assets) {
        revert YLP__QueueOnly();
    }

    // ============================================================
    // IYLPVault INTERFACE (Settlement with YoloHook)
    // ============================================================

    /// @inheritdoc IYLPVault
    function settlePnL(address user, address syntheticAsset, int256 pnlUSY)
        external
        override
        onlyHookCaller
        nonReentrant
    {
        if (pnlUSY > 0) {
            uint256 payout = SafeCast.toUint256(pnlUSY);
            YLPStorage storage $ = _getYLPStorage();
            if ($.usy.balanceOf(address(this)) < payout) revert YLP__InsufficientUSY();
            if (!$.usy.transfer(user, payout)) revert YLP__USYTransferFailed();
        } // pnlUSY < 0 means USY already minted to this vault by hook; no action needed
        emit PnLSettled(user, syntheticAsset, pnlUSY, block.timestamp);
    }

    /// @inheritdoc IYLPVault
    function recordTrade(address user, address syntheticAsset, uint256 notionalUSY, uint256 feeUSY)
        external
        override
        onlyHookCaller
    {
        // Placeholder for utilization tracking (to be implemented in Phase 3)
        emit TradeRecorded(user, syntheticAsset, notionalUSY, feeUSY);
    }

    // ============================================================
    // ADMIN FUNCTIONS (RISK_ADMIN role)
    // ============================================================

    /// @inheritdoc IYLPVault
    function setMinDepositAmount(uint256 minAmount) external override onlyRiskAdmin {
        YLPStorage storage $ = _getYLPStorage();
        uint256 oldAmount = $.minDepositAmount;
        $.minDepositAmount = minAmount;
        emit IYLPVault.MinDepositAmountUpdated(oldAmount, minAmount);
    }

    /// @inheritdoc IYLPVault
    function setMaxDepositAmount(uint256 maxAmount) external override onlyRiskAdmin {
        YLPStorage storage $ = _getYLPStorage();
        uint256 oldAmount = $.maxDepositAmount;
        $.maxDepositAmount = maxAmount;
        emit IYLPVault.MaxDepositAmountUpdated(oldAmount, maxAmount);
    }

    /// @inheritdoc IYLPVault
    function setMinWithdrawalAmount(uint256 minAmount) external override onlyRiskAdmin {
        YLPStorage storage $ = _getYLPStorage();
        uint256 oldAmount = $.minWithdrawalAmount;
        $.minWithdrawalAmount = minAmount;
        emit IYLPVault.MinWithdrawalAmountUpdated(oldAmount, minAmount);
    }

    /// @inheritdoc IYLPVault
    function setWithdrawalFeeBps(uint256 feeBps) external override onlyRiskAdmin {
        if (feeBps > 10000) revert YLP__InvalidFeeBps(); // Max 100%
        YLPStorage storage $ = _getYLPStorage();
        uint256 oldFeeBps = $.withdrawalFeeBps;
        $.withdrawalFeeBps = feeBps;
        emit IYLPVault.WithdrawalFeeBpsUpdated(oldFeeBps, feeBps);
    }

    /**
     * @notice Set max absolute PnL bound (basis points)
     * @dev Only callable by RISK_ADMIN
     * @param bps Maximum absolute PnL as percentage of balance (e.g., 4000 = 40%)
     */
    function setMaxAbsPnLBps(uint256 bps) external onlyRiskAdmin {
        if (bps > 10000) revert YLP__InvalidFeeBps(); // Max 100%
        YLPStorage storage $ = _getYLPStorage();
        $.maxAbsPnLBps = bps;
    }

    /**
     * @notice Set max rate of change bound (basis points)
     * @dev Only callable by RISK_ADMIN
     * @param bps Maximum PnL change rate between epochs (e.g., 1500 = 15%)
     */
    function setMaxRateChangeBps(uint256 bps) external onlyRiskAdmin {
        if (bps > 10000) revert YLP__InvalidFeeBps(); // Max 100%
        YLPStorage storage $ = _getYLPStorage();
        $.maxRateChangeBps = bps;
    }

    /**
     * @notice Set auto-pause loss threshold (basis points)
     * @dev Only callable by RISK_ADMIN
     * @param bps Loss threshold that triggers auto-pause (e.g., 3500 = 35%)
     */
    function setAutoPauseLossBps(uint256 bps) external onlyRiskAdmin {
        if (bps > 10000) revert YLP__InvalidFeeBps(); // Max 100%
        YLPStorage storage $ = _getYLPStorage();
        $.autoPauseLossBps = bps;
    }

    /**
     * @notice Set minimum epoch spacing (blocks)
     * @dev Only callable by RISK_ADMIN
     * @param blocks Minimum blocks between epoch seals
     */
    function setMinEpochBlocks(uint256 blocks) external onlyRiskAdmin {
        YLPStorage storage $ = _getYLPStorage();
        $.minEpochBlocks = blocks;
    }

    /**
     * @notice Set minimum block lag for sealing
     * @dev Only callable by RISK_ADMIN
     * @param blocks Minimum blocks after snapshot before seal allowed
     */
    function setMinBlockLag(uint256 blocks) external onlyRiskAdmin {
        YLPStorage storage $ = _getYLPStorage();
        $.minBlockLag = blocks;
    }

    /**
     * @notice Set maximum batch size for execute operations
     * @dev Only callable by RISK_ADMIN
     * @param size Maximum number of requests per batch
     */
    function setMaxBatchSize(uint256 size) external onlyRiskAdmin {
        YLPStorage storage $ = _getYLPStorage();
        $.maxBatchSize = size;
    }

    /**
     * @notice Toggle deposits paused state
     * @dev Only callable by RISK_ADMIN
     * @param paused True to pause deposits, false to resume
     */
    function setDepositsPaused(bool paused) external onlyRiskAdmin {
        YLPStorage storage $ = _getYLPStorage();
        $.depositsPaused = paused;
    }

    // ============================================================
    // DEPOSIT/WITHDRAWAL QUEUE (User-Initiated)
    // ============================================================

    /// @inheritdoc IYLPVault
    function requestDeposit(uint256 usyAmount, uint256 minYLPShares, uint256 maxSlippageBps)
        external
        override
        returns (uint256 requestId)
    {
        if (usyAmount == 0) revert YLP__ZeroAmount();
        YLPStorage storage $ = _getYLPStorage();
        if ($.depositsPaused) revert YLP__DepositsPaused();
        if ($.minDepositAmount > 0 && usyAmount < $.minDepositAmount) revert YLP__DepositBelowMinimum();
        if ($.maxDepositAmount > 0 && usyAmount > $.maxDepositAmount) revert YLP__DepositAboveMaximum();

        // Pull USY into vault (pending)
        if (!$.usy.transferFrom(msg.sender, address(this), usyAmount)) revert YLP__USYTransferFailed();

        requestId = $.nextDepositRequestId++;
        $.depositRequests[requestId] = DepositRequest({
            user: msg.sender,
            usyAmount: usyAmount,
            minYLPShares: minYLPShares,
            maxSlippageBps: maxSlippageBps,
            requestBlock: block.number,
            executed: false
        });
        $.depositRequestEpoch[requestId] = $.currentEpochId;
        emit DepositRequested(requestId, msg.sender, usyAmount, minYLPShares, block.number);
    }

    /// @inheritdoc IYLPVault
    /// @dev Withdrawals are intentionally allowed even when depositsPaused = true (withdraw-only mode)
    function requestWithdrawal(uint256 ylpShares, uint256 minUSYOut, uint256 maxSlippageBps)
        external
        override
        returns (uint256 requestId)
    {
        if (ylpShares == 0) revert YLP__ZeroAmount();
        YLPStorage storage $ = _getYLPStorage();
        if ($.minWithdrawalAmount > 0 && ylpShares < $.minWithdrawalAmount) revert YLP__WithdrawalBelowMinimum();

        // Pull YLP shares into vault (pending)
        _spendAllowance(msg.sender, address(this), ylpShares);
        _transfer(msg.sender, address(this), ylpShares);

        requestId = $.nextWithdrawalRequestId++;
        $.withdrawalRequests[requestId] = WithdrawalRequest({
            user: msg.sender,
            ylpShares: ylpShares,
            minUSYOut: minUSYOut,
            maxSlippageBps: maxSlippageBps,
            requestBlock: block.number,
            executed: false
        });
        $.withdrawalRequestEpoch[requestId] = $.currentEpochId;
        emit WithdrawalRequested(requestId, msg.sender, ylpShares, minUSYOut, block.number);
    }

    // ============================================================
    // SOLVER FUNCTIONS (YLP_SOLVER role only)
    // ============================================================

    /// @inheritdoc IYLPVault
    function sealEpoch(int256 unrealizedPnL, uint256 snapshotBlock)
        external
        override
        onlyYlpSolver
        returns (uint256 epochId, uint256 navUSY, uint256 pricePerShareRay)
    {
        YLPStorage storage $ = _getYLPStorage();

        // Monotonicity and lag
        if (snapshotBlock <= $.lastSnapshot.snapshotBlock) revert YLP__SnapshotTooOld();
        if (block.number < snapshotBlock + $.minBlockLag) revert YLP__SealTooSoon();
        if ($.lastSnapshot.snapshotBlock > 0) {
            if (snapshotBlock - $.lastSnapshot.snapshotBlock < $.minEpochBlocks) revert YLP__EpochTooShort();
        }

        // Bounds vs current balance
        uint256 balance = $.usy.balanceOf(address(this));
        uint256 absBound = (balance * $.maxAbsPnLBps) / 10000;
        int256 absPnL = unrealizedPnL >= 0 ? unrealizedPnL : -unrealizedPnL;
        if (SafeCast.toUint256(absPnL) > absBound) revert YLP__PnLExceedsBounds();

        // Rate-of-change bound vs last epoch
        if ($.lastSnapshot.isSealed) {
            int256 last = $.lastSnapshot.unrealizedPnL;
            int256 delta = unrealizedPnL - last;
            int256 absDelta = delta >= 0 ? delta : -delta;
            uint256 rateBound = (balance * $.maxRateChangeBps) / 10000;
            if (SafeCast.toUint256(absDelta) > rateBound) revert YLP__PnLChangedTooFast();
        }

        // Compute NAV and guards
        int256 navSigned = SafeCast.toInt256(balance) + unrealizedPnL;
        if (navSigned <= 0) revert YLP__NegativeNAV();
        navUSY = SafeCast.toUint256(navSigned);

        // Auto-pause on extreme loss
        if (unrealizedPnL < -int256((balance * $.autoPauseLossBps) / 10000)) {
            $.depositsPaused = true;
        }

        // Increment epoch and store snapshot
        $.currentEpochId += 1;
        epochId = $.currentEpochId;
        uint256 supply = totalSupply();
        pricePerShareRay = supply == 0 ? 1e27 : (navUSY * 1e27) / supply;

        EpochSnapshot memory snap = EpochSnapshot({
            epochId: epochId,
            navUSY: navUSY,
            pricePerShareRay: pricePerShareRay,
            snapshotBlock: snapshotBlock,
            unrealizedPnL: unrealizedPnL,
            timestamp: block.timestamp,
            isSealed: true
        });
        $.lastSnapshot = snap;
        $.epochSnapshots[epochId] = snap;

        emit EpochSealed(epochId, navUSY, pricePerShareRay, snapshotBlock, unrealizedPnL, block.timestamp, msg.sender);
    }

    /// @inheritdoc IYLPVault
    function executeDeposits(uint256[] calldata requestIds) external override onlyYlpSolver whenEpochSealed {
        YLPStorage storage $ = _getYLPStorage();
        uint256 len = requestIds.length;
        if (len > $.maxBatchSize) revert YLP__BatchSizeTooLarge();

        uint256 ppsRay = $.lastSnapshot.pricePerShareRay;
        uint256 snapshotBlock = $.lastSnapshot.snapshotBlock;

        for (uint256 i = 0; i < len; i++) {
            uint256 id = requestIds[i];
            DepositRequest storage req = $.depositRequests[id];
            if (req.user == address(0)) revert YLP__InvalidRequestId();
            if (req.executed) revert YLP__RequestAlreadyExecuted();
            if (req.requestBlock >= snapshotBlock) revert YLP__RequestTooRecent();

            // USY vault: shares = usyAmount / pps
            uint256 shares = ppsRay == 0 ? 0 : (req.usyAmount * 1e27) / ppsRay;

            bool ok = true;
            if (req.minYLPShares > 0 && shares < req.minYLPShares) {
                // Negative slippage check only (positive slippage is OK)
                uint256 diff = req.minYLPShares - shares;
                uint256 bps = (diff * 10000) / req.minYLPShares;
                if (bps > req.maxSlippageBps) ok = false;
            }

            if (ok && shares > 0) {
                _mint(req.user, shares);
                req.executed = true;
                emit DepositExecuted(id, req.user, req.usyAmount, shares);
            } else {
                // Refund USY
                if (!$.usy.transfer(req.user, req.usyAmount)) revert YLP__USYTransferFailed();
                req.executed = true;
                emit DepositRefunded(id, req.user, req.usyAmount, "Slippage or zero shares");
            }
        }
    }

    /// @inheritdoc IYLPVault
    function executeWithdrawals(uint256[] calldata requestIds) external override onlyYlpSolver whenEpochSealed {
        YLPStorage storage $ = _getYLPStorage();
        uint256 len = requestIds.length;
        if (len > $.maxBatchSize) revert YLP__BatchSizeTooLarge();

        uint256 ppsRay = $.lastSnapshot.pricePerShareRay;
        uint256 snapshotBlock = $.lastSnapshot.snapshotBlock;

        for (uint256 i = 0; i < len; i++) {
            uint256 id = requestIds[i];
            WithdrawalRequest storage req = $.withdrawalRequests[id];
            if (req.user == address(0)) revert YLP__InvalidRequestId();
            if (req.executed) revert YLP__RequestAlreadyExecuted();
            if (req.requestBlock >= snapshotBlock) revert YLP__RequestTooRecent();

            // USY vault: usyOut = shares * pps
            uint256 usyOut = (req.ylpShares * ppsRay) / 1e27;

            // Apply fee
            uint256 fee = ($.withdrawalFeeBps == 0) ? 0 : (usyOut * $.withdrawalFeeBps) / 10000;
            uint256 usyAfterFee = usyOut - fee;

            bool ok = true;
            if (req.minUSYOut > 0 && usyAfterFee < req.minUSYOut) {
                uint256 diff = req.minUSYOut - usyAfterFee;
                uint256 bps = (diff * 10000) / req.minUSYOut;
                if (bps > req.maxSlippageBps) ok = false;
            }

            if (ok && usyAfterFee > 0) {
                // Burn shares held by vault
                _burn(address(this), req.ylpShares);
                // Transfer USY to user (fee stays in vault)
                if (!$.usy.transfer(req.user, usyAfterFee)) revert YLP__USYTransferFailed();
                req.executed = true;
                emit WithdrawalExecuted(id, req.user, req.ylpShares, usyAfterFee, fee);
            } else {
                // Refund YLP shares to user
                _transfer(address(this), req.user, req.ylpShares);
                req.executed = true;
                emit WithdrawalRefunded(id, req.user, req.ylpShares, "Slippage or zero assets");
            }
        }
    }

    // ============================================================
    // VIEW FUNCTIONS (Helper conversions & Queries)
    // ============================================================

    // No conversion helpers in USY vault mode

    /// @inheritdoc IYLPVault
    function getLastSnapshot()
        external
        view
        override
        returns (uint256 epochId, uint256 navUSY, uint256 pricePerShareRay, uint256 timestamp)
    {
        YLPStorage storage $ = _getYLPStorage();
        EpochSnapshot memory snapshot = $.lastSnapshot;
        return (snapshot.epochId, snapshot.navUSY, snapshot.pricePerShareRay, snapshot.timestamp);
    }

    /// @inheritdoc IYLPVault
    function getDepositRequest(uint256 requestId) external view override returns (IYLPVault.DepositRequest memory) {
        YLPStorage storage $ = _getYLPStorage();
        return $.depositRequests[requestId];
    }

    /// @inheritdoc IYLPVault
    function getWithdrawalRequest(uint256 requestId)
        external
        view
        override
        returns (IYLPVault.WithdrawalRequest memory)
    {
        YLPStorage storage $ = _getYLPStorage();
        return $.withdrawalRequests[requestId];
    }

    // ============================================================
    // UTILIZATION TRACKING (Phase 3)
    // ============================================================

    // TODO: Utilization enforcement functions

    // ============================================================
    // EMERGENCY CONTROLS (Phase 4)
    // ============================================================

    // TODO: Emergency state machine
}
