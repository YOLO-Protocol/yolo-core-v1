// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base02_DeployYoloHook} from "./base/Base02_DeployYoloHook.t.sol";
import {YoloHook} from "../src/core/YoloHook.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";
import {IYoloOracle} from "../src/interfaces/IYoloOracle.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockYoloOracle} from "../src/mocks/MockYoloOracle.sol";

/**
 * @title TestAction01_CreateSyntheticAsset
 * @notice Comprehensive test suite for synthetic asset creation and pairing
 * @dev Tests YoloHook's asset creation, management, and lending pair configuration
 */
contract TestAction01_CreateSyntheticAsset is Base02_DeployYoloHook {
    // ============================================================
    // CONTRACTS
    // ============================================================

    YoloSyntheticAsset public syntheticAssetImpl;

    // ============================================================
    // TEST ACCOUNTS
    // ============================================================

    address public assetsAdmin = makeAddr("assetsAdmin");
    address public riskAdmin = makeAddr("riskAdmin");
    address public pauser = makeAddr("pauser");
    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // ============================================================
    // MOCK ASSETS
    // ============================================================

    MockERC20 public weth;
    MockERC20 public wbtc;

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public override {
        super.setUp(); // Deploy YoloHook from Base02

        // Deploy test-specific collateral
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);

        // Set up ACL roles for test
        aclManager.createRole("ASSETS_ADMIN", bytes32(0));
        aclManager.createRole("RISK_ADMIN", bytes32(0));
        aclManager.createRole("PAUSER", bytes32(0));
        aclManager.grantRole(keccak256("ASSETS_ADMIN"), assetsAdmin);
        aclManager.grantRole(keccak256("RISK_ADMIN"), riskAdmin);
        aclManager.grantRole(keccak256("PAUSER"), pauser);

        // Verify proxy setup
        assertEq(address(yoloHook.yoloOracle()), address(oracle), "Oracle mismatch");
        assertTrue(usy != address(0), "USY should be deployed");
        assertTrue(sUSY != address(0), "sUSY should be deployed");
        assertEq(yoloHook.usdcDecimals(), 6, "USDC decimals should be 6");
        assertEq(yoloHook.ylpVault(), address(ylpVault), "YLP vault mismatch");

        // Deploy test-specific synthetic asset implementation
        syntheticAssetImpl = new YoloSyntheticAsset();

        // Set up oracle prices
        oracle.setAssetPrice(address(weth), 2000e8); // $2000 per ETH
        oracle.setAssetPrice(address(wbtc), 40000e8); // $40000 per BTC
        oracle.setAssetPrice(address(usdc), 1e8); // $1 per USDC
    }

    // ============================================================
    // TEST CASE 01: SUCCESSFUL SYNTHETIC ASSET CREATION
    // ============================================================

    function test_Action01_Case01_createSyntheticAssetSuccess() public {
        vm.startPrank(assetsAdmin);

        address syntheticAsset = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH",
            "yETH",
            18,
            address(weth), // underlying
            address(weth), // oracle source
            address(syntheticAssetImpl),
            0, // no max supply
            0 // no flash loan cap
        );

        vm.stopPrank();

        // Verify synthetic asset was created
        assertTrue(syntheticAsset != address(0), "Synthetic asset should be created");
        assertTrue(yoloHook.isYoloAsset(syntheticAsset), "Should be registered as YOLO asset");

        // Verify configuration
        DataTypes.AssetConfiguration memory config = yoloHook.getAssetConfiguration(syntheticAsset);
        assertEq(config.syntheticToken, syntheticAsset, "Synthetic token address mismatch");
        assertEq(config.underlyingAsset, address(weth), "Underlying asset mismatch");
        assertEq(config.oracleSource, address(weth), "Oracle source mismatch");
        assertEq(config.maxSupply, 0, "Max supply should be unlimited");
        assertTrue(config.isActive, "Asset should be active");
        assertEq(config.createdAt, block.timestamp, "Created timestamp mismatch");

        // Verify token properties
        YoloSyntheticAsset synthToken = YoloSyntheticAsset(syntheticAsset);
        assertEq(synthToken.name(), "Yolo Synthetic ETH", "Token name mismatch");
        assertEq(synthToken.symbol(), "yETH", "Token symbol mismatch");
        assertEq(synthToken.decimals(), 18, "Token decimals mismatch");
        assertEq(synthToken.underlyingAsset(), address(weth), "Token underlying mismatch");
        assertEq(synthToken.maxSupply(), 0, "Token max supply mismatch");
        assertTrue(synthToken.tradingEnabled(), "Trading should be enabled");
    }

    // ============================================================
    // TEST CASE 02: ACCESS CONTROL - ONLY ASSETS ADMIN
    // ============================================================

    function test_Action01_Case02_onlyAssetsAdminCanCreate() public {
        vm.prank(user1);
        vm.expectRevert(YoloHook.YoloHook__CallerNotAuthorized.selector);
        yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );
    }

    // ============================================================
    // TEST CASE 03: CREATE MULTIPLE SYNTHETIC ASSETS
    // ============================================================

    function test_Action01_Case03_createMultipleSyntheticAssets() public {
        vm.startPrank(assetsAdmin);

        // Create yETH
        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        // Create yBTC
        address yBTC = yoloHook.createSyntheticAsset(
            "Yolo Synthetic BTC", "yBTC", 8, address(wbtc), address(wbtc), address(syntheticAssetImpl), 0, 0
        );

        vm.stopPrank();

        // Verify both assets registered
        assertTrue(yoloHook.isYoloAsset(yETH), "yETH should be registered");
        assertTrue(yoloHook.isYoloAsset(yBTC), "yBTC should be registered");

        // Verify getAllSyntheticAssets (includes USY created during initialization)
        address[] memory assets = yoloHook.getAllSyntheticAssets();
        assertEq(assets.length, 3, "Should have 3 assets (USY + yETH + yBTC)");
        assertEq(assets[0], usy, "First asset should be USY");
        assertEq(assets[1], yETH, "Second asset should be yETH");
        assertEq(assets[2], yBTC, "Third asset should be yBTC");
    }

    // ============================================================
    // TEST CASE 04: ASSET DEACTIVATION
    // ============================================================

    function test_Action01_Case04_deactivateSyntheticAsset() public {
        vm.startPrank(assetsAdmin);

        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        // Deactivate asset
        yoloHook.deactivateSyntheticAsset(yETH);

        vm.stopPrank();

        // Verify deactivation
        DataTypes.AssetConfiguration memory config = yoloHook.getAssetConfiguration(yETH);
        assertFalse(config.isActive, "Asset should be deactivated");
    }

    // ============================================================
    // TEST CASE 05: ASSET REACTIVATION
    // ============================================================

    function test_Action01_Case05_reactivateSyntheticAsset() public {
        vm.startPrank(assetsAdmin);

        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        // Deactivate then reactivate
        yoloHook.deactivateSyntheticAsset(yETH);
        yoloHook.reactivateSyntheticAsset(yETH);

        vm.stopPrank();

        // Verify reactivation
        DataTypes.AssetConfiguration memory config = yoloHook.getAssetConfiguration(yETH);
        assertTrue(config.isActive, "Asset should be reactivated");
    }

    // ============================================================
    // TEST CASE 06: COLLATERAL WHITELISTING
    // ============================================================

    function test_Action01_Case06_whitelistCollateral() public {
        vm.startPrank(assetsAdmin);

        yoloHook.whitelistCollateral(address(usdc));
        yoloHook.whitelistCollateral(address(weth));

        vm.stopPrank();

        // Verify whitelisting (tested via pair config - collateral must be whitelisted)
        // We'll verify in the next test by successfully creating a pair
    }

    // ============================================================
    // TEST CASE 07: LENDING PAIR CONFIGURATION
    // ============================================================

    function test_Action01_Case07_configureLendingPair() public {
        vm.startPrank(assetsAdmin);

        // Create synthetic asset
        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        // Whitelist collateral
        yoloHook.whitelistCollateral(address(usdc));

        // Configure lending pair (no deposit/debt tokens)
        bytes32 pairId = yoloHook.configureLendingPair(
            yETH, // synthetic asset
            address(usdc), // collateral
            address(0), // no deposit token
            address(0), // no debt token
            8000, // 80% LTV
            8500, // 85% liquidation threshold
            500, // 5% liquidation bonus
            500, // 5% liquidation penalty
            300, // 3% borrow rate
            type(uint256).max, // unlimited mint cap
            type(uint256).max, // unlimited supply cap
            1e18, // minimum borrow amount (1 unit)
            false, // not expirable
            0 // no expiry period
        );

        vm.stopPrank();

        // Verify pair configuration
        DataTypes.PairConfiguration memory config = yoloHook.getPairConfiguration(yETH, address(usdc));
        assertEq(config.syntheticAsset, yETH, "Synthetic asset mismatch");
        assertEq(config.collateralAsset, address(usdc), "Collateral asset mismatch");
        assertEq(config.depositToken, address(0), "Deposit token should be zero");
        assertEq(config.debtToken, address(0), "Debt token should be zero");
        assertEq(config.ltv, 8000, "LTV mismatch");
        assertEq(config.liquidationThreshold, 8500, "Liquidation threshold mismatch");
        assertEq(config.liquidationBonus, 500, "Liquidation bonus mismatch");
        assertEq(config.borrowRate, 300, "Borrow rate mismatch");
        assertTrue(config.isActive, "Pair should be active");
    }

    // ============================================================
    // TEST CASE 08: LENDING PAIR WITH OPTIONAL TOKENS
    // ============================================================

    function test_Action01_Case08_configureLendingPairWithTokens() public {
        address depositToken = makeAddr("depositToken");
        address debtToken = makeAddr("debtToken");

        vm.startPrank(assetsAdmin);

        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        yoloHook.whitelistCollateral(address(usdc));

        // Configure with deposit/debt tokens
        yoloHook.configureLendingPair(
            yETH,
            address(usdc),
            depositToken,
            debtToken,
            8000,
            8500,
            500,
            500,
            300,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            false,
            0
        );

        vm.stopPrank();

        // Verify tokens are set
        DataTypes.PairConfiguration memory config = yoloHook.getPairConfiguration(yETH, address(usdc));
        assertEq(config.depositToken, depositToken, "Deposit token mismatch");
        assertEq(config.debtToken, debtToken, "Debt token mismatch");
    }

    // ============================================================
    // TEST CASE 09: MULTIPLE COLLATERALS FOR ONE SYNTHETIC
    // ============================================================

    function test_Action01_Case09_multipleCollateralsForSynthetic() public {
        vm.startPrank(assetsAdmin);

        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        // Whitelist multiple collaterals
        yoloHook.whitelistCollateral(address(usdc));
        yoloHook.whitelistCollateral(address(weth));

        // Configure multiple pairs
        yoloHook.configureLendingPair(
            yETH,
            address(usdc),
            address(0),
            address(0),
            8000,
            8500,
            500,
            500,
            300,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            false,
            0
        );
        yoloHook.configureLendingPair(
            yETH,
            address(weth),
            address(0),
            address(0),
            7500,
            8000,
            500,
            500,
            250,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            false,
            0
        );

        vm.stopPrank();

        // Verify both pairs exist
        DataTypes.PairConfiguration memory config1 = yoloHook.getPairConfiguration(yETH, address(usdc));
        DataTypes.PairConfiguration memory config2 = yoloHook.getPairConfiguration(yETH, address(weth));

        assertTrue(config1.isActive, "USDC pair should be active");
        assertTrue(config2.isActive, "WETH pair should be active");
        assertEq(config1.ltv, 8000, "USDC LTV mismatch");
        assertEq(config2.ltv, 7500, "WETH LTV mismatch");
    }

    // ============================================================
    // TEST CASE 10: RISK PARAMETER UPDATES
    // ============================================================

    function test_Action01_Case10_updateRiskParameters() public {
        vm.startPrank(assetsAdmin);

        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        yoloHook.whitelistCollateral(address(usdc));
        bytes32 pairId = yoloHook.configureLendingPair(
            yETH,
            address(usdc),
            address(0),
            address(0),
            8000,
            8500,
            500,
            500,
            300,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            false,
            0
        );

        vm.stopPrank();

        // Update risk parameters as risk admin
        vm.prank(riskAdmin);
        yoloHook.updateRiskParameters(
            pairId,
            7000, // new LTV
            7500, // new liquidation threshold
            1000 // new liquidation bonus
        );

        // Verify updates
        DataTypes.PairConfiguration memory config = yoloHook.getPairConfiguration(yETH, address(usdc));
        assertEq(config.ltv, 7000, "LTV should be updated");
        assertEq(config.liquidationThreshold, 7500, "Liquidation threshold should be updated");
        assertEq(config.liquidationBonus, 1000, "Liquidation bonus should be updated");
    }

    // ============================================================
    // TEST CASE 11: ONLY RISK ADMIN CAN UPDATE RISK PARAMETERS
    // ============================================================

    function test_Action01_Case11_onlyRiskAdminCanUpdateRiskParams() public {
        vm.startPrank(assetsAdmin);

        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        yoloHook.whitelistCollateral(address(usdc));
        bytes32 pairId = yoloHook.configureLendingPair(
            yETH,
            address(usdc),
            address(0),
            address(0),
            8000,
            8500,
            500,
            500,
            300,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            false,
            0
        );

        vm.stopPrank();

        // Try to update as non-admin
        vm.prank(user1);
        vm.expectRevert(YoloHook.YoloHook__CallerNotAuthorized.selector);
        yoloHook.updateRiskParameters(pairId, 7000, 7500, 1000);
    }

    // ============================================================
    // TEST CASE 12: ORACLE UPDATE
    // ============================================================

    function test_Action01_Case12_updateOracle() public {
        MockYoloOracle newOracle = new MockYoloOracle();

        vm.prank(riskAdmin);
        yoloHook.updateOracle(IYoloOracle(address(newOracle)));

        // Verify oracle updated
        assertEq(address(yoloHook.yoloOracle()), address(newOracle), "Oracle should be updated");
    }

    // ============================================================
    // TEST CASE 13: YLP VAULT UPDATE
    // ============================================================

    function test_Action01_Case13_updateYLPVault() public {
        address newVault = makeAddr("newVault");

        vm.prank(assetsAdmin);
        yoloHook.updateYLPVault(newVault);

        // Verify vault updated
        assertEq(yoloHook.ylpVault(), newVault, "YLP vault should be updated");
    }

    // ============================================================
    // TEST CASE 14: SYNTHETIC ASSET UPGRADE
    // ============================================================

    function test_Action01_Case14_upgradeSyntheticAsset() public {
        vm.startPrank(assetsAdmin);

        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        // Deploy new implementation
        YoloSyntheticAsset newImpl = new YoloSyntheticAsset();

        // Upgrade synthetic asset
        yoloHook.upgradeSyntheticAsset(yETH, address(newImpl));

        vm.stopPrank();

        // Verify asset still functions (proxy pattern)
        YoloSyntheticAsset synthToken = YoloSyntheticAsset(yETH);
        assertEq(synthToken.name(), "Yolo Synthetic ETH", "Name should persist after upgrade");
    }

    // ============================================================
    // TEST CASE 15: CANNOT UPGRADE NON-YOLO ASSET
    // ============================================================

    function test_Action01_Case15_cannotUpgradeNonYoloAsset() public {
        address randomAsset = makeAddr("randomAsset");
        YoloSyntheticAsset newImpl = new YoloSyntheticAsset();

        vm.prank(assetsAdmin);
        vm.expectRevert(YoloHook.YoloHook__NotYoloAsset.selector);
        yoloHook.upgradeSyntheticAsset(randomAsset, address(newImpl));
    }

    // ============================================================
    // TEST CASE 16: INVALID ORACLE REVERTS
    // ============================================================

    function test_Action01_Case16_invalidOracleReverts() public {
        vm.prank(riskAdmin);
        vm.expectRevert(YoloHook.YoloHook__InvalidOracle.selector);
        yoloHook.updateOracle(IYoloOracle(address(0)));
    }

    // ============================================================
    // TEST CASE 17: INVALID YLP VAULT REVERTS
    // ============================================================

    function test_Action01_Case17_invalidYLPVaultReverts() public {
        vm.prank(assetsAdmin);
        vm.expectRevert(YoloHook.YoloHook__InvalidAddress.selector);
        yoloHook.updateYLPVault(address(0));
    }

    // ============================================================
    // TEST CASE 18: CREATE WITH MAX SUPPLY CAP
    // ============================================================

    function test_Action01_Case18_createWithMaxSupply() public {
        vm.prank(assetsAdmin);

        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH",
            "yETH",
            18,
            address(weth),
            address(weth),
            address(syntheticAssetImpl),
            1000000e18, // 1M max supply
            0 // no flash loan cap
        );

        // Verify max supply
        YoloSyntheticAsset synthToken = YoloSyntheticAsset(yETH);
        assertEq(synthToken.maxSupply(), 1000000e18, "Max supply should be set");
    }

    // ============================================================
    // TEST CASE 19: COMPLEX INTEGRATION TEST
    // ============================================================

    function test_Action01_Case19_complexIntegrationFlow() public {
        vm.startPrank(assetsAdmin);

        // Create multiple synthetic assets
        address yETH = yoloHook.createSyntheticAsset(
            "Yolo Synthetic ETH", "yETH", 18, address(weth), address(weth), address(syntheticAssetImpl), 0, 0
        );

        address yBTC = yoloHook.createSyntheticAsset(
            "Yolo Synthetic BTC", "yBTC", 8, address(wbtc), address(wbtc), address(syntheticAssetImpl), 0, 0
        );

        // Whitelist collaterals
        yoloHook.whitelistCollateral(address(usdc));
        yoloHook.whitelistCollateral(address(weth));

        // Configure multiple pairs
        yoloHook.configureLendingPair(
            yETH,
            address(usdc),
            address(0),
            address(0),
            8000,
            8500,
            500,
            500,
            300,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            false,
            0
        );
        yoloHook.configureLendingPair(
            yETH,
            address(weth),
            address(0),
            address(0),
            7500,
            8000,
            500,
            500,
            250,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            false,
            0
        );
        yoloHook.configureLendingPair(
            yBTC,
            address(usdc),
            address(0),
            address(0),
            7000,
            7500,
            500,
            500,
            400,
            type(uint256).max,
            type(uint256).max,
            1e18, // minimum borrow amount (1 unit)
            false,
            0
        );

        vm.stopPrank();

        // Verify all assets and pairs (includes USY created during initialization)
        address[] memory assets = yoloHook.getAllSyntheticAssets();
        assertEq(assets.length, 3, "Should have 3 assets (USY + yETH + yBTC)");

        DataTypes.PairConfiguration memory config1 = yoloHook.getPairConfiguration(yETH, address(usdc));
        DataTypes.PairConfiguration memory config2 = yoloHook.getPairConfiguration(yETH, address(weth));
        DataTypes.PairConfiguration memory config3 = yoloHook.getPairConfiguration(yBTC, address(usdc));

        assertTrue(config1.isActive, "yETH-USDC pair should be active");
        assertTrue(config2.isActive, "yETH-WETH pair should be active");
        assertTrue(config3.isActive, "yBTC-USDC pair should be active");

        // Test asset deactivation
        vm.prank(assetsAdmin);
        yoloHook.deactivateSyntheticAsset(yETH);

        DataTypes.AssetConfiguration memory assetConfig = yoloHook.getAssetConfiguration(yETH);
        assertFalse(assetConfig.isActive, "yETH should be deactivated");

        // Test risk parameter update
        bytes32 pairId = keccak256(abi.encodePacked(yBTC, address(usdc)));
        vm.prank(riskAdmin);
        yoloHook.updateRiskParameters(pairId, 6500, 7000, 1000);

        DataTypes.PairConfiguration memory updatedConfig = yoloHook.getPairConfiguration(yBTC, address(usdc));
        assertEq(updatedConfig.ltv, 6500, "LTV should be updated");
    }

    // ============================================================
    // TEST CASE 20: PAUSE PROTOCOL
    // ============================================================

    function test_Action01_Case20_pauseProtocol() public {
        vm.prank(pauser);
        yoloHook.pause();

        assertTrue(yoloHook.paused(), "Protocol should be paused");

        vm.prank(pauser);
        yoloHook.unpause();

        assertFalse(yoloHook.paused(), "Protocol should be unpaused");
    }
}
