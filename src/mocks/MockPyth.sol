// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PythStructs} from "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

contract MockPyth {
    error MockPyth__StalePrice();

    uint256 public updateFee = 1;
    PythStructs.Price public currentPrice;

    function setUpdateFee(uint256 fee) external {
        updateFee = fee;
    }

    function setPrice(int64 price, int32 expo, uint256 publishTime) external {
        currentPrice = PythStructs.Price({price: price, conf: 0, expo: expo, publishTime: publishTime});
    }

    function getUpdateFee(bytes[] calldata) external view returns (uint256) {
        return updateFee;
    }

    function updatePriceFeeds(bytes[] calldata) external payable {
        require(msg.value >= updateFee, "insufficient-fee");
    }

    function getPriceNoOlderThan(bytes32, uint256 maxAge) external view returns (PythStructs.Price memory) {
        if (block.timestamp - currentPrice.publishTime > maxAge) {
            revert MockPyth__StalePrice();
        }
        return currentPrice;
    }

    function getPriceUnsafe(bytes32) external view returns (PythStructs.Price memory) {
        return currentPrice;
    }
}
