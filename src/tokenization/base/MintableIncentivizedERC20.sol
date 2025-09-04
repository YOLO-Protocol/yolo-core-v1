// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IncentivizedERC20.sol";

/**
 * @title MintableIncentivizedERC20
 * @author alvin@yolo.wtf
 * @notice Extends IncentivizedERC20 with mint/burn capabilities restricted to YoloHook
 * @dev Base contract for all YOLO Protocol tokens that require minting/burning
 */
abstract contract MintableIncentivizedERC20 is IncentivizedERC20 {
    // Custom errors
    error MintableIncentivizedERC20__OnlyYoloHook();
    error MintableIncentivizedERC20__InvalidYoloHook();
    error MintableIncentivizedERC20__LengthMismatch();

    // Immutable reference to YoloHook (for proxy compatibility)
    address public immutable YOLO_HOOK;

    /**
     * @dev Constructor sets up YoloHook reference
     * @param yoloHook The YoloHook contract address
     * @param aclManager The ACLManager contract address
     * @param name_ The token name
     * @param symbol_ The token symbol
     * @param decimals_ The token decimals
     */
    constructor(address yoloHook, address aclManager, string memory name_, string memory symbol_, uint8 decimals_)
        IncentivizedERC20(aclManager, name_, symbol_, decimals_)
    {
        if (yoloHook == address(0)) revert MintableIncentivizedERC20__InvalidYoloHook();
        YOLO_HOOK = yoloHook;
    }

    /**
     * @dev Modifier to restrict functions to YoloHook only
     */
    modifier onlyYoloHook() {
        if (_msgSender() != YOLO_HOOK) revert MintableIncentivizedERC20__OnlyYoloHook();
        _;
    }

    /**
     * @notice Mints tokens to a specified account
     * @dev Only callable by YoloHook
     * @param to The account to mint tokens to
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external virtual onlyYoloHook {
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens from a specified account
     * @dev Only callable by YoloHook
     * @param from The account to burn tokens from
     * @param amount The amount of tokens to burn
     */
    function burn(address from, uint256 amount) external virtual onlyYoloHook {
        _burn(from, amount);
    }

    /**
     * @notice Mints tokens to multiple accounts in a single transaction
     * @dev Only callable by YoloHook, useful for batch operations
     * @param recipients Array of recipient addresses
     * @param amounts Array of amounts to mint to each recipient
     */
    function mintBatch(address[] calldata recipients, uint256[] calldata amounts) external virtual onlyYoloHook {
        uint256 length = recipients.length;
        if (length != amounts.length) revert MintableIncentivizedERC20__LengthMismatch();

        for (uint256 i = 0; i < length;) {
            _mint(recipients[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
    }

    /**
     * @notice Burns tokens from multiple accounts in a single transaction
     * @dev Only callable by YoloHook, useful for batch operations
     * @param accounts Array of accounts to burn from
     * @param amounts Array of amounts to burn from each account
     */
    function burnBatch(address[] calldata accounts, uint256[] calldata amounts) external virtual onlyYoloHook {
        uint256 length = accounts.length;
        if (length != amounts.length) revert MintableIncentivizedERC20__LengthMismatch();

        for (uint256 i = 0; i < length;) {
            _burn(accounts[i], amounts[i]);
            unchecked {
                ++i;
            }
        }
    }
}
