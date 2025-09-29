// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./IncentivizedERC20Upgradeable.sol";

/**
 * @title MintableIncentivizedERC20Upgradeable
 * @author alvin@yolo.wtf
 * @notice Upgradeable version with mint/burn capabilities restricted to YoloHook
 * @dev Base contract for all YOLO Protocol proxy tokens that require minting/burning
 */
abstract contract MintableIncentivizedERC20Upgradeable is IncentivizedERC20Upgradeable {
    // Custom errors
    error MintableIncentivizedERC20__OnlyYoloHook();
    error MintableIncentivizedERC20__InvalidYoloHook();
    error MintableIncentivizedERC20__LengthMismatch();

    // Storage reference to YoloHook (for proxy compatibility)
    address public YOLO_HOOK;

    /**
     * @dev Initializes the mintable token with YoloHook reference
     * @param yoloHook The YoloHook contract address
     * @param aclManager The ACLManager contract address
     * @param name_ The token name
     * @param symbol_ The token symbol
     * @param decimals_ The token decimals
     */
    function __MintableIncentivizedERC20_init(
        address yoloHook,
        address aclManager,
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) internal onlyInitializing {
        if (yoloHook == address(0)) revert MintableIncentivizedERC20__InvalidYoloHook();

        YOLO_HOOK = yoloHook;

        // Initialize parent
        __IncentivizedERC20_init(aclManager, name_, symbol_, decimals_);
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
     * @notice Mints tokens to multiple accounts in one transaction
     * @dev Only callable by YoloHook. Gas efficient for bulk operations.
     * @param recipients Array of accounts to mint tokens to
     * @param amounts Array of amounts to mint to each account
     */
    function batchMint(address[] calldata recipients, uint256[] calldata amounts) external virtual onlyYoloHook {
        uint256 length = recipients.length;
        if (length != amounts.length) revert MintableIncentivizedERC20__LengthMismatch();

        for (uint256 i = 0; i < length; i++) {
            _mint(recipients[i], amounts[i]);
        }
    }

    /**
     * @notice Burns tokens from multiple accounts in one transaction
     * @dev Only callable by YoloHook. Gas efficient for bulk operations.
     * @param accounts Array of accounts to burn tokens from
     * @param amounts Array of amounts to burn from each account
     */
    function batchBurn(address[] calldata accounts, uint256[] calldata amounts) external virtual onlyYoloHook {
        uint256 length = accounts.length;
        if (length != amounts.length) revert MintableIncentivizedERC20__LengthMismatch();

        for (uint256 i = 0; i < length; i++) {
            _burn(accounts[i], amounts[i]);
        }
    }

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[48] private __gap;
}