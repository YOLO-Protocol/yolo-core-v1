// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AppStorage} from "../core/YoloHookStorage.sol";
import {DataTypes} from "./DataTypes.sol";
import {IFlashBorrower} from "../interfaces/IFlashBorrower.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title FlashLoanModule
 * @author alvin@yolo.wtf
 * @notice Externally linked library for flash loan operations
 * @dev Implements EIP-3156 inspired flash loans adapted for YOLO Protocol
 *      Uses mint→callback→burn pattern for synthetic assets
 *      Fees are minted to treasury, not burned
 */
library FlashLoanModule {
    using SafeERC20 for IERC20;

    // ============================================================
    // EVENTS
    // ============================================================

    event MaxFlashLoanAmountUpdated(address indexed syntheticToken, uint256 newMaxFlashLoanAmount);

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Maximum flash loan fee (100% = 10000 bps)
    uint256 private constant MAX_FLASH_LOAN_FEE_BPS = 10000;

    // ============================================================
    // ERRORS
    // ============================================================

    error FlashLoanModule__InvalidAsset();
    error FlashLoanModule__InvalidAmount();
    error FlashLoanModule__InactiveAsset();
    error FlashLoanModule__FlashLoansDisabled();
    error FlashLoanModule__ExceedsMaxFlashLoan();
    error FlashLoanModule__InvalidBorrower();
    error FlashLoanModule__InsufficientRepayment();
    error FlashLoanModule__InvalidArrayLength();
    error FlashLoanModule__AssetNotFound();

    // ============================================================
    // FLASH LOAN - SINGLE ASSET
    // ============================================================

    /**
     * @notice Execute a flash loan for a single synthetic asset
     * @dev Mints synthetic asset → calls borrower callback → burns repayment
     *      Fee is minted to treasury
     * @param s AppStorage reference
     * @param borrower Contract implementing IFlashBorrower
     * @param token Synthetic asset to borrow
     * @param amount Amount to borrow (in token decimals)
     * @param data Arbitrary data passed to borrower callback
     * @return success Whether flash loan succeeded
     */
    function flashLoan(AppStorage storage s, address borrower, address token, uint256 amount, bytes calldata data)
        external
        returns (bool success, uint256 fee)
    {
        // Validate inputs
        if (borrower == address(0)) revert FlashLoanModule__InvalidBorrower();
        if (amount == 0) revert FlashLoanModule__InvalidAmount();
        if (!s._isYoloAsset[token]) revert FlashLoanModule__InvalidAsset();

        // Check asset configuration
        DataTypes.AssetConfiguration storage config = s._assetConfigs[token];
        if (!config.isActive) revert FlashLoanModule__InactiveAsset();

        // Check flash loan cap (0 = disabled, >0 = cap, type(uint256).max = unlimited)
        if (config.maxFlashLoanAmount == 0) {
            revert FlashLoanModule__FlashLoansDisabled();
        }
        if (amount > config.maxFlashLoanAmount) {
            revert FlashLoanModule__ExceedsMaxFlashLoan();
        }

        // Calculate fee (zero for privileged flashloaners)
        if (IACLManager(s.ACL_MANAGER).hasRole(keccak256("PRIVILEGED_FLASHLOANER"), msg.sender)) {
            fee = 0; // Privileged flashloaners get zero fees
        } else {
            fee = (amount * s.flashLoanFeeBps) / 10000; // Normal fee for others
        }

        // Get current balance before minting
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));

        // Mint borrowed amount to borrower (temporary supply increase)
        _mintSynthetic(s, token, borrower, amount);

        // Call borrower's callback
        IFlashBorrower(borrower).onFlashLoan(msg.sender, token, amount, fee, data);

        // Get balance after callback
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        // Verify repayment (hook must have received amount + fee)
        // Note: We compare balances because borrower must transfer tokens back
        if (balanceAfter < balanceBefore + amount + fee) {
            revert FlashLoanModule__InsufficientRepayment();
        }

        // Burn principal (restores original supply)
        _burnSynthetic(s, token, address(this), amount);

        // Mint fee to treasury (fee is permanent supply increase)
        if (fee > 0 && s.treasury != address(0)) {
            _mintSynthetic(s, token, s.treasury, fee);
        }
        return (true, fee);
    }

    // ============================================================
    // FLASH LOAN - BATCH
    // ============================================================

    /**
     * @notice Execute a flash loan for multiple synthetic assets
     * @dev Mints all assets → calls borrower callback → burns all repayments
     *      Fees are minted to treasury
     * @param s AppStorage reference
     * @param borrower Contract implementing IFlashBorrower
     * @param tokens Array of synthetic assets to borrow
     * @param amounts Array of amounts to borrow (in token decimals)
     * @param data Arbitrary data passed to borrower callback
     * @return success Whether flash loan succeeded
     */
    function flashLoanBatch(
        AppStorage storage s,
        address borrower,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bool success, uint256[] memory fees) {
        // Validate inputs
        if (borrower == address(0)) revert FlashLoanModule__InvalidBorrower();
        if (tokens.length == 0 || tokens.length != amounts.length) {
            revert FlashLoanModule__InvalidArrayLength();
        }

        uint256 length = tokens.length;
        fees = new uint256[](length);
        uint256[] memory balancesBefore = new uint256[](length);

        // Phase 1: Validate and mint all tokens
        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];

            // Validate
            if (amount == 0) revert FlashLoanModule__InvalidAmount();
            if (!s._isYoloAsset[token]) revert FlashLoanModule__InvalidAsset();

            DataTypes.AssetConfiguration storage config = s._assetConfigs[token];
            if (!config.isActive) revert FlashLoanModule__InactiveAsset();

            // Check flash loan cap (0 = disabled, >0 = cap, type(uint256).max = unlimited)
            if (config.maxFlashLoanAmount == 0) {
                revert FlashLoanModule__FlashLoansDisabled();
            }
            if (amount > config.maxFlashLoanAmount) {
                revert FlashLoanModule__ExceedsMaxFlashLoan();
            }

            // Calculate fee (zero for privileged flashloaners)
            if (IACLManager(s.ACL_MANAGER).hasRole(keccak256("PRIVILEGED_FLASHLOANER"), msg.sender)) {
                fees[i] = 0; // Privileged flashloaners get zero fees
            } else {
                fees[i] = (amount * s.flashLoanFeeBps) / 10000; // Normal fee for others
            }

            // Store balance before
            balancesBefore[i] = IERC20(token).balanceOf(address(this));

            // Mint borrowed amount to borrower
            _mintSynthetic(s, token, borrower, amount);
        }

        // Phase 2: Call borrower's callback
        IFlashBorrower(borrower).onBatchFlashLoan(msg.sender, tokens, amounts, fees, data);

        // Phase 3: Verify repayments and burn/mint
        for (uint256 i = 0; i < length; i++) {
            address token = tokens[i];
            uint256 amount = amounts[i];
            uint256 fee = fees[i];

            // Verify repayment
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            if (balanceAfter < balancesBefore[i] + amount + fee) {
                revert FlashLoanModule__InsufficientRepayment();
            }

            // Burn principal
            _burnSynthetic(s, token, address(this), amount);

            // Mint fee to treasury
            if (fee > 0 && s.treasury != address(0)) {
                _mintSynthetic(s, token, s.treasury, fee);
            }
        }

        return (true, fees);
    }

    // ============================================================
    // PREVIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Preview flash loan fee for a single asset
     * @param s AppStorage reference
     * @param token Synthetic asset address
     * @param amount Amount to borrow
     * @return fee Fee amount in token decimals
     */
    function previewFlashLoanFee(AppStorage storage s, address token, uint256 amount)
        external
        view
        returns (uint256 fee)
    {
        if (!s._isYoloAsset[token]) return 0;
        fee = (amount * s.flashLoanFeeBps) / 10000;
    }

    /**
     * @notice Get maximum flash loan amount for an asset
     * @param s AppStorage reference
     * @param token Synthetic asset address
     * @return maxAmount Maximum flash loan amount (0 = disabled, >0 = cap, type(uint256).max = unlimited)
     */
    function maxFlashLoan(AppStorage storage s, address token) external view returns (uint256 maxAmount) {
        if (!s._isYoloAsset[token]) return 0;

        DataTypes.AssetConfiguration storage config = s._assetConfigs[token];
        if (!config.isActive) return 0;

        return config.maxFlashLoanAmount; // 0 = disabled, >0 = cap, type(uint256).max = unlimited
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Update maximum flash loan amount for a synthetic asset
     * @dev Only callable via YoloHook by RISK_ADMIN
     * @param s AppStorage reference
     * @param syntheticToken Address of the synthetic token
     * @param newMaxFlashLoanAmount New maximum flash loan amount (0 = disable, type(uint256).max = unlimited)
     */
    function updateMaxFlashLoanAmount(AppStorage storage s, address syntheticToken, uint256 newMaxFlashLoanAmount)
        external
    {
        if (!s._isYoloAsset[syntheticToken]) revert FlashLoanModule__AssetNotFound();

        s._assetConfigs[syntheticToken].maxFlashLoanAmount = newMaxFlashLoanAmount;
        emit MaxFlashLoanAmountUpdated(syntheticToken, newMaxFlashLoanAmount);
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Mint synthetic asset tokens
     * @dev Calls mint() on the synthetic asset token (UUPS proxy)
     * @param s AppStorage reference
     * @param token Synthetic asset address
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function _mintSynthetic(AppStorage storage s, address token, address to, uint256 amount) private {
        // Call mint function on synthetic asset (YoloAsset contract)
        // YoloAsset has: function mint(address to, uint256 amount) external onlyYoloHook
        (bool success, bytes memory returndata) =
            token.call(abi.encodeWithSignature("mint(address,uint256)", to, amount));

        if (!success) {
            // Bubble up revert reason if available
            if (returndata.length > 0) {
                assembly {
                    revert(add(32, returndata), mload(returndata))
                }
            }
            revert("FlashLoanModule: mint failed");
        }
    }

    /**
     * @notice Burn synthetic asset tokens
     * @dev Calls burn() on the synthetic asset token (UUPS proxy)
     * @param s AppStorage reference
     * @param token Synthetic asset address
     * @param from Address to burn from (must have approved hook)
     * @param amount Amount to burn
     */
    function _burnSynthetic(AppStorage storage s, address token, address from, uint256 amount) private {
        // Call burn function on synthetic asset (YoloAsset contract)
        // YoloAsset has: function burn(address from, uint256 amount) external onlyYoloHook
        (bool success, bytes memory returndata) =
            token.call(abi.encodeWithSignature("burn(address,uint256)", from, amount));

        if (!success) {
            // Bubble up revert reason if available
            if (returndata.length > 0) {
                assembly {
                    revert(add(32, returndata), mload(returndata))
                }
            }
            revert("FlashLoanModule: burn failed");
        }
    }
}
