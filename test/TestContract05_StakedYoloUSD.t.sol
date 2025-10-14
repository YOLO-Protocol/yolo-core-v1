// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {StakedYoloUSD} from "../src/tokenization/StakedYoloUSD.sol";
import {IYoloHook} from "../src/interfaces/IYoloHook.sol";
import {ACLManager} from "../src/access/ACLManager.sol";
import {IACLManager} from "../src/interfaces/IACLManager.sol";
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
        sUSYImpl = new StakedYoloUSD(IACLManager(address(aclManager)));

        // Deploy sUSY proxy
        bytes memory initData = abi.encodeWithSignature("initialize(address)", address(mockHook));
        address sUSYProxy = address(new ERC1967Proxy(address(sUSYImpl), initData));
        sUSY = StakedYoloUSD(sUSYProxy);
    }

    // ============================================================
    // BOOTSTRAP TESTS (SUPPLY == 0)
    // ============================================================

    function test_BreakdownZeroSupply_ReturnsBootstrapDefaults() public view {
        // When supply is 0, should return placeholder (1e18, 1e18)
        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        assertEq(usyPerSUSY, 1e18, "Bootstrap USY per sUSY should be 1e18");
        assertEq(usdcPerSUSY, 1e18, "Bootstrap USDC per sUSY should be 1e18");
    }

    function test_ApproxUsdValue_ZeroSupply_Returns2e18() public view {
        // When supply is 0, approx USD value should be 2e18 (1 USY + 1 USDC)
        uint256 approxValue = sUSY.getApproxUsdValuePerSUSY();

        assertEq(approxValue, 2e18, "Bootstrap approx USD value should be 2e18");
    }

    // ============================================================
    // BREAKDOWN TESTS (WITH RESERVES)
    // ============================================================

    function test_BreakdownMatchesReservesAndSupply() public {
        // Setup: Mock reserves and mint some sUSY
        mockHook.setReserves(1000e18, 1000e6); // 1000 USY, 1000 USDC (6 decimals)
        mockHook.setUsdcDecimals(6);

        // Mint 500 sUSY to user1
        vm.prank(address(mockHook));
        sUSY.mint(user1, 500e18);

        // Get breakdown
        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        // Expected: (1000e18 * 1e18) / 500e18 = 2e18 USY per sUSY
        //           (1000e18 * 1e18) / 500e18 = 2e18 USDC per sUSY (normalized)
        assertEq(usyPerSUSY, 2e18, "USY per sUSY should be 2e18");
        assertEq(usdcPerSUSY, 2e18, "USDC per sUSY should be 2e18 (normalized)");
    }

    function test_BreakdownWithDifferentRatios() public {
        // Setup: Unbalanced reserves
        mockHook.setReserves(2000e18, 1000e6); // 2:1 ratio
        mockHook.setUsdcDecimals(6);

        // Mint 100 sUSY
        vm.prank(address(mockHook));
        sUSY.mint(user1, 100e18);

        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        // Expected: (2000e18 * 1e18) / 100e18 = 20e18 USY per sUSY
        //           (1000e18 * 1e18) / 100e18 = 10e18 USDC per sUSY
        assertEq(usyPerSUSY, 20e18, "USY per sUSY should be 20e18");
        assertEq(usdcPerSUSY, 10e18, "USDC per sUSY should be 10e18");
    }

    // ============================================================
    // PREVIEW TESTS
    // ============================================================

    function test_PreviewMint_DelegatesToHook() public {
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

    function test_PreviewRedeem_DelegatesToHook() public {
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

    function test_Normalization_UsdcWith6Decimals() public {
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

    function test_Normalization_UsdcWith18Decimals() public {
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

    function test_OnlyHookCanMint() public {
        vm.prank(user1);
        vm.expectRevert(StakedYoloUSD.OnlyYoloHook.selector);
        sUSY.mint(user1, 100e18);
    }

    function test_OnlyHookCanBurn() public {
        vm.prank(address(mockHook));
        sUSY.mint(user1, 100e18);

        vm.prank(user1);
        vm.expectRevert(StakedYoloUSD.OnlyYoloHook.selector);
        sUSY.burn(user1, 50e18);
    }

    function test_OnlyAssetsAdminCanUpdateHook() public {
        address newHook = makeAddr("newHook");

        // Should fail from non-admin
        vm.prank(user1);
        vm.expectRevert(StakedYoloUSD.Unauthorized.selector);
        sUSY.updateYoloHook(newHook);

        // Should succeed from assetsAdmin
        vm.prank(assetsAdmin);
        sUSY.updateYoloHook(newHook);

        assertEq(address(sUSY.yoloHook()), newHook, "Hook should be updated");
    }

    // ============================================================
    // EDGE CASES
    // ============================================================

    function test_BreakdownWithSmallSupply() public {
        mockHook.setReserves(1e18, 1e6); // Minimal reserves
        mockHook.setUsdcDecimals(6);

        vm.prank(address(mockHook));
        sUSY.mint(user1, 1e18); // 1 sUSY

        (uint256 usyPerSUSY, uint256 usdcPerSUSY) = sUSY.getReserveBreakdownPerSUSY();

        assertEq(usyPerSUSY, 1e18, "USY per sUSY should be 1e18");
        assertEq(usdcPerSUSY, 1e18, "USDC per sUSY should be 1e18");
    }

    function test_BreakdownWithLargeSupply() public {
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
}
