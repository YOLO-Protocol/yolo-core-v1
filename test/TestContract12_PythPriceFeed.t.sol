// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {PythPriceFeed} from "../src/oracles/PythPriceFeed.sol";
import {MockPyth} from "../src/mocks/MockPyth.sol";

contract TestContract12_PythPriceFeed is Test {
    MockPyth public mockPyth;
    PythPriceFeed public feed;
    bytes32 public constant PRICE_ID = bytes32(uint256(1));

    receive() external payable {}

    function setUp() public {
        mockPyth = new MockPyth();
        feed = new PythPriceFeed(
            address(mockPyth),
            PRICE_ID,
            "TEST/USD",
            60 // 60 seconds lag
        );
    }

    function test_Contract12_Case01_latestAnswerScaling() public {
        // 1000 * 10^-8 = 0.00001000
        // We want 8 decimals.
        // PythPriceFeed goal: return int256 with 8 decimals.

        // Example: $2500.00
        // Pyth might send: 250000 * 10^-2
        mockPyth.setPrice(250000, -2, block.timestamp);

        // Expected: 2500 * 10^8 = 250000000000
        int256 price = feed.latestAnswer();
        console.logInt(price);
        assertEq(price, 250000000000);
    }

    function test_Contract12_Case02_latestAnswerScalingNegativeExpo() public {
        // Example: 0.00012345
        // Pyth: 12345 * 10^-8
        mockPyth.setPrice(12345, -8, block.timestamp);

        // Expected: 0.00012345 * 10^8 = 12345
        int256 price = feed.latestAnswer();
        assertEq(price, 12345);
    }

    function test_Contract12_Case03_updatePriceRefundsExcess() public {
        // This test verifies that excess ETH is refunded.

        address payable user = payable(makeAddr("user"));
        uint256 fee = mockPyth.updateFee();
        uint256 sentAmount = 1 ether;
        vm.deal(user, sentAmount);

        bytes[] memory data = new bytes[](1);

        vm.prank(user);
        feed.updatePrice{value: sentAmount}(data);

        uint256 finalBalance = user.balance;
        uint256 contractBalance = address(feed).balance;

        console.log("Fee:", fee);
        console.log("Sent:", sentAmount);
        console.log("Spent:", sentAmount - finalBalance);
        console.log("Feed Contract Balance:", contractBalance);

        // If bug exists, contractBalance will be > 0 (sentAmount - fee)
        // And we (this) will have lost sentAmount

        // Ideally: contractBalance should be 0, and we should have lost only 'fee'.
        assertEq(contractBalance, 0, "Feed contract kept excess ETH");
        assertEq(sentAmount - finalBalance, fee, "Sender was not refunded");
    }

    function test_latestRoundDataReturnsExpectedTuple() public {
        uint256 publishTime = block.timestamp;
        mockPyth.setPrice(50000, -2, publishTime);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();

        assertEq(roundId, uint80(publishTime));
        assertEq(startedAt, publishTime);
        assertEq(updatedAt, publishTime);
        assertEq(answeredInRound, roundId);
        assertEq(answer, 50000000000);
    }

    function test_latestAnswerRevertsWhenStale() public {
        vm.warp(1 hours);
        mockPyth.setPrice(1000, -2, block.timestamp - 120);
        vm.expectRevert(MockPyth.MockPyth__StalePrice.selector);
        feed.latestAnswer();
    }
}
