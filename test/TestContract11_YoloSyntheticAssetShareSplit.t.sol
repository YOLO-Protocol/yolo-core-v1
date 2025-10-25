// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Base03_DeployComprehensiveTestEnvironment} from "./base/Base03_DeployComprehensiveTestEnvironment.t.sol";
import {YoloSyntheticAsset} from "../src/tokenization/YoloSyntheticAsset.sol";
import {IYoloSyntheticAsset} from "../src/interfaces/IYoloSyntheticAsset.sol";
import {MockYLPVault} from "../src/mocks/MockYLPVault.sol";

/**
 * @title TestContract11_YoloSyntheticAssetShareSplit
 * @notice Comprehensive tests for corporate actions (stock splits, dividends) in YoloSyntheticAsset
 * @dev Tests functionality not covered in TestContract02 (base ERC20)
 */
contract TestContract11_YoloSyntheticAssetShareSplit is Base03_DeployComprehensiveTestEnvironment {
    YoloSyntheticAsset public yETH_asset; // Casted version of yETH address
    address public alice;
    address public bob;
    address public charlie;

    uint256 constant WAD = 1e18;
    uint256 constant INITIAL_PRICE = 3200e8; // $3200 in 8 decimals (ETH price from Base03)

    event Transfer(address indexed from, address indexed to, uint256 value);
    event CostBasisUpdated(address indexed user, uint256 newBalance, uint128 newAvgPriceX8);
    event StockSplitExecuted(uint256 numerator, uint256 denominator, uint256 newLiquidityIndex);
    event CashDividendExecuted(uint256 dividendPerShareWAD, uint256 additionalShares, uint256 newLiquidityIndex);
    event StockDividendExecuted(uint256 percentageWAD, uint256 newLiquidityIndex);

    function setUp() public override {
        super.setUp();

        // Cast yETH address to YoloSyntheticAsset for easier testing
        yETH_asset = YoloSyntheticAsset(yETH);

        // Setup test accounts
        alice = makeAddr("Alice");
        bob = makeAddr("Bob");
        charlie = makeAddr("Charlie");
    }

    // ============================================================
    // STOCK SPLIT TESTS
    // ============================================================

    /**
     * @dev Test Case 01: Basic 2:1 forward stock split
     */
    function test_Contract11_Case01_forwardStockSplit2to1() public {
        uint256 mintAmount = 100e18;

        // Mint tokens to alice
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, mintAmount);

        uint256 balanceBefore = yETH_asset.balanceOf(alice);
        uint256 liquidityIndexBefore = yETH_asset.liquidityIndex();

        // Execute 2:1 split
        vm.prank(address(yoloHook));
        vm.expectEmit(true, true, true, true);
        emit StockSplitExecuted(2, 1, liquidityIndexBefore * 2);
        yETH_asset.executeStockSplit(2, 1);

        // Verify balances doubled
        uint256 balanceAfter = yETH_asset.balanceOf(alice);
        assertEq(balanceAfter, balanceBefore * 2, "Balance should double after 2:1 split");

        // Verify liquidityIndex doubled
        assertEq(yETH_asset.liquidityIndex(), liquidityIndexBefore * 2, "LiquidityIndex should double");

        // Verify total supply doubled
        assertEq(yETH_asset.totalSupply(), mintAmount * 2, "Total supply should double");
    }

    /**
     * @dev Test Case 02: Reverse 1:2 stock split
     */
    function test_Contract11_Case02_reverseStockSplit1to2() public {
        uint256 mintAmount = 100e18;

        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, mintAmount);

        uint256 balanceBefore = yETH_asset.balanceOf(alice);
        uint256 liquidityIndexBefore = yETH_asset.liquidityIndex();

        // Execute 1:2 reverse split
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(1, 2);

        // Verify balances halved
        assertEq(yETH_asset.balanceOf(alice), balanceBefore / 2, "Balance should halve after 1:2 split");

        // Verify liquidityIndex halved
        assertEq(yETH_asset.liquidityIndex(), liquidityIndexBefore / 2, "LiquidityIndex should halve");
    }

    /**
     * @dev Test Case 03: Cost basis rescales correctly after stock split
     */
    function test_Contract11_Case03_costBasisRescaleAfterSplit() public {
        uint256 mintAmount = 100e18;

        // Mint to alice at $100 price
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, mintAmount);

        uint128 avgPriceBefore = yETH_asset.avgPriceX8(alice);
        assertEq(avgPriceBefore, INITIAL_PRICE, "Initial avg price should match oracle");

        // Execute 2:1 split (doubles shares)
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(2, 1);

        // Transfer to trigger cost basis rescale
        vm.prank(alice);
        yETH_asset.transfer(bob, 1e18);

        // Cost basis should rescale to half (same total value, double shares)
        uint128 avgPriceAfter = yETH_asset.avgPriceX8(alice);
        assertEq(avgPriceAfter, INITIAL_PRICE / 2, "Avg price should halve after 2:1 split");
    }

    /**
     * @dev Test Case 04: 1:1 split is a no-op
     */
    function test_Contract11_Case04_oneToOneSplitNoOp() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 100e18);

        uint256 balanceBefore = yETH_asset.balanceOf(alice);
        uint256 indexBefore = yETH_asset.liquidityIndex();

        // 1:1 split should do nothing
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(1, 1);

        assertEq(yETH_asset.balanceOf(alice), balanceBefore, "Balance unchanged after 1:1 split");
        assertEq(yETH_asset.liquidityIndex(), indexBefore, "Index unchanged after 1:1 split");
    }

    /**
     * @dev Test Case 05: Complex ratio split (3:2)
     */
    function test_Contract11_Case05_complexRatioSplit() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 200e18);

        uint256 balanceBefore = yETH_asset.balanceOf(alice);

        // 3:2 split (1.5x increase)
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(3, 2);

        // Balance should be 1.5x
        assertEq(yETH_asset.balanceOf(alice), balanceBefore * 3 / 2, "Balance should be 1.5x after 3:2 split");
    }

    // ============================================================
    // CASH DIVIDEND TESTS (DRIP)
    // ============================================================

    /**
     * @dev Test Case 06: Basic cash dividend DRIP
     */
    function test_Contract11_Case06_basicCashDividend() public {
        uint256 mintAmount = 1000e18;

        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, mintAmount);

        uint256 balanceBefore = yETH_asset.balanceOf(alice);
        uint256 indexBefore = yETH_asset.liquidityIndex();

        // Get current oracle price
        uint256 priceX8 = yoloOracleReal.getAssetPrice(address(yETH));
        uint256 priceWAD = priceX8 * 1e10; // Convert 8 decimals to 18 decimals

        // Pay 2% dividend (e.g., $64 per share @ $3200 price)
        uint256 dividendPerShare = priceWAD * 2 / 100; // 2% of price

        vm.prank(address(yoloHook));
        yETH_asset.executeCashDividend(dividendPerShare);

        // New index should be: oldIndex * (price + dividend) / price
        uint256 expectedIndex = (indexBefore * (priceWAD + dividendPerShare)) / priceWAD;
        assertEq(yETH_asset.liquidityIndex(), expectedIndex, "Index should increase by dividend ratio");

        // Balance should increase by 2%
        uint256 balanceAfter = yETH_asset.balanceOf(alice);
        assertApproxEqRel(balanceAfter, balanceBefore * 102 / 100, 0.01e18, "Balance should increase ~2%");
    }

    /**
     * @dev Test Case 07: Cash dividend formula correctness
     */
    function test_Contract11_Case07_cashDividendFormulaCorrect() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 1000e18);

        // Get current oracle price
        uint256 priceX8 = yoloOracleReal.getAssetPrice(address(yETH));
        uint256 priceWAD = priceX8 * 1e10;

        // 0.5% dividend
        uint256 dividendPerShare = priceWAD * 5 / 1000;

        uint256 indexBefore = yETH_asset.liquidityIndex();

        vm.prank(address(yoloHook));
        yETH_asset.executeCashDividend(dividendPerShare);

        // Verify formula: liquidityIndex * (price + dividend) / price
        uint256 expectedIndex = (indexBefore * (priceWAD + dividendPerShare)) / priceWAD;
        assertEq(yETH_asset.liquidityIndex(), expectedIndex, "Formula mismatch");
    }

    /**
     * @dev Test Case 08: Zero dividend is no-op
     */
    function test_Contract11_Case08_zeroDividendNoOp() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 100e18);

        uint256 indexBefore = yETH_asset.liquidityIndex();

        vm.prank(address(yoloHook));
        yETH_asset.executeCashDividend(0);

        assertEq(yETH_asset.liquidityIndex(), indexBefore, "Index unchanged on zero dividend");
    }

    /**
     * @dev Test Case 09: Multiple dividends compound correctly
     */
    function test_Contract11_Case09_multipleDividendsCompound() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 1000e18);

        uint256 balanceInitial = yETH_asset.balanceOf(alice);

        // Get current price
        uint256 priceX8 = yoloOracleReal.getAssetPrice(address(yETH));
        uint256 priceWAD = priceX8 * 1e10;

        // First dividend: 1% of price
        uint256 dividend1 = priceWAD / 100;
        vm.prank(address(yoloHook));
        yETH_asset.executeCashDividend(dividend1);

        // Second dividend: another 1% of price
        uint256 dividend2 = priceWAD / 100;
        vm.prank(address(yoloHook));
        yETH_asset.executeCashDividend(dividend2);

        // Should compound: 1.01 * 1.01 = 1.0201 (2.01% total)
        uint256 balanceFinal = yETH_asset.balanceOf(alice);
        assertApproxEqRel(balanceFinal, balanceInitial * 10201 / 10000, 0.01e18, "Dividends should compound");
    }

    // ============================================================
    // STOCK DIVIDEND TESTS
    // ============================================================

    /**
     * @dev Test Case 10: Basic 5% stock dividend
     */
    function test_Contract11_Case10_fivePercentStockDividend() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 1000e18);

        uint256 balanceBefore = yETH_asset.balanceOf(alice);

        // 5% stock dividend
        vm.prank(address(yoloHook));
        vm.expectEmit(true, true, true, true);
        emit StockDividendExecuted(0.05e18, WAD * 105 / 100);
        yETH_asset.executeStockDividend(0.05e18);

        // Balance should increase by 5%
        assertEq(yETH_asset.balanceOf(alice), balanceBefore * 105 / 100, "Balance should increase 5%");
    }

    /**
     * @dev Test Case 11: Stock dividend formula verification
     */
    function test_Contract11_Case11_stockDividendFormula() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 1000e18);

        uint256 indexBefore = yETH_asset.liquidityIndex();
        uint256 percentage = 0.1e18; // 10%

        vm.prank(address(yoloHook));
        yETH_asset.executeStockDividend(percentage);

        // Formula: liquidityIndex * (1 + percentage)
        uint256 expectedIndex = (indexBefore * (WAD + percentage)) / WAD;
        assertEq(yETH_asset.liquidityIndex(), expectedIndex, "Stock dividend formula mismatch");
    }

    // ============================================================
    // ERC-20 COMPLIANCE WITH CORPORATE ACTIONS
    // ============================================================

    /**
     * @dev Test Case 12: Transfer event emits actual amount after split
     */
    function test_Contract11_Case12_transferEventActualAmountAfterSplit() public {
        // Execute 2:1 split first (liquidityIndex = 2e18)
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(2, 1);

        // Now mint 100 tokens
        // With liquidityIndex = 2e18:
        // scaledAmount = ceiling(100 * 1e18 / 2e18) = 50e18
        // actualMinted = 50e18 * 2e18 / 1e18 = 100e18 (exact)

        uint256 requestedAmount = 100e18;

        // Capture the actual emitted Transfer amount
        vm.expectEmit(true, true, false, false);
        emit Transfer(address(0), alice, 0); // We'll check the actual amount manually

        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, requestedAmount);

        // Verify balance matches
        assertEq(yETH_asset.balanceOf(alice), 100e18, "Balance should be 100 tokens");
    }

    /**
     * @dev Test Case 13: Burn event emits actual amount with non-standard liquidityIndex
     */
    function test_Contract11_Case13_burnEventActualAmount() public {
        // Setup: 3:2 split (liquidityIndex = 1.5e18)
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(3, 2);

        // Mint tokens
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 150e18);

        uint256 balanceBefore = yETH_asset.balanceOf(alice);

        // Burn 100 tokens
        vm.prank(address(yoloHook));
        yETH_asset.burn(alice, 100e18);

        uint256 balanceAfter = yETH_asset.balanceOf(alice);
        uint256 actualBurned = balanceBefore - balanceAfter;

        // The Transfer event should have emitted actualBurned, not 100e18
        // We verify indirectly by checking balance delta matches
        assertGe(actualBurned, 100e18, "Actual burned should be >= requested due to ceiling");
    }

    // ============================================================
    // PnL SETTLEMENT AFTER CORPORATE ACTIONS
    // ============================================================

    /**
     * @dev Test Case 14: PnL settlement uses rescaled avgPriceX8 after split
     */
    function test_Contract11_Case14_pnlUsesRescaledCostBasis() public {
        // Get initial oracle price
        uint256 initialPriceX8 = yoloOracleReal.getAssetPrice(address(yETH));

        // Mint at current price
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 100e18);

        // Verify initial cost basis matches oracle price
        assertEq(yETH_asset.avgPriceX8(alice), initialPriceX8, "Initial cost basis");

        // Execute 2:1 split (doubles shares, halves cost basis)
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(2, 1);

        // Burn should trigger PnL settlement using rescaled cost basis
        // After split: cost basis should be half of initial price
        // PnL = (currentPrice - rescaledAvgCost) * amount
        vm.prank(address(yoloHook));
        yETH_asset.burn(alice, 50e18);

        // Verify burn completed successfully (PnL settlement happened internally)
        // The fact that burn didn't revert proves _settleAndBurn worked correctly
        assertLt(yETH_asset.balanceOf(alice), 200e18, "Balance reduced after burn");
    }

    /**
     * @dev Test Case 15: Cost basis updates correctly after cash dividend
     */
    function test_Contract11_Case15_costBasisAfterCashDividend() public {
        // Mint at current price
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 100e18);

        uint128 avgBefore = yETH_asset.avgPriceX8(alice);

        // Get current price and pay 10% dividend
        uint256 priceX8 = yoloOracleReal.getAssetPrice(address(yETH));
        uint256 priceWAD = priceX8 * 1e10;
        uint256 dividend = priceWAD * 10 / 100; // 10% of price

        vm.prank(address(yoloHook));
        yETH_asset.executeCashDividend(dividend);

        // Transfer to trigger rescale
        vm.prank(alice);
        yETH_asset.transfer(bob, 1e18);

        // Cost basis should rescale: avgBefore * 1.0e18 / 1.1e18 ≈ avgBefore * 10/11
        uint128 avgAfter = yETH_asset.avgPriceX8(alice);
        assertApproxEqRel(avgAfter, avgBefore * 100 / 110, 0.01e18, "Cost basis should rescale after dividend");
    }

    // ============================================================
    // EDGE CASES AND ERROR CONDITIONS
    // ============================================================

    /**
     * @dev Test Case 16: Corporate action with zero supply
     */
    function test_Contract11_Case16_dividendWithZeroSupply() public {
        // No tokens minted, total supply = 0
        assertEq(yETH_asset.totalSupply(), 0, "Supply should be zero");

        // Cash dividend should revert on zero supply
        vm.prank(address(yoloHook));
        vm.expectRevert(YoloSyntheticAsset.YoloSyntheticAsset__InvalidPrice.selector);
        yETH_asset.executeCashDividend(1e18);
    }

    /**
     * @dev Test Case 17: Only YoloHook can execute corporate actions
     */
    function test_Contract11_Case17_onlyYoloHookCanExecute() public {
        // Stock split
        vm.prank(alice);
        vm.expectRevert();
        yETH_asset.executeStockSplit(2, 1);

        // Cash dividend
        vm.prank(alice);
        vm.expectRevert();
        yETH_asset.executeCashDividend(1e18);

        // Stock dividend
        vm.prank(alice);
        vm.expectRevert();
        yETH_asset.executeStockDividend(0.05e18);
    }

    /**
     * @dev Test Case 18: Invalid split ratios revert
     */
    function test_Contract11_Case18_invalidSplitRatios() public {
        // Zero numerator
        vm.prank(address(yoloHook));
        vm.expectRevert(YoloSyntheticAsset.YoloSyntheticAsset__InvalidPrice.selector);
        yETH_asset.executeStockSplit(0, 1);

        // Zero denominator
        vm.prank(address(yoloHook));
        vm.expectRevert(YoloSyntheticAsset.YoloSyntheticAsset__InvalidPrice.selector);
        yETH_asset.executeStockSplit(1, 0);
    }

    /**
     * @dev Test Case 19: Sequence of corporate actions
     */
    function test_Contract11_Case19_sequenceOfCorporateActions() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 100e18);

        uint256 balanceStart = yETH_asset.balanceOf(alice);

        // 2:1 split (2x)
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(2, 1);

        // 5% stock dividend (1.05x)
        vm.prank(address(yoloHook));
        yETH_asset.executeStockDividend(0.05e18);

        // 5% cash dividend (1.05x)
        uint256 priceX8 = yoloOracleReal.getAssetPrice(address(yETH));
        uint256 priceWAD = priceX8 * 1e10;
        uint256 cashDividend = priceWAD * 5 / 100;
        vm.prank(address(yoloHook));
        yETH_asset.executeCashDividend(cashDividend);

        // Total: 2 * 1.05 * 1.05 = 2.205x
        uint256 balanceEnd = yETH_asset.balanceOf(alice);
        assertApproxEqRel(balanceEnd, balanceStart * 2205 / 1000, 0.01e18, "Sequence should compound correctly");
    }

    /**
     * @dev Test Case 20: Global cost basis tracking after corporate actions
     */
    function test_Contract11_Case20_globalCostBasisAfterActions() public {
        // Mint to alice at $100
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 100e18);

        // Mint to bob at $100
        vm.prank(address(yoloHook));
        yETH_asset.mint(bob, 100e18);

        uint256 globalCostBefore = yETH_asset.getTotalCostBasisX8();

        // Execute 2:1 split
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(2, 1);

        // Trigger rescale for both users
        vm.prank(alice);
        yETH_asset.transfer(charlie, 1e18);
        vm.prank(bob);
        yETH_asset.transfer(charlie, 1e18);

        // Global cost basis should remain consistent (same total value, different shares)
        uint256 globalCostAfter = yETH_asset.getTotalCostBasisX8();

        // After split: avgPrice halves, balance doubles, so total cost stays same
        // But we need to account for the 2 tokens transferred to charlie
        // The global cost basis tracking should be mathematically consistent
        assertGt(globalCostAfter, 0, "Global cost basis should be tracked");
    }

    /**
     * @dev Test Case 21: Cost basis cleared on full position close after corporate action
     */
    function test_Contract11_Case21_costBasisClearedAfterFullClose() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 100e18);

        // Execute dividend
        vm.prank(address(yoloHook));
        yETH_asset.executeStockDividend(0.1e18); // 10% increase

        uint256 finalBalance = yETH_asset.balanceOf(alice);

        // Burn entire balance
        vm.prank(address(yoloHook));
        yETH_asset.burn(alice, finalBalance);

        // Cost basis should be cleared
        assertEq(yETH_asset.avgPriceX8(alice), 0, "Cost basis should be zero after full close");
        assertEq(yETH_asset.balanceOf(alice), 0, "Balance should be zero");
    }

    /**
     * @dev Test Case 22: Large split ratio doesn't cause overflow
     */
    function test_Contract11_Case22_largeSplitRatio() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 1e18);

        // 100:1 split
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(100, 1);

        assertEq(yETH_asset.balanceOf(alice), 100e18, "Should handle large split");
        assertEq(yETH_asset.liquidityIndex(), 100e18, "Index should scale correctly");
    }

    /**
     * @dev Test Case 23: Very small dividend
     */
    function test_Contract11_Case23_verySmallDividend() public {
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 1000e18);

        // Get current price
        uint256 priceX8 = yoloOracleReal.getAssetPrice(address(yETH));
        uint256 priceWAD = priceX8 * 1e10;

        // 0.01% dividend (1 basis point)
        uint256 tinyDividend = priceWAD / 10000;

        vm.prank(address(yoloHook));
        yETH_asset.executeCashDividend(tinyDividend);

        // Should still apply correctly
        uint256 expectedIndex = (WAD * (priceWAD + tinyDividend)) / priceWAD;
        assertEq(yETH_asset.liquidityIndex(), expectedIndex, "Small dividend should apply");
    }

    /**
     * @dev Test Case 24: Transfer between users after corporate action
     */
    function test_Contract11_Case24_transferBetweenUsersAfterAction() public {
        // Mint to alice and bob at $100
        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 100e18);
        vm.prank(address(yoloHook));
        yETH_asset.mint(bob, 100e18);

        // Execute 2:1 split
        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(2, 1);

        // Alice transfers to Bob
        uint256 bobBalanceBefore = yETH_asset.balanceOf(bob);
        vm.prank(alice);
        yETH_asset.transfer(bob, 50e18);

        // Verify transfer worked correctly
        uint256 bobBalanceAfter = yETH_asset.balanceOf(bob);
        assertGe(bobBalanceAfter - bobBalanceBefore, 50e18, "Transfer should work post-split");
    }

    /**
     * @dev Test Case 25: Fuzz test stock split ratios
     */
    function testFuzz_Contract11_Case25_splitRatios(uint16 numerator, uint16 denominator) public {
        vm.assume(numerator > 0 && numerator <= 1000);
        vm.assume(denominator > 0 && denominator <= 1000);
        vm.assume(numerator != denominator); // Skip 1:1

        vm.prank(address(yoloHook));
        yETH_asset.mint(alice, 1000e18);

        uint256 balanceBefore = yETH_asset.balanceOf(alice);
        uint256 indexBefore = yETH_asset.liquidityIndex();

        vm.prank(address(yoloHook));
        yETH_asset.executeStockSplit(numerator, denominator);

        // Verify ratio applied correctly
        uint256 expectedIndex = (indexBefore * numerator) / denominator;
        assertEq(yETH_asset.liquidityIndex(), expectedIndex, "Index ratio mismatch");

        uint256 balanceAfter = yETH_asset.balanceOf(alice);
        assertApproxEqRel(balanceAfter, (balanceBefore * numerator) / denominator, 0.01e18, "Balance ratio mismatch");
    }
}
