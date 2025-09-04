// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/**
 * @title ACLManager
 * @author alvin@yolo.wtf
 * @notice Centralized contract that manages all roles within YOLO
 * @dev Allows dynamic creation and management of roles with gas-efficient enumeration
 */
contract ACLManager is AccessControl {
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using EnumerableSet for EnumerableSet.AddressSet;

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

    address public immutable YOLO_HOOK;

    /// @notice Address proposed to become the new DEFAULT_ADMIN_ROLE holder
    address public pendingDefaultAdmin;

    /// @notice Set of all created roles for efficient enumeration
    EnumerableSet.Bytes32Set private _allRoles;

    /// @notice Mapping of role to its members for efficient enumeration
    mapping(bytes32 => EnumerableSet.AddressSet) private _roleMembers;

    event RoleCreated(bytes32 indexed role, string name);
    event RoleRemoved(bytes32 indexed role);
    event DefaultAdminTransferred(address indexed previousAdmin, address indexed newAdmin);
    event DefaultAdminProposed(address indexed currentAdmin, address indexed proposedAdmin);
    event DefaultAdminProposalCanceled(address indexed canceledAdmin);

    /**
     * @dev Constructor sets msg.sender as DEFAULT_ADMIN_ROLE and stores YoloHook address
     * @param yoloHook The address of the YoloHook contract
     */
    constructor(address yoloHook) {
        if (yoloHook == address(0)) revert ACL__ZeroAddress();
        YOLO_HOOK = yoloHook;

        // Track DEFAULT_ADMIN_ROLE and grant it to deployer
        _allRoles.add(DEFAULT_ADMIN_ROLE);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _roleMembers[DEFAULT_ADMIN_ROLE].add(msg.sender);
    }

    /**
     * @dev Internal function to check if a role is admin of any other roles
     * @param role The role to check
     * @return True if the role admins other roles
     */
    function _isAdminOfAnyRole(bytes32 role) internal view returns (bool) {
        uint256 count = _allRoles.length();
        for (uint256 i = 0; i < count; i++) {
            bytes32 checkRole = _allRoles.at(i);
            if (checkRole != role && getRoleAdmin(checkRole) == role) {
                return true;
            }
        }
        return false;
    }

    /**
     * @dev Checks if setting newAdmin as admin of role would create a circular dependency
     * @param role The role to check
     * @param newAdmin The proposed admin role
     * @return True if it would create a circular dependency
     */
    function _wouldCreateCircularDependency(bytes32 role, bytes32 newAdmin) internal view returns (bool) {
        bytes32 current = newAdmin;
        uint256 iterations = 0;
        uint256 maxIterations = _allRoles.length(); // Prevent infinite loops

        while (current != bytes32(0) && current != DEFAULT_ADMIN_ROLE && iterations < maxIterations) {
            if (current == role) return true;
            current = getRoleAdmin(current);
            iterations++;
        }
        return false;
    }

    /**
     * @notice Creates a new role with optional admin role
     * @param name The string name for the role (will be hashed to bytes32)
     * @param adminRole The role that will administer this new role (0x00 for DEFAULT_ADMIN_ROLE)
     * @return role The bytes32 role identifier
     */
    function createRole(string calldata name, bytes32 adminRole)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes32)
    {
        if (bytes(name).length == 0) revert ACL__EmptyRoleName();
        bytes32 role = keccak256(abi.encodePacked(name));
        if (_allRoles.contains(role)) revert ACL__RoleAlreadyExists();

        // If adminRole is provided, verify it exists
        if (adminRole != bytes32(0) && !_allRoles.contains(adminRole)) {
            revert ACL__RoleDoesNotExist();
        }

        _allRoles.add(role);

        // Set the admin role if specified
        if (adminRole != bytes32(0)) {
            _setRoleAdmin(role, adminRole);
        }

        emit RoleCreated(role, name);
        return role;
    }

    /**
     * @notice Removes a role from the system
     * @param role The role to remove
     */
    function removeRole(bytes32 role) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_allRoles.contains(role)) revert ACL__RoleDoesNotExist();
        if (role == DEFAULT_ADMIN_ROLE) revert ACL__CannotRemoveDefaultAdmin(); // Can't remove DEFAULT_ADMIN_ROLE
        if (_roleMembers[role].length() > 0) revert ACL__RoleHasMembers();

        // Prevent removing roles that admin other roles
        if (_isAdminOfAnyRole(role)) revert ACL__RoleIsAdminOfOtherRoles();

        _allRoles.remove(role);
        emit RoleRemoved(role);
    }

    /**
     * @notice Sets which role administers another role
     * @param role The role to set admin for
     * @param adminRole The admin role
     */
    function setRoleAdmin(bytes32 role, bytes32 adminRole) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (!_allRoles.contains(role)) revert ACL__RoleDoesNotExist();
        if (!_allRoles.contains(adminRole)) revert ACL__RoleDoesNotExist();

        // Prevent circular dependencies
        if (_wouldCreateCircularDependency(role, adminRole)) {
            revert ACL__WouldCreateCircularDependency();
        }

        _setRoleAdmin(role, adminRole);
    }

    /**
     * @notice Override grantRole to add validation and tracking
     * @param role The role to grant
     * @param account The account to grant the role to
     */
    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (!_allRoles.contains(role) && role != DEFAULT_ADMIN_ROLE) revert ACL__RoleDoesNotExist();

        // Only process if account doesn't already have the role
        if (!hasRole(role, account)) {
            super.grantRole(role, account);
            _roleMembers[role].add(account);
        }
    }

    /**
     * @notice Override revokeRole to add validation and tracking
     * @param role The role to revoke
     * @param account The account to revoke the role from
     */
    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (!_allRoles.contains(role) && role != DEFAULT_ADMIN_ROLE) revert ACL__RoleDoesNotExist();

        // Only process if account has the role
        if (hasRole(role, account)) {
            super.revokeRole(role, account);
            _roleMembers[role].remove(account);
        }
    }

    /**
     * @notice Override renounceRole to add validation and tracking
     * @param role The role to renounce
     * @param account The account renouncing the role (must be msg.sender)
     */
    function renounceRole(bytes32 role, address account) public override {
        if (account != msg.sender) revert ACL__CannotRenounceForOthers();
        if (!hasRole(role, account)) revert ACL__DoesNotHaveRole();

        // Prevent renouncing if it would leave no DEFAULT_ADMIN
        if (role == DEFAULT_ADMIN_ROLE && _roleMembers[role].length() <= 1) {
            revert ACL__CannotRenounceLastAdmin();
        }

        super.renounceRole(role, account);
        _roleMembers[role].remove(account);
    }

    /**
     * @notice Proposes a new address to become the DEFAULT_ADMIN_ROLE holder
     * @dev The proposed admin must accept the role by calling acceptDefaultAdmin()
     * @param newAdmin The address to propose as the new default admin
     */
    function proposeDefaultAdmin(address newAdmin) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newAdmin == address(0)) revert ACL__ZeroAddress();
        if (newAdmin == msg.sender) revert ACL__CannotTransferToSelf();

        pendingDefaultAdmin = newAdmin;
        emit DefaultAdminProposed(msg.sender, newAdmin);
    }

    /**
     * @notice Cancels the pending DEFAULT_ADMIN_ROLE transfer
     * @dev Only the current DEFAULT_ADMIN can cancel
     */
    function cancelDefaultAdminProposal() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (pendingDefaultAdmin == address(0)) revert ACL__NoPendingAdmin();

        address canceledAdmin = pendingDefaultAdmin;
        pendingDefaultAdmin = address(0);
        emit DefaultAdminProposalCanceled(canceledAdmin);
    }

    /**
     * @notice Accepts the DEFAULT_ADMIN_ROLE transfer
     * @dev Must be called by the pending admin address
     */
    function acceptDefaultAdmin() external {
        if (msg.sender != pendingDefaultAdmin) revert ACL__NotPendingAdmin();
        if (pendingDefaultAdmin == address(0)) revert ACL__NoPendingAdmin();

        // Get current admin(s) - there should only be one
        uint256 adminCount = _roleMembers[DEFAULT_ADMIN_ROLE].length();
        address previousAdmin;

        // Remove all current DEFAULT_ADMIN_ROLE holders
        for (uint256 i = 0; i < adminCount; i++) {
            previousAdmin = _roleMembers[DEFAULT_ADMIN_ROLE].at(0);
            _revokeRole(DEFAULT_ADMIN_ROLE, previousAdmin);
            _roleMembers[DEFAULT_ADMIN_ROLE].remove(previousAdmin);
        }

        // Grant role to new admin
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _roleMembers[DEFAULT_ADMIN_ROLE].add(msg.sender);

        // Clear pending admin
        pendingDefaultAdmin = address(0);

        emit DefaultAdminTransferred(previousAdmin, msg.sender);
    }

    /**
     * @notice Gets all created roles
     * @return roles Array of all role identifiers
     */
    function getAllRoles() external view returns (bytes32[] memory roles) {
        return _allRoles.values();
    }

    /**
     * @notice Gets the total number of roles
     * @return The number of roles
     */
    function getRoleCount() external view returns (uint256) {
        return _allRoles.length();
    }

    /**
     * @notice Gets a role by index
     * @param index The index of the role
     * @return The role identifier
     */
    function getRoleByIndex(uint256 index) external view returns (bytes32) {
        if (index >= _allRoles.length()) revert ACL__IndexOutOfBounds();
        return _allRoles.at(index);
    }

    /**
     * @notice Checks if a role exists
     * @param role The role to check
     * @return True if the role exists
     */
    function roleExists(bytes32 role) external view returns (bool) {
        return _allRoles.contains(role);
    }

    /**
     * @notice Gets the number of members in a role
     * @param role The role to query
     * @return The number of members
     */
    function getRoleMemberCount(bytes32 role) external view returns (uint256) {
        return _roleMembers[role].length();
    }

    /**
     * @notice Gets a role member by index
     * @param role The role to query
     * @param index The index of the member
     * @return The address of the role member
     */
    function getRoleMember(bytes32 role, uint256 index) external view returns (address) {
        if (index >= _roleMembers[role].length()) revert ACL__IndexOutOfBounds();
        return _roleMembers[role].at(index);
    }

    /**
     * @notice Gets all members of a role
     * @param role The role to query
     * @return members Array of addresses with the role
     */
    function getRoleMembers(bytes32 role) external view returns (address[] memory members) {
        return _roleMembers[role].values();
    }

    /**
     * @notice Grants a role to multiple accounts in one transaction
     * @param role The role to grant
     * @param accounts Array of accounts to grant the role to
     */
    function grantRoleBatch(bytes32 role, address[] calldata accounts) external onlyRole(getRoleAdmin(role)) {
        if (!_allRoles.contains(role) && role != DEFAULT_ADMIN_ROLE) revert ACL__RoleDoesNotExist();

        for (uint256 i = 0; i < accounts.length; i++) {
            if (!hasRole(role, accounts[i])) {
                super.grantRole(role, accounts[i]);
                _roleMembers[role].add(accounts[i]);
            }
        }
    }

    /**
     * @notice Revokes a role from multiple accounts in one transaction
     * @param role The role to revoke
     * @param accounts Array of accounts to revoke the role from
     */
    function revokeRoleBatch(bytes32 role, address[] calldata accounts) external onlyRole(getRoleAdmin(role)) {
        if (!_allRoles.contains(role) && role != DEFAULT_ADMIN_ROLE) revert ACL__RoleDoesNotExist();

        for (uint256 i = 0; i < accounts.length; i++) {
            if (hasRole(role, accounts[i])) {
                super.revokeRole(role, accounts[i]);
                _roleMembers[role].remove(accounts[i]);
            }
        }
    }

    /**
     * @notice Checks if the contract supports a specific interface
     * @param interfaceId The interface identifier
     * @return True if the interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
