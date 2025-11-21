// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {PythPriceFeed} from "@yolo/core-v1/oracles/PythPriceFeed.sol";

/**
 * @title DeployTask_PythOracleAdapter
 * @author alvin@yolo.wtf
 * @notice Deployment script for Pyth oracle adapters with automatic address recording
 * @dev Usage:
 *      1. Configure oracle parameters in the `_configureOracles()` function
 *      2. Run: forge script script/DeployTask_PythOracleAdapter.sol:DeployTask_PythOracleAdapter --rpc-url <RPC_URL> --broadcast
 *      3. Deployed addresses are saved to deployments/PythOracleAdapters.json
 */
contract DeployTask_PythOracleAdapter is Script {
    // ========================
    // TYPES
    // ========================

    /**
     * @notice Configuration for a single Pyth price feed adapter
     * @param assetSymbol Human-readable symbol (e.g., "ETH/USD", "NVDA/USD")
     * @param priceId Pyth price feed identifier (32-byte hex)
     * @param maxAllowedPriceLag Maximum staleness in seconds (e.g., 60 for 1 minute)
     */
    struct OracleConfig {
        string assetSymbol;
        bytes32 priceId;
        uint32 maxAllowedPriceLag;
    }

    /**
     * @notice Deployment result for a single oracle
     */
    struct DeployedOracle {
        string assetSymbol;
        address deployedAddress;
        bytes32 priceId;
        uint32 maxAllowedPriceLag;
    }

    // ========================
    // STATE VARIABLES
    // ========================

    /// @notice Pyth contract address (set per chain)
    address public pythAddress;

    /// @notice Array of oracle configurations to deploy
    OracleConfig[] public oracleConfigs;

    /// @notice Array of deployed oracle adapters
    DeployedOracle[] public deployedOracles;

    // ========================
    // MAIN DEPLOYMENT LOGIC
    // ========================

    /**
     * @notice Main deployment function
     */
    function run() external {
        // Load deployer private key from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=================================");
        console2.log("Pyth Oracle Adapter Deployment");
        console2.log("=================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        // Configure oracles for the current chain
        _configureOracles();

        // Validate configuration
        require(pythAddress != address(0), "Pyth address not configured for this chain");
        require(oracleConfigs.length > 0, "No oracle configurations found");

        console2.log("Pyth Address:", pythAddress);
        console2.log("Oracles to deploy:", oracleConfigs.length);
        console2.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy each oracle adapter
        for (uint256 i = 0; i < oracleConfigs.length; i++) {
            _deployOracle(oracleConfigs[i]);
        }

        vm.stopBroadcast();

        // Save deployment addresses to JSON
        _saveDeployments();

        console2.log("");
        console2.log("=================================");
        console2.log("Deployment Complete!");
        console2.log("=================================");
    }

    // ========================
    // ORACLE CONFIGURATION
    // ========================

    /**
     * @notice Configure oracle parameters based on chain ID
     * @dev ADD YOUR ORACLE CONFIGURATIONS HERE
     *
     * To add a new oracle:
     * 1. Find the Pyth price feed ID from: https://pyth.network/developers/price-feed-ids
     * 2. Add a new entry to oracleConfigs array
     * 3. Set assetSymbol, priceId, and maxAllowedPriceLag
     *
     * Example Pyth Price IDs:
     * - ETH/USD:  0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace
     * - BTC/USD:  0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43
     * - NVDA/USD: 0x3a9c5d3ab4e0e51fa8f7d1e5c5c4e4d10ae8d6ec3f9ef5d08b6ab10d5d09e4c9
     */
    function _configureOracles() internal {
        // Base Mainnet (Chain ID: 8453)
        if (block.chainid == 8453) {
            pythAddress = 0x8250f4aF4B972684F7b336503E2D6dFeDeB1487a; // Pyth on Base

            // Example configurations - REPLACE WITH YOUR ACTUAL PRICE FEED IDs
            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "ETH/USD",
                    priceId: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
                    maxAllowedPriceLag: 60 // 60 seconds
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "BTC/USD",
                    priceId: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43,
                    maxAllowedPriceLag: 60 // 60 seconds
                })
            );

            // ADD MORE ORACLES HERE:
            // oracleConfigs.push(OracleConfig({
            //     assetSymbol: "NVDA/USD",
            //     priceId: 0x..., // Get from https://pyth.network/developers/price-feed-ids
            //     maxAllowedPriceLag: 60
            // }));
        }
        // Base Sepolia Testnet (Chain ID: 84532)
        else if (block.chainid == 84532) {
            pythAddress = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729; // Pyth on Base Sepolia

            /****************************************
             * CRYPTO
             ****************************************/

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "BTC / USD",
                    priceId: 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43,
                    maxAllowedPriceLag: 120 // 2 minutes (more lenient for testnet)
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "ETH / USD",
                    priceId: 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "SOL / USD",
                    priceId: 0xef0d8b6fda2ceba41da15d4095d1da392a0d2f8ed0c6c7bc0f4cfac8c280b56d,
                    maxAllowedPriceLag: 120
                })
            );

            /****************************************
             * EQUITIES - Technology
             ****************************************/

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "AAPL / USD",
                    priceId: 0x49f6b65cb1de6b10eaf75e7c03ca029c306d0357e91b5311b175084a5ad55688,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "GOOGL / USD",
                    priceId: 0x5a48c03e9b9cb337801073ed9d166817473697efff0d138874e0f6a33d6d5aa6,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "NVDA / USD",
                    priceId: 0xb1073854ed24cbc755dc527418f52b7d271f6cc967bbf8d8129112b18860a593,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "META / USD",
                    priceId: 0x78a3e3b8e676a8f73c439f5d749737034b139bbbe899ba5775216fba596607fe,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "MSFT / USD",
                    priceId: 0xd0ca23c1cc005e004ccf1db5bf76aeb6a49218f43dac3d4b275e92de12ded4d1,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "AMD / USD",
                    priceId: 0x3622e381dbca2efd1859253763b1adc63f7f9abb8e76da1aa8e638a57ccde93e,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "NFLX / USD",
                    priceId: 0x8376cfd7ca8bcdf372ced05307b24dced1f15b1afafdeff715664598f15a3dd2,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "INTC / USD",
                    priceId: 0xc1751e085ee292b8b3b9dd122a135614485a201c35dfc653553f0e28c1baf3ff,
                    maxAllowedPriceLag: 120
                })
            );

            /****************************************
             * EQUITIES - Financial Services
             ****************************************/

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "COIN / USD",
                    priceId: 0xfee33f2a978bf32dd6b662b65ba8083c6773b494f8401194ec1870c640860245,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "HOOD / USD",
                    priceId: 0x306736a4035846ba15a3496eed57225b64cc19230a50d14f3ed20fd7219b7849,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "JPM / USD",
                    priceId: 0x7f4f157e57bfcccd934c566df536f34933e74338fe241a5425ce561acdab164e,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "BAC / USD",
                    priceId: 0x21debc1718a4b76ff74dadf801c261d76c46afaafb74d9645b65e00b80f5ee3e,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "GS / USD",
                    priceId: 0x9c68c0c6999765cf6e27adf75ed551b34403126d3b0d5b686a2addb147ed4554,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "V / USD",
                    priceId: 0xc719eb7bab9b2bc060167f1d1680eb34a29c490919072513b545b9785b73ee90,
                    maxAllowedPriceLag: 120
                })
            );

            /****************************************
             * EQUITIES - Consumer & Other
             ****************************************/

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "TSLA / USD",
                    priceId: 0x16dad506d7db8da01c87581c87ca897a012a153557d4d578c3b9c9e1bc0632f1,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "AMZN / USD",
                    priceId: 0xb5d0e0fa58a1f8b81498ae670ce93c872d14434b72c364885d4fa1b257cbb07a,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "DIS / USD",
                    priceId: 0x703e36203020ae6761e6298975764e266fb869210db9b35dd4e4225fa68217d0,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "BA / USD",
                    priceId: 0x8419416ba640c8bbbcf2d464561ed7dd860db1e38e51cec9baf1e34c4be839ae,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "BABA / USD",
                    priceId: 0x72bc23b1d0afb1f8edef20b7fb60982298993161bc0fd749587d6f60cd1ee9a3,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "PLTR / USD",
                    priceId: 0x11a70634863ddffb71f2b11f2cff29f73f3db8f6d0b78c49f2b5f4ad36e885f0,
                    maxAllowedPriceLag: 120
                })
            );

            /****************************************
             * ETFs & INDICES
             ****************************************/

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "QQQ / USD",
                    priceId: 0x9695e2b96ea7b3859da9ed25b7a46a920a776e2fdae19a7bcfdf2b219230452d,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "SPY / USD",
                    priceId: 0x19e09bb805456ada3979a7d1cbb4b6d63babc3a0f8e8a9509f68afa5c4c11cd5,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "DIA / USD",
                    priceId: 0x57cff3a9a4d4c87b595a2d1bd1bac0240400a84677366d632ab838bbbe56f763,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "IWM / USD",
                    priceId: 0xeff690a187797aa225723345d4612abec0bf0cec1ae62347c0e7b1905d730879,
                    maxAllowedPriceLag: 120
                })
            );

            /****************************************
             * CURRENCIES
             ****************************************/

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "EUR / USD",
                    priceId: 0xa995d00bb36a63cef7fd2c287dc105fc8f3d93779f062f09551b0af3e81ec30b,
                    maxAllowedPriceLag: 120
                })
            );

            /****************************************
             * COMMODITIES - Energy
             ****************************************/

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "BRENT / USD",
                    priceId: 0x27f0d5e09a830083e5491795cac9ca521399c8f7fd56240d09484b14e614d57a,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "WTI / USD",
                    priceId: 0x925ca92ff005ae943c158e3563f59698ce7e75c5a8c8dd43303a0a154887b3e6,
                    maxAllowedPriceLag: 120
                })
            );

            /****************************************
             * COMMODITIES - Precious Metals
             ****************************************/

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "XAU / USD",
                    priceId: 0x765d2ba906dbc32ca17cc11f5310a89e9ee1f6420508c63861f2f8ba4ee34bb2,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "XAG / USD",
                    priceId: 0xf2fb02c32b055c805e7238d628e5e9dadef274376114eb1f012337cabe93871e,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "XPT / USD",
                    priceId: 0x398e4bbc7cbf89d6648c21e08019d878967677753b3096799595c78f805a34e5,
                    maxAllowedPriceLag: 120
                })
            );

            oracleConfigs.push(
                OracleConfig({
                    assetSymbol: "XPD / USD",
                    priceId: 0x80367e9664197f37d89a07a804dffd2101c479c7c4e8490501bc9d9e1e7f9021,
                    maxAllowedPriceLag: 120
                })
            );
        }
        // Add other chains as needed
        else {
            revert("Chain not configured");
        }
    }

    // ========================
    // DEPLOYMENT HELPERS
    // ========================

    /**
     * @notice Deploy a single Pyth oracle adapter
     */
    function _deployOracle(OracleConfig memory config) internal {
        console2.log("Deploying oracle for:", config.assetSymbol);
        console2.log("  Price ID:", vm.toString(config.priceId));
        console2.log("  Max Lag:", config.maxAllowedPriceLag, "seconds");

        // Deploy PythPriceFeed
        PythPriceFeed oracle =
            new PythPriceFeed(pythAddress, config.priceId, config.assetSymbol, config.maxAllowedPriceLag);

        console2.log("  Deployed at:", address(oracle));
        console2.log("");

        // Record deployment
        deployedOracles.push(
            DeployedOracle({
                assetSymbol: config.assetSymbol,
                deployedAddress: address(oracle),
                priceId: config.priceId,
                maxAllowedPriceLag: config.maxAllowedPriceLag
            })
        );
    }

    /**
     * @notice Save deployment addresses to JSON file
     * @dev Creates deployments/PythOracleAdapters.json with all deployed addresses
     */
    function _saveDeployments() internal {
        string memory json = "deployments";

        // Write metadata
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeAddress(json, "pythAddress", pythAddress);
        vm.serializeUint(json, "timestamp", block.timestamp);

        // Write each oracle deployment
        for (uint256 i = 0; i < deployedOracles.length; i++) {
            string memory oracleKey = string.concat("oracle_", vm.toString(i));
            string memory oracleJson = string.concat(json, "_", oracleKey);

            vm.serializeString(oracleJson, "assetSymbol", deployedOracles[i].assetSymbol);
            vm.serializeAddress(oracleJson, "address", deployedOracles[i].deployedAddress);
            vm.serializeBytes32(oracleJson, "priceId", deployedOracles[i].priceId);
            string memory oracleOutput =
                vm.serializeUint(oracleJson, "maxAllowedPriceLag", deployedOracles[i].maxAllowedPriceLag);

            // Add to main JSON
            vm.serializeString(json, deployedOracles[i].assetSymbol, oracleOutput);
        }

        // Write array of all oracle addresses for easy access
        address[] memory addresses = new address[](deployedOracles.length);
        string[] memory symbols = new string[](deployedOracles.length);
        for (uint256 i = 0; i < deployedOracles.length; i++) {
            addresses[i] = deployedOracles[i].deployedAddress;
            symbols[i] = deployedOracles[i].assetSymbol;
        }
        vm.serializeAddress(json, "allAddresses", addresses);
        string memory finalJson = vm.serializeString(json, "allSymbols", symbols);

        // Ensure deployments directory exists
        string memory deploymentsDir = "deployments";
        if (!vm.exists(deploymentsDir)) {
            vm.createDir(deploymentsDir, true);
        }

        // Write to file
        string memory fileName =
            string.concat(deploymentsDir, "/PythOracleAdapters_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);

        console2.log("Deployment addresses saved to:", fileName);
    }
}
