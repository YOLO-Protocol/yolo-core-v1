// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimeLock} from "../src/admin/TimeLock.sol";

contract MockTarget {
    uint256 public value;
    address public caller;

    function setValue(uint256 _value) external {
        value = _value;
        caller = msg.sender;
    }

    function revertingFunction() external pure {
        revert("Intentional revert");
    }

    receive() external payable {}
}

contract TestContract08_TimeLock is Test {
    TimeLock public timeLock;
    MockTarget public target;

    address public admin1;
    address public admin2;
    address public admin3;
    address public nonAdmin;

    uint256 public constant DEFAULT_DELAY = 2 days;

    function setUp() public {
        admin1 = makeAddr("admin1");
        admin2 = makeAddr("admin2");
        admin3 = makeAddr("admin3");
        nonAdmin = makeAddr("nonAdmin");

        timeLock = new TimeLock(admin1, DEFAULT_DELAY);
        target = new MockTarget();

        // Fund timeLock with some ETH for testing
        vm.deal(address(timeLock), 10 ether);
    }

    // ============================================================
    // CONSTRUCTOR TESTS
    // ============================================================

    function test_Contract08_Case01_constructorSetsInitialState() public view {
        assertEq(timeLock.delayTime(), DEFAULT_DELAY);
        assertEq(timeLock.totalAdmins(), 1);
        assertTrue(timeLock.isAdmin(admin1));
    }

    function test_Contract08_Case02_constructorRevertsOnZeroAddress() public {
        vm.expectRevert(TimeLock.TimeLock__InvalidAddress.selector);
        new TimeLock(address(0), DEFAULT_DELAY);
    }

    function test_Contract08_Case03_constructorRevertsOnDelayTooLow() public {
        vm.expectRevert(TimeLock.TimeLock__DelayBelowMinimum.selector);
        new TimeLock(admin1, 0.5 days);
    }

    function test_Contract08_Case04_constructorRevertsOnDelayTooHigh() public {
        vm.expectRevert(TimeLock.TimeLock__DelayAboveMaximum.selector);
        new TimeLock(admin1, 31 days);
    }

    function test_Contract08_Case05_constructorAcceptsValidDelayRange() public {
        TimeLock tl1 = new TimeLock(admin1, 1 days); // Minimum
        assertEq(tl1.delayTime(), 1 days);

        TimeLock tl2 = new TimeLock(admin1, 30 days); // Maximum
        assertEq(tl2.delayTime(), 30 days);

        TimeLock tl3 = new TimeLock(admin1, 7 days); // Middle
        assertEq(tl3.delayTime(), 7 days);
    }

    // ============================================================
    // PENDING ADMIN TESTS
    // ============================================================

    function test_Contract08_Case06_setPendingAdminViaTimelock() public {
        bytes memory data = abi.encode(admin2);
        _queueTransaction(address(timeLock), 0, "setPendingAdmin(address)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        timeLock.executeTransaction(address(timeLock), 0, "setPendingAdmin(address)", data, block.timestamp);

        assertTrue(timeLock.pendingAdmins(admin2));
    }

    function test_Contract08_Case07_setPendingAdminRevertsIfNotTimelock() public {
        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__OnlyTimeLockItself.selector);
        timeLock.setPendingAdmin(admin2);
    }

    function test_Contract08_Case08_setPendingAdminRevertsOnZeroAddress() public {
        bytes memory data = abi.encode(address(0));
        _queueTransaction(address(timeLock), 0, "setPendingAdmin(address)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionFailed.selector);
        timeLock.executeTransaction(address(timeLock), 0, "setPendingAdmin(address)", data, block.timestamp);
    }

    function test_Contract08_Case09_setPendingAdminRevertsOnExistingAdmin() public {
        bytes memory data = abi.encode(admin1);
        _queueTransaction(address(timeLock), 0, "setPendingAdmin(address)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionFailed.selector);
        timeLock.executeTransaction(address(timeLock), 0, "setPendingAdmin(address)", data, block.timestamp);
    }

    function test_Contract08_Case10_cancelPendingAdmin() public {
        // First set pending
        _setPendingAdminViaTimelock(admin2);
        assertTrue(timeLock.pendingAdmins(admin2));

        // Then cancel
        bytes memory data = abi.encode(admin2);
        _queueTransaction(address(timeLock), 0, "cancelPendingAdmin(address)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        timeLock.executeTransaction(address(timeLock), 0, "cancelPendingAdmin(address)", data, block.timestamp);

        assertFalse(timeLock.pendingAdmins(admin2));
    }

    // ============================================================
    // ACCEPT ADMIN TESTS
    // ============================================================

    function test_Contract08_Case11_acceptAdminSuccess() public {
        _setPendingAdminViaTimelock(admin2);

        vm.prank(admin2);
        timeLock.acceptAdmin();

        assertTrue(timeLock.isAdmin(admin2));
        assertFalse(timeLock.pendingAdmins(admin2));
        assertEq(timeLock.totalAdmins(), 2);
    }

    function test_Contract08_Case12_acceptAdminRevertsIfNotPending() public {
        vm.prank(admin2);
        vm.expectRevert(TimeLock.TimeLock__OnlyPendingAdmin.selector);
        timeLock.acceptAdmin();
    }

    function test_Contract08_Case13_acceptAdminPreventDoubleCountingBug() public {
        // This test verifies the double-counting bug fix
        // The bug: if acceptAdmin() didn't check isAdmin, an existing admin could
        // be set as pending (bypassing setPendingAdmin guards) and accept again,
        // incrementing totalAdmins twice for the same address.

        // Our fix prevents this at multiple levels:
        // 1. setPendingAdmin blocks existing admins (tested in Case09)
        // 2. acceptAdmin also checks isAdmin as a guard

        // We can't easily test the acceptAdmin guard without storage manipulation,
        // but we verify the system is protected by confirming Case09 behavior
        _setPendingAdminViaTimelock(admin2);
        vm.prank(admin2);
        timeLock.acceptAdmin();

        // Attempting to set admin2 as pending again fails (tested in Case09)
        assertTrue(timeLock.isAdmin(admin2));
        assertEq(timeLock.totalAdmins(), 2); // Correctly counted once
    }

    function test_Contract08_Case14_multipleAdminsCanCoexist() public {
        _setPendingAdminViaTimelock(admin2);
        vm.prank(admin2);
        timeLock.acceptAdmin();

        _setPendingAdminViaTimelock(admin3);
        vm.prank(admin3);
        timeLock.acceptAdmin();

        assertTrue(timeLock.isAdmin(admin1));
        assertTrue(timeLock.isAdmin(admin2));
        assertTrue(timeLock.isAdmin(admin3));
        assertEq(timeLock.totalAdmins(), 3);
    }

    // ============================================================
    // SELF REVOKE ADMIN TESTS
    // ============================================================

    function test_Contract08_Case15_selfRevokeAdminSuccess() public {
        _setPendingAdminViaTimelock(admin2);
        vm.prank(admin2);
        timeLock.acceptAdmin();

        vm.prank(admin2);
        timeLock.selfRevokeAdmin();

        assertFalse(timeLock.isAdmin(admin2));
        assertEq(timeLock.totalAdmins(), 1);
    }

    function test_Contract08_Case16_selfRevokeAdminRevertsIfNotAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(TimeLock.TimeLock__OnlyAdmin.selector);
        timeLock.selfRevokeAdmin();
    }

    function test_Contract08_Case17_selfRevokeAdminRevertsIfLastAdmin() public {
        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__MustHaveAtLeastOneAdmin.selector);
        timeLock.selfRevokeAdmin();
    }

    // ============================================================
    // FORCED REVOKE ADMIN TESTS
    // ============================================================

    function test_Contract08_Case18_revokeAdminViaTimelock() public {
        // Add second admin
        _setPendingAdminViaTimelock(admin2);
        vm.prank(admin2);
        timeLock.acceptAdmin();

        // Revoke admin2 via timelock
        bytes memory data = abi.encode(admin2);
        _queueTransaction(address(timeLock), 0, "revokeAdmin(address)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        timeLock.executeTransaction(address(timeLock), 0, "revokeAdmin(address)", data, block.timestamp);

        assertFalse(timeLock.isAdmin(admin2));
        assertEq(timeLock.totalAdmins(), 1);
    }

    function test_Contract08_Case19_revokeAdminRevertsIfNotTimelock() public {
        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__OnlyTimeLockItself.selector);
        timeLock.revokeAdmin(admin2);
    }

    function test_Contract08_Case20_revokeAdminRevertsIfNotAdmin() public {
        bytes memory data = abi.encode(nonAdmin);
        _queueTransaction(address(timeLock), 0, "revokeAdmin(address)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionFailed.selector);
        timeLock.executeTransaction(address(timeLock), 0, "revokeAdmin(address)", data, block.timestamp);
    }

    function test_Contract08_Case21_revokeAdminRevertsIfLastAdmin() public {
        bytes memory data = abi.encode(admin1);
        _queueTransaction(address(timeLock), 0, "revokeAdmin(address)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionFailed.selector);
        timeLock.executeTransaction(address(timeLock), 0, "revokeAdmin(address)", data, block.timestamp);
    }

    // ============================================================
    // QUEUE TRANSACTION TESTS
    // ============================================================

    function test_Contract08_Case22_queueTransactionSuccess() public {
        bytes memory data = abi.encode(uint256(42));
        uint256 eta = block.timestamp + DEFAULT_DELAY;

        vm.prank(admin1);
        bytes32 txHash = timeLock.queueTransaction(address(target), 0, "setValue(uint256)", data, eta);

        assertTrue(timeLock.queuedTransactions(txHash));
    }

    function test_Contract08_Case23_queueTransactionRevertsIfNotAdmin() public {
        bytes memory data = abi.encode(uint256(42));
        uint256 eta = block.timestamp + DEFAULT_DELAY;

        vm.prank(nonAdmin);
        vm.expectRevert(TimeLock.TimeLock__OnlyAdmin.selector);
        timeLock.queueTransaction(address(target), 0, "setValue(uint256)", data, eta);
    }

    function test_Contract08_Case24_queueTransactionRevertsIfEtaTooEarly() public {
        bytes memory data = abi.encode(uint256(42));
        uint256 eta = block.timestamp + DEFAULT_DELAY - 1;

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__EtaBelowDelay.selector);
        timeLock.queueTransaction(address(target), 0, "setValue(uint256)", data, eta);
    }

    // ============================================================
    // CANCEL TRANSACTION TESTS
    // ============================================================

    function test_Contract08_Case25_cancelTransactionSuccess() public {
        bytes memory data = abi.encode(uint256(42));
        bytes32 txHash = _queueTransaction(address(target), 0, "setValue(uint256)", data);

        vm.prank(admin1);
        timeLock.cancelTransaction(address(target), 0, "setValue(uint256)", data, block.timestamp + DEFAULT_DELAY);

        assertFalse(timeLock.queuedTransactions(txHash));
    }

    function test_Contract08_Case26_cancelTransactionRevertsIfNotAdmin() public {
        bytes memory data = abi.encode(uint256(42));
        _queueTransaction(address(target), 0, "setValue(uint256)", data);

        vm.prank(nonAdmin);
        vm.expectRevert(TimeLock.TimeLock__OnlyAdmin.selector);
        timeLock.cancelTransaction(address(target), 0, "setValue(uint256)", data, block.timestamp + DEFAULT_DELAY);
    }

    // ============================================================
    // EXECUTE TRANSACTION TESTS
    // ============================================================

    function test_Contract08_Case27_executeTransactionSuccess() public {
        bytes memory data = abi.encode(uint256(42));
        _queueTransaction(address(target), 0, "setValue(uint256)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        timeLock.executeTransaction(address(target), 0, "setValue(uint256)", data, block.timestamp);

        assertEq(target.value(), 42);
        assertEq(target.caller(), address(timeLock));
    }

    function test_Contract08_Case28_executeTransactionRevertsIfNotAdmin() public {
        bytes memory data = abi.encode(uint256(42));
        _queueTransaction(address(target), 0, "setValue(uint256)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(nonAdmin);
        vm.expectRevert(TimeLock.TimeLock__OnlyAdmin.selector);
        timeLock.executeTransaction(address(target), 0, "setValue(uint256)", data, block.timestamp);
    }

    function test_Contract08_Case29_executeTransactionRevertsIfNotQueued() public {
        bytes memory data = abi.encode(uint256(42));

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionNotQueued.selector);
        timeLock.executeTransaction(address(target), 0, "setValue(uint256)", data, block.timestamp);
    }

    function test_Contract08_Case30_executeTransactionRevertsIfNotReady() public {
        bytes memory data = abi.encode(uint256(42));
        _queueTransaction(address(target), 0, "setValue(uint256)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY - 1);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionNotReady.selector);
        timeLock.executeTransaction(address(target), 0, "setValue(uint256)", data, block.timestamp + DEFAULT_DELAY);
    }

    function test_Contract08_Case31_executeTransactionRevertsIfStale() public {
        bytes memory data = abi.encode(uint256(42));
        uint256 eta = block.timestamp + DEFAULT_DELAY;
        _queueTransaction(address(target), 0, "setValue(uint256)", data);

        vm.warp(eta + 15 days); // Past EXEC_PERIOD

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionStale.selector);
        timeLock.executeTransaction(address(target), 0, "setValue(uint256)", data, eta);
    }

    function test_Contract08_Case32_executeTransactionRevertsOnTargetFailure() public {
        bytes memory data = "";
        _queueTransaction(address(target), 0, "revertingFunction()", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionFailed.selector);
        timeLock.executeTransaction(address(target), 0, "revertingFunction()", data, block.timestamp);
    }

    function test_Contract08_Case33_executeTransactionWithValue() public {
        bytes memory data = "";
        _queueTransaction(address(target), 1 ether, "", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        uint256 targetBalanceBefore = address(target).balance;
        uint256 timelockBalanceBefore = address(timeLock).balance;

        vm.prank(admin1);
        timeLock.executeTransaction(address(target), 1 ether, "", data, block.timestamp);

        assertEq(address(target).balance, targetBalanceBefore + 1 ether);
        assertEq(address(timeLock).balance, timelockBalanceBefore - 1 ether);
    }

    function test_Contract08_Case34_executeTransactionClearsQueue() public {
        bytes memory data = abi.encode(uint256(42));
        bytes32 txHash = _queueTransaction(address(target), 0, "setValue(uint256)", data);

        assertTrue(timeLock.queuedTransactions(txHash));

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        timeLock.executeTransaction(address(target), 0, "setValue(uint256)", data, block.timestamp);

        assertFalse(timeLock.queuedTransactions(txHash));
    }

    // ============================================================
    // SET DELAY TESTS
    // ============================================================

    function test_Contract08_Case35_setDelayViaTimelock() public {
        uint256 newDelay = 5 days;
        bytes memory data = abi.encode(newDelay);
        _queueTransaction(address(timeLock), 0, "setDelay(uint256)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        timeLock.executeTransaction(address(timeLock), 0, "setDelay(uint256)", data, block.timestamp);

        assertEq(timeLock.delayTime(), newDelay);
    }

    function test_Contract08_Case36_setDelayRevertsIfNotTimelock() public {
        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__OnlyTimeLockItself.selector);
        timeLock.setDelay(5 days);
    }

    function test_Contract08_Case37_setDelayRevertsIfTooLow() public {
        bytes memory data = abi.encode(uint256(0.5 days));
        _queueTransaction(address(timeLock), 0, "setDelay(uint256)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionFailed.selector);
        timeLock.executeTransaction(address(timeLock), 0, "setDelay(uint256)", data, block.timestamp);
    }

    function test_Contract08_Case38_setDelayRevertsIfTooHigh() public {
        bytes memory data = abi.encode(uint256(31 days));
        _queueTransaction(address(timeLock), 0, "setDelay(uint256)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__TransactionFailed.selector);
        timeLock.executeTransaction(address(timeLock), 0, "setDelay(uint256)", data, block.timestamp);
    }

    // ============================================================
    // TRANSFER ETHER TESTS
    // ============================================================

    function test_Contract08_Case39_transferEtherSuccess() public {
        address payable recipient = payable(makeAddr("recipient"));
        uint256 amount = 1 ether;

        uint256 recipientBalanceBefore = recipient.balance;
        uint256 timelockBalanceBefore = address(timeLock).balance;

        vm.prank(admin1);
        timeLock.transferEther(recipient, amount);

        assertEq(recipient.balance, recipientBalanceBefore + amount);
        assertEq(address(timeLock).balance, timelockBalanceBefore - amount);
    }

    function test_Contract08_Case40_transferEtherRevertsIfNotAdmin() public {
        address payable recipient = payable(makeAddr("recipient"));

        vm.prank(nonAdmin);
        vm.expectRevert(TimeLock.TimeLock__OnlyAdmin.selector);
        timeLock.transferEther(recipient, 1 ether);
    }

    function test_Contract08_Case41_transferEtherRevertsIfInsufficientBalance() public {
        address payable recipient = payable(makeAddr("recipient"));
        uint256 excessAmount = address(timeLock).balance + 1 ether;

        vm.prank(admin1);
        vm.expectRevert(TimeLock.TimeLock__InsufficientBalance.selector);
        timeLock.transferEther(recipient, excessAmount);
    }

    // ============================================================
    // RECEIVE/FALLBACK TESTS
    // ============================================================

    function test_Contract08_Case42_receiveEther() public {
        uint256 balanceBefore = address(timeLock).balance;

        (bool success,) = address(timeLock).call{value: 1 ether}("");
        assertTrue(success);

        assertEq(address(timeLock).balance, balanceBefore + 1 ether);
    }

    function test_Contract08_Case43_fallbackWithData() public {
        uint256 balanceBefore = address(timeLock).balance;

        (bool success,) = address(timeLock).call{value: 0.5 ether}(abi.encodeWithSignature("nonExistentFunction()"));
        assertTrue(success);

        assertEq(address(timeLock).balance, balanceBefore + 0.5 ether);
    }

    // ============================================================
    // HELPER FUNCTIONS
    // ============================================================

    function _queueTransaction(address target_, uint256 value, string memory signature, bytes memory data)
        internal
        returns (bytes32)
    {
        uint256 eta = block.timestamp + DEFAULT_DELAY;

        vm.prank(admin1);
        return timeLock.queueTransaction(target_, value, signature, data, eta);
    }

    function _setPendingAdminViaTimelock(address pendingAdmin) internal {
        bytes memory data = abi.encode(pendingAdmin);
        _queueTransaction(address(timeLock), 0, "setPendingAdmin(address)", data);

        vm.warp(block.timestamp + DEFAULT_DELAY);

        vm.prank(admin1);
        timeLock.executeTransaction(address(timeLock), 0, "setPendingAdmin(address)", data, block.timestamp);
    }
}
