// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYoloHook} from "../interfaces/IYoloHook.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";
import {IRouter} from "../interfaces/IRouter.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/**
 * @title YoloLooper
 * @author alvin@yolo.wtf
 * @notice Helper contract for creating leveraged collateral positions via flash loans
 * @dev Enables capital-efficient leverage loops using flash loans + external router + YOLO internal routing
 *
 *      ═══════════════════════════════════════════════════════════════════════
 *      LEVERAGE FLOW (Open/Increase Position)
 *      ═══════════════════════════════════════════════════════════════════════
 *
 *      1. User provides collateral (e.g., PT-USDe) to Looper
 *      2. Calculate collateral USD value using oracle
 *      3. Calculate how much synthetic asset to borrow (based on target leverage)
 *      4. Flash loan synthetic asset (yNVDA, yETH, or USY)
 *      5. **INTERNAL YOLO**: syntheticAsset → USY → USDC (via YOLO router adapter)
 *      6. **EXTERNAL ROUTER**: USDC → collateral (via Kyber/MockRouter for PT tokens, exotic assets)
 *      7. Borrow synthetic + deposit ALL collateral (combined operation creates/updates position)
 *      8. Result: Leveraged position created/increased
 *
 *      Example: User has 100 PT-USDe ($0.98 each, discount bond), wants 5x leverage with yNVDA ($500)
 *      - Collateral value = 100 * $0.98 = $98
 *      - Target value = $98 * 5 = $490
 *      - Additional needed = $490 - $98 = $392
 *      - Flash loan: $392 / $500 = 0.784 yNVDA
 *      - YOLO: 0.784 yNVDA → USY → 392 USDC
 *      - Kyber: 392 USDC → $392 / $0.98 = 400 PT-USDe
 *      - Borrow + Deposit: 0.784 yNVDA borrowed, 500 PT-USDe deposited (single combined call)
 *      - Result: 5x position (500 PT-USDe × $0.98 = $490 collateral, 0.784 yNVDA × $500 = $392 debt)
 *
 *      ═══════════════════════════════════════════════════════════════════════
 *      DELEVERAGE FLOW (Close/Reduce Position)
 *      ═══════════════════════════════════════════════════════════════════════
 *
 *      1. Calculate how much debt to repay (partial or full)
 *      2. Flash loan synthetic asset (amount to repay)
 *      3. Repay debt on behalf of user (reduces debt, frees collateral)
 *      4. Withdraw freed collateral from user's position
 *      5. **EXTERNAL ROUTER**: collateral → USDC (via Kyber/MockRouter for exotic assets)
 *      6. **INTERNAL YOLO**: USDC → USY → syntheticAsset (via Uniswap V4 router)
 *      7. Repay flash loan
 *      8. Return any remaining collateral to user
 *      9. Result: Leveraged position reduced/closed
 *
 *      Example: User has 5x position (500 PT-USDe × $0.98 = $490, 0.784 yNVDA × $500 = $392 debt)
 *      - Current equity: $490 - $392 = $98
 *      - Target: 2x leverage (Collateral = 2 × Equity)
 *      - Target collateral: 2 × $98 = $196, Target debt: $98
 *      - Need to repay: $392 - $98 = $294 → $294 / $500 = 0.588 yNVDA
 *      - Flash loan: 0.588 yNVDA
 *      - Repay: 0.588 yNVDA (debt goes from 0.784 → 0.196 yNVDA)
 *      - Withdraw: $294 collateral freed → $294 / $0.98 = 300 PT-USDe
 *      - Kyber: 300 PT-USDe × $0.98 = $294 → 294 USDC
 *      - YOLO: 294 USDC → USY → yNVDA = $294 / $500 = 0.588 yNVDA
 *      - Repay flash: 0.588 yNVDA
 *      - Result: 2x position (200 PT-USDe × $0.98 = $196, 0.196 yNVDA × $500 = $98 debt)
 *
 *      ═══════════════════════════════════════════════════════════════════════
 *
 *      FEATURES:
 *      - Supports decimal leverage (e.g., 9.832x = 9832000000000000000 with 18 decimals)
 *      - Supports partial operations (increase/decrease existing positions)
 *      - Uses flash loans to avoid solvency issues during deleverage
 *      - Works with exotic collateral (PT tokens, LP tokens, etc.) via external router
 *
 *      Security:
 *      - Requires LOOPER_ROLE on YoloHook for onBehalfOf operations
 *      - Requires PRIVILEGED_FLASHLOANER_ROLE for zero-fee flash loans
 *      - Uses YoloOracle for accurate calculations
 *      - Slippage protection on external swaps
 *      - User retains full ownership of position
 */
contract YoloLooper is IERC3156FlashBorrower {
    using SafeERC20 for IERC20;

    // ============================================================
    // ERRORS
    // ============================================================

    error YoloLooper__InvalidCaller();
    error YoloLooper__InvalidInitiator();
    error YoloLooper__InvalidAsset();
    error YoloLooper__InsufficientCollateral();
    error YoloLooper__SlippageExceeded();
    error YoloLooper__InvalidLeverage();
    error YoloLooper__ZeroAddress();
    error YoloLooper__InvalidOperation();

    // ============================================================
    // IMMUTABLES
    // ============================================================

    /// @notice YoloHook contract for CDP operations
    IYoloHook public immutable YOLO_HOOK;

    /// @notice YoloOracle for price feeds
    /// @dev Used to calculate flash loan amounts and verify swap outputs
    IYoloOracle public immutable YOLO_ORACLE;

    /// @notice External router for collateral ↔ USDC conversion
    /// @dev External DEX aggregator (MockRouter in tests, Kyber/1inch/Uniswap in production)
    ///      Handles exotic assets like PT tokens, LP tokens, etc.
    ///      EXTERNAL_ROUTER ONLY converts: collateral ↔ USDC
    IRouter public immutable EXTERNAL_ROUTER;

    /// @notice YOLO router for protocol internal swaps (USDC ↔ USY ↔ synthetics)
    /// @dev Adapter wrapping Uniswap V4 action-based API into IRouter interface
    ///      Handles USDC ↔ USY ↔ synthetic swaps via Uniswap V4 pools
    ///      Adapter implementation deployed separately (UniswapV4RouterAdapter.sol)
    IRouter public immutable YOLO_ROUTER;

    /// @notice USDC address (gateway to YOLO protocol)
    /// @dev External router converts collateral ↔ USDC, then YOLO routing takes over
    address public immutable USDC;

    /// @notice USY address (anchor stablecoin)
    /// @dev Used for internal routing: USDC ↔ USY ↔ synthetic assets
    address public immutable USY;

    /// @notice Anchor pool key (USDC-USY)
    /// @dev Used for swapping USDC ↔ USY via Curve StableSwap
    ///      Cannot be immutable (struct type), set in constructor
    PoolKey public ANCHOR_POOL_KEY;

    // ============================================================
    // CONSTANTS
    // ============================================================

    /// @notice Flash loan callback success signature
    /// @dev Required return value for IERC3156FlashBorrower.onFlashLoan
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    /// @notice Minimum leverage multiplier (1x = 1e18)
    /// @dev Leverage below 1x makes no economic sense
    uint256 private constant MIN_LEVERAGE = 1e18;

    /// @notice Maximum leverage multiplier (100x = 100e18)
    /// @dev Safety cap to prevent extreme positions
    uint256 private constant MAX_LEVERAGE = 100e18;

    /// @notice Operation type: Leverage (open/increase position)
    uint8 private constant OP_LEVERAGE = 1;

    /// @notice Operation type: Deleverage (close/reduce position)
    uint8 private constant OP_DELEVERAGE = 2;

    // ============================================================
    // CONSTRUCTOR
    // ============================================================

    /**
     * @notice Deploy YoloLooper with immutable references
     * @param _yoloHook Address of the YoloHook contract
     * @param _yoloOracle Address of the YoloOracle contract
     * @param _externalRouter Address of the external DEX router (MockRouter/Kyber/1inch adapter)
     * @param _yoloRouter Address of the YOLO router (Uniswap V4 adapter implementing IRouter)
     * @param _usdc Address of the USDC token (gateway to YOLO protocol)
     * @param _usy Address of the USY token (anchor stablecoin)
     * @param _anchorPoolKey Anchor pool key for USDC-USY swaps
     */
    constructor(
        address _yoloHook,
        address _yoloOracle,
        address _externalRouter,
        address _yoloRouter,
        address _usdc,
        address _usy,
        PoolKey memory _anchorPoolKey
    ) {
        if (
            _yoloHook == address(0) || _yoloOracle == address(0) || _externalRouter == address(0)
                || _yoloRouter == address(0) || _usdc == address(0) || _usy == address(0)
        ) {
            revert YoloLooper__ZeroAddress();
        }

        YOLO_HOOK = IYoloHook(_yoloHook);
        YOLO_ORACLE = IYoloOracle(_yoloOracle);
        EXTERNAL_ROUTER = IRouter(_externalRouter);
        YOLO_ROUTER = IRouter(_yoloRouter);
        USDC = _usdc;
        USY = _usy;
        ANCHOR_POOL_KEY = _anchorPoolKey;
    }

    // ============================================================
    // LEVERAGE OPERATIONS
    // ============================================================

    /**
     * @notice Create or increase a leveraged collateral position
     * @dev Flow:
     *      1. User provides collateral (PT-USDe, LP tokens, etc.)
     *      2. Calculate USD value using oracle
     *      3. Calculate how much synthetic asset to borrow
     *      4. Flash loan synthetic asset
     *      5. In callback:
     *         a. YOLO: synthetic → USY → USDC (internal swaps)
     *         b. External Router: USDC → collateral (Kyber handles exotic assets)
     *         c. Deposit total collateral on behalf of user
     *         d. Borrow synthetic to repay flash loan
     *      6. Result: Leveraged position
     *
     *      Example: 100 PT-USDe + 5x leverage with yNVDA
     *      - Value = $100, target = $500, need $400
     *      - Flash 0.8 yNVDA ($500 each)
     *      - yNVDA → USY → USDC → PT-USDe
     *      - Deposit 500 PT-USDe, borrow 0.8 yNVDA
     *
     * @param collateral Collateral asset (PT-USDe, LP tokens, wstETH, etc.)
     * @param syntheticAsset Synthetic asset to borrow (yNVDA, yETH, yGOLD, USY)
     * @param collateralAmount Amount of collateral from user (native decimals)
     * @param targetLeverage Target leverage in 18 decimals (5e18 = 5x, 9832e15 = 9.832x)
     * @param minCollateralOut Minimum additional collateral from swaps (slippage protection)
     */
    function leverage(
        address collateral,
        address syntheticAsset,
        uint256 collateralAmount,
        uint256 targetLeverage,
        uint256 minCollateralOut
    ) external {
        // Validation
        if (targetLeverage < MIN_LEVERAGE || targetLeverage > MAX_LEVERAGE) {
            revert YoloLooper__InvalidLeverage();
        }
        if (collateralAmount == 0) revert YoloLooper__InsufficientCollateral();

        // Transfer initial collateral from user
        IERC20(collateral).safeTransferFrom(msg.sender, address(this), collateralAmount);

        // Calculate how much synthetic asset to flash loan
        uint256 flashLoanAmount =
            _calculateLeverageFlashLoan(collateral, syntheticAsset, collateralAmount, targetLeverage);

        // Encode callback data
        bytes memory data = abi.encode(
            OP_LEVERAGE, // operation type
            msg.sender, // user
            collateral, // collateral asset
            syntheticAsset, // synthetic to borrow
            collateralAmount, // initial collateral
            minCollateralOut // slippage protection
        );

        // Flash loan synthetic asset (zero fee due to PRIVILEGED_FLASHLOANER_ROLE)
        YOLO_HOOK.leverageFlashLoan(address(this), syntheticAsset, flashLoanAmount, data);
    }

    /**
     * @notice Reduce or close a leveraged position
     * @dev Flow:
     *      1. Calculate how much debt to repay (partial or full)
     *      2. Flash loan synthetic asset
     *      3. In callback:
     *         a. Repay debt on behalf of user (frees collateral)
     *         b. Withdraw freed collateral
     *         c. External Router: collateral → USDC
     *         d. YOLO: USDC → USY → synthetic (internal swaps)
     *         e. Repay flash loan
     *         f. Return remaining to user
     *      4. Result: Reduced/closed position
     *
     *      Example: Reduce 5x to 2x
     *      - Repay 0.48 yNVDA (partial)
     *      - Flash 0.48 yNVDA, repay, withdraw ~300 PT-USDe
     *      - PT-USDe → USDC → USY → yNVDA
     *      - Repay flash, return excess
     *
     * @param collateral Collateral asset
     * @param syntheticAsset Synthetic asset debt
     * @param repayAmount Amount of synthetic asset to repay (0 = full repayment)
     * @param minCollateralFreed Minimum collateral expected to be freed (slippage protection)
     */
    function deleverage(address collateral, address syntheticAsset, uint256 repayAmount, uint256 minCollateralFreed)
        external
    {
        // If repayAmount = 0, calculate full debt
        if (repayAmount == 0) {
            repayAmount = YOLO_HOOK.getPositionDebt(msg.sender, collateral, syntheticAsset);
        }
        if (repayAmount == 0) revert YoloLooper__InvalidOperation();

        // Encode callback data
        bytes memory data = abi.encode(
            OP_DELEVERAGE, // operation type
            msg.sender, // user
            collateral, // collateral asset
            syntheticAsset, // synthetic debt
            repayAmount, // amount to repay
            minCollateralFreed // slippage protection
        );

        // Flash loan synthetic asset to repay debt
        YOLO_HOOK.leverageFlashLoan(address(this), syntheticAsset, repayAmount, data);
    }

    // ============================================================
    // FLASH LOAN CALLBACK
    // ============================================================

    /**
     * @notice Flash loan callback - routes to leverage or deleverage logic
     * @dev Called by YoloHook during flash loan execution
     *
     * @param initiator Address that initiated the flash loan (must be this contract)
     * @param asset Asset borrowed in flash loan (synthetic asset)
     * @param amount Amount borrowed
     * @param fee Flash loan fee (should be 0 for PRIVILEGED_FLASHLOANER_ROLE)
     * @param data Encoded callback data
     * @return CALLBACK_SUCCESS signature
     */
    function onFlashLoan(address initiator, address asset, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        // Security validation
        if (msg.sender != address(YOLO_HOOK)) revert YoloLooper__InvalidCaller();
        if (initiator != address(this)) revert YoloLooper__InvalidInitiator();

        // Decode operation type
        uint8 opType = abi.decode(data, (uint8));

        if (opType == OP_LEVERAGE) {
            _handleLeverageCallback(asset, amount, fee, data);
        } else if (opType == OP_DELEVERAGE) {
            _handleDeleverageCallback(asset, amount, fee, data);
        } else {
            revert YoloLooper__InvalidOperation();
        }

        return CALLBACK_SUCCESS;
    }

    // ============================================================
    // INTERNAL SWAP HELPERS
    // ============================================================

    /**
     * @notice Swap synthetic asset to USDC via YOLO router (2-hop: synthetic → USY → USDC)
     * @dev Router adapter handles multi-hop routing internally
     *      Currently called with minUsdcOut=0, relying on external leg slippage protection
     * @param syntheticAsset Address of synthetic asset to swap from
     * @param amountIn Amount of synthetic asset to swap
     * @param minUsdcOut Minimum USDC to receive (currently unused, set to 0)
     * @return usdcOut Actual USDC received
     */
    function _swapSyntheticToUsdc(address syntheticAsset, uint256 amountIn, uint256 minUsdcOut)
        internal
        returns (uint256 usdcOut)
    {
        // Approve YOLO router to spend synthetic asset
        IERC20(syntheticAsset).forceApprove(address(YOLO_ROUTER), amountIn);

        // Execute swap via adapter (handles 2-hop routing: synthetic → USY → USDC)
        usdcOut = YOLO_ROUTER.swap(syntheticAsset, USDC, amountIn, minUsdcOut);
    }

    /**
     * @notice Swap USDC to synthetic asset via YOLO router (2-hop: USDC → USY → synthetic)
     * @dev Router adapter handles multi-hop routing internally
     *      Called with minSyntheticOut = flash loan amount to ensure repayment succeeds
     * @param syntheticAsset Address of synthetic asset to swap to
     * @param amountIn Amount of USDC to swap
     * @param minSyntheticOut Minimum synthetic to receive (enforces flash loan repayment)
     * @return syntheticOut Actual synthetic asset received
     */
    function _swapUsdcToSynthetic(address syntheticAsset, uint256 amountIn, uint256 minSyntheticOut)
        internal
        returns (uint256 syntheticOut)
    {
        // Approve YOLO router to spend USDC
        IERC20(USDC).forceApprove(address(YOLO_ROUTER), amountIn);

        // Execute swap via adapter (handles 2-hop routing: USDC → USY → synthetic)
        syntheticOut = YOLO_ROUTER.swap(USDC, syntheticAsset, amountIn, minSyntheticOut);
    }

    /**
     * @notice Calculate maximum collateral that can be freed after debt repayment
     * @param user User address who owns the position
     * @param collateral Collateral asset address
     * @param syntheticAsset Synthetic asset address
     * @return maxFreed Maximum amount of collateral that can be withdrawn
     */
    function _calculateMaxFreedCollateral(address user, address collateral, address syntheticAsset)
        internal
        view
        returns (uint256 maxFreed)
    {
        DataTypes.UserPosition memory position = YOLO_HOOK.getUserPosition(user, collateral, syntheticAsset);
        if (position.collateralSuppliedAmount == 0) return 0;

        // Get current debt
        uint256 debtAfter = YOLO_HOOK.getPositionDebt(user, collateral, syntheticAsset);

        // If no debt, all collateral is free
        if (debtAfter == 0) {
            return position.collateralSuppliedAmount;
        }

        uint256 collateralPrice = YOLO_ORACLE.getAssetPrice(collateral);
        uint256 syntheticPrice = YOLO_ORACLE.getAssetPrice(syntheticAsset);

        // Get LTV and decimals
        DataTypes.PairConfiguration memory pairConfig = YOLO_HOOK.getPairConfiguration(syntheticAsset, collateral);
        uint256 ltvBps = pairConfig.ltv;
        uint256 collateralDecimals = _getTokenDecimals(collateral);
        uint256 syntheticDecimals = _getTokenDecimals(syntheticAsset);

        // Calculate debt value in USD
        uint256 debtValueUSD = (debtAfter * syntheticPrice) / (10 ** syntheticDecimals);

        // Calculate minimum collateral value needed
        uint256 requiredValueUSD = (debtValueUSD * 10000) / ltvBps;

        // Convert USD value to collateral tokens
        uint256 requiredCollateral = (requiredValueUSD * (10 ** collateralDecimals)) / collateralPrice;

        // Add 0.5% safety buffer to avoid rounding issues
        uint256 safetyBuffer = (requiredCollateral * 1005) / 1000;

        if (position.collateralSuppliedAmount <= safetyBuffer) return 0;

        maxFreed = position.collateralSuppliedAmount - safetyBuffer;
    }

    /**
     * @notice Calculate and withdraw freed collateral after debt repayment (DEPRECATED - kept for compatibility)
     * @param user User address who owns the position
     * @param collateral Collateral asset address
     * @param syntheticAsset Synthetic asset address
     * @param minExpected Minimum collateral expected to be freed
     * @return freedAmount Amount of collateral withdrawn
     */
    function _withdrawFreedCollateral(address user, address collateral, address syntheticAsset, uint256 minExpected)
        internal
        returns (uint256 freedAmount)
    {
        freedAmount = _calculateMaxFreedCollateral(user, collateral, syntheticAsset);

        if (freedAmount == 0) return 0;
        if (freedAmount < minExpected) revert YoloLooper__SlippageExceeded();

        // Withdraw freed collateral to this contract
        YOLO_HOOK.withdrawCollateral(collateral, syntheticAsset, freedAmount, user, address(this));
    }

    /**
     * @notice Get token decimals
     * @param token Token address
     * @return decimals Token decimals
     */
    function _getTokenDecimals(address token) internal view returns (uint256) {
        // Try calling decimals() - most ERC20 tokens support this
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (success && data.length >= 32) {
            return abi.decode(data, (uint256));
        }
        // Default to 18 if call fails
        return 18;
    }

    // ============================================================
    // INTERNAL CALLBACKS
    // ============================================================

    /**
     * @notice Handle leverage callback
     * @dev Flow: synthetic → USY → USDC → collateral → deposit → borrow
     */
    function _handleLeverageCallback(address asset, uint256 amount, uint256 fee, bytes calldata data) internal {
        // Decode callback data
        (
            ,
            address user,
            address collateral,
            address syntheticAsset,
            uint256 initialCollateral,
            uint256 minCollateralOut
        ) = abi.decode(data, (uint8, address, address, address, uint256, uint256));

        // Verify asset matches
        if (asset != syntheticAsset) revert YoloLooper__InvalidAsset();

        // STEP 1: YOLO Internal - synthetic → USY → USDC (via Uniswap V4)
        uint256 usdcAmount = _swapSyntheticToUsdc(syntheticAsset, amount, 0); // minOut = 0 for now, can add slippage param

        // STEP 2: External Router - USDC → collateral
        IERC20(USDC).forceApprove(address(EXTERNAL_ROUTER), usdcAmount);
        uint256 swappedCollateral = EXTERNAL_ROUTER.swap(USDC, collateral, usdcAmount, minCollateralOut);

        if (swappedCollateral < minCollateralOut) {
            revert YoloLooper__SlippageExceeded();
        }

        // STEP 3: Borrow synthetic asset with collateral deposit (creates/updates position)
        // Combined operation: deposit total collateral + borrow synthetic to repay flash loan
        uint256 totalCollateral = initialCollateral + swappedCollateral;
        IERC20(collateral).forceApprove(address(YOLO_HOOK), totalCollateral);

        YOLO_HOOK.borrow(
            syntheticAsset,
            amount + fee, // Borrow enough to repay flash loan + fee
            collateral,
            totalCollateral, // Deposit all collateral (initial + swapped)
            user // onBehalfOf: position owner and debt holder
        );

        // STEP 4: Transfer borrowed synthetic tokens back to YoloHook for flash loan repayment
        // The tokens we borrowed are now in this contract, we need to transfer them to YoloHook
        IERC20(syntheticAsset).safeTransfer(address(YOLO_HOOK), amount + fee);
    }

    /**
     * @notice Handle deleverage callback
     * @dev Flow: repay debt → calculate minimum collateral needed → swap → repay flash loan →
     *      use excess synthetic for more debt repayment → redeposit unused collateral
     */
    function _handleDeleverageCallback(address asset, uint256 amount, uint256 fee, bytes calldata data) internal {
        // Decode callback data
        (, address user, address collateral, address syntheticAsset, uint256 repayAmount, uint256 minCollateralFreed) =
            abi.decode(data, (uint8, address, address, address, uint256, uint256));

        // Verify asset matches
        if (asset != syntheticAsset) revert YoloLooper__InvalidAsset();

        // STEP 1: Repay debt on behalf of user (frees collateral)
        IERC20(syntheticAsset).forceApprove(address(YOLO_HOOK), repayAmount);
        YOLO_HOOK.repay(syntheticAsset, collateral, repayAmount, false, user);

        // STEP 2: Calculate minimum collateral needed to repay flash loan
        // Get oracle prices to estimate swap ratios
        uint256 collateralPrice = YOLO_ORACLE.getAssetPrice(collateral);
        uint256 syntheticPrice = YOLO_ORACLE.getAssetPrice(syntheticAsset);
        uint256 collateralDecimals = _getTokenDecimals(collateral);
        uint256 syntheticDecimals = _getTokenDecimals(syntheticAsset);

        // Calculate value needed in USD (flash loan + fee in synthetic)
        uint256 syntheticValueNeeded = ((amount + fee) * syntheticPrice) / (10 ** syntheticDecimals);

        // Add 2% buffer for slippage and rounding
        uint256 collateralNeeded = (syntheticValueNeeded * (10 ** collateralDecimals) * 102) / (collateralPrice * 100);

        // STEP 3: Withdraw only the collateral needed (not all freed collateral)
        uint256 maxFreed = _calculateMaxFreedCollateral(user, collateral, syntheticAsset);

        // Check slippage protection - user expects to free at least minCollateralFreed
        if (maxFreed < minCollateralFreed) revert YoloLooper__SlippageExceeded();

        uint256 collateralToWithdraw = collateralNeeded > maxFreed ? maxFreed : collateralNeeded;

        if (collateralToWithdraw == 0) revert YoloLooper__InvalidOperation();

        // Withdraw calculated amount
        YOLO_HOOK.withdrawCollateral(collateral, syntheticAsset, collateralToWithdraw, user, address(this));

        // STEP 4: External Router - collateral → USDC
        IERC20(collateral).forceApprove(address(EXTERNAL_ROUTER), collateralToWithdraw);
        uint256 usdcAmount = EXTERNAL_ROUTER.swap(collateral, USDC, collateralToWithdraw, 0);

        // STEP 5: YOLO Internal - USDC → USY → synthetic (via Uniswap V4)
        uint256 syntheticAmount = _swapUsdcToSynthetic(syntheticAsset, usdcAmount, 0); // Remove min requirement

        // STEP 6: Repay flash loan
        IERC20(syntheticAsset).safeTransfer(address(YOLO_HOOK), amount + fee);

        // STEP 7: Handle excess synthetic
        if (syntheticAmount > (amount + fee)) {
            uint256 excessSynthetic = syntheticAmount - (amount + fee);

            // Check if there's remaining debt after the initial repayment
            uint256 remainingDebt = YOLO_HOOK.getPositionDebt(user, collateral, syntheticAsset);

            if (remainingDebt > 0) {
                // Use excess to repay more debt
                uint256 repaymentAmount = excessSynthetic > remainingDebt ? remainingDebt : excessSynthetic;
                IERC20(syntheticAsset).forceApprove(address(YOLO_HOOK), repaymentAmount);
                YOLO_HOOK.repay(syntheticAsset, collateral, repaymentAmount, false, user);

                // Update excess after repayment
                excessSynthetic = excessSynthetic > repaymentAmount ? excessSynthetic - repaymentAmount : 0;
            }

            // If there's still excess synthetic (or no debt to repay), refund to user
            if (excessSynthetic > 0) {
                IERC20(syntheticAsset).safeTransfer(user, excessSynthetic);
            }
        }

        // STEP 8: If debt is fully repaid, withdraw ALL remaining collateral
        uint256 finalDebt = YOLO_HOOK.getPositionDebt(user, collateral, syntheticAsset);
        if (finalDebt == 0) {
            // Get final position to check remaining collateral
            DataTypes.UserPosition memory finalPosition = YOLO_HOOK.getUserPosition(user, collateral, syntheticAsset);
            if (finalPosition.collateralSuppliedAmount > 0) {
                // Withdraw all remaining collateral and send to user
                YOLO_HOOK.withdrawCollateral(
                    collateral, syntheticAsset, finalPosition.collateralSuppliedAmount, user, user
                );
            }
        }
        // Otherwise, excess collateral stays in position (already optimal for partial deleverage)
    }

    // ============================================================
    // VIEW FUNCTIONS
    // ============================================================

    /**
     * @notice Calculate flash loan amount for leverage operation
     * @param collateral Collateral asset
     * @param syntheticAsset Synthetic asset to borrow
     * @param collateralAmount Initial collateral amount
     * @param targetLeverage Target leverage (18 decimals, e.g., 9832e15 = 9.832x)
     * @return Flash loan amount in synthetic asset decimals
     */
    function _calculateLeverageFlashLoan(
        address collateral,
        address syntheticAsset,
        uint256 collateralAmount,
        uint256 targetLeverage
    ) internal view returns (uint256) {
        // Get oracle prices (8 decimals)
        uint256 collateralPriceX8 = YOLO_ORACLE.getAssetPrice(collateral);
        uint256 syntheticPriceX8 = YOLO_ORACLE.getAssetPrice(syntheticAsset);

        // Calculate collateral USD value
        uint256 collateralValueUSD = (collateralAmount * collateralPriceX8) / (10 ** _getDecimals(collateral));

        // Calculate target USD value
        uint256 targetValueUSD = (collateralValueUSD * targetLeverage) / 1e18;

        // Calculate additional USD needed
        uint256 additionalUSD = targetValueUSD - collateralValueUSD;

        // Convert to synthetic asset amount
        return (additionalUSD * (10 ** _getDecimals(syntheticAsset))) / syntheticPriceX8;
    }

    /**
     * @notice Get decimals for a token
     * @param token Token address
     * @return Number of decimals
     */
    function _getDecimals(address token) internal view returns (uint8) {
        (bool success, bytes memory data) = token.staticcall(abi.encodeWithSignature("decimals()"));
        if (!success) return 18;
        return abi.decode(data, (uint8));
    }
}
