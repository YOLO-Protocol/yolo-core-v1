// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AppStorage} from "../core/YoloHookStorage.sol";
import {DataTypes} from "./DataTypes.sol";
import {IACLManager} from "../interfaces/IACLManager.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/**
 * @title BootstrapModule
 * @author alvin@yolo.wtf
 * @notice Handles one-time deployment/bootstrap logic for YoloHook
 */
library BootstrapModule {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /**
     * @notice Execute full protocol bootstrap
     * @param s AppStorage reference
     * @param poolManager Uniswap V4 PoolManager instance
     * @param aclManager ACL manager instance
     * @param yoloHook Address of the YoloHook proxy (hook)
     * @param yoloOracle Oracle instance
     * @param usdc USDC token address
     * @param usyImplementation Yolo USD implementation address
     * @param sUSYImplementation sUSY implementation address
     * @param ylpVaultImplementation Placeholder YLP vault implementation
     * @param treasury Treasury address
     * @param anchorAmplificationCoefficient StableSwap amplification coefficient
     * @param anchorSwapFeeBps Anchor pool swap fee (bps)
     * @param syntheticSwapFeeBps Synthetic pool swap fee (bps)
     */
    function initialize(
        AppStorage storage s,
        IPoolManager poolManager,
        IACLManager aclManager,
        address yoloHook,
        IYoloOracle yoloOracle,
        address usdc,
        address usyImplementation,
        address sUSYImplementation,
        address ylpVaultImplementation,
        address treasury,
        uint256 anchorAmplificationCoefficient,
        uint256 anchorSwapFeeBps,
        uint256 syntheticSwapFeeBps
    ) external {
        // Persist global configuration
        s.yoloOracle = yoloOracle;
        s.usdc = usdc;
        s.treasury = treasury;
        s.ACL_MANAGER = address(aclManager);
        s.usdcDecimals = IERC20Metadata(usdc).decimals();
        s.usdcScaleUp = 10 ** (18 - s.usdcDecimals);
        s.anchorAmplificationCoefficient = anchorAmplificationCoefficient;
        s.anchorSwapFeeBps = anchorSwapFeeBps;
        s.syntheticSwapFeeBps = syntheticSwapFeeBps;
        s.flashLoanFeeBps = 9; // default flash-loan fee

        // Deploy USY via UUPS proxy
        bytes memory usyInitData = abi.encodeWithSignature(
            "initialize(address,address,string,string,uint8,address,address,address,uint256)",
            yoloHook,
            address(aclManager),
            "Yolo USD",
            "USY",
            uint8(18),
            address(0),
            address(yoloOracle),
            ylpVaultImplementation,
            uint256(0)
        );
        address usyProxy = address(new ERC1967Proxy(usyImplementation, usyInitData));
        s.usy = usyProxy;
        s._isYoloAsset[usyProxy] = true;
        s._yoloAssets.push(usyProxy);
        s._assetConfigs[usyProxy] = DataTypes.AssetConfiguration({
            syntheticToken: usyProxy,
            underlyingAsset: address(0),
            oracleSource: address(0),
            maxSupply: 0,
            maxFlashLoanAmount: type(uint256).max,
            isActive: true,
            createdAt: block.timestamp
        });

        // Approvals for settlement
        IERC20(usdc).approve(address(poolManager), type(uint256).max);
        IERC20(usyProxy).approve(address(poolManager), type(uint256).max);

        // Create anchor pool key and initialize at 1:1
        bool usdcIs0 = usdc < usyProxy;
        Currency currency0 = Currency.wrap(usdcIs0 ? usdc : usyProxy);
        Currency currency1 = Currency.wrap(usdcIs0 ? usyProxy : usdc);
        PoolKey memory anchorPoolKey =
            PoolKey({currency0: currency0, currency1: currency1, fee: 0, tickSpacing: 60, hooks: IHooks(yoloHook)});
        poolManager.initialize(anchorPoolKey, uint160(1) << 96);

        bytes32 anchorPoolId = PoolId.unwrap(anchorPoolKey.toId());
        s._anchorPoolKey = anchorPoolId;
        s._poolConfigs[anchorPoolId] = DataTypes.PoolConfiguration({
            poolKey: anchorPoolKey,
            isAnchorPool: true,
            isSyntheticPool: false,
            token0: Currency.unwrap(currency0),
            token1: Currency.unwrap(currency1),
            createdAt: block.timestamp
        });

        // Deploy sUSY receipt token
        bytes memory sUSYInitData = abi.encodeWithSignature("initialize(address)", yoloHook);
        address sUSYProxy = address(new ERC1967Proxy(sUSYImplementation, sUSYInitData));
        s.sUSY = sUSYProxy;

        // Initialize pause state & YLP placeholder
        s._paused = false;
        s.ylpVault = ylpVaultImplementation;
    }
}
