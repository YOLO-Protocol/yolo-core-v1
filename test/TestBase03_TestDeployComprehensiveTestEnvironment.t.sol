// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base03_DeployComprehensiveTestEnvironment} from "./base/Base03_DeployComprehensiveTestEnvironment.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title TestBase03_TestDeployComprehensiveTestEnvironment
 * @notice Test suite for Base03 comprehensive deployment verification
 * @dev Verifies that all collaterals, synthetics, oracles, and whitelisting are configured correctly
 */
contract TestBase03_TestDeployComprehensiveTestEnvironment is Base03_DeployComprehensiveTestEnvironment {
    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice Verify all 7 collateral assets are deployed
     */
    function test_Base03_Case01_CollateralAssetsDeployed() public {
        address[] memory collaterals = getCollateralAssets();
        assertEq(collaterals.length, 7, "Should have 7 collateral assets");
        assertEq(collaterals[0], address(usdc), "USDC address mismatch");
        assertEq(collaterals[1], address(usdt), "USDT address mismatch");
        assertEq(collaterals[2], address(dai), "DAI address mismatch");
        assertEq(collaterals[3], address(weth), "WETH address mismatch");
        assertEq(collaterals[4], address(wbtc), "WBTC address mismatch");
        assertEq(collaterals[5], address(ptUsde), "PT-USDe address mismatch");
        assertEq(collaterals[6], address(sUsde), "sUSDe address mismatch");
    }

    /**
     * @notice Verify all 10 synthetic assets are deployed
     */
    function test_Base03_Case02_SyntheticAssetsDeployed() public {
        address[] memory synthetics = getSyntheticAssets();
        assertEq(synthetics.length, 10, "Should have 10 synthetic assets");
        // Commodities
        assertTrue(synthetics[0] != address(0), "yXAU not deployed");
        assertTrue(synthetics[1] != address(0), "ySILVER not deployed");
        assertTrue(synthetics[2] != address(0), "yCRUDE not deployed");
        // Currencies
        assertTrue(synthetics[3] != address(0), "yEUR not deployed");
        assertTrue(synthetics[4] != address(0), "yJPY not deployed");
        // Equities
        assertTrue(synthetics[5] != address(0), "yTSLA not deployed");
        assertTrue(synthetics[6] != address(0), "yAAPL not deployed");
        assertTrue(synthetics[7] != address(0), "yNVDA not deployed");
        // Crypto
        assertTrue(synthetics[8] != address(0), "yBTC not deployed");
        assertTrue(synthetics[9] != address(0), "yETH not deployed");
    }

    /**
     * @notice Verify collateral asset oracles are configured with correct prices
     */
    function test_Base03_Case03_CollateralOraclesConfigured() public {
        // Stablecoins
        assertTrue(getAssetOracle(address(usdc)) != address(0), "USDC oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(usdc)), 1e8, "USDC price should be $1");
        assertTrue(getAssetOracle(address(usdt)) != address(0), "USDT oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(usdt)), 1e8, "USDT price should be $1");
        assertTrue(getAssetOracle(address(dai)) != address(0), "DAI oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(dai)), 1e8, "DAI price should be $1");

        // Crypto
        assertTrue(getAssetOracle(address(weth)) != address(0), "WETH oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(weth)), 3200e8, "WETH price should be $3200");
        assertTrue(getAssetOracle(address(wbtc)) != address(0), "WBTC oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(wbtc)), 68000e8, "WBTC price should be $68000");

        // DeFi assets
        assertTrue(getAssetOracle(address(ptUsde)) != address(0), "PT-USDe oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(ptUsde)), 96e6, "PT-USDe price should be $0.96");
        assertTrue(getAssetOracle(address(sUsde)) != address(0), "sUSDe oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(sUsde)), 119e6, "sUSDe price should be $1.19");
    }

    /**
     * @notice Verify synthetic asset oracles are configured with correct prices
     */
    function test_Base03_Case04_SyntheticOraclesConfigured() public {
        // Commodities
        assertTrue(getAssetOracle(yXAU) != address(0), "yXAU oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yXAU), 2650e8, "yXAU price should be $2650");
        assertTrue(getAssetOracle(ySILVER) != address(0), "ySILVER oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(ySILVER), 3150e6, "ySILVER price should be $31.50");
        assertTrue(getAssetOracle(yCRUDE) != address(0), "yCRUDE oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yCRUDE), 7580e6, "yCRUDE price should be $75.80");

        // Currencies
        assertTrue(getAssetOracle(yEUR) != address(0), "yEUR oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yEUR), 108e6, "yEUR price should be $1.08");
        assertTrue(getAssetOracle(yJPY) != address(0), "yJPY oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yJPY), 67e4, "yJPY price should be $0.0067");

        // Equities
        assertTrue(getAssetOracle(yTSLA) != address(0), "yTSLA oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yTSLA), 340e8, "yTSLA price should be $340");
        assertTrue(getAssetOracle(yAAPL) != address(0), "yAAPL oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yAAPL), 230e8, "yAAPL price should be $230");
        assertTrue(getAssetOracle(yNVDA) != address(0), "yNVDA oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yNVDA), 13500e7, "yNVDA price should be $1350");

        // Crypto
        assertTrue(getAssetOracle(yBTC) != address(0), "yBTC oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yBTC), 68000e8, "yBTC price should be $68000");
        assertTrue(getAssetOracle(yETH) != address(0), "yETH oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yETH), 3200e8, "yETH price should be $3200");
    }

    /**
     * @notice Verify all collateral assets are whitelisted in YoloHook
     */
    function test_Base03_Case05_CollateralsWhitelisted() public {
        assertTrue(yoloHook.isWhitelistedCollateral(address(usdc)), "USDC not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(usdt)), "USDT not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(dai)), "DAI not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(weth)), "WETH not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(wbtc)), "WBTC not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(ptUsde)), "PT-USDe not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(sUsde)), "sUSDe not whitelisted");
    }

    /**
     * @notice Verify YLP vault has initial funding
     */
    function test_Base03_Case06_YLPVaultFunded() public {
        uint256 ylpBalance = IERC20(usy).balanceOf(ylpVault);
        assertEq(ylpBalance, 1_000_000e18, "YLP vault should have 1M USY");
    }

    /**
     * @notice Verify sUSY has initial liquidity in anchor pool
     */
    function test_Base03_Case07_sUSYInitialLiquidity() public {
        uint256 sUSYBalance = IERC20(sUSY).balanceOf(address(this));
        assertTrue(sUSYBalance > 0, "Should have sUSY balance");

        // In Uniswap V4, liquidity tokens are held by PoolManager, not the hook
        // The hook tracks reserves in storage
        (uint256 reserveUSY, uint256 reserveUSDC) = yoloHook.getAnchorReserves();
        assertTrue(reserveUSY > 0, "Should have USY reserves");
        assertTrue(reserveUSDC > 0, "Should have USDC reserves");
    }

    /**
     * @notice Verify users can borrow synthetic assets against collateral
     */
    function test_Base03_Case08_CanBorrowSyntheticAssets() public {
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yXAU, 1e18, address(usdc), 3600e6, address(this)); // Borrow 1 yXAU (Gold)
        assertEq(IERC20(yXAU).balanceOf(address(this)), 1e18, "Should receive 1 yXAU");
    }

    /**
     * @notice Verify oracle prices can be updated dynamically
     */
    function test_Base03_Case09_OraclePricesCanBeUpdated() public {
        assertEq(yoloOracleReal.getAssetPrice(yXAU), 2650e8, "Initial yXAU price");
        yXAUOracle.updateAnswer(2700e8);
        assertEq(yoloOracleReal.getAssetPrice(yXAU), 2700e8, "Updated yXAU price");
    }

    /**
     * @notice Verify all synthetic assets are registered as YOLO assets
     */
    function test_Base03_Case10_SyntheticAssetsAreYoloAssets() public {
        // Commodities
        assertTrue(yoloHook.isYoloAsset(yXAU), "yXAU should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(ySILVER), "ySILVER should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(yCRUDE), "yCRUDE should be a YOLO asset");
        // Currencies
        assertTrue(yoloHook.isYoloAsset(yEUR), "yEUR should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(yJPY), "yJPY should be a YOLO asset");
        // Equities
        assertTrue(yoloHook.isYoloAsset(yTSLA), "yTSLA should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(yAAPL), "yAAPL should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(yNVDA), "yNVDA should be a YOLO asset");
        // Crypto
        assertTrue(yoloHook.isYoloAsset(yBTC), "yBTC should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(yETH), "yETH should be a YOLO asset");
        // Anchor
        assertTrue(yoloHook.isYoloAsset(usy), "USY should be a YOLO asset");
    }
}
