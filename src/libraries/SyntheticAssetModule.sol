// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {DataTypes} from "./DataTypes.sol";
import {AppStorage} from "../core/YoloHookStorage.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title SyntheticAssetModule
 * @author alvin@yolo.wtf
 * @notice Library for creating and managing synthetic assets in YOLO Protocol V1
 * @dev Externally linked library following Aave-style architecture
 *      Uses UUPS proxy pattern for all synthetic asset deployments
 *      Implementation address passed as parameter (not stored)
 */
library SyntheticAssetModule {
    using PoolIdLibrary for PoolKey;

    uint32 internal constant SECONDS_PER_DAY = 86_400;
    // ============================================================
    // EVENTS
    // ============================================================

    /**
     * @notice Emitted when a new synthetic asset is created
     * @param syntheticToken Address of the deployed synthetic token (proxy)
     * @param oracleSource Price feed source for the synthetic asset
     * @param name Token name
     * @param symbol Token symbol
     * @param implementation Implementation contract used for deployment
     */
    event SyntheticAssetCreated(
        address indexed syntheticToken, address indexed oracleSource, string name, string symbol, address implementation
    );

    /**
     * @notice Emitted when a synthetic asset is deactivated
     * @param syntheticToken Address of the synthetic token
     */
    event SyntheticAssetDeactivated(address indexed syntheticToken);

    /**
     * @notice Emitted when a synthetic asset is reactivated
     * @param syntheticToken Address of the synthetic token
     */
    event SyntheticAssetReactivated(address indexed syntheticToken);

    /**
     * @notice Emitted when a synthetic asset's max supply is updated
     * @param syntheticToken Address of the synthetic token
     * @param newMaxSupply New maximum supply
     */
    event SyntheticAssetMaxSupplyUpdated(address indexed syntheticToken, uint256 newMaxSupply);

    /**
     * @notice Emitted when a synthetic asset's perp configuration changes
     * @param syntheticToken Address of the synthetic token
     * @param config New perpetual trading configuration
     */
    event SyntheticAssetPerpConfigUpdated(address indexed syntheticToken, DataTypes.PerpConfiguration config);

    // ============================================================
    // ERRORS
    // ============================================================

    error SyntheticAssetModule__InvalidImplementation();
    error SyntheticAssetModule__InvalidOracle();
    error SyntheticAssetModule__InvalidYLPVault();
    error SyntheticAssetModule__AssetAlreadyExists();
    error SyntheticAssetModule__AssetNotFound();
    error SyntheticAssetModule__InvalidAddress();
    error SyntheticAssetModule__InvalidPerpConfig();

    // ============================================================
    // SYNTHETIC ASSET CREATION
    // ============================================================

    /**
     * @notice Creates a new synthetic asset with UUPS proxy
     * @dev Deploys ERC1967Proxy wrapping the provided implementation
     *      Implementation address passed as parameter (Aave-style)
     *      YoloHook maintains upgrade control via _authorizeUpgrade
     *      Automatically creates virtual synthetic pool (USY-yAsset) on PoolManager
     *      The synthetic asset's address is registered directly in YoloOracle
     * @param s Reference to AppStorage
     * @param poolManager Uniswap V4 PoolManager for pool creation
     * @param yoloHook Address of YoloHook (used as hook address for pools)
     * @param aclManager ACL manager for access control
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
        AppStorage storage s,
        IPoolManager poolManager,
        address yoloHook,
        IACLManager aclManager,
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address oracleSource,
        address implementation,
        uint256 maxSupply,
        uint256 maxFlashLoanAmount
    ) external returns (address syntheticToken) {
        // Validation
        if (implementation == address(0)) revert SyntheticAssetModule__InvalidImplementation();
        if (address(s.yoloOracle) == address(0)) revert SyntheticAssetModule__InvalidOracle();
        if (s.ylpVault == address(0)) revert SyntheticAssetModule__InvalidYLPVault();

        // Encode initializer call
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,string,string,uint8,address,uint256)",
            address(this), // yoloHook = address of YoloHook (this contract)
            address(aclManager),
            name,
            symbol,
            decimals,
            s.ylpVault,
            maxSupply
        );

        // Deploy UUPS proxy
        syntheticToken = address(new ERC1967Proxy(implementation, initData));

        // Register synthetic asset
        s._isYoloAsset[syntheticToken] = true;
        s._yoloAssets.push(syntheticToken);

        // Store configuration
        s._assetConfigs[syntheticToken] = DataTypes.AssetConfiguration({
            syntheticToken: syntheticToken,
            oracleSource: oracleSource,
            maxSupply: maxSupply,
            maxFlashLoanAmount: maxFlashLoanAmount,
            isActive: true,
            createdAt: block.timestamp,
            perpConfig: DataTypes.PerpConfiguration({
                enabled: false,
                maxOpenInterestUsd: 0,
                maxLongOpenInterestUsd: 0,
                maxShortOpenInterestUsd: 0,
                maxLeverageBpsDay: 0,
                maxLeverageBpsCarryOvernight: 0,
                tradeSessionStart: 0,
                tradeSessionEnd: 0,
                marketState: DataTypes.TradeMarketState.OFFLINE
            })
        });

        // Register oracle source for this synthetic asset
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = syntheticToken;
        sources[0] = oracleSource;
        s.yoloOracle.setAssetSources(assets, sources);

        // CRITICAL: Approve PoolManager for synthetic token settlement
        IERC20(syntheticToken).approve(address(poolManager), type(uint256).max);

        // Create virtual synthetic pool (USY-syntheticToken)
        bool usyIs0 = s.usy < syntheticToken;
        Currency currency0 = Currency.wrap(usyIs0 ? s.usy : syntheticToken);
        Currency currency1 = Currency.wrap(usyIs0 ? syntheticToken : s.usy);

        PoolKey memory syntheticPoolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0, // Fees handled in hook
            tickSpacing: 1, // Tighter tick spacing for synthetic pools
            hooks: IHooks(yoloHook)
        });

        // Initialize at 1:1 price (virtual pool, no actual liquidity)
        poolManager.initialize(syntheticPoolKey, uint160(1) << 96);

        // Store pool configuration
        bytes32 syntheticPoolId = PoolId.unwrap(syntheticPoolKey.toId());
        s._poolConfigs[syntheticPoolId] = DataTypes.PoolConfiguration({
            poolKey: syntheticPoolKey,
            isAnchorPool: false,
            isSyntheticPool: true,
            token0: Currency.unwrap(currency0),
            token1: Currency.unwrap(currency1),
            createdAt: block.timestamp
        });

        // Register synthetic asset to pool mapping
        s._syntheticAssetToPool[syntheticToken] = syntheticPoolId;

        emit SyntheticAssetCreated(syntheticToken, oracleSource, name, symbol, implementation);
    }

    // ============================================================
    // ASSET MANAGEMENT
    // ============================================================

    /**
     * @notice Deactivates a synthetic asset
     * @dev Only callable by assets admin via YoloHook
     * @param s Reference to AppStorage
     * @param syntheticToken Address of the synthetic token
     */
    function deactivateSyntheticAsset(AppStorage storage s, address syntheticToken) external {
        if (!s._isYoloAsset[syntheticToken]) revert SyntheticAssetModule__AssetNotFound();

        s._assetConfigs[syntheticToken].isActive = false;
        emit SyntheticAssetDeactivated(syntheticToken);
    }

    /**
     * @notice Reactivates a synthetic asset
     * @dev Only callable by assets admin via YoloHook
     * @param s Reference to AppStorage
     * @param syntheticToken Address of the synthetic token
     */
    function reactivateSyntheticAsset(AppStorage storage s, address syntheticToken) external {
        if (!s._isYoloAsset[syntheticToken]) revert SyntheticAssetModule__AssetNotFound();

        s._assetConfigs[syntheticToken].isActive = true;
        emit SyntheticAssetReactivated(syntheticToken);
    }

    /**
     * @notice Updates max supply for a synthetic asset
     * @dev Only callable by assets admin via YoloHook
     * @param s Reference to AppStorage
     * @param syntheticToken Address of the synthetic token
     * @param newMaxSupply New maximum supply (0 for unlimited)
     */
    function updateMaxSupply(AppStorage storage s, address syntheticToken, uint256 newMaxSupply) external {
        if (!s._isYoloAsset[syntheticToken]) revert SyntheticAssetModule__AssetNotFound();

        s._assetConfigs[syntheticToken].maxSupply = newMaxSupply;
        emit SyntheticAssetMaxSupplyUpdated(syntheticToken, newMaxSupply);
    }

    /**
     * @notice Updates the leveraged trading configuration for an asset
     * @dev Validates session bounds and directional caps before storing
     * @param s Reference to AppStorage
     * @param syntheticToken Address of the synthetic token being configured
     * @param config New configuration struct
     */
    function updatePerpConfiguration(
        AppStorage storage s,
        address syntheticToken,
        DataTypes.PerpConfiguration calldata config
    ) external {
        if (!s._isYoloAsset[syntheticToken]) revert SyntheticAssetModule__AssetNotFound();

        // Require directional caps to live within the total OI cap when enabled
        if (
            config.maxLongOpenInterestUsd > config.maxOpenInterestUsd
                || config.maxShortOpenInterestUsd > config.maxOpenInterestUsd
        ) {
            revert SyntheticAssetModule__InvalidPerpConfig();
        }

        // Trade session timestamps represent seconds since midnight UTC and must be within a 24h window
        if (config.tradeSessionStart >= SECONDS_PER_DAY || config.tradeSessionEnd > SECONDS_PER_DAY) {
            revert SyntheticAssetModule__InvalidPerpConfig();
        }

        if (
            config.tradeSessionEnd != 0 && config.tradeSessionStart != 0
                && config.tradeSessionStart == config.tradeSessionEnd
        ) {
            revert SyntheticAssetModule__InvalidPerpConfig();
        }

        s._assetConfigs[syntheticToken].perpConfig = config;
        emit SyntheticAssetPerpConfigUpdated(syntheticToken, config);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Returns all created synthetic assets
     * @param s Reference to AppStorage
     * @return Array of synthetic asset addresses
     */
    function getAllSyntheticAssets(AppStorage storage s) external view returns (address[] memory) {
        return s._yoloAssets;
    }

    /**
     * @notice Returns configuration for a synthetic asset
     * @param s Reference to AppStorage
     * @param syntheticToken Address of the synthetic token
     * @return Configuration struct
     */
    function getAssetConfiguration(AppStorage storage s, address syntheticToken)
        external
        view
        returns (DataTypes.AssetConfiguration memory)
    {
        return s._assetConfigs[syntheticToken];
    }

    /**
     * @notice Checks if address is a YOLO synthetic asset
     * @param s Reference to AppStorage
     * @param syntheticToken Address to check
     * @return True if asset is a YOLO synthetic asset
     */
    function isYoloAsset(AppStorage storage s, address syntheticToken) external view returns (bool) {
        return s._isYoloAsset[syntheticToken];
    }
}
