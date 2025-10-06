// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IYLPVault
 * @author alvin@yolo.wtf
 * @notice Interface for YLP Vault that handles P&L settlement for synthetic assets
 * @dev Settlement endpoint for all synthetic asset burns (swaps and loan repayments)
 */
interface IYLPVault {
    /**
     * @notice Settles P&L for a synthetic asset position
     * @dev Called by synthetic asset token during burn
     * @param user The user whose position is being settled
     * @param asset The synthetic asset address calling this function
     * @param pnlUSY The P&L amount in USY (18 decimals). Positive = user profit, Negative = user loss
     */
    function settlePnL(address user, address asset, int256 pnlUSY) external;

    /**
     * @notice Records a trade for tracking (optional)
     * @param user The user trading
     * @param asset The synthetic asset
     * @param notionalUSY The notional value in USY
     * @param feeUSY The fee amount in USY
     */
    function recordTrade(address user, address asset, uint256 notionalUSY, uint256 feeUSY) external;

    // Events
    event PnLSettled(address indexed user, address indexed asset, int256 pnlUSY, uint256 timestamp);
    event TradeRecorded(address indexed user, address indexed asset, uint256 notionalUSY, uint256 feeUSY);
}
