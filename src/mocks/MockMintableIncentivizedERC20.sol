// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../tokenization/base/MintableIncentivizedERC20.sol";

/**
 * @title MockMintableIncentivizedERC20
 * @author alvin@yolo.wtf
 * @notice Concrete implementation of MintableIncentivizedERC20 for testing
 * @dev Non-abstract version for testing purposes
 */
contract MockMintableIncentivizedERC20 is MintableIncentivizedERC20 {
    /**
     * @dev Constructor passes all parameters to parent
     * @param yoloHook The YoloHook contract address
     * @param aclManager The ACLManager contract address
     * @param name_ The token name
     * @param symbol_ The token symbol
     * @param decimals_ The token decimals
     */
    constructor(address yoloHook, address aclManager, string memory name_, string memory symbol_, uint8 decimals_)
        MintableIncentivizedERC20(yoloHook, aclManager, name_, symbol_, decimals_)
    {}

    // ============ Helper Functions for Testing ============

    /**
     * @notice Gets the user state for testing
     * @param user The user to query
     * @return balance The user's balance
     * @return additionalData The user's additional data
     */
    function getUserState(address user) external view returns (uint128 balance, uint128 additionalData) {
        UserState memory state = _userState[user];
        return (state.balance, state.additionalData);
    }

    /**
     * @notice Sets additional data for a user (testing only)
     * @param user The user to update
     * @param data The additional data to set
     */
    function setUserAdditionalData(address user, uint128 data) external {
        _setAdditionalData(user, data);
    }

    /**
     * @notice Exposes the internal transfer for testing
     * @param from The sender
     * @param to The recipient
     * @param amount The amount to transfer
     */
    function testTransfer(address from, address to, uint256 amount) external {
        _transfer(from, to, amount);
    }
}
