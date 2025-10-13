// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./base/MintableIncentivizedERC20Upgradeable.sol";
import "./base/EIP712BaseUpgradeable.sol";
import "../interfaces/IYoloSyntheticAsset.sol";
import "../interfaces/IYoloOracle.sol";
import "../interfaces/IYLPVault.sol";

/**
 * @title YoloSyntheticAsset
 * @author alvin@yolo.wtf
 * @notice Synthetic asset token with cost basis tracking for YOLO Protocol V1
 * @dev Upgradeable implementation that tracks weighted average purchase price
 *      while maintaining full ERC20 compatibility and composability.
 *      Uses ceiling division for average price calculations so rounding dust
 *      benefits the protocol (users pay slightly more).
 */
contract YoloSyntheticAsset is MintableIncentivizedERC20Upgradeable, EIP712BaseUpgradeable, IYoloSyntheticAsset {
    // Custom errors
    error YoloSyntheticAsset__InvalidOracle();
    error YoloSyntheticAsset__InvalidAddress();
    error YoloSyntheticAsset__TradingDisabled();
    error YoloSyntheticAsset__ExceedsMaxSupply();
    error YoloSyntheticAsset__InvalidPrice();

    // Cost basis tracking - using 8 decimals precision (1e8 = 1 USY)
    mapping(address => uint128) public avgPriceX8;

    // Synthetic asset configuration
    address public underlyingAsset; // Reference asset (e.g., WETH for yETH)
    IYoloOracle public yoloOracle; // YoloOracle for price feeds
    address public ylpVault; // YLP vault for P&L settlement
    uint256 public maxSupply; // Optional supply cap (0 = unlimited)
    bool public tradingEnabled; // Circuit breaker for risk management

    /**
     * @dev Disables initializers to prevent implementation contract initialization
     * @notice This protects the implementation from being initialized directly
     */
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initializes the synthetic asset token
     * @param yoloHook The YoloHook contract address
     * @param aclManager The ACL manager for access control
     * @param name_ Token name (e.g., "Yolo Synthetic ETH")
     * @param symbol_ Token symbol (e.g., "yETH")
     * @param decimals_ Token decimals (typically 18)
     * @param _underlyingAsset Reference asset address
     * @param _yoloOracle YoloOracle contract address
     * @param _ylpVault YLP vault for P&L settlement
     * @param _maxSupply Maximum supply cap (0 for unlimited)
     */
    function initialize(
        address yoloHook,
        address aclManager,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address _underlyingAsset,
        IYoloOracle _yoloOracle,
        address _ylpVault,
        uint256 _maxSupply
    ) external initializer {
        if (address(_yoloOracle) == address(0)) revert YoloSyntheticAsset__InvalidOracle();
        if (_ylpVault == address(0)) revert YoloSyntheticAsset__InvalidAddress();

        // Initialize parent contracts
        __MintableIncentivizedERC20_init(yoloHook, aclManager, name_, symbol_, decimals_);
        __EIP712Base_init(name_);

        // Set synthetic asset configuration
        underlyingAsset = _underlyingAsset;
        yoloOracle = _yoloOracle;
        ylpVault = _ylpVault;
        maxSupply = _maxSupply;
        tradingEnabled = true;
    }

    /**
     * @notice Mints synthetic assets with cost basis tracking
     * @dev Only callable by YoloHook. Price is fetched from YoloOracle
     * @param to Recipient address
     * @param amount Amount to mint (in token decimals)
     */
    function mint(address to, uint256 amount)
        external
        virtual
        override(MintableIncentivizedERC20Upgradeable, IYoloSyntheticAsset)
        onlyYoloHook
    {
        _mintWithOraclePrice(to, amount);
    }

    /**
     * @notice Burns synthetic assets with P&L settlement
     * @dev Only callable by YoloHook. Settles P&L with YLP vault
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burn(address from, uint256 amount)
        external
        virtual
        override(MintableIncentivizedERC20Upgradeable, IYoloSyntheticAsset)
        onlyYoloHook
    {
        _settleAndBurn(from, amount);
    }

    /**
     * @dev Internal function to settle P&L and burn tokens
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function _settleAndBurn(address from, uint256 amount) internal {
        uint256 balance = balanceOf(from);
        uint128 avgCost = avgPriceX8[from];

        // Get current price for P&L calculation
        uint256 currentPriceX8 = yoloOracle.getAssetPrice(underlyingAsset);
        if (currentPriceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

        // Calculate and settle P&L if avgCost exists
        if (avgCost > 0) {
            int256 deltaX8 = int256(currentPriceX8) - int256(uint256(avgCost));
            int256 pnlUSY;

            if (deltaX8 >= 0) {
                // User profit: FLOOR payout (less to user)
                uint256 profitNumerator = uint256(deltaX8) * amount;
                pnlUSY = int256(profitNumerator / 1e8);
            } else {
                // User loss: CEIL charge (more from user)
                uint256 lossNumerator = uint256(-deltaX8) * amount;
                pnlUSY = -int256((lossNumerator + 1e8 - 1) / 1e8);
            }

            // Settle P&L with YLP vault (no reentrancy into token)
            IYLPVault(ylpVault).settlePnL(from, address(this), pnlUSY);

            // Emit P&L settled event
            emit CostBasisUpdated(from, balance - amount, avgCost);
        }
        // If avgCost == 0 (edge case), no P&L settlement

        // Clear average price if burning entire balance
        if (balance == amount && avgCost > 0) {
            avgPriceX8[from] = 0;
            emit CostBasisUpdated(from, 0, 0);
        }
        // For partial burns, average price remains unchanged

        // Execute burn
        _burn(from, amount);
    }

    /**
     * @notice Hook called before token transfers
     * @dev Updates cost basis for transfers while maintaining ERC20 compatibility
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount being transferred
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        // Check trading status for transfers (not mint/burn)
        if (!tradingEnabled && from != address(0) && to != address(0)) {
            revert YoloSyntheticAsset__TradingDisabled();
        }

        // Skip cost basis updates for mint/burn
        if (from == address(0) || to == address(0)) {
            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        // Skip if transferring to self or zero amount
        if (from == to || amount == 0) {
            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        // Get pre-transfer balances
        uint256 fromBalance = balanceOf(from);
        uint256 toBalance = balanceOf(to);

        // Update recipient's weighted average
        if (toBalance == 0) {
            // Recipient has no tokens - inherit sender's average
            avgPriceX8[to] = avgPriceX8[from];
        } else if (avgPriceX8[from] > 0) {
            // Calculate new weighted average for recipient with ceiling division
            uint256 carriedCost = uint256(avgPriceX8[from]) * amount;
            uint256 existingCost = uint256(avgPriceX8[to]) * toBalance;
            uint256 totalCost = existingCost + carriedCost;
            uint256 totalQuantity = toBalance + amount;
            // Ceiling division: (a + b - 1) / b
            avgPriceX8[to] = uint128((totalCost + totalQuantity - 1) / totalQuantity);
        }

        // Clear sender's average if transferring entire balance
        if (fromBalance == amount && avgPriceX8[from] > 0) {
            avgPriceX8[from] = 0;
            emit CostBasisUpdated(from, 0, 0);
        }

        // Emit update event for recipient if their cost basis changed
        if (toBalance == 0 || avgPriceX8[from] > 0) {
            emit CostBasisUpdated(to, toBalance + amount, avgPriceX8[to]);
        }

        // Continue with parent logic
        super._beforeTokenTransfer(from, to, amount);
    }

    /**
     * @notice Returns the average cost basis for a user
     * @param user Address to query
     * @return Average price in 8 decimal precision
     */
    function averagePriceX8(address user) external view override returns (uint128) {
        return avgPriceX8[user];
    }

    /**
     * @notice Returns the price oracle address for compatibility
     * @return Address of the YoloOracle
     */
    function priceOracle() external view override returns (address) {
        return address(yoloOracle);
    }

    /**
     * @notice Enables or disables trading (circuit breaker)
     * @dev Only callable by risk admin
     * @param enabled New trading status
     */
    function setTradingEnabled(bool enabled) external override {
        if (!ACL_MANAGER.hasRole(keccak256("RISK_ADMIN"), _msgSender())) {
            revert IncentivizedERC20__OnlyIncentivesAdmin(); // Reuse error for consistency
        }
        tradingEnabled = enabled;
        emit TradingStatusChanged(enabled);
    }

    /**
     * @notice Updates the maximum supply cap
     * @dev Only callable by assets admin
     * @param _maxSupply New maximum supply (0 for unlimited)
     */
    function setMaxSupply(uint256 _maxSupply) external override {
        if (!ACL_MANAGER.hasRole(keccak256("ASSETS_ADMIN"), _msgSender())) {
            revert IncentivizedERC20__OnlyIncentivesAdmin(); // Reuse error for consistency
        }
        maxSupply = _maxSupply;
        emit MaxSupplyUpdated(_maxSupply);
    }

    /**
     * @notice Updates the YoloOracle
     * @dev Only callable by risk admin
     * @param _yoloOracle New YoloOracle address
     */
    function setYoloOracle(IYoloOracle _yoloOracle) external override {
        if (address(_yoloOracle) == address(0)) revert YoloSyntheticAsset__InvalidOracle();
        if (!ACL_MANAGER.hasRole(keccak256("RISK_ADMIN"), _msgSender())) {
            revert IncentivizedERC20__OnlyIncentivesAdmin(); // Reuse error for consistency
        }
        yoloOracle = _yoloOracle;
        emit OracleUpdated(address(_yoloOracle));
    }

    /**
     * @notice EIP-2612 permit for gasless approvals
     * @dev Inherited from EIP712BaseUpgradeable
     */
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        _validateAndUsePermit(owner, spender, value, deadline, v, r, s);
        _approve(owner, spender, value);
    }

    // Override required functions from interface
    function DOMAIN_SEPARATOR()
        public
        view
        virtual
        override(EIP712BaseUpgradeable, IYoloSyntheticAsset)
        returns (bytes32)
    {
        return super.DOMAIN_SEPARATOR();
    }

    function nonces(address owner)
        public
        view
        virtual
        override(EIP712BaseUpgradeable, IYoloSyntheticAsset)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function batchMint(address[] calldata recipients, uint256[] calldata amounts)
        external
        virtual
        override(MintableIncentivizedERC20Upgradeable, IYoloSyntheticAsset)
        onlyYoloHook
    {
        uint256 length = recipients.length;
        for (uint256 i = 0; i < length; i++) {
            // Use internal mint logic with oracle price
            _mintWithOraclePrice(recipients[i], amounts[i]);
        }
    }

    /**
     * @dev Internal mint with oracle price
     */
    function _mintWithOraclePrice(address to, uint256 amount) internal {
        // Check supply cap
        if (maxSupply > 0) {
            uint256 newSupply = totalSupply() + amount;
            if (newSupply > maxSupply) revert YoloSyntheticAsset__ExceedsMaxSupply();
        }

        // Get current price from oracle
        uint256 priceX8 = yoloOracle.getAssetPrice(underlyingAsset);
        if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

        // Update cost basis with ceiling division
        uint256 currentBalance = balanceOf(to);
        if (currentBalance > 0) {
            uint256 totalCost = uint256(avgPriceX8[to]) * currentBalance + priceX8 * amount;
            uint256 totalQuantity = currentBalance + amount;
            avgPriceX8[to] = uint128((totalCost + totalQuantity - 1) / totalQuantity);
        } else {
            avgPriceX8[to] = uint128(priceX8);
        }

        emit CostBasisUpdated(to, currentBalance + amount, avgPriceX8[to]);

        // Execute mint
        _mint(to, amount);
    }

    function batchBurn(address[] calldata accounts, uint256[] calldata amounts)
        external
        virtual
        override(MintableIncentivizedERC20Upgradeable, IYoloSyntheticAsset)
        onlyYoloHook
    {
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; i++) {
            // Use shared settlement logic
            _settleAndBurn(accounts[i], amounts[i]);
        }
    }

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[44] private __gap;
}
