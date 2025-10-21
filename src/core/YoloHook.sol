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
import {YoloHookStorage, AppStorage} from "./YoloHookStorage.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {SyntheticAssetModule} from "../libraries/SyntheticAssetModule.sol";
import {LendingPairModule} from "../libraries/LendingPairModule.sol";
import {LiquidationModule} from "../libraries/LiquidationModule.sol";
import {FlashLoanModule} from "../libraries/FlashLoanModule.sol";
import {StablecoinModule} from "../libraries/StablecoinModule.sol";
import {SwapModule} from "../libraries/SwapModule.sol";
import {SyntheticSwapModule} from "../libraries/SyntheticSwapModule.sol";
import {BootstrapModule} from "../libraries/BootstrapModule.sol";
import {DecimalNormalization} from "../libraries/DecimalNormalization.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
contract YoloHook is BaseHook, ReentrancyGuard, YoloHookStorage, UUPSUpgradeable {
    // ========================
    // LIBRARY USAGE
    // ========================

    using SyntheticAssetModule for AppStorage;
    using LendingPairModule for AppStorage;
    using DecimalNormalization for uint256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
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

    // ========================
    // IMMUTABLE STORAGE
    // ========================

    /// @notice ACL Manager for role-based access control
    /// @dev Immutable is proxy-safe (stored in bytecode, not storage)
    IACLManager public immutable ACL_MANAGER;

    // Note: State variables moved to YoloHookStorage for upgradeability

    // ========================
    // EVENTS
    // ========================

    event Paused(address indexed account);
    event Unpaused(address indexed account);
    event OracleUpdated(address indexed newOracle);
    event YLPVaultUpdated(address indexed newVault);
    event TreasuryUpdated(address indexed newTreasury);
    event SyntheticAssetUpgraded(address indexed syntheticAsset, address indexed newImplementation);
    event AnchorSwapFeeUpdated(uint256 newFeeBps);
    event SyntheticSwapFeeUpdated(uint256 newFeeBps);
    event AnchorAmplificationUpdated(uint256 newAmplification);
    event PrivilegedLiquidatorToggled(bool enabled);
    event YLPFundedWithUSY(address indexed callerAsset, uint256 amount);

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

    // ========================
    // MODIFIERS
    // ========================

    /**
     * @notice Ensure caller has PAUSER role
     * @dev Used for emergency pause/unpause functions
     */
    modifier onlyPauser() {
        if (!ACL_MANAGER.hasRole(PAUSER_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
        _;
    }

    /**
     * @notice Ensure caller has ASSETS_ADMIN role
     * @dev Used for creating synthetic assets and configuring asset parameters
     */
    modifier onlyAssetsAdmin() {
        if (!ACL_MANAGER.hasRole(ASSETS_ADMIN_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
        _;
    }

    /**
     * @notice Ensure caller has RISK_ADMIN role
     * @dev Used for configuring risk parameters (LTV, interest rates, liquidation penalties)
     */
    modifier onlyRiskAdmin() {
        if (!ACL_MANAGER.hasRole(RISK_ADMIN_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
        _;
    }

    /**
     * @notice Ensure protocol is not paused
     * @dev Used to protect user-facing functions during emergency pause
     */
    modifier whenNotPaused() {
        if (s._paused) {
            revert YoloHook__ProtocolPaused();
        }
        _;
    }

    /**
     * @notice Ensure protocol is paused
     * @dev Used to ensure unpause is only called when protocol is paused
     */
    modifier whenPaused() {
        if (!s._paused) {
            revert YoloHook__ProtocolNotPaused();
        }
        _;
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
     * @notice Check if protocol is currently paused
     * @return True if protocol is paused, false otherwise
     */
    function paused() public view returns (bool) {
        return s._paused;
    }

    /**
     * @notice Returns the oracle module address
     * @return Oracle module address
     */
    function yoloOracle() external view returns (IYoloOracle) {
        return s.yoloOracle;
    }

    /**
     * @notice Returns the USY stablecoin address
     * @return USY stablecoin address
     */
    function usy() external view returns (address) {
        return s.usy;
    }

    /**
     * @notice Returns the YLP vault address
     * @return YLP vault address
     */
    function ylpVault() external view returns (address) {
        return s.ylpVault;
    }

    /**
     * @notice Preview anchor pool swap output
     * @dev Simulates a swap without executing it
     *      Delegates to SwapModule for calculation
     * @param zeroForOne Direction of swap (true = token0 -> token1)
     * @param amountIn Input amount (in native decimals)
     * @return amountOut Output amount (in 18 decimals normalized)
     * @return feeAmount Fee amount (in 18 decimals normalized)
     */
    function previewAnchorSwap(bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        return SwapModule.previewAnchorSwap(s, s._anchorPoolKey, zeroForOne, amountIn);
    }

    /**
     * @notice Get total anchor pool reserve for USY
     * @return Total USY reserve (18 decimals)
     */
    function totalAnchorReserveUSY() external view returns (uint256) {
        return s.totalAnchorReserveUSY;
    }

    /**
     * @notice Get total anchor pool reserve for USDC
     * @return Total USDC reserve (18 decimals normalized)
     */
    function totalAnchorReserveUSDC() external view returns (uint256) {
        return s.totalAnchorReserveUSDC;
    }

    /**
     * @notice Get pending synthetic burn state
     * @return token Synthetic asset awaiting burn
     * @return amount Amount of synthetic asset pending burn
     */
    function getPendingSyntheticBurn() external view returns (address token, uint256 amount) {
        return (s.pendingSyntheticToken, s.pendingSyntheticAmount);
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
     * @notice Upgrades a synthetic asset implementation
     * @dev Only callable by default admin (via UUPS authorization)
     *      YoloHook holds upgrade power over all synthetic assets it created
     * @param syntheticAsset Address of the synthetic asset to upgrade
     * @param newImplementation Address of the new implementation
     */
    function upgradeSyntheticAsset(address syntheticAsset, address newImplementation)
        external
        onlyAssetsAdmin
        nonReentrant
    {
        if (!s._isYoloAsset[syntheticAsset]) revert YoloHook__NotYoloAsset();
        if (newImplementation == address(0)) revert YoloHook__InvalidAddress();

        UUPSUpgradeable(syntheticAsset).upgradeToAndCall(newImplementation, "");
        emit SyntheticAssetUpgraded(syntheticAsset, newImplementation);
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
     * @dev Only callable by risk admin (oracle is swappable)
     * @param _yoloOracle New oracle address
     */
    function updateOracle(IYoloOracle _yoloOracle) external onlyRiskAdmin {
        if (address(_yoloOracle) == address(0)) revert YoloHook__InvalidOracle();
        s.yoloOracle = _yoloOracle;
        emit OracleUpdated(address(_yoloOracle));
    }

    /**
     * @notice Updates the YLP vault
     * @dev Only callable by assets admin
     * @param _ylpVault New YLP vault address
     */
    function updateYLPVault(address _ylpVault) external onlyAssetsAdmin {
        if (_ylpVault == address(0)) revert YoloHook__InvalidAddress();
        s.ylpVault = _ylpVault;
        emit YLPVaultUpdated(_ylpVault);
    }

    /**
     * @notice Updates the treasury address
     * @dev Only callable by assets admin
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyAssetsAdmin {
        if (_treasury == address(0)) revert YoloHook__InvalidAddress();
        s.treasury = _treasury;
        emit TreasuryUpdated(_treasury);
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

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Returns all created synthetic assets
     * @return Array of synthetic asset addresses
     */
    function getAllSyntheticAssets() external view returns (address[] memory) {
        return s._yoloAssets;
    }

    /**
     * @notice Returns configuration for a synthetic asset
     * @param syntheticToken Address of the synthetic token
     * @return Configuration struct
     */
    function getAssetConfiguration(address syntheticToken) external view returns (DataTypes.AssetConfiguration memory) {
        return s._assetConfigs[syntheticToken];
    }

    /**
     * @notice Returns configuration for a lending pair
     * @param syntheticAsset The synthetic asset
     * @param collateralAsset The collateral asset
     * @return Configuration struct
     */
    function getPairConfiguration(address syntheticAsset, address collateralAsset)
        external
        view
        returns (DataTypes.PairConfiguration memory)
    {
        bytes32 pairId = keccak256(abi.encodePacked(syntheticAsset, collateralAsset));
        return s._pairConfigs[pairId];
    }

    // ========================
    // ANCHOR POOL & sUSY VIEWS
    // ========================

    /**
     * @notice Get current anchor pool reserves (raw values)
     * @dev USY in 18 decimals, USDC in native decimals (6 or 18 depending on chain)
     * @return reserveUSY USY reserves (18 decimals)
     * @return reserveUSDC USDC reserves (native decimals)
     */
    function getAnchorReserves() external view returns (uint256 reserveUSY, uint256 reserveUSDC) {
        return (s.totalAnchorReserveUSY, s.totalAnchorReserveUSDC);
    }

    /**
     * @notice Get anchor pool reserves normalized to 18 decimals
     * @dev Both values returned in 18 decimals for consistent calculations
     * @return reserveUSY18 USY reserves (18 decimals)
     * @return reserveUSDC18 USDC reserves (18 decimals normalized)
     */
    function getAnchorReservesNormalized18() external view returns (uint256 reserveUSY18, uint256 reserveUSDC18) {
        reserveUSY18 = s.totalAnchorReserveUSY; // Already 18 decimals
        reserveUSDC18 = s.totalAnchorReserveUSDC.to18(s.usdcDecimals);
    }

    /**
     * @notice Get USDC decimals (chain-dependent)
     * @dev Retrieved during initialize() from USDC contract
     * @return decimals USDC decimals (typically 6, but can be 18 on some chains)
     */
    function usdcDecimals() external view returns (uint8) {
        return s.usdcDecimals;
    }

    /**
     * @notice Get USDC token address
     * @return usdc address
     */
    function usdc() external view returns (address) {
        return s.usdc;
    }

    /**
     * @notice Exposes PoolManager address for integrations (e.g., vault add/remove liquidity)
     */
    function poolManagerAddress() external view returns (address) {
        return address(poolManager);
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
    }

    /**
     * @notice Get sUSY token address
     * @return sUSY address
     */
    function sUSY() external view returns (address) {
        return s.sUSY;
    }

    /**
     * @notice Preview sUSY minted for adding liquidity
     * @dev Delegates to StablecoinModule for calculation
     * @param usyIn18 USY amount to deposit (18 decimals)
     * @param usdcIn18 USDC amount to deposit (18 decimals normalized)
     * @return sUSYToMint Expected sUSY tokens (18 decimals)
     */
    function previewAddLiquidity(uint256 usyIn18, uint256 usdcIn18) external view returns (uint256 sUSYToMint) {
        return StablecoinModule.previewAddLiquidity(s, usyIn18, usdcIn18);
    }

    /**
     * @notice Preview token amounts for removing liquidity
     * @dev Delegates to StablecoinModule for calculation
     * @param sUSYAmount sUSY to burn
     * @return usyOut18 USY to receive (18 decimals)
     * @return usdcOut18 USDC to receive (18 decimals normalized)
     */
    function previewRemoveLiquidity(uint256 sUSYAmount) external view returns (uint256 usyOut18, uint256 usdcOut18) {
        return StablecoinModule.previewRemoveLiquidity(s, sUSYAmount);
    }

    /**
     * @notice Checks if address is a YOLO synthetic asset
     * @param syntheticToken Address to check
     * @return True if asset is a YOLO synthetic asset
     */
    function isYoloAsset(address syntheticToken) external view returns (bool) {
        return s._isYoloAsset[syntheticToken];
    }

    /**
     * @notice Checks if address is a whitelisted collateral
     * @param collateralAsset Address to check
     * @return True if asset is whitelisted as collateral
     */
    function isWhitelistedCollateral(address collateralAsset) external view returns (bool) {
        return LendingPairModule.isWhitelistedCollateral(s, collateralAsset);
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
        if (onBehalfOf != msg.sender) {
            if (!ACL_MANAGER.hasRole(LOOPER_ROLE, msg.sender)) {
                revert YoloHook__CallerNotAuthorized();
            }
        }

        s.borrowSyntheticAsset(yoloAsset, borrowAmount, collateral, collateralAmount, onBehalfOf);
    }

    /**
     * @notice Repay borrowed synthetic assets
     * @dev Follows Aave V3 onBehalfOf pattern for debt repayment
     *      - If onBehalfOf != msg.sender, caller must have LOOPER_ROLE
     *      - Tokens are burned from msg.sender (payer)
     *      - Debt reduction is applied to onBehalfOf's position (beneficiary)
     *      - Collateral returned to onBehalfOf if fully repaid
     * @param yoloAsset Synthetic asset to repay
     * @param collateral Collateral asset
     * @param repayAmount Amount to repay (18 decimals)
     * @param onBehalfOf Address whose debt to reduce (tokens burned from msg.sender)
     */
    function repay(address yoloAsset, address collateral, uint256 repayAmount, address onBehalfOf)
        external
        whenNotPaused
        nonReentrant
    {
        // Authorization: only LOOPER_ROLE can repay on behalf of others
        if (onBehalfOf != msg.sender) {
            if (!ACL_MANAGER.hasRole(LOOPER_ROLE, msg.sender)) {
                revert YoloHook__CallerNotAuthorized();
            }
        }

        s.repaySyntheticAsset(collateral, yoloAsset, repayAmount, true, onBehalfOf); // true = claim collateral if fully repaid
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
        if (onBehalfOf != msg.sender) {
            if (!ACL_MANAGER.hasRole(LOOPER_ROLE, msg.sender)) {
                revert YoloHook__CallerNotAuthorized();
            }
        }

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
        if (onBehalfOf != msg.sender) {
            if (!ACL_MANAGER.hasRole(LOOPER_ROLE, msg.sender)) {
                revert YoloHook__CallerNotAuthorized();
            }
        }

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
     * @notice Get user position data
     * @param user User address
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @return position User position struct
     */
    function getUserPosition(address user, address collateral, address yoloAsset)
        external
        view
        returns (DataTypes.UserPosition memory)
    {
        return s.positions[user][collateral][yoloAsset];
    }

    /**
     * @notice Get current debt for a position with accrued interest
     * @param user User address
     * @param collateral Collateral asset
     * @param yoloAsset Synthetic asset
     * @return Current debt amount (18 decimals)
     */
    function getPositionDebt(address user, address collateral, address yoloAsset) external view returns (uint256) {
        return LendingPairModule.getPositionDebt(s, user, collateral, yoloAsset);
    }

    /**
     * @notice Get user account data across all positions
     * @dev Delegates to LendingPairModule for calculation
     * @param user User address
     * @return totalCollateralUSD Total collateral value (8 decimals)
     * @return totalDebtUSD Total debt value (8 decimals)
     * @return ltv Current LTV in basis points
     */
    function getUserAccountData(address user)
        external
        view
        returns (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 ltv)
    {
        return LendingPairModule.getUserAccountData(s, user);
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
        bytes32 pairId = keccak256(abi.encodePacked(syntheticAsset, collateralAsset));
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
        bytes32 pairId = keccak256(abi.encodePacked(syntheticAsset, collateralAsset));
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
        bytes32 pairId = keccak256(abi.encodePacked(syntheticAsset, collateralAsset));
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
        (success, fee) = FlashLoanModule.flashLoan(s, borrower, token, amount, data);

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
        (success, fees) = FlashLoanModule.flashLoanBatch(s, borrower, tokens, amounts, data);

        // Emit event (library cannot emit events with proper context)
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

    /**
     * @notice Preview flash loan fee for a single asset
     * @param token Synthetic asset address
     * @param amount Amount to borrow
     * @return fee Fee amount in token decimals
     */
    function previewFlashLoanFee(address token, uint256 amount) external view returns (uint256 fee) {
        return FlashLoanModule.previewFlashLoanFee(s, token, amount);
    }

    /**
     * @notice Get maximum flash loan amount for an asset
     * @param token Synthetic asset address
     * @return maxAmount Maximum flash loan amount (0 = disabled, >0 = cap, type(uint256).max = unlimited)
     */
    function maxFlashLoan(address token) external view returns (uint256 maxAmount) {
        return FlashLoanModule.maxFlashLoan(s, token);
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
        SwapModule.AnchorSwapResult memory result = SwapModule.executeAnchorSwap(s, poolManager, key, params);
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
    // UPGRADE AUTHORIZATION
    // ============================================================

    /**
     * @notice Authorizes contract upgrades
     * @dev Only default admin can upgrade YoloHook
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyAssetsAdmin {}
}
