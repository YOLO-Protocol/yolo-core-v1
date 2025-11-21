// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";

/**
 * @title DeployTask_FullProtocol
 * @author alvin@yolo.wtf
 * @notice Comprehensive deployment script for YOLO Protocol V1 on testnet
 * @dev Follows the 4-layer deployment pattern from test/base/:
 *      1. Uniswap V4 Infrastructure (PoolManager, routers)
 *      2. Core YOLO Components (ACL, tokens, hook proxy)
 *      3. Collateral + Oracles + Initial Liquidity
 *      4. Trade Infrastructure (TradeOrchestrator, perp config)
 *
 * Usage:
 *   forge script script/DeployTask_FullProtocol.sol:DeployTask_FullProtocol \
 *     --rpc-url $RPC_URL --broadcast -vvv
 *
 * Prerequisites:
 *   - deployments/MockUSDC_{chainId}.json (from DeployTask_DeployMockUSDC)
 *   - deployments/PythOracleAdapters_{chainId}.json (from DeployTask_PythOracleAdapter)
 *
 * Output:
 *   - deployments/FullProtocol_{chainId}.json (all deployed addresses)
 */
contract DeployTask_FullProtocol is Script {
    // ========================
    // DEPLOYMENT STATE
    // ========================

    struct DeploymentAddresses {
        // Layer 1: Uniswap V4
        address poolManager;
        address universalRouter;
        address positionsManager;
        // Layer 2: Core YOLO
        address aclManager;
        address treasury;
        address yoloHookImpl;
        address yoloHookProxy;
        address yoloHookViews;
        address yoloOracle;
        address usy;
        address sUSY;
        address ylpVault;
        address usdc;
        // Layer 3: Collateral tokens
        address usdt;
        address dai;
        address weth;
        address wbtc;
        address ptUsde;
        address sUsde;
        // Layer 4: Trade infrastructure
        address tradeOrchestrator;
    }

    DeploymentAddresses public deployed;

    // ========================
    // CONFIGURATION
    // ========================

    // Manually configure USDC address for your chain
    address constant USDC_ADDRESS = 0xF32B34Dfc110BF618a0Ff148afBAd8C3915c45aB; // FILL IN: USDC address on target network
    address constant POOL_MANAGER_ADDRESS = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408; // FILL IN: PoolManager address on target network
    address constant UNIVERSAL_ROUTER_ADDRESS = 0x492E6456D9528771018DeB9E87ef7750EF184104; // FILL IN: UniverswalRouter address on target network
    address constant POSITIONS_MANAGER_ADDRESS = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80; // FILL IN: ModifyLiquidityRouter address on target network

    uint256 constant ANCHOR_A = 100; // StableSwap amplification coefficient: similar to A in curve math
    uint256 constant ANCHOR_FEE_BPS = 10; // 100 = 1% swap fee
    uint256 constant SYNTHETIC_FEE_BPS = 20; // 100 = 1% swap fee

    // ========================
    // MAIN DEPLOYMENT
    // ========================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console2.log("============================================================");
        console2.log("YOLO Protocol V1 - Full Testnet Deployment");
        console2.log("============================================================");
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);
        console2.log("");

        // Validate USDC configuration
        require(USDC_ADDRESS != address(0), "USDC_ADDRESS not configured");
        deployed.usdc = USDC_ADDRESS;
        console2.log("Using USDC at:", USDC_ADDRESS);

        vm.startBroadcast(deployerPrivateKey);

        // Layer 1: Uniswap V4 (use existing deployment or deploy fresh)
        _setupUniswapV4Infrastructure();

        // Layer 2: Core YOLO components
        _deployCoreYOLOComponents();

        // Layer 3: Collateral tokens + oracle configuration
        _deployCollateralAndOracles();

        // Layer 4: Bootstrap initial liquidity
        _bootstrapInitialLiquidity();

        // Layer 5: Trade infrastructure
        _deployTradeInfrastructure();

        vm.stopBroadcast();

        // Save all deployment addresses
        _saveDeployment();

        console2.log("");
        console2.log("============================================================");
        console2.log("Deployment Complete!");
        console2.log("============================================================");
    }

    // ========================
    // LAYER 1: UNISWAP V4
    // ========================

    function _setupUniswapV4Infrastructure() internal {
        console2.log("[Layer 1] Deploying Uniswap V4 Infrastructure...");

        // TODO: Check if canonical V4 deployment exists on this chain
        // For now, we'll note that this needs manual configuration
        console2.log("  NOTE: Using existing Uniswap V4 deployment");
        console2.log("  TODO: Configure poolManager address for", block.chainid);

        // Base Sepolia canonical addresses (example)
        deployed.poolManager = POOL_MANAGER_ADDRESS; // FILL IN: Canonical PoolManager
        deployed.universalRouter = UNIVERSAL_ROUTER_ADDRESS; // FILL IN: SwapRouter
        deployed.positionsManager = POSITIONS_MANAGER_ADDRESS; // FILL IN: ModifyLiquidityRouter

        require(deployed.poolManager != address(0), "PoolManager not configured for this chain");
        console2.log("  PoolManager:", deployed.poolManager);
        console2.log("");
    }

    // ========================
    // LAYER 2: CORE YOLO
    // ========================

    function _deployCoreYOLOComponents() internal {
        console2.log("[Layer 2] Deploying Core YOLO Components...");
        console2.log("  TODO: Implement core component deployment");
        console2.log("  - ACLManager");
        console2.log("  - YoloHook (impl + proxy)");
        console2.log("  - YoloHookViews");
        console2.log("  - Token implementations (USY, sUSY, YLP)");
        console2.log("");
    }

    // ========================
    // LAYER 3: COLLATERAL + ORACLES
    // ========================

    function _deployCollateralAndOracles() internal {
        console2.log("[Layer 3] Deploying Collateral Tokens & Configuring Oracles...");
        console2.log("  TODO: Deploy mock collateral tokens");
        console2.log("  TODO: Register Pyth price feeds in YoloOracle");
        console2.log("  TODO: Create synthetic asset proxies");
        console2.log("  TODO: Configure lending pairs");
        console2.log("");
    }

    // ========================
    // LAYER 4: BOOTSTRAP LIQUIDITY
    // ========================

    function _bootstrapInitialLiquidity() internal {
        console2.log("[Layer 4] Bootstrapping Initial Liquidity...");
        console2.log("  TODO: Mint 1M USY to YLP vault");
        console2.log("  TODO: Add USY/USDC anchor pool liquidity");
        console2.log("  TODO: Mint sUSY LP tokens");
        console2.log("");
    }

    // ========================
    // LAYER 5: TRADE INFRASTRUCTURE
    // ========================

    function _deployTradeInfrastructure() internal {
        console2.log("[Layer 5] Deploying Trade Infrastructure...");
        console2.log("  TODO: Deploy TradeOrchestrator");
        console2.log("  TODO: Grant ACL roles (TRADE_OPERATOR, TRADE_ADMIN, TRADE_KEEPER)");
        console2.log("  TODO: Configure perp markets (yNVDA, yETH, etc.)");
        console2.log("");
    }

    // ========================
    // HELPER FUNCTIONS
    // ========================

    function _saveDeployment() internal {
        string memory json = "deployment";

        // Layer 1: Uniswap V4
        vm.serializeAddress(json, "poolManager", deployed.poolManager);
        vm.serializeAddress(json, "universol", deployed.swapRouter);
        vm.serializeAddress(json, "modifyLiquidityRouter", deployed.modifyLiquidityRouter);

        // Layer 2: Core YOLO
        vm.serializeAddress(json, "aclManager", deployed.aclManager);
        vm.serializeAddress(json, "treasury", deployed.treasury);
        vm.serializeAddress(json, "yoloHookImpl", deployed.yoloHookImpl);
        vm.serializeAddress(json, "yoloHookProxy", deployed.yoloHookProxy);
        vm.serializeAddress(json, "yoloHookViews", deployed.yoloHookViews);
        vm.serializeAddress(json, "yoloOracle", deployed.yoloOracle);
        vm.serializeAddress(json, "usy", deployed.usy);
        vm.serializeAddress(json, "sUSY", deployed.sUSY);
        vm.serializeAddress(json, "ylpVault", deployed.ylpVault);
        vm.serializeAddress(json, "usdc", deployed.usdc);

        // Layer 3: Collateral
        vm.serializeAddress(json, "usdt", deployed.usdt);
        vm.serializeAddress(json, "dai", deployed.dai);
        vm.serializeAddress(json, "weth", deployed.weth);
        vm.serializeAddress(json, "wbtc", deployed.wbtc);
        vm.serializeAddress(json, "ptUsde", deployed.ptUsde);
        vm.serializeAddress(json, "sUsde", deployed.sUsde);

        // Layer 4: Trade
        vm.serializeAddress(json, "tradeOrchestrator", deployed.tradeOrchestrator);

        // Metadata
        vm.serializeUint(json, "chainId", block.chainid);
        string memory finalJson = vm.serializeUint(json, "timestamp", block.timestamp);

        // Write to file
        string memory fileName = string.concat("deployments/FullProtocol_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);

        console2.log("Deployment addresses saved to:", fileName);
    }
}
