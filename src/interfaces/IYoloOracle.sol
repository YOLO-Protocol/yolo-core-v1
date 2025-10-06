// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IYoloOracle
 * @author alvin@yolo.wtf
 * @notice Interface for YOLO Protocol oracle system
 */
interface IYoloOracle {
    function getAssetPrice(address asset) external view returns (uint256);
    function getAssetsPrices(address[] calldata assets) external view returns (uint256[] memory);
    function getSourceOfAsset(address asset) external view returns (address);
    function setAssetSources(address[] calldata assets, address[] calldata sources) external;
}
