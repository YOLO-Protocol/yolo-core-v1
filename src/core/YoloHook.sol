// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";

/**
 * @title YoloHook
 * @author alvin@yolo.wtf
 * @notice Main hook contract for YOLO Protocol V1 - Yield-Optimized Leverage Onchain
 * @dev Uniswap V4 Hook integrating ACL-based access control and modular architecture
 *      - Proxy-safe: Immutables in constructor, storage init in initialize()
 *      - All hook permissions enabled for maximum flexibility
 *      - ACL-based access control (no Ownable/Pausable inheritance)
 *      - Reentrancy protection for external calls
 *      - Foundation for externally linked library modules (Aave-style)
 *      - Handles both anchor pool (USY-USDC Curve) and synthetic pools (oracle-based)
 */
contract YoloHook is BaseHook, ReentrancyGuard, Initializable {
    // ========================
    // CONSTANTS
    // ========================

    /// @notice Role for pausing protocol operations
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER");

    /// @notice Role for configuring assets and synthetic pairs
    bytes32 public constant ASSETS_ADMIN_ROLE = keccak256("ASSETS_ADMIN");

    /// @notice Role for risk parameter management
    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN");

    // ========================
    // IMMUTABLE STORAGE
    // ========================

    /// @notice ACL Manager for role-based access control
    /// @dev Immutable is proxy-safe (stored in bytecode, not storage)
    IACLManager public immutable ACL_MANAGER;

    // ========================
    // STATE VARIABLES
    // ========================

    /// @notice Protocol pause state
    /// @dev Initialized via initialize() function, not constructor (proxy-safe)
    bool private _paused;

    // ========================
    // EVENTS
    // ========================

    event Paused(address indexed account);
    event Unpaused(address indexed account);

    // ========================
    // ERRORS
    // ========================

    error YoloHook__CallerNotAuthorized();
    error YoloHook__ProtocolPaused();
    error YoloHook__ProtocolNotPaused();

    // ========================
    // MODIFIERS
    // ========================

    /**
     * @notice Ensure caller has PAUSER role
     * @dev Used for emergency pause/unpause functions
     */
    modifier onlyPauser() {
        if (!ACL_MANAGER.hasRole(PAUSER_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
        _;
    }

    /**
     * @notice Ensure caller has ASSETS_ADMIN role
     * @dev Used for creating synthetic assets and configuring asset parameters
     */
    modifier onlyAssetsAdmin() {
        if (!ACL_MANAGER.hasRole(ASSETS_ADMIN_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
        _;
    }

    /**
     * @notice Ensure caller has RISK_ADMIN role
     * @dev Used for configuring risk parameters (LTV, interest rates, liquidation penalties)
     */
    modifier onlyRiskAdmin() {
        if (!ACL_MANAGER.hasRole(RISK_ADMIN_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
        _;
    }

    /**
     * @notice Ensure protocol is not paused
     * @dev Used to protect user-facing functions during emergency pause
     */
    modifier whenNotPaused() {
        if (_paused) {
            revert YoloHook__ProtocolPaused();
        }
        _;
    }

    /**
     * @notice Ensure protocol is paused
     * @dev Used to ensure unpause is only called when protocol is paused
     */
    modifier whenPaused() {
        if (!_paused) {
            revert YoloHook__ProtocolNotPaused();
        }
        _;
    }

    // ========================
    // CONSTRUCTOR
    // ========================

    /**
     * @notice Deploy YoloHook implementation with immutable references
     * @param _poolManager Address of the Uniswap V4 Pool Manager contract
     * @param _aclManager Address of the ACL Manager contract for role-based access control
     * @dev Constructor only sets immutables (proxy-safe)
     *      Storage variables must be initialized via initialize() after proxy deployment
     *      Immutables are stored in bytecode and work correctly with proxy pattern
     */
    constructor(IPoolManager _poolManager, IACLManager _aclManager) BaseHook(_poolManager) {
        ACL_MANAGER = _aclManager;
        // Note: Do NOT initialize storage variables here
        // Storage init happens in initialize() for proxy compatibility
        _disableInitializers(); // Prevent implementation contract from being initialized
    }

    // ========================
    // INITIALIZER
    // ========================

    /**
     * @notice Initialize storage variables for proxy deployment
     * @dev Can only be called once due to initializer modifier
     *      Must be called immediately after proxy deployment
     *      Protocol starts in unpaused state
     */
    function initialize() external initializer {
        _paused = false;
    }

    // ========================
    // EXTERNAL VIEW FUNCTIONS
    // ========================

    /**
     * @notice Returns the permissions for this hook
     * @dev Enable all hook permissions for future upgradability and module integration
     *      - beforeSwap/afterSwap: Anchor pool (Curve) + Synthetic pool (oracle) swap logic
     *      - beforeSwapReturnDelta: Override default pool math with custom calculations
     *      - beforeInitialize/afterInitialize: Pool setup and validation
     *      - Liquidity hooks: Anchor pool LP management (sUSY minting)
     *      - Donate hooks: Reserved for future fee distribution mechanisms
     * @return permissions Struct containing all enabled hook permissions
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /**
     * @notice Check if protocol is currently paused
     * @return True if protocol is paused, false otherwise
     */
    function paused() public view returns (bool) {
        return _paused;
    }

    // ========================
    // ADMIN FUNCTIONS
    // ========================

    /**
     * @notice Pause the protocol (emergency stop)
     * @dev Can only be called by accounts with PAUSER role
     *      Prevents execution of user-facing functions while allowing admin operations
     */
    function pause() external onlyPauser whenNotPaused {
        _paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Unpause the protocol
     * @dev Can only be called by accounts with PAUSER role
     *      Resumes normal protocol operations after emergency pause
     */
    function unpause() external onlyPauser whenPaused {
        _paused = false;
        emit Unpaused(msg.sender);
    }
}
