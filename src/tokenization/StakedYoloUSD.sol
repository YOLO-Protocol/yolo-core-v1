// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MintableIncentivizedERC20Upgradeable} from "./base/MintableIncentivizedERC20Upgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IYoloHook} from "../interfaces/IYoloHook.sol";

/**
 * @title StakedYoloUSD (sUSY)
 * @author alvin@yolo.wtf
 * @notice LP receipt token for USY-USDC anchor pool
 * @dev Represents proportional claim on TWO reserves (USY + USDC)
 *      CRITICAL DESIGN PRINCIPLES:
 *      - Exchange rate is TWO numbers (usyPerSUSY, usdcPerSUSY), not USD value
 *      - All outputs normalized to 18 decimals for consistency
 *      - Min-share mint formula prevents dilution attacks
 *      - Balanced deposits enforced within tolerance
 *      - Single source of truth: YoloHook reserves
 *      - Round down user outputs to favor pool
 *
 *      Inherits from MintableIncentivizedERC20Upgradeable for:
 *      - Future yield distribution via IncentivesController
 *      - Standardized YoloHook-only mint/burn with batch operations
 *      - ACL-based access control
 *      - ERC20Permit support
 */
contract StakedYoloUSD is MintableIncentivizedERC20Upgradeable, UUPSUpgradeable {
    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Role identifier (matches YoloHook)
    bytes32 public constant ASSETS_ADMIN = keccak256("ASSETS_ADMIN");

    /// @notice Maximum imbalance tolerance for deposits (100 = 1%)
    uint256 public constant MAX_IMBALANCE_BPS = 100; // 1% tolerance
    uint256 public constant BPS_DIVISOR = 10000;

    // ============================================================
    // ERRORS
    // ============================================================

    error StakedYoloUSD__Unauthorized();
    error StakedYoloUSD__InvalidAddress();

    // ============================================================
    // EVENTS
    // ============================================================

    event YoloHookUpdated(address indexed oldHook, address indexed newHook);

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor() {
        _disableInitializers();
    }

    // ============================================================
    // INITIALIZER
    // ============================================================

    function initialize(address _yoloHook, address _aclManager) external initializer {
        if (_yoloHook == address(0)) revert StakedYoloUSD__InvalidAddress();
        if (_aclManager == address(0)) revert StakedYoloUSD__InvalidAddress();

        __MintableIncentivizedERC20_init(_yoloHook, _aclManager, "Staked YOLO USD", "sUSY", 18);
        __UUPSUpgradeable_init();
    }

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyRole(bytes32 role) {
        if (!ACL_MANAGER.hasRole(role, msg.sender)) revert StakedYoloUSD__Unauthorized();
        _;
    }

    // Note: mint() and burn() are inherited from MintableIncentivizedERC20Upgradeable
    // with onlyYoloHook modifier already applied

    // ============================================================
    // PRIMARY VIEW: TWO-ASSET BREAKDOWN (CANONICAL)
    // ============================================================

    /**
     * @notice Get reserves backing each sUSY token (CANONICAL EXCHANGE RATE)
     * @dev Returns TWO numbers representing reserves per 1 sUSY
     *      BOTH values normalized to 18 decimals for consistency
     *      This is the TRUE exchange rate - not USD approximation
     * @return usyPerSUSY USY amount per 1 sUSY (18 decimals)
     * @return usdcPerSUSY USDC amount per 1 sUSY (18 decimals normalized)
     */
    function getReserveBreakdownPerSUSY() external view returns (uint256 usyPerSUSY, uint256 usdcPerSUSY) {
        uint256 supply = totalSupply();

        if (supply == 0) {
            // Bootstrap default: 1 sUSY = 1 USY + 1 USDC
            // Label: these are placeholder values, not real reserves
            return (1e18, 1e18);
        }

        // Get normalized reserves from YoloHook (single source of truth)
        (uint256 reserveUSY18, uint256 reserveUSDC18) = IYoloHook(YOLO_HOOK).getAnchorReservesNormalized18();

        // Calculate per-sUSY breakdown (proportional share)
        // Round down to favor pool
        usyPerSUSY = (reserveUSY18 * 1e18) / supply;
        usdcPerSUSY = (reserveUSDC18 * 1e18) / supply;
    }

    // ============================================================
    // PREVIEW FUNCTIONS (EXACT TOKEN AMOUNTS)
    // ============================================================

    /**
     * @notice Preview exact redemption amounts for burning sUSY
     * @dev Returns actual token amounts (both normalized to 18 decimals)
     *      Preview MUST match execution exactly
     * @param sUSYAmount Amount of sUSY to burn
     * @return usyOut18 USY to receive (18 decimals)
     * @return usdcOut18 USDC to receive (18 decimals normalized)
     */
    function previewRedeem(uint256 sUSYAmount) external view returns (uint256 usyOut18, uint256 usdcOut18) {
        // Delegate to YoloHook for accurate calculation
        return IYoloHook(YOLO_HOOK).previewRemoveLiquidity(sUSYAmount);
    }

    /**
     * @notice Preview sUSY minted for depositing USY + USDC
     * @dev Uses min-share formula to prevent dilution
     *      Enforces balanced deposits within tolerance
     *      Preview MUST match execution exactly
     * @param usyIn18 USY to deposit (18 decimals)
     * @param usdcIn18 USDC to deposit (18 decimals normalized)
     * @return sUSYToMint Expected sUSY tokens to receive
     */
    function previewMint(uint256 usyIn18, uint256 usdcIn18) external view returns (uint256 sUSYToMint) {
        // Delegate to YoloHook for accurate calculation
        return IYoloHook(YOLO_HOOK).previewAddLiquidity(usyIn18, usdcIn18);
    }

    // ============================================================
    // OPTIONAL: USD VALUE APPROXIMATION (NOT CANONICAL)
    // ============================================================

    /**
     * @notice Get approximate USD value per sUSY
     * @dev ⚠️ APPROXIMATION ONLY - assumes USY ≈ USDC ≈ $1
     *      NOT canonical exchange rate
     *      Use getReserveBreakdownPerSUSY() for accurate accounting
     *      For UI display only
     * @return approxUsdValue18 Approximate USD value (18 decimals)
     */
    function getApproxUsdValuePerSUSY() external view returns (uint256 approxUsdValue18) {
        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = this.getReserveBreakdownPerSUSY();

        // Assumption: 1 USY = 1 USDC = $1
        approxUsdValue18 = usyPerSUSY + usdcPerSUSY;
    }

    /**
     * @notice Get approximate total USD value of anchor pool
     * @dev ⚠️ APPROXIMATION ONLY - for UI display only
     * @return approxTotalValue18 Approximate total value (18 decimals)
     */
    function getApproxTotalPoolValueUsd() external view returns (uint256 approxTotalValue18) {
        (uint256 reserveUSY18, uint256 reserveUSDC18) = IYoloHook(YOLO_HOOK).getAnchorReservesNormalized18();

        // Assumption: 1 USY = 1 USDC = $1
        approxTotalValue18 = reserveUSY18 + reserveUSDC18;
    }

    // ============================================================
    // ADMIN FUNCTIONS
    // ============================================================

    /**
     * @notice Update YoloHook address (for hook rotation/upgrades)
     * @dev Only ASSETS_ADMIN can call
     * @param newHook New YoloHook address
     */
    function updateYoloHook(address newHook) external onlyRole(ASSETS_ADMIN) {
        if (newHook == address(0)) revert StakedYoloUSD__InvalidAddress();

        address oldHook = YOLO_HOOK;
        YOLO_HOOK = newHook;

        emit YoloHookUpdated(oldHook, newHook);
    }

    // ============================================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ASSETS_ADMIN) {}
}
