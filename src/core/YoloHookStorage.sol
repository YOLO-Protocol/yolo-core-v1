// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {DataTypes} from "../libraries/DataTypes.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";

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
    /// @notice YLP vault address for P&L settlement
    address ylpVault;
    /// @notice Pause state (managed via ACLManager PAUSER_ROLE)
    bool _paused;
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

    /// @notice User positions for lending pairs
    mapping(bytes32 => mapping(address => DataTypes.UserPosition)) _userPositions;
    // ============================================================
    // POOL REGISTRY
    // ============================================================

    /// @notice Registry of created Uniswap V4 pools (both anchor and synthetic)
    mapping(bytes32 => DataTypes.PoolConfiguration) _poolConfigs;
    /// @notice Anchor pool key (USY-USDC Curve StableSwap)
    bytes32 _anchorPoolKey;
    /// @notice Mapping from synthetic asset to its pool ID
    mapping(address => bytes32) _syntheticAssetToPool;
    /// @notice Anchor pool reserves for Curve math
    uint256 totalAnchorReserveUSY;
    uint256 totalAnchorReserveUSDC;
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
}
