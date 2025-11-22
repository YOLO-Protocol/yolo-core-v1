// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script} from "@forge-std/Script.sol";
import {console2} from "@forge-std/console2.sol";
import {YoloHook} from "@yolo/core-v1/core/YoloHook.sol";
import {YoloHookViews} from "@yolo/core-v1/core/YoloHookViews.sol";
import {YoloOracle} from "@yolo/core-v1/core/YoloOracle.sol";
import {YoloSyntheticAsset} from "@yolo/core-v1/tokenization/YoloSyntheticAsset.sol";
import {StakedYoloUSD} from "@yolo/core-v1/tokenization/StakedYoloUSD.sol";
import {YLP} from "@yolo/core-v1/tokenization/YLP.sol";
import {ACLManager} from "@yolo/core-v1/access/ACLManager.sol";
import {IACLManager} from "@yolo/core-v1/interfaces/IACLManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IYoloHook} from "@yolo/core-v1/interfaces/IYoloHook.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IYoloOracle} from "@yolo/core-v1/interfaces/IYoloOracle.sol";

/**
 * @title Deploy01_FullProtocolCore
 * @author alvin@yolo.wtf
 * @notice Comprehensive deployment script for YOLO Protocol V1 (works on both testnet and mainnet)
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
contract Deploy01_FullProtocolCore is Script {
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
        address syntheticAssetImpl;
        address stakedYoloUSDImpl;
        address ylpImpl;
        address usy;
        address sUSY;
        address ylpVault;
        address usdc;
    }

    DeploymentAddresses public deployed;

    // ========================
    // CONFIGURATION
    // ========================

    address DEPLOYER;

    // Hook address flags for Uniswap V4
    uint160 constant HOOK_FLAGS = Hooks.ALL_HOOK_MASK;

    // Create2 deployer address
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Configure addresses per target network
    address constant USDC_ADDRESS = 0xF32B34Dfc110BF618a0Ff148afBAd8C3915c45aB; // FILL IN: USDC address on target network
    address constant POOL_MANAGER_ADDRESS = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408; // FILL IN: PoolManager address on target network
    address constant UNIVERSAL_ROUTER_ADDRESS = 0x492E6456D9528771018DeB9E87ef7750EF184104; // FILL IN: UniverswalRouter address on target network
    address constant POSITIONS_MANAGER_ADDRESS = 0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80; // FILL IN: PositionsManager address on target network
    address constant TREASURY = 0xf35a5A74aC460B700279D4118F950710abB73213; // FILL IN: Treasury address

    uint256 constant ANCHOR_A = 100; // StableSwap amplification coefficient: similar to A in curve math
    uint256 constant ANCHOR_FEE_BPS = 10; // 100 = 1% swap fee
    uint256 constant SYNTHETIC_FEE_BPS = 20; // 100 = 1% swap fee

    // ========================
    // MAIN DEPLOYMENT
    // ========================

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        DEPLOYER = deployer;

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

        // Step 1: Set treasury address
        deployed.treasury = TREASURY; // FILL IN: Treasury address
        require(deployed.treasury != address(0), "Treasury address not configured");
        console2.log("  [2.1] Treasury set to:", deployed.treasury);

        // Step 2: Deploy ACL Manager
        console2.log("  [2.2] Deploying ACLManager...");
        ACLManager aclManager = new ACLManager(); // Deployer as ACL admin
        deployed.aclManager = address(aclManager);
        console2.log("    ACLManager:", deployed.aclManager);

        // Step 3: Deploy Token Implementations
        console2.log("  [2.3] Deploying token implementations...");
        YoloSyntheticAsset syntheticAssetImpl = new YoloSyntheticAsset();
        StakedYoloUSD stakedYoloUSDImpl = new StakedYoloUSD();
        YLP ylpImpl = new YLP();
        deployed.syntheticAssetImpl = address(syntheticAssetImpl);
        deployed.stakedYoloUSDImpl = address(stakedYoloUSDImpl);
        deployed.ylpImpl = address(ylpImpl);
        console2.log("    YoloSyntheticAsset Implementation:", deployed.syntheticAssetImpl);
        console2.log("    StakedYoloUSD Implementation:", deployed.stakedYoloUSDImpl);
        console2.log("    YLP Implementation:", deployed.ylpImpl);

        // Step 4: Compute hook implementation address and deploy

        console2.log("  [2.4] Deploying YoloHook implementation & Proxy...");

        // 4.1: Deploy YoloHook implementation at computed address

        bytes memory yoloHookImplementationArgs =
            abi.encode(IPoolManager(deployed.poolManager), IACLManager(deployed.aclManager));
        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, HOOK_FLAGS, type(YoloHook).creationCode, yoloHookImplementationArgs);
        console2.log("    Computed YoloHook Implementation address:", hookAddress);

        YoloHook yoloHookImpl =
            new YoloHook{salt: salt}(IPoolManager(deployed.poolManager), IACLManager(deployed.aclManager));
        require(address(yoloHookImpl) == hookAddress, "YoloHook implementation address mismatch");
        deployed.yoloHookImpl = address(yoloHookImpl);
        console2.log("    YoloHook Implementation deployed at:", deployed.yoloHookImpl);

        // 4.2: Deploy YoloHook Proxy at computed address

        // Prepare proxy initialization data
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,uint256,uint256,uint256)",
            DEPLOYER, // IMPORTANT: serves as a placeholder, should set to YoloOracle address
            address(deployed.usdc),
            address(deployed.syntheticAssetImpl),
            address(deployed.stakedYoloUSDImpl),
            address(deployed.ylpImpl),
            deployed.treasury,
            ANCHOR_A,
            ANCHOR_FEE_BPS,
            SYNTHETIC_FEE_BPS
        );

        // Compute proxy address
        (address hookProxyAddress, bytes32 proxySalt) = HookMiner.find(
            CREATE2_DEPLOYER, HOOK_FLAGS, type(ERC1967Proxy).creationCode, abi.encode(deployed.yoloHookImpl, initData)
        );

        console2.log("    Computed YoloHook Proxy address:", hookProxyAddress);

        ERC1967Proxy yoloHookProxy = new ERC1967Proxy{salt: proxySalt}(deployed.yoloHookImpl, initData);
        require(address(yoloHookProxy) == hookProxyAddress, "YoloHook proxy address mismatch");
        deployed.yoloHookProxy = address(yoloHookProxy);
        console2.log("    YoloHook Proxy deployed at:", deployed.yoloHookProxy);

        // Step 5: Deploy and setup YoloHookViews
        console2.log("  [2.5] Deploying YoloHookViews...");
        YoloHookViews views = new YoloHookViews();
        deployed.yoloHookViews = address(views);
        YoloHook(deployed.yoloHookProxy).setViewImplementation(address(views));
        console2.log("    YoloHookViews deployed at:", deployed.yoloHookViews);

        // Step 6: Deploy YoloOracle with empty asset sources (will configure later)
        console2.log("  [2.6] Deploying YoloOracle...");
        address[] memory emptyAssets = new address[](0);
        address[] memory emptySources = new address[](0);
        YoloOracle oracle = new YoloOracle(
            IACLManager(deployed.aclManager),
            deployed.yoloHookProxy,
            IYoloHook(address(deployed.yoloHookProxy)).usy(),
            emptyAssets,
            emptySources
        );
        deployed.yoloOracle = address(oracle);
        console2.log("    YoloOracle:", deployed.yoloOracle);
        IYoloHook(deployed.yoloHookProxy).updateOracle(IYoloOracle(deployed.yoloOracle));
        console2.log("    YoloOracle set in YoloHook");

        // Step 7: Get deployed token addresses from proxy
        console2.log("  [2.7] Retrieving deployed token addresses...");
        IYoloHook yoloHook = IYoloHook(deployed.yoloHookProxy);
        deployed.usy = yoloHook.usy();
        deployed.sUSY = yoloHook.sUSY();
        deployed.ylpVault = yoloHook.ylpVault();
        console2.log("    USY:", deployed.usy);
        console2.log("    sUSY:", deployed.sUSY);
        console2.log("    YLP Vault:", deployed.ylpVault);
        console2.log("  [Layer 2] Complete!");
        console2.log("");
    }

    // ========================
    // HELPER FUNCTIONS
    // ========================

    function _saveDeployment() internal {
        string memory json = "deployment";

        // Layer 1: Uniswap V4
        vm.serializeAddress(json, "poolManager", deployed.poolManager);
        vm.serializeAddress(json, "universalRouter", deployed.universalRouter);
        vm.serializeAddress(json, "positionsManager", deployed.positionsManager);

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

        // Metadata
        vm.serializeUint(json, "chainId", block.chainid);
        string memory finalJson = vm.serializeUint(json, "timestamp", block.timestamp);

        // Write to file
        string memory fileName = string.concat("deployments/FullProtocol_", vm.toString(block.chainid), ".json");
        vm.writeJson(finalJson, fileName);

        console2.log("Deployment addresses saved to:", fileName);
    }
}
