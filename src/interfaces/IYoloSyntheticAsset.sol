// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "./IYoloOracle.sol";

/**
 * @title IYoloSyntheticAsset
 * @author alvin@yolo.wtf
 * @notice Interface for YOLO Protocol synthetic asset tokens
 * @dev Extends ERC20 with cost basis tracking and YoloHook-controlled minting
 */
interface IYoloSyntheticAsset is IERC20, IERC20Metadata {
    // Events
    event CostBasisUpdated(address indexed user, uint256 newBalance, uint128 newAvgPriceX8);
    event TradingStatusChanged(bool enabled);
    event MaxSupplyUpdated(uint256 newMaxSupply);
    event OracleUpdated(address newOracle);

    // Mint/Burn functions (only callable by YoloHook)
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;

    // Batch operations for gas efficiency
    function batchMint(address[] calldata recipients, uint256[] calldata amounts) external;
    function batchBurn(address[] calldata accounts, uint256[] calldata amounts) external;

    // Cost basis queries
    function avgPriceX8(address user) external view returns (uint128);
    function averagePriceX8(address user) external view returns (uint128);

    // Configuration getters
    function underlyingAsset() external view returns (address);
    function priceOracle() external view returns (address); // Returns address of YoloOracle
    function maxSupply() external view returns (uint256);
    function tradingEnabled() external view returns (bool);

    // Admin functions (role-based)
    function setTradingEnabled(bool enabled) external;
    function setMaxSupply(uint256 _maxSupply) external;
    function setYoloOracle(IYoloOracle _yoloOracle) external;

    // EIP-2612 permit
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;

    // Domain separator for EIP-712
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function nonces(address owner) external view returns (uint256);
}
