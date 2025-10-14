// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AppStorage} from "../core/YoloHookStorage.sol";
import {DataTypes} from "./DataTypes.sol";
import {DecimalNormalization} from "./DecimalNormalization.sol";
import {StakedYoloUSD} from "../tokenization/StakedYoloUSD.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title StablecoinModule
 * @author alvin@yolo.wtf
 * @notice Externally linked library for USY stablecoin and anchor pool LP operations
 * @dev Handles add/remove liquidity via PoolManager unlock callbacks
 *      Uses PoolManager's settle/take pattern for Uniswap V4 router compatibility
 */
library StablecoinModule {
    using DecimalNormalization for uint256;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    // ============================================================
    // CONSTANTS
    // ============================================================

    /**
     * @dev MINIMUM_LIQUIDITY mirrors YoloHookStorage.MINIMUM_LIQUIDITY
     *      Libraries cannot access contract constants, so we maintain this copy.
     *      CRITICAL: Must match YoloHookStorage.MINIMUM_LIQUIDITY = 1000
     */
    uint256 private constant MINIMUM_LIQUIDITY = 1000;

    // ============================================================
    // ERRORS
    // ============================================================

    error UnknownAction();
    error InsufficientBootstrapLiquidity();
    error InsufficientLiquidityMinted();
    error ImbalancedDeposit();
    error InsufficientLiquidity();
    error InsufficientOutput();

    // ============================================================
    // UNLOCK CALLBACK ROUTING
    // ============================================================

    /**
     * @notice Handle unlock callback routing for liquidity operations
     * @param s AppStorage reference
     * @param poolManager PoolManager instance
     * @param data Encoded CallbackData
     * @return Encoded result
     */
    function handleUnlockCallback(AppStorage storage s, IPoolManager poolManager, bytes calldata data)
        external
        returns (bytes memory)
    {
        DataTypes.CallbackData memory cbd = abi.decode(data, (DataTypes.CallbackData));

        if (cbd.action == DataTypes.UnlockAction.ADD_LIQUIDITY) {
            return _handleAddLiquidity(s, poolManager, cbd.data);
        } else if (cbd.action == DataTypes.UnlockAction.REMOVE_LIQUIDITY) {
            return _handleRemoveLiquidity(s, poolManager, cbd.data);
        } else {
            revert UnknownAction();
        }
    }

    // ============================================================
    // ADD LIQUIDITY CALLBACK
    // ============================================================

    /**
     * @notice Handle add liquidity unlock callback
     * @param s AppStorage reference
     * @param poolManager PoolManager instance
     * @param data Encoded AddLiquidityData
     * @return Encoded (usyUsed, usdcUsed, sUSYMinted)
     */
    function _handleAddLiquidity(AppStorage storage s, IPoolManager poolManager, bytes memory data)
        internal
        returns (bytes memory)
    {
        DataTypes.AddLiquidityData memory params = abi.decode(data, (DataTypes.AddLiquidityData));

        // Get current state
        StakedYoloUSD sUSYContract = StakedYoloUSD(s.sUSY);
        uint256 totalSupply = sUSYContract.totalSupply();

        uint256 usyUsed;
        uint256 usdcUsed;
        uint256 sUSYMinted;

        if (totalSupply == 0) {
            // BOOTSTRAP CASE
            (usyUsed, usdcUsed, sUSYMinted) = _handleBootstrapLiquidity(s, params, sUSYContract);
        } else {
            // SUBSEQUENT LIQUIDITY
            (usyUsed, usdcUsed, sUSYMinted) = _handleSubsequentLiquidity(s, params, sUSYContract, totalSupply);
        }

        // ===== POOLMANAGER SETTLEMENT PATTERN =====

        Currency usyCurrency = Currency.wrap(s.usy);
        Currency usdcCurrency = Currency.wrap(s.usdc);

        // Step 1: Pull tokens from sender to PoolManager (settle from sender)
        usyCurrency.settle(poolManager, params.sender, usyUsed, false);
        usdcCurrency.settle(poolManager, params.sender, usdcUsed, false);

        // Step 2: Hook takes claim tokens from PoolManager
        usyCurrency.take(poolManager, address(this), usyUsed, true); // true = as claims
        usdcCurrency.take(poolManager, address(this), usdcUsed, true);

        // ===== UPDATE RESERVES (ATOMIC, BEFORE MINT) =====
        s.totalAnchorReserveUSY += usyUsed;
        s.totalAnchorReserveUSDC += usdcUsed;

        // ===== MINT sUSY TO RECEIVER =====
        sUSYContract.mint(params.receiver, sUSYMinted);

        // Emit event (must be done in YoloHook context, not library)
        // Event will be emitted by YoloHook after unlockCallback returns

        return abi.encode(usyUsed, usdcUsed, sUSYMinted);
    }

    /**
     * @notice Handle bootstrap liquidity (first LP)
     * @dev Enforces 1:1 ratio, locks MINIMUM_LIQUIDITY
     */
    function _handleBootstrapLiquidity(
        AppStorage storage s,
        DataTypes.AddLiquidityData memory params,
        StakedYoloUSD sUSYContract
    ) internal returns (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) {
        // 1. Normalize to 18 decimals
        uint256 maxUsyIn18 = params.maxUsyIn; // Already 18 decimals
        uint256 maxUsdcIn18 = params.maxUsdcIn.to18(s.usdcDecimals);

        // 2. Enforce 1:1 ratio (take minimum)
        uint256 minAmount18 = maxUsyIn18 < maxUsdcIn18 ? maxUsyIn18 : maxUsdcIn18;

        // 3. Calculate actual amounts
        usyUsed = minAmount18;
        usdcUsed = minAmount18.from18(s.usdcDecimals);

        // 4. Calculate total value and sUSY to mint
        uint256 totalValue18 = minAmount18 + minAmount18; // Both equal
        if (totalValue18 <= MINIMUM_LIQUIDITY) revert InsufficientBootstrapLiquidity();

        sUSYMinted = totalValue18 - MINIMUM_LIQUIDITY;
        if (sUSYMinted < params.minSUSY) revert InsufficientLiquidityMinted();

        // 5. Lock MINIMUM_LIQUIDITY permanently to address(1)
        sUSYContract.mint(address(1), MINIMUM_LIQUIDITY);
    }

    /**
     * @notice Handle subsequent liquidity (after bootstrap)
     * @dev Uses min-share formula with 1% imbalance tolerance
     */
    function _handleSubsequentLiquidity(
        AppStorage storage s,
        DataTypes.AddLiquidityData memory params,
        StakedYoloUSD, /* sUSYContract */
        uint256 totalSupply
    ) internal view returns (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) {
        // 1. Normalize reserves and inputs to 18 decimals
        uint256 reserveUSY18 = s.totalAnchorReserveUSY;
        uint256 reserveUSDC18 = s.totalAnchorReserveUSDC.to18(s.usdcDecimals);
        uint256 maxUsyIn18 = params.maxUsyIn;
        uint256 maxUsdcIn18 = params.maxUsdcIn.to18(s.usdcDecimals);

        // 2. Calculate optimal amounts maintaining pool ratio
        uint256 optimalUsyIn18 = (maxUsdcIn18 * reserveUSY18) / reserveUSDC18;
        uint256 usyIn18;
        uint256 usdcIn18;

        if (optimalUsyIn18 <= maxUsyIn18) {
            // USDC is limiting factor
            usdcIn18 = maxUsdcIn18;
            usyIn18 = optimalUsyIn18;
        } else {
            // USY is limiting factor
            uint256 optimalUsdcIn18 = (maxUsyIn18 * reserveUSDC18) / reserveUSY18;
            usyIn18 = maxUsyIn18;
            usdcIn18 = optimalUsdcIn18;
        }

        // 3. Min-share formula (prevents dilution)
        uint256 shareUSY = (usyIn18 * totalSupply) / reserveUSY18;
        uint256 shareUSDC = (usdcIn18 * totalSupply) / reserveUSDC18;

        // 4. Check 1% imbalance tolerance
        uint256 diff = shareUSY > shareUSDC ? shareUSY - shareUSDC : shareUSDC - shareUSY;
        uint256 maxShare = shareUSY > shareUSDC ? shareUSY : shareUSDC;
        if ((diff * 10000) / maxShare > 100) revert ImbalancedDeposit(); // 1% = 100 bps

        // 5. Take minimum share (conservative, favors pool)
        sUSYMinted = shareUSY < shareUSDC ? shareUSY : shareUSDC;
        if (sUSYMinted < params.minSUSY) revert InsufficientLiquidityMinted();

        // 6. Convert back to native decimals
        usyUsed = usyIn18;
        usdcUsed = usdcIn18.from18(s.usdcDecimals);
    }

    // ============================================================
    // REMOVE LIQUIDITY CALLBACK
    // ============================================================

    /**
     * @notice Handle remove liquidity unlock callback
     * @param s AppStorage reference
     * @param poolManager PoolManager instance
     * @param data Encoded RemoveLiquidityData
     * @return Encoded (usyOut, usdcOut)
     */
    function _handleRemoveLiquidity(AppStorage storage s, IPoolManager poolManager, bytes memory data)
        internal
        returns (bytes memory)
    {
        DataTypes.RemoveLiquidityData memory params = abi.decode(data, (DataTypes.RemoveLiquidityData));

        // Get current state
        StakedYoloUSD sUSYContract = StakedYoloUSD(s.sUSY);
        uint256 totalSupply = sUSYContract.totalSupply();
        if (totalSupply == 0) revert InsufficientLiquidity();

        // 1. Normalize reserves to 18 decimals
        uint256 reserveUSY18 = s.totalAnchorReserveUSY;
        uint256 reserveUSDC18 = s.totalAnchorReserveUSDC.to18(s.usdcDecimals);

        // 2. Calculate proportional amounts (round down to favor pool)
        uint256 usyOut18 = (params.sUSYAmount * reserveUSY18) / totalSupply;
        uint256 usdcOut18 = (params.sUSYAmount * reserveUSDC18) / totalSupply;

        // 3. Convert USDC back to native decimals
        uint256 usyOut = usyOut18;
        uint256 usdcOut = usdcOut18.from18(s.usdcDecimals);

        // 4. Check slippage protection
        if (usyOut < params.minUsyOut) revert InsufficientOutput();
        if (usdcOut < params.minUsdcOut) revert InsufficientOutput();

        // 5. Handle dehypothecation if needed (TODO: implement when RehypothecationModule ready)
        // if (s.rehypothecationEnabled) {
        //     _handleDehypothecation(s, usdcOut);
        // }

        // ===== CEI: BURN FIRST =====
        sUSYContract.burn(params.sender, params.sUSYAmount);

        // ===== UPDATE RESERVES (ATOMIC, BEFORE TRANSFERS) =====
        s.totalAnchorReserveUSY -= usyOut;
        s.totalAnchorReserveUSDC -= usdcOut;

        // ===== POOLMANAGER SETTLEMENT PATTERN =====

        Currency usyCurrency = Currency.wrap(s.usy);
        Currency usdcCurrency = Currency.wrap(s.usdc);

        // Hook settles claim tokens back to PoolManager
        usyCurrency.settle(poolManager, address(this), usyOut, true); // true = using claims
        usdcCurrency.settle(poolManager, address(this), usdcOut, true);

        // PoolManager converts claims to real tokens and sends to receiver
        usyCurrency.take(poolManager, params.receiver, usyOut, false); // false = real tokens
        usdcCurrency.take(poolManager, params.receiver, usdcOut, false);

        // Emit event (must be done in YoloHook context, not library)
        // Event will be emitted by YoloHook after unlockCallback returns

        return abi.encode(usyOut, usdcOut);
    }
}
