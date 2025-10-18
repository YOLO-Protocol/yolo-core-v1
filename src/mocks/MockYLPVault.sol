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

    // ============================================================
    // ADMIN FUNCTIONS (Mock implementations)
    // ============================================================

    function setMinDepositAmount(uint256) external pure override {
        // Mock: no-op
    }

    function setMaxDepositAmount(uint256) external pure override {
        // Mock: no-op
    }

    function setMinWithdrawalAmount(uint256) external pure override {
        // Mock: no-op
    }

    function setWithdrawalFeeBps(uint256) external pure override {
        // Mock: no-op
    }

    // ============================================================
    // SOLVER FUNCTIONS (Mock implementations)
    // ============================================================

    function sealEpoch(int256, uint256) external pure override returns (uint256, uint256, uint256) {
        return (1, 1000000e18, 1e27); // Mock: epochId=1, NAV=1M, PPS=1.0
    }

    // ============================================================
    // DEPOSIT/WITHDRAWAL QUEUE (Mock implementations)
    // ============================================================

    function requestDeposit(uint256, uint256, uint256) external pure override returns (uint256) {
        return 0; // Mock: always return request ID 0
    }

    function requestWithdrawal(uint256, uint256, uint256) external pure override returns (uint256) {
        return 0; // Mock: always return request ID 0
    }

    function executeDeposits(uint256[] calldata) external pure override {
        // Mock: no-op
    }

    function executeWithdrawals(uint256[] calldata) external pure override {
        // Mock: no-op
    }

    // ============================================================
    // VIEW FUNCTIONS (Mock implementations)
    // ============================================================

    // No conversion helpers in USY vault mode

    function getLastSnapshot() external view override returns (uint256, uint256, uint256, uint256) {
        return (1, 1000000e18, 1e27, block.timestamp); // Mock: epochId=1, NAV=1M, PPS=1.0
    }

    function getDepositRequest(uint256) external pure override returns (IYLPVault.DepositRequest memory) {
        return IYLPVault.DepositRequest({
            user: address(0), usyAmount: 0, minYLPShares: 0, maxSlippageBps: 0, requestBlock: 0, executed: false
        });
    }

    function getWithdrawalRequest(uint256) external pure override returns (IYLPVault.WithdrawalRequest memory) {
        return IYLPVault.WithdrawalRequest({
            user: address(0), ylpShares: 0, minUSYOut: 0, maxSlippageBps: 0, requestBlock: 0, executed: false
        });
    }

    // ============================================================
    // TEST HELPERS
    // ============================================================

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
