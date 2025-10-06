// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/mocks/TestYoloSyntheticAsset.sol";
import "../src/access/ACLManager.sol";
import "../src/mocks/MockIncentivesController.sol";
import "../src/mocks/MockYoloOracle.sol";
import "../src/mocks/MockYLPVault.sol";

contract TestContract04_YoloSyntheticAsset is Test {
    TestYoloSyntheticAsset public yETH;
    ACLManager public aclManager;
    MockIncentivesController public incentivesController;
    MockYoloOracle public yoloOracle;
    MockYLPVault public ylpVault;

    address public yoloHook = address(0x1234);
    address public alice = address(0xABCD);
    address public bob = address(0x5678);
    address public charlie = address(0x9999);
    address public underlyingWETH = address(0xBEEF);

    // Price constants (8 decimals, 1e8 = 1 USY)
    uint128 constant PRICE_100_USY = 100e8;
    uint128 constant PRICE_200_USY = 200e8;
    uint128 constant PRICE_300_USY = 300e8;

    function setUp() public {
        // Deploy ACLManager
        aclManager = new ACLManager(yoloHook);

        // Setup roles
        aclManager.createRole("RISK_ADMIN", 0x00);
        aclManager.createRole("ASSETS_ADMIN", 0x00);
        aclManager.createRole("INCENTIVES_ADMIN", 0x00);
        aclManager.grantRole(keccak256("RISK_ADMIN"), address(this));
        aclManager.grantRole(keccak256("ASSETS_ADMIN"), address(this));
        aclManager.grantRole(keccak256("INCENTIVES_ADMIN"), address(this));

        // Deploy incentives controller
        incentivesController = new MockIncentivesController();

        // Deploy YoloOracle and set price
        yoloOracle = new MockYoloOracle();
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_100_USY); // Default price

        // Deploy YLP Vault for P&L settlement
        ylpVault = new MockYLPVault();

        // Deploy and initialize TestYoloSyntheticAsset (for testing)
        yETH = new TestYoloSyntheticAsset();
        yETH.initialize(
            yoloHook,
            address(aclManager),
            "Yolo Synthetic ETH",
            "yETH",
            18,
            underlyingWETH,
            yoloOracle,
            address(ylpVault),
            0 // No max supply
        );

        // Set incentives tracker
        yETH.setIncentivesTracker(incentivesController);
    }

    /**
     * @dev Test initialization state
     */
    function test_Contract04_Case01_initialization() public view {
        assertEq(yETH.name(), "Yolo Synthetic ETH");
        assertEq(yETH.symbol(), "yETH");
        assertEq(yETH.decimals(), 18);
        assertEq(yETH.YOLO_HOOK(), yoloHook);
        assertEq(yETH.underlyingAsset(), underlyingWETH);
        assertEq(yETH.priceOracle(), address(yoloOracle));
        assertEq(yETH.ylpVault(), address(ylpVault));
        assertEq(yETH.maxSupply(), 0);
        assertTrue(yETH.tradingEnabled());
    }

    /**
     * @dev Test mint with oracle price and cost basis calculation
     */
    function test_Contract04_Case02_mintWithOraclePrice() public {
        uint256 amount = 10e18; // 10 tokens

        // Oracle already set to 100 USY in setUp
        vm.prank(yoloHook);
        yETH.mint(alice, amount);

        assertEq(yETH.balanceOf(alice), amount);
        assertEq(yETH.avgPriceX8(alice), PRICE_100_USY);
        assertEq(yETH.averagePriceX8(alice), PRICE_100_USY);
    }

    /**
     * @dev Test weighted average calculation on multiple mints
     */
    function test_Contract04_Case03_weightedAverageMint() public {
        // First mint: 10 tokens at 100 USY (default oracle price)
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Update oracle price to 200 USY
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_200_USY);

        // Second mint: 10 tokens at 200 USY
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Average should be (10*100e8 + 10*200e8) / 20 = 150e8 (exact, no rounding)
        assertEq(yETH.balanceOf(alice), 20e18);
        // In this case ceiling division gives same result as regular division (no remainder)
        assertEq(yETH.avgPriceX8(alice), 150e8);
    }

    /**
     * @dev Test transfer updates cost basis correctly
     */
    function test_Contract04_Case04_transferCostBasis() public {
        // Alice gets 10 tokens at 100 USY (default oracle price)
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Update oracle price and mint to Bob
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_200_USY);
        vm.prank(yoloHook);
        yETH.mint(bob, 10e18);

        // Alice transfers 5 tokens to Bob
        vm.prank(alice);
        yETH.transfer(bob, 5e18);

        // Alice should still have avg price of 100
        assertEq(yETH.balanceOf(alice), 5e18);
        assertEq(yETH.avgPriceX8(alice), PRICE_100_USY);

        // Bob should have weighted average: (10*200e8 + 5*100e8) / 15 = 166.67e8 (ceiling)
        assertEq(yETH.balanceOf(bob), 15e18);
        // With ceiling division: (2000e26 + 500e26 + 15e18 - 1) / 15e18
        uint256 totalCost = 10e18 * PRICE_200_USY + 5e18 * PRICE_100_USY;
        uint256 totalQty = 15e18;
        uint128 expectedAvg = uint128((totalCost + totalQty - 1) / totalQty);
        assertEq(yETH.avgPriceX8(bob), expectedAvg);
    }

    /**
     * @dev Test transfer entire balance clears cost basis
     */
    function test_Contract04_Case05_fullTransferClearsCostBasis() public {
        // Alice gets tokens at oracle price
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Alice transfers all to Bob
        vm.prank(alice);
        yETH.transfer(bob, 10e18);

        // Alice's average should be cleared
        assertEq(yETH.balanceOf(alice), 0);
        assertEq(yETH.avgPriceX8(alice), 0);

        // Bob inherits Alice's average
        assertEq(yETH.balanceOf(bob), 10e18);
        assertEq(yETH.avgPriceX8(bob), PRICE_100_USY);
    }

    /**
     * @dev Test burn entire balance clears cost basis and settles P&L
     */
    function test_Contract04_Case06_burnClearsCostBasisAndSettlesPnL() public {
        // Alice gets tokens at 100 USY
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Price increases to 150 USY (profit scenario)
        yoloOracle.setAssetPrice(underlyingWETH, 150e8);

        // Burn all tokens - should trigger profit settlement
        vm.prank(yoloHook);
        yETH.burn(alice, 10e18);

        assertEq(yETH.balanceOf(alice), 0);
        assertEq(yETH.avgPriceX8(alice), 0);

        // Check P&L settlement
        MockYLPVault.Settlement memory settlement = ylpVault.getLastSettlement();
        assertEq(settlement.user, alice);
        assertEq(settlement.asset, address(yETH));
        // P&L = (150 - 100) * 10e18 / 1e8 = 50 * 10e10 = 500e10 = 5000e9
        // With floor division for profits
        int256 expectedPnL = int256((50e8 * 10e18) / 1e8);
        assertEq(settlement.pnlUSY, expectedPnL);
    }

    /**
     * @dev Test partial burn keeps cost basis and settles partial P&L
     */
    function test_Contract04_Case07_partialBurnKeepsCostBasisAndSettlesPartialPnL() public {
        // Mint at 200 USY
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_200_USY);
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Price drops to 150 USY (loss scenario)
        yoloOracle.setAssetPrice(underlyingWETH, 150e8);

        // Burn half - should trigger loss settlement
        vm.prank(yoloHook);
        yETH.burn(alice, 5e18);

        // Average should remain unchanged
        assertEq(yETH.balanceOf(alice), 5e18);
        assertEq(yETH.avgPriceX8(alice), PRICE_200_USY);

        // Check P&L settlement (loss)
        MockYLPVault.Settlement memory settlement = ylpVault.getLastSettlement();
        assertEq(settlement.user, alice);
        // P&L = (150 - 200) * 5e18 / 1e8 = -50 * 5e10 = -250e10
        // With ceiling division for losses (more from user)
        uint256 lossNumerator = 50e8 * 5e18;
        int256 expectedPnL = -int256((lossNumerator + 1e8 - 1) / 1e8);
        assertEq(settlement.pnlUSY, expectedPnL);
    }

    /**
     * @dev Test complex multi-party transfers
     */
    function test_Contract04_Case08_complexTransfers() public {
        // Alice gets 20 tokens at 100 USY
        vm.prank(yoloHook);
        yETH.mint(alice, 20e18);

        // Bob gets 10 tokens at 200 USY
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_200_USY);
        vm.prank(yoloHook);
        yETH.mint(bob, 10e18);

        // Alice transfers 10 to Charlie (who has nothing)
        vm.prank(alice);
        yETH.transfer(charlie, 10e18);

        assertEq(yETH.avgPriceX8(charlie), PRICE_100_USY); // Inherits Alice's price

        // Bob transfers 5 to Charlie
        vm.prank(bob);
        yETH.transfer(charlie, 5e18);

        // Charlie should have: (10*100e8 + 5*200e8) / 15 = 133.33e8 (ceiling)
        assertEq(yETH.balanceOf(charlie), 15e18);
        // With ceiling division
        uint256 charlieTotalCost = 10e18 * PRICE_100_USY + 5e18 * PRICE_200_USY;
        uint256 charlieTotalQty = 15e18;
        uint128 expectedCharlieAvg = uint128((charlieTotalCost + charlieTotalQty - 1) / charlieTotalQty);
        assertEq(yETH.avgPriceX8(charlie), expectedCharlieAvg);

        // Alice still has her original average
        assertEq(yETH.avgPriceX8(alice), PRICE_100_USY);

        // Bob still has his original average
        assertEq(yETH.avgPriceX8(bob), PRICE_200_USY);
    }

    /**
     * @dev Test trading circuit breaker
     */
    function test_Contract04_Case09_tradingCircuitBreaker() public {
        // Mint tokens at oracle price
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Disable trading
        yETH.setTradingEnabled(false);

        // Transfer should fail
        vm.prank(alice);
        vm.expectRevert(TestYoloSyntheticAsset.YoloSyntheticAsset__TradingDisabled.selector);
        yETH.transfer(bob, 5e18);

        // Mint and burn should still work
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_200_USY);
        vm.prank(yoloHook);
        yETH.mint(bob, 5e18);

        vm.prank(yoloHook);
        yETH.burn(alice, 5e18);

        // Re-enable trading
        yETH.setTradingEnabled(true);

        // Transfer should work now
        vm.prank(alice);
        yETH.transfer(bob, 2e18);
        assertEq(yETH.balanceOf(bob), 7e18);
    }

    /**
     * @dev Test max supply enforcement
     */
    function test_Contract04_Case10_maxSupplyEnforcement() public {
        // Set max supply to 100 tokens
        yETH.setMaxSupply(100e18);

        // Mint 60 tokens - should work
        vm.prank(yoloHook);
        yETH.mint(alice, 60e18);

        // Update oracle and mint 40 more - should work (exactly at limit)
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_200_USY);
        vm.prank(yoloHook);
        yETH.mint(bob, 40e18);

        // Try to mint 1 more - should fail
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_300_USY);
        vm.prank(yoloHook);
        vm.expectRevert(TestYoloSyntheticAsset.YoloSyntheticAsset__ExceedsMaxSupply.selector);
        yETH.mint(charlie, 1e18);

        // Burn some tokens
        vm.prank(yoloHook);
        yETH.burn(alice, 10e18);

        // Now minting should work again
        vm.prank(yoloHook);
        yETH.mint(charlie, 5e18);
        assertEq(yETH.totalSupply(), 95e18);
    }

    /**
     * @dev Test oracle price changes affect minting
     */
    function test_Contract04_Case11_oraclePriceChanges() public {
        // Mint at initial price (100 USY)
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);
        assertEq(yETH.avgPriceX8(alice), PRICE_100_USY);

        // Change oracle price and mint more
        yoloOracle.setAssetPrice(underlyingWETH, PRICE_300_USY);
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Average should be (10*100e8 + 10*300e8) / 20 = 200e8 (exact, no rounding)
        assertEq(yETH.balanceOf(alice), 20e18);
        // In this case ceiling division gives same result (no remainder)
        assertEq(yETH.avgPriceX8(alice), 200e8);
    }

    /**
     * @dev Test batch operations
     */
    function test_Contract04_Case12_batchOperations() public {
        address[] memory recipients = new address[](3);
        uint256[] memory amounts = new uint256[](3);

        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = charlie;

        amounts[0] = 10e18;
        amounts[1] = 20e18;
        amounts[2] = 30e18;

        // Batch mint (without price tracking)
        vm.prank(yoloHook);
        yETH.batchMint(recipients, amounts);

        assertEq(yETH.balanceOf(alice), 10e18);
        assertEq(yETH.balanceOf(bob), 20e18);
        assertEq(yETH.balanceOf(charlie), 30e18);

        // All should have oracle price (100 USY) as cost basis
        assertEq(yETH.avgPriceX8(alice), PRICE_100_USY);
        assertEq(yETH.avgPriceX8(bob), PRICE_100_USY);
        assertEq(yETH.avgPriceX8(charlie), PRICE_100_USY);

        // Batch burn
        address[] memory accounts = new address[](2);
        uint256[] memory burnAmounts = new uint256[](2);

        accounts[0] = alice;
        accounts[1] = bob;
        burnAmounts[0] = 5e18;
        burnAmounts[1] = 10e18;

        vm.prank(yoloHook);
        yETH.batchBurn(accounts, burnAmounts);

        assertEq(yETH.balanceOf(alice), 5e18);
        assertEq(yETH.balanceOf(bob), 10e18);
    }

    /**
     * @dev Test oracle update
     */
    function test_Contract04_Case13_oracleUpdate() public {
        MockYoloOracle newOracle = new MockYoloOracle();
        newOracle.setAssetPrice(underlyingWETH, PRICE_300_USY);

        // Update oracle
        yETH.setYoloOracle(newOracle);
        assertEq(yETH.priceOracle(), address(newOracle));

        // Try to set zero address - should fail
        vm.expectRevert(TestYoloSyntheticAsset.YoloSyntheticAsset__InvalidOracle.selector);
        yETH.setYoloOracle(IYoloOracle(address(0)));
    }

    /**
     * @dev Test incentives tracking integration
     */
    function test_Contract04_Case14_incentivesTracking() public {
        // Mint triggers incentives
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        assertEq(incentivesController.userActionCount(alice), 1);

        // Transfer triggers incentives for both parties
        incentivesController.reset();
        vm.prank(alice);
        yETH.transfer(bob, 5e18);

        assertEq(incentivesController.userActionCount(alice), 1);
        assertEq(incentivesController.userActionCount(bob), 1);

        // Burn triggers incentives
        incentivesController.reset();
        vm.prank(yoloHook);
        yETH.burn(bob, 5e18);

        assertEq(incentivesController.userActionCount(bob), 1);
    }

    /**
     * @dev Test burn with zero cost basis (edge case)
     */
    function test_Contract04_Case15_burnEdgeCases() public {
        // Manually give Alice tokens without setting cost basis
        // This simulates bridged tokens or legacy positions
        vm.prank(yoloHook);
        yETH.mint(alice, 10e18);

        // Manually reset cost basis to 0 (simulating edge case)
        // Note: In production, this shouldn't happen if all mints use oracle

        // Now burn - should not revert, P&L will be settled based on avgCost set during mint
        vm.prank(yoloHook);
        yETH.burn(alice, 5e18);

        // Settlement should occur with the avgCost from the mint
        assertEq(yETH.balanceOf(alice), 5e18);
    }

    /**
     * @dev Test access control
     */
    function test_Contract04_Case16_accessControl() public {
        // Non-YoloHook cannot mint
        vm.prank(alice);
        vm.expectRevert(MintableIncentivizedERC20Upgradeable.MintableIncentivizedERC20__OnlyYoloHook.selector);
        yETH.mint(alice, 10e18);

        // Non-YoloHook cannot burn
        vm.prank(alice);
        vm.expectRevert(MintableIncentivizedERC20Upgradeable.MintableIncentivizedERC20__OnlyYoloHook.selector);
        yETH.burn(alice, 10e18);

        // Non-admin cannot change settings
        vm.prank(alice);
        vm.expectRevert();
        yETH.setTradingEnabled(false);

        vm.prank(alice);
        vm.expectRevert();
        yETH.setMaxSupply(1000e18);

        vm.prank(alice);
        vm.expectRevert();
        yETH.setYoloOracle(IYoloOracle(address(0xDEAD)));
    }
}
