// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/access/ACLManager.sol";

/**
 * @title   TestContract01_ACLManager
 * @author  alvin@yolo.wtf
 * @dev     Comprehensive test suite for ACLManager contract to ensure proper role-based
 *          access control with dynamic role creation and management capabilities
 */
contract TestContract01_ACLManager is Test {
    ACLManager public aclManager;

    address public admin;
    address public user1;
    address public user2;
    address public user3;
    address public mockYoloHook;

    bytes32 public constant RISK_ADMIN_ROLE = keccak256("RISK_ADMIN");
    bytes32 public constant ASSETS_ADMIN_ROLE = keccak256("ASSETS_ADMIN");
    bytes32 public constant PRIVILEGED_LIQUIDATOR_ROLE = keccak256("PRIVILEGED_LIQUIDATOR");
    bytes32 public constant EMERGENCY_ADMIN_ROLE = keccak256("EMERGENCY_ADMIN");

    event RoleCreated(bytes32 indexed role, string name);
    event RoleRemoved(bytes32 indexed role);
    event DefaultAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event DefaultAdminProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event DefaultAdminProposalCanceled(address indexed canceledAdmin);

    function setUp() public {
        admin = address(this);
        user1 = address(0x1);
        user2 = address(0x2);
        user3 = address(0x3);
        mockYoloHook = address(0xbeef);

        // Deploy ACLManager with mock YoloHook address
        aclManager = new ACLManager(mockYoloHook);

        console.log("ACLManager deployed at:", address(aclManager));
        console.log("Admin address:", admin);
        emit log_named_address("YoloHook address", mockYoloHook);
    }

    /**
     * @dev Test initial deployment state
     */
    function test_Contract01_Case01_deploymentState() public {
        // Verify YoloHook is set correctly
        assertEq(aclManager.YOLO_HOOK(), mockYoloHook, "YoloHook should be set correctly");

        // Verify deployer has DEFAULT_ADMIN_ROLE
        assertTrue(
            aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), admin), "Deployer should have DEFAULT_ADMIN_ROLE"
        );

        // Verify DEFAULT_ADMIN_ROLE exists in allRoles
        bytes32[] memory allRoles = aclManager.getAllRoles();
        assertEq(allRoles.length, 1, "Should have exactly one role initially");
        assertEq(allRoles[0], aclManager.DEFAULT_ADMIN_ROLE(), "DEFAULT_ADMIN_ROLE should be in allRoles");

        // Verify no pending admin initially
        assertEq(aclManager.pendingDefaultAdmin(), address(0), "No pending admin should be set initially");
    }

    /**
     * @dev Test creating new roles dynamically
     */
    function test_Contract01_Case02_createRole() public {
        // Create RISK_ADMIN role
        vm.expectEmit(true, false, false, true);
        emit RoleCreated(RISK_ADMIN_ROLE, "RISK_ADMIN");
        bytes32 createdRole = aclManager.createRole("RISK_ADMIN", bytes32(0));

        assertEq(createdRole, RISK_ADMIN_ROLE, "Created role should match expected hash");
        assertTrue(aclManager.roleExists(RISK_ADMIN_ROLE), "Role should exist after creation");

        // Verify role is added to allRoles
        bytes32[] memory allRoles = aclManager.getAllRoles();
        assertEq(allRoles.length, 2, "Should have two roles after creation");

        // Try to create duplicate role - should fail
        vm.expectRevert(ACLManager.ACL__RoleAlreadyExists.selector);
        aclManager.createRole("RISK_ADMIN", bytes32(0));
    }

    /**
     * @dev Test creating role with custom admin
     */
    function test_Contract01_Case03_createRoleWithCustomAdmin() public {
        // First create RISK_ADMIN role
        bytes32 riskAdminRole = aclManager.createRole("RISK_ADMIN", bytes32(0));

        // Create ASSETS_ADMIN role with RISK_ADMIN as admin
        bytes32 assetsAdminRole = aclManager.createRole("ASSETS_ADMIN", riskAdminRole);

        // Verify RISK_ADMIN is the admin of ASSETS_ADMIN
        assertEq(aclManager.getRoleAdmin(assetsAdminRole), riskAdminRole, "RISK_ADMIN should be admin of ASSETS_ADMIN");

        // Try to create role with non-existent admin - should fail
        bytes32 nonExistentRole = keccak256("NON_EXISTENT");
        vm.expectRevert(ACLManager.ACL__RoleDoesNotExist.selector);
        aclManager.createRole("TEST_ROLE", nonExistentRole);
    }

    /**
     * @dev Test granting and revoking roles
     */
    function test_Contract01_Case04_grantAndRevokeRole() public {
        // Create a role
        bytes32 role = aclManager.createRole("RISK_ADMIN", bytes32(0));

        // Grant role to user1
        aclManager.grantRole(role, user1);
        assertTrue(aclManager.hasRole(role, user1), "User1 should have role after grant");

        // Verify member count
        assertEq(aclManager.getRoleMemberCount(role), 1, "Role should have 1 member");
        assertEq(aclManager.getRoleMember(role, 0), user1, "First member should be user1");

        // Grant role to user2
        aclManager.grantRole(role, user2);
        assertEq(aclManager.getRoleMemberCount(role), 2, "Role should have 2 members");

        // Revoke role from user1
        aclManager.revokeRole(role, user1);
        assertFalse(aclManager.hasRole(role, user1), "User1 should not have role after revoke");
        assertEq(aclManager.getRoleMemberCount(role), 1, "Role should have 1 member after revoke");

        // Try to grant non-existent role - should fail
        bytes32 nonExistentRole = keccak256("NON_EXISTENT");
        vm.expectRevert(ACLManager.ACL__RoleDoesNotExist.selector);
        aclManager.grantRole(nonExistentRole, user1);
    }

    /**
     * @dev Test batch operations for efficiency
     */
    function test_Contract01_Case05_batchOperations() public {
        // Create a role
        bytes32 role = aclManager.createRole("LIQUIDATOR", bytes32(0));

        // Prepare batch of addresses
        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = user3;

        // Grant role to batch
        aclManager.grantRoleBatch(role, accounts);

        // Verify all have the role
        assertTrue(aclManager.hasRole(role, user1), "User1 should have role");
        assertTrue(aclManager.hasRole(role, user2), "User2 should have role");
        assertTrue(aclManager.hasRole(role, user3), "User3 should have role");
        assertEq(aclManager.getRoleMemberCount(role), 3, "Role should have 3 members");

        // Revoke role from batch
        aclManager.revokeRoleBatch(role, accounts);

        // Verify all roles revoked
        assertFalse(aclManager.hasRole(role, user1), "User1 should not have role");
        assertFalse(aclManager.hasRole(role, user2), "User2 should not have role");
        assertFalse(aclManager.hasRole(role, user3), "User3 should not have role");
        assertEq(aclManager.getRoleMemberCount(role), 0, "Role should have 0 members");
    }

    /**
     * @dev Test renouncing roles
     */
    function test_Contract01_Case06_renounceRole() public {
        // Create role and grant to user1
        bytes32 role = aclManager.createRole("RISK_ADMIN", bytes32(0));
        aclManager.grantRole(role, user1);

        // User1 renounces their role
        vm.prank(user1);
        aclManager.renounceRole(role, user1);

        assertFalse(aclManager.hasRole(role, user1), "User1 should not have role after renounce");

        // User2 tries to renounce for user1 - should fail
        vm.prank(user2);
        vm.expectRevert(ACLManager.ACL__CannotRenounceForOthers.selector);
        aclManager.renounceRole(role, user1);

        // User tries to renounce role they don't have - should fail
        vm.prank(user3);
        vm.expectRevert(ACLManager.ACL__DoesNotHaveRole.selector);
        aclManager.renounceRole(role, user3);
    }

    /**
     * @dev Test setting role admin
     */
    function test_Contract01_Case07_setRoleAdmin() public {
        // Create two roles
        bytes32 managerRole = aclManager.createRole("MANAGER", bytes32(0));
        bytes32 operatorRole = aclManager.createRole("OPERATOR", bytes32(0));

        // Set MANAGER as admin of OPERATOR
        aclManager.setRoleAdmin(operatorRole, managerRole);
        assertEq(aclManager.getRoleAdmin(operatorRole), managerRole, "MANAGER should be admin of OPERATOR");

        // Grant MANAGER role to user1
        aclManager.grantRole(managerRole, user1);

        // User1 (with MANAGER role) should be able to grant OPERATOR role
        vm.prank(user1);
        aclManager.grantRole(operatorRole, user2);
        assertTrue(aclManager.hasRole(operatorRole, user2), "User2 should have OPERATOR role");

        // Admin (without MANAGER role) should not be able to grant OPERATOR role anymore
        vm.expectRevert();
        aclManager.grantRole(operatorRole, user3);
    }

    /**
     * @dev Test two-step DEFAULT_ADMIN transfer - propose and accept
     */
    function test_Contract01_Case08_twoStepAdminTransfer() public {
        // Propose new admin
        vm.expectEmit(true, true, false, true);
        emit DefaultAdminProposed(admin, user1);
        aclManager.proposeDefaultAdmin(user1);

        assertEq(aclManager.pendingDefaultAdmin(), user1, "User1 should be pending admin");

        // User1 accepts admin role
        vm.prank(user1);
        vm.expectEmit(true, true, false, true);
        emit DefaultAdminTransferred(admin, user1);
        aclManager.acceptDefaultAdmin();

        // Verify transfer completed
        assertTrue(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), user1), "User1 should have DEFAULT_ADMIN_ROLE");
        assertFalse(aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), admin), "Original admin should not have role");
        assertEq(aclManager.pendingDefaultAdmin(), address(0), "Pending admin should be cleared");

        // Verify only one DEFAULT_ADMIN exists
        assertEq(
            aclManager.getRoleMemberCount(aclManager.DEFAULT_ADMIN_ROLE()), 1, "Should have exactly one DEFAULT_ADMIN"
        );
    }

    /**
     * @dev Test canceling admin transfer proposal
     */
    function test_Contract01_Case09_cancelAdminProposal() public {
        // Propose new admin
        aclManager.proposeDefaultAdmin(user1);
        assertEq(aclManager.pendingDefaultAdmin(), user1, "User1 should be pending admin");

        // Cancel proposal
        vm.expectEmit(true, false, false, true);
        emit DefaultAdminProposalCanceled(user1);
        aclManager.cancelDefaultAdminProposal();

        assertEq(aclManager.pendingDefaultAdmin(), address(0), "Pending admin should be cleared");

        // User1 tries to accept - should fail
        vm.prank(user1);
        vm.expectRevert(ACLManager.ACL__NotPendingAdmin.selector);
        aclManager.acceptDefaultAdmin();

        // Try to cancel when no proposal - should fail
        vm.expectRevert(ACLManager.ACL__NoPendingAdmin.selector);
        aclManager.cancelDefaultAdminProposal();
    }

    /**
     * @dev Test admin transfer edge cases
     */
    function test_Contract01_Case10_adminTransferEdgeCases() public {
        // Try to propose zero address - should fail
        vm.expectRevert(ACLManager.ACL__ZeroAddress.selector);
        aclManager.proposeDefaultAdmin(address(0));

        // Try to propose self - should fail
        vm.expectRevert(ACLManager.ACL__CannotTransferToSelf.selector);
        aclManager.proposeDefaultAdmin(admin);

        // Wrong user tries to accept - should fail
        aclManager.proposeDefaultAdmin(user1);
        vm.prank(user2);
        vm.expectRevert(ACLManager.ACL__NotPendingAdmin.selector);
        aclManager.acceptDefaultAdmin();

        // Non-admin tries to propose - should fail
        vm.prank(user2);
        vm.expectRevert();
        aclManager.proposeDefaultAdmin(user3);
    }

    /**
     * @dev Test removing roles
     */
    function test_Contract01_Case11_removeRole() public {
        // Create and remove empty role
        bytes32 role = aclManager.createRole("TEMP_ROLE", bytes32(0));
        assertTrue(aclManager.roleExists(role), "Role should exist");

        aclManager.removeRole(role);
        assertFalse(aclManager.roleExists(role), "Role should not exist after removal");

        // Create role with members
        bytes32 roleWithMembers = aclManager.createRole("ROLE_WITH_MEMBERS", bytes32(0));
        aclManager.grantRole(roleWithMembers, user1);

        // Try to remove role with members - should fail
        vm.expectRevert(ACLManager.ACL__RoleHasMembers.selector);
        aclManager.removeRole(roleWithMembers);

        // Remove member then remove role
        aclManager.revokeRole(roleWithMembers, user1);
        aclManager.removeRole(roleWithMembers);
        assertFalse(aclManager.roleExists(roleWithMembers), "Role should be removed");

        // Try to remove DEFAULT_ADMIN_ROLE - should fail
        bytes32 defaultAdminRole = aclManager.DEFAULT_ADMIN_ROLE();
        vm.expectRevert(ACLManager.ACL__CannotRemoveDefaultAdmin.selector);
        aclManager.removeRole(defaultAdminRole);

        // Try to remove non-existent role - should fail
        vm.expectRevert(ACLManager.ACL__RoleDoesNotExist.selector);
        aclManager.removeRole(keccak256("NON_EXISTENT"));
    }

    /**
     * @dev Test role enumeration functions
     */
    function test_Contract01_Case12_roleEnumeration() public {
        // Create multiple roles
        bytes32 role1 = aclManager.createRole("ROLE_1", bytes32(0));
        bytes32 role2 = aclManager.createRole("ROLE_2", bytes32(0));
        bytes32 role3 = aclManager.createRole("ROLE_3", bytes32(0));

        // Test getAllRoles
        bytes32[] memory allRoles = aclManager.getAllRoles();
        assertEq(allRoles.length, 4, "Should have 4 roles (including DEFAULT_ADMIN)");

        // Test getRoleCount
        assertEq(aclManager.getRoleCount(), 4, "Role count should be 4");

        // Test getRoleByIndex
        bytes32 roleAtIndex1 = aclManager.getRoleByIndex(1);
        assertTrue(
            roleAtIndex1 == role1 || roleAtIndex1 == role2 || roleAtIndex1 == role3,
            "Role at index should be one of created roles"
        );

        // Test index out of bounds
        vm.expectRevert(ACLManager.ACL__IndexOutOfBounds.selector);
        aclManager.getRoleByIndex(10);

        // Add members and test member enumeration
        aclManager.grantRole(role1, user1);
        aclManager.grantRole(role1, user2);
        aclManager.grantRole(role1, user3);

        assertEq(aclManager.getRoleMemberCount(role1), 3, "Role should have 3 members");

        // Test getRoleMembers
        address[] memory members = aclManager.getRoleMembers(role1);
        assertEq(members.length, 3, "Should return 3 members");

        // Test getRoleMember by index
        address member0 = aclManager.getRoleMember(role1, 0);
        assertTrue(member0 == user1 || member0 == user2 || member0 == user3, "Member should be one of the users");

        // Test member index out of bounds
        vm.expectRevert(ACLManager.ACL__IndexOutOfBounds.selector);
        aclManager.getRoleMember(role1, 10);
    }

    /**
     * @dev Test access control on admin functions
     */
    function test_Contract01_Case13_accessControlOnAdminFunctions() public {
        // Non-admin tries to create role - should fail
        vm.prank(user1);
        vm.expectRevert();
        aclManager.createRole("UNAUTHORIZED_ROLE", bytes32(0));

        // Non-admin tries to remove role - should fail
        bytes32 role = aclManager.createRole("TEST_ROLE", bytes32(0));
        vm.prank(user1);
        vm.expectRevert();
        aclManager.removeRole(role);

        // Non-admin tries to set role admin - should fail
        bytes32 defaultAdminRole = aclManager.DEFAULT_ADMIN_ROLE();
        vm.prank(user1);
        vm.expectRevert();
        aclManager.setRoleAdmin(role, defaultAdminRole);

        // Non-admin tries to cancel admin proposal - should fail
        aclManager.proposeDefaultAdmin(user2);
        vm.prank(user1);
        vm.expectRevert();
        aclManager.cancelDefaultAdminProposal();
    }

    /**
     * @dev Test that override functions prevent bypass
     */
    function test_Contract01_Case14_overridePreventsRoleBypass() public {
        // Create a role
        bytes32 role = aclManager.createRole("TEST_ROLE", bytes32(0));

        // Grant role using public grantRole (should work with validation)
        aclManager.grantRole(role, user1);
        assertTrue(aclManager.hasRole(role, user1), "User1 should have role");

        // Try to grant non-existent role (should fail due to override validation)
        bytes32 fakeRole = keccak256("FAKE_ROLE");
        vm.expectRevert(ACLManager.ACL__RoleDoesNotExist.selector);
        aclManager.grantRole(fakeRole, user2);

        // Verify DEFAULT_ADMIN_ROLE bypass works (special case)
        aclManager.grantRole(aclManager.DEFAULT_ADMIN_ROLE(), user2);
        assertTrue(
            aclManager.hasRole(aclManager.DEFAULT_ADMIN_ROLE(), user2), "Should be able to grant DEFAULT_ADMIN_ROLE"
        );
    }

    /**
     * @dev Test interface support
     */
    function test_Contract01_Case15_supportsInterface() public {
        // Test IAccessControl interface support
        bytes4 accessControlInterface = 0x7965db0b; // IAccessControl interface ID
        assertTrue(aclManager.supportsInterface(accessControlInterface), "Should support IAccessControl interface");

        // Test ERC165 interface support
        bytes4 erc165Interface = 0x01ffc9a7; // IERC165 interface ID
        assertTrue(aclManager.supportsInterface(erc165Interface), "Should support ERC165 interface");

        // Test unsupported interface
        bytes4 randomInterface = 0x12345678;
        assertFalse(aclManager.supportsInterface(randomInterface), "Should not support random interface");
    }

    /**
     * @dev Test comprehensive role hierarchy
     */
    function test_Contract01_Case16_roleHierarchy() public {
        // Create role hierarchy: DEFAULT_ADMIN -> RISK_ADMIN -> ASSETS_ADMIN -> PRIVILEGED_LIQUIDATOR
        bytes32 riskAdmin = aclManager.createRole("RISK_ADMIN", aclManager.DEFAULT_ADMIN_ROLE());
        bytes32 assetsAdmin = aclManager.createRole("ASSETS_ADMIN", riskAdmin);
        bytes32 liquidator = aclManager.createRole("PRIVILEGED_LIQUIDATOR", assetsAdmin);

        // Grant roles in hierarchy
        aclManager.grantRole(riskAdmin, user1);

        // user1 (RISK_ADMIN) can grant ASSETS_ADMIN
        vm.prank(user1);
        aclManager.grantRole(assetsAdmin, user2);

        // user2 (ASSETS_ADMIN) can grant PRIVILEGED_LIQUIDATOR
        vm.prank(user2);
        aclManager.grantRole(liquidator, user3);

        // Verify hierarchy
        assertTrue(aclManager.hasRole(riskAdmin, user1), "User1 should have RISK_ADMIN");
        assertTrue(aclManager.hasRole(assetsAdmin, user2), "User2 should have ASSETS_ADMIN");
        assertTrue(aclManager.hasRole(liquidator, user3), "User3 should have PRIVILEGED_LIQUIDATOR");

        // user3 cannot grant roles above their hierarchy
        vm.prank(user3);
        vm.expectRevert();
        aclManager.grantRole(assetsAdmin, address(0x4));
    }

    /**
     * @dev Test zero address validation
     */
    function test_Contract01_Case17_zeroAddressValidation() public {
        // Try to deploy with zero address YoloHook - should fail
        vm.expectRevert(ACLManager.ACL__ZeroAddress.selector);
        new ACLManager(address(0));
    }

    /**
     * @dev Test gas optimization with batch vs individual operations
     */
    function test_Contract01_Case18_gasOptimizationBatch() public {
        bytes32 role = aclManager.createRole("GAS_TEST", bytes32(0));

        address[] memory accounts = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            accounts[i] = address(uint160(0x100 + i));
        }

        // Measure gas for batch operation
        uint256 gasBefore = gasleft();
        aclManager.grantRoleBatch(role, accounts);
        uint256 batchGas = gasBefore - gasleft();

        // Create another role for individual grants
        bytes32 role2 = aclManager.createRole("GAS_TEST_2", bytes32(0));

        // Measure gas for individual operations
        gasBefore = gasleft();
        for (uint256 i = 0; i < 10; i++) {
            aclManager.grantRole(role2, accounts[i]);
        }
        uint256 individualGas = gasBefore - gasleft();

        console.log("Batch operation gas:", batchGas);
        console.log("Individual operations gas:", individualGas);
        console.log("Gas saved:", individualGas - batchGas);

        // Batch should be more efficient
        assertTrue(batchGas < individualGas, "Batch operation should use less gas");
    }

    /**
     * @dev Test that removing a role that admins other roles fails
     */
    function test_Contract01_Case19_cannotRemoveRoleThatAdminsOthers() public {
        bytes32 parentRole = aclManager.createRole("PARENT", bytes32(0));
        bytes32 childRole = aclManager.createRole("CHILD", parentRole);

        // Try to remove parent role - should fail
        vm.expectRevert(ACLManager.ACL__RoleIsAdminOfOtherRoles.selector);
        aclManager.removeRole(parentRole);

        // Should be able to remove child first, then parent
        aclManager.removeRole(childRole);
        aclManager.removeRole(parentRole);
        assertFalse(aclManager.roleExists(parentRole), "Parent role should be removed");
    }

    /**
     * @dev Test that last DEFAULT_ADMIN cannot renounce
     */
    function test_Contract01_Case20_cannotRenounceLastDefaultAdmin() public {
        bytes32 defaultAdminRole = aclManager.DEFAULT_ADMIN_ROLE();

        // Verify we have exactly one admin
        assertEq(aclManager.getRoleMemberCount(defaultAdminRole), 1);

        // Try to renounce - should fail
        vm.expectRevert(ACLManager.ACL__CannotRenounceLastAdmin.selector);
        aclManager.renounceRole(defaultAdminRole, admin);

        // Add second admin
        aclManager.grantRole(defaultAdminRole, user1);

        // Now first admin can renounce
        aclManager.renounceRole(defaultAdminRole, admin);
        assertEq(aclManager.getRoleMemberCount(defaultAdminRole), 1);
        assertTrue(aclManager.hasRole(defaultAdminRole, user1), "User1 should be the remaining admin");
    }

    /**
     * @dev Test two-step transfer with multiple current admins
     */
    function test_Contract01_Case21_twoStepTransferWithMultipleAdmins() public {
        bytes32 adminRole = aclManager.DEFAULT_ADMIN_ROLE();

        // Add second admin
        aclManager.grantRole(adminRole, user1);
        assertEq(aclManager.getRoleMemberCount(adminRole), 2);

        // Propose user2
        aclManager.proposeDefaultAdmin(user2);

        // User2 accepts
        vm.prank(user2);
        aclManager.acceptDefaultAdmin();

        // Should have exactly one admin (user2)
        assertEq(aclManager.getRoleMemberCount(adminRole), 1);
        assertTrue(aclManager.hasRole(adminRole, user2));
        assertFalse(aclManager.hasRole(adminRole, admin));
        assertFalse(aclManager.hasRole(adminRole, user1));
    }

    /**
     * @dev Test batch operations with empty arrays
     */
    function test_Contract01_Case22_batchOperationsWithEmptyArrays() public {
        bytes32 role = aclManager.createRole("EMPTY_BATCH", bytes32(0));
        address[] memory emptyArray = new address[](0);

        // Should not revert with empty arrays
        aclManager.grantRoleBatch(role, emptyArray);
        aclManager.revokeRoleBatch(role, emptyArray);

        assertEq(aclManager.getRoleMemberCount(role), 0);
    }

    /**
     * @dev Test idempotency of grant and revoke operations
     */
    function test_Contract01_Case23_grantRevokeIdempotency() public {
        bytes32 role = aclManager.createRole("IDEMPOTENT", bytes32(0));

        // Grant twice - should be idempotent
        aclManager.grantRole(role, user1);
        aclManager.grantRole(role, user1);
        assertEq(aclManager.getRoleMemberCount(role), 1);
        assertTrue(aclManager.hasRole(role, user1), "User1 should have role");

        // Revoke twice - should be idempotent
        aclManager.revokeRole(role, user1);
        aclManager.revokeRole(role, user1);
        assertEq(aclManager.getRoleMemberCount(role), 0);
        assertFalse(aclManager.hasRole(role, user1), "User1 should not have role");
    }

    /**
     * @dev Test prevention of circular role hierarchies
     */
    function test_Contract01_Case24_preventCircularRoleHierarchy() public {
        bytes32 roleA = aclManager.createRole("ROLE_A", bytes32(0));
        bytes32 roleB = aclManager.createRole("ROLE_B", roleA);
        bytes32 roleC = aclManager.createRole("ROLE_C", roleB);

        // Try to set roleA's admin to roleC (would create circular dependency A->C->B->A)
        vm.expectRevert(ACLManager.ACL__WouldCreateCircularDependency.selector);
        aclManager.setRoleAdmin(roleA, roleC);

        // Try to set roleB's admin to roleC (would create circular dependency B->C->B)
        vm.expectRevert(ACLManager.ACL__WouldCreateCircularDependency.selector);
        aclManager.setRoleAdmin(roleB, roleC);

        // Try to set roleA's admin to roleB (would create circular dependency A->B->A)
        vm.expectRevert(ACLManager.ACL__WouldCreateCircularDependency.selector);
        aclManager.setRoleAdmin(roleA, roleB);

        // Setting to DEFAULT_ADMIN_ROLE should always work
        aclManager.setRoleAdmin(roleA, aclManager.DEFAULT_ADMIN_ROLE());
        assertEq(aclManager.getRoleAdmin(roleA), aclManager.DEFAULT_ADMIN_ROLE());
    }

    /**
     * @dev Test DEFAULT_ADMIN_ROLE special properties
     */
    function test_Contract01_Case25_defaultAdminRoleProperties() public {
        bytes32 defaultAdmin = aclManager.DEFAULT_ADMIN_ROLE();

        // DEFAULT_ADMIN_ROLE should exist
        assertTrue(aclManager.roleExists(defaultAdmin), "DEFAULT_ADMIN_ROLE should exist");

        // DEFAULT_ADMIN_ROLE's admin should be itself
        assertEq(aclManager.getRoleAdmin(defaultAdmin), defaultAdmin, "DEFAULT_ADMIN_ROLE should admin itself");

        // Should have at least one member
        assertTrue(aclManager.getRoleMemberCount(defaultAdmin) > 0, "DEFAULT_ADMIN_ROLE should have members");

        // Cannot be removed
        vm.expectRevert(ACLManager.ACL__CannotRemoveDefaultAdmin.selector);
        aclManager.removeRole(defaultAdmin);
    }

    /**
     * @dev Test empty role name validation
     */
    function test_Contract01_Case26_emptyRoleNameReverts() public {
        vm.expectRevert(ACLManager.ACL__EmptyRoleName.selector);
        aclManager.createRole("", bytes32(0));
    }

    /**
     * @dev Test deeper circular dependency prevention
     */
    function test_Contract01_Case27_deeperCircularDependencyPrevention() public {
        // Create a chain of roles
        bytes32 roleA = aclManager.createRole("ROLE_A", bytes32(0));
        bytes32 roleB = aclManager.createRole("ROLE_B", bytes32(0));
        bytes32 roleC = aclManager.createRole("ROLE_C", bytes32(0));
        bytes32 roleD = aclManager.createRole("ROLE_D", bytes32(0));

        // Set up a chain: A -> B -> C -> D
        aclManager.setRoleAdmin(roleB, roleA);
        aclManager.setRoleAdmin(roleC, roleB);
        aclManager.setRoleAdmin(roleD, roleC);

        // Trying to make D admin of A should fail (would create circular dependency)
        vm.expectRevert(ACLManager.ACL__WouldCreateCircularDependency.selector);
        aclManager.setRoleAdmin(roleA, roleD);

        // Trying to make C admin of A should also fail
        vm.expectRevert(ACLManager.ACL__WouldCreateCircularDependency.selector);
        aclManager.setRoleAdmin(roleA, roleC);

        // Trying to make B admin of C should fail (C is already under B)
        vm.expectRevert(ACLManager.ACL__WouldCreateCircularDependency.selector);
        aclManager.setRoleAdmin(roleB, roleC);

        // But making a new role E with D as admin should work
        bytes32 roleE = aclManager.createRole("ROLE_E", bytes32(0));
        aclManager.setRoleAdmin(roleE, roleD);
        assertEq(aclManager.getRoleAdmin(roleE), roleD, "Role E should have D as admin");
    }
}
