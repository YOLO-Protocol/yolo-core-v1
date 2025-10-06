// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYoloOracle.sol";

/**
 * @title MockYoloOracle
 * @notice Mock oracle for testing synthetic asset pricing
 */
contract MockYoloOracle is IYoloOracle {
    mapping(address => uint256) private prices;
    mapping(address => address) private sources;

    /**
     * @notice Set a single asset price
     */
    function setAssetPrice(address asset, uint256 price) external {
        prices[asset] = price;
    }

    /**
     * @notice Get price for an asset
     */
    function getAssetPrice(address asset) external view override returns (uint256) {
        return prices[asset];
    }

    /**
     * @notice Get prices for multiple assets
     */
    function getAssetsPrices(address[] calldata assets) external view override returns (uint256[] memory) {
        uint256[] memory assetPrices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            assetPrices[i] = prices[assets[i]];
        }
        return assetPrices;
    }

    /**
     * @notice Get oracle source for an asset
     */
    function getSourceOfAsset(address asset) external view override returns (address) {
        return sources[asset];
    }

    /**
     * @notice Set oracle sources for assets
     */
    function setAssetSources(address[] calldata assets, address[] calldata _sources) external override {
        require(assets.length == _sources.length, "Length mismatch");
        for (uint256 i = 0; i < assets.length; i++) {
            sources[assets[i]] = _sources[i];
        }
    }
}
