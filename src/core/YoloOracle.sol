// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IACLManager} from "../interfaces/IACLManager.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/**
 * @title YoloOracle
 * @author alvin@yolo.wtf
 * @notice Unified price aggregator for YOLO Protocol V1
 * @dev Based on V0.5 design with ACL integration and gas optimizations
 *      - ACL-based access control instead of Ownable
 *      - Immutable storage for gas efficiency
 *      - Simple single-source oracle mapping (complexity handled by adapters)
 */
contract YoloOracle {
    // ========================
    // CONSTANTS
    // ========================

    /// @notice Role for oracle administration
    bytes32 public constant ORACLE_ADMIN_ROLE = keccak256("ORACLE_ADMIN");

    // ========================
    // IMMUTABLE STORAGE
    // ========================

    /// @notice ACL Manager for role-based access control
    IACLManager public immutable ACL_MANAGER;

    /// @notice YoloHook address (immutable for gas efficiency)
    address public immutable YOLO_HOOK;

    /// @notice Anchor asset (USY) with fixed $1 price
    address public immutable ANCHOR;

    // ========================
    // STATE VARIABLES
    // ========================

    /// @notice Mapping from asset to price source oracle
    mapping(address => IPriceOracle) private assetToPriceSource;

    // ========================
    // EVENTS
    // ========================

    event AssetSourceUpdated(address indexed asset, address indexed source);

    // ========================
    // ERRORS
    // ========================

    error YoloOracle__ParamsLengthMismatch();
    error YoloOracle__PriceSourceCannotBeZero();
    error YoloOracle__CallerNotAuthorized();
    error YoloOracle__UnsupportedAsset();

    // ========================
    // MODIFIERS
    // ========================

    /**
     * @notice Ensure caller has ORACLE_ADMIN role
     * @dev YoloHook should be granted this role to set price sources when creating synthetic assets
     */
    modifier onlyOracleAdmin() {
        if (!ACL_MANAGER.hasRole(ORACLE_ADMIN_ROLE, msg.sender)) {
            revert YoloOracle__CallerNotAuthorized();
        }
        _;
    }

    // ========================
    // CONSTRUCTOR
    // ========================

    /**
     * @notice Initialize YoloOracle with ACL Manager, YoloHook and anchor asset
     * @param _aclManager Address of the ACL Manager contract
     * @param _yoloHook Address of the YoloHook contract (typically msg.sender)
     * @param _anchor Address of the anchor asset (USY)
     * @param _assets Initial assets to set price sources for
     * @param _sources Corresponding price sources for the assets
     */
    constructor(
        IACLManager _aclManager,
        address _yoloHook,
        address _anchor,
        address[] memory _assets,
        address[] memory _sources
    ) {
        ACL_MANAGER = _aclManager;
        YOLO_HOOK = _yoloHook;
        ANCHOR = _anchor;
        _setAssetsSources(_assets, _sources);
    }

    // ========================
    // EXTERNAL VIEW FUNCTIONS
    // ========================

    /**
     * @notice Get the price of a single asset
     * @param _asset Address of the asset for which the price is requested
     * @return price The asset price (8 decimals for USD feeds)
     */
    function getAssetPrice(address _asset) public view returns (uint256) {
        // If asset is the anchor (USY), return fixed $1.00 price
        if (_asset == ANCHOR) return 1e8;

        IPriceOracle source = assetToPriceSource[_asset];
        if (source == IPriceOracle(address(0))) revert YoloOracle__UnsupportedAsset();

        int256 price = source.latestAnswer();
        if (price > 0) return uint256(price);
        else return 0;
    }

    /**
     * @notice Get prices of multiple assets in batch
     * @param _assets Array of asset addresses for which prices are requested
     * @return prices Array of asset prices
     */
    function getAssetsPrices(address[] calldata _assets) external view returns (uint256[] memory) {
        uint256[] memory prices = new uint256[](_assets.length);
        for (uint256 i = 0; i < _assets.length; i++) {
            prices[i] = getAssetPrice(_assets[i]);
        }
        return prices;
    }

    /**
     * @notice Get the price source address for a given asset
     * @param _asset The asset to query
     * @return The address of the price source oracle
     */
    function getSourceOfAsset(address _asset) external view returns (address) {
        return address(assetToPriceSource[_asset]);
    }

    // ========================
    // ADMIN FUNCTIONS
    // ========================

    /**
     * @notice Set price sources for given assets
     * @dev Can be called by accounts with ORACLE_ADMIN role (including YoloHook)
     * @param _assets Array of assets to set price sources for
     * @param _sources Array of price source addresses
     */
    function setAssetSources(address[] calldata _assets, address[] calldata _sources) external onlyOracleAdmin {
        _setAssetsSources(_assets, _sources);
    }

    // ========================
    // INTERNAL FUNCTIONS
    // ========================

    /**
     * @notice Internal function to set price sources for assets
     * @param _assets Array of asset addresses
     * @param _sources Array of price source addresses
     */
    function _setAssetsSources(address[] memory _assets, address[] memory _sources) internal {
        // Validate input arrays have same length
        if (_assets.length != _sources.length) revert YoloOracle__ParamsLengthMismatch();

        // Set price source for each asset
        for (uint256 i = 0; i < _assets.length; i++) {
            if (_sources[i] == address(0)) revert YoloOracle__PriceSourceCannotBeZero();
            assetToPriceSource[_assets[i]] = IPriceOracle(_sources[i]);
            emit AssetSourceUpdated(_assets[i], _sources[i]);
        }
    }
}
