// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IYLPVault
 * @author alvin@yolo.wtf
 * @notice Interface for YLP Vault that handles P&L settlement for synthetic assets
 * @dev Settlement endpoint for all synthetic asset burns (swaps and loan repayments)
 *      Also provides epoch-based deposit/withdrawal queue to prevent frontrunning unrealized gains
 */
interface IYLPVault {
    // ============================================================
    // STRUCTS
    // ============================================================

    /**
     * @notice Deposit request submitted by user
     * @param user Address of the user requesting deposit
     * @param usyAmount Amount of USY to deposit
     * @param minYLPShares Minimum YLP shares expected (slippage protection)
     * @param maxSlippageBps Maximum tolerable slippage in basis points (e.g., 50 = 0.5%)
     * @param requestBlock Block number when request was submitted
     * @param executed Whether this request has been processed
     */
    struct DepositRequest {
        address user;
        uint256 usyAmount;
        uint256 minYLPShares;
        uint256 maxSlippageBps;
        uint256 requestBlock;
        bool executed;
    }

    /**
     * @notice Withdrawal request submitted by user
     * @param user Address of the user requesting withdrawal
     * @param ylpShares Amount of YLP shares to withdraw
     * @param minUSYOut Minimum USY expected (slippage protection)
     * @param maxSlippageBps Maximum tolerable slippage in basis points
     * @param requestBlock Block number when request was submitted
     * @param executed Whether this request has been processed
     */
    struct WithdrawalRequest {
        address user;
        uint256 ylpShares;
        uint256 minUSYOut;
        uint256 maxSlippageBps;
        uint256 requestBlock;
        bool executed;
    }

    // ============================================================
    // SETTLEMENT INTERFACE (Called by YoloHook)
    // ============================================================

    /**
     * @notice Settles P&L for a synthetic asset position
     * @dev Called by YoloHook during synthetic asset burns
     *      - Positive pnlUSY: Trader profit, vault pays out USY
     *      - Negative pnlUSY: Trader loss, vault receives USY (hook funds vault first)
     * @param user The user whose position is being settled
     * @param asset The synthetic asset address
     * @param pnlUSY The P&L amount in USY (18 decimals). Positive = user profit, Negative = user loss
     */
    function settlePnL(address user, address asset, int256 pnlUSY) external;

    /**
     * @notice Records a trade for utilization tracking
     * @dev Called by YoloHook when synthetic positions are opened
     *      Used to track per-asset exposure and enforce utilization caps
     * @param user The user trading
     * @param asset The synthetic asset
     * @param notionalUSY The notional value in USY
     * @param feeUSY The fee amount in USY
     */
    function recordTrade(address user, address asset, uint256 notionalUSY, uint256 feeUSY) external;

    // ============================================================
    // DEPOSIT/WITHDRAWAL QUEUE (User-Initiated)
    // ============================================================

    /**
     * @notice Request to deposit USY into YLP vault
     * @dev User initiates deposit request which will be processed by solver in next epoch
     *      Epochs can be time-based (5/15 min) or block-based (100/200 blocks) - TBD
     *      USY is transferred to vault immediately in pending state via safeTransferFrom
     *      Prevents frontrunning of unrealized PnL by batching deposits
     * @param usyAmount Amount of USY to deposit (must approve vault first)
     * @param minYLPShares Minimum YLP shares expected (slippage protection)
     * @param maxSlippageBps Maximum tolerable slippage in basis points (e.g., 50 = 0.5%)
     * @return requestId Unique identifier for this deposit request
     */
    function requestDeposit(uint256 usyAmount, uint256 minYLPShares, uint256 maxSlippageBps)
        external
        returns (uint256 requestId);

    /**
     * @notice Request to withdraw YLP shares from vault
     * @dev User initiates withdrawal request which will be processed by solver in next epoch
     *      YLP shares are transferred to vault immediately in pending state
     *      Prevents frontrunning of unrealized PnL by batching withdrawals
     * @param ylpShares Amount of YLP shares to withdraw
     * @param minUSYOut Minimum USY expected to receive (slippage protection)
     * @param maxSlippageBps Maximum tolerable slippage in basis points
     * @return requestId Unique identifier for this withdrawal request
     */
    function requestWithdrawal(uint256 ylpShares, uint256 minUSYOut, uint256 maxSlippageBps)
        external
        returns (uint256 requestId);

    // ============================================================
    // ADMIN FUNCTIONS (RISK_ADMIN or POOL_ADMIN role)
    // ============================================================

    /**
     * @notice Set minimum deposit amount to prevent dust attacks
     * @dev Only callable by RISK_ADMIN role
     * @param minAmount Minimum USY amount for deposits (18 decimals)
     */
    function setMinDepositAmount(uint256 minAmount) external;

    /**
     * @notice Set maximum deposit amount per request
     * @dev Only callable by RISK_ADMIN role
     *      Used to cap individual deposits or total TVL
     * @param maxAmount Maximum USY amount for deposits (18 decimals)
     */
    function setMaxDepositAmount(uint256 maxAmount) external;

    /**
     * @notice Set minimum withdrawal amount to prevent dust attacks
     * @dev Only callable by RISK_ADMIN role
     * @param minAmount Minimum YLP shares for withdrawals (18 decimals)
     */
    function setMinWithdrawalAmount(uint256 minAmount) external;

    /**
     * @notice Set withdrawal fee in basis points
     * @dev Only callable by RISK_ADMIN role
     *      Fee is deducted from withdrawn USY amount
     *      Example: 50 bps = 0.5% fee
     * @param feeBps Fee in basis points (max 10000 = 100%)
     */
    function setWithdrawalFeeBps(uint256 feeBps) external;

    // ============================================================
    // SOLVER FUNCTIONS (YLP_SOLVER role only)
    // ============================================================

    /**
     * @notice Seal the current epoch by computing and storing NAV snapshot
     * @dev Only callable by YLP_SOLVER role (via ACLManager)
     *      Must be called BEFORE executing any deposits/withdrawals for the epoch
     *      Computation (expensive, done once per epoch):
     *      1. Get USY balance of vault
     *      3. Loop through tracked synthetic assets:
     *         - Fetch oracle price for each asset
     *         - Calculate unrealized PnL: (entryPrice - currentPrice) * totalSupply
     *         - Sum absolute values for total exposure
     *      4. Query pending rewards from incentive controller
     *      5. Calculate NAV in USY terms
     *      6. Calculate price per share = (NAV * RAY) / totalYLPSupply
     *      7. Store snapshot with epochId, timestamp
     *      8. Emit EpochSealed event
     * @param unrealizedPnL Unrealized PnL from YLP's perspective (positive = YLP profit, negative = YLP loss)
     * @param snapshotBlock L2 block number anchor for this epoch snapshot
     * @return epochId The sealed epoch identifier
     * @return navUSY The computed NAV in USY terms (balance + unrealizedPnL)
     * @return pricePerShareRay The price per share in RAY precision
     */
    function sealEpoch(int256 unrealizedPnL, uint256 snapshotBlock)
        external
        returns (uint256 epochId, uint256 navUSY, uint256 pricePerShareRay);

    /**
     * @notice Execute pending deposit requests in batch
     * @dev Only callable by YLP_SOLVER role (via ACLManager)
     *      MUST be called AFTER sealEpoch() for the current epoch
     *      Uses SEALED snapshot NAV only (never recomputes)
     *      For each request:
     *      - Calculate shares: (usyAmount * 1e27) / pricePerShareRay
     *      - Check slippage: |calculatedShares - minYLPShares| / minYLPShares <= maxSlippageBps
     *      - If acceptable: mint YLP shares to user
     *      - If exceeded: refund USY to user with reason
     * @param requestIds Array of deposit request IDs to execute
     */
    function executeDeposits(uint256[] calldata requestIds) external;

    /**
     * @notice Execute pending withdrawal requests in batch
     * @dev Only callable by YLP_SOLVER role (via ACLManager)
     *      MUST be called AFTER sealEpoch() for the current epoch
     *      Uses SEALED snapshot NAV only (never recomputes)
     *      For each request:
     *      - Calculate USY out: (ylpShares * pricePerShareRay) / 1e27
     *      - Check slippage: |calculatedUSY - minUSYOut| / minUSYOut <= maxSlippageBps
     *      - If acceptable: burn YLP shares, transfer USY to user
     *      - If exceeded: refund YLP shares to user with reason
     * @param requestIds Array of withdrawal request IDs to execute
     */
    function executeWithdrawals(uint256[] calldata requestIds) external;

    // (no conversion helpers in USY vault mode)

    /**
     * @notice Get the last sealed epoch snapshot
     * @dev Snapshots are sealed once per epoch by YLP_SOLVER via sealEpoch()
     *      Execution (executeDeposits/executeWithdrawals) ONLY uses sealed snapshots, never live NAV
     *      This prevents expensive recomputation and MEV/reorg issues
     * @return epochId The epoch identifier when snapshot was sealed
     * @return navUSY Total net asset value in USY terms (18 decimals)
     * @return pricePerShareRay Price per YLP share in RAY precision (27 decimals)
     * @return timestamp Block timestamp when snapshot was sealed
     */
    function getLastSnapshot()
        external
        view
        returns (uint256 epochId, uint256 navUSY, uint256 pricePerShareRay, uint256 timestamp);

    /**
     * @notice Get deposit request details
     * @param requestId The deposit request ID
     * @return request The deposit request struct
     */
    function getDepositRequest(uint256 requestId) external view returns (DepositRequest memory request);

    /**
     * @notice Get withdrawal request details
     * @param requestId The withdrawal request ID
     * @return request The withdrawal request struct
     */
    function getWithdrawalRequest(uint256 requestId) external view returns (WithdrawalRequest memory request);

    // ============================================================
    // EVENTS
    // ============================================================

    // Settlement events
    event PnLSettled(address indexed user, address indexed asset, int256 pnlUSY, uint256 timestamp);
    event TradeRecorded(address indexed user, address indexed asset, uint256 notionalUSY, uint256 feeUSY);

    // Admin events
    event MinDepositAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event MaxDepositAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event MinWithdrawalAmountUpdated(uint256 oldAmount, uint256 newAmount);
    event WithdrawalFeeBpsUpdated(uint256 oldFeeBps, uint256 newFeeBps);

    // Epoch events
    event EpochSealed(
        uint256 indexed epochId,
        uint256 navUSY,
        uint256 pricePerShareRay,
        uint256 snapshotBlock,
        int256 unrealizedPnL,
        uint256 timestamp,
        address indexed solver
    );

    // Queue events
    event DepositRequested(
        uint256 indexed requestId, address indexed user, uint256 usyAmount, uint256 minYLPShares, uint256 requestBlock
    );
    event WithdrawalRequested(
        uint256 indexed requestId, address indexed user, uint256 ylpShares, uint256 minUSYOut, uint256 requestBlock
    );
    event DepositExecuted(uint256 indexed requestId, address indexed user, uint256 usyAmount, uint256 ylpSharesMinted);
    event DepositRefunded(uint256 indexed requestId, address indexed user, uint256 usyAmount, string reason);
    event WithdrawalExecuted(
        uint256 indexed requestId, address indexed user, uint256 ylpSharesBurned, uint256 usyOut, uint256 feeAmount
    );
    event WithdrawalRefunded(uint256 indexed requestId, address indexed user, uint256 ylpShares, string reason);
}
