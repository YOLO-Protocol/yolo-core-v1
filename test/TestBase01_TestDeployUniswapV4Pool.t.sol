// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base01_DeployUniswapV4Pool} from "./base/Base01_DeployUniswapV4Pool.t.sol";

/**
 * @title TestBase01_TestDeployUniswapV4Pool
 * @notice Test suite for Base01 Uniswap V4 PoolManager deployment
 * @dev Verifies that PoolManager deploys correctly and can handle basic pool operations
 */
contract TestBase01_TestDeployUniswapV4Pool is Base01_DeployUniswapV4Pool {
    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice Verify PoolManager is deployed at non-zero address
     */
    function test_Base01_Case01_PoolManagerDeployed() public {
        assertTrue(address(manager) != address(0), "PoolManager should be deployed");
    }

    /**
     * @notice Verify PoolManager can create pools and execute swaps
     * @dev Uses the internal _validatePoolManager() helper
     */
    function test_Base01_Case02_PoolManagerFunctional() public {
        _validatePoolManager();
    }

    /**
     * @notice Verify getPoolManager() helper returns correct address
     */
    function test_Base01_Case03_PoolManagerAccessor() public {
        assertEq(address(getPoolManager()), address(manager), "getPoolManager should return manager");
    }
}
