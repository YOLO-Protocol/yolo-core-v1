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
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
 *      - Handles both anchor pool (USY-USDC Curve) and synthetic pools (oracle-based)
 */
contract YoloHook is BaseHook, ReentrancyGuard, YoloHookStorage, UUPSUpgradeable {
    // ========================
    // LIBRARY USAGE
    // ========================

    using SyntheticAssetModule for AppStorage;
    using LendingPairModule for AppStorage;
    using PoolIdLibrary for PoolKey;
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
        address _ylpVaultImplementation
    ) external initializer {
        // Validation
        if (address(_yoloOracle) == address(0)) revert YoloHook__InvalidOracle();
        if (_usdc == address(0)) revert YoloHook__InvalidAddress();
        if (_usyImplementation == address(0)) revert YoloHook__InvalidAddress();

        // Store oracle
        s.yoloOracle = _yoloOracle;

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

        // Initialize protocol state
        s._paused = false;

        // Store YLP vault placeholder (will be properly deployed in Phase 3)
        s.ylpVault = _ylpVaultImplementation;

        // TODO: Phase 3 - Deploy sUSY (LP receipt token)
        // IStakedYoloUSD sUSY = IStakedYoloUSD(address(new ERC1967Proxy(_sUSYImplementation, sUSYInitData)));
        // s.sUSY = address(sUSY);

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
     *      - beforeSwap/afterSwap: Anchor pool (Curve) + Synthetic pool (oracle) swap logic
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

    /**
     * @notice Checks if address is a YOLO synthetic asset
     * @param syntheticToken Address to check
     * @return True if asset is a YOLO synthetic asset
     */
    function isYoloAsset(address syntheticToken) external view returns (bool) {
        return s._isYoloAsset[syntheticToken];
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
