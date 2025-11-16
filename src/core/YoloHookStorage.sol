// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {DataTypes} from "../libraries/DataTypes.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";
import {IStabilityTracker} from "../interfaces/IStabilityTracker.sol";

/**
 * @title YoloHookStorage
 * @author alvin@yolo.wtf
 * @notice Storage contract using AppStorage pattern (EIP-2535 Diamond Standard)
 * @dev Uses single storage struct to avoid slot conflicts with inherited contracts
 *      This pattern ensures libraries can safely access storage without assembly tricks
 */

/**
 * @notice Single storage struct containing all protocol state
 * @dev Occupies a single storage slot that points to this struct
 *      This avoids conflicts with parent contract storage (BaseHook, ReentrancyGuard, UUPS)
 */
struct AppStorage {
    // ============================================================
    // PROTOCOL CONFIGURATION
    // ============================================================

    /// @notice Oracle module for price feeds (swappable via governance)
    IYoloOracle yoloOracle;
    /// @notice USY stablecoin address
    address usy;
    /// @notice USDC stablecoin address (chain-dependent: 6 or 18 decimals)
    address usdc;
    /// @notice sUSY LP receipt token address
    address sUSY;
    /// @notice YLP vault address for P&L settlement
    address ylpVault;
    /// @notice USDC decimals (chain-dependent - can be 6 or 18)
    uint8 usdcDecimals;
    /// @notice Scale factor to convert USDC to 18 decimals: 10^(18-usdcDecimals)
    /// @dev Used for consistent decimal normalization across all calculations
    uint256 USDC_SCALE_UP;
    /// @notice Pause state (managed via ACLManager PAUSER_ROLE)
    bool _paused;
    /// @notice If true, only addresses with PRIVILEGED_LIQUIDATOR role can liquidate
    bool onlyPrivilegedLiquidator;
    /// @notice ACL Manager instance for role-based access control
    address ACL_MANAGER;
    // ============================================================
    // SYNTHETIC ASSETS REGISTRY
    // ============================================================

    /// @notice Mapping to check if address is a YOLO synthetic asset
    mapping(address => bool) _isYoloAsset;
    /// @notice Array of all created synthetic assets
    address[] _yoloAssets;
    /// @notice Configuration for each synthetic asset
    mapping(address => DataTypes.AssetConfiguration) _assetConfigs;
    // ============================================================
    // COLLATERAL REGISTRY
    // ============================================================

    /// @notice Mapping to check if asset is whitelisted as collateral
    mapping(address => bool) _isWhitelistedCollateral;
    /// @notice Array of all whitelisted collateral assets
    address[] _whitelistedCollaterals;
    // ============================================================
    // LENDING PAIRS CONFIGURATION
    // ============================================================

    /// @notice Configuration for lending pairs (collateral <-> synthetic)
    /// @dev pairId = keccak256(abi.encodePacked(syntheticAsset, collateralAsset))
    mapping(bytes32 => DataTypes.PairConfiguration) _pairConfigs;
    /// @notice Mapping from synthetic asset to all valid collaterals
    mapping(address => address[]) _syntheticToCollaterals;
    /// @notice Mapping from collateral to all valid synthetic assets
    mapping(address => address[]) _collateralToSynthetics;
    // ============================================================
    // USER POSITIONS
    // ============================================================

    /// @notice User positions triple-nested mapping: user => collateral => yoloAsset => position
    mapping(address => mapping(address => mapping(address => DataTypes.UserPosition))) positions;
    /// @notice Array of position keys for each user (for enumeration)
    mapping(address => DataTypes.UserPositionKey[]) userPositionKeys;
    /// @notice Treasury address for interest payments
    address treasury;
    /// @notice Leveraged trade positions per user (managed via TRADE_OPERATOR_ROLE)
    mapping(address => DataTypes.TradePosition[]) tradePositions;
    /// @notice Aggregated open interest stats per synthetic asset
    mapping(address => DataTypes.TradeAssetState) tradeAssetState;
    // ============================================================
    // POOL REGISTRY
    // ============================================================

    /// @notice Registry of created Uniswap V4 pools (both anchor and synthetic)
    mapping(bytes32 => DataTypes.PoolConfiguration) _poolConfigs;
    /// @notice Anchor pool key (USY-USDC StableSwap)
    bytes32 _anchorPoolKey;
    /// @notice Mapping from synthetic asset to its pool ID
    mapping(address => bytes32) _syntheticAssetToPool;
    /// @notice Anchor pool reserves for StableSwap math
    uint256 totalAnchorReserveUSY;
    uint256 totalAnchorReserveUSDC;
    /// @notice Pending rehypothecation/dehypothecation amounts for future use
    uint256 _pendingRehypoUSDC;
    uint256 _pendingDehypoUSDC;
    // ============================================================
    // SWAP CONFIGURATION
    // ============================================================

    /// @notice Anchor pool amplification coefficient (A parameter for StableSwap)
    uint256 anchorAmplificationCoefficient;
    /// @notice Anchor pool swap fee in basis points (0-10000, e.g., 4 = 0.04%)
    uint256 anchorSwapFeeBps;
    /// @notice Anchor pool fee share that goes to treasury in basis points (0-10000)
    /// @dev Remaining share (10000 - anchorFeeTreasuryShareBps) auto-compounds into LP reserves
    ///      Example: 2000 = 20% to treasury, 80% to LPs
    uint256 anchorFeeTreasuryShareBps;
    /// @notice Synthetic pool swap fee in basis points (0-10000)
    uint256 syntheticSwapFeeBps;
    /// @notice Pending synthetic asset to burn (settled next unlock)
    address pendingSyntheticToken;
    /// @notice Pending synthetic amount awaiting burn
    uint256 pendingSyntheticAmount;
    // ============================================================
    // FLASH LOAN CONFIGURATION
    // ============================================================

    /// @notice Flash loan fee in basis points (0-10000, e.g., 9 = 0.09%)
    uint256 flashLoanFeeBps;
    // ============================================================
    // STABILITY INCENTIVES (OPTIONAL MODULE)
    // ============================================================

    /// @notice Stability tracker for USY-USDC peg incentives (optional pluggable module)
    /// @dev Tracks swaps that move USY price closer to or further from $1.00 peg
    IStabilityTracker stabilityTracker;
}

/**
 * @title YoloHookStorage
 * @notice Base contract that holds the AppStorage variable
 * @dev Contracts inheriting this get access to the unified storage struct
 */
abstract contract YoloHookStorage {
    /// @notice Single storage variable using AppStorage pattern
    /// @dev All protocol state accessed through this struct
    AppStorage internal s;

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Minimum liquidity locked on first deposit to prevent zero-supply attacks
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    // ============================================================
    // ERRORS
    // ============================================================

    // Liquidity errors
    error YoloHookStorage__InvalidAmount();
    error YoloHookStorage__InvalidAddress();
    error YoloHookStorage__sUSYNotInitialized();
    error YoloHookStorage__InsufficientBalance();
    error YoloHookStorage__InsufficientBootstrapLiquidity();
    error YoloHookStorage__InsufficientLiquidityMinted();
    error YoloHookStorage__InsufficientLiquidity();
    error YoloHookStorage__InsufficientOutput();
    error YoloHookStorage__ImbalancedDeposit();
    error YoloHookStorage__DirectPoolManagerLiquidityNotAllowed(); // modifyLiquidity must use YoloHook functions

    // Swap errors
    error YoloHookStorage__InsufficientLiquidityForSwap();
    error YoloHookStorage__InvalidSwapAmount();
    error YoloHookStorage__SyntheticSwapNotImplemented();
    error YoloHookStorage__UnknownPool();
    error YoloHookStorage__NoPendingSyntheticBurn();
    error YoloHookStorage__UnknownUnlockAction();

    // ============================================================
    // EVENTS
    // ============================================================

    /**
     * @notice Emitted when liquidity is added to anchor pool
     * @param sender Address initiating the add
     * @param receiver Address receiving sUSY tokens
     * @param usyAmount USY deposited (18 decimals)
     * @param usdcAmount USDC deposited (native decimals)
     * @param sUSYMinted sUSY tokens minted (18 decimals)
     * @param isBootstrap Whether this was the first liquidity
     */
    event LiquidityAdded(
        address indexed sender,
        address indexed receiver,
        uint256 usyAmount,
        uint256 usdcAmount,
        uint256 sUSYMinted,
        bool isBootstrap
    );

    /**
     * @notice Emitted when liquidity is removed from anchor pool
     * @param sender Address initiating the removal (sUSY burner)
     * @param receiver Address receiving USY + USDC
     * @param sUSYBurned sUSY tokens burned (18 decimals)
     * @param usyAmount USY received (18 decimals)
     * @param usdcAmount USDC received (native decimals)
     */
    event LiquidityRemoved(
        address indexed sender, address indexed receiver, uint256 sUSYBurned, uint256 usyAmount, uint256 usdcAmount
    );

    /**
     * @notice Emitted when a swap occurs in the anchor pool
     * @param poolId Pool identifier
     * @param sender Address initiating the swap
     * @param amount0Delta Delta for token0 (negative = to pool, positive = from pool)
     * @param amount1Delta Delta for token1 (negative = to pool, positive = from pool)
     * @param reserveUSY Updated USY reserve after swap
     * @param reserveUSDC Updated USDC reserve after swap
     * @param feeAmount Fee collected in output token (native decimals)
     */
    event AnchorSwap(
        bytes32 indexed poolId,
        address indexed sender,
        int128 amount0Delta,
        int128 amount1Delta,
        uint256 reserveUSY,
        uint256 reserveUSDC,
        uint256 feeAmount
    );

    /**
     * @notice Emitted when a synthetic swap is executed
     * @param poolId Pool identifier
     * @param sender Address initiating the swap
     * @param tokenIn Synthetic token paid by trader
     * @param tokenOut Synthetic token received by trader
     * @param grossInput Total amount specified by trader (before fee)
     * @param netInput Net amount after fee (tracked as pending burn)
     * @param amountOut Output amount minted to the pool
     * @param feeAmount Fee captured in input token
     * @param exactInput True if swap was exact-in, false for exact-out
     */
    event SyntheticSwap(
        bytes32 indexed poolId,
        address indexed sender,
        address indexed tokenIn,
        address tokenOut,
        uint256 grossInput,
        uint256 netInput,
        uint256 amountOut,
        uint256 feeAmount,
        bool exactInput
    );

    /**
     * @notice Emitted when a flash loan is executed
     * @param borrower Address receiving the flash loan
     * @param initiator Address that initiated the flash loan
     * @param assets Array of asset addresses borrowed
     * @param amounts Array of amounts borrowed (in token decimals)
     * @param fees Array of fees paid (in token decimals)
     */
    event FlashLoanExecuted(
        address indexed borrower, address indexed initiator, address[] assets, uint256[] amounts, uint256[] fees
    );
}
