// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {ACLManager} from "@yolo/core-v1/access/ACLManager.sol";
import {IACLManager} from "@yolo/core-v1/interfaces/IACLManager.sol";
import {IYLPVault} from "@yolo/core-v1/interfaces/IYLPVault.sol";
import {IYoloOracle} from "@yolo/core-v1/interfaces/IYoloOracle.sol";
import {IYoloHook} from "@yolo/core-v1/interfaces/IYoloHook.sol";
import {DataTypes} from "@yolo/core-v1/libraries/DataTypes.sol";
import {TradeOrchestrator} from "@yolo/core-v1/trade/TradeOrchestrator.sol";
import {PythPriceFeed} from "@yolo/core-v1/oracles/PythPriceFeed.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

interface IYoloHookPerp is IYoloHook {
    function updateAssetPerpConfiguration(address syntheticToken, DataTypes.PerpConfiguration calldata config) external;
}

/**
 * @title Deploy03_ConfigurePerpTrading
 * @author alvin@yolo.wtf
 * @notice Mirrors Base04 test fixture to deploy TradeOrchestrator, wire ACL roles, and
 *         configure perp trading markets backed by Pyth oracles.
 * @dev Prerequisites:
 *        - Deploy01_FullProtocol deployed core + YoloHook proxy
 *        - Deploy02_ConfigureProtocol created synthetic assets & whitelisted collaterals
 *        - DeployTask_PythOracleAdapter deployed oracle adapters for each synthetic
 *
 * Usage:
 *   TRADE_ADMIN=0xYourAdmin TRADE_KEEPERS=0xKeeper1,0xKeeper2 \
 *   forge script script/Deploy03_ConfigurePerpTrading.s.sol:Deploy03_ConfigurePerpTrading \
 *     --rpc-url $RPC_URL --broadcast -vvv
 */
contract Deploy03_ConfigurePerpTrading is Script {
    // ========================
    // CONFIG - CORE ADDRESSES
    // ========================

    address constant YOLO_HOOK_PROXY = 0x033ea50dEaa8b064958fC40E34F994C154D27FFf;
    address constant YOLO_ORACLE = 0x3ae085e154dB66bAC6721E062Ce30625b6F78D92;
    address constant ACL_MANAGER = 0x778A78699a6F03Bb9b6123580A32A5800E53FF1A;
    address constant YLP_VAULT = 0xc774ba78fd2cd3bDc5d4Dce3d639295627276066;
    address constant PYTH_CONTRACT = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729;

    // Set to non-zero to reuse an existing deployment instead of deploying a new orchestrator
    address constant EXISTING_TRADE_ORCHESTRATOR = address(0);

    error Deploy03__MissingPriceSource(address asset);
    error Deploy03__InvalidPythPrice(address asset);

    // ========================
    // CONFIG - MARKET DATA
    // ========================

    enum RiskTier {
        LOW,
        MEDIUM,
        HIGH,
        CURRENCY,
        CRYPTO,
        COMMODITY,
        METAL
    }

    uint8 internal constant PYTH_TARGET_DECIMALS = 8;
    int32 internal constant PYTH_MAX_EXPONENT = 38;

    function _findSyntheticToken(address[] memory synthetics, string memory symbol) internal view returns (address) {
        bytes32 targetHash = keccak256(bytes(symbol));
        for (uint256 i = 0; i < synthetics.length; i++) {
            if (synthetics[i] == address(0)) continue;
            string memory tokenSymbol = IERC20Metadata(synthetics[i]).symbol();
            if (keccak256(bytes(tokenSymbol)) == targetHash) {
                return synthetics[i];
            }
        }
        return address(0);
    }

    function _getTargetAssetConfigs() internal pure returns (TargetAssetConfig[] memory configs) {
        configs = new TargetAssetConfig[](34);

        configs[0] = TargetAssetConfig({
            symbol: "yBTC",
            oracleAdapter: 0x2f09E672459cCF2B20A4C621aFA756CC0b9D3B8D,
            pythPriceId: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43,
            tier: RiskTier.CRYPTO
        });
        configs[1] = TargetAssetConfig({
            symbol: "yETH",
            oracleAdapter: 0xE3d179F77A6c514C374A8De1B3AabB1CCC8E3140,
            pythPriceId: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
            tier: RiskTier.CRYPTO
        });
        configs[2] = TargetAssetConfig({
            symbol: "ySOL",
            oracleAdapter: 0x41De0a331EA729F23F1c428F88e4c1Ac2d313De4,
            pythPriceId: 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d,
            tier: RiskTier.CRYPTO
        });
        configs[3] = TargetAssetConfig({
            symbol: "yAAPL",
            oracleAdapter: 0x037A2C629Bbb421c1E3229b64749e5319e39d29e,
            pythPriceId: 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688,
            tier: RiskTier.LOW
        });
        configs[4] = TargetAssetConfig({
            symbol: "yGOOGL",
            oracleAdapter: 0xe44242B70Fa76ddE2aCf63685a3f10079772f643,
            pythPriceId: 0x5a48c03e9b9cb337801073ed9d166817473697efff0d138874e0f6a33d6d5aa6,
            tier: RiskTier.LOW
        });
        configs[5] = TargetAssetConfig({
            symbol: "yNVDA",
            oracleAdapter: 0xd604AAC32CcF7a0cFB65e3b2B5014b9DC9a43E9E,
            pythPriceId: 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593,
            tier: RiskTier.MEDIUM
        });
        configs[6] = TargetAssetConfig({
            symbol: "yMETA",
            oracleAdapter: 0xB105dcBD614bBF3d0B30D55CCA5600dC3a3e8683,
            pythPriceId: 0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe,
            tier: RiskTier.LOW
        });
        configs[7] = TargetAssetConfig({
            symbol: "yMSFT",
            oracleAdapter: 0x2104df60FacEd7f3A0fcF4550f01D0b08e1f9DF8,
            pythPriceId: 0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1,
            tier: RiskTier.LOW
        });
        configs[8] = TargetAssetConfig({
            symbol: "yAMD",
            oracleAdapter: 0x71BC651205C68ed5DFBF1DCe35361C32dddCFF88,
            pythPriceId: 0x3622e381dbca2efd1859253763b1adc63f7f9abb8e76da1aa8e638a57ccde93e,
            tier: RiskTier.MEDIUM
        });
        configs[9] = TargetAssetConfig({
            symbol: "yNFLX",
            oracleAdapter: 0x43290B6Fb1A8cDc09FDaCB8F7c9F68886ECfaf11,
            pythPriceId: 0x8376cfd7ca8bcdf372ced05307b24dced1f15b1afafdeff715664598f15a3dd2,
            tier: RiskTier.MEDIUM
        });
        configs[10] = TargetAssetConfig({
            symbol: "yINTC",
            oracleAdapter: 0x537DA8502940B8f1Ef734d04f85b8D4Dc0434C5f,
            pythPriceId: 0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff,
            tier: RiskTier.MEDIUM
        });
        configs[11] = TargetAssetConfig({
            symbol: "yCOIN",
            oracleAdapter: 0x2e5662a3aAD5cD595A1FCc10bD5DAF40198f70F7,
            pythPriceId: 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245,
            tier: RiskTier.HIGH
        });
        configs[12] = TargetAssetConfig({
            symbol: "yHOOD",
            oracleAdapter: 0x51208ae242f03B3134F505e33B7f725BCB7F7966,
            pythPriceId: 0x306736a4035846ba15a3496eed57225b64cc19230a50d14f3ed20fd7219b7849,
            tier: RiskTier.HIGH
        });
        configs[13] = TargetAssetConfig({
            symbol: "yJPM",
            oracleAdapter: 0x4A19f360aA922704B785ca0719bb540456DAb4E7,
            pythPriceId: 0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e,
            tier: RiskTier.LOW
        });
        configs[14] = TargetAssetConfig({
            symbol: "yBAC",
            oracleAdapter: 0x76Bb06BFCB5FdB7197bD6c9785b4ccA11CF0bF8C,
            pythPriceId: 0x21debc1718a4b76ff74dadf801c261d76c46afaafb74d9645b65e00b80f5ee3e,
            tier: RiskTier.LOW
        });
        configs[15] = TargetAssetConfig({
            symbol: "yGS",
            oracleAdapter: 0x522Ed762874cF498F651bC254B2d95568a0553B3,
            pythPriceId: 0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554,
            tier: RiskTier.LOW
        });
        configs[16] = TargetAssetConfig({
            symbol: "yV",
            oracleAdapter: 0xF2dc034fbceCaA18424B0345E4f7Ce41E4Cda8fF,
            pythPriceId: 0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90,
            tier: RiskTier.LOW
        });
        configs[17] = TargetAssetConfig({
            symbol: "yTSLA",
            oracleAdapter: 0xc3EC36F93657AD8039191259F4768F2FD937f64d,
            pythPriceId: 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1,
            tier: RiskTier.HIGH
        });
        configs[18] = TargetAssetConfig({
            symbol: "yAMZN",
            oracleAdapter: 0x77E6E6d57bfbB789E5A5119AcB5AB9378AAa0B58,
            pythPriceId: 0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a,
            tier: RiskTier.LOW
        });
        configs[19] = TargetAssetConfig({
            symbol: "yDIS",
            oracleAdapter: 0xE0846158b10DBd1Dcf5c9f61b0Da3b375eCb2E21,
            pythPriceId: 0x703e36203020ae6761e6298975764e266fb869210db9b35dd4e4225fa68217d0,
            tier: RiskTier.MEDIUM
        });
        configs[20] = TargetAssetConfig({
            symbol: "yBA",
            oracleAdapter: 0x11b422db5E687217DcFDFF03eF5B5Ba6cDd94ded,
            pythPriceId: 0x8419416ba640c8bbbcf2d464561ed7dd860db1e38e51cec9baf1e34c4be839ae,
            tier: RiskTier.MEDIUM
        });
        configs[21] = TargetAssetConfig({
            symbol: "yBABA",
            oracleAdapter: 0x8e0F9257CeBA1E2d9caf70a4Ca6E0A898A977F0f,
            pythPriceId: 0x72bc23b1d0afb1f8edef20b7fb60982298993161bc0fd749587d6f60cd1ee9a3,
            tier: RiskTier.MEDIUM
        });
        configs[22] = TargetAssetConfig({
            symbol: "yPLTR",
            oracleAdapter: 0x04bFA450C7e4CE6a12cC59Afbd58C5A2251D514D,
            pythPriceId: 0x11a70634863ddffb71f2b11f2cff29f73f3db8f6d0b78c49f2b5f4ad36e885f0,
            tier: RiskTier.HIGH
        });
        configs[23] = TargetAssetConfig({
            symbol: "yQQQ",
            oracleAdapter: 0x9cc48DBb04EDBb48B0196874E605b698fCB50f9B,
            pythPriceId: 0x9695e2b96ea7b3859da9ed25b7a46a920a776e2fdae19a7bcfdf2b219230452d,
            tier: RiskTier.LOW
        });
        configs[24] = TargetAssetConfig({
            symbol: "ySPY",
            oracleAdapter: 0x5A5B99FFAFe7A0b6209A06CB4eE998E6aE3507A0,
            pythPriceId: 0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5,
            tier: RiskTier.LOW
        });
        configs[25] = TargetAssetConfig({
            symbol: "yDIA",
            oracleAdapter: 0x4AB167bFf65CFa03958dc9633353c414F4460a05,
            pythPriceId: 0x57cff3a9a4d4c87b595a2d1bd1bac0240400a84677366d632ab838bbbe56f763,
            tier: RiskTier.LOW
        });
        configs[26] = TargetAssetConfig({
            symbol: "yIWM",
            oracleAdapter: 0x3b19Ef929Af16e55b551a4A379884c373cE53A12,
            pythPriceId: 0xeff690a187797aa225723345d4612abec0bf0cec1ae62347c0e7b1905d730879,
            tier: RiskTier.MEDIUM
        });
        configs[27] = TargetAssetConfig({
            symbol: "yEUR",
            oracleAdapter: 0x4289027b3885EFdF8603A0e8867D78b8CDAE0838,
            pythPriceId: 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b,
            tier: RiskTier.CURRENCY
        });
        configs[28] = TargetAssetConfig({
            symbol: "yBRENT",
            oracleAdapter: 0x5cb83399FbD90cdD4A3673aD1617A02E1F11Dd5F,
            pythPriceId: 0x27f0d5e09a830083e5491795cac9ca521399c8f7fd56240d09484b14e614d57a,
            tier: RiskTier.COMMODITY
        });
        configs[29] = TargetAssetConfig({
            symbol: "yWTI",
            oracleAdapter: 0xDBFdF3C8BDc6011D411134Da30504d40A7426fE9,
            pythPriceId: 0x925ca92ff005ae943c158e3563f59698ce7e75c5a8c8dd43303a0a154887b3e6,
            tier: RiskTier.COMMODITY
        });
        configs[30] = TargetAssetConfig({
            symbol: "yXAU",
            oracleAdapter: 0xC45052955cb49f66eB55502B9f1A82fc1e9C9d5C,
            pythPriceId: 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2,
            tier: RiskTier.METAL
        });
        configs[31] = TargetAssetConfig({
            symbol: "yXAG",
            oracleAdapter: 0x5121ac7B01DF7A997BD272b3D57C6a14f9f54070,
            pythPriceId: 0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e,
            tier: RiskTier.METAL
        });
        configs[32] = TargetAssetConfig({
            symbol: "yXPT",
            oracleAdapter: 0x2EB33bD83Ece44C42337D04cC1271d67317a67cC,
            pythPriceId: 0x398e4bbc7cbf89d6648c21e08019d878967677753b3096799595c78f805a34e5,
            tier: RiskTier.METAL
        });
        configs[33] = TargetAssetConfig({
            symbol: "yXPD",
            oracleAdapter: 0x1D6115BA17A4EEd3fAb981dA8511e70C703A6Dd4,
            pythPriceId: 0x80367e9664197f37d89a07a804dffd2101c479c7c4e8490501bc9d9e1e7f9021,
            tier: RiskTier.METAL
        });
    }

    struct TradeAssetInput {
        string symbol;
        address syntheticAsset;
        address oracleAdapter;
        bytes32 pythPriceId;
        RiskTier tier;
        uint256 maxSupply;
    }

    struct TargetAssetConfig {
        string symbol;
        address oracleAdapter;
        bytes32 pythPriceId;
        RiskTier tier;
    }

    struct TierParameters {
        uint32 maxLeverageBpsDay;
        uint32 maxLeverageBpsNight;
        uint32 maxPriceAgeSec;
        uint16 maxDeviationBps;
        uint16 longSpreadBps;
        uint16 shortSpreadBps;
        uint16 openFeeBps;
        uint16 closeFeeBps;
        uint16 overnightUnwindFeeBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationRewardBps;
        uint32 fundingFactorPerHour;
        uint16 fixedBorrowBps;
        uint256 minCollateralUsy;
        uint16 oiMultiplierBps;
    }

    function _configureTradeAssets() internal view returns (TradeAssetInput[] memory) {
        TargetAssetConfig[] memory targets = _getTargetAssetConfigs();
        address[] memory syntheticTokens = IYoloHook(YOLO_HOOK_PROXY).getAllSyntheticAssets();

        TradeAssetInput[] memory assets = new TradeAssetInput[](targets.length);
        for (uint256 i = 0; i < targets.length; i++) {
            address syntheticToken = _findSyntheticToken(syntheticTokens, targets[i].symbol);
            require(syntheticToken != address(0), string.concat("Missing synthetic asset for ", targets[i].symbol));

            DataTypes.AssetConfiguration memory cfg = IYoloHook(YOLO_HOOK_PROXY).getAssetConfiguration(syntheticToken);

            assets[i] = TradeAssetInput({
                symbol: targets[i].symbol,
                syntheticAsset: syntheticToken,
                oracleAdapter: targets[i].oracleAdapter,
                pythPriceId: targets[i].pythPriceId,
                tier: targets[i].tier,
                maxSupply: cfg.maxSupply
            });
        }
        return assets;
    }

    // ========================
    // CONSTANTS
    // ========================

    bytes32 public constant TRADE_OPERATOR_ROLE = keccak256("TRADE_OPERATOR");
    bytes32 public constant TRADE_ADMIN_ROLE = keccak256("TRADE_ADMIN_ROLE");
    bytes32 public constant TRADE_KEEPER_ROLE = keccak256("TRADE_KEEPER_ROLE");

    uint32 internal constant TRADE_SESSION_START = uint32(13 hours); // 13:00 UTC
    uint32 internal constant TRADE_SESSION_END = uint32(22 hours); // 22:00 UTC

    // ========================
    // STATE
    // ========================

    struct DeploymentArtifacts {
        address tradeOrchestrator;
    }

    DeploymentArtifacts public deployed;

    // ========================
    // ENTRYPOINT
    // ========================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        address tradeAdmin = vm.envOr("TRADE_ADMIN", deployer);
        address keeperFallback = vm.envOr("TRADE_KEEPER", tradeAdmin);

        address[] memory defaultKeepers = new address[](1);
        defaultKeepers[0] = keeperFallback;
        address[] memory keeperRecipients = vm.envOr("TRADE_KEEPERS", ",", defaultKeepers);

        TradeAssetInput[] memory tradeAssets = _configureTradeAssets();
        require(tradeAssets.length > 0, "No trade assets configured");

        console2.log("============================================================");
        console2.log("YOLO Protocol V1 - Deploy03 Configure Perp Trading");
        console2.log("============================================================");
        console2.log("Deployer:", deployer);
        console2.log("Trade Admin:", tradeAdmin);
        console2.log("Keeper count:", keeperRecipients.length);
        console2.log("Configured assets:", tradeAssets.length);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        deployed.tradeOrchestrator = EXISTING_TRADE_ORCHESTRATOR;
        if (deployed.tradeOrchestrator == address(0)) {
            deployed.tradeOrchestrator = _deployTradeOrchestrator();
        } else {
            console2.log("[TradeOrchestrator] Using existing deployment:", deployed.tradeOrchestrator);
        }

        _setupTradeRoles(deployed.tradeOrchestrator, tradeAdmin, keeperRecipients);
        _configureOracleSources(tradeAssets);
        _configurePerpMarkets(tradeAssets, deployed.tradeOrchestrator);

        vm.stopBroadcast();

        _saveDeployment(tradeAdmin, keeperRecipients, tradeAssets);

        console2.log("");
        console2.log("============================================================");
        console2.log("Deploy03 Complete!");
        console2.log("============================================================");
    }

    // ========================
    // DEPLOY + CONFIG HELPERS
    // ========================

    function _deployTradeOrchestrator() internal returns (address) {
        console2.log("[Step 1] Deploying TradeOrchestrator...");
        TradeOrchestrator orchestrator = new TradeOrchestrator(
            IACLManager(ACL_MANAGER), IYoloHook(YOLO_HOOK_PROXY), IYLPVault(YLP_VAULT), IPyth(PYTH_CONTRACT)
        );
        console2.log("  TradeOrchestrator deployed:", address(orchestrator));
        return address(orchestrator);
    }

    function _setupTradeRoles(address tradeOrchestrator, address tradeAdmin, address[] memory keepers) internal {
        console2.log("[Step 2] Wiring ACL roles...");
        ACLManager acl = ACLManager(ACL_MANAGER);

        _createRoleIfMissing(acl, "TRADE_OPERATOR", bytes32(0));
        _createRoleIfMissing(acl, "TRADE_ADMIN_ROLE", bytes32(0));
        _createRoleIfMissing(acl, "TRADE_KEEPER_ROLE", bytes32(0));

        acl.grantRole(TRADE_OPERATOR_ROLE, tradeOrchestrator);
        console2.log("  Granted TRADE_OPERATOR to orchestrator:", tradeOrchestrator);

        acl.grantRole(TRADE_ADMIN_ROLE, tradeAdmin);
        console2.log("  Granted TRADE_ADMIN_ROLE to:", tradeAdmin);

        for (uint256 i = 0; i < keepers.length; i++) {
            if (keepers[i] == address(0)) continue;
            acl.grantRole(TRADE_KEEPER_ROLE, keepers[i]);
            console2.log("  Granted TRADE_KEEPER_ROLE to:", keepers[i]);
        }
        console2.log("  [Step 2] Complete!");
        console2.log("");
    }

    function _configureOracleSources(TradeAssetInput[] memory assets) internal {
        console2.log("[Step 3] Updating YoloOracle sources...");
        IYoloOracle oracle = IYoloOracle(YOLO_ORACLE);

        uint256 validCount;
        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].oracleAdapter != address(0)) {
                validCount++;
            }
        }

        if (validCount == 0) {
            console2.log("  No oracle adapters configured, skipping");
            console2.log("");
            return;
        }

        address[] memory assetAddresses = new address[](validCount);
        address[] memory oracleSources = new address[](validCount);
        uint256 cursor;

        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].oracleAdapter == address(0)) continue;
            assetAddresses[cursor] = assets[i].syntheticAsset;
            oracleSources[cursor] = assets[i].oracleAdapter;
            console2.log("  -", assets[i].symbol, "->", assets[i].oracleAdapter);
            cursor++;
        }

        oracle.setAssetSources(assetAddresses, oracleSources);
        console2.log("  Oracle sources updated");
        console2.log("");
    }

    function _configurePerpMarkets(TradeAssetInput[] memory assets, address tradeOrchestrator) internal {
        console2.log("[Step 4] Configuring perp markets...");
        IYoloHookPerp yoloHook = IYoloHookPerp(YOLO_HOOK_PROXY);
        TradeOrchestrator orchestrator = TradeOrchestrator(tradeOrchestrator);
        IYoloOracle oracle = IYoloOracle(YOLO_ORACLE);

        for (uint256 i = 0; i < assets.length; i++) {
            if (assets[i].syntheticAsset == address(0) || assets[i].pythPriceId == bytes32(0)) {
                console2.log("  Skipping", assets[i].symbol, "(missing address or price ID)");
                continue;
            }

            TierParameters memory tierParams = _tierParameters(assets[i].tier);
            uint256 priceX8 = _getPythPriceX8(oracle, assets[i].syntheticAsset);
            uint256 mintCapUsd = _usdValue(assets[i].maxSupply, priceX8);
            uint256 maxOpenInterestUsd = (mintCapUsd * tierParams.oiMultiplierBps) / 10_000;
            if (maxOpenInterestUsd == 0) {
                console2.log("  Skipping", assets[i].symbol, "(zero mint cap)");
                continue;
            }

            DataTypes.PerpConfiguration memory perpCfg = DataTypes.PerpConfiguration({
                enabled: true,
                maxOpenInterestUsd: maxOpenInterestUsd,
                maxLongOpenInterestUsd: maxOpenInterestUsd / 2,
                maxShortOpenInterestUsd: maxOpenInterestUsd / 2,
                maxLeverageBpsDay: tierParams.maxLeverageBpsDay,
                maxLeverageBpsCarryOvernight: tierParams.maxLeverageBpsNight,
                tradeSessionStart: TRADE_SESSION_START,
                tradeSessionEnd: TRADE_SESSION_END,
                marketState: DataTypes.TradeMarketState.OPEN
            });

            yoloHook.updateAssetPerpConfiguration(assets[i].syntheticAsset, perpCfg);
            orchestrator.configureTradeAsset(
                assets[i].syntheticAsset, _buildTradeAssetConfig(assets[i].pythPriceId, tierParams)
            );

            console2.log("  Configured", assets[i].symbol);
            console2.log("    Tier:", _tierName(assets[i].tier));
            console2.log("    Mint cap (USD):", mintCapUsd / 1e18);
            console2.log("    Max OI (USD):", maxOpenInterestUsd / 1e18);
            console2.log("    Fixed borrow APR (bps):", tierParams.fixedBorrowBps);
        }

        console2.log("  [Step 4] Complete!");
        console2.log("");
    }

    // ========================
    // CONFIG BUILDERS
    // ========================

    function _buildTradeAssetConfig(bytes32 priceId, TierParameters memory params)
        internal
        pure
        returns (TradeOrchestrator.TradeAssetConfig memory)
    {
        return TradeOrchestrator.TradeAssetConfig({
            pythPriceId: priceId,
            maxPriceAgeSec: params.maxPriceAgeSec,
            maxDeviationBps: params.maxDeviationBps,
            longSpreadBps: params.longSpreadBps,
            shortSpreadBps: params.shortSpreadBps,
            fundingFactorPerHour: params.fundingFactorPerHour,
            fixedBorrowBps: params.fixedBorrowBps,
            liquidationThresholdBps: params.liquidationThresholdBps,
            liquidationRewardBps: params.liquidationRewardBps,
            openFeeBps: params.openFeeBps,
            closeFeeBps: params.closeFeeBps,
            overnightUnwindFeeBps: params.overnightUnwindFeeBps,
            minCollateralUsy: params.minCollateralUsy,
            feesEnabled: true,
            isActive: true
        });
    }

    function _tierParameters(RiskTier tier) internal pure returns (TierParameters memory params) {
        if (tier == RiskTier.LOW) {
            params = TierParameters({
                maxLeverageBpsDay: 120_000,
                maxLeverageBpsNight: 40_000,
                maxPriceAgeSec: 120,
                maxDeviationBps: 50,
                longSpreadBps: 4,
                shortSpreadBps: 4,
                openFeeBps: 10,
                closeFeeBps: 10,
                overnightUnwindFeeBps: 25,
                liquidationThresholdBps: 1_000,
                liquidationRewardBps: 250,
                fundingFactorPerHour: 100_000,
                fixedBorrowBps: 1_800,
                minCollateralUsy: 5e18,
                oiMultiplierBps: 8_000
            });
        } else if (tier == RiskTier.MEDIUM) {
            params = TierParameters({
                maxLeverageBpsDay: 25_000,
                maxLeverageBpsNight: 4_000,
                maxPriceAgeSec: 120,
                maxDeviationBps: 50,
                longSpreadBps: 6,
                shortSpreadBps: 6,
                openFeeBps: 10,
                closeFeeBps: 10,
                overnightUnwindFeeBps: 25,
                liquidationThresholdBps: 1_000,
                liquidationRewardBps: 250,
                fundingFactorPerHour: 100_000,
                fixedBorrowBps: 1_800,
                minCollateralUsy: 5e18,
                oiMultiplierBps: 6_000
            });
        } else if (tier == RiskTier.HIGH) {
            params = TierParameters({
                maxLeverageBpsDay: 10_000,
                maxLeverageBpsNight: 2_000,
                maxPriceAgeSec: 120,
                maxDeviationBps: 50,
                longSpreadBps: 8,
                shortSpreadBps: 8,
                openFeeBps: 10,
                closeFeeBps: 10,
                overnightUnwindFeeBps: 25,
                liquidationThresholdBps: 1_000,
                liquidationRewardBps: 250,
                fundingFactorPerHour: 100_000,
                fixedBorrowBps: 1_800,
                minCollateralUsy: 5e18,
                oiMultiplierBps: 4_000
            });
        } else if (tier == RiskTier.CRYPTO) {
            params = TierParameters({
                maxLeverageBpsDay: 150_000,
                maxLeverageBpsNight: 150_000,
                maxPriceAgeSec: 120,
                maxDeviationBps: 50,
                longSpreadBps: 12,
                shortSpreadBps: 12,
                openFeeBps: 10,
                closeFeeBps: 10,
                overnightUnwindFeeBps: 25,
                liquidationThresholdBps: 1_000,
                liquidationRewardBps: 250,
                fundingFactorPerHour: 100_000,
                fixedBorrowBps: 1_800,
                minCollateralUsy: 5e18,
                oiMultiplierBps: 2_500
            });
        } else if (tier == RiskTier.CURRENCY) {
            params = TierParameters({
                maxLeverageBpsDay: 250_000,
                maxLeverageBpsNight: 20_000,
                maxPriceAgeSec: 120,
                maxDeviationBps: 50,
                longSpreadBps: 3,
                shortSpreadBps: 3,
                openFeeBps: 10,
                closeFeeBps: 10,
                overnightUnwindFeeBps: 25,
                liquidationThresholdBps: 1_000,
                liquidationRewardBps: 250,
                fundingFactorPerHour: 100_000,
                fixedBorrowBps: 1_800,
                minCollateralUsy: 5e18,
                oiMultiplierBps: 9_000
            });
        } else if (tier == RiskTier.COMMODITY) {
            params = TierParameters({
                maxLeverageBpsDay: 125_000,
                maxLeverageBpsNight: 5_000,
                maxPriceAgeSec: 120,
                maxDeviationBps: 50,
                longSpreadBps: 6,
                shortSpreadBps: 6,
                openFeeBps: 10,
                closeFeeBps: 10,
                overnightUnwindFeeBps: 25,
                liquidationThresholdBps: 1_000,
                liquidationRewardBps: 250,
                fundingFactorPerHour: 100_000,
                fixedBorrowBps: 1_800,
                minCollateralUsy: 5e18,
                oiMultiplierBps: 7_000
            });
        } else {
            // Metal tier
            params = TierParameters({
                maxLeverageBpsDay: 125_000,
                maxLeverageBpsNight: 5_000,
                maxPriceAgeSec: 120,
                maxDeviationBps: 50,
                longSpreadBps: 5,
                shortSpreadBps: 5,
                openFeeBps: 10,
                closeFeeBps: 10,
                overnightUnwindFeeBps: 25,
                liquidationThresholdBps: 1_000,
                liquidationRewardBps: 250,
                fundingFactorPerHour: 100_000,
                fixedBorrowBps: 1_800,
                minCollateralUsy: 5e18,
                oiMultiplierBps: 7_500
            });
        }
    }

    function _usdValue(uint256 amount, uint256 priceX8) internal pure returns (uint256) {
        return (amount * priceX8) / 1e8;
    }

    function _tierName(RiskTier tier) internal pure returns (string memory) {
        if (tier == RiskTier.LOW) return "LOW";
        if (tier == RiskTier.MEDIUM) return "MEDIUM";
        if (tier == RiskTier.HIGH) return "HIGH";
        if (tier == RiskTier.CURRENCY) return "CURRENCY";
        if (tier == RiskTier.CRYPTO) return "CRYPTO";
        if (tier == RiskTier.COMMODITY) return "COMMODITY";
        if (tier == RiskTier.METAL) return "METAL";
        return "UNKNOWN";
    }

    function _getPythPriceX8(IYoloOracle oracle, address asset) internal view returns (uint256) {
        address source = oracle.getSourceOfAsset(asset);
        if (source == address(0)) revert Deploy03__MissingPriceSource(asset);
        PythPriceFeed feed = PythPriceFeed(source);
        PythStructs.Price memory rawPrice = feed.getPythPrice();
        return _scalePythPrice(rawPrice, asset);
    }

    function _scalePythPrice(PythStructs.Price memory price, address asset) internal pure returns (uint256) {
        if (price.price <= 0) revert Deploy03__InvalidPythPrice(asset);
        int32 adjustment = price.expo + int32(uint32(PYTH_TARGET_DECIMALS));
        if (adjustment > PYTH_MAX_EXPONENT || adjustment < -PYTH_MAX_EXPONENT) {
            revert Deploy03__InvalidPythPrice(asset);
        }
        int256 value = price.price;
        if (adjustment != 0) {
            int32 absAdjInt = adjustment >= 0 ? adjustment : -adjustment;
            uint256 absAdj = uint256(uint32(uint32(absAdjInt)));
            int256 scale = int256(10 ** absAdj);
            if (adjustment > 0) {
                value *= scale;
            } else {
                value /= scale;
            }
        }
        if (value <= 0) revert Deploy03__InvalidPythPrice(asset);
        return uint256(value);
    }

    // ========================
    // UTILITIES
    // ========================

    function _createRoleIfMissing(ACLManager acl, string memory name, bytes32 adminRole) internal {
        try acl.createRole(name, adminRole) returns (bytes32 roleId) {
            console2.log("  Created role", name, "->", vm.toString(roleId));
        } catch {
            console2.log("  Role", name, "already exists (skipping)");
        }
    }

    function _saveDeployment(address tradeAdmin, address[] memory keepers, TradeAssetInput[] memory assets) internal {
        string memory json = "deploy03";
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "yoloHookProxy", YOLO_HOOK_PROXY);
        vm.serializeAddress(json, "yoloOracle", YOLO_ORACLE);
        vm.serializeAddress(json, "aclManager", ACL_MANAGER);
        vm.serializeAddress(json, "ylpVault", YLP_VAULT);
        vm.serializeAddress(json, "pythContract", PYTH_CONTRACT);
        vm.serializeAddress(json, "tradeOrchestrator", deployed.tradeOrchestrator);
        vm.serializeAddress(json, "tradeAdmin", tradeAdmin);

        for (uint256 i = 0; i < keepers.length; i++) {
            string memory key = string.concat("keeper_", vm.toString(i));
            vm.serializeAddress(json, key, keepers[i]);
        }

        IYoloOracle oracle = IYoloOracle(YOLO_ORACLE);

        for (uint256 i = 0; i < assets.length; i++) {
            string memory assetKey = string.concat("asset_", assets[i].symbol);
            string memory assetJson = vm.serializeAddress(assetKey, "syntheticAsset", assets[i].syntheticAsset);
            assetJson = vm.serializeAddress(assetKey, "oracleAdapter", assets[i].oracleAdapter);
            assetJson = vm.serializeBytes32(assetKey, "pythPriceId", assets[i].pythPriceId);
            assetJson = vm.serializeBool(assetKey, "configured", assets[i].syntheticAsset != address(0));
            assetJson = vm.serializeString(assetKey, "symbol", assets[i].symbol);
            assetJson = vm.serializeString(assetKey, "tier", _tierName(assets[i].tier));
            assetJson = vm.serializeUint(assetKey, "maxSupply", assets[i].maxSupply);
            uint256 priceX8 = _getPythPriceX8(oracle, assets[i].syntheticAsset);
            uint256 mintCapUsd = _usdValue(assets[i].maxSupply, priceX8);
            TierParameters memory tierParams = _tierParameters(assets[i].tier);
            uint256 maxOiUsd = (mintCapUsd * tierParams.oiMultiplierBps) / 10_000;
            assetJson = vm.serializeUint(assetKey, "mintCapUsd18", mintCapUsd);
            assetJson = vm.serializeUint(assetKey, "maxOiUsd18", maxOiUsd);
            vm.serializeString(json, string.concat("config_", assets[i].symbol), assetJson);
        }

        string memory finalJson = vm.serializeUint(json, "timestamp", block.timestamp);
        string memory fileName = string.concat("deployments/TradePerpConfig_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);

        console2.log("Deployment summary saved to:", fileName);
    }
}
