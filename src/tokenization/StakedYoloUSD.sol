// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20PermitUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
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
 */
contract StakedYoloUSD is Initializable, ERC20Upgradeable, ERC20PermitUpgradeable, UUPSUpgradeable {
    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Role identifier (matches YoloHook)
    bytes32 public constant ASSETS_ADMIN = keccak256("ASSETS_ADMIN");

    /// @notice Maximum imbalance tolerance for deposits (100 = 1%)
    uint256 public constant MAX_IMBALANCE_BPS = 100; // 1% tolerance
    uint256 public constant BPS_DIVISOR = 10000;

    // ============================================================
    // IMMUTABLES
    // ============================================================

    IACLManager public immutable ACL_MANAGER;

    // ============================================================
    // STATE VARIABLES
    // ============================================================

    address public yoloHook;

    // ============================================================
    // ERRORS
    // ============================================================

    error OnlyYoloHook();
    error Unauthorized();
    error InvalidAddress();

    // ============================================================
    // EVENTS
    // ============================================================

    event YoloHookUpdated(address indexed oldHook, address indexed newHook);

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    constructor(IACLManager _aclManager) {
        ACL_MANAGER = _aclManager;
        _disableInitializers();
    }

    // ============================================================
    // INITIALIZER
    // ============================================================

    function initialize(address _yoloHook) external initializer {
        if (_yoloHook == address(0)) revert InvalidAddress();

        __ERC20_init("Staked YOLO USD", "sUSY");
        __ERC20Permit_init("Staked YOLO USD");
        __UUPSUpgradeable_init();

        yoloHook = _yoloHook;
    }

    // ============================================================
    // MODIFIERS
    // ============================================================

    modifier onlyYoloHook() {
        if (msg.sender != yoloHook) revert OnlyYoloHook();
        _;
    }

    modifier onlyRole(bytes32 role) {
        if (!ACL_MANAGER.hasRole(role, msg.sender)) revert Unauthorized();
        _;
    }

    // ============================================================
    // MINT & BURN (ONLY YOLO HOOK)
    // ============================================================

    /**
     * @notice Mint sUSY LP tokens
     * @dev ONLY callable by YoloHook after reserve updates
     *      Amount calculated using min-share formula
     * @param to Liquidity provider
     * @param amount sUSY amount to mint
     */
    function mint(address to, uint256 amount) external onlyYoloHook {
        _mint(to, amount);
    }

    /**
     * @notice Burn sUSY LP tokens
     * @dev ONLY callable by YoloHook during liquidity removal
     * @param from Token holder
     * @param amount sUSY amount to burn
     */
    function burn(address from, uint256 amount) external onlyYoloHook {
        _burn(from, amount);
    }

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
        (uint256 reserveUSY18, uint256 reserveUSDC18) = IYoloHook(yoloHook).getAnchorReservesNormalized18();

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
        return IYoloHook(yoloHook).previewRemoveLiquidity(sUSYAmount);
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
        return IYoloHook(yoloHook).previewAddLiquidity(usyIn18, usdcIn18);
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
        (uint256 reserveUSY18, uint256 reserveUSDC18) = IYoloHook(yoloHook).getAnchorReservesNormalized18();

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
        if (newHook == address(0)) revert InvalidAddress();

        address oldHook = yoloHook;
        yoloHook = newHook;

        emit YoloHookUpdated(oldHook, newHook);
    }

    // ============================================================
    // UUPS UPGRADE AUTHORIZATION
    // ============================================================

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(ASSETS_ADMIN) {}
}
