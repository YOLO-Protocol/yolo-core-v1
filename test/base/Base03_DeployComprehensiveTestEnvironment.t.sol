// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base02_DeployYoloHook} from "./Base02_DeployYoloHook.t.sol";
import {YoloOracle} from "../../src/core/YoloOracle.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {YoloSyntheticAsset} from "../../src/tokenization/YoloSyntheticAsset.sol";
import {IACLManager} from "../../src/interfaces/IACLManager.sol";
import {IYoloOracle} from "../../src/interfaces/IYoloOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title Base03_DeployComprehensiveTestEnvironment
 * @notice Comprehensive test environment with multiple assets, real oracle, and funding
 * @dev Inherits Base02 and adds:
 *      - Multiple collateral assets (USDC, USDT, DAI, WETH, WBTC)
 *      - Real YoloOracle with MockPriceOracle feeds
 *      - Multiple synthetic assets (commodities, currencies, stocks)
 *      - Properly funded sUSY and YLP vaults
 *      - Pre-configured lending pairs
 */
contract Base03_DeployComprehensiveTestEnvironment is Base02_DeployYoloHook {
    // ============================================================
    // COLLATERAL ASSETS
    // ============================================================

    MockERC20 public usdt;
    MockERC20 public dai;
    MockERC20 public weth;
    MockERC20 public wbtc;

    // ============================================================
    // ORACLES
    // ============================================================

    YoloOracle public yoloOracleReal;

    // Price oracles for collaterals
    MockPriceOracle public usdcOracle;
    MockPriceOracle public usdtOracle;
    MockPriceOracle public daiOracle;
    MockPriceOracle public wethOracle;
    MockPriceOracle public wbtcOracle;

    // Price oracles for synthetics
    MockPriceOracle public yXAUOracle; // Gold
    MockPriceOracle public yEUROracle; // Euro
    MockPriceOracle public yJPYOracle; // Japanese Yen
    MockPriceOracle public yTSLAOracle; // Tesla stock
    MockPriceOracle public yAAPLOracle; // Apple stock
    MockPriceOracle public usyOracle; // USY stablecoin

    // ============================================================
    // SYNTHETIC ASSETS
    // ============================================================

    address public yXAU; // Synthetic Gold
    address public yEUR; // Synthetic Euro
    address public yJPY; // Synthetic Japanese Yen
    address public yTSLA; // Synthetic Tesla
    address public yAAPL; // Synthetic Apple

    // ============================================================
    // CONFIGURATION
    // ============================================================

    YoloSyntheticAsset public syntheticAssetImpl;

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public virtual override {
        super.setUp(); // Deploy YoloHook with basic infrastructure from Base02

        // ========================================
        // STEP 1: Deploy Collateral Assets
        // ========================================

        usdt = new MockERC20("Tether USD", "USDT", 6);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        // ========================================
        // STEP 2: Deploy MockPriceOracle Feeds (BEFORE YoloOracle)
        // ========================================

        // Collateral oracles (8 decimals for prices)
        usdcOracle = new MockPriceOracle(1e8, "USDC / USD"); // $1.00
        usdtOracle = new MockPriceOracle(1e8, "USDT / USD"); // $1.00
        daiOracle = new MockPriceOracle(1e8, "DAI / USD"); // $1.00
        wethOracle = new MockPriceOracle(3200e8, "WETH / USD"); // $3,200
        wbtcOracle = new MockPriceOracle(68000e8, "WBTC / USD"); // $68,000

        // Synthetic asset oracles (realistic current prices)
        yXAUOracle = new MockPriceOracle(2650e8, "yXAU / USD"); // Gold: $2,650/oz
        yEUROracle = new MockPriceOracle(108e6, "yEUR / USD"); // EUR: $1.08 (6 decimals for precision)
        yJPYOracle = new MockPriceOracle(0.0067e8, "yJPY / USD"); // JPY: $0.0067 (¥150 = $1)
        yTSLAOracle = new MockPriceOracle(340e8, "yTSLA / USD"); // Tesla: $340/share
        yAAPLOracle = new MockPriceOracle(230e8, "yAAPL / USD"); // Apple: $230/share
        usyOracle = new MockPriceOracle(1e8, "USY / USD"); // $1.00

        // ========================================
        // STEP 3: Deploy YoloOracle with Initial Price Sources
        // ========================================

        // Prepare collateral assets and sources for constructor
        address[] memory initialAssets = new address[](6);
        address[] memory initialSources = new address[](6);

        initialAssets[0] = address(usdc);
        initialSources[0] = address(usdcOracle);
        initialAssets[1] = address(usdt);
        initialSources[1] = address(usdtOracle);
        initialAssets[2] = address(dai);
        initialSources[2] = address(daiOracle);
        initialAssets[3] = address(weth);
        initialSources[3] = address(wethOracle);
        initialAssets[4] = address(wbtc);
        initialSources[4] = address(wbtcOracle);
        initialAssets[5] = usy;
        initialSources[5] = address(usyOracle);

        // Deploy YoloOracle with all price sources registered in constructor
        yoloOracleReal = new YoloOracle(
            IACLManager(address(aclManager)),
            address(yoloHook),
            usy, // anchor asset (USY)
            initialAssets,
            initialSources
        );

        // ========================================
        // STEP 4: Set Up ACL Roles
        // ========================================

        // Create all required roles
        aclManager.createRole("ORACLE_ADMIN", bytes32(0));
        aclManager.createRole("ASSETS_ADMIN", bytes32(0));
        aclManager.createRole("RISK_ADMIN", bytes32(0));

        // Grant roles to test contract for direct operations
        aclManager.grantRole(keccak256("ORACLE_ADMIN"), address(this));
        aclManager.grantRole(keccak256("ASSETS_ADMIN"), address(this));
        aclManager.grantRole(keccak256("RISK_ADMIN"), address(this));

        // CRITICAL: Grant ORACLE_ADMIN to YoloHook so it can register synthetic asset oracles
        // When createSyntheticAsset() is called, YoloHook calls YoloOracle.setAssetSources()
        aclManager.grantRole(keccak256("ORACLE_ADMIN"), address(yoloHook));

        // ========================================
        // STEP 5: Update YoloHook to use Real Oracle
        // ========================================

        // CRITICAL: YoloHook from Base02 has MockYoloOracle
        // We need to swap it with our new real oracle BEFORE creating synthetic assets
        yoloHook.updateOracle(IYoloOracle(address(yoloOracleReal)));

        // ========================================
        // STEP 6: Deploy Synthetic Asset Implementation
        // ========================================

        syntheticAssetImpl = new YoloSyntheticAsset();

        // ========================================
        // STEP 7: Create Synthetic Assets (with oracle sources)
        // ========================================

        // yXAU - Synthetic Gold (18 decimals)
        yXAU = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Gold",
            "yXAU",
            18,
            address(yXAUOracle), // Pass oracle source directly
            address(syntheticAssetImpl),
            0, // unlimited supply
            type(uint256).max // unlimited flash loans
        );

        // yEUR - Synthetic Euro (18 decimals)
        yEUR = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Euro",
            "yEUR",
            18,
            address(yEUROracle), // Pass oracle source directly
            address(syntheticAssetImpl),
            0,
            type(uint256).max
        );

        // yJPY - Synthetic Japanese Yen (18 decimals)
        yJPY = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Japanese Yen",
            "yJPY",
            18,
            address(yJPYOracle), // Pass oracle source directly
            address(syntheticAssetImpl),
            0,
            type(uint256).max
        );

        // yTSLA - Synthetic Tesla Stock (18 decimals)
        yTSLA = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Tesla",
            "yTSLA",
            18,
            address(yTSLAOracle), // Pass oracle source directly
            address(syntheticAssetImpl),
            0,
            type(uint256).max
        );

        // yAAPL - Synthetic Apple Stock (18 decimals)
        yAAPL = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Apple",
            "yAAPL",
            18,
            address(yAAPLOracle), // Pass oracle source directly
            address(syntheticAssetImpl),
            0,
            type(uint256).max
        );

        // ========================================
        // STEP 8: Whitelist Collaterals
        // ========================================

        yoloHook.whitelistCollateral(address(usdc));
        yoloHook.whitelistCollateral(address(usdt));
        yoloHook.whitelistCollateral(address(dai));
        yoloHook.whitelistCollateral(address(weth));
        yoloHook.whitelistCollateral(address(wbtc));

        // ========================================
        // STEP 9: Configure Lending Pairs
        // ========================================

        _configureLendingPair(yXAU, address(usdc), 7500, 8000); // Gold: 75% LTV
        _configureLendingPair(yXAU, address(weth), 7000, 7500); // Gold-WETH: 70% LTV

        _configureLendingPair(yEUR, address(usdc), 8000, 8500); // EUR: 80% LTV
        _configureLendingPair(yEUR, address(dai), 8000, 8500); // EUR-DAI: 80% LTV

        _configureLendingPair(yJPY, address(usdc), 8000, 8500); // JPY: 80% LTV

        _configureLendingPair(yTSLA, address(usdc), 6000, 6500); // Tesla: 60% LTV (volatile)
        _configureLendingPair(yTSLA, address(weth), 5500, 6000); // Tesla-WETH: 55% LTV

        _configureLendingPair(yAAPL, address(usdc), 6500, 7000); // Apple: 65% LTV (less volatile)
        _configureLendingPair(yAAPL, address(wbtc), 6000, 6500); // Apple-WBTC: 60% LTV

        // ========================================
        // STEP 10: Fund YLP Vault with USY
        // ========================================

        // Mint 1 million USY to YLP vault for trader PnL settlements
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(usy).mint(ylpVault, 1_000_000e18);

        // ========================================
        // STEP 11: Add Initial sUSY Liquidity
        // ========================================

        // Mint initial liquidity to test contract
        usdc.mint(address(this), 100_000e6); // 100k USDC
        vm.prank(address(yoloHook));
        YoloSyntheticAsset(usy).mint(address(this), 100_000e18); // 100k USY

        // Approve and add liquidity
        usdc.approve(address(yoloHook), type(uint256).max);
        IERC20(usy).approve(address(yoloHook), type(uint256).max);

        yoloHook.addLiquidity(
            100_000e18, // 100k USY
            100_000e6, // 100k USDC
            0, // min sUSY
            address(this) // receiver
        );
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    /**
     * @notice Configure a lending pair with standard parameters
     * @param synthetic Synthetic asset address
     * @param collateral Collateral asset address
     * @param ltv Loan-to-value ratio in bps
     * @param liquidationThreshold Liquidation threshold in bps
     */
    function _configureLendingPair(address synthetic, address collateral, uint256 ltv, uint256 liquidationThreshold)
        internal
    {
        yoloHook.configureLendingPair(
            synthetic,
            collateral,
            address(0), // no deposit token
            address(0), // no debt token
            ltv,
            liquidationThreshold,
            500, // 5% liquidation bonus
            500, // 5% liquidation penalty
            300, // 3% borrow rate
            type(uint256).max, // unlimited mint cap
            type(uint256).max, // unlimited supply cap
            1e18, // minimum borrow 1 unit
            false, // not expirable
            0 // no expiry
        );
    }

    // ============================================================
    // PUBLIC GETTERS FOR TEST ACCESS
    // ============================================================

    /**
     * @notice Get all collateral assets
     * @return Array of collateral addresses [USDC, USDT, DAI, WETH, WBTC]
     */
    function getCollateralAssets() public view returns (address[] memory) {
        address[] memory collaterals = new address[](5);
        collaterals[0] = address(usdc);
        collaterals[1] = address(usdt);
        collaterals[2] = address(dai);
        collaterals[3] = address(weth);
        collaterals[4] = address(wbtc);
        return collaterals;
    }

    /**
     * @notice Get all synthetic assets
     * @return Array of synthetic addresses [yXAU, yEUR, yJPY, yTSLA, yAAPL]
     */
    function getSyntheticAssets() public view returns (address[] memory) {
        address[] memory synthetics = new address[](5);
        synthetics[0] = yXAU;
        synthetics[1] = yEUR;
        synthetics[2] = yJPY;
        synthetics[3] = yTSLA;
        synthetics[4] = yAAPL;
        return synthetics;
    }

    /**
     * @notice Get price oracle for an asset
     * @param asset Asset address
     * @return Oracle address
     */
    function getAssetOracle(address asset) public view returns (address) {
        return yoloOracleReal.getSourceOfAsset(asset);
    }

    // ============================================================
    // BASE03 VERIFICATION TESTS
    // ============================================================

    function test_Base03_Case01_CollateralAssetsDeployed() public {
        address[] memory collaterals = getCollateralAssets();
        assertEq(collaterals.length, 5, "Should have 5 collateral assets");
        assertEq(collaterals[0], address(usdc), "USDC address mismatch");
        assertEq(collaterals[1], address(usdt), "USDT address mismatch");
        assertEq(collaterals[2], address(dai), "DAI address mismatch");
        assertEq(collaterals[3], address(weth), "WETH address mismatch");
        assertEq(collaterals[4], address(wbtc), "WBTC address mismatch");
    }

    function test_Base03_Case02_SyntheticAssetsDeployed() public {
        address[] memory synthetics = getSyntheticAssets();
        assertEq(synthetics.length, 5, "Should have 5 synthetic assets");
        assertTrue(synthetics[0] != address(0), "yXAU not deployed");
        assertTrue(synthetics[1] != address(0), "yEUR not deployed");
        assertTrue(synthetics[2] != address(0), "yJPY not deployed");
        assertTrue(synthetics[3] != address(0), "yTSLA not deployed");
        assertTrue(synthetics[4] != address(0), "yAAPL not deployed");
    }

    function test_Base03_Case03_CollateralOraclesConfigured() public {
        assertTrue(getAssetOracle(address(usdc)) != address(0), "USDC oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(usdc)), 1e8, "USDC price should be $1");
        assertTrue(getAssetOracle(address(weth)) != address(0), "WETH oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(weth)), 3200e8, "WETH price should be $3200");
        assertTrue(getAssetOracle(address(wbtc)) != address(0), "WBTC oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(address(wbtc)), 68000e8, "WBTC price should be $68000");
    }

    function test_Base03_Case04_SyntheticOraclesConfigured() public {
        assertTrue(getAssetOracle(yXAU) != address(0), "yXAU oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yXAU), 2650e8, "yXAU price should be $2650");
        assertTrue(getAssetOracle(yTSLA) != address(0), "yTSLA oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yTSLA), 340e8, "yTSLA price should be $340");
        assertTrue(getAssetOracle(yAAPL) != address(0), "yAAPL oracle not configured");
        assertEq(yoloOracleReal.getAssetPrice(yAAPL), 230e8, "yAAPL price should be $230");
    }

    function test_Base03_Case05_CollateralsWhitelisted() public {
        assertTrue(yoloHook.isWhitelistedCollateral(address(usdc)), "USDC not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(usdt)), "USDT not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(dai)), "DAI not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(weth)), "WETH not whitelisted");
        assertTrue(yoloHook.isWhitelistedCollateral(address(wbtc)), "WBTC not whitelisted");
    }

    function test_Base03_Case06_YLPVaultFunded() public {
        uint256 ylpBalance = IERC20(usy).balanceOf(ylpVault);
        assertEq(ylpBalance, 1_000_000e18, "YLP vault should have 1M USY");
    }

    function test_Base03_Case07_sUSYInitialLiquidity() public {
        uint256 sUSYBalance = IERC20(sUSY).balanceOf(address(this));
        assertTrue(sUSYBalance > 0, "Should have sUSY balance");

        // In Uniswap V4, liquidity tokens are held by PoolManager, not the hook
        // The hook tracks reserves in storage
        (uint256 reserveUSY, uint256 reserveUSDC) = yoloHook.getAnchorReserves();
        assertTrue(reserveUSY > 0, "Should have USY reserves");
        assertTrue(reserveUSDC > 0, "Should have USDC reserves");
    }

    function test_Base03_Case08_CanBorrowSyntheticAssets() public {
        usdc.mint(address(this), 10000e6);
        usdc.approve(address(yoloHook), type(uint256).max);
        yoloHook.borrow(yXAU, 1e18, address(usdc), 3600e6); // Borrow 1 yXAU (Gold)
        assertEq(IERC20(yXAU).balanceOf(address(this)), 1e18, "Should receive 1 yXAU");
    }

    function test_Base03_Case09_OraclePricesCanBeUpdated() public {
        assertEq(yoloOracleReal.getAssetPrice(yXAU), 2650e8, "Initial yXAU price");
        yXAUOracle.updateAnswer(2700e8);
        assertEq(yoloOracleReal.getAssetPrice(yXAU), 2700e8, "Updated yXAU price");
    }

    function test_Base03_Case10_SyntheticAssetsAreYoloAssets() public {
        assertTrue(yoloHook.isYoloAsset(yXAU), "yXAU should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(yEUR), "yEUR should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(yTSLA), "yTSLA should be a YOLO asset");
        assertTrue(yoloHook.isYoloAsset(usy), "USY should be a YOLO asset");
    }
}
