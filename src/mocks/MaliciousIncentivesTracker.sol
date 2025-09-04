// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../interfaces/IIncentivesTracker.sol";
import "../tokenization/base/MintableIncentivizedERC20.sol";

/**
 * @title MaliciousIncentivesTracker
 * @author alvin@yolo.wtf
 * @notice Malicious implementation that attempts reentrancy
 * @dev Used for testing reentrancy protection
 */
contract MaliciousIncentivesTracker is IIncentivesTracker {
    MintableIncentivizedERC20 public immutable token;
    bool public attackAttempted;
    uint256 public reentrancyDepth;

    constructor(address _token) {
        token = MintableIncentivizedERC20(_token);
    }

    /**
     * @notice Attempts to reenter the token contract
     */
    function handleAction(address user, uint256 totalSupply, uint256 userBalance) external override {
        reentrancyDepth++;

        // Only attempt attack once to avoid infinite loop
        if (!attackAttempted && reentrancyDepth == 1) {
            attackAttempted = true;

            // Attempt to reenter by minting (will fail due to onlyYoloHook)
            // or by triggering another transfer
            try token.transfer(user, 0) {
                // If this succeeds, reentrancy protection failed
            } catch {
                // Expected to fail due to reentrancy guard
            }
        }
    }
}
