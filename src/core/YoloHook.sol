// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";
import {IYLPVault} from "../interfaces/IYLPVault.sol";
import {IYoloSyntheticAsset} from "../interfaces/IYoloSyntheticAsset.sol";
import {IStabilityTracker} from "../interfaces/IStabilityTracker.sol";
import {IYoloHook} from "../interfaces/IYoloHook.sol";
import {YoloHookStorage, AppStorage, ReferralData} from "./YoloHookStorage.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {SyntheticAssetModule} from "../libraries/SyntheticAssetModule.sol";
import {LendingPairModule} from "../libraries/LendingPairModule.sol";
import {LiquidationModule} from "../libraries/LiquidationModule.sol";
import {FlashLoanModule} from "../libraries/FlashLoanModule.sol";
import {StablecoinModule} from "../libraries/StablecoinModule.sol";
import {SwapModule} from "../libraries/SwapModule.sol";
import {SyntheticSwapModule} from "../libraries/SyntheticSwapModule.sol";
import {BootstrapModule} from "../libraries/BootstrapModule.sol";
import {TradeModule} from "../libraries/TradeModule.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title YoloHook
 * @author alvin@yolo.wtf
 * @notice Main hook contract for YOLO Protocol V1 - Yield-Optimized Leverage Onchain
 * @dev Uniswap V4 Hook integrating ACL-based access control and modular architecture
 *      - Proxy-safe: Immutables in constructor, storage init in initialize()
 *      - All hook permissions enabled for maximum flexibility
 *      - ACL-based access control (no Ownable/Pausable inheritance)
 *      - Reentrancy protection for external calls
 *      - Externally linked library modules (Aave-style) for gas efficiency
 *      - UUPS upgradeability with admin-only authorization
 *      - Handles both anchor pool (USY-USDC StableSwap) and synthetic pools (oracle-based)
 */
contract YoloHook is BaseHook, YoloHookStorage, ReentrancyGuard, UUPSUpgradeable {
    // ========================
    // LIBRARY USAGE
    // ========================

    using SyntheticAssetModule for AppStorage;
    using LendingPairModule for AppStorage;
    using TradeModule for AppStorage;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;
    // ========================
    // CONSTANTS
    // ========================

    /// @notice Role for pausing protocol operations
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER");

    /// @notice Role for configuring assets and synthetic pairs
    bytes32 public constant ASSETS_ADMIN_ROLE = keccak256("ASSETS_ADMIN");

    /// @notice Role for risk parameter management
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN");

    /// @notice Role for privileged liquidators (when onlyPrivilegedLiquidator is enabled)
    bytes32 public constant PRIVILEGED_LIQUIDATOR_ROLE = keccak256("PRIVILEGED_LIQUIDATOR");

    /// @notice Role for zero-fee flash loans
    bytes32 public constant PRIVILEGED_FLASHLOANER_ROLE = keccak256("PRIVILEGED_FLASHLOANER");

    /// @notice Role for contracts that can operate on behalf of users (Looper, Position Managers)
    /// @dev Allows deposit/borrow/repay operations for onBehalfOf addresses (e.g., leverage loops)
    bytes32 public constant LOOPER_ROLE = keccak256("LOOPER");

    /// @notice Role for leverage TradeOrchestrator contracts
    /// @dev Gates all leveraged trading storage mutations and settlement flows
    bytes32 public constant TRADE_OPERATOR_ROLE = keccak256("TRADE_OPERATOR");

    // ========================
    // IMMUTABLE STORAGE
    // ========================

    /// @notice ACL Manager for role-based access control
    /// @dev Immutable is proxy-safe (stored in bytecode, not storage)
    IACLManager public immutable ACL_MANAGER;

    /// @notice Delegatecall target for read-only helpers
    address public viewImplementation;

    // Note: State variables moved to YoloHookStorage for upgradeability

    // ========================
    // EVENTS
    // ========================

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event OracleUpdated(address indexed newOracle);
    event YLPVaultUpdated(address indexed newVault);
    event TreasuryUpdated(address indexed newTreasury);
    event StabilityTrackerUpdated(address indexed newTracker);
    event ImplementationUpgraded(address indexed target, address indexed newImplementation);
    event AnchorSwapFeeUpdated(uint256 newFeeBps);
    event SyntheticSwapFeeUpdated(uint256 newFeeBps);
    event AnchorAmplificationUpdated(uint256 newAmplification);
    event AnchorFeeTreasuryShareUpdated(uint256 oldShareBps, uint256 newShareBps);
    event TradeProfitShareUpdated(uint256 oldShareBps, uint256 newShareBps);
    event PrivilegedLiquidatorToggled(bool enabled);
    event YLPFundedWithUSY(address indexed callerAsset, uint256 amount);
    event EmergencyWithdrawal(address indexed token, address indexed to, uint256 amount);
    event TradePositionUpdated(
        address indexed user,
        address indexed syntheticAsset,
        DataTypes.TradeUpdateAction action,
        uint256 index,
        int256 collateralDelta,
        int256 syntheticDelta
    );
    event ViewImplementationUpdated(address indexed newImplementation);
    event ReferralCodeRegistered(address indexed referrer, bytes32 code);
    event ReferralLinked(address indexed trader, address indexed tier1, address indexed tier2);
    event ReferralRewardAccrued(address indexed referrer, uint256 amount, IYoloHook.ReferralRewardType rewardType);
    event ReferralRewardsClaimed(address indexed referrer, address indexed to, uint256 amount);

    // ========================
    // ERRORS
    // ========================

    error YoloHook__CallerNotAuthorized();
    error YoloHook__ProtocolPaused();
    error YoloHook__ProtocolNotPaused();
    error YoloHook__InvalidOracle();
    error YoloHook__InvalidAddress();
    error YoloHook__NotYoloAsset();
    error YoloHook__ImbalancedDeposit();
    error YoloHook__InvalidConfiguration();
    error YoloHook__NoPrivilegedLiquidators();
    error YoloHook__InvalidRescue();
    error YoloHook__InvalidFeeSplit();
    error YoloHook__InvalidTradeIndex();
    error YoloHook__ViewImplementationNotSet();
    error YoloHook__ReferralCodeUnavailable();
    error YoloHook__ReferralCodeUnknown();
    error YoloHook__ReferralAlreadySet();
    error YoloHook__ReferralSelf();
    error YoloHook__ReferralLoop();
    error YoloHook__NoReferralRewards();

    // ========================
    // INTERNAL ACCESS CONTROL CHECKS
    // ========================
    // NOTE: These internal functions reduce bytecode size by avoiding modifier inlining

    /**
     * @dev Check caller has PAUSER role (internal to save bytecode)
     */
    function _checkPauser() private view {
        if (!ACL_MANAGER.hasRole(PAUSER_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
    }

    /**
     * @dev Check caller has ASSETS_ADMIN role (internal to save bytecode)
     */
    function _checkAssetsAdmin() private view {
        if (
            !ACL_MANAGER.hasRole(ASSETS_ADMIN_ROLE, msg.sender) && !ACL_MANAGER.hasRole(0x00, msg.sender) // DEFAULT_ADMIN
        ) {
            revert YoloHook__CallerNotAuthorized();
        }
    }

    /**
     * @dev Check caller has RISK_ADMIN role (internal to save bytecode)
     */
    function _checkRiskAdmin() private view {
        if (
            !ACL_MANAGER.hasRole(RISK_ADMIN_ROLE, msg.sender) && !ACL_MANAGER.hasRole(0x00, msg.sender) // DEFAULT_ADMIN
        ) {
            revert YoloHook__CallerNotAuthorized();
        }
    }

    /**
     * @dev Check caller has DEFAULT_ADMIN_ROLE (internal to save bytecode)
     */
    function _checkDefaultAdmin() private view {
        if (!ACL_MANAGER.hasRole(0x00, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
    }

    /**
     * @dev Check protocol is not paused (internal to save bytecode)
     */
    function _checkNotPaused() private view {
        if (s._paused) {
            revert YoloHook__ProtocolPaused();
        }
    }

    /**
     * @dev Check protocol is paused (internal to save bytecode)
     */
    function _checkPaused() private view {
        if (!s._paused) {
            revert YoloHook__ProtocolNotPaused();
        }
    }

    /**
     * @dev Check caller has LOOPER role (internal to save bytecode)
     */
    function _checkLooper() private view {
        if (!ACL_MANAGER.hasRole(LOOPER_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
    }

    /**
     * @dev Check caller has TRADE_OPERATOR role (leveraged trading modules)
     */
    function _checkTradeOperator() private view {
        if (!ACL_MANAGER.hasRole(TRADE_OPERATOR_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
    }

    // ========================
    // MODIFIERS
    // ========================

    modifier onlyPauser() {
        _checkPauser();
        _;
    }

    modifier onlyAssetsAdmin() {
        _checkAssetsAdmin();
        _;
    }

    modifier onlyRiskAdmin() {
        _checkRiskAdmin();
        _;
    }

    modifier onlyDefaultAdmin() {
        _checkDefaultAdmin();
        _;
    }

    modifier whenNotPaused() {
        _checkNotPaused();
        _;
    }

    modifier whenPaused() {
        _checkPaused();
        _;
    }

    modifier onlyLooper() {
        _checkLooper();
        _;
    }

    modifier onlyTradeOperator() {
        _checkTradeOperator();
        _;
    }

    // ========================
    // INTERNAL HELPERS
    // ========================

    /**
     * @notice Require caller is either the account owner or has LOOPER_ROLE
     * @dev Reduces bytecode by consolidating repeated authorization checks
     * @param onBehalfOf The account being acted on behalf of
     */
    function _requireLooperOrSelf(address onBehalfOf) private view {
        if (onBehalfOf != msg.sender) {
            if (!ACL_MANAGER.hasRole(LOOPER_ROLE, msg.sender)) {
                revert YoloHook__CallerNotAuthorized();
            }
        }
    }

    /**
     * @notice Generate pairId for a synthetic-collateral pair
     * @dev Reduces bytecode by consolidating repeated keccak256 calls
     * @param syntheticAsset The synthetic asset address
     * @param collateralAsset The collateral asset address
     * @return pairId The unique identifier for the pair
     */
    function _pairId(address syntheticAsset, address collateralAsset) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(syntheticAsset, collateralAsset));
    }

    // ========================
    // CONSTRUCTOR
    // ========================

    /**
     * @notice Deploy YoloHook implementation with immutable references
     * @param _poolManager Address of the Uniswap V4 Pool Manager contract
     * @param _aclManager Address of the ACL Manager contract for role-based access control
     * @dev Constructor only sets immutables (proxy-safe)
     *      Storage variables must be initialized via initialize() after proxy deployment
     *      Immutables are stored in bytecode and work correctly with proxy pattern
     */
    constructor(IPoolManager _poolManager, IACLManager _aclManager) BaseHook(_poolManager) {
        ACL_MANAGER = _aclManager;
        // Note: Do NOT initialize storage variables here
        // Storage init happens in initialize() for proxy compatibility
        _disableInitializers(); // Prevent implementation contract from being initialized
    }

    // ========================
    // INITIALIZER
    // ========================

    /**
     * @notice Initialize storage variables for proxy deployment
     * @param _yoloOracle Oracle module for price feeds
     * @param _usdc USDC token address (varies by chain)
     * @param _usyImplementation USY implementation for UUPS deployment
     * @param _sUSYImplementation sUSY implementation for UUPS deployment
     * @param _ylpVaultImplementation YLP vault implementation for UUPS deployment
     * @param _treasury Treasury address for interest payments
     * @param _anchorAmplificationCoefficient StableSwap amplification coefficient
     * @param _anchorSwapFeeBps Anchor pool swap fee (bps)
     * @param _syntheticSwapFeeBps Synthetic pool swap fee (bps)
     * @dev Can only be called once due to initializer modifier
     *      Deploys USY, sUSY, and YLP with UUPS proxies
     *      Creates anchor pool (USY-USDC)
     *      Protocol starts in unpaused state
     */
    function initialize(
        IYoloOracle _yoloOracle,
        address _usdc,
        address _usyImplementation,
        address _sUSYImplementation,
        address _ylpVaultImplementation,
        address _treasury,
        uint256 _anchorAmplificationCoefficient,
        uint256 _anchorSwapFeeBps,
        uint256 _syntheticSwapFeeBps
    ) external initializer {
        // Validation
        if (address(_yoloOracle) == address(0)) revert YoloHook__InvalidOracle();
        if (_usdc == address(0)) revert YoloHook__InvalidAddress();
        if (_usyImplementation == address(0)) revert YoloHook__InvalidAddress();
        if (_sUSYImplementation == address(0)) revert YoloHook__InvalidAddress();
        if (_treasury == address(0)) revert YoloHook__InvalidAddress();
        if (_anchorAmplificationCoefficient == 0) revert YoloHook__InvalidConfiguration();
        if (_anchorSwapFeeBps > 10000) revert YoloHook__InvalidConfiguration(); // Max 100%
        if (_syntheticSwapFeeBps > 10000) revert YoloHook__InvalidConfiguration(); // Max 100%
        BootstrapModule.initialize(
            s,
            poolManager,
            ACL_MANAGER,
            address(this),
            _yoloOracle,
            _usdc,
            _usyImplementation,
            _sUSYImplementation,
            _ylpVaultImplementation,
            _treasury,
            _anchorAmplificationCoefficient,
            _anchorSwapFeeBps,
            _syntheticSwapFeeBps
        );
    }

    // ========================
    // EXTERNAL VIEW FUNCTIONS
    // ========================

    /**
     * @notice Returns the permissions for this hook
     * @dev Enable all hook permissions for future upgradability and module integration
     *      - beforeSwap/afterSwap: Anchor pool (StableSwap) + Synthetic pool (oracle) swap logic
     *      - beforeSwapReturnDelta: Override default pool math with custom calculations
     *      - beforeInitialize/afterInitialize: Pool setup and validation
     *      - Liquidity hooks: Anchor pool LP management (sUSY minting)
     *      - Donate hooks: Reserved for future fee distribution mechanisms
     * @return permissions Struct containing all enabled hook permissions
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /**
     * @notice Exposes PoolManager address for integrations (e.g., vault add/remove liquidity)
     */
    function poolManagerAddress() external view returns (address) {
        return address(poolManager);
    }

    // ========================
    // ADMIN FUNCTIONS
    // ========================

    /**
     * @notice Pause the protocol (emergency stop)
     * @dev Can only be called by accounts with PAUSER role
     *      Prevents execution of user-facing functions while allowing admin operations
     */
    function pause() external onlyPauser whenNotPaused {
        s._paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the protocol
     * @dev Can only be called by accounts with PAUSER role
     *      Resumes normal protocol operations after emergency pause
     */
    function unpause() external onlyPauser whenPaused {
        s._paused = false;
        emit Unpaused(msg.sender);
    }

    // ============================================================
    // SYNTHETIC ASSET MANAGEMENT
    // ============================================================

    /**
     * @notice Creates a new synthetic asset with UUPS proxy
     * @dev Only callable by assets admin
     *      Implementation address passed as parameter (Aave-style)
     *      YoloHook maintains upgrade control via _authorizeUpgrade
     *      The synthetic asset's address is registered directly in YoloOracle
     * @param name Token name (e.g., "Yolo Synthetic ETH")
     * @param symbol Token symbol (e.g., "yETH")
     * @param decimals Token decimals (typically 18)
     * @param oracleSource Price feed source for the synthetic asset
     * @param implementation YoloSyntheticAsset implementation address
     * @param maxSupply Maximum supply cap (0 for unlimited)
     * @param maxFlashLoanAmount Maximum flash loan amount (0 for unlimited)
     * @return syntheticToken Address of deployed synthetic token proxy
     */
    function createSyntheticAsset(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address oracleSource,
        address implementation,
        uint256 maxSupply,
        uint256 maxFlashLoanAmount
    ) external onlyAssetsAdmin returns (address syntheticToken) {
        return s.createSyntheticAsset(
            poolManager,
            address(this),
            ACL_MANAGER,
            name,
            symbol,
            decimals,
            oracleSource,
            implementation,
            maxSupply,
            maxFlashLoanAmount
        );
    }

    /**
     * @notice Upgrade any YOLO protocol contract implementation
     * @dev Only DEFAULT_ADMIN_ROLE can upgrade. Automatically validates contract type.
     *      Supports: USY, sUSY, YLP, and any synthetic asset (yNVDA, yTSLA, etc.)
     * @param target Contract proxy to upgrade
     * @param newImplementation New implementation address
     */
    function upgradeImplementation(address target, address newImplementation) external onlyDefaultAdmin nonReentrant {
        if (newImplementation == address(0)) revert YoloHook__InvalidAddress();

        // Validate target is a known protocol contract
        bool isValid = false;

        if (target == s.usy) isValid = true; // USY stablecoin
        else if (target == s.sUSY) isValid = true; // sUSY LP token
        else if (target == s.ylpVault) isValid = true; // YLP vault
        else if (s._isYoloAsset[target]) isValid = true; // Any synthetic asset

        if (!isValid) revert YoloHook__InvalidAddress();

        // Execute upgrade
        UUPSUpgradeable(target).upgradeToAndCall(newImplementation, "");

        emit ImplementationUpgraded(target, newImplementation);
    }

    /**
     * @notice Deactivates a synthetic asset
     * @dev Only callable by assets admin
     * @param syntheticToken Address of the synthetic token
     */
    function deactivateSyntheticAsset(address syntheticToken) external onlyAssetsAdmin {
        s.deactivateSyntheticAsset(syntheticToken);
    }

    /**
     * @notice Reactivates a synthetic asset
     * @dev Only callable by assets admin
     * @param syntheticToken Address of the synthetic token
     */
    function reactivateSyntheticAsset(address syntheticToken) external onlyAssetsAdmin {
        s.reactivateSyntheticAsset(syntheticToken);
    }

    /**
     * @notice Updates max supply for a synthetic asset
     * @dev Only callable by assets admin
     *      Allows dynamic adjustment of supply cap
     *      0 = unlimited supply
     * @param syntheticToken Address of the synthetic token
     * @param newMaxSupply New maximum supply (0 for unlimited)
     */
    function updateAssetMaxSupply(address syntheticToken, uint256 newMaxSupply) external onlyAssetsAdmin {
        s.updateMaxSupply(syntheticToken, newMaxSupply);
    }

    /**
     * @notice Updates the leveraged trading configuration for a synthetic asset
     * @param syntheticToken Address of the synthetic asset
     * @param config New configuration struct
     */
    function updateAssetPerpConfiguration(address syntheticToken, DataTypes.PerpConfiguration calldata config)
        external
        onlyAssetsAdmin
    {
        s.updatePerpConfiguration(syntheticToken, config);
    }

    // ============================================================
    // LEVERAGED TRADING (TRADE MODULE)
    // ============================================================

    /**
     * @notice Mutates a leveraged trade via the TradeModule
     * @param update Structured trade mutation parameters
     */
    function updateTradePosition(DataTypes.TradeUpdate calldata update)
        external
        whenNotPaused
        onlyTradeOperator
        nonReentrant
        returns (uint256 idx, int256 collateralDelta, int256 syntheticDelta)
    {
        (idx, collateralDelta, syntheticDelta) = s.updateTradePosition(update, msg.sender);
        emit TradePositionUpdated(
            update.user, update.syntheticAsset, update.action, idx, collateralDelta, syntheticDelta
        );
    }

    // ============================================================
    // LENDING PAIR CONFIGURATION
    // ============================================================

    /**
     * @notice Configures a new lending pair
     * @dev Only callable by assets admin
     *      Deposit/debt tokens are OPTIONAL (pass address(0) to skip)
     * @param syntheticAsset The synthetic asset being borrowed
     * @param collateralAsset The collateral asset
     * @param depositToken Optional receipt token for deposits (can be address(0))
     * @param debtToken Optional debt tracking token (can be address(0))
     * @param ltv Loan-to-Value ratio in basis points
     * @param liquidationThreshold Liquidation threshold in basis points
     * @param liquidationBonus Liquidation bonus in basis points
     * @param liquidationPenalty Liquidation penalty in basis points
     * @param borrowRate Annual borrow rate in basis points
     * @param maxMintableCap Maximum mintable cap for synthetic asset
     * @param maxSupplyCap Maximum supply cap for collateral
     * @param minimumBorrowAmount Minimum borrow amount per transaction (in synthetic asset decimals, 0 = no minimum)
     * @param isExpirable Whether positions expire
     * @param expirePeriod Expiry period in seconds
     * @return pairId Unique identifier for the pair
     */
    function configureLendingPair(
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
    ) external onlyAssetsAdmin returns (bytes32 pairId) {
        return s.configureLendingPair(
            syntheticAsset,
            collateralAsset,
            depositToken,
            debtToken,
            ltv,
            liquidationThreshold,
            liquidationBonus,
            liquidationPenalty,
            borrowRate,
            maxMintableCap,
            maxSupplyCap,
            minimumBorrowAmount,
            isExpirable,
            expirePeriod
        );
    }

    /**
     * @notice Whitelists a collateral asset
     * @dev Only callable by assets admin
     * @param collateralAsset Address of collateral to whitelist
     */
    function whitelistCollateral(address collateralAsset) external onlyAssetsAdmin {
        s.whitelistCollateral(collateralAsset);
    }

    /**
     * @notice Updates risk parameters for a lending pair
     * @dev Only callable by risk admin
     * @param pairId Unique identifier for the pair
     * @param ltv New Loan-to-Value ratio
     * @param liquidationThreshold New liquidation threshold
     * @param liquidationBonus New liquidation bonus
     */
    function updateRiskParameters(bytes32 pairId, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus)
        external
        onlyRiskAdmin
    {
        s.updateRiskParameters(pairId, ltv, liquidationThreshold, liquidationBonus);
    }

    // ============================================================
    // PROTOCOL CONFIGURATION
    // ============================================================

    /**
     * @notice Updates the oracle module
     * @dev Only callable by default admin (critical infrastructure change)
     * @param _yoloOracle New oracle address
     */
    function updateOracle(IYoloOracle _yoloOracle) external onlyDefaultAdmin {
        if (address(_yoloOracle) == address(0)) revert YoloHook__InvalidOracle();
        s.yoloOracle = _yoloOracle;
        emit OracleUpdated(address(_yoloOracle));
    }

    /**
     * @notice Updates the YLP vault
     * @dev Only callable by default admin (critical infrastructure change)
     * @param _ylpVault New YLP vault address
     */
    function updateYLPVault(address _ylpVault) external onlyDefaultAdmin {
        if (_ylpVault == address(0)) revert YoloHook__InvalidAddress();
        s.ylpVault = _ylpVault;
        emit YLPVaultUpdated(_ylpVault);
    }

    /**
     * @notice Updates the treasury address
     * @dev Only callable by default admin (governance-level decision)
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyDefaultAdmin {
        if (_treasury == address(0)) revert YoloHook__InvalidAddress();
        s.treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    /**
     * @notice Sets or removes the stability tracker module
     * @dev Only callable by default admin (governance-level decision)
     *      This is an optional pluggable module that rewards traders who help maintain USY-USDC peg
     *      Pass address(0) to disable the module
     * @param _stabilityTracker Address of the stability tracker contract (or address(0) to disable)
     */
    function setStabilityTracker(address _stabilityTracker) external onlyDefaultAdmin {
        // Allow address(0) to disable the module
        s.stabilityTracker = IStabilityTracker(_stabilityTracker);
        emit StabilityTrackerUpdated(_stabilityTracker);
    }

    /**
     * @notice Sets the delegatecall target for read-only helpers
     * @dev Only callable by default admin
     * @param newImplementation Address of the YoloHookViews implementation (0 to disable)
     */
    function setViewImplementation(address newImplementation) external onlyDefaultAdmin {
        viewImplementation = newImplementation;
        emit ViewImplementationUpdated(newImplementation);
    }

    // ========================
    // REFERRAL PROGRAM
    // ========================

    /**
     * @notice Registers an obfuscated referral code derived from caller + salt
     * @param salt Arbitrary salt used to derive the referral code off-chain
     * @return code Generated referral code
     */
    function registerReferralCode(bytes32 salt) external whenNotPaused returns (bytes32 code) {
        code = keccak256(abi.encodePacked(msg.sender, salt));
        if (code == bytes32(0) || s.referralCodeOwner[code] != address(0)) {
            revert YoloHook__ReferralCodeUnavailable();
        }
        s.referralCodeOwner[code] = msg.sender;
        emit ReferralCodeRegistered(msg.sender, code);
    }

    /**
     * @notice Returns the owner of a referral code
     */
    function referralCodeOwner(bytes32 code) external view returns (address) {
        return s.referralCodeOwner[code];
    }

    /**
     * @notice Returns the referral tree (tier1/tier2) for a trader
     */
    function getUserReferrals(address user) external view returns (address tier1, address tier2) {
        ReferralData storage data = s.referralTree[user];
        return (data.tier1, data.tier2);
    }

    /**
     * @notice Assign upstream referrals for a trader (callable by orchestrators)
     * @param user Trader address receiving the referral tree
     * @param referralCode Registered referral code provided by the trader
     */
    function setUserReferral(address user, bytes32 referralCode) external whenNotPaused onlyTradeOperator {
        if (user == address(0)) revert YoloHook__InvalidAddress();
        if (referralCode == bytes32(0)) revert YoloHook__ReferralCodeUnknown();
        ReferralData storage existing = s.referralTree[user];
        if (existing.tier1 != address(0)) revert YoloHook__ReferralAlreadySet();

        address tier1 = s.referralCodeOwner[referralCode];
        if (tier1 == address(0)) revert YoloHook__ReferralCodeUnknown();
        if (tier1 == user) revert YoloHook__ReferralSelf();

        ReferralData storage tier1Data = s.referralTree[tier1];
        address tier2 = tier1Data.tier1;
        if (tier2 == user) revert YoloHook__ReferralLoop();

        s.referralTree[user] = ReferralData({tier1: tier1, tier2: tier2});
        emit ReferralLinked(user, tier1, tier2);
    }

    /**
     * @notice Credits referral rewards for a referrer
     * @dev TradeOrchestrator must transfer funds before invoking this
     */
    function creditReferralReward(address referrer, uint256 amount, IYoloHook.ReferralRewardType rewardType)
        external
        whenNotPaused
        onlyTradeOperator
    {
        if (referrer == address(0) || amount == 0) {
            return;
        }
        s.referralRewards[referrer] += amount;
        emit ReferralRewardAccrued(referrer, amount, rewardType);
    }

    /**
     * @notice View function for accrued referral rewards
     */
    function referralRewards(address referrer) external view returns (uint256) {
        return s.referralRewards[referrer];
    }

    /**
     * @notice Claim accumulated referral rewards
     * @param to Recipient for claimed USY (defaults to msg.sender if zero)
     * @return amount Amount transferred
     */
    function claimReferralRewards(address to) external whenNotPaused nonReentrant returns (uint256 amount) {
        amount = s.referralRewards[msg.sender];
        if (amount == 0) revert YoloHook__NoReferralRewards();
        s.referralRewards[msg.sender] = 0;
        address receiver = to == address(0) ? msg.sender : to;
        IERC20(s.usy).safeTransfer(receiver, amount);
        emit ReferralRewardsClaimed(msg.sender, receiver, amount);
    }

    /**
     * @notice Toggle privileged liquidator mode
     * @dev Only callable by assets admin
     *      When enabled, only addresses with PRIVILEGED_LIQUIDATOR_ROLE can liquidate
     *      Enforces that at least one privileged liquidator exists before enabling
     * @param enabled True to restrict liquidations to privileged liquidators only
     */
    function togglePrivilegedLiquidator(bool enabled) external onlyAssetsAdmin {
        // If enabling, ensure at least one PRIVILEGED_LIQUIDATOR exists
        if (enabled && ACL_MANAGER.getRoleMemberCount(PRIVILEGED_LIQUIDATOR_ROLE) == 0) {
            revert YoloHook__NoPrivilegedLiquidators();
        }
        s.onlyPrivilegedLiquidator = enabled;
        emit PrivilegedLiquidatorToggled(enabled);
    }

    /**
     * @notice Emergency withdraw accidentally sent tokens
     * @dev Only callable by RISK_ADMIN
     *      Cannot withdraw protocol-critical tokens (USY, USDC, any synthetic assets)
     *      Uses low-level call to minimize bytecode overhead
     * @param token Token address to withdraw
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function emergencyWithdraw(address token, address to, uint256 amount) external onlyRiskAdmin nonReentrant {
        if (token == address(0)) revert YoloHook__InvalidAddress();
        if (to == address(0)) revert YoloHook__InvalidAddress();

        // Cannot withdraw protocol-critical tokens (includes user collaterals)
        if (token == s.usy || token == s.usdc || s._isYoloAsset[token] || s._isWhitelistedCollateral[token]) {
            revert YoloHook__InvalidRescue();
        }

        // Use low-level call to save bytecode
        (bool success,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(success, "Transfer failed");

        emit EmergencyWithdrawal(token, to, amount);
    }

    /**
     * @notice Updates anchor swap fee
     * @dev Only callable by risk admin
     *      Changes take effect immediately for new swaps
     * @param newFeeBps New fee in basis points (0-10000, e.g., 4 = 0.04%)
     */
    function updateAnchorSwapFee(uint256 newFeeBps) external onlyRiskAdmin {
        if (newFeeBps > 10000) revert YoloHook__InvalidConfiguration(); // Max 100%
        s.anchorSwapFeeBps = newFeeBps;
        emit AnchorSwapFeeUpdated(newFeeBps);
    }

    /**
     * @notice Updates synthetic swap fee
     * @dev Only callable by risk admin
     *      Changes take effect immediately for new swaps
     * @param newFeeBps New fee in basis points (0-10000)
     */
    function updateSyntheticSwapFee(uint256 newFeeBps) external onlyRiskAdmin {
        if (newFeeBps > 10000) revert YoloHook__InvalidConfiguration(); // Max 100%
        s.syntheticSwapFeeBps = newFeeBps;
        emit SyntheticSwapFeeUpdated(newFeeBps);
    }

    /**
     * @notice Updates anchor pool fee treasury share
     * @dev Only callable by risk admin
     *      Remaining share (10000 - newShareBps) auto-compounds into LP reserves
     *      Changes take effect immediately for new swaps
     * @param newShareBps New treasury share in basis points (0-10000)
     */
    function setAnchorFeeTreasuryShare(uint256 newShareBps) external onlyRiskAdmin {
        if (newShareBps > 10_000) revert YoloHook__InvalidFeeSplit();

        uint256 oldShare = s.anchorFeeTreasuryShareBps;
        s.anchorFeeTreasuryShareBps = newShareBps;

        emit AnchorFeeTreasuryShareUpdated(oldShare, newShareBps);
    }

    /**
     * @notice Updates profit sharing for positive leveraged PnL
     * @dev Only callable by risk admin
     * @param newShareBps Treasury share in basis points (0-10000)
     */
    function setTradeProfitShare(uint256 newShareBps) external onlyRiskAdmin {
        if (newShareBps > 10_000) revert YoloHook__InvalidFeeSplit();
        uint256 oldShare = s.tradeProfitShareBps;
        s.tradeProfitShareBps = newShareBps;
        emit TradeProfitShareUpdated(oldShare, newShareBps);
    }

    /**
     * @notice Updates anchor amplification coefficient
     * @dev Only callable by risk admin
     *      Changes take effect immediately for new swaps
     *      Higher amplification = lower slippage for balanced pools
     * @param newAmplification New amplification coefficient (must be > 0)
     */
    function updateAnchorAmplification(uint256 newAmplification) external onlyRiskAdmin {
        if (newAmplification == 0) revert YoloHook__InvalidConfiguration();
        s.anchorAmplificationCoefficient = newAmplification;
        emit AnchorAmplificationUpdated(newAmplification);
    }

    /**
     * @notice Mint USY into the YLP vault to fund negative PnL settlements
     * @dev Callable only by registered YOLO synthetic assets during burn settlement flows
     *      Mints USY directly to the YLP vault (s.ylpVault)
     * @param amount Amount of USY (18 decimals)
     */
    function fundYLPWithUSY(uint256 amount) external whenNotPaused {
        if (!s._isYoloAsset[msg.sender]) revert YoloHook__NotYoloAsset();
        if (amount == 0) revert YoloHook__InvalidConfiguration();
        IYoloSyntheticAsset(s.usy).mint(s.ylpVault, amount);
        emit YLPFundedWithUSY(msg.sender, amount);
    }

    /**
     * @notice Synthetic asset calls this to settle PnL during burn
     * @dev Enforces caller is a registered YOLO synthetic asset; funds YLP for losses
     */
    function settlePnLFromSynthetic(address user, int256 pnlUSY) external whenNotPaused {
        if (!s._isYoloAsset[msg.sender]) revert YoloHook__NotYoloAsset();
        if (pnlUSY < 0) {
            uint256 gain = SafeCast.toUint256(-pnlUSY);
            IYoloSyntheticAsset(s.usy).mint(s.ylpVault, gain);
            emit YLPFundedWithUSY(msg.sender, gain);
        }
        IYLPVault(s.ylpVault).settlePnL(user, msg.sender, pnlUSY);
        uint256 treasuryShare = _treasuryShareFromLoss(pnlUSY);
        if (treasuryShare > 0) {
            IYLPVault(s.ylpVault).settlePnL(s.treasury, msg.sender, SafeCast.toInt256(treasuryShare));
        }
    }

    /**
     * @notice Allows TradeOrchestrators to settle leveraged-trade PnL against YLP
     * @param user Trader receiving or paying PnL
     * @param syntheticAsset Underlying synthetic asset the trade references
     * @param pnlUSY Signed PnL in USY (positive = user profit, negative = user loss)
     */
    function settlePnLFromPerps(address user, address syntheticAsset, int256 pnlUSY)
        external
        whenNotPaused
        onlyTradeOperator
    {
        if (!s._isYoloAsset[syntheticAsset]) revert YoloHook__NotYoloAsset();
        // NOTE: Perp orchestrators must transfer the user's collateral loss to YLP before calling this hook.
        // Unlike synthetic burns, no USY minting occurs here to avoid double counting.
        IYLPVault(s.ylpVault).settlePnL(user, syntheticAsset, pnlUSY);
        uint256 treasuryShare = _treasuryShareFromLoss(pnlUSY);
        if (treasuryShare > 0) {
            IYLPVault(s.ylpVault).settlePnL(s.treasury, syntheticAsset, SafeCast.toInt256(treasuryShare));
        }
    }

    /**
     * @notice Calculates treasury share taken from YLP profits (user losses)
     * @param pnlUSY Signed PnL (negative when user loses)
     * @return share Amount of USY owed to treasury
     */
    function _treasuryShareFromLoss(int256 pnlUSY) private view returns (uint256 share) {
        if (pnlUSY >= 0) {
            return 0;
        }
        uint256 shareBps = s.tradeProfitShareBps;
        address treasuryAddr = s.treasury;
        if (shareBps == 0 || treasuryAddr == address(0)) {
            return 0;
        }
        uint256 loss = SafeCast.toUint256(-pnlUSY);
        uint256 shareAmount = (loss * shareBps) / 10_000;
        return shareAmount;
    }

    // ============================================================
    // CDP OPERATIONS (LENDING PAIR MODULE)
    // ============================================================

    /**
     * @notice Borrow synthetic assets against collateral
     * @dev Follows Aave V3 onBehalfOf pattern for leverage loop contracts
     *      - If onBehalfOf != msg.sender, caller must have LOOPER_ROLE
     *      - Collateral is pulled from msg.sender (payer)
     *      - Borrowed tokens are minted to msg.sender (enables flash loan repayment)
     *      - Position ownership and debt is attributed to onBehalfOf (NOT token receiver)
     * @param yoloAsset Synthetic asset to borrow
     * @param borrowAmount Amount to borrow (18 decimals)
     * @param collateral Collateral asset
     * @param collateralAmount Collateral to deposit (native decimals)
     * @param onBehalfOf Address to own the position/debt (borrowed tokens minted to msg.sender)
     */
    function borrow(
        address yoloAsset,
        uint256 borrowAmount,
        address collateral,
        uint256 collateralAmount,
        address onBehalfOf
    ) external whenNotPaused nonReentrant {
        // Authorization: only LOOPER_ROLE can borrow on behalf of others
        _requireLooperOrSelf(onBehalfOf);

        s.borrowSyntheticAsset(yoloAsset, borrowAmount, collateral, collateralAmount, onBehalfOf);
    }

    /**
     * @notice Repay borrowed synthetic assets
     * @dev Follows Aave V3 onBehalfOf pattern for debt repayment
     *      - If onBehalfOf != msg.sender, caller must have LOOPER_ROLE
     *      - Tokens are burned from msg.sender (payer)
     *      - Debt reduction is applied to onBehalfOf's position (beneficiary)
     *      - Collateral returned to onBehalfOf if fully repaid (when autoClaimOnFullRepayment = true)
     * @param yoloAsset Synthetic asset to repay
     * @param collateral Collateral asset
     * @param repayAmount Amount to repay (18 decimals)
     * @param autoClaimOnFullRepayment Whether to automatically return collateral if debt becomes 0
     * @param onBehalfOf Address whose debt to reduce (tokens burned from msg.sender)
     */
    function repay(
        address yoloAsset,
        address collateral,
        uint256 repayAmount,
        bool autoClaimOnFullRepayment,
        address onBehalfOf
    ) external whenNotPaused nonReentrant {
        // Authorization: only LOOPER_ROLE can repay on behalf of others
        _requireLooperOrSelf(onBehalfOf);

        s.repaySyntheticAsset(collateral, yoloAsset, repayAmount, autoClaimOnFullRepayment, onBehalfOf);
    }

    /**
     * @notice Renew expirable position
     * @param yoloAsset Synthetic asset
     * @param collateral Collateral asset
     */
    function renewPosition(address yoloAsset, address collateral) external whenNotPaused nonReentrant {
        s.renewPosition(collateral, yoloAsset);
    }

    /**
     * @notice Add collateral to existing position
     * @dev Follows Aave V3 onBehalfOf pattern for collateral deposits
     *      - If onBehalfOf != msg.sender, caller must have LOOPER_ROLE
     *      - Collateral is pulled from msg.sender (payer)
     *      - Collateral is credited to onBehalfOf's position (receiver)
     *      - IMPORTANT: Requires existing position (use borrow() for new positions)
     * @param yoloAsset Synthetic asset
     * @param collateral Collateral asset
     * @param amount Amount to deposit
     * @param onBehalfOf Address to credit the collateral to (collateral from msg.sender)
     */
    function depositCollateral(address yoloAsset, address collateral, uint256 amount, address onBehalfOf)
        external
        whenNotPaused
        nonReentrant
    {
        // Authorization: only LOOPER_ROLE can deposit on behalf of others
        _requireLooperOrSelf(onBehalfOf);

        s.depositCollateral(collateral, yoloAsset, amount, onBehalfOf);
    }

    /**
     * @notice Withdraw collateral from position
     * @dev LOOPER_ROLE required when onBehalfOf != msg.sender
     *      Withdraws from onBehalfOf's position, sends to receiver
     *      Must maintain minimum collateralization after withdrawal
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param amount Amount to withdraw
     * @param onBehalfOf Address whose position to withdraw from
     * @param receiver Address to receive the withdrawn collateral
     */
    function withdrawCollateral(
        address collateral,
        address yoloAsset,
        uint256 amount,
        address onBehalfOf,
        address receiver
    ) external whenNotPaused nonReentrant {
        // Authorization: only LOOPER_ROLE can withdraw on behalf of others
        _requireLooperOrSelf(onBehalfOf);

        s.withdrawCollateral(collateral, yoloAsset, amount, onBehalfOf, receiver);
    }

    /**
     * @notice Liquidate undercollateralized or expired position
     * @param user User to liquidate
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @param repayAmount Amount to repay
     */
    function liquidate(address user, address collateral, address yoloAsset, uint256 repayAmount)
        external
        whenNotPaused
        nonReentrant
    {
        LiquidationModule.liquidate(s, user, collateral, yoloAsset, repayAmount);
    }

    /**
     * @notice Update borrow rate for a lending pair
     * @param pairId Lending pair ID
     * @param newBorrowRate New borrow rate in basis points
     */
    function updateBorrowRate(bytes32 pairId, uint256 newBorrowRate) external onlyAssetsAdmin {
        s.updateBorrowRate(pairId, newBorrowRate);
    }

    /**
     * @notice Update minimum borrow amount for a lending pair
     * @dev Only callable by risk admin
     *      Enables per-pair minimum tuning for different asset economics
     * @param pairId Lending pair ID
     * @param newMinimumBorrowAmount New minimum borrow amount (in synthetic asset decimals, 0 = no minimum)
     */
    function updateMinimumBorrowAmount(bytes32 pairId, uint256 newMinimumBorrowAmount) external onlyRiskAdmin {
        s.updateMinimumBorrowAmount(pairId, newMinimumBorrowAmount);
    }

    /**
     * @notice Update caps for a lending pair
     * @dev Only callable by risk admin
     *      Allows dynamic adjustment of supply/mint caps
     *      0 = paused (for both maxMintableCap and maxSupplyCap)
     * @param syntheticAsset Synthetic asset address
     * @param collateralAsset Collateral asset address
     * @param newMaxMintableCap New maximum mintable cap (0 = pause minting)
     * @param newMaxSupplyCap New maximum supply cap (0 = pause collateral deposits)
     */
    function updatePairCaps(
        address syntheticAsset,
        address collateralAsset,
        uint256 newMaxMintableCap,
        uint256 newMaxSupplyCap
    ) external onlyRiskAdmin {
        bytes32 pairId = _pairId(syntheticAsset, collateralAsset);
        LendingPairModule.updatePairCaps(s, pairId, newMaxMintableCap, newMaxSupplyCap);
    }

    /**
     * @notice Update liquidation penalty for a lending pair
     * @dev Only callable by risk admin
     * @param syntheticAsset Synthetic asset address
     * @param collateralAsset Collateral asset address
     * @param newLiquidationPenalty New liquidation penalty in basis points
     */
    function updateLiquidationPenalty(address syntheticAsset, address collateralAsset, uint256 newLiquidationPenalty)
        external
        onlyRiskAdmin
    {
        bytes32 pairId = _pairId(syntheticAsset, collateralAsset);
        LendingPairModule.updateLiquidationPenalty(s, pairId, newLiquidationPenalty);
    }

    /**
     * @notice Update expiry settings for a lending pair
     * @dev Only callable by assets admin
     * @param syntheticAsset Synthetic asset address
     * @param collateralAsset Collateral asset address
     * @param isExpirable Whether positions should expire
     * @param expirePeriod Expiry period in seconds (ignored if isExpirable = false)
     */
    function updatePairExpiry(address syntheticAsset, address collateralAsset, bool isExpirable, uint256 expirePeriod)
        external
        onlyAssetsAdmin
    {
        bytes32 pairId = _pairId(syntheticAsset, collateralAsset);
        LendingPairModule.updatePairExpiry(s, pairId, isExpirable, expirePeriod);
    }

    // ============================================================
    // FLASH LOAN OPERATIONS
    // ============================================================

    /**
     * @notice Execute a flash loan for a single synthetic asset
     * @dev EIP-3156 inspired interface adapted for YOLO Protocol
     *      Mints synthetic asset → calls borrower callback → burns repayment
     *      Fee is minted to treasury
     * @param borrower Contract implementing IFlashBorrower
     * @param token Synthetic asset to borrow
     * @param amount Amount to borrow (in token decimals)
     * @param data Arbitrary data passed to borrower callback
     * @return success Whether flash loan succeeded
     */
    function flashLoan(address borrower, address token, uint256 amount, bytes calldata data)
        external
        whenNotPaused
        nonReentrant
        returns (bool success)
    {
        uint256 fee;
        // Pass msg.sender as caller for privilege checking
        (success, fee) = FlashLoanModule.flashLoan(s, msg.sender, borrower, token, amount, data);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory fees = new uint256[](1);
        fees[0] = fee;

        emit FlashLoanExecuted(borrower, msg.sender, tokens, amounts, fees);
    }

    /**
     * @notice Execute a flash loan for multiple synthetic assets
     * @dev Mints all assets → calls borrower callback → burns all repayments
     *      Fees are minted to treasury
     * @param borrower Contract implementing IFlashBorrower
     * @param tokens Array of synthetic assets to borrow
     * @param amounts Array of amounts to borrow (in token decimals)
     * @param data Arbitrary data passed to borrower callback
     * @return success Whether flash loan succeeded
     */
    function flashLoanBatch(
        address borrower,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata data
    ) external whenNotPaused nonReentrant returns (bool success) {
        uint256[] memory fees;
        // Pass msg.sender as caller for privilege checking
        (success, fees) = FlashLoanModule.flashLoanBatch(s, msg.sender, borrower, tokens, amounts, data);

        // Emit event (library cannot emit events with proper context)
        emit FlashLoanExecuted(borrower, msg.sender, tokens, amounts, fees);
    }

    /**
     * @notice Execute a privileged flash loan for leverage operations
     * @dev Only callable by contracts with LOOPER_ROLE
     *      No reentrancy guard to allow callbacks to borrow/repay
     *      Used by YoloLooper for leverage/deleverage operations
     *      Borrower must be msg.sender to prevent proxy attacks
     * @param borrower Contract implementing IFlashBorrower (must be msg.sender)
     * @param token Synthetic asset to borrow
     * @param amount Amount to borrow (in token decimals)
     * @param data Arbitrary data passed to borrower callback
     * @return success Whether flash loan succeeded
     */
    function leverageFlashLoan(address borrower, address token, uint256 amount, bytes calldata data)
        external
        whenNotPaused
        onlyLooper
        returns (bool success)
    {
        // Security: Prevent loopers from proxying flash loans to arbitrary addresses
        if (borrower != msg.sender) {
            revert YoloHook__CallerNotAuthorized();
        }

        // Note: No nonReentrant modifier - allows callback to call borrow/repay
        uint256 fee;
        // Pass msg.sender (the looper) as caller for privilege checking
        (success, fee) = FlashLoanModule.flashLoan(s, msg.sender, borrower, token, amount, data);

        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory fees = new uint256[](1);
        fees[0] = fee;

        emit FlashLoanExecuted(borrower, msg.sender, tokens, amounts, fees);
    }

    /**
     * @notice Burn any pending synthetic balances accumulated from earlier swaps
     * @dev Anyone can trigger the burn; uses PoolManager.unlock to convert claims into real tokens
     */
    function burnPendingSynthetic() external whenNotPaused nonReentrant {
        if (s.pendingSyntheticToken == address(0) || s.pendingSyntheticAmount == 0) {
            revert YoloHookStorage.YoloHookStorage__NoPendingSyntheticBurn();
        }

        bytes memory callbackData =
            abi.encode(DataTypes.CallbackData({action: DataTypes.UnlockAction.SWAP, data: bytes("")}));

        poolManager.unlock(callbackData);
    }

    /**
     * @notice Update flash loan fee
     * @dev Only callable by risk admin
     * @param newFeeBps New flash loan fee in basis points (0-10000, e.g., 9 = 0.09%)
     */
    function updateFlashLoanFee(uint256 newFeeBps) external onlyRiskAdmin {
        if (newFeeBps > 10000) revert YoloHook__InvalidConfiguration(); // Max 100%
        s.flashLoanFeeBps = newFeeBps;
    }

    /**
     * @notice Update maximum flash loan amount for a synthetic asset
     * @dev Only callable by risk admin
     *      0 = flash loans disabled
     *      >0 = specific cap
     *      type(uint256).max = unlimited
     * @param syntheticToken Address of the synthetic token
     * @param newMaxFlashLoanAmount New maximum flash loan amount
     */
    function updateMaxFlashLoanAmount(address syntheticToken, uint256 newMaxFlashLoanAmount) external onlyRiskAdmin {
        FlashLoanModule.updateMaxFlashLoanAmount(s, syntheticToken, newMaxFlashLoanAmount);
    }

    // ============================================================
    // LIQUIDITY OPERATIONS (POOLMANAGER-CENTRIC)
    // ============================================================

    /**
     * @notice Add liquidity to USY-USDC anchor pool via PoolManager
     * @dev Routes through PoolManager.unlock() for Uniswap V4 router compatibility
     *      Uses min-share formula with 1% imbalance tolerance
     *      First liquidity provider locks MINIMUM_LIQUIDITY permanently
     * @param maxUsyAmount Maximum USY to deposit (18 decimals)
     * @param maxUsdcAmount Maximum USDC to deposit (native decimals)
     * @param minSUSYReceive Minimum sUSY to receive (slippage protection, 18 decimals)
     * @param receiver Address to receive sUSY LP tokens
     * @return usyUsed Actual USY deposited (18 decimals)
     * @return usdcUsed Actual USDC deposited (native decimals)
     * @return sUSYMinted LP tokens minted (18 decimals)
     */
    function addLiquidity(uint256 maxUsyAmount, uint256 maxUsdcAmount, uint256 minSUSYReceive, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted)
    {
        (bool isBootstrap, uint256 usyUsedLocal, uint256 usdcUsedLocal, uint256 sUSYMintedLocal) = StablecoinModule.addLiquidity(
            s, poolManager, msg.sender, maxUsyAmount, maxUsdcAmount, minSUSYReceive, receiver
        );

        usyUsed = usyUsedLocal;
        usdcUsed = usdcUsedLocal;
        sUSYMinted = sUSYMintedLocal;

        // Emit event
        emit LiquidityAdded(msg.sender, receiver, usyUsed, usdcUsed, sUSYMinted, isBootstrap);
    }

    /**
     * @notice Remove liquidity from USY-USDC anchor pool via PoolManager
     * @dev Routes through PoolManager.unlock() for Uniswap V4 router compatibility
     *      Burns sUSY and returns proportional USY + USDC
     * @param sUSYAmount Amount of sUSY to burn (18 decimals)
     * @param minUsyOut Minimum USY to receive (slippage protection, 18 decimals)
     * @param minUsdcOut Minimum USDC to receive (slippage protection, native decimals)
     * @param receiver Address to receive USY + USDC
     * @return usyOut Actual USY received (18 decimals)
     * @return usdcOut Actual USDC received (native decimals)
     */
    function removeLiquidity(uint256 sUSYAmount, uint256 minUsyOut, uint256 minUsdcOut, address receiver)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 usyOut, uint256 usdcOut)
    {
        (uint256 usyOutLocal, uint256 usdcOutLocal) =
            StablecoinModule.removeLiquidity(s, poolManager, msg.sender, sUSYAmount, minUsyOut, minUsdcOut, receiver);

        usyOut = usyOutLocal;
        usdcOut = usdcOutLocal;

        // Emit event
        emit LiquidityRemoved(msg.sender, receiver, sUSYAmount, usyOut, usdcOut);
    }

    /**
     * @notice PoolManager unlock callback for liquidity operations
     * @dev Only callable by PoolManager during unlock
     *      Routes to StablecoinModule library based on action type
     * @param data Encoded CallbackData with action and parameters
     * @return Encoded result data
     */
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        // Only PoolManager can call
        if (msg.sender != address(poolManager)) revert YoloHook__CallerNotAuthorized();

        DataTypes.CallbackData memory callback = abi.decode(data, (DataTypes.CallbackData));

        if (
            callback.action == DataTypes.UnlockAction.ADD_LIQUIDITY
                || callback.action == DataTypes.UnlockAction.REMOVE_LIQUIDITY
        ) {
            return StablecoinModule.handleUnlockCallback(s, poolManager, data);
        }

        if (callback.action == DataTypes.UnlockAction.SWAP) {
            return SyntheticSwapModule.handleUnlockCallback(s, poolManager, callback.data);
        }

        revert YoloHookStorage.YoloHookStorage__UnknownUnlockAction();
    }

    // ============================================================
    // MODIFY LIQUIDITY HOOKS (REVERTS - USE CUSTOM FUNCTIONS)
    // ============================================================

    /**
     * @notice Reverts PoolManager.modifyLiquidity calls
     * @dev Users MUST use YoloHook.addLiquidity() instead of PoolManager.modifyLiquidity
     *      This ensures proper accounting, sUSY minting, and reserve tracking
     */
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert YoloHookStorage.YoloHookStorage__DirectPoolManagerLiquidityNotAllowed();
    }

    /**
     * @notice Reverts PoolManager.modifyLiquidity calls
     * @dev Users MUST use YoloHook.removeLiquidity() instead of PoolManager.modifyLiquidity
     *      This ensures proper accounting, sUSY burning, and reserve tracking
     */
    function _beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert YoloHookStorage.YoloHookStorage__DirectPoolManagerLiquidityNotAllowed();
    }

    /**
     * @notice Reverts afterAddLiquidity (not used)
     * @dev All liquidity logic handled in unlock callback
     */
    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal pure override returns (bytes4, BalanceDelta) {
        revert YoloHookStorage.YoloHookStorage__DirectPoolManagerLiquidityNotAllowed();
    }

    /**
     * @notice Reverts afterRemoveLiquidity (not used)
     * @dev All liquidity logic handled in unlock callback
     */
    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal pure override returns (bytes4, BalanceDelta) {
        revert YoloHookStorage.YoloHookStorage__DirectPoolManagerLiquidityNotAllowed();
    }

    // ============================================================
    // SWAP HOOKS
    // ============================================================

    /**
     * @notice Handle beforeSwap hook - calculates and returns swap deltas
     * @dev Implements StableSwap for anchor pool, oracle-based for synthetic pools
     *      Returns BeforeSwapDelta to override PoolManager's math
     * @param sender Address initiating the swap
     * @param key PoolKey identifying the pool
     * @param params Swap parameters (direction, amount, etc.)
     * @param hookData Additional data passed from router
     * @return selector Function selector for validation
     * @return delta BeforeSwapDelta specifying token flows
     * @return lpFeeOverride LP fee override (0 = no override)
     */
    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Get pool configuration
        bytes32 poolId = PoolId.unwrap(key.toId());
        DataTypes.PoolConfiguration memory poolConfig = s._poolConfigs[poolId];

        // Route based on pool type
        if (poolConfig.isAnchorPool) {
            return _handleAnchorSwap(key, params, sender);
        } else if (poolConfig.isSyntheticPool) {
            SyntheticSwapModule.SyntheticSwapResult memory result =
                SyntheticSwapModule.executeSyntheticSwap(s, poolManager, key, params);

            emit SyntheticSwap(
                poolId,
                sender,
                result.tokenIn,
                result.tokenOut,
                result.grossInput,
                result.netInput,
                result.amountOut,
                result.feeAmount,
                result.exactInput
            );

            return (result.selector, result.delta, result.lpFeeOverride);
        } else {
            revert YoloHookStorage.YoloHookStorage__UnknownPool();
        }
    }

    /**
     * @notice Handle anchor pool swaps (USY-USDC StableSwap)
     * @dev Delegates swap logic to SwapModule, emits event in hook context
     *      Integrates with optional stability tracker for peg maintenance incentives
     * @param key PoolKey identifying the anchor pool
     * @param params Swap parameters
     * @param sender Address initiating the swap
     * @return selector Function selector
     * @return delta BeforeSwapDelta specifying token flows
     * @return lpFeeOverride Always 0 (fees handled in hook)
     */
    function _handleAnchorSwap(PoolKey calldata key, SwapParams calldata params, address sender)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // Stability tracking - capture reserves BEFORE swap
        if (address(s.stabilityTracker) != address(0)) {
            // V1.0 TEMPORARY SOLUTION: Using tx.origin for EOA attribution
            // KNOWN LIMITATION: AA wallets, Safe wallets, CowSwap, and bundlers
            // will show the relayer's EOA instead of the end user
            //
            // WHY tx.origin over sender:
            // - Uniswap router has no claiming or distribution logic
            // - Using sender would permanently lock rewards at router address
            // - Using tx.origin at least credits a claimable EOA (even if sometimes wrong)
            // - Both approaches fail for AA/bundlers - router sees relayers as sender too
            //
            // MITIGATION: Use excludeFromIncentives() to block known bundler/relayer addresses
            //
            // TODO V1.1: Replace with hookData decoding when custom router is deployed
            // address swapper = _extractOriginalSwapper(hookData);

            address swapper = tx.origin;
            s.stabilityTracker.beforeSwapUpdate(swapper, s.totalAnchorReserveUSDC, s.totalAnchorReserveUSY);
        }

        // Execute the swap
        SwapModule.AnchorSwapResult memory result = SwapModule.executeAnchorSwap(s, poolManager, key, params);

        // Stability tracking - capture reserves AFTER swap
        if (address(s.stabilityTracker) != address(0)) {
            // V1.0 TEMPORARY: tx.origin for EOA attribution (see comment above)
            // TODO V1.1: address swapper = _extractOriginalSwapper(hookData);
            address swapper = tx.origin;
            s.stabilityTracker.afterSwapUpdate(swapper, s.totalAnchorReserveUSDC, s.totalAnchorReserveUSY);
        }

        emit AnchorSwap(
            PoolId.unwrap(key.toId()),
            sender,
            result.delta0,
            result.delta1,
            s.totalAnchorReserveUSY,
            s.totalAnchorReserveUSDC,
            result.feeAmount
        );

        return (result.selector, result.delta, result.lpFeeOverride);
    }

    /**
     * @notice Handle afterSwap hook
     * @dev All swap logic handled in beforeSwap, this cleans up pending markers
     * @param sender Address initiating the swap
     * @param key PoolKey identifying the pool
     * @param params Swap parameters
     * @param delta Realized BalanceDelta from the swap
     * @param hookData Additional data passed from router
     * @return selector Function selector for validation
     * @return hookDeltaUnspent Always 0 (no unspent hook delta)
     */
    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        SwapModule.afterSwapCleanup(s);
        return (this.afterSwap.selector, 0);
    }

    // ============================================================
    // VIEW DELEGATION
    // ============================================================

    fallback() external {
        _delegateView();
    }

    function _delegateView() private {
        address impl = viewImplementation;
        if (impl == address(0)) {
            revert YoloHook__ViewImplementationNotSet();
        }
        assembly {
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ============================================================
    // UPGRADE AUTHORIZATION
    // ============================================================

    /**
     * @notice Authorizes contract upgrades
     * @dev Only DEFAULT_ADMIN_ROLE can upgrade YoloHook
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyDefaultAdmin {}
}
