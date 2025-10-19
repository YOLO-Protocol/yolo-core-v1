// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AppStorage} from "../core/YoloHookStorage.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IYoloSyntheticAsset} from "../interfaces/IYoloSyntheticAsset.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title SyntheticSwapModule
 * @notice Externally linked library that mirrors the V0.5 synthetic swap mechanics
 */
library SyntheticSwapModule {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    uint256 internal constant FEE_PRECISION = 10_000; // basis points

    error SyntheticSwapModule__BadOracle();
    error SyntheticSwapModule__FeeOverflow();
    error SyntheticSwapModule__BurnUnavailable();

    struct SyntheticSwapResult {
        bytes4 selector;
        BeforeSwapDelta delta;
        uint24 lpFeeOverride;
        int128 delta0;
        int128 delta1;
        uint256 grossInput;
        uint256 netInput;
        uint256 amountOut;
        uint256 feeAmount;
        address tokenIn;
        address tokenOut;
        bool exactInput;
    }

    /**
     * @notice Finalize any pending synthetic burns from previous swaps
     * @dev Converts ERC-6909 claims into real tokens, then burns the synthetic asset
     */
    function settlePendingBurn(AppStorage storage s, IPoolManager poolManager) public {
        address token = s.pendingSyntheticToken;
        uint256 amount = s.pendingSyntheticAmount;
        if (token == address(0) || amount == 0) return;

        Currency currency = Currency.wrap(token);
        currency.settle(poolManager, address(this), amount, true);
        currency.take(poolManager, address(this), amount, false);
        IYoloSyntheticAsset(token).burn(address(this), amount);

        s.pendingSyntheticToken = address(0);
        s.pendingSyntheticAmount = 0;
    }

    /**
     * @notice Execute the synthetic swap path, mirroring the legacy behaviour
     */
    function executeSyntheticSwap(
        AppStorage storage s,
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata params
    ) external returns (SyntheticSwapResult memory result) {
        // Flush any leftover synthetic tokens from a previous swap
        if (s.pendingSyntheticToken != address(0)) {
            settlePendingBurn(s, poolManager);
        }

        Currency currencyIn = params.zeroForOne ? key.currency0 : key.currency1;
        Currency currencyOut = params.zeroForOne ? key.currency1 : key.currency0;
        address tokenIn = Currency.unwrap(currencyIn);
        address tokenOut = Currency.unwrap(currencyOut);

        uint256 priceIn = s.yoloOracle.getAssetPrice(tokenIn);
        uint256 priceOut = s.yoloOracle.getAssetPrice(tokenOut);
        if (priceIn == 0 || priceOut == 0) revert SyntheticSwapModule__BadOracle();

        bool exactIn = params.amountSpecified < 0;
        uint256 grossIn;
        uint256 netIn;
        uint256 feeAmount;
        uint256 amountOut;

        if (exactIn) {
            grossIn = uint256(-params.amountSpecified);
            feeAmount = (grossIn * s.syntheticSwapFeeBps) / FEE_PRECISION;
            netIn = grossIn - feeAmount;
            amountOut = (priceIn * netIn) / priceOut;
        } else {
            amountOut = uint256(params.amountSpecified);
            netIn = (priceOut * amountOut + priceIn - 1) / priceIn;
            uint256 denominator = FEE_PRECISION - s.syntheticSwapFeeBps;
            if (denominator == 0) revert SyntheticSwapModule__FeeOverflow();
            grossIn = (netIn * FEE_PRECISION + denominator - 1) / denominator;
            feeAmount = grossIn - netIn;
        }

        currencyIn.take(poolManager, address(this), netIn, true);
        if (feeAmount > 0) {
            currencyIn.take(poolManager, s.treasury, feeAmount, true);
        }

        IYoloSyntheticAsset(tokenOut).mint(address(this), amountOut);
        currencyOut.settle(poolManager, address(this), amountOut, false);

        s.pendingSyntheticToken = tokenIn;
        s.pendingSyntheticAmount = netIn;

        int128 delta0 =
            exactIn ? SafeCast.toInt128(SafeCast.toInt256(grossIn)) : -SafeCast.toInt128(SafeCast.toInt256(amountOut));
        int128 delta1 =
            exactIn ? -SafeCast.toInt128(SafeCast.toInt256(amountOut)) : SafeCast.toInt128(SafeCast.toInt256(grossIn));

        result.selector = IHooks.beforeSwap.selector;
        result.delta = toBeforeSwapDelta(delta0, delta1);
        result.lpFeeOverride = 0;
        result.delta0 = delta0;
        result.delta1 = delta1;
        result.grossInput = grossIn;
        result.netInput = netIn;
        result.amountOut = amountOut;
        result.feeAmount = feeAmount;
        result.tokenIn = tokenIn;
        result.tokenOut = tokenOut;
        result.exactInput = exactIn;
    }

    /**
     * @notice Handle PoolManager.unlock callbacks for synthetic burn actions
     */
    function handleUnlockCallback(AppStorage storage s, IPoolManager poolManager, bytes memory)
        external
        returns (bytes memory)
    {
        if (s.pendingSyntheticToken == address(0) || s.pendingSyntheticAmount == 0) {
            revert SyntheticSwapModule__BurnUnavailable();
        }

        settlePendingBurn(s, poolManager);
        return bytes("");
    }
}
