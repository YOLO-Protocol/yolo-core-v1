// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base01_DeployUniswapV4Pool} from "./Base01_DeployUniswapV4Pool.t.sol";
import {YoloHook} from "../../src/core/YoloHook.sol";
import {YoloHookViews} from "../../src/core/YoloHookViews.sol";
import {YoloSyntheticAsset} from "../../src/tokenization/YoloSyntheticAsset.sol";
import {StakedYoloUSD} from "../../src/tokenization/StakedYoloUSD.sol";
import {YLP} from "../../src/tokenization/YLP.sol";
import {ACLManager} from "../../src/access/ACLManager.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockYoloOracle} from "../../src/mocks/MockYoloOracle.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IYoloHook} from "../../src/interfaces/IYoloHook.sol";

/**
 * @title Base02_DeployYoloHook
 * @notice Base test contract that deploys YoloHook infrastructure
 * @dev Inherits Base01 (PoolManager) and adds YoloHook deployment
 *      All TestAction contracts should inherit from this to avoid duplication
 */
contract Base02_DeployYoloHook is Base01_DeployUniswapV4Pool {
    // ============================================================
    // STATE VARIABLES (PUBLIC)
    // ============================================================

    YoloHook public yoloHookProxy;
    YoloHook public yoloHookImpl;
    YoloHookViews public yoloHookViews;
    IYoloHook public yoloHook;
    ACLManager public aclManager;
    MockYoloOracle public oracle;
    YLP public ylpImpl;
    MockERC20 public usdc;
    YoloSyntheticAsset public usyImpl;
    StakedYoloUSD public sUSYImpl;
    address public usy;
    address public sUSY;
    address public ylpVault;
    address public treasury;

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public virtual override {
        super.setUp(); // Deploy PoolManager from Base01

        // Deploy mock infrastructure
        oracle = new MockYoloOracle();
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Get treasury address (customizable)
        treasury = _getTreasuryAddress();

        // Deploy ACL Manager
        address aclAdmin = _getACLAdmin();
        aclManager = new ACLManager();

        // Deploy implementations
        usyImpl = new YoloSyntheticAsset();
        sUSYImpl = new StakedYoloUSD();
        ylpImpl = new YLP();

        // Compute hook addresses using Uniswap V4 pattern
        address hookImplAddress = address(uint160(Hooks.ALL_HOOK_MASK));
        address hookProxyAddress = address(uint160(Hooks.ALL_HOOK_MASK << 1) + 1);

        // Deploy YoloHook implementation at specific address
        deployCodeTo("YoloHook.sol:YoloHook", abi.encode(address(manager), address(aclManager)), hookImplAddress);
        yoloHookImpl = YoloHook(hookImplAddress);

        // Get initialization parameters (customizable)
        (uint256 anchorA, uint256 anchorFee, uint256 syntheticFee) = _getYoloHookInitParams();

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSignature(
            "initialize(address,address,address,address,address,address,uint256,uint256,uint256)",
            address(oracle),
            address(usdc),
            address(usyImpl),
            address(sUSYImpl),
            address(ylpImpl),
            treasury,
            anchorA,
            anchorFee,
            syntheticFee
        );

        // Deploy UUPS proxy at specific address
        deployCodeTo("ERC1967Proxy.sol:ERC1967Proxy", abi.encode(hookImplAddress, initData), hookProxyAddress);
        yoloHookProxy = YoloHook(hookProxyAddress);

        // Deploy and setup YoloHookViews.sol on YoloHook
        yoloHookViews = new YoloHookViews();
        yoloHookProxy.setViewImplementation(address(yoloHookViews));

        // Convert to interface
        yoloHook = IYoloHook(address(yoloHookProxy));

        // Get deployed token addresses
        usy = IYoloHook(address(yoloHookProxy)).usy();
        sUSY = IYoloHook(address(yoloHookProxy)).sUSY();
        ylpVault = IYoloHook(address(yoloHookProxy)).ylpVault();
    }

    // ============================================================
    // CUSTOMIZATION HOOKS (VIRTUAL)
    // ============================================================

    /**
     * @notice Get YoloHook initialization parameters
     * @dev Override this function to customize YoloHook configuration
     * @return anchorAmplificationCoefficient StableSwap A parameter (default: 100)
     * @return anchorSwapFeeBps Anchor pool swap fee in bps (default: 10 = 0.1%)
     * @return syntheticSwapFeeBps Synthetic pool swap fee in bps (default: 10 = 0.1%)
     */
    function _getYoloHookInitParams()
        internal
        virtual
        returns (uint256 anchorAmplificationCoefficient, uint256 anchorSwapFeeBps, uint256 syntheticSwapFeeBps)
    {
        return (100, 10, 10);
    }

    /**
     * @notice Get treasury address for interest payments
     * @dev Override this function to use a custom treasury address
     * @return Treasury address (default: makeAddr("treasury"))
     */
    function _getTreasuryAddress() internal virtual returns (address) {
        return makeAddr("treasury");
    }

    /**
     * @notice Get ACL admin address
     * @dev Override this function to use a custom admin
     * @return ACL admin address (default: address(this))
     */
    function _getACLAdmin() internal virtual returns (address) {
        return address(this);
    }
}
