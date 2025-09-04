// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IPriceOracle
 * @notice Interface for Chainlink-compatible price oracles
 * @dev Minimal interface focusing on latestAnswer() for simplicity
 *      Adapters can implement full AggregatorV3Interface if needed
 */
interface IPriceOracle {
    /**
     * @notice Get the latest price answer
     * @return The latest price (decimals depend on the feed)
     */
    function latestAnswer() external view returns (int256);

    /**
     * @notice Get the number of decimals in the response
     * @return The number of decimals
     */
    function decimals() external view returns (uint8);
}
