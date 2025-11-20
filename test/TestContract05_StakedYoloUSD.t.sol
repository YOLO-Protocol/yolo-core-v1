// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StakedYoloUSD} from "../src/tokenization/StakedYoloUSD.sol";
import {IYoloHook} from "../src/interfaces/IYoloHook.sol";
import {IYoloOracle} from "../src/interfaces/IYoloOracle.sol";
import {ACLManager} from "../src/access/ACLManager.sol";
import {DataTypes} from "../src/libraries/DataTypes.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title TestContract05_StakedYoloUSD
 * @notice Unit tests for sUSY LP receipt token
 * @dev Tests two-asset breakdown, previews, and normalization without requiring full YoloHook setup
 */
contract TestContract05_StakedYoloUSD is Test {
    // ============================================================
    // CONTRACTS
    // ============================================================

    StakedYoloUSD public sUSYImpl;
    StakedYoloUSD public sUSY;
    ACLManager public aclManager;
    MockYoloHook public mockHook;

    // ============================================================
    // TEST ACCOUNTS
    // ============================================================

    address public admin = makeAddr("admin");
    address public assetsAdmin = makeAddr("assetsAdmin");
    address public user1 = makeAddr("user1");

    // ============================================================
    // SETUP
    // ============================================================

    function setUp() public {
        // Deploy ACL Manager (test contract becomes DEFAULT_ADMIN)
        aclManager = new ACLManager(address(this));

        // Setup roles (called from test contract which has DEFAULT_ADMIN)
        aclManager.createRole("ASSETS_ADMIN", bytes32(0));
        aclManager.grantRole(keccak256("ASSETS_ADMIN"), assetsAdmin);

        // Deploy mock YoloHook
        mockHook = new MockYoloHook();

        // Deploy sUSY implementation
        sUSYImpl = new StakedYoloUSD();

        // Deploy sUSY proxy
        bytes memory initData =
            abi.encodeWithSignature("initialize(address,address)", address(mockHook), address(aclManager));
        address sUSYProxy = address(new ERC1967Proxy(address(sUSYImpl), initData));
        sUSY = StakedYoloUSD(sUSYProxy);
    }

    // ============================================================
    // BOOTSTRAP TESTS (SUPPLY == 0)
    // ============================================================

    function test_Contract05_Case01_breakdownZeroSupplyReturnsBootstrapDefaults() public view {
        // When supply is 0, should return placeholder (1e18, 1e18)
        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        assertEq(usyPerSUSY, 1e18, "Bootstrap USY per sUSY should be 1e18");
        assertEq(usdcPerSUSY, 1e18, "Bootstrap USDC per sUSY should be 1e18");
    }

    function test_Contract05_Case02_approxUsdValueZeroSupplyReturns2e18() public view {
        // When supply is 0, approx USD value should be 2e18 (1 USY + 1 USDC)
        uint256 approxValue = sUSY.getApproxUsdValuePerSUSY();

        assertEq(approxValue, 2e18, "Bootstrap approx USD value should be 2e18");
    }

    // ============================================================
    // BREAKDOWN TESTS (WITH RESERVES)
    // ============================================================

    function test_Contract05_Case03_breakdownMatchesReservesAndSupply() public {
        // Setup: Mock reserves and mint some sUSY
        mockHook.setReserves(1000e18, 1000e6); // 1000 USY, 1000 USDC (6 decimals)
        mockHook.setUsdcDecimals(6);

        // Mint 500 sUSY to user1
        vm.prank(address(mockHook));
        sUSY.mint(user1, 500e18);

        // Get breakdown
        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        // Expected: (1000e18 * 1e18) / 500e18 = 2e18 USY per sUSY
        //           1000e6 USDC normalized to 1000e18, then (1000e18 * 1e18) / 500e18 = 2e18 USDC per sUSY
        assertEq(usyPerSUSY, 2e18, "USY per sUSY should be 2e18");
        assertEq(usdcPerSUSY, 2e18, "USDC per sUSY should be 2e18 (normalized)");
    }

    function test_Contract05_Case04_breakdownWithDifferentRatios() public {
        // Setup: Unbalanced reserves
        mockHook.setReserves(2000e18, 1000e6); // 2:1 ratio
        mockHook.setUsdcDecimals(6);

        // Mint 100 sUSY
        vm.prank(address(mockHook));
        sUSY.mint(user1, 100e18);

        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        // Expected: (2000e18 * 1e18) / 100e18 = 20e18 USY per sUSY
        //           1000e6 USDC normalized to 1000e18, then (1000e18 * 1e18) / 100e18 = 10e18 USDC per sUSY
        assertEq(usyPerSUSY, 20e18, "USY per sUSY should be 20e18");
        assertEq(usdcPerSUSY, 10e18, "USDC per sUSY should be 10e18");
    }

    // ============================================================
    // PREVIEW TESTS
    // ============================================================

    function test_Contract05_Case05_previewMintDelegatesToHook() public {
        // Setup reserves
        mockHook.setReserves(1000e18, 1000e6);
        mockHook.setUsdcDecimals(6);

        // Mint initial supply
        vm.prank(address(mockHook));
        sUSY.mint(user1, 500e18);

        // Preview should match what hook returns
        uint256 preview = sUSY.previewMint(100e18, 100e18);

        // This delegates to mockHook.previewAddLiquidity
        // Mock returns usyIn18 + usdcIn18 for simplicity
        assertEq(preview, 200e18, "Preview should delegate to hook");
    }

    function test_Contract05_Case06_previewRedeemDelegatesToHook() public {
        // Setup
        mockHook.setReserves(1000e18, 1000e6);
        mockHook.setUsdcDecimals(6);

        vm.prank(address(mockHook));
        sUSY.mint(user1, 500e18);

        // Preview redemption
        (uint256 usyOut, uint256 usdcOut) = sUSY.previewRedeem(100e18);

        // Mock returns proportional amounts
        // (100 * 1000) / 500 = 200 for each
        assertEq(usyOut, 200e18, "USY out should be proportional");
        assertEq(usdcOut, 200e18, "USDC out should be proportional (normalized)");
    }

    // ============================================================
    // DECIMAL NORMALIZATION TESTS
    // ============================================================

    function test_Contract05_Case07_normalizationUsdcWith6Decimals() public {
        // Setup: USDC with 6 decimals
        mockHook.setReserves(1000e18, 1000e6); // 1000 USDC (6 decimals)
        mockHook.setUsdcDecimals(6);

        vm.prank(address(mockHook));
        sUSY.mint(user1, 500e18);

        // Get normalized reserves
        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        // Both should be 18 decimals
        assertEq(usyPerSUSY, 2e18, "USY normalized correctly");
        assertEq(usdcPerSUSY, 2e18, "USDC normalized to 18 decimals");
    }

    function test_Contract05_Case08_normalizationUsdcWith18Decimals() public {
        // Setup: USDC with 18 decimals (some chains)
        mockHook.setReserves(1000e18, 1000e18); // Both 18 decimals
        mockHook.setUsdcDecimals(18);

        vm.prank(address(mockHook));
        sUSY.mint(user1, 500e18);

        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        assertEq(usyPerSUSY, 2e18, "USY should be 2e18");
        assertEq(usdcPerSUSY, 2e18, "USDC should be 2e18 (no conversion needed)");
    }

    // ============================================================
    // ACCESS CONTROL TESTS
    // ============================================================

    function test_Contract05_Case09_onlyHookCanMint() public {
        vm.prank(user1);
        vm.expectRevert(); // MintableIncentivizedERC20__OnlyYoloHook
        sUSY.mint(user1, 100e18);
    }

    function test_Contract05_Case10_onlyHookCanBurn() public {
        vm.prank(address(mockHook));
        sUSY.mint(user1, 100e18);

        vm.prank(user1);
        vm.expectRevert(); // MintableIncentivizedERC20__OnlyYoloHook
        sUSY.burn(user1, 50e18);
    }

    function test_Contract05_Case11_onlyAssetsAdminCanUpdateHook() public {
        address newHook = makeAddr("newHook");

        // Should fail from non-admin
        vm.prank(user1);
        vm.expectRevert(StakedYoloUSD.StakedYoloUSD__Unauthorized.selector);
        sUSY.updateYoloHook(newHook);

        // Should succeed from assetsAdmin
        vm.prank(assetsAdmin);
        sUSY.updateYoloHook(newHook);

        assertEq(sUSY.YOLO_HOOK(), newHook, "Hook should be updated");
    }

    // ============================================================
    // EDGE CASES
    // ============================================================

    function test_Contract05_Case12_breakdownWithSmallSupply() public {
        mockHook.setReserves(1e18, 1e6); // Minimal reserves
        mockHook.setUsdcDecimals(6);

        vm.prank(address(mockHook));
        sUSY.mint(user1, 1e18); // 1 sUSY

        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        assertEq(usyPerSUSY, 1e18, "USY per sUSY should be 1e18");
        assertEq(usdcPerSUSY, 1e18, "USDC per sUSY should be 1e18");
    }

    function test_Contract05_Case13_breakdownWithLargeSupply() public {
        mockHook.setReserves(1000000e18, 1000000e6); // 1M each
        mockHook.setUsdcDecimals(6);

        vm.prank(address(mockHook));
        sUSY.mint(user1, 500000e18); // 500K sUSY

        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        assertEq(usyPerSUSY, 2e18, "Large numbers should maintain precision");
        assertEq(usdcPerSUSY, 2e18, "Large numbers should maintain precision");
    }
}

// ============================================================
// MOCK YOLO HOOK
// ============================================================

contract MockYoloHook is IYoloHook {
    uint256 private _reserveUSY;
    uint256 private _reserveUSDC;
    uint8 private _usdcDecimals;

    function setReserves(uint256 reserveUSY, uint256 reserveUSDC) external {
        _reserveUSY = reserveUSY;
        _reserveUSDC = reserveUSDC;
    }

    function setUsdcDecimals(uint8 decimals) external {
        _usdcDecimals = decimals;
    }

    function getAnchorReserves() external view returns (uint256 reserveUSY, uint256 reserveUSDC) {
        return (_reserveUSY, _reserveUSDC);
    }

    function getAnchorReservesNormalized18() external view returns (uint256 reserveUSY18, uint256 reserveUSDC18) {
        reserveUSY18 = _reserveUSY;
        // Normalize USDC to 18 decimals
        if (_usdcDecimals == 6) {
            reserveUSDC18 = _reserveUSDC * 1e12;
        } else {
            reserveUSDC18 = _reserveUSDC;
        }
    }

    function usdcDecimals() external view returns (uint8) {
        return _usdcDecimals;
    }

    function totalAnchorReserveUSY() external view returns (uint256) {
        return _reserveUSY;
    }

    function totalAnchorReserveUSDC() external view returns (uint256) {
        return _reserveUSDC;
    }

    function getPendingSyntheticBurn() external pure returns (address token, uint256 amount) {
        return (address(0), 0);
    }

    function burnPendingSynthetic() external pure {}

    function previewAnchorSwap(bool, uint256) external pure returns (uint256 amountOut, uint256 feeAmount) {
        return (0, 0);
    }

    function previewAddLiquidity(uint256 usyIn18, uint256 usdcIn18) external pure returns (uint256 sUSYToMint) {
        // Simple mock: return sum for testing
        return usyIn18 + usdcIn18;
    }

    function previewRemoveLiquidity(uint256 sUSYAmount) external view returns (uint256 usyOut18, uint256 usdcOut18) {
        // Simple proportional calculation
        uint256 totalSupply = 500e18; // Hardcoded for mock
        usyOut18 = (sUSYAmount * _reserveUSY) / totalSupply;

        uint256 reserveUSDC18 = _usdcDecimals == 6 ? _reserveUSDC * 1e12 : _reserveUSDC;
        usdcOut18 = (sUSYAmount * reserveUSDC18) / totalSupply;
    }
    // Added to satisfy extended interface in some contexts (no-op/defaults)

    function usy() external pure returns (address) {
        return address(0);
    }

    function yoloOracle() external pure returns (IYoloOracle) {
        return IYoloOracle(address(0));
    }

    function treasury() external pure returns (address) {
        return address(0);
    }

    function usdc() external pure returns (address) {
        return address(0);
    }

    function poolManagerAddress() external pure returns (address) {
        return address(0);
    }

    function fundYLPWithUSY(uint256) external {}
    function settlePnLFromSynthetic(address, int256) external {}

    function addLiquidity(uint256, uint256, uint256, address) external pure returns (uint256, uint256, uint256) {
        return (0, 0, 0);
    }

    function removeLiquidity(uint256, uint256, uint256, address) external pure returns (uint256, uint256) {
        return (0, 0);
    }

    function unlockCallback(bytes calldata) external pure returns (bytes memory) {
        return "";
    }

    function isYoloAsset(address) external pure returns (bool) {
        return true;
    }

    function isWhitelistedCollateral(address) external pure returns (bool) {
        return true;
    }

    function getAllSyntheticAssets() external pure returns (address[] memory) {
        return new address[](0);
    }

    function createSyntheticAsset(string calldata, string calldata, uint8, address, address, uint256, uint256)
        external
        pure
        returns (address syntheticToken)
    {
        return address(0);
    }

    function deactivateSyntheticAsset(address) external pure {}

    function reactivateSyntheticAsset(address) external pure {}

    function getAllWhitelistedCollaterals() external pure returns (address[] memory) {
        return new address[](0);
    }

    function whitelistCollateral(address) external pure {}

    function configureLendingPair(
        address,
        address,
        address,
        address,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        uint256,
        bool,
        uint256
    ) external pure returns (bytes32 pairId) {
        return bytes32(0);
    }

    function updateRiskParameters(bytes32, uint256, uint256, uint256) external pure {}

    function updateBorrowRate(bytes32, uint256) external pure {}

    function updateOracle(IYoloOracle) external pure {}

    function updateYLPVault(address) external pure {}

    function upgradeImplementation(address, address) external pure {}

    function getAssetConfiguration(address) external pure returns (DataTypes.AssetConfiguration memory) {
        return DataTypes.AssetConfiguration({
            syntheticToken: address(0),
            oracleSource: address(0),
            maxSupply: 0,
            maxFlashLoanAmount: 0,
            isActive: false,
            createdAt: 0,
            perpConfig: DataTypes.PerpConfiguration({
                enabled: false,
                maxOpenInterestUsd: 0,
                maxLongOpenInterestUsd: 0,
                maxShortOpenInterestUsd: 0,
                maxLeverageBpsDay: 0,
                maxLeverageBpsCarryOvernight: 0,
                tradeSessionStart: 0,
                tradeSessionEnd: 0,
                marketState: DataTypes.TradeMarketState.OFFLINE
            })
        });
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function pause() external pure {}

    function unpause() external pure {}

    function getUserPositionKeys(address) external pure returns (DataTypes.UserPositionKey[] memory) {
        return new DataTypes.UserPositionKey[](0);
    }

    function getSyntheticCollaterals(address) external pure returns (address[] memory) {
        return new address[](0);
    }

    function getCollateralSynthetics(address) external pure returns (address[] memory) {
        return new address[](0);
    }

    function getUserTrades(address) external pure returns (DataTypes.TradePosition[] memory) {
        return new DataTypes.TradePosition[](0);
    }

    function getUserTrade(address, uint256) external pure returns (DataTypes.TradePosition memory position) {
        return position;
    }

    function getUserTradeCount(address) external pure returns (uint256) {
        return 0;
    }

    function getAnchorAmplification() external pure returns (uint256) {
        return 100; // Mock amplification
    }

    function getAnchorSwapFeeBps() external pure returns (uint256) {
        return 4; // Mock 0.04%
    }

    function MINIMUM_LIQUIDITY() external pure returns (uint256) {
        return 1000;
    }

    function LOOPER_ROLE() external pure returns (bytes32) {
        return keccak256("LOOPER");
    }

    function PRIVILEGED_FLASHLOANER_ROLE() external pure returns (bytes32) {
        return keccak256("PRIVILEGED_FLASHLOANER");
    }

    function getSyntheticSwapFeeBps() external pure returns (uint256) {
        return 30; // Mock 0.30%
    }

    function getFlashLoanFeeBps() external pure returns (uint256) {
        return 9; // Mock 0.09%
    }

    // CDP Operations (stub implementations for IYoloHook compliance)
    function borrow(address, uint256, address, uint256, address) external pure {}
    function repay(address, address, uint256, bool, address) external pure {}
    function renewPosition(address, address) external pure {}
    function depositCollateral(address, address, uint256, address) external pure {}

    function withdrawCollateral(address, address, uint256, address, address) external pure {}

    function liquidate(address, address, address, uint256) external pure {}

    function getPositionDebt(address, address, address) external pure returns (uint256) {
        return 0;
    }

    function getUserPosition(address, address, address) external pure returns (DataTypes.UserPosition memory position) {
        return position; // Return empty position
    }

    function getUserAccountData(address)
        external
        pure
        returns (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 ltv)
    {
        return (0, 0, 0);
    }

    function getPairConfiguration(address, address)
        external
        pure
        returns (DataTypes.PairConfiguration memory pairConfig)
    {
        return pairConfig; // Return empty config
    }

    function flashLoan(address, address, uint256, bytes calldata) external pure returns (bool) {
        return true;
    }

    function flashLoanBatch(address, address[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bool)
    {
        return true;
    }

    function leverageFlashLoan(address, address, uint256, bytes calldata) external pure returns (bool) {
        return true;
    }

    function maxFlashLoan(address) external pure returns (uint256 maxAmount) {
        return type(uint256).max;
    }

    function previewFlashLoanFee(address, uint256) external pure returns (uint256 fee) {
        return 0;
    }

    function updateMaxFlashLoanAmount(address, uint256) external pure {}

    function updateFlashLoanFee(uint256) external pure {}

    function togglePrivilegedLiquidator(bool) external pure {}

    function updateTradePosition(DataTypes.TradeUpdate calldata) external pure returns (uint256, int256, int256) {
        return (0, 0, 0);
    }

    function settlePnLFromPerps(address, address, int256) external pure {}

    function sUSY() external pure returns (address) {
        return address(0);
    }

    function ylpVault() external pure returns (address) {
        return address(0);
    }

    function setUserReferral(address, bytes32) external pure {}

    function getUserReferrals(address) external pure returns (address, address) {
        return (address(0), address(0));
    }

    function creditReferralReward(address, uint256, ReferralRewardType) external pure {}
}
