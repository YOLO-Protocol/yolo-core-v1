// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {MockERC20} from "@yolo/core-v1/mocks/MockERC20.sol";

/**
 * @title DeployTask_DeployMockUSDC
 * @author alvin@yolo.wtf
 * @notice Deployment script for MockUSDC token with automatic address recording
 * @dev Usage:
 *      1. Run: forge script script/DeployTask_DeployMockUSDC.sol:DeployTask_DeployMockUSDC --rpc-url <RPC_URL> --broadcast
 *      2. Deployed address is saved to deployments/MockUSDC_{chainId}.json
 */
contract DeployTask_DeployMockUSDC is Script {
    // ========================
    // CONSTANTS
    // ========================

    string constant TOKEN_NAME = "Mock USDC";
    string constant TOKEN_SYMBOL = "USDC";
    uint8 constant TOKEN_DECIMALS = 6;

    // ========================
    // STATE VARIABLES
    // ========================

    MockERC20 public mockUSDC;

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
        console2.log("Mock USDC Deployment");
        console2.log("=================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        // Deploy MockERC20 as USDC
        mockUSDC = new MockERC20(TOKEN_NAME, TOKEN_SYMBOL, TOKEN_DECIMALS);

        console2.log("Mock USDC deployed at:", address(mockUSDC));
        console2.log("  Name:", TOKEN_NAME);
        console2.log("  Symbol:", TOKEN_SYMBOL);
        console2.log("  Decimals:", TOKEN_DECIMALS);

        vm.stopBroadcast();

        // Save deployment address to JSON
        _saveDeployment();

        console2.log("");
        console2.log("=================================");
        console2.log("Deployment Complete!");
        console2.log("=================================");
    }

    // ========================
    // INTERNAL HELPERS
    // ========================

    /**
     * @notice Save deployment address to JSON file
     * @dev Creates deployments/MockUSDC_{chainId}.json with deployed address
     */
    function _saveDeployment() internal {
        string memory json = "deployment";

        // Write metadata
        vm.serializeString(json, "name", TOKEN_NAME);
        vm.serializeString(json, "symbol", TOKEN_SYMBOL);
        vm.serializeUint(json, "decimals", TOKEN_DECIMALS);
        vm.serializeAddress(json, "address", address(mockUSDC));
        vm.serializeUint(json, "chainId", block.chainid);
        string memory finalJson = vm.serializeUint(json, "timestamp", block.timestamp);

        // Ensure deployments directory exists
        string memory deploymentsDir = "deployments";
        if (!vm.exists(deploymentsDir)) {
            vm.createDir(deploymentsDir, true);
        }

        // Write to file
        string memory fileName = string.concat(deploymentsDir, "/MockUSDC_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);

        console2.log("");
        console2.log("Deployment address saved to:", fileName);
    }
}
