// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/IAccessControl.sol";

/**
 * @title IACLManager
 * @author alvin@yolo.wtf
 * @notice Complete interface for the ACLManager contract
 * @dev Extends IAccessControl and adds YOLO-specific role management functionality
 */
interface IACLManager is IAccessControl {
    // ============ Events ============

    event RoleCreated(bytes32 indexed role, string name);
    event RoleRemoved(bytes32 indexed role);
    event DefaultAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event DefaultAdminProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event DefaultAdminProposalCanceled(address indexed canceledAdmin);

    // ============ Errors ============

    error ACL__ZeroAddress();
    error ACL__RoleAlreadyExists();
    error ACL__RoleDoesNotExist();
    error ACL__CannotTransferToSelf();
    error ACL__IndexOutOfBounds();
    error ACL__DoesNotHaveRole();
    error ACL__RoleHasMembers();
    error ACL__CannotRenounceForOthers();
    error ACL__NotPendingAdmin();
    error ACL__NoPendingAdmin();
    error ACL__CannotRemoveDefaultAdmin();
    error ACL__RoleIsAdminOfOtherRoles();
    error ACL__CannotRenounceLastAdmin();
    error ACL__WouldCreateCircularDependency();
    error ACL__EmptyRoleName();

    // ============ Protocol Integration ============

    /**
     * @notice Returns the YoloHook contract address
     * @return The address of the YoloHook contract
     */
    function YOLO_HOOK() external view returns (address);

    // ============ Admin Transfer Functions ============

    /**
     * @notice Returns the pending DEFAULT_ADMIN_ROLE address
     * @return The address proposed to become the new admin
     */
    function pendingDefaultAdmin() external view returns (address);

    /**
     * @notice Proposes a new address to become the DEFAULT_ADMIN_ROLE holder
     * @param newAdmin The address to propose as the new default admin
     */
    function proposeDefaultAdmin(address newAdmin) external;

    /**
     * @notice Cancels the pending DEFAULT_ADMIN_ROLE transfer
     */
    function cancelDefaultAdminProposal() external;

    /**
     * @notice Accepts the DEFAULT_ADMIN_ROLE transfer
     * @dev Must be called by the pending admin address
     */
    function acceptDefaultAdmin() external;

    // ============ Role Management Functions ============

    /**
     * @notice Creates a new role with optional admin role
     * @param name The string name for the role
     * @param adminRole The role that will administer this new role
     * @return role The bytes32 role identifier
     */
    function createRole(string calldata name, bytes32 adminRole) external returns (bytes32);

    /**
     * @notice Removes a role from the system
     * @param role The role to remove
     */
    function removeRole(bytes32 role) external;

    /**
     * @notice Sets which role administers another role
     * @param role The role to set admin for
     * @param adminRole The admin role
     */
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external;

    // ============ Batch Operations ============

    /**
     * @notice Grants a role to multiple accounts in one transaction
     * @param role The role to grant
     * @param accounts Array of accounts to grant the role to
     */
    function grantRoleBatch(bytes32 role, address[] calldata accounts) external;

    /**
     * @notice Revokes a role from multiple accounts in one transaction
     * @param role The role to revoke
     * @param accounts Array of accounts to revoke the role from
     */
    function revokeRoleBatch(bytes32 role, address[] calldata accounts) external;

    // ============ Role Enumeration Functions ============

    /**
     * @notice Gets all created roles
     * @return roles Array of all role identifiers
     */
    function getAllRoles() external view returns (bytes32[] memory roles);

    /**
     * @notice Gets the total number of roles
     * @return The number of roles
     */
    function getRoleCount() external view returns (uint256);

    /**
     * @notice Gets a role by index
     * @param index The index of the role
     * @return The role identifier
     */
    function getRoleByIndex(uint256 index) external view returns (bytes32);

    /**
     * @notice Checks if a role exists
     * @param role The role to check
     * @return True if the role exists
     */
    function roleExists(bytes32 role) external view returns (bool);

    // ============ Role Member Functions ============

    /**
     * @notice Gets the number of members in a role
     * @param role The role to query
     * @return The number of members
     */
    function getRoleMemberCount(bytes32 role) external view returns (uint256);

    /**
     * @notice Gets a role member by index
     * @param role The role to query
     * @param index The index of the member
     * @return The address of the role member
     */
    function getRoleMember(bytes32 role, uint256 index) external view returns (address);

    /**
     * @notice Gets all members of a role
     * @param role The role to query
     * @return members Array of addresses with the role
     */
    function getRoleMembers(bytes32 role) external view returns (address[] memory members);

    // ============ Inherited from IAccessControl ============
    // These are already declared in IAccessControl but listed here for clarity:
    // - hasRole(bytes32 role, address account)
    // - getRoleAdmin(bytes32 role)
    // - grantRole(bytes32 role, address account)
    // - revokeRole(bytes32 role, address account)
    // - renounceRole(bytes32 role, address account)
}
