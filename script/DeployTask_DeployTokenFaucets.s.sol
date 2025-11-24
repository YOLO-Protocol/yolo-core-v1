// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "@yolo/core-v1/mocks/MockERC20.sol";
import {TokenFaucet} from "@yolo/core-v1/mocks/TokenFaucet.sol";
import {IYoloHook} from "@yolo/core-v1/interfaces/IYoloHook.sol";

contract DeployTask_DeployTokenFaucets is Script {
    // ========================
    // CONFIGURATION - ADDRESSES
    // ========================
    address constant WBTC = 0x47A94537Cd5169dD0D7E8B86B65372794C9Ff8e8;
    address constant WETH = 0x119000192D6C783d355aC50320670F8140D051d0;
    address constant USDC = 0xF32B34Dfc110BF618a0Ff148afBAd8C3915c45aB;
    address constant S_USDE = 0x9aFE68A4A330e8eA3ebB997Fe4B27aa802b7F076;
    address constant USY = 0x50108c7CCdfDf341baEC1c1f4A94B42A764628EF;
    address constant YOLO_HOOK_PROXY = 0x033ea50dEaa8b064958fC40E34F994C154D27FFf;

    // ========================
    // CONFIGURATION - FUNDING AMOUNTS (RAW TOKEN UNITS)
    // ========================
    uint256 constant WBTC_INITIAL_FUNDING = 500 * 1e8; // 500 WBTC
    uint256 constant WBTC_DAILY_CLAIM = 1e6; // 0.01 WBTC

    uint256 constant WETH_INITIAL_FUNDING = 10_000 * 1e18; // 10k WETH
    uint256 constant WETH_DAILY_CLAIM = 1e17; // 0.1 WETH

    uint256 constant USDC_INITIAL_FUNDING = 100_000_000 * 1e6; // 100M USDC
    uint256 constant USDC_DAILY_CLAIM = 1_000 * 1e6; // 1k USDC

    uint256 constant S_USDE_INITIAL_FUNDING = 10_000_000 * 1e18; // 10M sUSDe
    uint256 constant S_USDE_DAILY_CLAIM = 500 * 1e18; // 500 sUSDe

    uint256 constant USY_INITIAL_FUNDING = 5_000_000 * 1e18; // 5M USY
    uint256 constant USY_DAILY_CLAIM = 1_000 * 1e18; // 1k USY

    uint256 constant USY_COLLATERAL_WBTC = 100 * 1e8; // 100 WBTC collateral for borrow

    // ========================
    // STRUCTS
    // ========================
    struct FaucetInfo {
        string label;
        address token;
        address faucet;
        uint256 dispensePerDay;
        uint256 initialFunding;
    }

    // ========================
    // STATE
    // ========================
    address public deployer;

    // ========================
    // MAIN EXECUTION
    // ========================
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);

        console2.log("============================================================");
        console2.log("YOLO Protocol V1 - Deploy Token Faucets");
        console2.log("============================================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPrivateKey);

        FaucetInfo[] memory faucets = new FaucetInfo[](5);
        uint256 idx;

        faucets[idx++] = _deployMockFaucet("WBTC", WBTC, WBTC_INITIAL_FUNDING, WBTC_DAILY_CLAIM);
        faucets[idx++] = _deployMockFaucet("WETH", WETH, WETH_INITIAL_FUNDING, WETH_DAILY_CLAIM);
        faucets[idx++] = _deployMockFaucet("USDC", USDC, USDC_INITIAL_FUNDING, USDC_DAILY_CLAIM);
        faucets[idx++] = _deployMockFaucet("sUSDe", S_USDE, S_USDE_INITIAL_FUNDING, S_USDE_DAILY_CLAIM);
        faucets[idx++] = _deployUsyFaucet();

        vm.stopBroadcast();

        _saveDeployment(faucets);

        console2.log("");
        console2.log("============================================================");
        console2.log("Token Faucet Deployment Complete!");
        console2.log("============================================================");
    }

    // ========================
    // INTERNAL HELPERS
    // ========================

    function _deployMockFaucet(string memory label, address token, uint256 fundingAmount, uint256 dispensePerDay)
        internal
        returns (FaucetInfo memory info)
    {
        console2.log(string.concat("[", label, "] Deploying faucet..."));
        TokenFaucet faucet = new TokenFaucet(token, dispensePerDay);
        console2.log("  Faucet:", address(faucet));

        // Mint mock tokens for funding and deposit them into the faucet
        MockERC20(token).mint(deployer, fundingAmount);
        console2.log("  Minted", fundingAmount, "raw units to deployer");

        IERC20(token).approve(address(faucet), fundingAmount);
        faucet.deposit(fundingAmount);
        console2.log("  Deposited", fundingAmount, "raw units into faucet");
        console2.log("  Daily dispense (raw):", dispensePerDay);
        console2.log("");

        info = FaucetInfo({
            label: label,
            token: token,
            faucet: address(faucet),
            dispensePerDay: dispensePerDay,
            initialFunding: fundingAmount
        });
    }

    function _deployUsyFaucet() internal returns (FaucetInfo memory info) {
        console2.log("[USY] Deploying faucet...");
        TokenFaucet faucet = new TokenFaucet(USY, USY_DAILY_CLAIM);
        console2.log("  Faucet:", address(faucet));

        // Mint WBTC collateral and deposit into YoloHook to borrow USY
        MockERC20(WBTC).mint(deployer, USY_COLLATERAL_WBTC);
        console2.log("  Minted collateral WBTC (raw):", USY_COLLATERAL_WBTC);

        IERC20(WBTC).approve(YOLO_HOOK_PROXY, USY_COLLATERAL_WBTC);
        console2.log("  Approved YoloHook for WBTC collateral");

        IYoloHook(YOLO_HOOK_PROXY).borrow(USY, USY_INITIAL_FUNDING, WBTC, USY_COLLATERAL_WBTC, deployer);
        console2.log("  Borrowed USY (raw):", USY_INITIAL_FUNDING);

        IERC20(USY).approve(address(faucet), USY_INITIAL_FUNDING);
        faucet.deposit(USY_INITIAL_FUNDING);
        console2.log("  Deposited USY into faucet");
        console2.log("  Daily dispense (raw):", USY_DAILY_CLAIM);
        console2.log("");

        info = FaucetInfo({
            label: "USY",
            token: USY,
            faucet: address(faucet),
            dispensePerDay: USY_DAILY_CLAIM,
            initialFunding: USY_INITIAL_FUNDING
        });
    }

    function _saveDeployment(FaucetInfo[] memory faucets) internal {
        string memory root = "tokenFaucets";
        vm.serializeUint(root, "chainId", block.chainid);

        for (uint256 i = 0; i < faucets.length; i++) {
            string memory entryKey = string.concat("faucet_", faucets[i].label);
            string memory faucetJson = vm.serializeString(entryKey, "label", faucets[i].label);
            faucetJson = vm.serializeAddress(entryKey, "token", faucets[i].token);
            faucetJson = vm.serializeAddress(entryKey, "faucet", faucets[i].faucet);
            faucetJson = vm.serializeUint(entryKey, "dispensePerDay", faucets[i].dispensePerDay);
            faucetJson = vm.serializeUint(entryKey, "initialFunding", faucets[i].initialFunding);
            vm.serializeString(root, entryKey, faucetJson);
        }

        string memory finalJson = vm.serializeUint(root, "timestamp", block.timestamp);

        string memory deploymentsDir = "deployments";
        if (!vm.exists(deploymentsDir)) {
            vm.createDir(deploymentsDir, true);
        }

        string memory fileName = string.concat(deploymentsDir, "/TokenFaucets_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);
        console2.log("Deployment summary saved to:", fileName);
    }
}
