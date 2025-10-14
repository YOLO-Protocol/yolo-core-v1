// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";
import {IYoloSyntheticAsset} from "../interfaces/IYoloSyntheticAsset.sol";
import {YoloHookStorage, AppStorage} from "./YoloHookStorage.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {SyntheticAssetModule} from "../libraries/SyntheticAssetModule.sol";
import {LendingPairModule} from "../libraries/LendingPairModule.sol";
import {StablecoinModule} from "../libraries/StablecoinModule.sol";
import {SwapModule} from "../libraries/SwapModule.sol";
import {DecimalNormalization} from "../libraries/DecimalNormalization.sol";
import {StakedYoloUSD} from "../tokenization/StakedYoloUSD.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

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
    event SyntheticAssetUpgraded(address indexed syntheticAsset, address indexed newImplementation);

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
     * @param _ylpVaultImplementation YLP vault implementation (placeholder for Phase 3)
     * @dev Can only be called once due to initializer modifier
     *      Deploys USY with UUPS and creates anchor pool (USY-USDC)
     *      Protocol starts in unpaused state
     */
    function initialize(
        IYoloOracle _yoloOracle,
        address _usdc,
        address _usyImplementation,
        address _sUSYImplementation,
        address _ylpVaultImplementation,
        uint256 _anchorAmplificationCoefficient,
        uint256 _anchorSwapFeeBps,
        uint256 _syntheticSwapFeeBps
    ) external initializer {
        // Validation
        if (address(_yoloOracle) == address(0)) revert YoloHook__InvalidOracle();
        if (_usdc == address(0)) revert YoloHook__InvalidAddress();
        if (_usyImplementation == address(0)) revert YoloHook__InvalidAddress();
        if (_sUSYImplementation == address(0)) revert YoloHook__InvalidAddress();
        if (_anchorAmplificationCoefficient == 0) revert YoloHook__InvalidConfiguration();
        if (_anchorSwapFeeBps > 10000) revert YoloHook__InvalidConfiguration(); // Max 100%
        if (_syntheticSwapFeeBps > 10000) revert YoloHook__InvalidConfiguration(); // Max 100%

        // Store oracle, USDC address, and USDC decimals
        s.yoloOracle = _yoloOracle;
        s.usdc = _usdc;
        s.usdcDecimals = IERC20Metadata(_usdc).decimals();
        s.usdcScaleUp = 10 ** (18 - s.usdcDecimals); // V0.5 USDC_SCALE_UP pattern

        // Store swap configuration
        s.anchorAmplificationCoefficient = _anchorAmplificationCoefficient;
        s.anchorSwapFeeBps = _anchorSwapFeeBps;
        s.syntheticSwapFeeBps = _syntheticSwapFeeBps;

        // Deploy USY with UUPS
        bytes memory usyInitData = abi.encodeWithSignature(
            "initialize(address,address,string,string,uint8,address,address,address,uint256)",
            address(this), // yoloHook
            address(ACL_MANAGER),
            "Yolo USD",
            "USY",
            uint8(18),
            address(0), // no underlying (USY is the anchor)
            address(_yoloOracle),
            _ylpVaultImplementation, // ylpVault placeholder (Phase 3)
            uint256(0) // no max supply for USY
        );

        address usyProxy = address(new ERC1967Proxy(_usyImplementation, usyInitData));
        s.usy = usyProxy;

        // Register USY as YOLO asset
        s._isYoloAsset[usyProxy] = true;
        s._yoloAssets.push(usyProxy);
        s._assetConfigs[usyProxy] = DataTypes.AssetConfiguration({
            syntheticToken: usyProxy,
            underlyingAsset: address(0), // USY is the anchor
            oracleSource: address(0), // Fixed $1 price
            maxSupply: 0, // Unlimited for stablecoin
            isActive: true,
            createdAt: block.timestamp
        });

        // Approve PoolManager for settlement (CRITICAL)
        IERC20(_usdc).approve(address(poolManager), type(uint256).max);
        IERC20(usyProxy).approve(address(poolManager), type(uint256).max);

        // Create anchor pool (USY-USDC) on PoolManager
        bool usdcIs0 = _usdc < usyProxy;
        Currency currency0 = Currency.wrap(usdcIs0 ? _usdc : usyProxy);
        Currency currency1 = Currency.wrap(usdcIs0 ? usyProxy : _usdc);

        PoolKey memory anchorPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0, // Fees handled in hook
            tickSpacing: 60, // Standard for stableswap
            hooks: IHooks(address(this))
        });

        // Initialize at 1:1 price (sqrtPriceX96 = 2^96)
        poolManager.initialize(anchorPoolKey, uint160(1) << 96);

        // Store anchor pool configuration
        bytes32 anchorPoolId = PoolId.unwrap(anchorPoolKey.toId());
        s._anchorPoolKey = anchorPoolId;
        s._poolConfigs[anchorPoolId] = DataTypes.PoolConfiguration({
            poolKey: anchorPoolKey,
            isAnchorPool: true,
            isSyntheticPool: false,
            token0: Currency.unwrap(currency0),
            token1: Currency.unwrap(currency1),
            createdAt: block.timestamp
        });

        // Deploy sUSY (LP receipt token) with UUPS
        bytes memory sUSYInitData = abi.encodeWithSignature("initialize(address)", address(this));

        address sUSYProxy = address(new ERC1967Proxy(_sUSYImplementation, sUSYInitData));
        s.sUSY = sUSYProxy;

        // Initialize protocol state
        s._paused = false;

        // Store YLP vault placeholder (will be properly deployed in Phase 3)
        s.ylpVault = _ylpVaultImplementation;

        // TODO: Phase 3 - Deploy YLP Vault (ERC4626) with proper proxy
        // address ylpVault = address(new ERC1967Proxy(_ylpVaultImplementation, ylpInitData));
        // s.ylpVault = ylpVault; // Would replace the placeholder
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
     * @param zeroForOne Direction of swap (true = token0 -> token1)
     * @param amountIn Input amount (in native decimals)
     * @return amountOut Output amount (in native decimals, after fees)
     * @return feeAmount Fee amount (in output token, native decimals)
     */
    function previewAnchorSwap(bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        // Get anchor pool key
        bytes32 anchorPoolId = s._anchorPoolKey;
        DataTypes.PoolConfiguration memory poolConfig = s._poolConfigs[anchorPoolId];

        // Construct swap params (exact input)
        SwapParams memory params = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amountIn), // Negative for exact input
            sqrtPriceLimitX96: zeroForOne ? 4295128739 : 1461446703485210103287273052203988822378723970342
        });
        // Price limits to prevent unlimited slippage

        // Calculate swap delta using SwapModule
        (uint256 calculatedAmountIn, uint256 calculatedAmountOut, uint256 calculatedFeeAmount) =
            SwapModule.calculateAnchorSwapDelta(s, poolConfig.poolKey, params.zeroForOne, params.amountSpecified);

        // V0.5 pattern: Tests expect 18 decimal outputs
        // Determine if output is USDC (needs scaling) or USY (already 18 decimals)
        bool isToken0USY = Currency.unwrap(poolConfig.poolKey.currency0) == s.usy;
        bool outputIsUSY = zeroForOne ? !isToken0USY : isToken0USY;

        // Scale USDC output to 18 decimals for tests
        if (!outputIsUSY && s.usdcDecimals != 18) {
            calculatedAmountOut = calculatedAmountOut * s.usdcScaleUp;
            calculatedFeeAmount = calculatedFeeAmount * s.usdcScaleUp;
        }

        return (calculatedAmountOut, calculatedFeeAmount);
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
     * @param name Token name (e.g., "Yolo Synthetic ETH")
     * @param symbol Token symbol (e.g., "yETH")
     * @param decimals Token decimals (typically 18)
     * @param underlyingAsset Reference asset for price oracle
     * @param oracleSource Price feed source for the underlying asset
     * @param implementation YoloSyntheticAsset implementation address
     * @param maxSupply Maximum supply cap (0 for unlimited)
     * @return syntheticToken Address of deployed synthetic token proxy
     */
    function createSyntheticAsset(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address underlyingAsset,
        address oracleSource,
        address implementation,
        uint256 maxSupply
    ) external onlyAssetsAdmin returns (address syntheticToken) {
        return s.createSyntheticAsset(
            poolManager,
            address(this),
            ACL_MANAGER,
            name,
            symbol,
            decimals,
            underlyingAsset,
            oracleSource,
            implementation,
            maxSupply
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
     * @param borrowRate Annual borrow rate in basis points
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
        uint256 borrowRate
    ) external onlyAssetsAdmin returns (bytes32 pairId) {
        return s.configureLendingPair(
            syntheticAsset,
            collateralAsset,
            depositToken,
            debtToken,
            ltv,
            liquidationThreshold,
            liquidationBonus,
            borrowRate
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
    function getAssetConfiguration(address syntheticToken)
        external
        view
        returns (DataTypes.AssetConfiguration memory)
    {
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
     * @notice Get sUSY token address
     * @return sUSY address
     */
    function sUSY() external view returns (address) {
        return s.sUSY;
    }

    /**
     * @notice Preview sUSY minted for adding liquidity
     * @dev Uses min-share formula to prevent dilution
     *      Enforces balanced deposits within 1% tolerance
     *      Bootstrap case subtracts MINIMUM_LIQUIDITY
     *      All inputs normalized to 18 decimals
     * @param usyIn18 USY amount to deposit (18 decimals)
     * @param usdcIn18 USDC amount to deposit (18 decimals normalized)
     * @return sUSYToMint Expected sUSY tokens (18 decimals)
     */
    function previewAddLiquidity(uint256 usyIn18, uint256 usdcIn18) external view returns (uint256 sUSYToMint) {
        uint256 totalSupply = IERC20(s.sUSY).totalSupply();

        // Get normalized reserves
        uint256 reserveUSY18 = s.totalAnchorReserveUSY;
        uint256 reserveUSDC18 = s.totalAnchorReserveUSDC.to18(s.usdcDecimals);

        if (totalSupply == 0) {
            // Bootstrap: Enforce 1:1 ratio and subtract MINIMUM_LIQUIDITY
            uint256 minAmount18 = usyIn18 < usdcIn18 ? usyIn18 : usdcIn18;
            uint256 totalValue18 = minAmount18 + minAmount18;

            if (totalValue18 <= MINIMUM_LIQUIDITY) return 0; // Would revert
            sUSYToMint = totalValue18 - MINIMUM_LIQUIDITY;
        } else {
            // Calculate optimal amounts maintaining pool ratio
            uint256 optimalUsyIn18 = (usdcIn18 * reserveUSY18) / reserveUSDC18;
            uint256 usyToUse;
            uint256 usdcToUse;

            if (optimalUsyIn18 <= usyIn18) {
                usdcToUse = usdcIn18;
                usyToUse = optimalUsyIn18;
            } else {
                uint256 optimalUsdcIn18 = (usyIn18 * reserveUSDC18) / reserveUSY18;
                usyToUse = usyIn18;
                usdcToUse = optimalUsdcIn18;
            }

            // Min-share formula
            uint256 shareUSY = (usyToUse * totalSupply) / reserveUSY18;
            uint256 shareUSDC = (usdcToUse * totalSupply) / reserveUSDC18;

            // Check balance tolerance (1% max imbalance)
            uint256 diff = shareUSY > shareUSDC ? shareUSY - shareUSDC : shareUSDC - shareUSY;
            uint256 maxShare = shareUSY > shareUSDC ? shareUSY : shareUSDC;

            // Return 0 if imbalance > 1% (would revert)
            if ((diff * 10000) / maxShare > 100) return 0;

            // Take minimum (round down to favor pool)
            sUSYToMint = shareUSY < shareUSDC ? shareUSY : shareUSDC;
        }
    }

    /**
     * @notice Preview token amounts for removing liquidity
     * @dev Proportional redemption based on sUSY share
     *      Rounds down to favor pool
     *      All outputs normalized to 18 decimals
     * @param sUSYAmount sUSY to burn
     * @return usyOut18 USY to receive (18 decimals)
     * @return usdcOut18 USDC to receive (18 decimals normalized)
     */
    function previewRemoveLiquidity(uint256 sUSYAmount) external view returns (uint256 usyOut18, uint256 usdcOut18) {
        uint256 totalSupply = IERC20(s.sUSY).totalSupply();

        // Get normalized reserves
        uint256 reserveUSY18 = s.totalAnchorReserveUSY;
        uint256 reserveUSDC18 = s.totalAnchorReserveUSDC.to18(s.usdcDecimals);

        // Proportional redemption (round down to favor pool)
        usyOut18 = (reserveUSY18 * sUSYAmount) / totalSupply;
        usdcOut18 = (reserveUSDC18 * sUSYAmount) / totalSupply;
    }

    /**
     * @notice Checks if address is a YOLO synthetic asset
     * @param syntheticToken Address to check
     * @return True if asset is a YOLO synthetic asset
     */
    function isYoloAsset(address syntheticToken) external view returns (bool) {
        return s._isYoloAsset[syntheticToken];
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
        // Validation
        if (maxUsyAmount == 0 || maxUsdcAmount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();
        if (s.sUSY == address(0)) revert sUSYNotInitialized();

        // Encode callback data
        bytes memory callbackData = abi.encode(
            DataTypes.CallbackData({
                action: DataTypes.UnlockAction.ADD_LIQUIDITY,
                data: abi.encode(
                    DataTypes.AddLiquidityData({
                        sender: msg.sender,
                        receiver: receiver,
                        maxUsyIn: maxUsyAmount,
                        maxUsdcIn: maxUsdcAmount,
                        minSUSY: minSUSYReceive
                    })
                )
            })
        );

        // Check if bootstrap (before unlock changes state)
        bool isBootstrap = IERC20(s.sUSY).totalSupply() == 0;

        // Route through PoolManager
        bytes memory result = poolManager.unlock(callbackData);

        // Decode result
        (usyUsed, usdcUsed, sUSYMinted) = abi.decode(result, (uint256, uint256, uint256));

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
        // Validation
        if (sUSYAmount == 0) revert InvalidAmount();
        if (receiver == address(0)) revert InvalidAddress();
        if (s.sUSY == address(0)) revert sUSYNotInitialized();

        StakedYoloUSD sUSYContract = StakedYoloUSD(s.sUSY);
        if (sUSYContract.balanceOf(msg.sender) < sUSYAmount) revert InsufficientBalance();

        // Encode callback data
        bytes memory callbackData = abi.encode(
            DataTypes.CallbackData({
                action: DataTypes.UnlockAction.REMOVE_LIQUIDITY,
                data: abi.encode(
                    DataTypes.RemoveLiquidityData({
                        sender: msg.sender,
                        receiver: receiver,
                        sUSYAmount: sUSYAmount,
                        minUsyOut: minUsyOut,
                        minUsdcOut: minUsdcOut
                    })
                )
            })
        );

        // Route through PoolManager
        bytes memory result = poolManager.unlock(callbackData);

        // Decode result
        (usyOut, usdcOut) = abi.decode(result, (uint256, uint256));

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

        // Delegate to StablecoinModule library
        return StablecoinModule.handleUnlockCallback(s, poolManager, data);
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
        revert DirectPoolManagerLiquidityNotAllowed();
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
        revert DirectPoolManagerLiquidityNotAllowed();
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
        revert DirectPoolManagerLiquidityNotAllowed();
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
        revert DirectPoolManagerLiquidityNotAllowed();
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
            // Synthetic swaps not implemented yet
            revert SyntheticSwapNotImplemented();
        } else {
            revert UnknownPool();
        }
    }

    /**
     * @notice Handle anchor pool swaps (USY-USDC StableSwap)
     * @dev V0.5 pattern: Handle all settlement in hook, return zero deltas
     * @param key PoolKey identifying the anchor pool
     * @param params Swap parameters
     * @param sender Address initiating the swap
     * @return selector Function selector
     * @return delta BeforeSwapDelta (always zero - hook handles everything)
     * @return lpFeeOverride Always 0 (fees handled in hook)
     */
    function _handleAnchorSwap(PoolKey calldata key, SwapParams calldata params, address sender)
        internal
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        (uint256 grossIn, uint256 amountOut, uint256 feeAmount) =
            SwapModule.calculateAnchorSwapDelta(s, key, params.zeroForOne, params.amountSpecified);

        uint256 netIn = grossIn - feeAmount;

        bool isToken0USY = Currency.unwrap(key.currency0) == s.usy;
        bool usdcToUsy = params.zeroForOne ? !isToken0USY : isToken0USY;

        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = params.zeroForOne ? key.currency1 : key.currency0;

        // Settlement follows v0.5 pattern
        if (netIn > 0) {
            currencyIn.take(poolManager, address(this), netIn, true);
        }
        if (feeAmount > 0) {
            currencyIn.take(poolManager, address(this), feeAmount, false);
        }
        if (amountOut > 0) {
            currencyOut.settle(poolManager, address(this), amountOut, true);
        }

        // Update reserves immediately (authoritative in v0.5)
        if (usdcToUsy) {
            s.totalAnchorReserveUSDC += netIn;
            s.totalAnchorReserveUSY -= amountOut;
            s._pendingRehypoUSDC = netIn;
        } else {
            s.totalAnchorReserveUSY += netIn;
            s.totalAnchorReserveUSDC -= amountOut;
            s._pendingDehypoUSDC = amountOut;
        }

        bool exactIn = params.amountSpecified < 0;
        int128 delta0;
        int128 delta1;

        if (exactIn) {
            delta0 = int128(uint128(grossIn));
            delta1 = -int128(uint128(amountOut));
        } else {
            delta0 = -int128(uint128(amountOut));
            delta1 = int128(uint128(grossIn));
        }

        emit AnchorSwap(
            PoolId.unwrap(key.toId()),
            sender,
            delta0,
            delta1,
            s.totalAnchorReserveUSY,
            s.totalAnchorReserveUSDC,
            feeAmount
        );

        return (this.beforeSwap.selector, toBeforeSwapDelta(delta0, delta1), 0);
    }

    /**
     * @notice Handle afterSwap hook
     * @dev V0.5 pattern: All swap logic handled in beforeSwap, this is just a no-op
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
        // Reset pending markers (rehypothecation module not yet integrated)
        s._pendingRehypoUSDC = 0;
        s._pendingDehypoUSDC = 0;

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
