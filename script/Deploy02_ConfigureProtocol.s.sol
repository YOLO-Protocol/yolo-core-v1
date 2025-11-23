// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {IYoloHook} from "@yolo/core-v1/interfaces/IYoloHook.sol";
import {IYoloOracle} from "@yolo/core-v1/interfaces/IYoloOracle.sol";
import {ACLManager} from "@yolo/core-v1/access/ACLManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@yolo/core-v1/mocks/MockERC20.sol";

/**
 * @title Deploy02_ConfigureProtocol
 * @author alvin@yolo.wtf
 * @notice Configuration script for YOLO Protocol V1 after core deployment
 * @dev This script configures oracles, creates synthetic assets, whitelists collaterals,
 *      sets up lending pairs, and bootstraps initial liquidity
 *
 * Prerequisites:
 *   - Deploy01_FullProtocol must be completed (YoloHook, YoloOracle, ACL deployed)
 *   - DeployTask_DeployMockAssetsAndOracles must be completed (collateral assets deployed)
 *
 * Usage:
 *   forge script script/Deploy02_ConfigureProtocol.s.sol:Deploy02_ConfigureProtocol \
 *     --rpc-url $RPC_URL --broadcast -vvv
 *
 * Output:
 *   - deployments/ConfiguredProtocol_{chainId}.json (configuration summary)
 */
contract Deploy02_ConfigureProtocol is Script {
    // ========================
    // CONFIGURATION - DEPLOYED ADDRESSES
    // ========================

    // From Deploy01_FullProtocol.s.sol deployment
    address constant YOLO_HOOK_PROXY = 0x033ea50dEaa8b064958fC40E34F994C154D27FFf; // FILL IN: YoloHook proxy address
    address constant YOLO_ORACLE = 0x3ae085e154dB66bAC6721E062Ce30625b6F78D92; // FILL IN: YoloOracle address
    address constant ACL_MANAGER = 0x778A78699a6F03Bb9b6123580A32A5800E53FF1A; // FILL IN: ACLManager address
    address constant SYNTHETIC_ASSET_IMPL = 0x8f1263d705D3EB4A05c32e2247Fb179e9DfC6A4c; // FILL IN: YoloSyntheticAsset implementation

    // From DeployTask_DeployMockUSDC.s.sol
    address constant USDC = 0xF32B34Dfc110BF618a0Ff148afBAd8C3915c45aB; // FILL IN: USDC address

    // USY address (retrieve from YoloHook)
    address public usy;
    address public ylpVault;

    // ========================
    // CONFIGURATION - COLLATERAL ASSETS & ORACLES
    // ========================

    struct CollateralConfig {
        string symbol;
        address assetAddress;
        address oracleAddress;
    }

    // Storage for dynamic configuration
    CollateralConfig[] private collateralConfigs;

    // CONFIGURE: Add your collateral assets and their oracles here
    // Configured for Base Sepolia testnet (Chain ID: 84532)
    function _getCollateralConfigs() internal returns (CollateralConfig[] memory) {
        // Asset 1: WETH - Wrapped Ether
        collateralConfigs.push(
            CollateralConfig({
                symbol: "WETH",
                assetAddress: 0x119000192D6C783d355aC50320670F8140D051d0,
                oracleAddress: 0xE3d179F77A6c514C374A8De1B3AabB1CCC8E3140
            })
        );

        // Asset 2: WBTC - Wrapped Bitcoin
        collateralConfigs.push(
            CollateralConfig({
                symbol: "WBTC",
                assetAddress: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                oracleAddress: 0x2f09E672459cCF2B20A4C621aFA756CC0b9D3B8D
            })
        );

        // Asset 3: SOL - Solana
        collateralConfigs.push(
            CollateralConfig({
                symbol: "SOL",
                assetAddress: 0xDf4c4332937528E955B79E2117bc51A1E99BaA8C,
                oracleAddress: 0x41De0a331EA729F23F1c428F88e4c1Ac2d313De4
            })
        );

        // Asset 4: sUSDe - Staked USDe (Ethena)
        collateralConfigs.push(
            CollateralConfig({
                symbol: "sUSDe",
                assetAddress: 0x9aFE68A4A330e8eA3ebB997Fe4B27aa802b7F076,
                oracleAddress: 0x1C58fE2eE4531461d2FEead1bF1511Ed0cAaC662
            })
        );

        return collateralConfigs;
    }

    // ========================
    // CONFIGURATION - SYNTHETIC ASSETS
    // ========================

    struct SyntheticConfig {
        string name;
        string symbol;
        uint8 decimals;
        address oracleAddress;
        uint256 mintCap; // 0 = unlimited
        uint256 flashLoanCap; // type(uint256).max = unlimited
    }

    // Storage for dynamic configuration
    SyntheticConfig[] private syntheticConfigs;

    // CONFIGURE: Add your synthetic assets here
    function _getSyntheticConfigs() internal returns (SyntheticConfig[] memory) {
        // ========================
        // SYNTHETIC CRYPTOS (Blue Chip)
        // ========================

        // yBTC - Bitcoin (10M cap - most liquid crypto)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Bitcoin",
                symbol: "yBTC",
                decimals: 18,
                oracleAddress: 0x2f09E672459cCF2B20A4C621aFA756CC0b9D3B8D,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yETH - Ethereum (10M cap - most liquid crypto)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Ethereum",
                symbol: "yETH",
                decimals: 18,
                oracleAddress: 0xE3d179F77A6c514C374A8De1B3AabB1CCC8E3140,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // ySOL - Solana (5M cap - top L1 alt)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Solana",
                symbol: "ySOL",
                decimals: 18,
                oracleAddress: 0x41De0a331EA729F23F1c428F88e4c1Ac2d313De4,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC TECH STOCKS (Mega Cap)
        // ========================

        // yAAPL - Apple (10M cap - largest market cap)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Apple",
                symbol: "yAAPL",
                decimals: 18,
                oracleAddress: 0x037A2C629Bbb421c1E3229b64749e5319e39d29e,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yGOOGL - Google (10M cap - mega cap tech)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Google",
                symbol: "yGOOGL",
                decimals: 18,
                oracleAddress: 0xe44242B70Fa76ddE2aCf63685a3f10079772f643,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yNVDA - Nvidia (10M cap - AI leader)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Nvidia",
                symbol: "yNVDA",
                decimals: 18,
                oracleAddress: 0xd604AAC32CcF7a0cFB65e3b2B5014b9DC9a43E9E,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yMETA - Meta (10M cap - social media giant)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Meta",
                symbol: "yMETA",
                decimals: 18,
                oracleAddress: 0xB105dcBD614bBF3d0B30D55CCA5600dC3a3e8683,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yMSFT - Microsoft (10M cap - mega cap tech)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Microsoft",
                symbol: "yMSFT",
                decimals: 18,
                oracleAddress: 0x2104df60FacEd7f3A0fcF4550f01D0b08e1f9DF8,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yAMZN - Amazon (10M cap - e-commerce leader)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Amazon",
                symbol: "yAMZN",
                decimals: 18,
                oracleAddress: 0x77E6E6d57bfbB789E5A5119AcB5AB9378AAa0B58,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yTSLA - Tesla (5M cap - volatile but popular)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Tesla",
                symbol: "yTSLA",
                decimals: 18,
                oracleAddress: 0xc3EC36F93657AD8039191259F4768F2FD937f64d,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC TECH STOCKS (Mid-Large Cap)
        // ========================

        // yAMD - AMD (5M cap - semiconductor)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic AMD",
                symbol: "yAMD",
                decimals: 18,
                oracleAddress: 0x71BC651205C68ed5DFBF1DCe35361C32dddCFF88,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // yNFLX - Netflix (5M cap - streaming leader)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Netflix",
                symbol: "yNFLX",
                decimals: 18,
                oracleAddress: 0x43290B6Fb1A8cDc09FDaCB8F7c9F68886ECfaf11,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // yINTC - Intel (2M cap - legacy semiconductor)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Intel",
                symbol: "yINTC",
                decimals: 18,
                oracleAddress: 0x537DA8502940B8f1Ef734d04f85b8D4Dc0434C5f,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // yPLTR - Palantir (2M cap - data analytics)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Palantir",
                symbol: "yPLTR",
                decimals: 18,
                oracleAddress: 0x04bFA450C7e4CE6a12cC59Afbd58C5A2251D514D,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC CRYPTO/FINTECH STOCKS
        // ========================

        // yCOIN - Coinbase (2M cap - crypto exchange)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Coinbase",
                symbol: "yCOIN",
                decimals: 18,
                oracleAddress: 0x2e5662a3aAD5cD595A1FCc10bD5DAF40198f70F7,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // yHOOD - Robinhood (1M cap - retail trading)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Robinhood",
                symbol: "yHOOD",
                decimals: 18,
                oracleAddress: 0x51208ae242f03B3134F505e33B7f725BCB7F7966,
                mintCap: 1_000_000 * 1e18,
                flashLoanCap: 1_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC FINANCIAL STOCKS
        // ========================

        // yJPM - JPMorgan Chase (5M cap - largest US bank)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic JPMorgan",
                symbol: "yJPM",
                decimals: 18,
                oracleAddress: 0x4A19f360aA922704B785ca0719bb540456DAb4E7,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // yBAC - Bank of America (2M cap - major bank)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Bank of America",
                symbol: "yBAC",
                decimals: 18,
                oracleAddress: 0x76Bb06BFCB5FdB7197bD6c9785b4ccA11CF0bF8C,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // yGS - Goldman Sachs (2M cap - investment bank)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Goldman Sachs",
                symbol: "yGS",
                decimals: 18,
                oracleAddress: 0x522Ed762874cF498F651bC254B2d95568a0553B3,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // yV - Visa (5M cap - payment network)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Visa",
                symbol: "yV",
                decimals: 18,
                oracleAddress: 0xF2dc034fbceCaA18424B0345E4f7Ce41E4Cda8fF,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC CONSUMER STOCKS
        // ========================

        // yDIS - Disney (2M cap - entertainment)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Disney",
                symbol: "yDIS",
                decimals: 18,
                oracleAddress: 0xE0846158b10DBd1Dcf5c9f61b0Da3b375eCb2E21,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC INDUSTRIAL STOCKS
        // ========================

        // yBA - Boeing (2M cap - aerospace)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Boeing",
                symbol: "yBA",
                decimals: 18,
                oracleAddress: 0x11b422db5E687217DcFDFF03eF5B5Ba6cDd94ded,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC INTERNATIONAL STOCKS
        // ========================

        // yBABA - Alibaba (2M cap - China e-commerce)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Alibaba",
                symbol: "yBABA",
                decimals: 18,
                oracleAddress: 0x8e0F9257CeBA1E2d9caf70a4Ca6E0A898A977F0f,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC ETFs (Most Liquid)
        // ========================

        // ySPY - S&P 500 ETF (10M cap - most liquid ETF)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic SPY",
                symbol: "ySPY",
                decimals: 18,
                oracleAddress: 0x5A5B99FFAFe7A0b6209A06CB4eE998E6aE3507A0,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yQQQ - Nasdaq 100 ETF (10M cap - tech ETF)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic QQQ",
                symbol: "yQQQ",
                decimals: 18,
                oracleAddress: 0x9cc48DBb04EDBb48B0196874E605b698fCB50f9B,
                mintCap: 10_000_000 * 1e18,
                flashLoanCap: 10_000_000 * 1e18
            })
        );

        // yDIA - Dow Jones ETF (5M cap)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic DIA",
                symbol: "yDIA",
                decimals: 18,
                oracleAddress: 0x4AB167bFf65CFa03958dc9633353c414F4460a05,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // yIWM - Russell 2000 ETF (2M cap - small cap)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic IWM",
                symbol: "yIWM",
                decimals: 18,
                oracleAddress: 0x3b19Ef929Af16e55b551a4A379884c373cE53A12,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // yUVXY - VIX ETF (500K cap - volatility product, risky)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic UVXY",
                symbol: "yUVXY",
                decimals: 18,
                oracleAddress: 0xb92Fe8Bbc66997228fF2B8d70EF5C07f529ab973,
                mintCap: 500_000 * 1e18,
                flashLoanCap: 500_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC FOREX
        // ========================

        // yEUR - Euro (5M cap - most liquid forex pair)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Euro",
                symbol: "yEUR",
                decimals: 18,
                oracleAddress: 0x4289027b3885EFdF8603A0e8867D78b8CDAE0838,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC COMMODITIES (Energy)
        // ========================

        // yBRENT - Brent Crude Oil (2M cap)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Brent Crude",
                symbol: "yBRENT",
                decimals: 18,
                oracleAddress: 0x5cb83399FbD90cdD4A3673aD1617A02E1F11Dd5F,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // yWTI - WTI Crude Oil (2M cap)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic WTI Crude",
                symbol: "yWTI",
                decimals: 18,
                oracleAddress: 0xDBFdF3C8BDc6011D411134Da30504d40A7426fE9,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // ========================
        // SYNTHETIC PRECIOUS METALS
        // ========================

        // yXAU - Gold (5M cap - safe haven)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Gold",
                symbol: "yXAU",
                decimals: 18,
                oracleAddress: 0xC45052955cb49f66eB55502B9f1A82fc1e9C9d5C,
                mintCap: 5_000_000 * 1e18,
                flashLoanCap: 5_000_000 * 1e18
            })
        );

        // yXAG - Silver (2M cap)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Silver",
                symbol: "yXAG",
                decimals: 18,
                oracleAddress: 0x5121ac7B01DF7A997BD272b3D57C6a14f9f54070,
                mintCap: 2_000_000 * 1e18,
                flashLoanCap: 2_000_000 * 1e18
            })
        );

        // yXPT - Platinum (1M cap)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Platinum",
                symbol: "yXPT",
                decimals: 18,
                oracleAddress: 0x2EB33bD83Ece44C42337D04cC1271d67317a67cC,
                mintCap: 1_000_000 * 1e18,
                flashLoanCap: 1_000_000 * 1e18
            })
        );

        // yXPD - Palladium (500K cap - less liquid)
        syntheticConfigs.push(
            SyntheticConfig({
                name: "Yolo Synthetic Palladium",
                symbol: "yXPD",
                decimals: 18,
                oracleAddress: 0x1D6115BA17A4EEd3fAb981dA8511e70C703A6Dd4,
                mintCap: 500_000 * 1e18,
                flashLoanCap: 500_000 * 1e18
            })
        );

        return syntheticConfigs;
    }

    // ========================
    // CONFIGURATION - LENDING PAIRS
    // ========================

    struct LendingPairConfig {
        string syntheticSymbol; // For display only
        address syntheticAsset;
        string collateralSymbol; // For display only
        address collateralAsset;
        uint256 ltv; // Loan-to-value in bps (7500 = 75%)
        uint256 liquidationThreshold; // In bps (8000 = 80%)
        uint256 liquidationBonus; // In bps (500 = 5%)
        uint256 liquidationPenalty; // In bps (500 = 5%)
        uint256 borrowRate; // In bps (300 = 3%)
        uint256 mintCap; // type(uint256).max = unlimited
        uint256 supplyCap; // type(uint256).max = unlimited
        uint256 minBorrow; // Minimum borrow amount (e.g., 1e18 = 1 unit)
    }

    // Storage for dynamic configuration
    LendingPairConfig[] private lendingPairConfigs;

    // CONFIGURE: Add your lending pairs here
    // NOTE: syntheticAsset addresses will be filled after synthetic creation
    // For now, use address(0) and we'll populate them dynamically
    //
    // RISK FRAMEWORK:
    // - WETH/WBTC: Support ALL assets (blue chip, highest liquidity)
    // - SOL: Support USY + select blue chips (medium risk)
    // - sUSDe: Support USY + safe havens only (conservative)
    //
    // RATE STRUCTURE:
    // - USY: 8-10% (based on collateral risk)
    // - Stocks/Commodities/Metals: 3-6% (based on volatility)
    // - Forex: ~5%
    //
    // CAP STRATEGY:
    // - Single collateral can mint max 40% of asset's total cap
    // - USY: Unlimited
    function _getLendingPairConfigs() internal returns (LendingPairConfig[] memory) {
        // ========================================
        // WETH COLLATERAL (15 pairs)
        // ========================================

        // WETH -> USY (9% rate, 75% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "USY",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 7500,
                liquidationThreshold: 8000,
                liquidationBonus: 500,
                liquidationPenalty: 500,
                borrowRate: 900,
                mintCap: type(uint256).max,
                supplyCap: type(uint256).max,
                minBorrow: 100e18
            })
        );

        // WETH -> yETH (3%, 90% LTV - same asset)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yETH",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 9000,
                liquidationThreshold: 9500,
                liquidationBonus: 300,
                liquidationPenalty: 300,
                borrowRate: 300,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // WETH -> yBTC (3%, 70% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yBTC",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 7000,
                liquidationThreshold: 7500,
                liquidationBonus: 500,
                liquidationPenalty: 500,
                borrowRate: 300,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 0.01e18
            })
        );

        // WETH -> ySOL (4%, 65% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "ySOL",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 2_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // WETH -> yAAPL (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yAAPL",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> yGOOGL (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yGOOGL",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> yNVDA (5%, 55% LTV - volatile)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yNVDA",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 5500,
                liquidationThreshold: 6000,
                liquidationBonus: 800,
                liquidationPenalty: 800,
                borrowRate: 500,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> yMETA (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yMETA",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> yMSFT (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yMSFT",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> yAMZN (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yAMZN",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> yTSLA (6%, 50% LTV - very volatile)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yTSLA",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 5000,
                liquidationThreshold: 5500,
                liquidationBonus: 1000,
                liquidationPenalty: 1000,
                borrowRate: 600,
                mintCap: 2_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> ySPY (3%, 65% LTV - stable ETF)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "ySPY",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 600,
                liquidationPenalty: 600,
                borrowRate: 300,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> yQQQ (4%, 65% LTV - tech ETF)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yQQQ",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 600,
                liquidationPenalty: 600,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WETH -> yEUR (5%, 60% LTV - forex)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yEUR",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 500,
                mintCap: 2_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 100e18
            })
        );

        // WETH -> yXAU (4%, 65% LTV - gold)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yXAU",
                syntheticAsset: address(0),
                collateralSymbol: "WETH",
                collateralAsset: 0x119000192D6C783d355aC50320670F8140D051d0,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 600,
                liquidationPenalty: 600,
                borrowRate: 400,
                mintCap: 2_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // ========================================
        // WBTC COLLATERAL (12 pairs)
        // ========================================

        // WBTC -> USY (9% rate)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "USY",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 7500,
                liquidationThreshold: 8000,
                liquidationBonus: 500,
                liquidationPenalty: 500,
                borrowRate: 900,
                mintCap: type(uint256).max,
                supplyCap: type(uint256).max,
                minBorrow: 100e18
            })
        );

        // WBTC -> yBTC (3%, 90% LTV - same asset)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yBTC",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 9000,
                liquidationThreshold: 9500,
                liquidationBonus: 300,
                liquidationPenalty: 300,
                borrowRate: 300,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 0.01e18
            })
        );

        // WBTC -> yETH (3%, 70% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yETH",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 7000,
                liquidationThreshold: 7500,
                liquidationBonus: 500,
                liquidationPenalty: 500,
                borrowRate: 300,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // WBTC -> ySOL (4%, 65% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "ySOL",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 2_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // WBTC -> yAAPL (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yAAPL",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WBTC -> yGOOGL (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yGOOGL",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WBTC -> yNVDA (5%, 55% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yNVDA",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 5500,
                liquidationThreshold: 6000,
                liquidationBonus: 800,
                liquidationPenalty: 800,
                borrowRate: 500,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WBTC -> yMSFT (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yMSFT",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WBTC -> ySPY (3%, 65% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "ySPY",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 600,
                liquidationPenalty: 600,
                borrowRate: 300,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WBTC -> yQQQ (4%, 65% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yQQQ",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 600,
                liquidationPenalty: 600,
                borrowRate: 400,
                mintCap: 4_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // WBTC -> yEUR (5%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yEUR",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 500,
                mintCap: 2_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 100e18
            })
        );

        // WBTC -> yXAU (4%, 65% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yXAU",
                syntheticAsset: address(0),
                collateralSymbol: "WBTC",
                collateralAsset: 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 600,
                liquidationPenalty: 600,
                borrowRate: 400,
                mintCap: 2_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // ========================================
        // SOL COLLATERAL (6 pairs - selective)
        // ========================================

        // SOL -> USY (10% rate, 65% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "USY",
                syntheticAsset: address(0),
                collateralSymbol: "SOL",
                collateralAsset: 0xDf4c4332937528E955B79E2117bc51A1E99BaA8C,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 700,
                liquidationPenalty: 700,
                borrowRate: 1000,
                mintCap: type(uint256).max,
                supplyCap: type(uint256).max,
                minBorrow: 100e18
            })
        );

        // SOL -> ySOL (4%, 85% LTV - same asset)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "ySOL",
                syntheticAsset: address(0),
                collateralSymbol: "SOL",
                collateralAsset: 0xDf4c4332937528E955B79E2117bc51A1E99BaA8C,
                ltv: 8500,
                liquidationThreshold: 9000,
                liquidationBonus: 400,
                liquidationPenalty: 400,
                borrowRate: 400,
                mintCap: 2_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // SOL -> yBTC (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yBTC",
                syntheticAsset: address(0),
                collateralSymbol: "SOL",
                collateralAsset: 0xDf4c4332937528E955B79E2117bc51A1E99BaA8C,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 800,
                liquidationPenalty: 800,
                borrowRate: 400,
                mintCap: 1_500_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 0.01e18
            })
        );

        // SOL -> yETH (4%, 60% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yETH",
                syntheticAsset: address(0),
                collateralSymbol: "SOL",
                collateralAsset: 0xDf4c4332937528E955B79E2117bc51A1E99BaA8C,
                ltv: 6000,
                liquidationThreshold: 6500,
                liquidationBonus: 800,
                liquidationPenalty: 800,
                borrowRate: 400,
                mintCap: 1_500_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // SOL -> ySPY (4%, 55% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "ySPY",
                syntheticAsset: address(0),
                collateralSymbol: "SOL",
                collateralAsset: 0xDf4c4332937528E955B79E2117bc51A1E99BaA8C,
                ltv: 5500,
                liquidationThreshold: 6000,
                liquidationBonus: 800,
                liquidationPenalty: 800,
                borrowRate: 400,
                mintCap: 1_500_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // SOL -> yQQQ (5%, 55% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yQQQ",
                syntheticAsset: address(0),
                collateralSymbol: "SOL",
                collateralAsset: 0xDf4c4332937528E955B79E2117bc51A1E99BaA8C,
                ltv: 5500,
                liquidationThreshold: 6000,
                liquidationBonus: 800,
                liquidationPenalty: 800,
                borrowRate: 500,
                mintCap: 1_500_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        // ========================================
        // sUSDe COLLATERAL (4 pairs - conservative)
        // ========================================

        // sUSDe -> USY (8%, 80% LTV - both USD)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "USY",
                syntheticAsset: address(0),
                collateralSymbol: "sUSDe",
                collateralAsset: 0x9aFE68A4A330e8eA3ebB997Fe4B27aa802b7F076,
                ltv: 8000,
                liquidationThreshold: 8500,
                liquidationBonus: 400,
                liquidationPenalty: 400,
                borrowRate: 800,
                mintCap: type(uint256).max,
                supplyCap: type(uint256).max,
                minBorrow: 100e18
            })
        );

        // sUSDe -> yEUR (5%, 70% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yEUR",
                syntheticAsset: address(0),
                collateralSymbol: "sUSDe",
                collateralAsset: 0x9aFE68A4A330e8eA3ebB997Fe4B27aa802b7F076,
                ltv: 7000,
                liquidationThreshold: 7500,
                liquidationBonus: 500,
                liquidationPenalty: 500,
                borrowRate: 500,
                mintCap: 1_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 100e18
            })
        );

        // sUSDe -> yXAU (4%, 70% LTV - safe haven)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "yXAU",
                syntheticAsset: address(0),
                collateralSymbol: "sUSDe",
                collateralAsset: 0x9aFE68A4A330e8eA3ebB997Fe4B27aa802b7F076,
                ltv: 7000,
                liquidationThreshold: 7500,
                liquidationBonus: 500,
                liquidationPenalty: 500,
                borrowRate: 400,
                mintCap: 1_000_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 1e18
            })
        );

        // sUSDe -> ySPY (3%, 65% LTV)
        lendingPairConfigs.push(
            LendingPairConfig({
                syntheticSymbol: "ySPY",
                syntheticAsset: address(0),
                collateralSymbol: "sUSDe",
                collateralAsset: 0x9aFE68A4A330e8eA3ebB997Fe4B27aa802b7F076,
                ltv: 6500,
                liquidationThreshold: 7000,
                liquidationBonus: 600,
                liquidationPenalty: 600,
                borrowRate: 300,
                mintCap: 1_500_000e18,
                supplyCap: type(uint256).max,
                minBorrow: 10e18
            })
        );

        return lendingPairConfigs;
    }

    // ========================
    // CONFIGURATION - INITIAL LIQUIDITY
    // ========================

    uint256 constant YLP_VAULT_FUNDING = 10_000_000e18; // 10M USY for YLP vault
    uint256 constant INITIAL_USY_LIQUIDITY = 2_000_000e18; // 1M USY for anchor pool
    uint256 constant INITIAL_USDC_LIQUIDITY = 2_000_000e6; // 1M USDC for anchor pool

    // ========================
    // STATE TRACKING
    // ========================

    IYoloHook public yoloHook;
    IYoloOracle public yoloOracle;
    ACLManager public aclManager;

    mapping(string => address) public deployedSynthetics; // symbol => address

    // ========================
    // MAIN DEPLOYMENT
    // ========================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("============================================================");
        console2.log("YOLO Protocol V1 - Configuration & Setup");
        console2.log("============================================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        // Validate prerequisites
        require(YOLO_HOOK_PROXY != address(0), "YOLO_HOOK_PROXY not configured");
        require(YOLO_ORACLE != address(0), "YOLO_ORACLE not configured");
        require(ACL_MANAGER != address(0), "ACL_MANAGER not configured");
        require(USDC != address(0), "USDC not configured");

        // Initialize contracts
        yoloHook = IYoloHook(YOLO_HOOK_PROXY);
        yoloOracle = IYoloOracle(YOLO_ORACLE);
        aclManager = ACLManager(ACL_MANAGER);

        // Get USY and YLP vault addresses
        usy = yoloHook.usy();
        ylpVault = yoloHook.ylpVault();

        // FIX: Register USY so lending pair configuration works
        deployedSynthetics["USY"] = usy;

        console2.log("YoloHook:", YOLO_HOOK_PROXY);
        console2.log("YoloOracle:", YOLO_ORACLE);
        console2.log("ACLManager:", ACL_MANAGER);
        console2.log("USY:", usy);
        console2.log("YLP Vault:", ylpVault);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        // STEP 0: Setup ACL Roles (MUST BE FIRST)
        _setupACLRoles(deployer);

        // STEP 1: Register Collateral Oracles
        _registerCollateralOracles();

        // STEP 2: Create Synthetic Assets
        _createSyntheticAssets();

        // STEP 3: Whitelist Collaterals
        _whitelistCollaterals();

        // STEP 4: Configure Lending Pairs
        _configureLendingPairs();

        // STEP 4.5: Prepare Deployer Funds (mint USDC and USY) in testnet
        _prepareDeployerFunds(deployer);

        // STEP 5: Fund YLP Vault
        _fundYLPVault();

        // STEP 6: Bootstrap sUSY Liquidity
        _bootstrapSUSYLiquidity();

        vm.stopBroadcast();

        // Save configuration summary
        _saveConfiguration();

        console2.log("");
        console2.log("============================================================");
        console2.log("Configuration Complete!");
        console2.log("============================================================");
    }

    // ========================
    // STEP 0: ACL ROLES SETUP
    // ========================

    function _setupACLRoles(address deployer) internal {
        console2.log("[Step 0] Setting up ACL Roles...");

        // Create required roles
        bytes32 oracleAdminRole = aclManager.createRole("ORACLE_ADMIN", bytes32(0));
        bytes32 assetsAdminRole = aclManager.createRole("ASSETS_ADMIN", bytes32(0));
        bytes32 riskAdminRole = aclManager.createRole("RISK_ADMIN", bytes32(0));

        console2.log("  Created roles:");
        console2.log("    ORACLE_ADMIN:", vm.toString(oracleAdminRole));
        console2.log("    ASSETS_ADMIN:", vm.toString(assetsAdminRole));
        console2.log("    RISK_ADMIN:", vm.toString(riskAdminRole));

        // Grant all roles to deployer
        aclManager.grantRole(oracleAdminRole, deployer);
        aclManager.grantRole(assetsAdminRole, deployer);
        aclManager.grantRole(riskAdminRole, deployer);

        console2.log("  Granted all roles to deployer:", deployer);

        // CRITICAL: Grant ORACLE_ADMIN to YoloHook so it can register synthetic asset oracles
        aclManager.grantRole(oracleAdminRole, YOLO_HOOK_PROXY);
        console2.log("  Granted ORACLE_ADMIN to YoloHook:", YOLO_HOOK_PROXY);

        console2.log("  [Step 0] Complete!");
        console2.log("");
    }

    // ========================
    // STEP 1: REGISTER COLLATERAL ORACLES
    // ========================

    function _registerCollateralOracles() internal {
        console2.log("[Step 1] Registering Collateral Oracles...");

        CollateralConfig[] memory configs = _getCollateralConfigs();

        // Register USDC oracle first
        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = USDC;
        sources[0] = 0x0000000000000000000000000000000000000000; // FILL IN: USDC oracle address

        if (sources[0] != address(0)) {
            yoloOracle.setAssetSources(assets, sources);
            console2.log("  Registered USDC oracle");
        }

        // Register USY oracle
        assets[0] = usy;
        sources[0] = 0x0000000000000000000000000000000000000000; // FILL IN: USY oracle address (usually $1.00)

        if (sources[0] != address(0)) {
            yoloOracle.setAssetSources(assets, sources);
            console2.log("  Registered USY oracle");
        }

        // Register collateral oracles
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].assetAddress == address(0) || configs[i].oracleAddress == address(0)) {
                console2.log("  Skipping", configs[i].symbol, "(not configured)");
                continue;
            }

            assets[0] = configs[i].assetAddress;
            sources[0] = configs[i].oracleAddress;

            yoloOracle.setAssetSources(assets, sources);
            console2.log("  Registered", configs[i].symbol, "oracle");
        }

        console2.log("  [Step 1] Complete!");
        console2.log("");
    }

    // ========================
    // STEP 2: CREATE SYNTHETIC ASSETS
    // ========================

    function _createSyntheticAssets() internal {
        console2.log("[Step 2] Creating Synthetic Assets...");

        SyntheticConfig[] memory configs = _getSyntheticConfigs();

        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].oracleAddress == address(0)) {
                console2.log("  Skipping", configs[i].symbol, "(oracle not configured)");
                continue;
            }

            address syntheticAddress = yoloHook.createSyntheticAsset(
                configs[i].name,
                configs[i].symbol,
                configs[i].decimals,
                configs[i].oracleAddress,
                SYNTHETIC_ASSET_IMPL,
                configs[i].mintCap,
                configs[i].flashLoanCap
            );

            deployedSynthetics[configs[i].symbol] = syntheticAddress;

            console2.log("  Created", configs[i].symbol, "at:", syntheticAddress);
        }

        console2.log("  [Step 2] Complete!");
        console2.log("");
    }

    // ========================
    // STEP 3: WHITELIST COLLATERALS
    // ========================

    function _whitelistCollaterals() internal {
        console2.log("[Step 3] Whitelisting Collaterals...");

        // Whitelist USDC
        yoloHook.whitelistCollateral(USDC);
        console2.log("  Whitelisted USDC");

        // Whitelist other collaterals
        CollateralConfig[] memory configs = _getCollateralConfigs();

        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].assetAddress == address(0)) {
                console2.log("  Skipping", configs[i].symbol, "(not configured)");
                continue;
            }

            yoloHook.whitelistCollateral(configs[i].assetAddress);
            console2.log("  Whitelisted", configs[i].symbol);
        }

        console2.log("  [Step 3] Complete!");
        console2.log("");
    }

    // ========================
    // STEP 4: CONFIGURE LENDING PAIRS
    // ========================

    function _configureLendingPairs() internal {
        console2.log("[Step 4] Configuring Lending Pairs...");

        LendingPairConfig[] memory configs = _getLendingPairConfigs();

        for (uint256 i = 0; i < configs.length; i++) {
            // Get synthetic address from deployed mapping
            address syntheticAddress = deployedSynthetics[configs[i].syntheticSymbol];

            if (syntheticAddress == address(0)) {
                console2.log("  Skipping (synthetic not deployed):", configs[i].syntheticSymbol);
                continue;
            }

            if (configs[i].collateralAsset == address(0)) {
                console2.log("  Skipping (collateral not configured):", configs[i].syntheticSymbol);
                continue;
            }

            yoloHook.configureLendingPair(
                syntheticAddress,
                configs[i].collateralAsset,
                address(0), // no deposit token
                address(0), // no debt token
                configs[i].ltv,
                configs[i].liquidationThreshold,
                configs[i].liquidationBonus,
                configs[i].liquidationPenalty,
                configs[i].borrowRate,
                configs[i].mintCap,
                configs[i].supplyCap,
                configs[i].minBorrow,
                false, // not expirable
                0 // no expiry
            );

            console2.log("  Configured", configs[i].syntheticSymbol, "/", configs[i].collateralSymbol);
            console2.log("    LTV:", configs[i].ltv, "bps");
        }

        console2.log("  [Step 4] Complete!");
        console2.log("");
    }

    // ========================
    // STEP 4.5: PREPARE DEPLOYER FUNDS
    // ========================

    function _prepareDeployerFunds(address deployer) internal {
        console2.log("[Step 4.5] Preparing Deployer Funds...");

        // Total needed: 10M USY for YLP + 2M USY for sUSY = 12M USY
        // Also need: 2M USDC for sUSY
        uint256 totalUSYNeeded = YLP_VAULT_FUNDING + INITIAL_USY_LIQUIDITY; // 12M USY

        // 1. Mint USDC to deployer for sUSY bootstrap
        console2.log("  Minting USDC to deployer...");
        MockERC20(USDC).mint(deployer, INITIAL_USDC_LIQUIDITY);
        console2.log("    Minted", INITIAL_USDC_LIQUIDITY / 1e6, "USDC to deployer");

        // 2. Mint WBTC to deployer to borrow USY
        // Need enough WBTC to borrow 12M USY at safe LTV
        // WBTC->USY pair: 75% LTV, so need collateral = 12M / 0.75 = 16M USY value
        // Assuming WBTC price ~84k and USY ~$1, need ~$16M / $84k = ~190 WBTC
        // Add 50% safety margin: 285 WBTC (with 8 decimals)
        address WBTC_ADDRESS = 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8;
        uint256 WBTC_AMOUNT = 285e8; // 285 WBTC

        console2.log("  Minting WBTC to deployer...");
        MockERC20(WBTC_ADDRESS).mint(deployer, WBTC_AMOUNT);
        console2.log("    Minted", WBTC_AMOUNT / 1e8, "WBTC to deployer");

        // 3. Approve WBTC for YoloHook
        console2.log("  Approving WBTC for YoloHook...");
        IERC20(WBTC_ADDRESS).approve(address(yoloHook), type(uint256).max);

        // 4. Borrow USY using WBTC as collateral
        console2.log("  Borrowing USY against WBTC collateral...");
        yoloHook.borrow(
            usy, // yoloAsset (USY)
            totalUSYNeeded, // borrowAmount (12M USY)
            WBTC_ADDRESS, // collateral
            WBTC_AMOUNT, // collateralAmount (285 WBTC)
            deployer // onBehalfOf
        );

        uint256 usyBalance = IERC20(usy).balanceOf(deployer);
        console2.log("    Borrowed", usyBalance / 1e18, "USY");
        console2.log("    WBTC collateral deposited:", WBTC_AMOUNT / 1e8, "WBTC");

        console2.log("  [Step 4.5] Complete!");
        console2.log("");
    }

    // ========================
    // STEP 5: FUND YLP VAULT
    // ========================

    function _fundYLPVault() internal {
        console2.log("[Step 5] Funding YLP Vault...");

        // Transfer USY from deployer to YLP vault
        bool success = IERC20(usy).transfer(ylpVault, YLP_VAULT_FUNDING);
        require(success, "USY transfer to YLP vault failed");

        console2.log("  Transferred", YLP_VAULT_FUNDING / 1e18, "USY to YLP vault");
        console2.log("  YLP Vault balance:", IERC20(usy).balanceOf(ylpVault) / 1e18, "USY");

        console2.log("  [Step 5] Complete!");
        console2.log("");
    }

    // ========================
    // STEP 6: BOOTSTRAP sUSY LIQUIDITY
    // ========================

    function _bootstrapSUSYLiquidity() internal {
        console2.log("[Step 6] Bootstrapping sUSY Liquidity...");

        // Deployer already has USDC and USY from Step 4.5
        address deployer = msg.sender;

        console2.log("  Approving tokens for YoloHook...");
        IERC20(USDC).approve(address(yoloHook), type(uint256).max);
        IERC20(usy).approve(address(yoloHook), type(uint256).max);

        uint256 usyBalanceBefore = IERC20(usy).balanceOf(deployer);
        uint256 usdcBalanceBefore = IERC20(USDC).balanceOf(deployer);
        console2.log("    Deployer USY balance:", usyBalanceBefore / 1e18);
        console2.log("    Deployer USDC balance:", usdcBalanceBefore / 1e6);

        // Add liquidity to anchor pool
        console2.log("  Adding liquidity to anchor pool...");
        yoloHook.addLiquidity(
            INITIAL_USY_LIQUIDITY, // 2M USY
            INITIAL_USDC_LIQUIDITY, // 2M USDC
            0, // min sUSY
            deployer // receiver
        );

        uint256 sUSYBalance = IERC20(yoloHook.sUSY()).balanceOf(deployer);
        console2.log("  Received sUSY LP tokens:", sUSYBalance / 1e18);

        (uint256 reserveUSY, uint256 reserveUSDC) = yoloHook.getAnchorReserves();
        console2.log("  Anchor Pool Reserves:");
        console2.log("    USY:", reserveUSY / 1e18);
        console2.log("    USDC:", reserveUSDC / 1e6);

        console2.log("  [Step 6] Complete!");
        console2.log("");
    }

    // ========================
    // HELPER FUNCTIONS
    // ========================

    function _saveConfiguration() internal {
        string memory json = "configuration";

        // Write metadata
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeAddress(json, "yoloHook", YOLO_HOOK_PROXY);
        vm.serializeAddress(json, "yoloOracle", YOLO_ORACLE);

        // Get synthetic configs
        SyntheticConfig[] memory synthetics = _getSyntheticConfigs();

        // Write each synthetic asset deployment with full details
        for (uint256 i = 0; i < synthetics.length; i++) {
            address syntheticAddr = deployedSynthetics[synthetics[i].symbol];
            if (syntheticAddr == address(0)) continue; // Skip if not deployed

            string memory assetKey = synthetics[i].symbol;
            string memory assetJson = string.concat(json, "_", assetKey);

            vm.serializeString(assetJson, "name", synthetics[i].name);
            vm.serializeString(assetJson, "symbol", synthetics[i].symbol);
            vm.serializeAddress(assetJson, "syntheticAddress", syntheticAddr);
            vm.serializeAddress(assetJson, "oracleAddress", synthetics[i].oracleAddress);
            vm.serializeUint(assetJson, "decimals", synthetics[i].decimals);
            vm.serializeUint(assetJson, "mintCap", synthetics[i].mintCap);
            string memory assetOutput = vm.serializeUint(assetJson, "flashLoanCap", synthetics[i].flashLoanCap);

            // Add to main JSON
            vm.serializeString(json, assetKey, assetOutput);
        }

        // Write arrays for easy access
        uint256 deployedCount = 0;
        for (uint256 i = 0; i < synthetics.length; i++) {
            if (deployedSynthetics[synthetics[i].symbol] != address(0)) {
                deployedCount++;
            }
        }

        string[] memory syntheticSymbols = new string[](deployedCount);
        address[] memory syntheticAddresses = new address[](deployedCount);
        address[] memory oracleAddresses = new address[](deployedCount);

        uint256 idx = 0;
        for (uint256 i = 0; i < synthetics.length; i++) {
            address syntheticAddr = deployedSynthetics[synthetics[i].symbol];
            if (syntheticAddr != address(0)) {
                syntheticSymbols[idx] = synthetics[i].symbol;
                syntheticAddresses[idx] = syntheticAddr;
                oracleAddresses[idx] = synthetics[i].oracleAddress;
                idx++;
            }
        }

        vm.serializeUint(json, "syntheticCount", deployedCount);
        vm.serializeString(json, "allSymbols", syntheticSymbols);
        vm.serializeAddress(json, "allSyntheticAddresses", syntheticAddresses);
        string memory finalJson = vm.serializeAddress(json, "allOracleAddresses", oracleAddresses);

        // Ensure deployments directory exists
        string memory deploymentsDir = "deployments";
        if (!vm.exists(deploymentsDir)) {
            vm.createDir(deploymentsDir, true);
        }

        // Write to file
        string memory fileName =
            string.concat(deploymentsDir, "/ConfiguredProtocol_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);

        console2.log("Configuration saved to:", fileName);
    }
}
