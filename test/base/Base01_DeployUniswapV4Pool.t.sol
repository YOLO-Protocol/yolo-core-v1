// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/**
 * @title Base01_DeployUniswapV4Pool
 * @author alvin@yolo.wtf
 * @notice Base test contract for deploying Uniswap V4 PoolManager
 * @dev Provides real PoolManager deployment using Uniswap's Deployers utility
 *      This ensures proper pool initialization and hook integration
 */
contract Base01_DeployUniswapV4Pool is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Pool manager is inherited from Deployers
    // IPoolManager public manager; // Already defined in Deployers

    // Test currencies
    Currency internal testCurrency0;
    Currency internal testCurrency1;

    // Test pool for validation
    PoolKey internal testPoolKey;
    PoolId internal testPoolId;

    function setUp() public virtual {
        // Deploy fresh PoolManager and routers using Uniswap's Deployers
        // NOTE: We do NOT create test pool here to save gas for child contracts
        // Child contracts (like YoloHook tests) create their own pools during initialization
        deployFreshManagerAndRouters();

        // Log deployment info
        emit log_named_address("PoolManager deployed at", address(manager));
    }

    /**
     * @notice Verify PoolManager is properly deployed and can execute swaps
     * @dev Creates a test pool specifically for this validation test
     *      Made internal to avoid running in child test contracts
     */
    function _validatePoolManager() internal {
        // Deploy test currencies for basic pool testing
        (testCurrency0, testCurrency1) = deployMintAndApprove2Currencies();

        // Create a test pool without hooks to verify PoolManager works
        (testPoolKey, testPoolId) = initPoolAndAddLiquidity(
            testCurrency0,
            testCurrency1,
            IHooks(address(0)), // No hooks for test pool
            3000, // 0.3% fee
            SQRT_PRICE_1_1 // 1:1 initial price
        );

        // Log test pool info
        emit log_named_address("Test Currency0", Currency.unwrap(testCurrency0));
        emit log_named_address("Test Currency1", Currency.unwrap(testCurrency1));

        // Perform a test swap to ensure PoolManager functions correctly
        int256 amountIn = 100e18;
        bytes memory hookData = "";

        BalanceDelta delta = swap(testPoolKey, true, amountIn, hookData);

        // Verify swap executed (currency0 decreases, currency1 increases)
        assertLt(delta.amount0(), 0, "Currency0 should decrease");
        assertGt(delta.amount1(), 0, "Currency1 should increase");
    }

    /**
     * @notice Helper to get the deployed PoolManager for child contracts
     */
    function getPoolManager() public view returns (IPoolManager) {
        return manager;
    }
}
