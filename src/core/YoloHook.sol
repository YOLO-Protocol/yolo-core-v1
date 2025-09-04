// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title YoloHook
 * @author alvin@yolo.wtf
 * @notice Main hook contract for YOLO Protocol V1 - Yield-Optimized Leverage Onchain
 * @dev Bare bones V1 implementation with minimal inheritance structure
 *      - Uniswap V4 hook with all permissions enabled
 *      - Reentrancy protection and pausable functionality
 *      - Foundation for V1 modular architecture
 */
contract YoloHook is BaseHook, ReentrancyGuard, Ownable, Pausable {
    // ========================
    // CONSTRUCTOR
    // ========================

    /**
     * @notice Initialize YoloHook with Uniswap V4 Pool Manager
     * @param _poolManager Address of the Uniswap V4 Pool Manager contract
     */
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) Ownable(msg.sender) {}

    // ========================
    // EXTERNAL VIEW FUNCTIONS
    // ========================

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
