// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MintableIncentivizedERC20Upgradeable} from "./base/MintableIncentivizedERC20Upgradeable.sol";
import {IncentivizedERC20Upgradeable} from "./base/IncentivizedERC20Upgradeable.sol";
import {EIP712BaseUpgradeable} from "./base/EIP712BaseUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYoloSyntheticAsset} from "../interfaces/IYoloSyntheticAsset.sol";
import {IYoloHook} from "../interfaces/IYoloHook.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

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
    PausableUpgradeable,
    UUPSUpgradeable,
    IYoloSyntheticAsset
{
    // Custom errors
    error YoloSyntheticAsset__InvalidAddress();
    error YoloSyntheticAsset__TradingDisabled();
    error YoloSyntheticAsset__ExceedsMaxSupply();
    error YoloSyntheticAsset__InvalidPrice();
    error YoloSyntheticAsset__InvalidOraclePrice();

    // ========== CONSTANTS ==========

    /// @notice WAD precision (1e18) for liquidityIndex calculations
    uint256 public constant WAD = 1e18;

    // ========== CORPORATE ACTIONS ==========

    /// @notice Cached oracle reference (fetched during initialize)
    /// @dev Avoids repeated calls through YoloHook
    IYoloOracle public yoloOracle;

    /// @notice Cumulative corporate action index (starts at WAD = 1e18)
    /// @dev Updated on ALL corporate actions (splits, stock dividends, cash dividends)
    /// @dev 1:2 split → liquidityIndex *= 2
    /// @dev 2:1 reverse split → liquidityIndex /= 2
    /// @dev 5% stock dividend → liquidityIndex *= 1.05
    /// @dev $2 cash div @ $98 ex-div price → liquidityIndex *= (98+2)/98 = 1.0204
    uint256 public liquidityIndex;

    /// @notice Per-user cached liquidityIndex for lazy cost basis updates
    /// @dev Tracks when each user's avgPriceX8 was last updated
    /// @dev When liquidityIndex changes, avgPriceX8 is rescaled on next user interaction
    mapping(address => uint256) private _lastLiquidityIndex;

    // ========== COST BASIS TRACKING ==========

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
        __Pausable_init();

        // Initialize corporate action index to WAD (1.0)
        // Oracle will be lazily cached on first use
        liquidityIndex = WAD;

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
        // Update cost basis FIRST if liquidityIndex changed (ensures avgPriceX8 is current)
        if (!_isProtocolAccount(from)) {
            _updateCostBasisIfNeeded(from);
        }

        uint256 prevBalance = balanceOf(from);
        uint128 prevAvg = avgPriceX8[from];

        // PnL settlement only for yAssets (not USY), non-protocol accounts with cost basis
        if (_shouldTrackCostBasis() && !_isProtocolAccount(from) && prevAvg > 0) {
            uint256 currentPriceX8 = _getOracle().getAssetPrice(address(this));
            if (currentPriceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

            int256 deltaX8 = SafeCast.toInt256(currentPriceX8) - SafeCast.toInt256(uint256(prevAvg));
            int256 pnlUSY = deltaX8 >= 0
                ? SafeCast.toInt256((SafeCast.toUint256(deltaX8) * amount) / 1e8)  // FLOOR for profit
                : -SafeCast.toInt256((SafeCast.toUint256(-deltaX8) * amount + 1e8 - 1) / 1e8); // CEIL for loss

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
     * @dev Now simplified to only enforce trading halts (cost basis handled in manual _mint/_burn/_transfer)
     * @param from Sender address
     * @param to Recipient address
     * @param amount Amount being transferred
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        // Check trading status for user-to-user transfers (not mint/burn)
        if (!tradingEnabled && from != address(0) && to != address(0)) {
            revert YoloSyntheticAsset__TradingDisabled();
        }

        // Call parent hook
        super._beforeTokenTransfer(from, to, amount);
    }

    // ============================================================
    // VIEW FUNCTIONS - CORPORATE ACTIONS
    // ============================================================

    /**
     * @notice Returns actual balance (includes corporate actions via liquidityIndex)
     * @dev _userState[account].balance stores SCALED amount
     * @dev Actual balance = scaled balance × liquidityIndex / WAD
     * @param account Address to query
     * @return Actual token balance (ERC20 compliant)
     */
    function balanceOf(address account) public view override(IERC20, IncentivizedERC20Upgradeable) returns (uint256) {
        return (_userState[account].balance * liquidityIndex) / WAD;
    }

    /**
     * @notice Returns actual total supply (includes corporate actions via liquidityIndex)
     * @dev _totalSupply stores SCALED amount
     * @dev Actual supply = scaled supply × liquidityIndex / WAD
     * @return Actual total supply (ERC20 compliant)
     */
    function totalSupply() public view override(IERC20, IncentivizedERC20Upgradeable) returns (uint256) {
        return (_totalSupply * liquidityIndex) / WAD;
    }

    /**
     * @notice Returns scaled balance (internal accounting, normalized to liquidityIndex = 1.0)
     * @dev This is NOT the user's actual balance!
     * @dev Scaled balance is the internal storage value
     * @dev Actual balance = scaledBalance × liquidityIndex / WAD
     * @param account Address to query
     * @return Scaled balance (internal representation)
     */
    function scaledBalanceOf(address account) public view returns (uint256) {
        return _userState[account].balance;
    }

    /**
     * @notice Returns scaled total supply (internal accounting, normalized to liquidityIndex = 1.0)
     * @dev Actual supply = scaledTotalSupply × liquidityIndex / WAD
     * @return Scaled total supply (internal representation)
     */
    function scaledTotalSupply() public view returns (uint256) {
        return _totalSupply;
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
     * @return Address of the cached YoloOracle (lazily loaded, fallback to YoloHook query)
     */
    function priceOracle() external view override returns (address) {
        // Return cached oracle if available, otherwise query through YoloHook
        if (address(yoloOracle) != address(0)) {
            return address(yoloOracle);
        }
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

    // ============================================================
    // CORPORATE ACTIONS
    // ============================================================

    /**
     * @notice Execute a stock split (e.g., 2:1 means each share becomes 2 shares)
     * @dev Only callable by YoloHook. Adjusts liquidityIndex proportionally
     * @param numerator Split numerator (e.g., 2 for 2:1 split)
     * @param denominator Split denominator (e.g., 1 for 2:1 split)
     */
    function executeStockSplit(uint256 numerator, uint256 denominator) external onlyYoloHook whenNotPaused {
        if (numerator == 0 || denominator == 0) revert YoloSyntheticAsset__InvalidPrice();
        if (numerator == denominator) return; // No-op for 1:1

        // Adjust liquidityIndex: newIndex = oldIndex * numerator / denominator
        // For 2:1 split: index doubles (balances double)
        // For 1:2 reverse split: index halves (balances halve)
        liquidityIndex = (liquidityIndex * numerator) / denominator;

        emit StockSplitExecuted(numerator, denominator, liquidityIndex);
    }

    /**
     * @notice Execute a cash dividend via DRIP (Dividend Reinvestment Plan)
     * @dev Only callable by YoloHook. Auto-reinvests dividend as additional shares
     * @param dividendAmountWAD Total dividend amount in WAD (18 decimals)
     */
    function executeCashDividend(uint256 dividendAmountWAD) external onlyYoloHook whenNotPaused {
        if (dividendAmountWAD == 0) return; // No-op for zero dividend

        uint256 currentSupply = totalSupply();
        if (currentSupply == 0) revert YoloSyntheticAsset__InvalidPrice(); // Cannot distribute to zero holders

        // Get current oracle price (8 decimals) - lazily cache oracle if needed
        uint256 priceX8 = _getOracle().getAssetPrice(address(this));
        if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

        // Normalize price to WAD (18 decimals)
        uint256 priceWAD = _normalizeOraclePrice(priceX8);

        // Calculate additional shares from dividend with WAD precision (ceiling division)
        // Example: $2 dividend @ $100/share = (2e18 * 1e18) / 100e18 = 0.02e18 shares
        // Without * WAD, 2e18 / 100e18 = 0 (truncates to zero!)
        uint256 additionalShares = (dividendAmountWAD * WAD + priceWAD - 1) / priceWAD;

        // Adjust liquidityIndex to reflect DRIP: newIndex = oldIndex * (supply + additionalShares) / supply
        // This is equivalent to a stock dividend of (additionalShares / supply) percentage
        liquidityIndex = (liquidityIndex * (currentSupply + additionalShares)) / currentSupply;

        emit CashDividendExecuted(dividendAmountWAD, additionalShares, liquidityIndex);
    }

    /**
     * @notice Execute a stock dividend (e.g., 5% means each holder gets 5% more shares)
     * @dev Only callable by YoloHook. Adjusts liquidityIndex proportionally
     * @param percentageWAD Dividend percentage in WAD (e.g., 0.05e18 for 5%)
     */
    function executeStockDividend(uint256 percentageWAD) external onlyYoloHook whenNotPaused {
        if (percentageWAD == 0) return; // No-op for zero dividend

        // Adjust liquidityIndex: newIndex = oldIndex * (1 + percentage)
        // For 5% dividend: index *= 1.05 (balances increase by 5%)
        liquidityIndex = (liquidityIndex * (WAD + percentageWAD)) / WAD;

        emit StockDividendExecuted(percentageWAD, liquidityIndex);
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

        // Skip cost-basis tracking for protocol accounts or USY (cash-like stable)
        if (_isProtocolAccount(to) || !_shouldTrackCostBasis()) {
            _mint(to, amount);
            return;
        }

        // Update cost basis FIRST if liquidityIndex changed (ensures avgPriceX8 is current)
        _updateCostBasisIfNeeded(to);

        // Capture pre-mint balance BEFORE minting (can't trust balanceOf(to) - amount due to ceiling division)
        uint256 prevBalance = balanceOf(to);
        uint128 prevAvg = avgPriceX8[to];

        // Mint tokens
        _mint(to, amount);

        // Calculate actual minted amount (may differ from `amount` due to ceiling division in _mint)
        uint256 actualMinted = balanceOf(to) - prevBalance;

        // Get current price from cached oracle
        uint256 priceX8 = _getOracle().getAssetPrice(address(this));
        if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

        // Update cost basis with ceiling division using actual minted amount
        uint128 newAvg;
        if (prevBalance > 0) {
            uint256 totalCost = uint256(prevAvg) * prevBalance + priceX8 * actualMinted;
            uint256 totalQuantity = prevBalance + actualMinted;
            newAvg = SafeCast.toUint128((totalCost + totalQuantity - 1) / totalQuantity);
        } else {
            newAvg = SafeCast.toUint128(priceX8);
        }

        avgPriceX8[to] = newAvg;
        _updateGlobalCost(prevBalance, prevAvg, prevBalance + actualMinted, newAvg);
        emit CostBasisUpdated(to, prevBalance + actualMinted, newAvg);
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
        return SafeCast.toUint128((totalCostBasisX8 + supply - 1) / supply);
    }

    // ============================================================
    // HELPER FUNCTIONS - CORPORATE ACTIONS
    // ============================================================

    /**
     * @notice Lazily cache oracle reference if not already cached
     * @dev Caches on first call to avoid initialization ordering issues
     * @return Oracle instance
     */
    function _getOracle() internal returns (IYoloOracle) {
        if (address(yoloOracle) == address(0)) {
            yoloOracle = IYoloHook(YOLO_HOOK).yoloOracle();
        }
        return yoloOracle;
    }

    /**
     * @notice Normalize oracle price from 8 decimals to 18 decimals (WAD)
     * @dev YoloOracle returns prices in 8 decimals, we need 18 for internal calculations
     * @param priceX8 Price in 8 decimal format (1e8)
     * @return priceWAD Price in 18 decimal format (1e18)
     */
    function _normalizeOraclePrice(uint256 priceX8) internal pure returns (uint256 priceWAD) {
        return priceX8 * 1e10; // 1e8 * 1e10 = 1e18
    }

    /**
     * @notice Update user's cost basis if liquidityIndex has changed since last update
     * @dev Called before any operation that needs accurate cost basis
     * @param user Address of user whose cost basis to update
     */
    function _updateCostBasisIfNeeded(address user) internal {
        uint256 userLastIndex = _lastLiquidityIndex[user];

        // No update needed if index unchanged or user has no position
        if (userLastIndex == liquidityIndex || userLastIndex == 0) {
            // Initialize index for new users with existing balance
            if (userLastIndex == 0 && _userState[user].balance > 0) {
                _lastLiquidityIndex[user] = liquidityIndex;
            }
            return;
        }

        uint128 oldAvgPrice = avgPriceX8[user];
        if (oldAvgPrice == 0) {
            _lastLiquidityIndex[user] = liquidityIndex;
            return;
        }

        // Rescale: oldPrice * oldIndex / newIndex (ceiling division)
        uint256 scaledPrice = (uint256(oldAvgPrice) * userLastIndex + liquidityIndex - 1) / liquidityIndex;
        uint128 newAvgPrice = SafeCast.toUint128(scaledPrice);

        uint256 currentBalance = balanceOf(user);
        _updateGlobalCost(currentBalance, oldAvgPrice, currentBalance, newAvgPrice);

        avgPriceX8[user] = newAvgPrice;
        _lastLiquidityIndex[user] = liquidityIndex;

        emit CostBasisUpdated(user, currentBalance, newAvgPrice);
    }

    // ============================================================
    // MANUAL ERC20 OVERRIDES - CORPORATE ACTIONS SUPPORT
    // ============================================================

    /**
     * @dev Override _mint to work with scaled balances
     * @notice Does NOT call super - manual implementation to avoid double-booking
     * @param account Address to mint to
     * @param amount ACTUAL amount to mint (user-facing)
     */
    function _mint(address account, uint256 amount) internal virtual override {
        if (account == address(0)) revert IncentivizedERC20__InvalidAddress();

        _beforeTokenTransfer(address(0), account, amount);

        // Convert actual amount to scaled amount (ceiling division to favor protocol)
        uint128 scaledAmount = SafeCast.toUint128((amount * WAD + liquidityIndex - 1) / liquidityIndex);

        // Update state with scaled amounts
        _totalSupply = _totalSupply + scaledAmount;
        _userState[account].balance = _userState[account].balance + scaledAmount;

        // Calculate actual balances for incentives
        uint256 actualTotal = (_totalSupply * liquidityIndex) / WAD;
        uint256 actualBalance = (_userState[account].balance * liquidityIndex) / WAD;

        // Update incentives with actual amounts (ratio stays identical)
        _updateIncentives(address(0), account, actualTotal, 0, SafeCast.toUint128(actualBalance));

        // Emit Transfer with actual amount
        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Override _burn to work with scaled balances
     * @notice Does NOT call super - manual implementation to avoid double-booking
     * @param account Address to burn from
     * @param amount ACTUAL amount to burn (user-facing)
     */
    function _burn(address account, uint256 amount) internal virtual override {
        if (account == address(0)) revert IncentivizedERC20__InvalidAddress();

        // Update cost basis if needed BEFORE _beforeTokenTransfer (hook logic may depend on avgPriceX8)
        _updateCostBasisIfNeeded(account);

        _beforeTokenTransfer(account, address(0), amount);

        // Convert actual amount to scaled amount (ceiling division to favor protocol)
        uint128 scaledAmount = SafeCast.toUint128((amount * WAD + liquidityIndex - 1) / liquidityIndex);
        uint128 accountBalanceBefore = _userState[account].balance;

        if (accountBalanceBefore < scaledAmount) revert IncentivizedERC20__InsufficientBalance();

        // Update state with scaled amounts
        unchecked {
            _userState[account].balance = accountBalanceBefore - scaledAmount;
            _totalSupply = _totalSupply - scaledAmount;
        }

        // Calculate actual balances for incentives
        uint256 actualTotal = (_totalSupply * liquidityIndex) / WAD;
        uint256 actualBalance = (_userState[account].balance * liquidityIndex) / WAD;

        // Update incentives with actual amounts
        _updateIncentives(account, address(0), actualTotal, SafeCast.toUint128(actualBalance), 0);

        // Emit Transfer with actual amount
        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Override _transfer to work with scaled balances
     * @notice Does NOT call super - manual implementation to avoid double-booking
     * @param from Sender address
     * @param to Recipient address
     * @param amount ACTUAL amount to transfer (user-facing)
     */
    function _transfer(address from, address to, uint256 amount) internal virtual override {
        if (from == address(0)) revert IncentivizedERC20__InvalidAddress();
        if (to == address(0)) revert IncentivizedERC20__InvalidAddress();

        // Update cost basis for both parties BEFORE any logic (ensures avgPriceX8 reflects liquidityIndex)
        if (!_isProtocolAccount(from)) _updateCostBasisIfNeeded(from);
        if (!_isProtocolAccount(to)) _updateCostBasisIfNeeded(to);

        // ===== CASE 1: Protocol → User (Buy Flow) =====
        // User receives synthetic assets from protocol at current oracle price
        if (_isProtocolAccount(from) && !_isProtocolAccount(to) && _shouldTrackCostBasis()) {
            uint256 toBalance = balanceOf(to);
            uint128 prevToAvg = avgPriceX8[to];

            // Get current oracle price for this synthetic asset
            uint256 priceX8 = _getOracle().getAssetPrice(address(this));
            if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

            // Calculate new weighted average with ceiling division
            uint128 newToAvg;
            if (toBalance == 0) {
                newToAvg = SafeCast.toUint128(priceX8);
            } else {
                uint256 existingCost = uint256(prevToAvg) * toBalance;
                uint256 incomingCost = priceX8 * amount;
                uint256 totalCost = existingCost + incomingCost;
                uint256 totalQuantity = toBalance + amount;
                newToAvg = SafeCast.toUint128((totalCost + totalQuantity - 1) / totalQuantity); // ceiling
            }

            avgPriceX8[to] = newToAvg;
            _updateGlobalCost(toBalance, prevToAvg, toBalance + amount, newToAvg);
            emit CostBasisUpdated(to, toBalance + amount, newToAvg);
        }
        // ===== CASE 2: User → Protocol (Sell Flow) =====
        // Settle P&L for user at current oracle price before protocol receives tokens
        else if (!_isProtocolAccount(from) && _isProtocolAccount(to)) {
            uint256 fromBalance = balanceOf(from);
            uint128 prevFromAvg = avgPriceX8[from];

            // Realize P&L only for yAssets (not USY) with cost basis
            if (_shouldTrackCostBasis() && prevFromAvg > 0) {
                uint256 priceX8 = _getOracle().getAssetPrice(address(this));
                if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

                int256 deltaX8 = SafeCast.toInt256(priceX8) - SafeCast.toInt256(uint256(prevFromAvg));
                // FLOOR for profit, CEIL for loss (matches burn logic)
                int256 pnlUSY = deltaX8 >= 0
                    ? SafeCast.toInt256((SafeCast.toUint256(deltaX8) * amount) / 1e8)
                    : -SafeCast.toInt256((SafeCast.toUint256(-deltaX8) * amount + 1e8 - 1) / 1e8);

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
        }
        // ===== CASE 3: User ↔ User (Normal Transfer) =====
        // Handle cost basis transfer for user-to-user transfers (skip for protocol accounts)
        else if (_shouldTrackCostBasis() && !_isProtocolAccount(from) && !_isProtocolAccount(to)) {
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
                avgPriceX8[to] = SafeCast.toUint128((totalCost + totalQuantity - 1) / totalQuantity);
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

        _beforeTokenTransfer(from, to, amount);

        // Convert actual amount to scaled amount (ceiling division to favor protocol)
        uint128 scaledAmount = SafeCast.toUint128((amount * WAD + liquidityIndex - 1) / liquidityIndex);

        // Cache pre-transfer scaled balances
        uint128 fromBalanceBefore = _userState[from].balance;
        uint128 toBalanceBefore = _userState[to].balance;

        if (fromBalanceBefore < scaledAmount) revert IncentivizedERC20__InsufficientBalance();

        // Update balances with scaled amounts
        unchecked {
            _userState[from].balance = fromBalanceBefore - scaledAmount;
        }
        _userState[to].balance = toBalanceBefore + scaledAmount;

        // Calculate actual balances for incentives
        uint256 actualTotal = (_totalSupply * liquidityIndex) / WAD;
        uint256 fromActualBalance = (_userState[from].balance * liquidityIndex) / WAD;
        uint256 toActualBalance = (_userState[to].balance * liquidityIndex) / WAD;

        // Update incentives with actual amounts
        _updateIncentives(
            from, to, actualTotal, SafeCast.toUint128(fromActualBalance), SafeCast.toUint128(toActualBalance)
        );

        // Emit Transfer with actual amount
        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
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
