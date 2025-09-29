// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../tokenization/base/MintableIncentivizedERC20Upgradeable.sol";

/**
 * @title MockMintableIncentivizedERC20Upgradeable
 * @notice Mock implementation for testing upgradeable pattern
 */
contract MockMintableIncentivizedERC20Upgradeable is MintableIncentivizedERC20Upgradeable {
    // Note: No _disableInitializers() in mock for direct testing
    // Real implementation contracts should have it

    /**
     * @dev Initialize the mock token
     * @param yoloHook The YoloHook contract address
     * @param aclManager The ACLManager contract address
     * @param name_ The token name
     * @param symbol_ The token symbol
     * @param decimals_ The token decimals
     */
    function initialize(
        address yoloHook,
        address aclManager,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) external initializer {
        __MintableIncentivizedERC20_init(yoloHook, aclManager, name_, symbol_, decimals_);
    }

    /**
     * @notice Allows direct manipulation of additional data for testing
     * @param user The user address
     * @param data The additional data to set
     */
    function setAdditionalData(address user, uint128 data) external {
        _setAdditionalData(user, data);
    }
}