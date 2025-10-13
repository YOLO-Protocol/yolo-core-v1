// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../tokenization/YoloSyntheticAsset.sol";

/**
 * @title MockYoloSyntheticAsset
 * @notice Mock implementation for testing YoloSyntheticAsset
 * @dev Since parent constructor disables initializers, we need to use a proxy for testing
 *      or deploy via a factory pattern. For now, tests should use proxy pattern.
 */
contract MockYoloSyntheticAsset is YoloSyntheticAsset {
// Parent constructor will run and disable initializers
// This is correct behavior - even test contracts should follow production patterns
// Tests should deploy this behind a proxy for proper testing
}
