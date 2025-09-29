// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/mocks/MockMintableIncentivizedERC20Upgradeable.sol";
import "../src/mocks/MockIncentivesController.sol";
import "../src/access/ACLManager.sol";

contract TestContract03_MintableIncentivizedERC20Upgradeable is Test {
    MockMintableIncentivizedERC20Upgradeable public token;
    MockIncentivesController public incentivesController;
    ACLManager public aclManager;

    address public yoloHook = address(0x1234);
    address public alice = address(0xABCD);
    address public bob = address(0x5678);

    function setUp() public {
        // Deploy ACLManager
        aclManager = new ACLManager(yoloHook);

        // Setup roles
        aclManager.createRole("INCENTIVES_ADMIN", 0x00);
        aclManager.grantRole(keccak256("INCENTIVES_ADMIN"), address(this));

        // Deploy incentives controller
        incentivesController = new MockIncentivesController();

        // Deploy upgradeable token (without initialization)
        token = new MockMintableIncentivizedERC20Upgradeable();

        // Initialize the token
        token.initialize(yoloHook, address(aclManager), "Test Token", "TEST", 18);

        // Set incentives tracker
        token.setIncentivesTracker(incentivesController);
    }

    /**
     * @dev Test initialization state
     */
    function test_Contract03_Case01_initialization() public view {
        assertEq(token.name(), "Test Token");
        assertEq(token.symbol(), "TEST");
        assertEq(token.decimals(), 18);
        assertEq(token.YOLO_HOOK(), yoloHook);
        assertEq(address(token.ACL_MANAGER()), address(aclManager));
        assertEq(address(token.getIncentivesTracker()), address(incentivesController));
    }

    /**
     * @dev Test cannot reinitialize
     */
    function test_Contract03_Case02_cannotReinitialize() public {
        // OpenZeppelin's Initializable reverts with a different error
        vm.expectRevert(); // Generic revert check for OZ's "Initializable: contract is already initialized"
        token.initialize(yoloHook, address(aclManager), "New Name", "NEW", 18);
    }

    /**
     * @dev Test mint functionality
     */
    function test_Contract03_Case03_mint() public {
        uint256 amount = 1000 * 10 ** 18;

        vm.prank(yoloHook);
        token.mint(alice, amount);

        assertEq(token.balanceOf(alice), amount);
        assertEq(token.totalSupply(), amount);

        // Check incentives were tracked
        assertEq(incentivesController.userActionCount(alice), 1);
        MockIncentivesController.ActionRecord memory action = incentivesController.getLastAction(alice);
        assertEq(action.totalSupply, amount, "Should use post-mint total supply");
        assertEq(action.userBalance, amount, "Should use post-mint balance");
    }

    /**
     * @dev Test burn functionality
     */
    function test_Contract03_Case04_burn() public {
        uint256 amount = 1000 * 10 ** 18;

        // First mint
        vm.prank(yoloHook);
        token.mint(alice, amount);

        // Reset incentives
        incentivesController.reset();

        // Burn half
        vm.prank(yoloHook);
        token.burn(alice, amount / 2);

        assertEq(token.balanceOf(alice), amount / 2);
        assertEq(token.totalSupply(), amount / 2);

        // Check incentives were tracked
        MockIncentivesController.ActionRecord memory action = incentivesController.getLastAction(alice);
        assertEq(action.totalSupply, amount / 2, "Should use post-burn total supply");
        assertEq(action.userBalance, amount / 2, "Should use post-burn balance");
    }

    /**
     * @dev Test transfer functionality
     */
    function test_Contract03_Case05_transfer() public {
        uint256 amount = 1000 * 10 ** 18;

        // Mint to alice
        vm.prank(yoloHook);
        token.mint(alice, amount);

        // Reset tracking
        incentivesController.reset();

        // Transfer half to bob
        vm.prank(alice);
        token.transfer(bob, amount / 2);

        assertEq(token.balanceOf(alice), amount / 2);
        assertEq(token.balanceOf(bob), amount / 2);

        // Check incentives tracking
        MockIncentivesController.ActionRecord memory aliceAction = incentivesController.getLastAction(alice);
        assertEq(aliceAction.userBalance, amount / 2, "Alice post-transfer balance");

        MockIncentivesController.ActionRecord memory bobAction = incentivesController.getLastAction(bob);
        assertEq(bobAction.userBalance, amount / 2, "Bob post-transfer balance");
    }

    /**
     * @dev Test only YoloHook can mint
     */
    function test_Contract03_Case06_onlyYoloHookCanMint() public {
        vm.prank(alice);
        vm.expectRevert(MintableIncentivizedERC20Upgradeable.MintableIncentivizedERC20__OnlyYoloHook.selector);
        token.mint(alice, 100);
    }

    /**
     * @dev Test only YoloHook can burn
     */
    function test_Contract03_Case07_onlyYoloHookCanBurn() public {
        // First mint some tokens
        vm.prank(yoloHook);
        token.mint(alice, 100);

        // Try to burn from non-YoloHook
        vm.prank(alice);
        vm.expectRevert(MintableIncentivizedERC20Upgradeable.MintableIncentivizedERC20__OnlyYoloHook.selector);
        token.burn(alice, 50);
    }

    /**
     * @dev Test batch mint
     */
    function test_Contract03_Case08_batchMint() public {
        address[] memory recipients = new address[](3);
        uint256[] memory amounts = new uint256[](3);

        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = address(0x9999);

        amounts[0] = 100 * 10 ** 18;
        amounts[1] = 200 * 10 ** 18;
        amounts[2] = 300 * 10 ** 18;

        vm.prank(yoloHook);
        token.batchMint(recipients, amounts);

        assertEq(token.balanceOf(alice), 100 * 10 ** 18);
        assertEq(token.balanceOf(bob), 200 * 10 ** 18);
        assertEq(token.balanceOf(address(0x9999)), 300 * 10 ** 18);
        assertEq(token.totalSupply(), 600 * 10 ** 18);
    }

    /**
     * @dev Test storage gap doesn't interfere
     */
    function test_Contract03_Case09_storageGap() public {
        // This test ensures the storage gap doesn't cause issues
        // by performing various operations
        uint256 amount = 1000 * 10 ** 18;

        vm.startPrank(yoloHook);
        token.mint(alice, amount);
        token.burn(alice, amount / 4);
        vm.stopPrank();

        vm.prank(alice);
        token.transfer(bob, amount / 4);

        // Additional data should work
        token.setAdditionalData(alice, 12345);
        assertEq(token.getAdditionalData(alice), 12345);

        // All balances should be correct
        assertEq(token.balanceOf(alice), amount / 2);
        assertEq(token.balanceOf(bob), amount / 4);
        assertEq(token.totalSupply(), (amount * 3) / 4);
    }
}