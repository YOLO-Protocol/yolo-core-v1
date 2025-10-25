// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base02_DeployYoloHook} from "./base/Base02_DeployYoloHook.t.sol";

/**
 * @title TestBase02_TestDeployYoloHook
 * @notice Test suite for Base02 YoloHook deployment
 * @dev Verifies that YoloHook and all infrastructure contracts deploy correctly
 */
contract TestBase02_TestDeployYoloHook is Base02_DeployYoloHook {
    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice Verify YoloHook proxy is deployed at non-zero address
     */
    function test_Base02_Case01_YoloHookDeployed() public {
        assertTrue(address(yoloHook) != address(0), "YoloHook should be deployed");
    }

    /**
     * @notice Verify YoloHook implementation is deployed
     */
    function test_Base02_Case02_YoloHookImplementationDeployed() public {
        assertTrue(address(yoloHookImpl) != address(0), "YoloHook implementation should be deployed");
    }

    /**
     * @notice Verify ACL Manager is deployed and configured
     */
    function test_Base02_Case03_ACLManagerDeployed() public {
        assertTrue(address(aclManager) != address(0), "ACL Manager should be deployed");
    }

    /**
     * @notice Verify YoloOracle is deployed
     */
    function test_Base02_Case04_OracleDeployed() public {
        assertTrue(address(oracle) != address(0), "Oracle should be deployed");
        assertEq(address(yoloHook.yoloOracle()), address(oracle), "YoloHook should reference oracle");
    }

    /**
     * @notice Verify USY stablecoin is initialized
     */
    function test_Base02_Case05_USYInitialized() public {
        assertTrue(usy != address(0), "USY should be deployed");
        assertEq(yoloHook.usy(), usy, "YoloHook should track USY address");
    }

    /**
     * @notice Verify sUSY (staked USY) is initialized
     */
    function test_Base02_Case06_sUSYInitialized() public {
        assertTrue(sUSY != address(0), "sUSY should be deployed");
        assertEq(yoloHook.sUSY(), sUSY, "YoloHook should track sUSY address");
    }

    /**
     * @notice Verify YLP vault is initialized
     */
    function test_Base02_Case07_YLPVaultInitialized() public {
        assertTrue(ylpVault != address(0), "YLP vault should be deployed");
        assertEq(yoloHook.ylpVault(), ylpVault, "YoloHook should track YLP vault address");
    }

    /**
     * @notice Verify treasury address is set
     */
    function test_Base02_Case08_TreasuryConfigured() public {
        assertTrue(treasury != address(0), "Treasury should be set");
    }

    /**
     * @notice Verify USDC collateral is configured
     */
    function test_Base02_Case09_USDCConfigured() public {
        assertTrue(address(usdc) != address(0), "USDC should be deployed");
    }

    /**
     * @notice Verify PoolManager is accessible from YoloHook
     */
    function test_Base02_Case10_PoolManagerAccessible() public {
        assertEq(yoloHook.poolManagerAddress(), address(manager), "YoloHook should reference PoolManager");
    }
}
