// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title EIP712Base
 * @author alvin@yolo.wtf
 * @notice Base contract implementation of EIP712 for meta-transactions and gasless approvals
 * @dev Provides domain separator computation, nonce management, and signature verification
 *
 * WARNING: This contract uses immutable variables and constructor initialization,
 * making it incompatible with proxy patterns. For upgradeable contracts or proxies,
 * use EIP712BaseUpgradeable instead.
 */
abstract contract EIP712Base {
    // EIP712 Domain Separator typehash
    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // Permit typehash for gasless approvals (EIP-2612)
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // Delegation typehash for gasless delegation
    bytes32 public constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegator,address delegatee,uint256 nonce,uint256 deadline)");

    // Version of the EIP712 domain
    string public constant EIP712_VERSION = "1";

    // Hashed name for the EIP712 domain
    bytes32 private immutable _NAME_HASH;

    // Chain ID at deployment
    uint256 private immutable INITIAL_CHAIN_ID;

    // Domain separator at deployment
    bytes32 private immutable INITIAL_DOMAIN_SEPARATOR;

    // Mapping of address nonces for replay protection
    mapping(address => uint256) private _nonces;

    // Custom errors
    error EIP712__InvalidSignature();
    error EIP712__ExpiredDeadline();

    /**
     * @dev Constructor computes initial domain separator
     * @param name The name for the EIP712 domain (e.g., token name)
     */
    constructor(string memory name) {
        _NAME_HASH = keccak256(bytes(name));
        INITIAL_CHAIN_ID = block.chainid;
        INITIAL_DOMAIN_SEPARATOR = _computeDomainSeparator();
    }

    /**
     * @notice Get the current domain separator
     * @dev Returns cached value if chain ID hasn't changed, otherwise recomputes
     * @return The domain separator for the current chain
     */
    function DOMAIN_SEPARATOR() public view virtual returns (bytes32) {
        return block.chainid == INITIAL_CHAIN_ID ? INITIAL_DOMAIN_SEPARATOR : _computeDomainSeparator();
    }

    /**
     * @notice Get the current nonce for an address
     * @param owner The address to query
     * @return The current nonce for the address
     */
    function nonces(address owner) public view virtual returns (uint256) {
        return _nonces[owner];
    }

    /**
     * @notice Increment and return the nonce for an address
     * @dev Internal function to be used when consuming a signature
     * @param owner The address whose nonce to increment
     * @return current The current nonce before incrementing
     */
    function _useNonce(address owner) internal virtual returns (uint256 current) {
        current = _nonces[owner];
        _nonces[owner] = current + 1;
    }

    /**
     * @notice Verify and use a nonce for replay protection
     * @dev Reverts if the nonce doesn't match the expected value
     * @param owner The address whose nonce to verify
     * @param nonce The nonce value to verify
     */
    function _useCheckedNonce(address owner, uint256 nonce) internal virtual {
        uint256 current = _nonces[owner];
        if (current != nonce) revert EIP712__InvalidSignature();
        unchecked {
            _nonces[owner] = current + 1;
        }
    }

    /**
     * @notice Check if a deadline has passed
     * @dev Reverts if the deadline has passed. A deadline of 0 will always revert.
     * Consider using type(uint256).max for no deadline.
     * @param deadline The deadline timestamp to check
     */
    function _checkDeadline(uint256 deadline) internal view virtual {
        if (block.timestamp > deadline) revert EIP712__ExpiredDeadline();
    }

    /**
     * @notice Compute the domain separator
     * @return The computed domain separator
     */
    function _computeDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, _NAME_HASH, keccak256(bytes(EIP712_VERSION)), block.chainid, address(this)
            )
        );
    }

    /**
     * @notice Build a digest for EIP712 signature verification
     * @param structHash The hash of the EIP712 struct
     * @return The digest to be signed
     */
    function _hashTypedDataV4(bytes32 structHash) internal view virtual returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), structHash));
    }

    /**
     * @notice Recover signer address from signature
     * @param digest The digest that was signed
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     * @return The recovered signer address
     */
    function _recover(bytes32 digest, uint8 v, bytes32 r, bytes32 s) internal pure returns (address) {
        // Normalize v value: accept both 0/1 and 27/28 formats
        uint8 normalizedV = v;
        if (normalizedV < 27) {
            normalizedV += 27;
        }

        // Validate normalized v value
        if (normalizedV != 27 && normalizedV != 28) {
            revert EIP712__InvalidSignature();
        }

        // Prevent signature malleability (EIP-2)
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
            revert EIP712__InvalidSignature();
        }

        address recovered = ecrecover(digest, normalizedV, r, s);
        if (recovered == address(0)) revert EIP712__InvalidSignature();

        return recovered;
    }

    /**
     * @notice Recover signer from EIP-2098 compact signature
     * @param digest The digest that was signed
     * @param r Half of the ECDSA signature pair
     * @param vs Combined v and s values
     * @return The recovered signer address
     */
    function _recover(bytes32 digest, bytes32 r, bytes32 vs) internal pure returns (address) {
        bytes32 s = vs & bytes32(0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        uint8 v = uint8((uint256(vs) >> 255) + 27);
        return _recover(digest, v, r, s);
    }

    /**
     * @notice Validate and consume a permit signature
     * @param owner The token owner
     * @param spender The spender being approved
     * @param value The approval amount
     * @param deadline The deadline timestamp
     * @param v The recovery byte of the signature
     * @param r Half of the ECDSA signature pair
     * @param s Half of the ECDSA signature pair
     * @return nonce The nonce that was used
     */
    function _validateAndUsePermit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) internal returns (uint256 nonce) {
        _checkDeadline(deadline);
        nonce = _nonces[owner];

        bytes32 digest = _buildPermitDigest(owner, spender, value, nonce, deadline);
        address recovered = _recover(digest, v, r, s);

        if (recovered != owner) revert EIP712__InvalidSignature();

        unchecked {
            _nonces[owner] = nonce + 1;
        }
    }

    /**
     * @notice Build the permit digest for signature
     * @param owner The token owner
     * @param spender The spender being approved
     * @param value The approval amount
     * @param nonce The owner's nonce
     * @param deadline The deadline timestamp
     * @return The permit digest
     */
    function _buildPermitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }

    /**
     * @notice Build the delegation digest for signature
     * @param delegator The address delegating
     * @param delegatee The address being delegated to
     * @param nonce The delegator's nonce
     * @param deadline The deadline timestamp
     * @return The delegation digest
     */
    function _buildDelegationDigest(address delegator, address delegatee, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, delegator, delegatee, nonce, deadline));
        return _hashTypedDataV4(structHash);
    }
}
