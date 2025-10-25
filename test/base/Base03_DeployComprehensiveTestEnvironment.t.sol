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

/**
 * @title Base03_DeployComprehensiveTestEnvironment
 * @notice Comprehensive test environment with multiple assets, real oracle, and funding
 * @dev Inherits Base02 and adds:
 *      - Multiple collateral assets (USDC, USDT, DAI, WETH, WBTC, PT-USDe, sUSDe)
 *      - Real YoloOracle with MockPriceOracle feeds (6 decimals)
 *      - Multiple synthetic assets (commodities, currencies, stocks, crypto)
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
    MockERC20 public ptUsde; // Pendle PT-USDe-26DEC2025
    MockERC20 public sUsde; // Staked USDe (Ethena)

    // ============================================================
    // ORACLES (ALL 8 DECIMALS - CHAINLINK STANDARD)
    // ============================================================

    YoloOracle public yoloOracleReal;

    // Price oracles for collaterals
    MockPriceOracle public usdcOracle;
    MockPriceOracle public usdtOracle;
    MockPriceOracle public daiOracle;
    MockPriceOracle public wethOracle;
    MockPriceOracle public wbtcOracle;
    MockPriceOracle public ptUsdeOracle; // Pendle PT-USDe
    MockPriceOracle public sUsdeOracle; // Staked USDe

    // Price oracles for synthetics - Commodities
    MockPriceOracle public yXAUOracle; // Gold
    MockPriceOracle public ySILVEROracle; // Silver
    MockPriceOracle public yCRUDEOracle; // Crude Oil (WTI)

    // Price oracles for synthetics - Currencies
    MockPriceOracle public yEUROracle; // Euro
    MockPriceOracle public yJPYOracle; // Japanese Yen

    // Price oracles for synthetics - Equities
    MockPriceOracle public yTSLAOracle; // Tesla stock
    MockPriceOracle public yAAPLOracle; // Apple stock
    MockPriceOracle public yNVDAOracle; // Nvidia stock

    // Price oracles for synthetics - Crypto
    MockPriceOracle public yBTCOracle; // Synthetic Bitcoin
    MockPriceOracle public yETHOracle; // Synthetic Ethereum

    // USY oracle
    MockPriceOracle public usyOracle; // USY stablecoin

    // ============================================================
    // SYNTHETIC ASSETS (ALL 18 DECIMALS)
    // ============================================================

    // Commodities
    address public yXAU; // Synthetic Gold
    address public ySILVER; // Synthetic Silver
    address public yCRUDE; // Synthetic Crude Oil

    // Currencies
    address public yEUR; // Synthetic Euro
    address public yJPY; // Synthetic Japanese Yen

    // Equities
    address public yTSLA; // Synthetic Tesla
    address public yAAPL; // Synthetic Apple
    address public yNVDA; // Synthetic Nvidia

    // Crypto
    address public yBTC; // Synthetic Bitcoin
    address public yETH; // Synthetic Ethereum

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
        ptUsde = new MockERC20("PT Ethena USDe 26DEC2025", "PT-USDe-26DEC2025", 18);
        sUsde = new MockERC20("Staked USDe", "sUSDe", 18);

        // ========================================
        // STEP 2: Deploy MockPriceOracle Feeds (BEFORE YoloOracle)
        // ========================================

        // Collateral oracles (8 decimals - Chainlink standard)
        usdcOracle = new MockPriceOracle(1e8, "USDC / USD"); // $1.00
        usdtOracle = new MockPriceOracle(1e8, "USDT / USD"); // $1.00
        daiOracle = new MockPriceOracle(1e8, "DAI / USD"); // $1.00
        wethOracle = new MockPriceOracle(3200e8, "WETH / USD"); // $3,200
        wbtcOracle = new MockPriceOracle(68000e8, "WBTC / USD"); // $68,000
        ptUsdeOracle = new MockPriceOracle(96e6, "PT-USDe / USD"); // $0.96 (96000000 = 0.96 * 1e8)
        sUsdeOracle = new MockPriceOracle(119e6, "sUSDe / USD"); // $1.19 (119000000 = 1.19 * 1e8)

        // Synthetic asset oracles - Commodities (8 decimals)
        yXAUOracle = new MockPriceOracle(2650e8, "yXAU / USD"); // Gold: $2,650/oz
        ySILVEROracle = new MockPriceOracle(3150e6, "ySILVER / USD"); // Silver: $31.50/oz
        yCRUDEOracle = new MockPriceOracle(7580e6, "yCRUDE / USD"); // Crude Oil: $75.80/barrel

        // Synthetic asset oracles - Currencies (8 decimals)
        yEUROracle = new MockPriceOracle(108e6, "yEUR / USD"); // EUR: $1.08
        yJPYOracle = new MockPriceOracle(67e4, "yJPY / USD"); // JPY: $0.0067 (¥150 = $1)

        // Synthetic asset oracles - Equities (8 decimals)
        yTSLAOracle = new MockPriceOracle(340e8, "yTSLA / USD"); // Tesla: $340/share
        yAAPLOracle = new MockPriceOracle(230e8, "yAAPL / USD"); // Apple: $230/share
        yNVDAOracle = new MockPriceOracle(13500e7, "yNVDA / USD"); // Nvidia: $1,350/share

        // Synthetic asset oracles - Crypto (8 decimals)
        yBTCOracle = new MockPriceOracle(68000e8, "yBTC / USD"); // Bitcoin: $68,000
        yETHOracle = new MockPriceOracle(3200e8, "yETH / USD"); // Ethereum: $3,200

        // USY oracle (8 decimals)
        usyOracle = new MockPriceOracle(1e8, "USY / USD"); // $1.00

        // ========================================
        // STEP 3: Deploy YoloOracle with Initial Price Sources
        // ========================================

        // Prepare collateral assets and sources for constructor (7 collaterals + 1 USY = 8)
        address[] memory initialAssets = new address[](8);
        address[] memory initialSources = new address[](8);

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
        initialAssets[5] = address(ptUsde);
        initialSources[5] = address(ptUsdeOracle);
        initialAssets[6] = address(sUsde);
        initialSources[6] = address(sUsdeOracle);
        initialAssets[7] = usy;
        initialSources[7] = address(usyOracle);

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

        // COMMODITIES (18 decimals)

        // yXAU - Synthetic Gold
        yXAU = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Gold",
            "yXAU",
            18,
            address(yXAUOracle),
            address(syntheticAssetImpl),
            0, // unlimited supply
            type(uint256).max // unlimited flash loans
        );

        // ySILVER - Synthetic Silver
        ySILVER = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Silver",
            "ySILVER",
            18,
            address(ySILVEROracle),
            address(syntheticAssetImpl),
            0,
            type(uint256).max
        );

        // yCRUDE - Synthetic Crude Oil
        yCRUDE = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Crude Oil",
            "yCRUDE",
            18,
            address(yCRUDEOracle),
            address(syntheticAssetImpl),
            0,
            type(uint256).max
        );

        // CURRENCIES (18 decimals)

        // yEUR - Synthetic Euro
        yEUR = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Euro", "yEUR", 18, address(yEUROracle), address(syntheticAssetImpl), 0, type(uint256).max
        );

        // yJPY - Synthetic Japanese Yen
        yJPY = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Japanese Yen",
            "yJPY",
            18,
            address(yJPYOracle),
            address(syntheticAssetImpl),
            0,
            type(uint256).max
        );

        // EQUITIES (18 decimals)

        // yTSLA - Synthetic Tesla Stock
        yTSLA = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Tesla", "yTSLA", 18, address(yTSLAOracle), address(syntheticAssetImpl), 0, type(uint256).max
        );

        // yAAPL - Synthetic Apple Stock
        yAAPL = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Apple", "yAAPL", 18, address(yAAPLOracle), address(syntheticAssetImpl), 0, type(uint256).max
        );

        // yNVDA - Synthetic Nvidia Stock
        yNVDA = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Nvidia",
            "yNVDA",
            18,
            address(yNVDAOracle),
            address(syntheticAssetImpl),
            0,
            type(uint256).max
        );

        // CRYPTO (18 decimals)

        // yBTC - Synthetic Bitcoin
        yBTC = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Bitcoin", "yBTC", 18, address(yBTCOracle), address(syntheticAssetImpl), 0, type(uint256).max
        );

        // yETH - Synthetic Ethereum
        yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic Ethereum",
            "yETH",
            18,
            address(yETHOracle),
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
        yoloHook.whitelistCollateral(address(ptUsde));
        yoloHook.whitelistCollateral(address(sUsde));

        // ========================================
        // STEP 9: Configure Lending Pairs
        // ========================================

        // ===================
        // COMMODITIES
        // ===================

        // yXAU (Gold) - Stable commodity, high LTV
        _configureLendingPair(yXAU, address(usdc), 7500, 8000); // Gold / USDC: 75% LTV
        _configureLendingPair(yXAU, address(usdt), 7500, 8000); // Gold / USDT: 75% LTV
        _configureLendingPair(yXAU, address(dai), 7500, 8000); // Gold / DAI: 75% LTV
        _configureLendingPair(yXAU, address(weth), 7000, 7500); // Gold / WETH: 70% LTV
        _configureLendingPair(yXAU, address(ptUsde), 7200, 7700); // Gold / PT-USDe: 72% LTV
        _configureLendingPair(yXAU, address(sUsde), 7300, 7800); // Gold / sUSDe: 73% LTV

        // ySILVER (Silver) - More volatile commodity
        _configureLendingPair(ySILVER, address(usdc), 7000, 7500); // Silver / USDC: 70% LTV
        _configureLendingPair(ySILVER, address(usdt), 7000, 7500); // Silver / USDT: 70% LTV
        _configureLendingPair(ySILVER, address(weth), 6500, 7000); // Silver / WETH: 65% LTV
        _configureLendingPair(ySILVER, address(sUsde), 6800, 7300); // Silver / sUSDe: 68% LTV

        // yCRUDE (Crude Oil) - Volatile commodity
        _configureLendingPair(yCRUDE, address(usdc), 6500, 7000); // Crude / USDC: 65% LTV
        _configureLendingPair(yCRUDE, address(usdt), 6500, 7000); // Crude / USDT: 65% LTV
        _configureLendingPair(yCRUDE, address(dai), 6500, 7000); // Crude / DAI: 65% LTV
        _configureLendingPair(yCRUDE, address(weth), 6000, 6500); // Crude / WETH: 60% LTV

        // ===================
        // CURRENCIES
        // ===================

        // yEUR (Euro) - Stable currency, highest LTV
        _configureLendingPair(yEUR, address(usdc), 8000, 8500); // EUR / USDC: 80% LTV
        _configureLendingPair(yEUR, address(usdt), 8000, 8500); // EUR / USDT: 80% LTV
        _configureLendingPair(yEUR, address(dai), 8000, 8500); // EUR / DAI: 80% LTV
        _configureLendingPair(yEUR, address(ptUsde), 7800, 8300); // EUR / PT-USDe: 78% LTV
        _configureLendingPair(yEUR, address(sUsde), 7900, 8400); // EUR / sUSDe: 79% LTV

        // yJPY (Japanese Yen) - Stable currency
        _configureLendingPair(yJPY, address(usdc), 8000, 8500); // JPY / USDC: 80% LTV
        _configureLendingPair(yJPY, address(usdt), 8000, 8500); // JPY / USDT: 80% LTV
        _configureLendingPair(yJPY, address(dai), 8000, 8500); // JPY / DAI: 80% LTV

        // ===================
        // EQUITIES
        // ===================

        // yTSLA (Tesla) - Volatile stock
        _configureLendingPair(yTSLA, address(usdc), 6000, 6500); // Tesla / USDC: 60% LTV
        _configureLendingPair(yTSLA, address(usdt), 6000, 6500); // Tesla / USDT: 60% LTV
        _configureLendingPair(yTSLA, address(weth), 5500, 6000); // Tesla / WETH: 55% LTV
        _configureLendingPair(yTSLA, address(wbtc), 5500, 6000); // Tesla / WBTC: 55% LTV
        _configureLendingPair(yTSLA, address(sUsde), 5800, 6300); // Tesla / sUSDe: 58% LTV

        // yAAPL (Apple) - Less volatile stock
        _configureLendingPair(yAAPL, address(usdc), 6500, 7000); // Apple / USDC: 65% LTV
        _configureLendingPair(yAAPL, address(usdt), 6500, 7000); // Apple / USDT: 65% LTV
        _configureLendingPair(yAAPL, address(dai), 6500, 7000); // Apple / DAI: 65% LTV
        _configureLendingPair(yAAPL, address(weth), 6000, 6500); // Apple / WETH: 60% LTV
        _configureLendingPair(yAAPL, address(wbtc), 6000, 6500); // Apple / WBTC: 60% LTV
        _configureLendingPair(yAAPL, address(sUsde), 6300, 6800); // Apple / sUSDe: 63% LTV

        // yNVDA (Nvidia) - High volatility tech stock
        _configureLendingPair(yNVDA, address(usdc), 5500, 6000); // Nvidia / USDC: 55% LTV
        _configureLendingPair(yNVDA, address(usdt), 5500, 6000); // Nvidia / USDT: 55% LTV
        _configureLendingPair(yNVDA, address(weth), 5000, 5500); // Nvidia / WETH: 50% LTV
        _configureLendingPair(yNVDA, address(wbtc), 5000, 5500); // Nvidia / WBTC: 50% LTV
        _configureLendingPair(yNVDA, address(ptUsde), 7500, 8000); // Nvidia / PT-USDe: 75% LTV (for leverage tests)
        _configureLendingPair(yNVDA, address(sUsde), 7500, 8000); // Nvidia / sUSDe: 75% LTV (for leverage tests)

        // ===================
        // CRYPTO
        // ===================

        // yBTC (Synthetic Bitcoin) - High volatility crypto
        _configureLendingPair(yBTC, address(usdc), 7000, 7500); // yBTC / USDC: 70% LTV
        _configureLendingPair(yBTC, address(usdt), 7000, 7500); // yBTC / USDT: 70% LTV
        _configureLendingPair(yBTC, address(dai), 7000, 7500); // yBTC / DAI: 70% LTV
        _configureLendingPair(yBTC, address(wbtc), 8000, 8500); // yBTC / WBTC: 80% LTV (same asset)
        _configureLendingPair(yBTC, address(weth), 6500, 7000); // yBTC / WETH: 65% LTV
        _configureLendingPair(yBTC, address(sUsde), 6800, 7300); // yBTC / sUSDe: 68% LTV

        // yETH (Synthetic Ethereum) - High volatility crypto
        _configureLendingPair(yETH, address(usdc), 7000, 7500); // yETH / USDC: 70% LTV
        _configureLendingPair(yETH, address(usdt), 7000, 7500); // yETH / USDT: 70% LTV
        _configureLendingPair(yETH, address(dai), 7000, 7500); // yETH / DAI: 70% LTV
        _configureLendingPair(yETH, address(weth), 8000, 8500); // yETH / WETH: 80% LTV (same asset)
        _configureLendingPair(yETH, address(wbtc), 6500, 7000); // yETH / WBTC: 65% LTV
        _configureLendingPair(yETH, address(ptUsde), 7500, 8000); // yETH / PT-USDe: 75% LTV (for leverage tests)
        _configureLendingPair(yETH, address(sUsde), 7500, 8000); // yETH / sUSDe: 75% LTV (for leverage tests)

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
     * @return Array of collateral addresses [USDC, USDT, DAI, WETH, WBTC, PT-USDe, sUSDe]
     */
    function getCollateralAssets() public view returns (address[] memory) {
        address[] memory collaterals = new address[](7);
        collaterals[0] = address(usdc);
        collaterals[1] = address(usdt);
        collaterals[2] = address(dai);
        collaterals[3] = address(weth);
        collaterals[4] = address(wbtc);
        collaterals[5] = address(ptUsde);
        collaterals[6] = address(sUsde);
        return collaterals;
    }

    /**
     * @notice Get all synthetic assets
     * @return Array of synthetic addresses [Commodities: yXAU, ySILVER, yCRUDE | Currencies: yEUR, yJPY | Equities: yTSLA, yAAPL, yNVDA | Crypto: yBTC, yETH]
     */
    function getSyntheticAssets() public view returns (address[] memory) {
        address[] memory synthetics = new address[](10);
        // Commodities
        synthetics[0] = yXAU;
        synthetics[1] = ySILVER;
        synthetics[2] = yCRUDE;
        // Currencies
        synthetics[3] = yEUR;
        synthetics[4] = yJPY;
        // Equities
        synthetics[5] = yTSLA;
        synthetics[6] = yAAPL;
        synthetics[7] = yNVDA;
        // Crypto
        synthetics[8] = yBTC;
        synthetics[9] = yETH;
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

    // function test_Base03_Case01_CollateralAssetsDeployed() public {
    //     address[] memory collaterals = getCollateralAssets();
    //     assertEq(collaterals.length, 7, "Should have 7 collateral assets");
    //     assertEq(collaterals[0], address(usdc), "USDC address mismatch");
    //     assertEq(collaterals[1], address(usdt), "USDT address mismatch");
    //     assertEq(collaterals[2], address(dai), "DAI address mismatch");
    //     assertEq(collaterals[3], address(weth), "WETH address mismatch");
    //     assertEq(collaterals[4], address(wbtc), "WBTC address mismatch");
    //     assertEq(collaterals[5], address(ptUsde), "PT-USDe address mismatch");
    //     assertEq(collaterals[6], address(sUsde), "sUSDe address mismatch");
    // }

    // function test_Base03_Case02_SyntheticAssetsDeployed() public {
    //     address[] memory synthetics = getSyntheticAssets();
    //     assertEq(synthetics.length, 10, "Should have 10 synthetic assets");
    //     // Commodities
    //     assertTrue(synthetics[0] != address(0), "yXAU not deployed");
    //     assertTrue(synthetics[1] != address(0), "ySILVER not deployed");
    //     assertTrue(synthetics[2] != address(0), "yCRUDE not deployed");
    //     // Currencies
    //     assertTrue(synthetics[3] != address(0), "yEUR not deployed");
    //     assertTrue(synthetics[4] != address(0), "yJPY not deployed");
    //     // Equities
    //     assertTrue(synthetics[5] != address(0), "yTSLA not deployed");
    //     assertTrue(synthetics[6] != address(0), "yAAPL not deployed");
    //     assertTrue(synthetics[7] != address(0), "yNVDA not deployed");
    //     // Crypto
    //     assertTrue(synthetics[8] != address(0), "yBTC not deployed");
    //     assertTrue(synthetics[9] != address(0), "yETH not deployed");
    // }

    // function test_Base03_Case03_CollateralOraclesConfigured() public {
    //     // Stablecoins
    //     assertTrue(getAssetOracle(address(usdc)) != address(0), "USDC oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(address(usdc)), 1e8, "USDC price should be $1");
    //     assertTrue(getAssetOracle(address(usdt)) != address(0), "USDT oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(address(usdt)), 1e8, "USDT price should be $1");
    //     assertTrue(getAssetOracle(address(dai)) != address(0), "DAI oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(address(dai)), 1e8, "DAI price should be $1");

    //     // Crypto
    //     assertTrue(getAssetOracle(address(weth)) != address(0), "WETH oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(address(weth)), 3200e8, "WETH price should be $3200");
    //     assertTrue(getAssetOracle(address(wbtc)) != address(0), "WBTC oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(address(wbtc)), 68000e8, "WBTC price should be $68000");

    //     // DeFi assets
    //     assertTrue(getAssetOracle(address(ptUsde)) != address(0), "PT-USDe oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(address(ptUsde)), 96e6, "PT-USDe price should be $0.96");
    //     assertTrue(getAssetOracle(address(sUsde)) != address(0), "sUSDe oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(address(sUsde)), 119e6, "sUSDe price should be $1.19");
    // }

    // function test_Base03_Case04_SyntheticOraclesConfigured() public {
    //     // Commodities
    //     assertTrue(getAssetOracle(yXAU) != address(0), "yXAU oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yXAU), 2650e8, "yXAU price should be $2650");
    //     assertTrue(getAssetOracle(ySILVER) != address(0), "ySILVER oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(ySILVER), 3150e6, "ySILVER price should be $31.50");
    //     assertTrue(getAssetOracle(yCRUDE) != address(0), "yCRUDE oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yCRUDE), 7580e6, "yCRUDE price should be $75.80");

    //     // Currencies
    //     assertTrue(getAssetOracle(yEUR) != address(0), "yEUR oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yEUR), 108e6, "yEUR price should be $1.08");
    //     assertTrue(getAssetOracle(yJPY) != address(0), "yJPY oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yJPY), 67e4, "yJPY price should be $0.0067");

    //     // Equities
    //     assertTrue(getAssetOracle(yTSLA) != address(0), "yTSLA oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yTSLA), 340e8, "yTSLA price should be $340");
    //     assertTrue(getAssetOracle(yAAPL) != address(0), "yAAPL oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yAAPL), 230e8, "yAAPL price should be $230");
    //     assertTrue(getAssetOracle(yNVDA) != address(0), "yNVDA oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yNVDA), 13500e7, "yNVDA price should be $1350");

    //     // Crypto
    //     assertTrue(getAssetOracle(yBTC) != address(0), "yBTC oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yBTC), 68000e8, "yBTC price should be $68000");
    //     assertTrue(getAssetOracle(yETH) != address(0), "yETH oracle not configured");
    //     assertEq(yoloOracleReal.getAssetPrice(yETH), 3200e8, "yETH price should be $3200");
    // }

    // function test_Base03_Case05_CollateralsWhitelisted() public {
    //     assertTrue(yoloHook.isWhitelistedCollateral(address(usdc)), "USDC not whitelisted");
    //     assertTrue(yoloHook.isWhitelistedCollateral(address(usdt)), "USDT not whitelisted");
    //     assertTrue(yoloHook.isWhitelistedCollateral(address(dai)), "DAI not whitelisted");
    //     assertTrue(yoloHook.isWhitelistedCollateral(address(weth)), "WETH not whitelisted");
    //     assertTrue(yoloHook.isWhitelistedCollateral(address(wbtc)), "WBTC not whitelisted");
    //     assertTrue(yoloHook.isWhitelistedCollateral(address(ptUsde)), "PT-USDe not whitelisted");
    //     assertTrue(yoloHook.isWhitelistedCollateral(address(sUsde)), "sUSDe not whitelisted");
    // }

    // function test_Base03_Case06_YLPVaultFunded() public {
    //     uint256 ylpBalance = IERC20(usy).balanceOf(ylpVault);
    //     assertEq(ylpBalance, 1_000_000e18, "YLP vault should have 1M USY");
    // }

    // function test_Base03_Case07_sUSYInitialLiquidity() public {
    //     uint256 sUSYBalance = IERC20(sUSY).balanceOf(address(this));
    //     assertTrue(sUSYBalance > 0, "Should have sUSY balance");

    //     // In Uniswap V4, liquidity tokens are held by PoolManager, not the hook
    //     // The hook tracks reserves in storage
    //     (uint256 reserveUSY, uint256 reserveUSDC) = yoloHook.getAnchorReserves();
    //     assertTrue(reserveUSY > 0, "Should have USY reserves");
    //     assertTrue(reserveUSDC > 0, "Should have USDC reserves");
    // }

    // function test_Base03_Case08_CanBorrowSyntheticAssets() public {
    //     usdc.mint(address(this), 10000e6);
    //     usdc.approve(address(yoloHook), type(uint256).max);
    //     yoloHook.borrow(yXAU, 1e18, address(usdc), 3600e6, address(this)); // Borrow 1 yXAU (Gold)
    //     assertEq(IERC20(yXAU).balanceOf(address(this)), 1e18, "Should receive 1 yXAU");
    // }

    // function test_Base03_Case09_OraclePricesCanBeUpdated() public {
    //     assertEq(yoloOracleReal.getAssetPrice(yXAU), 2650e8, "Initial yXAU price");
    //     yXAUOracle.updateAnswer(2700e8);
    //     assertEq(yoloOracleReal.getAssetPrice(yXAU), 2700e8, "Updated yXAU price");
    // }

    // function test_Base03_Case10_SyntheticAssetsAreYoloAssets() public {
    //     // Commodities
    //     assertTrue(yoloHook.isYoloAsset(yXAU), "yXAU should be a YOLO asset");
    //     assertTrue(yoloHook.isYoloAsset(ySILVER), "ySILVER should be a YOLO asset");
    //     assertTrue(yoloHook.isYoloAsset(yCRUDE), "yCRUDE should be a YOLO asset");
    //     // Currencies
    //     assertTrue(yoloHook.isYoloAsset(yEUR), "yEUR should be a YOLO asset");
    //     assertTrue(yoloHook.isYoloAsset(yJPY), "yJPY should be a YOLO asset");
    //     // Equities
    //     assertTrue(yoloHook.isYoloAsset(yTSLA), "yTSLA should be a YOLO asset");
    //     assertTrue(yoloHook.isYoloAsset(yAAPL), "yAAPL should be a YOLO asset");
    //     assertTrue(yoloHook.isYoloAsset(yNVDA), "yNVDA should be a YOLO asset");
    //     // Crypto
    //     assertTrue(yoloHook.isYoloAsset(yBTC), "yBTC should be a YOLO asset");
    //     assertTrue(yoloHook.isYoloAsset(yETH), "yETH should be a YOLO asset");
    //     // Anchor
    //     assertTrue(yoloHook.isYoloAsset(usy), "USY should be a YOLO asset");
    // }
}
