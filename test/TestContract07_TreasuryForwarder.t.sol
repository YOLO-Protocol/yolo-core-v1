// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TreasuryForwarder} from "../src/treasury/TreasuryForwarder.sol";
import {ACLManager} from "../src/access/ACLManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockRewardToken is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {
        _mint(msg.sender, 1_000_000e18);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract TestContract07_TreasuryForwarder is Test {
    TreasuryForwarder public forwarder;
    ACLManager public aclManager;

    MockRewardToken public usy;
    MockRewardToken public yNVDA;
    MockRewardToken public yTSLA;

    address public rewardsAdmin;
    address public recipient1;
    address public recipient2;
    address public recipient3;

    bytes32 public constant REWARDS_ADMIN = keccak256("REWARDS_ADMIN");

    function setUp() public {
        // Create accounts
        rewardsAdmin = makeAddr("rewardsAdmin");
        recipient1 = makeAddr("recipient1");
        recipient2 = makeAddr("recipient2");
        recipient3 = makeAddr("recipient3");

        // Deploy ACLManager
        aclManager = new ACLManager(address(this));

        // Create and grant REWARDS_ADMIN role
        aclManager.createRole("REWARDS_ADMIN", 0x00);
        aclManager.grantRole(REWARDS_ADMIN, rewardsAdmin);

        // Deploy TreasuryForwarder
        forwarder = new TreasuryForwarder(address(aclManager));

        // Deploy mock tokens
        usy = new MockRewardToken("YOLO USD", "USY");
        yNVDA = new MockRewardToken("YOLO NVIDIA", "yNVDA");
        yTSLA = new MockRewardToken("YOLO TESLA", "yTSLA");

        // Send some tokens to forwarder
        require(usy.transfer(address(forwarder), 10_000e18), "USY transfer failed");
        require(yNVDA.transfer(address(forwarder), 5_000e18), "yNVDA transfer failed");
        require(yTSLA.transfer(address(forwarder), 3_000e18), "yTSLA transfer failed");
    }

    // ============================================================
    // REGISTER/DROP REWARD TESTS
    // ============================================================

    function test_Contract07_Case01_registerReward() public {
        vm.prank(rewardsAdmin);
        forwarder.registerReward(address(usy));

        assertTrue(forwarder.isReward(address(usy)));
        assertEq(forwarder.getAllRegisteredRewards().length, 1);
        assertEq(forwarder.getAllRegisteredRewards()[0], address(usy));
    }

    function test_Contract07_Case02_registerMultipleRewards() public {
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(usy));
        forwarder.registerReward(address(yNVDA));
        forwarder.registerReward(address(yTSLA));
        vm.stopPrank();

        address[] memory rewards = forwarder.getAllRegisteredRewards();
        assertEq(rewards.length, 3);
        assertTrue(forwarder.isReward(address(usy)));
        assertTrue(forwarder.isReward(address(yNVDA)));
        assertTrue(forwarder.isReward(address(yTSLA)));
    }

    function test_Contract07_Case03_dropReward() public {
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(usy));
        forwarder.registerReward(address(yNVDA));

        forwarder.dropReward(address(usy));
        vm.stopPrank();

        assertFalse(forwarder.isReward(address(usy)));
        assertTrue(forwarder.isReward(address(yNVDA)));
        assertEq(forwarder.getAllRegisteredRewards().length, 1);
        assertEq(forwarder.getAllRegisteredRewards()[0], address(yNVDA));
    }

    function test_Contract07_Case04_registerRewardRevertsIfNotAdmin() public {
        vm.prank(recipient1);
        vm.expectRevert(TreasuryForwarder.TreasuryForwarder__Unauthorized.selector);
        forwarder.registerReward(address(usy));
    }

    function test_Contract07_Case05_registerRewardRevertsIfAlreadyRegistered() public {
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(usy));

        vm.expectRevert(TreasuryForwarder.TreasuryForwarder__RewardAlreadyRegistered.selector);
        forwarder.registerReward(address(usy));
        vm.stopPrank();
    }

    // ============================================================
    // SET RECIPIENTS TESTS
    // ============================================================

    function test_Contract07_Case06_setRecipients() public {
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(usy));

        TreasuryForwarder.Recipient[] memory recipients = new TreasuryForwarder.Recipient[](3);
        recipients[0] = TreasuryForwarder.Recipient({destination: recipient1, allocPoints: 5000}); // 50%
        recipients[1] = TreasuryForwarder.Recipient({destination: recipient2, allocPoints: 3000}); // 30%
        recipients[2] = TreasuryForwarder.Recipient({destination: recipient3, allocPoints: 2000}); // 20%

        forwarder.setRecipients(address(usy), recipients);
        vm.stopPrank();

        TreasuryForwarder.Recipient[] memory stored = forwarder.getRecipients(address(usy));
        assertEq(stored.length, 3);
        assertEq(stored[0].destination, recipient1);
        assertEq(stored[0].allocPoints, 5000);
        assertEq(forwarder.getTotalAllocPoints(address(usy)), 10000);
    }

    function test_Contract07_Case07_setRecipientsRevertsIfNotAdmin() public {
        vm.prank(rewardsAdmin);
        forwarder.registerReward(address(usy));

        TreasuryForwarder.Recipient[] memory recipients = new TreasuryForwarder.Recipient[](1);
        recipients[0] = TreasuryForwarder.Recipient({destination: recipient1, allocPoints: 10000});

        vm.prank(recipient1);
        vm.expectRevert(TreasuryForwarder.TreasuryForwarder__Unauthorized.selector);
        forwarder.setRecipients(address(usy), recipients);
    }

    function test_Contract07_Case08_setRecipientsRevertsIfNotRegistered() public {
        TreasuryForwarder.Recipient[] memory recipients = new TreasuryForwarder.Recipient[](1);
        recipients[0] = TreasuryForwarder.Recipient({destination: recipient1, allocPoints: 10000});

        vm.prank(rewardsAdmin);
        vm.expectRevert(TreasuryForwarder.TreasuryForwarder__RewardNotRegistered.selector);
        forwarder.setRecipients(address(usy), recipients);
    }

    function test_Contract07_Case09_setRecipientsRevertsIfNotHundredPercent() public {
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(usy));

        TreasuryForwarder.Recipient[] memory recipients = new TreasuryForwarder.Recipient[](2);
        recipients[0] = TreasuryForwarder.Recipient({destination: recipient1, allocPoints: 5000});
        recipients[1] = TreasuryForwarder.Recipient({destination: recipient2, allocPoints: 3000}); // Total 8000, not 10000

        vm.expectRevert(TreasuryForwarder.TreasuryForwarder__InvalidAllocation.selector);
        forwarder.setRecipients(address(usy), recipients);
        vm.stopPrank();
    }

    // ============================================================
    // DISTRIBUTION TESTS
    // ============================================================

    function test_Contract07_Case10_distributeSingleAsset() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(usy));

        TreasuryForwarder.Recipient[] memory recipients = new TreasuryForwarder.Recipient[](3);
        recipients[0] = TreasuryForwarder.Recipient({destination: recipient1, allocPoints: 5000}); // 50%
        recipients[1] = TreasuryForwarder.Recipient({destination: recipient2, allocPoints: 3000}); // 30%
        recipients[2] = TreasuryForwarder.Recipient({destination: recipient3, allocPoints: 2000}); // 20%

        forwarder.setRecipients(address(usy), recipients);
        vm.stopPrank();

        uint256 totalBalance = usy.balanceOf(address(forwarder));

        // Distribute (anyone can call)
        forwarder.distributeSingleAsset(address(usy));

        // Check balances
        assertEq(usy.balanceOf(recipient1), totalBalance * 5000 / 10000);
        assertEq(usy.balanceOf(recipient2), totalBalance * 3000 / 10000);
        // Recipient3 gets remainder including dust
        assertGt(usy.balanceOf(recipient3), totalBalance * 2000 / 10000 - 1);
        assertEq(usy.balanceOf(address(forwarder)), 0); // All distributed
    }

    function test_Contract07_Case11_distributeAll() public {
        // Setup multiple rewards
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(usy));
        forwarder.registerReward(address(yNVDA));

        TreasuryForwarder.Recipient[] memory recipients = new TreasuryForwarder.Recipient[](2);
        recipients[0] = TreasuryForwarder.Recipient({destination: recipient1, allocPoints: 6000});
        recipients[1] = TreasuryForwarder.Recipient({destination: recipient2, allocPoints: 4000});

        forwarder.setRecipients(address(usy), recipients);
        forwarder.setRecipients(address(yNVDA), recipients);
        vm.stopPrank();

        uint256 usyBalance = usy.balanceOf(address(forwarder));
        uint256 yNVDABalance = yNVDA.balanceOf(address(forwarder));

        // Distribute all
        forwarder.distribute();

        // Check USY distributed
        assertEq(usy.balanceOf(recipient1), usyBalance * 6000 / 10000);
        assertGt(usy.balanceOf(recipient2), usyBalance * 4000 / 10000 - 1);
        assertEq(usy.balanceOf(address(forwarder)), 0);

        // Check yNVDA distributed
        assertEq(yNVDA.balanceOf(recipient1), yNVDABalance * 6000 / 10000);
        assertGt(yNVDA.balanceOf(recipient2), yNVDABalance * 4000 / 10000 - 1);
        assertEq(yNVDA.balanceOf(address(forwarder)), 0);
    }

    function test_Contract07_Case12_distributeSkipsIfNoRecipients() public {
        vm.prank(rewardsAdmin);
        forwarder.registerReward(address(usy));

        uint256 balanceBefore = usy.balanceOf(address(forwarder));

        // Distribute without setting recipients (should not revert, just skip)
        forwarder.distributeSingleAsset(address(usy));

        // Balance unchanged
        assertEq(usy.balanceOf(address(forwarder)), balanceBefore);
    }

    function test_Contract07_Case13_distributeSkipsIfNoBalance() public {
        // Setup
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(yTSLA));

        TreasuryForwarder.Recipient[] memory recipients = new TreasuryForwarder.Recipient[](1);
        recipients[0] = TreasuryForwarder.Recipient({destination: recipient1, allocPoints: 10000});
        forwarder.setRecipients(address(yTSLA), recipients);

        // Remove all tokens using emergency withdraw
        uint256 balance = yTSLA.balanceOf(address(forwarder));
        forwarder.emergencyWithdraw(address(yTSLA), recipient2, balance);
        vm.stopPrank();

        // Verify forwarder has no balance
        assertEq(yTSLA.balanceOf(address(forwarder)), 0);

        // Distribute (should not revert, just skip)
        forwarder.distributeSingleAsset(address(yTSLA));

        // Recipient1 should still have 0 (nothing distributed)
        assertEq(yTSLA.balanceOf(recipient1), 0);
    }

    // ============================================================
    // EMERGENCY WITHDRAWAL TESTS
    // ============================================================

    function test_Contract07_Case14_emergencyWithdraw() public {
        uint256 amount = 1000e18;
        uint256 balanceBefore = usy.balanceOf(address(forwarder));

        vm.prank(rewardsAdmin);
        forwarder.emergencyWithdraw(address(usy), recipient1, amount);

        assertEq(usy.balanceOf(recipient1), amount);
        assertEq(usy.balanceOf(address(forwarder)), balanceBefore - amount);
    }

    function test_Contract07_Case15_emergencyWithdrawRevertsIfNotAdmin() public {
        vm.prank(recipient1);
        vm.expectRevert(TreasuryForwarder.TreasuryForwarder__Unauthorized.selector);
        forwarder.emergencyWithdraw(address(usy), recipient1, 1000e18);
    }

    function test_Contract07_Case16_emergencyWithdrawRevertsIfInvalidAddress() public {
        vm.startPrank(rewardsAdmin);

        vm.expectRevert(TreasuryForwarder.TreasuryForwarder__InvalidAddress.selector);
        forwarder.emergencyWithdraw(address(0), recipient1, 1000e18);

        vm.expectRevert(TreasuryForwarder.TreasuryForwarder__InvalidAddress.selector);
        forwarder.emergencyWithdraw(address(usy), address(0), 1000e18);

        vm.stopPrank();
    }

    // ============================================================
    // DUST HANDLING TEST
    // ============================================================

    function test_Contract07_Case17_dustGoesToLastRecipient() public {
        // Setup with amount that creates dust
        vm.startPrank(rewardsAdmin);
        forwarder.registerReward(address(usy));

        TreasuryForwarder.Recipient[] memory recipients = new TreasuryForwarder.Recipient[](3);
        recipients[0] = TreasuryForwarder.Recipient({destination: recipient1, allocPoints: 3333}); // 33.33%
        recipients[1] = TreasuryForwarder.Recipient({destination: recipient2, allocPoints: 3333}); // 33.33%
        recipients[2] = TreasuryForwarder.Recipient({destination: recipient3, allocPoints: 3334}); // 33.34%

        forwarder.setRecipients(address(usy), recipients);
        vm.stopPrank();

        uint256 totalBalance = usy.balanceOf(address(forwarder));

        // Distribute
        forwarder.distributeSingleAsset(address(usy));

        // All tokens distributed (no dust left in forwarder)
        assertEq(usy.balanceOf(address(forwarder)), 0);

        // Last recipient gets remainder
        uint256 recipient1Balance = usy.balanceOf(recipient1);
        uint256 recipient2Balance = usy.balanceOf(recipient2);
        uint256 recipient3Balance = usy.balanceOf(recipient3);

        assertEq(recipient1Balance + recipient2Balance + recipient3Balance, totalBalance);
    }
}
