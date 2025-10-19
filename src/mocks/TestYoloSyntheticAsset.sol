// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Import all the parent contracts directly to avoid the constructor issue
import "../tokenization/base/MintableIncentivizedERC20Upgradeable.sol";
import "../tokenization/base/EIP712BaseUpgradeable.sol";
import "../interfaces/IYoloSyntheticAsset.sol";
import "../interfaces/IYoloOracle.sol";
import "../interfaces/IYLPVault.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title TestYoloSyntheticAsset
 * @notice Test version of YoloSyntheticAsset that doesn't disable initializers
 * @dev Duplicates YoloSyntheticAsset logic but without _disableInitializers() for testing
 */
contract TestYoloSyntheticAsset is MintableIncentivizedERC20Upgradeable, EIP712BaseUpgradeable, IYoloSyntheticAsset {
    // Custom errors
    error YoloSyntheticAsset__InvalidOracle();
    error YoloSyntheticAsset__InvalidAddress();
    error YoloSyntheticAsset__TradingDisabled();
    error YoloSyntheticAsset__ExceedsMaxSupply();
    error YoloSyntheticAsset__InvalidPrice();

    // Cost basis tracking - using 8 decimals precision (1e8 = 1 USY)
    mapping(address => uint128) public avgPriceX8;

    uint256 internal totalCostBasisX8;

    // Synthetic asset configuration
    IYoloOracle public yoloOracle;
    address public ylpVault;
    uint256 public maxSupply;
    bool public tradingEnabled;

    /**
     * @dev Constructor for test implementation - does NOT disable initializers
     */
    constructor() {
        // Intentionally empty - allows testing without proxy
    }

    /**
     * @notice Initializes the synthetic asset token
     */
    function initialize(
        address yoloHook,
        address aclManager,
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        IYoloOracle _yoloOracle,
        address _ylpVault,
        uint256 _maxSupply
    ) external initializer {
        if (address(_yoloOracle) == address(0)) revert YoloSyntheticAsset__InvalidOracle();
        if (_ylpVault == address(0)) revert YoloSyntheticAsset__InvalidAddress();

        __MintableIncentivizedERC20_init(yoloHook, aclManager, name_, symbol_, decimals_);
        __EIP712Base_init(name_);

        yoloOracle = _yoloOracle;
        ylpVault = _ylpVault;
        maxSupply = _maxSupply;
        tradingEnabled = true;
    }

    // Copy all the functions from YoloSyntheticAsset...
    // For brevity, I'll include the key ones

    function mint(address to, uint256 amount)
        external
        virtual
        override(MintableIncentivizedERC20Upgradeable, IYoloSyntheticAsset)
        onlyYoloHook
    {
        _mintWithOraclePrice(to, amount);
    }

    function burn(address from, uint256 amount)
        external
        virtual
        override(MintableIncentivizedERC20Upgradeable, IYoloSyntheticAsset)
        onlyYoloHook
    {
        _settleAndBurn(from, amount);
    }

    function _mintWithOraclePrice(address to, uint256 amount) internal {
        if (maxSupply > 0) {
            uint256 newSupply = totalSupply() + amount;
            if (newSupply > maxSupply) revert YoloSyntheticAsset__ExceedsMaxSupply();
        }

        // Query oracle with this synthetic asset's address, not underlyingAsset
        uint256 priceX8 = yoloOracle.getAssetPrice(address(this));
        if (priceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

        uint256 currentBalance = balanceOf(to);
        uint128 previousAvg = avgPriceX8[to];
        if (currentBalance > 0) {
            uint256 totalCost = uint256(avgPriceX8[to]) * currentBalance + priceX8 * amount;
            uint256 totalQuantity = currentBalance + amount;
            avgPriceX8[to] = SafeCast.toUint128((totalCost + totalQuantity - 1) / totalQuantity);
        } else {
            avgPriceX8[to] = SafeCast.toUint128(priceX8);
        }

        _updateGlobalCost(currentBalance, previousAvg, currentBalance + amount, avgPriceX8[to]);

        emit CostBasisUpdated(to, currentBalance + amount, avgPriceX8[to]);
        _mint(to, amount);
    }

    function _settleAndBurn(address from, uint256 amount) internal {
        uint256 balance = balanceOf(from);
        uint128 avgCost = avgPriceX8[from];

        // Query oracle with this synthetic asset's address, not underlyingAsset
        uint256 currentPriceX8 = yoloOracle.getAssetPrice(address(this));
        if (currentPriceX8 == 0) revert YoloSyntheticAsset__InvalidPrice();

        if (avgCost > 0) {
            int256 deltaX8 = SafeCast.toInt256(currentPriceX8) - SafeCast.toInt256(uint256(avgCost));
            int256 pnlUSY;

            if (deltaX8 >= 0) {
                uint256 profitNumerator = SafeCast.toUint256(deltaX8) * amount;
                pnlUSY = SafeCast.toInt256(profitNumerator / 1e8);
            } else {
                uint256 lossNumerator = SafeCast.toUint256(-deltaX8) * amount;
                pnlUSY = -SafeCast.toInt256((lossNumerator + 1e8 - 1) / 1e8);
            }

            IYLPVault(ylpVault).settlePnL(from, address(this), pnlUSY);
            emit CostBasisUpdated(from, balance - amount, avgCost);
        }

        if (balance == amount && avgCost > 0) {
            avgPriceX8[from] = 0;
            emit CostBasisUpdated(from, 0, 0);
        }

        _updateGlobalCost(balance, avgCost, balance - amount, avgPriceX8[from]);

        _burn(from, amount);
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual override {
        if (!tradingEnabled && from != address(0) && to != address(0)) {
            revert YoloSyntheticAsset__TradingDisabled();
        }

        if (from == address(0) || to == address(0)) {
            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        if (from == to || amount == 0) {
            super._beforeTokenTransfer(from, to, amount);
            return;
        }

        uint256 fromBalance = balanceOf(from);
        uint256 toBalance = balanceOf(to);
        uint128 prevFromAvg = avgPriceX8[from];
        uint128 prevToAvg = avgPriceX8[to];

        if (toBalance == 0) {
            avgPriceX8[to] = avgPriceX8[from];
        } else if (avgPriceX8[from] > 0) {
            uint256 carriedCost = uint256(avgPriceX8[from]) * amount;
            uint256 existingCost = uint256(avgPriceX8[to]) * toBalance;
            uint256 totalCost = existingCost + carriedCost;
            uint256 totalQuantity = toBalance + amount;
            avgPriceX8[to] = SafeCast.toUint128((totalCost + totalQuantity - 1) / totalQuantity);
        }

        if (fromBalance == amount && avgPriceX8[from] > 0) {
            avgPriceX8[from] = 0;
            emit CostBasisUpdated(from, 0, 0);
        }

        if (toBalance == 0 || avgPriceX8[from] > 0) {
            emit CostBasisUpdated(to, toBalance + amount, avgPriceX8[to]);
        }

        uint256 newFromBalance = fromBalance - amount;
        uint128 newFromAvg = avgPriceX8[from];
        uint256 newToBalance = toBalance + amount;
        uint128 newToAvg = avgPriceX8[to];

        _updateGlobalCost(fromBalance, prevFromAvg, newFromBalance, newFromAvg);
        _updateGlobalCost(toBalance, prevToAvg, newToBalance, newToAvg);

        super._beforeTokenTransfer(from, to, amount);
    }

    // Implement all other required functions...
    function averagePriceX8(address user) external view override returns (uint128) {
        return avgPriceX8[user];
    }

    function setTradingEnabled(bool enabled) external override {
        if (!ACL_MANAGER.hasRole(keccak256("RISK_ADMIN"), _msgSender())) {
            revert IncentivizedERC20__OnlyIncentivesAdmin();
        }
        tradingEnabled = enabled;
    }

    function setMaxSupply(uint256 _maxSupply) external override {
        if (!ACL_MANAGER.hasRole(keccak256("ASSETS_ADMIN"), _msgSender())) {
            revert IncentivizedERC20__OnlyIncentivesAdmin();
        }
        maxSupply = _maxSupply;
    }

    function priceOracle() external view override returns (address) {
        return address(yoloOracle);
    }

    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        _validateAndUsePermit(owner, spender, value, deadline, v, r, s);
        _approve(owner, spender, value);
    }

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
            _mintWithOraclePrice(recipients[i], amounts[i]);
        }
    }

    function batchBurn(address[] calldata accounts, uint256[] calldata amounts)
        external
        virtual
        override(MintableIncentivizedERC20Upgradeable, IYoloSyntheticAsset)
        onlyYoloHook
    {
        uint256 length = accounts.length;
        for (uint256 i = 0; i < length; i++) {
            _settleAndBurn(accounts[i], amounts[i]);
        }
    }

    function getTotalCostBasisX8() external view returns (uint256) {
        return totalCostBasisX8;
    }

    function globalAveragePriceX8() external view returns (uint128) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 0;
        }
        return SafeCast.toUint128((totalCostBasisX8 + supply - 1) / supply);
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

    uint256[43] private __gap;
}
