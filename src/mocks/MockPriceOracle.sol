// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPriceOracle} from "../interfaces/IPriceOracle.sol";

/**
 * @title MockPriceOracle
 * @author alvin@yolo.wtf
 * @notice Mock implementation of IPriceOracle for testing
 * @dev Simulates Chainlink-style price feeds with updateable prices
 *      WARNING: NOT FOR PRODUCTION USE
 */
contract MockPriceOracle is IPriceOracle {
    // ============================================================
    // STATE VARIABLES
    // ============================================================

    /// @notice Latest price answer (8 decimals for USD feeds)
    int256 private _latestAnswer;

    /// @notice Description of the price feed (e.g., "WETH / USD")
    string private _description;

    // ============================================================
    // EVENTS
    // ============================================================

    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize mock oracle with initial price
     * @param initialAnswer Initial price (8 decimals)
     * @param description_ Description of the feed
     */
    constructor(int256 initialAnswer, string memory description_) {
        _latestAnswer = initialAnswer;
        _description = description_;
        emit AnswerUpdated(initialAnswer, 0, block.timestamp);
    }

    // ============================================================
    // EXTERNAL FUNCTIONS
    // ============================================================

    /**
     * @notice Get the latest price answer
     * @return The latest price (8 decimals)
     */
    function latestAnswer() external view override returns (int256) {
        return _latestAnswer;
    }

    /**
     * @notice Get the number of decimals in the response
     * @return The number of decimals (always 8 for USD feeds)
     */
    function decimals() external pure override returns (uint8) {
        return 8;
    }

    /**
     * @notice Update the price answer (testing only)
     * @param newAnswer New price to set
     */
    function updateAnswer(int256 newAnswer) external {
        _latestAnswer = newAnswer;
        emit AnswerUpdated(newAnswer, 0, block.timestamp);
    }

    /**
     * @notice Get the feed description
     * @return The description string
     */
    function description() external view returns (string memory) {
        return _description;
    }

    /**
     * @notice Get latest round data (Chainlink compatibility)
     * @return roundId Round ID (always 0 for mock)
     * @return answer Latest price
     * @return startedAt Timestamp (current block)
     * @return updatedAt Timestamp (current block)
     * @return answeredInRound Round ID (always 0 for mock)
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (0, _latestAnswer, block.timestamp, block.timestamp, 0);
    }
}
