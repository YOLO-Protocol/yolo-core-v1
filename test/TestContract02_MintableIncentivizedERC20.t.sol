// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/mocks/MockMintableIncentivizedERC20.sol";
import "../src/mocks/MockIncentivesController.sol";
import "../src/mocks/MaliciousIncentivesTracker.sol";
import "../src/access/ACLManager.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";

contract TestContract02_MintableIncentivizedERC20 is Test {
    MockMintableIncentivizedERC20 public token;
    MockIncentivesController public incentivesController;
    ACLManager public aclManager;
    
    address public deployer;
    address public yoloHook;
    address public alice;
    address public bob;
    address public charlie;
    address public incentivesAdmin;
    
    bytes32 public constant INCENTIVES_ADMIN_ROLE = keccak256("INCENTIVES_ADMIN");
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event IncentivesTrackerUpdated(IIncentivesTracker indexed oldTracker, IIncentivesTracker indexed newTracker);
    event ActionRecorded(address indexed user, uint256 totalSupply, uint256 userBalance, uint256 timestamp);

    function setUp() public {
        // Set up accounts
        deployer = address(this);
        yoloHook = makeAddr("YoloHook");
        alice = makeAddr("Alice");
        bob = makeAddr("Bob");
        charlie = makeAddr("Charlie");
        incentivesAdmin = makeAddr("IncentivesAdmin");
        
        // Deploy ACLManager
        aclManager = new ACLManager(yoloHook);
        
        // Create and grant INCENTIVES_ADMIN role
        aclManager.createRole("INCENTIVES_ADMIN", bytes32(0));
        aclManager.grantRole(INCENTIVES_ADMIN_ROLE, incentivesAdmin);
        
        // Deploy mock incentives controller
        incentivesController = new MockIncentivesController();
        
        // Deploy token
        token = new MockMintableIncentivizedERC20(
            yoloHook,
            address(aclManager),
            "Mock Token",
            "MOCK",
            18
        );
        
        // Set incentives controller
        vm.prank(incentivesAdmin);
        token.setIncentivesTracker(incentivesController);
    }

    /**
     * @dev Test Case 01: Deployment state verification
     */
    function test_Contract02_Case01_deploymentState() public {
        assertEq(token.name(), "Mock Token", "Name mismatch");
        assertEq(token.symbol(), "MOCK", "Symbol mismatch");
        assertEq(token.decimals(), 18, "Decimals mismatch");
        assertEq(token.totalSupply(), 0, "Initial supply should be 0");
        assertEq(token.YOLO_HOOK(), yoloHook, "YoloHook mismatch");
        assertEq(address(token.ACL_MANAGER()), address(aclManager), "ACLManager mismatch");
        assertEq(address(token.getIncentivesTracker()), address(incentivesController), "Incentives controller mismatch");
    }

    /**
     * @dev Test Case 02: Only YoloHook can mint
     */
    function test_Contract02_Case02_onlyYoloHookCanMint() public {
        uint256 amount = 1000 * 10**18;
        
        // Non-YoloHook should fail
        vm.prank(alice);
        vm.expectRevert(MintableIncentivizedERC20.MintableIncentivizedERC20__OnlyYoloHook.selector);
        token.mint(alice, amount);
        
        // YoloHook should succeed
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        assertEq(token.balanceOf(alice), amount, "Balance mismatch after mint");
        assertEq(token.totalSupply(), amount, "Total supply mismatch after mint");
    }

    /**
     * @dev Test Case 03: Only YoloHook can burn
     */
    function test_Contract02_Case03_onlyYoloHookCanBurn() public {
        uint256 amount = 1000 * 10**18;
        
        // First mint some tokens
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Non-YoloHook should fail
        vm.prank(alice);
        vm.expectRevert(MintableIncentivizedERC20.MintableIncentivizedERC20__OnlyYoloHook.selector);
        token.burn(alice, amount / 2);
        
        // YoloHook should succeed
        vm.prank(yoloHook);
        token.burn(alice, amount / 2);
        
        assertEq(token.balanceOf(alice), amount / 2, "Balance mismatch after burn");
        assertEq(token.totalSupply(), amount / 2, "Total supply mismatch after burn");
    }

    /**
     * @dev Test Case 04: Mint triggers incentive tracking
     */
    function test_Contract02_Case04_mintTriggersIncentives() public {
        uint256 amount = 1000 * 10**18;
        
        // Mint tokens
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Check incentive tracking
        assertEq(incentivesController.userActionCount(alice), 1, "Should record 1 action");
        
        MockIncentivesController.ActionRecord memory action = incentivesController.getLastAction(alice);
        assertEq(action.user, alice, "User mismatch");
        assertEq(action.totalSupply, 0, "Should use pre-mint total supply");
        assertEq(action.userBalance, 0, "Should use pre-mint balance");
    }

    /**
     * @dev Test Case 05: Burn triggers incentive tracking
     */
    function test_Contract02_Case05_burnTriggersIncentives() public {
        uint256 amount = 1000 * 10**18;
        
        // First mint
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Reset incentives tracking
        incentivesController.reset();
        
        // Burn tokens
        vm.prank(yoloHook);
        token.burn(alice, amount / 2);
        
        // Check incentive tracking
        assertEq(incentivesController.userActionCount(alice), 1, "Should record 1 action");
        
        MockIncentivesController.ActionRecord memory action = incentivesController.getLastAction(alice);
        assertEq(action.user, alice, "User mismatch");
        assertEq(action.totalSupply, amount, "Should use pre-burn total supply");
        assertEq(action.userBalance, amount, "Should use pre-burn balance");
    }

    /**
     * @dev Test Case 06: Transfer triggers incentive tracking for both parties
     */
    function test_Contract02_Case06_transferTriggersIncentives() public {
        uint256 amount = 1000 * 10**18;
        
        // Mint to alice
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Reset tracking
        incentivesController.reset();
        
        // Transfer from alice to bob
        vm.prank(alice);
        token.transfer(bob, amount / 2);
        
        // Check alice's incentive tracking
        assertEq(incentivesController.userActionCount(alice), 1, "Alice should have 1 action");
        MockIncentivesController.ActionRecord memory aliceAction = incentivesController.getLastAction(alice);
        assertEq(aliceAction.userBalance, amount, "Alice's pre-transfer balance incorrect");
        
        // Check bob's incentive tracking
        assertEq(incentivesController.userActionCount(bob), 1, "Bob should have 1 action");
        MockIncentivesController.ActionRecord memory bobAction = incentivesController.getLastAction(bob);
        assertEq(bobAction.userBalance, 0, "Bob's pre-transfer balance should be 0");
        
        // Both should have same total supply
        assertEq(aliceAction.totalSupply, amount, "Total supply mismatch");
        assertEq(bobAction.totalSupply, amount, "Total supply mismatch");
    }

    /**
     * @dev Test Case 07: Self-transfer only triggers incentives once
     */
    function test_Contract02_Case07_selfTransferIncentivesOnce() public {
        uint256 amount = 1000 * 10**18;
        
        // Mint to alice
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Reset tracking
        incentivesController.reset();
        
        // Self-transfer
        vm.prank(alice);
        token.transfer(alice, amount / 2);
        
        // Should only record once
        assertEq(incentivesController.userActionCount(alice), 1, "Should only record once for self-transfer");
        assertEq(incentivesController.totalActionCount(), 1, "Total actions should be 1");
    }

    /**
     * @dev Test Case 08: Batch mint works correctly
     */
    function test_Contract02_Case08_batchMint() public {
        address[] memory recipients = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        
        recipients[0] = alice;
        recipients[1] = bob;
        recipients[2] = charlie;
        
        amounts[0] = 100 * 10**18;
        amounts[1] = 200 * 10**18;
        amounts[2] = 300 * 10**18;
        
        // Batch mint
        vm.prank(yoloHook);
        token.mintBatch(recipients, amounts);
        
        // Check balances
        assertEq(token.balanceOf(alice), amounts[0], "Alice balance mismatch");
        assertEq(token.balanceOf(bob), amounts[1], "Bob balance mismatch");
        assertEq(token.balanceOf(charlie), amounts[2], "Charlie balance mismatch");
        assertEq(token.totalSupply(), 600 * 10**18, "Total supply mismatch");
        
        // Check incentives were tracked
        assertEq(incentivesController.userActionCount(alice), 1, "Alice action count mismatch");
        assertEq(incentivesController.userActionCount(bob), 1, "Bob action count mismatch");
        assertEq(incentivesController.userActionCount(charlie), 1, "Charlie action count mismatch");
    }

    /**
     * @dev Test Case 09: Batch burn works correctly
     */
    function test_Contract02_Case09_batchBurn() public {
        // First mint tokens
        vm.startPrank(yoloHook);
        token.mint(alice, 100 * 10**18);
        token.mint(bob, 200 * 10**18);
        token.mint(charlie, 300 * 10**18);
        
        // Prepare batch burn
        address[] memory accounts = new address[](3);
        uint256[] memory amounts = new uint256[](3);
        
        accounts[0] = alice;
        accounts[1] = bob;
        accounts[2] = charlie;
        
        amounts[0] = 50 * 10**18;
        amounts[1] = 100 * 10**18;
        amounts[2] = 150 * 10**18;
        
        // Batch burn
        token.burnBatch(accounts, amounts);
        vm.stopPrank();
        
        // Check balances
        assertEq(token.balanceOf(alice), 50 * 10**18, "Alice balance mismatch");
        assertEq(token.balanceOf(bob), 100 * 10**18, "Bob balance mismatch");
        assertEq(token.balanceOf(charlie), 150 * 10**18, "Charlie balance mismatch");
        assertEq(token.totalSupply(), 300 * 10**18, "Total supply mismatch");
    }

    /**
     * @dev Test Case 10: Batch operations revert on length mismatch
     */
    function test_Contract02_Case10_batchLengthMismatch() public {
        address[] memory recipients = new address[](2);
        uint256[] memory amounts = new uint256[](3);
        
        recipients[0] = alice;
        recipients[1] = bob;
        
        amounts[0] = 100 * 10**18;
        amounts[1] = 200 * 10**18;
        amounts[2] = 300 * 10**18;
        
        // Should revert on mint
        vm.prank(yoloHook);
        vm.expectRevert(MintableIncentivizedERC20.MintableIncentivizedERC20__LengthMismatch.selector);
        token.mintBatch(recipients, amounts);
        
        // Should revert on burn
        vm.prank(yoloHook);
        vm.expectRevert(MintableIncentivizedERC20.MintableIncentivizedERC20__LengthMismatch.selector);
        token.burnBatch(recipients, amounts);
    }

    /**
     * @dev Test Case 11: Incentives admin can update tracker
     */
    function test_Contract02_Case11_incentivesAdminCanUpdateTracker() public {
        MockIncentivesController newController = new MockIncentivesController();
        
        // Non-admin should fail
        vm.prank(alice);
        vm.expectRevert(IncentivizedERC20.IncentivizedERC20__OnlyIncentivesAdmin.selector);
        token.setIncentivesTracker(newController);
        
        // Admin should succeed
        vm.prank(incentivesAdmin);
        vm.expectEmit(true, true, false, false);
        emit IncentivesTrackerUpdated(IIncentivesTracker(address(incentivesController)), IIncentivesTracker(address(newController)));
        token.setIncentivesTracker(newController);
        
        assertEq(address(token.getIncentivesTracker()), address(newController), "Tracker not updated");
    }

    /**
     * @dev Test Case 12: Operations work without incentives tracker
     */
    function test_Contract02_Case12_worksWithoutIncentivesTracker() public {
        // Remove incentives tracker
        vm.prank(incentivesAdmin);
        token.setIncentivesTracker(IIncentivesTracker(address(0)));
        
        uint256 amount = 1000 * 10**18;
        
        // Should work without tracker
        vm.startPrank(yoloHook);
        token.mint(alice, amount);
        token.burn(alice, amount / 2);
        vm.stopPrank();
        
        vm.prank(alice);
        token.transfer(bob, amount / 4);
        
        assertEq(token.balanceOf(alice), amount / 4, "Alice balance incorrect");
        assertEq(token.balanceOf(bob), amount / 4, "Bob balance incorrect");
    }

    /**
     * @dev Test Case 13: Additional data can be set and retrieved
     */
    function test_Contract02_Case13_additionalDataManagement() public {
        uint128 testData = 12345;
        
        // Set additional data
        token.setUserAdditionalData(alice, testData);
        
        // Retrieve and verify
        assertEq(token.getAdditionalData(alice), testData, "Additional data mismatch");
        
        // Mint doesn't affect additional data
        vm.prank(yoloHook);
        token.mint(alice, 1000 * 10**18);
        
        assertEq(token.getAdditionalData(alice), testData, "Additional data changed unexpectedly");
    }

    /**
     * @dev Test Case 14: Complex incentive tracking scenario
     */
    function test_Contract02_Case14_complexIncentiveTracking() public {
        uint256 amount1 = 1000 * 10**18;
        uint256 amount2 = 500 * 10**18;
        
        // Mint to alice
        vm.prank(yoloHook);
        token.mint(alice, amount1);
        
        // Transfer to bob
        vm.prank(alice);
        token.transfer(bob, amount2);
        
        // Bob transfers to charlie
        vm.prank(bob);
        token.transfer(charlie, amount2 / 2);
        
        // Burn from charlie
        vm.prank(yoloHook);
        token.burn(charlie, amount2 / 4);
        
        // Verify action counts
        assertEq(incentivesController.userActionCount(alice), 2, "Alice should have 2 actions");
        assertEq(incentivesController.userActionCount(bob), 2, "Bob should have 2 actions");
        assertEq(incentivesController.userActionCount(charlie), 2, "Charlie should have 2 actions");
        
        // Verify final balances
        assertEq(token.balanceOf(alice), amount2, "Alice final balance");
        assertEq(token.balanceOf(bob), amount2 / 2, "Bob final balance");
        assertEq(token.balanceOf(charlie), amount2 / 4, "Charlie final balance");
        assertEq(token.totalSupply(), amount1 - amount2 / 4, "Total supply after burn");
    }

    /**
     * @dev Test Case 15: Zero amount operations
     */
    function test_Contract02_Case15_zeroAmountOperations() public {
        // First give alice some tokens
        vm.prank(yoloHook);
        token.mint(alice, 1000 * 10**18);
        
        // Zero mint should work but not change anything
        vm.prank(yoloHook);
        token.mint(alice, 0);
        assertEq(token.balanceOf(alice), 1000 * 10**18, "Balance changed on zero mint");
        
        // Zero burn should work
        vm.prank(yoloHook);
        token.burn(alice, 0);
        assertEq(token.balanceOf(alice), 1000 * 10**18, "Balance changed on zero burn");
        
        // Zero transfer should work
        vm.prank(alice);
        token.transfer(bob, 0);
        assertEq(token.balanceOf(bob), 0, "Bob balance not zero");
    }

    /**
     * @dev Test Case 16: Fuzz test mint amounts
     */
    function testFuzz_Contract02_Case16_mintAmounts(uint256 amount) public {
        vm.assume(amount <= type(uint128).max);
        
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        assertEq(token.balanceOf(alice), amount, "Balance mismatch");
        assertEq(token.totalSupply(), amount, "Supply mismatch");
        
        // Verify incentives were tracked
        if (address(incentivesController) != address(0)) {
            assertEq(incentivesController.userActionCount(alice), 1, "Action not tracked");
        }
    }

    /**
     * @dev Test Case 17: Fuzz test transfer amounts
     */
    function testFuzz_Contract02_Case17_transferAmounts(uint256 mintAmount, uint256 transferAmount) public {
        vm.assume(mintAmount <= type(uint128).max);
        vm.assume(transferAmount <= mintAmount);
        
        // Mint first
        vm.prank(yoloHook);
        token.mint(alice, mintAmount);
        
        // Transfer
        vm.prank(alice);
        token.transfer(bob, transferAmount);
        
        assertEq(token.balanceOf(alice), mintAmount - transferAmount, "Alice balance incorrect");
        assertEq(token.balanceOf(bob), transferAmount, "Bob balance incorrect");
        assertEq(token.totalSupply(), mintAmount, "Total supply changed");
    }

    /**
     * @dev Test Case 18: Reentrancy protection
     */
    function test_Contract02_Case18_reentrancyProtection() public {
        // Deploy a malicious incentives tracker that tries to reenter
        MaliciousIncentivesTracker malicious = new MaliciousIncentivesTracker(address(token));
        
        vm.prank(incentivesAdmin);
        token.setIncentivesTracker(malicious);
        
        // Mint some tokens to enable the attack
        vm.prank(yoloHook);
        token.mint(address(malicious), 1000 * 10**18);
        
        // The malicious contract will try to reenter during handleAction
        // Should complete without reentrancy due to guard
        vm.prank(address(malicious));
        token.transfer(alice, 100 * 10**18);
        
        // Verify the transfer completed successfully
        assertEq(token.balanceOf(alice), 100 * 10**18, "Transfer should complete");
        assertTrue(malicious.attackAttempted(), "Attack should have been attempted");
    }

    /**
     * @dev Test Case 19: Overflow protection
     */
    function test_Contract02_Case19_overflowProtection() public {
        uint256 maxUint128 = type(uint128).max;
        
        // Should revert on amount > uint128.max
        vm.prank(yoloHook);
        vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, maxUint128 + 1));
        token.mint(alice, maxUint128 + 1);
        
        // Should work at exactly uint128.max
        vm.prank(yoloHook);
        token.mint(alice, maxUint128);
        assertEq(token.balanceOf(alice), maxUint128, "Should mint max uint128");
    }

    /**
     * @dev Test Case 20: Allowance and transferFrom with incentive tracking
     */
    function test_Contract02_Case20_allowanceAndTransferFrom() public {
        uint256 amount = 1000 * 10**18;
        
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Reset tracking for clarity
        incentivesController.reset();
        
        // Alice approves Bob
        vm.prank(alice);
        token.approve(bob, amount / 2);
        assertEq(token.allowance(alice, bob), amount / 2, "Allowance not set");
        
        // Bob transfers from Alice to Charlie
        vm.prank(bob);
        token.transferFrom(alice, charlie, amount / 2);
        
        // Check balances
        assertEq(token.balanceOf(alice), amount / 2, "Alice balance incorrect");
        assertEq(token.balanceOf(charlie), amount / 2, "Charlie balance incorrect");
        
        // Check incentives were tracked for both alice and charlie
        assertEq(incentivesController.userActionCount(alice), 1, "Alice action count");
        assertEq(incentivesController.userActionCount(charlie), 1, "Charlie action count");
        
        // Verify pre-transfer balances in incentive tracking
        MockIncentivesController.ActionRecord memory aliceAction = incentivesController.getLastAction(alice);
        assertEq(aliceAction.userBalance, amount, "Alice pre-transfer balance");
        
        MockIncentivesController.ActionRecord memory charlieAction = incentivesController.getLastAction(charlie);
        assertEq(charlieAction.userBalance, 0, "Charlie pre-transfer balance");
    }

    /**
     * @dev Test Case 21: Event emission verification
     */
    function test_Contract02_Case21_eventEmission() public {
        uint256 amount = 1000 * 10**18;
        
        // Check Transfer event on mint (from zero address)
        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, amount);
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Check Transfer event on burn (to zero address)
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, address(0), amount / 2);
        vm.prank(yoloHook);
        token.burn(alice, amount / 2);
        
        // Check Transfer event on regular transfer
        vm.expectEmit(true, true, false, true);
        emit Transfer(alice, bob, amount / 4);
        vm.prank(alice);
        token.transfer(bob, amount / 4);
    }

    /**
     * @dev Test Case 22: Concurrent operations tracking
     */
    function test_Contract02_Case22_concurrentOperations() public {
        // Multiple mints in same block
        vm.startPrank(yoloHook);
        token.mint(alice, 1000 * 10**18);
        token.mint(bob, 500 * 10**18);
        token.mint(charlie, 250 * 10**18);
        vm.stopPrank();
        
        // Reset for clear tracking
        incentivesController.reset();
        
        // Multiple transfers in same block to same recipient
        vm.prank(alice);
        token.transfer(charlie, 100 * 10**18);
        
        vm.prank(bob);
        token.transfer(charlie, 50 * 10**18);
        
        // Verify charlie's incentives were tracked for each receive
        assertEq(incentivesController.userActionCount(charlie), 2, "Charlie should have 2 actions");
        
        // Verify each action has correct pre-transfer balance
        MockIncentivesController.ActionRecord memory charlieAction1 = incentivesController.getAction(charlie, 0);
        assertEq(charlieAction1.userBalance, 250 * 10**18, "First transfer pre-balance");
        
        MockIncentivesController.ActionRecord memory charlieAction2 = incentivesController.getAction(charlie, 1);
        assertEq(charlieAction2.userBalance, 350 * 10**18, "Second transfer pre-balance");
    }

    /**
     * @dev Test Case 23: increaseAllowance and decreaseAllowance
     */
    function test_Contract02_Case23_allowanceModifications() public {
        uint256 initial = 100 * 10**18;
        uint256 increase = 50 * 10**18;
        uint256 decrease = 30 * 10**18;
        
        // Initial approval
        vm.prank(alice);
        token.approve(bob, initial);
        assertEq(token.allowance(alice, bob), initial, "Initial allowance");
        
        // Increase allowance
        vm.prank(alice);
        token.increaseAllowance(bob, increase);
        assertEq(token.allowance(alice, bob), initial + increase, "After increase");
        
        // Decrease allowance
        vm.prank(alice);
        token.decreaseAllowance(bob, decrease);
        assertEq(token.allowance(alice, bob), initial + increase - decrease, "After decrease");
        
        // Cannot decrease below zero
        vm.prank(alice);
        vm.expectRevert(IncentivizedERC20.IncentivizedERC20__InsufficientAllowance.selector);
        token.decreaseAllowance(bob, initial + increase);
    }

    /**
     * @dev Test Case 24: Burn more than balance should revert
     */
    function test_Contract02_Case24_burnInsufficientBalance() public {
        uint256 amount = 1000 * 10**18;
        
        // Mint tokens
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Try to burn more than balance
        vm.prank(yoloHook);
        vm.expectRevert(IncentivizedERC20.IncentivizedERC20__InsufficientBalance.selector);
        token.burn(alice, amount + 1);
    }

    /**
     * @dev Test Case 25: Transfer more than balance should revert
     */
    function test_Contract02_Case25_transferInsufficientBalance() public {
        uint256 amount = 1000 * 10**18;
        
        // Mint tokens
        vm.prank(yoloHook);
        token.mint(alice, amount);
        
        // Try to transfer more than balance
        vm.prank(alice);
        vm.expectRevert(IncentivizedERC20.IncentivizedERC20__InsufficientBalance.selector);
        token.transfer(bob, amount + 1);
    }
}