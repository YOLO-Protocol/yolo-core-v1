// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base03_DeployComprehensiveTestEnvironment} from "./Base03_DeployComprehensiveTestEnvironment.t.sol";
import {MockPyth} from "../../src/mocks/MockPyth.sol";
import {PythPriceFeed} from "../../src/oracles/PythPriceFeed.sol";
import {TradeOrchestrator} from "../../src/trade/TradeOrchestrator.sol";
import {DataTypes} from "../../src/libraries/DataTypes.sol";
import {IYLPVault} from "../../src/interfaces/IYLPVault.sol";
import {IACLManager} from "../../src/interfaces/IACLManager.sol";
import {YoloSyntheticAsset} from "../../src/tokenization/YoloSyntheticAsset.sol";
import {YoloHook} from "../../src/core/YoloHook.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";

/**
 * @title Base04_TradePerpTestEnvironment
 * @notice Extends Base03 with Pyth-style oracle adapters and a configured TradeOrchestrator
 * @dev Installs MockPyth price feeds for all collateral/synthetic assets, deploys the TradeOrchestrator,
 *      grants necessary ACL roles, and configures a default perp market (yNVDA) used across perp tests.
 */
contract Base04_TradePerpTestEnvironment is Base03_DeployComprehensiveTestEnvironment {
    using SafeCast for uint256;

    // ============================================================
    // CONSTANTS
    // ============================================================

    uint32 internal constant PYTH_MAX_LAG = 1 hours;
    bytes32 internal constant TRADE_OPERATOR_ROLE = keccak256("TRADE_OPERATOR");
    bytes32 internal constant TRADE_ADMIN_ROLE = keccak256("TRADE_ADMIN_ROLE");
    bytes32 internal constant TRADE_KEEPER_ROLE = keccak256("TRADE_KEEPER_ROLE");

    // ============================================================
    // STATE
    // ============================================================

    MockPyth public mockPyth;
    TradeOrchestrator public tradeOrchestrator;

    mapping(address => bytes32) public assetPriceIds;
    mapping(address => address) public assetPriceFeeds;

    address public perpAsset;
    address public perpTrader = makeAddr("perpTrader");
    address public perpKeeper = makeAddr("perpKeeper");

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public virtual override {
        super.setUp();

        mockPyth = new MockPyth();
        mockPyth.setUpdateFee(0);

        _installPythFeeds();

        tradeOrchestrator = new TradeOrchestrator(
            IACLManager(address(aclManager)), yoloHook, IYLPVault(ylpVault), IPyth(address(mockPyth))
        );

        _setupTradeRoles();

        perpAsset = yNVDA;
        _configurePerpAsset(perpAsset);
        _configureTradeAsset(perpAsset);

        // Seed trader with USY liquidity
        vm.startPrank(address(yoloHook));
        YoloSyntheticAsset(usy).mint(perpTrader, 1_000_000e18);
        vm.stopPrank();

        vm.prank(perpTrader);
        IERC20(usy).approve(address(tradeOrchestrator), type(uint256).max);
    }

    // ============================================================
    // INTERNAL HELPERS
    // ============================================================

    function _installPythFeeds() internal {
        _registerAssetOracle(address(usdc), "USDC / USD");
        _registerAssetOracle(address(usdt), "USDT / USD");
        _registerAssetOracle(address(dai), "DAI / USD");
        _registerAssetOracle(address(weth), "WETH / USD");
        _registerAssetOracle(address(wbtc), "WBTC / USD");
        _registerAssetOracle(address(ptUsde), "PT-USDe / USD");
        _registerAssetOracle(address(sUsde), "sUSDe / USD");

        _registerAssetOracle(yXAU, "yXAU / USD");
        _registerAssetOracle(ySILVER, "ySILVER / USD");
        _registerAssetOracle(yCRUDE, "yCRUDE / USD");
        _registerAssetOracle(yEUR, "yEUR / USD");
        _registerAssetOracle(yJPY, "yJPY / USD");
        _registerAssetOracle(yTSLA, "yTSLA / USD");
        _registerAssetOracle(yAAPL, "yAAPL / USD");
        _registerAssetOracle(yNVDA, "yNVDA / USD");
        _registerAssetOracle(yBTC, "yBTC / USD");
        _registerAssetOracle(yETH, "yETH / USD");
    }

    function _registerAssetOracle(address asset, string memory label) internal {
        uint256 price = yoloOracleReal.getAssetPrice(asset);
        bytes32 priceId = keccak256(abi.encodePacked(label, asset));
        assetPriceIds[asset] = priceId;
        PythPriceFeed feed = new PythPriceFeed(address(mockPyth), priceId, label, PYTH_MAX_LAG);
        assetPriceFeeds[asset] = address(feed);
        mockPyth.setPrice(priceId, SafeCast.toInt64(int256(price)), -8, block.timestamp);

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = asset;
        sources[0] = address(feed);
        yoloOracleReal.setAssetSources(assets, sources);
    }

    function _setupTradeRoles() internal {
        // Ensure orchestration roles exist
        aclManager.createRole("TRADE_OPERATOR", bytes32(0));
        aclManager.createRole("TRADE_ADMIN_ROLE", bytes32(0));
        aclManager.createRole("TRADE_KEEPER_ROLE", bytes32(0));

        aclManager.grantRole(TRADE_OPERATOR_ROLE, address(tradeOrchestrator));
        aclManager.grantRole(TRADE_ADMIN_ROLE, address(this));
        aclManager.grantRole(TRADE_KEEPER_ROLE, address(this));
        aclManager.grantRole(TRADE_KEEPER_ROLE, perpKeeper);
    }

    function _configurePerpAsset(address asset) internal {
        DataTypes.PerpConfiguration memory config = DataTypes.PerpConfiguration({
            enabled: true,
            maxOpenInterestUsd: 100_000_000e18,
            maxLongOpenInterestUsd: 50_000_000e18,
            maxShortOpenInterestUsd: 50_000_000e18,
            maxLeverageBpsDay: 100_000,
            maxLeverageBpsCarryOvernight: 30_000,
            tradeSessionStart: 13 hours,
            tradeSessionEnd: 22 hours,
            marketState: DataTypes.TradeMarketState.OPEN
        });

        YoloHook(address(yoloHook)).updateAssetPerpConfiguration(asset, config);
    }

    function _configureTradeAsset(address asset) internal {
        TradeOrchestrator.TradeAssetConfig memory cfg = TradeOrchestrator.TradeAssetConfig({
            pythPriceId: assetPriceIds[asset],
            maxPriceAgeSec: 120,
            maxDeviationBps: 200,
            longSpreadBps: 5,
            shortSpreadBps: 5,
            fundingFactorPerHour: 5e5,
            fixedBorrowBps: 300,
            liquidationThresholdBps: 2500,
            liquidationRewardBps: 500,
            openFeeBps: 10,
            closeFeeBps: 10,
            overnightUnwindFeeBps: 50,
            minCollateralUsy: 1_000e18,
            feesEnabled: true,
            isActive: true
        });

        tradeOrchestrator.configureTradeAsset(asset, cfg);
    }

    // ============================================================
    // PRICE HELPERS FOR TESTS
    // ============================================================

    function _setAssetPrice(address asset, uint256 priceX8) internal {
        bytes32 priceId = assetPriceIds[asset];
        mockPyth.setPrice(priceId, SafeCast.toInt64(int256(priceX8)), -8, block.timestamp);
    }

    function _buildPriceUpdate(address asset, uint256 priceX8) internal returns (bytes[] memory) {
        _setAssetPrice(asset, priceX8);
        bytes[] memory payload = new bytes[](1);
        payload[0] = abi.encode(assetPriceIds[asset], priceX8);
        return payload;
    }

    function _sizeForNotional(uint256 notionalUsdX8, uint256 priceX8) internal pure returns (uint256) {
        // Convert USD notional (8 decimals) into synthetic units (18 decimals)
        return Math.mulDiv(notionalUsdX8, 1e18, priceX8);
    }
}
