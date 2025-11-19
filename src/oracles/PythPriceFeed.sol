// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IPyth} from "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/**
 * @title PythPriceFeed
 * @author alvin@yolo.wtf
 * @notice Chainlink-compatible adapter that exposes Pyth prices with mandatory freshness checks
 * @dev Mirrors Chainlink's AggregatorV3 interface subset (`latestAnswer`, `decimals`) so consumers
 *      expecting standard feeds can integrate without changes. Prices are rescaled to 8 decimals and
 *      `latestAnswer` always enforces a maximum staleness window defined at construction.
 */
contract PythPriceFeed {
    // ========================
    // CONSTANTS
    // ========================

    /// @notice Number of decimals returned by `latestAnswer`
    uint8 private constant DECIMALS = 8;

    /// @notice Maximum supported exponent adjustment to avoid overflow (10**38 comfortably fits in int256)
    int32 private constant MAX_EXPONENT = 38;

    // ========================
    // IMMUTABLE STORAGE
    // ========================

    /// @notice Pyth oracle contract
    IPyth public immutable PYTH;

    /// @notice Identifier for the underlying Pyth price feed
    bytes32 public immutable PRICE_ID;

    /// @notice Human-readable label for frontends/indexers
    string public name;

    /// @notice Maximum allowed staleness (seconds) enforced by `latestAnswer`
    uint32 public immutable maxAllowedPriceLag;

    // ========================
    // ERRORS
    // ========================

    error PythPriceFeed__InvalidAddress();
    error PythPriceFeed__InvalidPriceId();
    error PythPriceFeed__InvalidPrice();
    error PythPriceFeed__InvalidLag();
    error PythPriceFeed__InsufficientFee();
    error PythPriceFeed__RefundFailed();

    // ========================
    // CONSTRUCTOR
    // ========================

    /**
     * @param pyth_ Address of the Pyth contract
     * @param priceId_ Identifier of the desired Pyth price feed
     * @param name_ Human-readable name for this adapter
     * @param maxAllowedPriceLag_ Maximum acceptable lag (in seconds) for the safe price fetch
     */
    constructor(address pyth_, bytes32 priceId_, string memory name_, uint32 maxAllowedPriceLag_) {
        if (pyth_ == address(0)) revert PythPriceFeed__InvalidAddress();
        if (priceId_ == bytes32(0)) revert PythPriceFeed__InvalidPriceId();
        if (maxAllowedPriceLag_ == 0) revert PythPriceFeed__InvalidLag();

        PYTH = IPyth(pyth_);
        PRICE_ID = priceId_;
        name = name_;
        maxAllowedPriceLag = maxAllowedPriceLag_;
    }

    // ========================
    // PUBLIC VIEW FUNCTIONS
    // ========================

    /**
     * @notice Chainlink-compatible decimals accessor
     */
    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    /**
     * @notice Returns the latest price in Chainlink format (int256, 8 decimals)
     * @dev Uses Pyth's freshness-enforced getter with the configured max lag
     */
    function latestAnswer() external view returns (int256) {
        PythStructs.Price memory price = PYTH.getPriceNoOlderThan(PRICE_ID, maxAllowedPriceLag);
        return _scalePrice(price);
    }

    /**
     * @notice Chainlink-compatible round data accessor
     */
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        PythStructs.Price memory price = PYTH.getPriceNoOlderThan(PRICE_ID, maxAllowedPriceLag);
        answer = _scalePrice(price);
        updatedAt = uint256(uint64(price.publishTime));
        startedAt = updatedAt;
        roundId = uint80(uint64(price.publishTime));
        answeredInRound = roundId;
    }

    /**
     * @notice Returns the latest price while allowing callers to specify a custom freshness window
     * @param maxAge Custom staleness tolerance (seconds)
     */
    function latestAnswerWithAge(uint256 maxAge) external view returns (int256) {
        if (maxAge == 0) revert PythPriceFeed__InvalidLag();
        uint32 window = SafeCast.toUint32(maxAge);
        PythStructs.Price memory price = PYTH.getPriceNoOlderThan(PRICE_ID, window);
        return _scalePrice(price);
    }

    /**
     * @notice View helper mirroring Chainlink adapters to forecast update fees with empty data
     */
    function viewUpdateFee() external view returns (uint256) {
        bytes[] memory updateData = new bytes[](1);
        updateData[0] = "";
        return PYTH.getUpdateFee(updateData);
    }

    /**
     * @notice Returns the Pyth update fee for the provided update payload
     */
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256) {
        return PYTH.getUpdateFee(updateData);
    }

    /**
     * @notice Pushes fresh price data into Pyth
     * @dev Caller must send sufficient ETH to cover the update fee. Excess ETH is refunded.
     */
    function updatePrice(bytes[] calldata updateData) external payable {
        uint256 fee = PYTH.getUpdateFee(updateData);
        if (msg.value < fee) revert PythPriceFeed__InsufficientFee();
        PYTH.updatePriceFeeds{value: fee}(updateData);
        if (msg.value > fee) {
            (bool ok,) = msg.sender.call{value: msg.value - fee}("");
            if (!ok) revert PythPriceFeed__RefundFailed();
        }
    }

    /**
     * @notice Raw passthrough for integrators needing the full Pyth struct (may be stale)
     */
    function getPythPrice() external view returns (PythStructs.Price memory) {
        return PYTH.getPriceUnsafe(PRICE_ID);
    }

    /**
     * @notice Returns the publish timestamp from the latest unchecked Pyth price
     */
    function getPublishTime() external view returns (uint256) {
        PythStructs.Price memory price = PYTH.getPriceUnsafe(PRICE_ID);
        return uint256(uint64(price.publishTime));
    }

    // ========================
    // INTERNAL HELPERS
    // ========================

    /**
     * @dev Rescales a Pyth price to 8 decimals while clamping extreme exponents
     */
    function _scalePrice(PythStructs.Price memory price) private pure returns (int256) {
        if (price.price <= 0) revert PythPriceFeed__InvalidPrice();

        int32 adjustment = price.expo + int32(uint32(DECIMALS));
        if (adjustment > MAX_EXPONENT || adjustment < -MAX_EXPONENT) {
            revert PythPriceFeed__InvalidPrice();
        }

        int256 value = price.price;
        if (adjustment == 0) {
            return value;
        }

        int32 absAdjustmentInt = adjustment >= 0 ? adjustment : -adjustment;
        // casting to uint32 is safe because |adjustment| is bounded by MAX_EXPONENT (<= 38)
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 absAdjustment32 = uint32(absAdjustmentInt);
        uint256 absAdjustment = uint256(absAdjustment32);
        // casting to int256 is safe because 10**38 fits within the int256 range
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 scale = int256(10 ** absAdjustment);

        if (adjustment > 0) {
            return value * scale;
        } else {
            return value / scale;
        }
    }
}
