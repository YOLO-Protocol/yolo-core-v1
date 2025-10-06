// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IYLPVault.sol";

/**
 * @title MockYLPVault
 * @notice Mock YLP vault for testing synthetic asset P&L settlement
 */
contract MockYLPVault is IYLPVault {
    struct Settlement {
        address user;
        address asset;
        int256 pnlUSY;
        uint256 timestamp;
    }

    Settlement[] public settlements;
    mapping(address => mapping(address => int256)) public userAssetPnL;
    mapping(address => int256) public totalUserPnL;
    int256 public totalPnL;

    /**
     * @notice Settles P&L for a synthetic asset position
     */
    function settlePnL(address user, address asset, int256 pnlUSY) external override {
        settlements.push(Settlement({user: user, asset: asset, pnlUSY: pnlUSY, timestamp: block.timestamp}));

        userAssetPnL[user][asset] += pnlUSY;
        totalUserPnL[user] += pnlUSY;
        totalPnL += pnlUSY;

        emit PnLSettled(user, asset, pnlUSY, block.timestamp);
    }

    /**
     * @notice Records a trade for tracking
     */
    function recordTrade(address user, address asset, uint256 notionalUSY, uint256 feeUSY) external override {
        emit TradeRecorded(user, asset, notionalUSY, feeUSY);
    }

    // Test helpers
    function getSettlementCount() external view returns (uint256) {
        return settlements.length;
    }

    function getLastSettlement() external view returns (Settlement memory) {
        require(settlements.length > 0, "No settlements");
        return settlements[settlements.length - 1];
    }

    function reset() external {
        delete settlements;
        totalPnL = 0;
        // Note: Cannot easily clear mappings, test should deploy new instance if needed
    }
}
