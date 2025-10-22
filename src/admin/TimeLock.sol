// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title TimeLock
 * @author alvin@yolo.wtf
 * @notice Timelock contract for protocol governance with multi-admin support
 * @dev Provides transparent delay buffer before critical protocol changes
 *      - Multi-admin system with pending admin flow
 *      - Configurable delay (1-30 days)
 *      - 14-day execution window after delay
 *      - Queue → Delay → Execute pattern
 *      - Reentrancy protection on external calls
 */
contract TimeLock is ReentrancyGuard {
    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Minimum delay for timelock (1 day)
    uint256 public constant MINIMUM_DELAY = 1 days;

    /// @notice Execution window after delay expires (14 days)
    uint256 public constant EXEC_PERIOD = 14 days;

    /// @notice Maximum delay for timelock (30 days)
    uint256 public constant MAXIMUM_DELAY = 30 days;

    // ============================================================
    // STATE VARIABLES
    // ============================================================

    /// @notice Mapping of admin addresses
    mapping(address => bool) public isAdmin;

    /// @notice Mapping of pending admin addresses
    mapping(address => bool) public pendingAdmins;

    /// @notice Mapping of queued transaction hashes
    mapping(bytes32 => bool) public queuedTransactions;

    /// @notice Total number of active admins
    uint256 public totalAdmins;

    /// @notice Current delay time in seconds
    uint256 public delayTime;

    // ============================================================
    // EVENTS
    // ============================================================

    /// @notice Emitted when delay time is changed
    event NewDelayTime(uint256 indexed newDelayTime);

    /// @notice Emitted when a new pending admin is proposed
    event NewPendingAdmin(address indexed newPendingAdmin);

    /// @notice Emitted when a new admin is set
    event NewAdmin(address indexed newAdmin);

    /// @notice Emitted when an admin is revoked
    event RevokedAdmin(address indexed revokedAdmin);

    /// @notice Emitted when ether is transferred from contract
    event EtherTransfer(address indexed to, uint256 amount);

    /// @notice Emitted when a transaction is queued
    event QueueTransaction(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    /// @notice Emitted when a queued transaction is canceled
    event CancelTransaction(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    /// @notice Emitted when a queued transaction is executed
    event ExecuteTransaction(
        bytes32 indexed txHash, address indexed target, uint256 value, string signature, bytes data, uint256 eta
    );

    // ============================================================
    // ERRORS
    // ============================================================

    error TimeLock__DelayBelowMinimum();
    error TimeLock__DelayAboveMaximum();
    error TimeLock__OnlyTimeLockItself();
    error TimeLock__OnlyPendingAdmin();
    error TimeLock__OnlyAdmin();
    error TimeLock__MustHaveAtLeastOneAdmin();
    error TimeLock__EtaBelowDelay();
    error TimeLock__TransactionNotQueued();
    error TimeLock__TransactionNotReady();
    error TimeLock__TransactionStale();
    error TimeLock__TransactionFailed();
    error TimeLock__InsufficientBalance();
    error TimeLock__EtherTransferFailed();

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Initialize timelock with initial admin and delay
     * @param _admin Initial administrator address
     * @param _delayTime Initial delay in seconds (must be between MINIMUM_DELAY and MAXIMUM_DELAY)
     */
    constructor(address _admin, uint256 _delayTime) {
        if (_delayTime < MINIMUM_DELAY) revert TimeLock__DelayBelowMinimum();
        if (_delayTime > MAXIMUM_DELAY) revert TimeLock__DelayAboveMaximum();

        isAdmin[_admin] = true;
        totalAdmins = 1;
        delayTime = _delayTime;

        emit NewAdmin(_admin);
    }

    // ============================================================
    // RECEIVE/FALLBACK
    // ============================================================

    /**
     * @notice Receive function to accept ETH transfers
     * @dev Allows timelock to hold ETH for protocol operations
     */
    receive() external payable {}

    /**
     * @notice Fallback function for non-matching calls
     * @dev Allows timelock to receive ETH with data
     */
    fallback() external payable {}

    // ============================================================
    // TIMELOCK ADMIN FUNCTIONS (SELF-CALLED)
    // ============================================================

    /**
     * @notice Set new delay time
     * @dev Can only be called by timelock itself (via executeTransaction)
     * @param _newDelayTime New delay in seconds
     */
    function setDelay(uint256 _newDelayTime) external {
        if (msg.sender != address(this)) revert TimeLock__OnlyTimeLockItself();
        if (_newDelayTime < MINIMUM_DELAY) revert TimeLock__DelayBelowMinimum();
        if (_newDelayTime > MAXIMUM_DELAY) revert TimeLock__DelayAboveMaximum();

        delayTime = _newDelayTime;

        emit NewDelayTime(delayTime);
    }

    /**
     * @notice Set new pending admin
     * @dev Can only be called by timelock itself (via executeTransaction)
     * @param _pendingAdmin Address of new pending admin
     */
    function setPendingAdmin(address _pendingAdmin) external {
        if (msg.sender != address(this)) revert TimeLock__OnlyTimeLockItself();

        pendingAdmins[_pendingAdmin] = true;

        emit NewPendingAdmin(_pendingAdmin);
    }

    // ============================================================
    // ADMIN MANAGEMENT FUNCTIONS
    // ============================================================

    /**
     * @notice Accept admin role (pending admin only)
     * @dev Caller must be in pendingAdmins mapping
     */
    function acceptAdmin() external {
        if (!pendingAdmins[msg.sender]) revert TimeLock__OnlyPendingAdmin();

        isAdmin[msg.sender] = true;
        totalAdmins += 1;
        pendingAdmins[msg.sender] = false;

        emit NewAdmin(msg.sender);
    }

    /**
     * @notice Revoke own admin rights
     * @dev Can only be called by an admin. Must maintain at least one admin.
     */
    function selfRevokeAdmin() external {
        if (!isAdmin[msg.sender]) revert TimeLock__OnlyAdmin();
        if (totalAdmins <= 1) revert TimeLock__MustHaveAtLeastOneAdmin();

        isAdmin[msg.sender] = false;
        totalAdmins -= 1;

        emit RevokedAdmin(msg.sender);
    }

    // ============================================================
    // TRANSACTION QUEUE FUNCTIONS
    // ============================================================

    /**
     * @notice Queue a transaction for future execution
     * @dev Only admin can queue. ETA must be at least delayTime in the future.
     * @param target Target contract address
     * @param value ETH value to send (in wei)
     * @param signature Function signature (e.g., "transfer(address,uint256)")
     * @param data ABI-encoded function parameters
     * @param eta Earliest execution timestamp
     * @return txHash Hash of the queued transaction
     */
    function queueTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        returns (bytes32)
    {
        if (!isAdmin[msg.sender]) revert TimeLock__OnlyAdmin();
        if (eta < getBlockTimestamp() + delayTime) revert TimeLock__EtaBelowDelay();

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = true;

        emit QueueTransaction(txHash, target, value, signature, data, eta);
        return txHash;
    }

    /**
     * @notice Cancel a queued transaction
     * @dev Only admin can cancel
     * @param target Target contract address
     * @param value ETH value
     * @param signature Function signature
     * @param data ABI-encoded parameters
     * @param eta Execution timestamp
     */
    function cancelTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
    {
        if (!isAdmin[msg.sender]) revert TimeLock__OnlyAdmin();

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));
        queuedTransactions[txHash] = false;

        emit CancelTransaction(txHash, target, value, signature, data, eta);
    }

    /**
     * @notice Execute a queued transaction
     * @dev Only admin can execute. Must be after ETA but before ETA + EXEC_PERIOD.
     * @param target Target contract address
     * @param value ETH value to send
     * @param signature Function signature
     * @param data ABI-encoded parameters
     * @param eta Execution timestamp
     * @return returnData Return data from the executed call
     */
    function executeTransaction(address target, uint256 value, string memory signature, bytes memory data, uint256 eta)
        external
        payable
        nonReentrant
        returns (bytes memory)
    {
        if (!isAdmin[msg.sender]) revert TimeLock__OnlyAdmin();

        bytes32 txHash = keccak256(abi.encode(target, value, signature, data, eta));

        if (!queuedTransactions[txHash]) revert TimeLock__TransactionNotQueued();
        if (getBlockTimestamp() < eta) revert TimeLock__TransactionNotReady();
        if (getBlockTimestamp() > eta + EXEC_PERIOD) revert TimeLock__TransactionStale();

        queuedTransactions[txHash] = false;

        bytes memory callData;

        if (bytes(signature).length == 0) {
            callData = data;
        } else {
            callData = abi.encodePacked(bytes4(keccak256(bytes(signature))), data);
        }

        (bool success, bytes memory returnData) = target.call{value: value}(callData);
        if (!success) revert TimeLock__TransactionFailed();

        emit ExecuteTransaction(txHash, target, value, signature, data, eta);

        return returnData;
    }

    // ============================================================
    // EMERGENCY FUNCTIONS
    // ============================================================

    /**
     * @notice Transfer ETH from timelock contract
     * @dev Only admin can call. Used to rescue accidentally sent ETH.
     * @param _to Recipient address
     * @param _amount Amount of ETH to send (in wei)
     */
    function transferEther(address payable _to, uint256 _amount) external nonReentrant {
        if (!isAdmin[msg.sender]) revert TimeLock__OnlyAdmin();
        if (address(this).balance < _amount) revert TimeLock__InsufficientBalance();

        (bool success,) = _to.call{value: _amount}("");
        if (!success) revert TimeLock__EtherTransferFailed();

        emit EtherTransfer(_to, _amount);
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Get current block timestamp
     * @dev Internal helper for testability
     * @return Current block timestamp
     */
    function getBlockTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }
}
