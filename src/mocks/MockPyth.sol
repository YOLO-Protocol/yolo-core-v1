// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

contract MockPyth {
    error MockPyth__StalePrice();
    error MockPyth__PriceNotSet();

    uint256 public updateFee = 1;
    mapping(bytes32 => PythStructs.Price) private _prices;

    function setUpdateFee(uint256 fee) external {
        updateFee = fee;
    }

    function setPrice(bytes32 priceId, int64 price, int32 expo, uint256 publishTime) external {
        _prices[priceId] = PythStructs.Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return updateFee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= updateFee, "insufficient-fee");
    }

    function getPriceNoOlderThan(bytes32 priceId, uint256 maxAge) external view returns (PythStructs.Price memory) {
        PythStructs.Price memory stored = _prices[priceId];
        if (stored.publishTime == 0) revert MockPyth__PriceNotSet();
        if (block.timestamp - stored.publishTime > maxAge) {
            revert MockPyth__StalePrice();
        }
        return stored;
    }

    function getPriceUnsafe(bytes32 priceId) external view returns (PythStructs.Price memory) {
        PythStructs.Price memory stored = _prices[priceId];
        if (stored.publishTime == 0) revert MockPyth__PriceNotSet();
        return stored;
    }
}
