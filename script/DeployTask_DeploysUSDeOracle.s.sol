// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {PythPriceFeed} from "@yolo/core-v1/oracles/PythPriceFeed.sol";
import {IYoloOracle} from "@yolo/core-v1/interfaces/IYoloOracle.sol";

contract DeployTask_DeploysUSDeOracle is Script {
    // ========================
    // CONFIGURATION
    // ========================
    address constant PYTH_CONTRACT = 0xA2aa501b19aff244D90cc15a4Cf739D2725B5729; // Base Sepolia
    address constant YOLO_ORACLE = 0x3ae085e154dB66bAC6721E062Ce30625b6F78D92;
    address constant S_USDE = 0x9aFE68A4A330e8eA3ebB997Fe4B27aa802b7F076;

    bytes32 constant PYTH_PRICE_ID = 0xca3ba9a619a4b3755c10ac7d5e760275aa95e9823d38a84fedd416856cdba37c;
    string constant PRICE_LABEL = "sUSDe / USD";
    uint32 constant MAX_PRICE_LAG = 300;

    PythPriceFeed public priceFeed;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("=================================");
        console2.log("Deploy sUSDe Pyth Price Feed");
        console2.log("=================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("Pyth:", PYTH_CONTRACT);
        console2.log("YoloOracle:", YOLO_ORACLE);
        console2.log("sUSDe:", S_USDE);
        console2.log("Price ID:", vm.toString(uint256(PYTH_PRICE_ID)));
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        priceFeed = new PythPriceFeed(PYTH_CONTRACT, PYTH_PRICE_ID, PRICE_LABEL, MAX_PRICE_LAG);
        console2.log("Deployed PythPriceFeed at:", address(priceFeed));

        address[] memory assets = new address[](1);
        address[] memory sources = new address[](1);
        assets[0] = S_USDE;
        sources[0] = address(priceFeed);
        IYoloOracle(YOLO_ORACLE).setAssetSources(assets, sources);
        console2.log("Updated YoloOracle source for sUSDe");

        vm.stopBroadcast();

        _saveDeployment();

        console2.log("");
        console2.log("Deployment Complete!");
        console2.log("=================================");
    }

    function _saveDeployment() internal {
        string memory json = "susdeOracle";
        vm.serializeAddress(json, "pyth", PYTH_CONTRACT);
        vm.serializeAddress(json, "yoloOracle", YOLO_ORACLE);
        vm.serializeAddress(json, "token", S_USDE);
        vm.serializeAddress(json, "priceFeed", address(priceFeed));
        vm.serializeBytes32(json, "priceId", PYTH_PRICE_ID);
        vm.serializeUint(json, "maxLag", MAX_PRICE_LAG);
        vm.serializeUint(json, "chainId", block.chainid);
        string memory finalJson = vm.serializeUint(json, "timestamp", block.timestamp);

        string memory dir = "deployments";
        if (!vm.exists(dir)) {
            vm.createDir(dir, true);
        }
        string memory fileName = string.concat(dir, "/sUSDe_PythOracle_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);
        console2.log("Saved deployment to:", fileName);
    }
}
