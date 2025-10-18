// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./base/MintableIncentivizedERC20Upgradeable.sol";
import "./base/EIP712BaseUpgradeable.sol";
import "../interfaces/IYoloSyntheticAsset.sol";
import "../interfaces/IYoloOracle.sol";
import "../interfaces/IYoloHook.sol";
import "../interfaces/IYLPVault.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title YoloSyntheticAsset
 * @author alvin@yolo.wtf
 * @notice Synthetic asset token with cost basis tracking for YOLO Protocol V1
 * @dev Upgradeable implementation that tracks weighted average purchase price
 *      while maintaining full ERC20 compatibility and composability.
 *      Uses ceiling division for average price calculations so rounding dust
 *      benefits the protocol (users pay slightly more).
 */
contract YoloSyntheticAsset is
    MintableIncentivizedERC20Upgradeable,
    EIP712BaseUpgradeable,
    UUPSUpgradeable,
    IYoloSyntheticAsset
{
    // Custom errors
    error YoloSyntheticAsset__InvalidAddress();
    error YoloSyntheticAsset__TradingDisabled();
    error YoloSyntheticAsset__ExceedsMaxSupply();
    error YoloSyntheticAsset__InvalidPrice();

    // Cost basis tracking - using 8 decimals precision (1e8 = 1 USY)
    mapping(address => uint128) public avgPriceX8;

    /// @notice Aggregated cost basis across all holders (price * quantity, 8+18 decimals)
    uint256 internal totalCostBasisX8;

    // Synthetic asset configuration
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
     * @param _ylpVault YLP vault for P&L settlement
     * @param _maxSupply Maximum supply cap (0 for unlimited)
     */
    function initialize(
        address yoloHook,
        address aclManager,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address _ylpVault,
        uint256 _maxSupply
    ) external initializer {
        if (_ylpVault == address(0)) revert YoloSyntheticAsset__InvalidAddress();

        // Initialize parent contracts
        __MintableIncentivizedERC20_init(yoloHook, aclManager, name_, symbol_, decimals_);
        __EIP712Base_init(name_);

        // Set synthetic asset configuration
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
        uint256 prevBalance = balanceOf(from);
        uint128 prevAvg = avgPriceX8[from];

        // PnL settlement only for yAssets (not USY), non-protocol accounts with cost basis
        if (_shouldTrackCostBasis() && !_isProtocolAccount(from) && prevAvg > 0) {
            uint256 currentPriceX8 = IYoloHook(YOLO_HOOK).yoloOracle().getAssetPrice(address(this));
            if (currentPriceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

            int256 deltaX8 = int256(currentPriceX8) - int256(uint256(prevAvg));
            int256 pnlUSY = deltaX8 >= 0
                ? int256((uint256(deltaX8) * amount) / 1e8)  // FLOOR for profit
                : -int256((uint256(-deltaX8) * amount + 1e8 - 1) / 1e8); // CEIL for loss

            IYoloHook(YOLO_HOOK).settlePnLFromSynthetic(from, pnlUSY);
        }

        // 1) Burn FIRST (so parent hooks run on consistent state)
        _burn(from, amount);

        // 2) Skip cost-basis tracking for protocol accounts or USY
        if (_isProtocolAccount(from) || !_shouldTrackCostBasis()) return;

        uint256 newBalance = prevBalance - amount;
        uint128 newAvg = newBalance == 0 ? 0 : prevAvg;
        avgPriceX8[from] = newAvg;

        _updateGlobalCost(prevBalance, prevAvg, newBalance, newAvg);
        emit CostBasisUpdated(from, newBalance, newAvg);
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

        // Skip cost basis updates for mint/burn (handled in mint/burn functions)
        if (from == address(0) || to == address(0)) {
            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        // Skip if transferring to self or zero amount
        if (from == to || amount == 0) {
            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        // Fast-path for protocol ↔ protocol transfers (gas savings + no tracking needed)
        if (_isProtocolAccount(from) && _isProtocolAccount(to)) {
            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        // ===== CASE 1: Protocol → User (Buy Flow) =====
        // User receives synthetic assets from protocol at current oracle price
        if (_isProtocolAccount(from) && !_isProtocolAccount(to)) {
            // Only track cost basis for yAssets, not USY
            if (_shouldTrackCostBasis()) {
                uint256 toBalance = balanceOf(to);
                uint128 prevToAvg = avgPriceX8[to];

                // Get current oracle price for this synthetic asset
                uint256 priceX8 = IYoloHook(YOLO_HOOK).yoloOracle().getAssetPrice(address(this));
                if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

                // Calculate new weighted average with ceiling division
                uint128 newToAvg;
                if (toBalance == 0) {
                    newToAvg = uint128(priceX8);
                } else {
                    uint256 existingCost = uint256(prevToAvg) * toBalance;
                    uint256 incomingCost = priceX8 * amount;
                    uint256 totalCost = existingCost + incomingCost;
                    uint256 totalQuantity = toBalance + amount;
                    newToAvg = uint128((totalCost + totalQuantity - 1) / totalQuantity); // ceiling
                }

                avgPriceX8[to] = newToAvg;
                _updateGlobalCost(toBalance, prevToAvg, toBalance + amount, newToAvg);
                emit CostBasisUpdated(to, toBalance + amount, newToAvg);
            }

            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        // ===== CASE 2: User → Protocol (Sell Flow) =====
        // Settle P&L for user at current oracle price before protocol receives tokens
        if (!_isProtocolAccount(from) && _isProtocolAccount(to)) {
            uint256 fromBalance = balanceOf(from);
            uint128 prevFromAvg = avgPriceX8[from];

            // Realize P&L only for yAssets (not USY) with cost basis
            if (_shouldTrackCostBasis() && prevFromAvg > 0) {
                uint256 priceX8 = IYoloHook(YOLO_HOOK).yoloOracle().getAssetPrice(address(this));
                if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

                int256 deltaX8 = int256(priceX8) - int256(uint256(prevFromAvg));
                // FLOOR for profit, CEIL for loss (matches burn logic)
                int256 pnlUSY = deltaX8 >= 0
                    ? int256((uint256(deltaX8) * amount) / 1e8)
                    : -int256((uint256(-deltaX8) * amount + 1e8 - 1) / 1e8);

                IYoloHook(YOLO_HOOK).settlePnLFromSynthetic(from, pnlUSY);
            }

            // Update/clear sender's average and global cost (only for yAssets)
            uint256 newFromBalance = fromBalance - amount;
            uint128 newFromAvg = (_shouldTrackCostBasis() && newFromBalance == 0) ? 0 : prevFromAvg;
            if (_shouldTrackCostBasis() && newFromAvg != prevFromAvg) {
                avgPriceX8[from] = newFromAvg;
                emit CostBasisUpdated(from, newFromBalance, newFromAvg);
            }
            _updateGlobalCost(fromBalance, prevFromAvg, newFromBalance, newFromAvg);

            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        // ===== CASE 3: User ↔ User (Normal Transfer) =====
        // Only track cost basis for yAssets, not USY
        if (_shouldTrackCostBasis()) {
            uint256 fromBalance = balanceOf(from);
            uint256 toBalance = balanceOf(to);
            uint128 prevFromAvg = avgPriceX8[from];
            uint128 prevToAvg = avgPriceX8[to];

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

            _updateGlobalCost(fromBalance, prevFromAvg, fromBalance - amount, avgPriceX8[from]);
            _updateGlobalCost(toBalance, prevToAvg, toBalance + amount, avgPriceX8[to]);
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
     * @return Address of the YoloOracle (queried through YoloHook)
     */
    function priceOracle() external view override returns (address) {
        return address(IYoloHook(YOLO_HOOK).yoloOracle());
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

        // 1) Mint FIRST (so parent hooks run on consistent state)
        _mint(to, amount);

        // 2) Skip cost-basis tracking for protocol accounts or USY (cash-like stable)
        if (_isProtocolAccount(to) || !_shouldTrackCostBasis()) return;

        // Get current price from oracle via YoloHook (centralized oracle)
        uint256 priceX8 = IYoloHook(YOLO_HOOK).yoloOracle().getAssetPrice(address(this));
        if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

        // Calculate previous balance (before the mint)
        uint256 prevBalance = balanceOf(to) - amount;
        uint128 prevAvg = avgPriceX8[to];

        // Update cost basis with ceiling division
        uint128 newAvg;
        if (prevBalance > 0) {
            uint256 totalCost = uint256(prevAvg) * prevBalance + priceX8 * amount;
            uint256 totalQuantity = prevBalance + amount;
            newAvg = uint128((totalCost + totalQuantity - 1) / totalQuantity);
        } else {
            newAvg = uint128(priceX8);
        }

        avgPriceX8[to] = newAvg;
        _updateGlobalCost(prevBalance, prevAvg, prevBalance + amount, newAvg);
        emit CostBasisUpdated(to, prevBalance + amount, newAvg);
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

    // ============================================================
    // UPGRADE AUTHORIZATION
    // ============================================================

    /**
     * @notice Authorizes contract upgrades
     * @dev Only YoloHook can upgrade synthetic assets it created
     *      This follows the Aave pattern where the main protocol contract
     *      maintains upgrade control over all deployed tokens
     * @param newImplementation Address of the new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyYoloHook {}

    /**
     * @notice Returns the total aggregated cost basis across all holders
     * @return Total cost basis in X8 precision (sum of all avgPriceX8 * balance)
     */
    function getTotalCostBasisX8() external view returns (uint256) {
        return totalCostBasisX8;
    }

    /**
     * @notice Returns the global average creation price across all holders (8 decimals)
     */
    function globalAveragePriceX8() external view returns (uint128) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        return uint128((totalCostBasisX8 + supply - 1) / supply);
    }

    function _updateGlobalCost(uint256 previousBalance, uint128 previousAvg, uint256 newBalance, uint128 newAvg)
        internal
    {
        if (previousBalance == newBalance && previousAvg == newAvg) {
            return;
        }

        uint256 prevCost = uint256(previousAvg) * previousBalance;
        uint256 newCost = uint256(newAvg) * newBalance;

        if (newCost >= prevCost) {
            totalCostBasisX8 += newCost - prevCost;
        } else {
            totalCostBasisX8 -= prevCost - newCost;
        }
    }

    /**
     * @dev Checks if this token is USY (the anchor stable)
     * @return True if this contract is USY
     */
    function _isUSYToken() internal view returns (bool) {
        return address(this) == IYoloHook(YOLO_HOOK).usy();
    }

    /**
     * @dev Checks if cost basis should be tracked for this token
     * @return True if should track (yAssets), False if not (USY)
     */
    function _shouldTrackCostBasis() internal view returns (bool) {
        // Track only for yAssets (yETH, yBTC, etc.), never for USY
        return !_isUSYToken();
    }

    /**
     * @dev Checks if address is a protocol account that shouldn't track cost basis
     * @return True if protocol account (YoloHook, YLP vault, PoolManager)
     */
    function _isProtocolAccount(address account) internal view returns (bool) {
        return account == YOLO_HOOK || account == ylpVault || account == IYoloHook(YOLO_HOOK).poolManagerAddress();
    }

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[43] private __gap;
}
