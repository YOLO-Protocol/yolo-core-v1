// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {MockERC20} from "@yolo/core-v1/mocks/MockERC20.sol";
import {MockPriceOracle} from "@yolo/core-v1/mocks/MockPriceOracle.sol";

/**
 * @title DeployTask_DeployMockAssetsAndOracles
 * @author alvin@yolo.wtf
 * @notice Deployment script for mock collateral assets and their price oracles
 * @dev Usage:
 *      1. Configure asset parameters in _configureAssets()
 *      2. Run: forge script script/DeployTask_DeployMockAssetsAndOracles.s.sol:DeployTask_DeployMockAssetsAndOracles --rpc-url $RPC_URL --broadcast
 *      3. Deployed addresses are saved to deployments/MockAssetsAndOracles_{chainId}.json
 *
 * Note: If oracleAddress is provided (non-zero), oracle deployment is skipped
 */
contract DeployTask_DeployMockAssetsAndOracles is Script {
    // ========================
    // TYPES
    // ========================

    /**
     * @notice Configuration for a single mock asset and its oracle
     * @param name Token name (e.g., "Wrapped Ether")
     * @param symbol Token symbol (e.g., "WETH")
     * @param decimals Token decimals (e.g., 18 for WETH, 8 for WBTC)
     * @param initialPrice Initial oracle price in USD (8 decimals, e.g., 2000_00000000 for $2000)
     * @param oracleAddress Existing oracle address (use address(0) to deploy new oracle)
     */
    struct AssetConfig {
        string name;
        string symbol;
        uint8 decimals;
        int256 initialPrice;
        address oracleAddress;
    }

    /**
     * @notice Deployment result for a single asset
     */
    struct DeployedAsset {
        string name;
        string symbol;
        address assetAddress;
        address oracleAddress;
        uint8 decimals;
        int256 initialPrice;
    }

    // ========================
    // STATE VARIABLES
    // ========================

    /// @notice Array of asset configurations to deploy
    AssetConfig[] public assetConfigs;

    /// @notice Array of deployed assets and oracles
    DeployedAsset[] public deployedAssets;

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

        console2.log("=================================================");
        console2.log("Mock Assets & Oracles Deployment");
        console2.log("=================================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        // Configure assets for the current chain
        _configureAssets();

        // Validate configuration
        require(assetConfigs.length > 0, "No asset configurations found");

        console2.log("Assets to deploy:", assetConfigs.length);
        console2.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy each asset and oracle
        for (uint256 i = 0; i < assetConfigs.length; i++) {
            _deployAssetAndOracle(assetConfigs[i]);
        }

        vm.stopBroadcast();

        // Save deployment addresses to JSON
        _saveDeployments();

        console2.log("");
        console2.log("=================================================");
        console2.log("Deployment Complete!");
        console2.log("=================================================");
    }

    // ========================
    // ASSET CONFIGURATION
    // ========================

    /**
     * @notice Configure asset parameters based on chain ID
     * @dev Modify this function to add/remove assets for deployment
     *
     * To add a new asset:
     * 1. Add a new AssetConfig to the assetConfigs array
     * 2. Set name, symbol, decimals, initialPrice (8 decimals USD)
     * 3. Set oracleAddress to address(0) to deploy new oracle, or provide existing oracle address
     */
    function _configureAssets() internal {
        // Base Sepolia Testnet (Chain ID: 84532)
        if (block.chainid == 84532) {
            // WETH - Wrapped Ether
            assetConfigs.push(
                AssetConfig({
                    name: "Wrapped Ether",
                    symbol: "WETH",
                    decimals: 18,
                    initialPrice: 2733_11020583,
                    oracleAddress: 0xE3d179F77A6c514C374A8De1B3AabB1CCC8E3140
                })
            );

            // WBTC - Wrapped Bitcoin
            assetConfigs.push(
                AssetConfig({
                    name: "Wrapped Bitcoin",
                    symbol: "WBTC",
                    decimals: 8,
                    initialPrice: 84153_80372409,
                    oracleAddress: 0x2f09E672459cCF2B20A4C621aFA756CC0b9D3B8D // Deploy new oracle
                })
            );

            // SOL - Solana
            assetConfigs.push(
                AssetConfig({
                    name: "Solana",
                    symbol: "SOL",
                    decimals: 18,
                    initialPrice: 1_2634881081,
                    oracleAddress: 0x41De0a331EA729F23F1c428F88e4c1Ac2d313De4 // Deploy new oracle
                })
            );

            // sUSDe - Staked USDe (Ethena)
            assetConfigs.push(
                AssetConfig({
                    name: "Staked USDe",
                    symbol: "sUSDe",
                    decimals: 18,
                    initialPrice: 1_20000000,
                    oracleAddress: address(0)
                })
            );
        }
        // Base Mainnet (Chain ID: 8453)
        else if (block.chainid == 8453) {
            revert("Mainnet configuration not set - please configure real asset addresses");
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
     * @notice Deploy a single asset and its oracle
     * @param config Asset configuration
     */
    function _deployAssetAndOracle(AssetConfig memory config) internal {
        console2.log("--------------------------------------------------");
        console2.log("Deploying:", config.symbol);
        console2.log("--------------------------------------------------");

        // Deploy MockERC20 token
        MockERC20 asset = new MockERC20(config.name, config.symbol, config.decimals);
        console2.log("  Token deployed at:", address(asset));
        console2.log("    Name:", config.name);
        console2.log("    Symbol:", config.symbol);
        console2.log("    Decimals:", config.decimals);

        // Deploy or use existing oracle
        address oracleAddress;
        if (config.oracleAddress == address(0)) {
            // Deploy new MockPriceOracle
            string memory oracleDescription = string.concat(config.symbol, " / USD");
            MockPriceOracle oracle = new MockPriceOracle(config.initialPrice, oracleDescription);
            oracleAddress = address(oracle);
            console2.log("  Oracle deployed at:", oracleAddress);
            console2.log("    Description:", oracleDescription);
            console2.log("    Initial Price: $", _formatPrice(config.initialPrice));
        } else {
            // Use existing oracle
            oracleAddress = config.oracleAddress;
            console2.log("  Using existing oracle:", oracleAddress);
        }

        console2.log("");

        // Record deployment
        deployedAssets.push(
            DeployedAsset({
                name: config.name,
                symbol: config.symbol,
                assetAddress: address(asset),
                oracleAddress: oracleAddress,
                decimals: config.decimals,
                initialPrice: config.initialPrice
            })
        );
    }

    /**
     * @notice Format price for display (8 decimals to readable string)
     * @param price Price with 8 decimals
     * @return Formatted price string
     */
    function _formatPrice(int256 price) internal pure returns (string memory) {
        uint256 absPrice = uint256(price);
        uint256 dollars = absPrice / 1e8;
        uint256 cents = (absPrice % 1e8) / 1e6;
        return string.concat(vm.toString(dollars), ".", _padZeros(cents, 2));
    }

    /**
     * @notice Pad number with leading zeros
     */
    function _padZeros(uint256 num, uint256 targetLength) internal pure returns (string memory) {
        string memory numStr = vm.toString(num);
        bytes memory numBytes = bytes(numStr);
        if (numBytes.length >= targetLength) return numStr;

        bytes memory result = new bytes(targetLength);
        uint256 padding = targetLength - numBytes.length;
        for (uint256 i = 0; i < padding; i++) {
            result[i] = "0";
        }
        for (uint256 i = 0; i < numBytes.length; i++) {
            result[padding + i] = numBytes[i];
        }
        return string(result);
    }

    // ========================
    // JSON SERIALIZATION
    // ========================

    /**
     * @notice Save deployment addresses to JSON file
     * @dev Creates deployments/MockAssetsAndOracles_{chainId}.json
     */
    function _saveDeployments() internal {
        string memory json = "deployment";

        // Write metadata
        vm.serializeUint(json, "chainId", block.chainid);
        vm.serializeUint(json, "timestamp", block.timestamp);
        vm.serializeUint(json, "assetCount", deployedAssets.length);

        // Write each asset deployment
        for (uint256 i = 0; i < deployedAssets.length; i++) {
            string memory assetKey = deployedAssets[i].symbol;
            string memory assetJson = string.concat(json, "_", assetKey);

            vm.serializeString(assetJson, "name", deployedAssets[i].name);
            vm.serializeString(assetJson, "symbol", deployedAssets[i].symbol);
            vm.serializeAddress(assetJson, "assetAddress", deployedAssets[i].assetAddress);
            vm.serializeAddress(assetJson, "oracleAddress", deployedAssets[i].oracleAddress);
            vm.serializeUint(assetJson, "decimals", deployedAssets[i].decimals);
            string memory assetOutput = vm.serializeInt(assetJson, "initialPrice", deployedAssets[i].initialPrice);

            // Add to main JSON
            vm.serializeString(json, assetKey, assetOutput);
        }

        // Write array of all asset addresses for easy access
        address[] memory assetAddresses = new address[](deployedAssets.length);
        address[] memory oracleAddresses = new address[](deployedAssets.length);
        string[] memory symbols = new string[](deployedAssets.length);

        for (uint256 i = 0; i < deployedAssets.length; i++) {
            assetAddresses[i] = deployedAssets[i].assetAddress;
            oracleAddresses[i] = deployedAssets[i].oracleAddress;
            symbols[i] = deployedAssets[i].symbol;
        }

        vm.serializeAddress(json, "allAssetAddresses", assetAddresses);
        vm.serializeAddress(json, "allOracleAddresses", oracleAddresses);
        string memory finalJson = vm.serializeString(json, "allSymbols", symbols);

        // Ensure deployments directory exists
        string memory deploymentsDir = "deployments";
        if (!vm.exists(deploymentsDir)) {
            vm.createDir(deploymentsDir, true);
        }

        // Write to file
        string memory fileName =
            string.concat(deploymentsDir, "/MockAssetsAndOracles_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);

        console2.log("Deployment addresses saved to:", fileName);
    }
}
