// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IFlashBorrower
 * @author alvin@yolo.wtf
 * @notice Interface for flash loan borrowers
 * @dev Borrowers must implement these callbacks to receive flash loans
 *      Inspired by EIP-3156 with adaptations for YOLO Protocol
 */
interface IFlashBorrower {
    /**
     * @notice Callback for single asset flash loan
     * @dev Called by FlashLoanModule during flash loan execution
     *      Borrower must approve YoloHook to burn amount + fee
     * @param initiator Address that initiated the flash loan
     * @param token Token address being borrowed (synthetic asset)
     * @param amount Amount borrowed (in token decimals)
     * @param fee Fee amount to be repaid (in token decimals)
     * @param data Arbitrary data passed from borrower
     */
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data) external;

    /**
     * @notice Callback for batch flash loan
     * @dev Called by FlashLoanModule during batch flash loan execution
     *      Borrower must approve YoloHook to burn amounts[i] + fees[i] for each token
     * @param initiator Address that initiated the flash loan
     * @param tokens Array of token addresses being borrowed
     * @param amounts Array of amounts borrowed per token
     * @param fees Array of fees to be repaid per token
     * @param data Arbitrary data passed from borrower
     */
    function onBatchFlashLoan(
        address initiator,
        address[] calldata tokens,
        uint256[] calldata amounts,
        uint256[] calldata fees,
        bytes calldata data
    ) external;
}
