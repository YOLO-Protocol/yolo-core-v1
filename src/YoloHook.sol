// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title YoloHook V1
 * @notice YOLO Protocol V1 - Yield-Optimized Leverage Onchain Hook
 * @dev Bare bones implementation with minimal inheritance structure
 */
contract YoloHook is BaseHook, ReentrancyGuard, Ownable, Pausable {
    
    /**
     * @notice Constructor to initialize the YoloHook with the V4 Pool Manager
     * @param _poolManager Address of the Uniswap V4 Pool Manager contract
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) Ownable(msg.sender) {}

    /**
     * @notice Returns the permissions for this hook
     * @dev Enable all hook permissions for future upgradability
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: true,
            afterDonate: true,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }
}