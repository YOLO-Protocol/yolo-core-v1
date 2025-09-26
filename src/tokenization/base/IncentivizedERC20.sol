// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "../../interfaces/IACLManager.sol";
import "../../interfaces/IIncentivesTracker.sol";

/**
 * @title IncentivizedERC20
 * @author alvin@yolo.wtf
 * @notice Base ERC20 implementation with incentive mechanics for YOLO Protocol
 * @dev Inspired by Aave's implementation, optimized for YOLO's architecture
 */
abstract contract IncentivizedERC20 is Context, IERC20, IERC20Metadata {
    using SafeCast for uint256;

    /**
     * @dev UserState struct packs balance with additional data for gas efficiency
     * The additionalData field usage varies by token type:
     * - DepositToken: Last supply/withdrawal index
     * - DebtToken: Borrow index or stable rate
     * - YoloLiquidityToken: Fee accumulation index
     * - SyntheticAssetToken: Position metadata
     */
    struct UserState {
        uint128 balance;
        uint128 additionalData;
    }

    // Custom errors
    error IncentivizedERC20__InsufficientBalance();
    error IncentivizedERC20__InsufficientAllowance();
    error IncentivizedERC20__InvalidAddress();
    error IncentivizedERC20__OnlyIncentivesAdmin();
    error IncentivizedERC20__IncentivesReentrancy();

    // State variables
    mapping(address => UserState) internal _userState;
    mapping(address => mapping(address => uint256)) private _allowances;

    uint256 internal _totalSupply;
    string private _name;
    string private _symbol;
    uint8 private _decimals;

    // Reentrancy guard for incentive calls
    bool private _incentivesLocked;

    // Immutable reference
    IACLManager public immutable ACL_MANAGER;

    // Role identifier for incentives administration
    bytes32 public constant INCENTIVES_ADMIN_ROLE = keccak256("INCENTIVES_ADMIN");

    // Incentives tracker (can be updated by admin)
    IIncentivesTracker public incentivesTracker;

    // Events
    event IncentivesTrackerUpdated(IIncentivesTracker indexed oldTracker, IIncentivesTracker indexed newTracker);

    /**
     * @dev Constructor sets up immutable references and token metadata
     * @param aclManager The ACLManager contract address
     * @param name_ The token name
     * @param symbol_ The token symbol
     * @param decimals_ The token decimals
     */
    constructor(address aclManager, string memory name_, string memory symbol_, uint8 decimals_) {
        if (aclManager == address(0)) revert IncentivizedERC20__InvalidAddress();

        ACL_MANAGER = IACLManager(aclManager);
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    /**
     * @dev Modifier to restrict functions to incentives admin only
     */
    modifier onlyIncentivesAdmin() {
        if (!ACL_MANAGER.hasRole(INCENTIVES_ADMIN_ROLE, _msgSender())) {
            revert IncentivizedERC20__OnlyIncentivesAdmin();
        }
        _;
    }

    /**
     * @dev Prevents reentrancy specifically for incentive tracker calls
     */
    modifier incentivesGuard() {
        if (_incentivesLocked) revert IncentivizedERC20__IncentivesReentrancy();
        _incentivesLocked = true;
        _;
        _incentivesLocked = false;
    }

    // ============ ERC20 Metadata ============

    /**
     * @notice Returns the name of the token
     */
    function name() public view virtual override returns (string memory) {
        return _name;
    }

    /**
     * @notice Returns the symbol of the token
     */
    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    /**
     * @notice Returns the decimals of the token
     */
    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    // ============ ERC20 Core ============

    /**
     * @notice Returns the total supply of the token
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @notice Returns the balance of an account
     * @param account The address to query
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _userState[account].balance;
    }

    /**
     * @notice Returns the additional data for a user
     * @param account The address to query
     * @return The additional data value
     */
    function getAdditionalData(address account) public view virtual returns (uint128) {
        return _userState[account].additionalData;
    }

    /**
     * @notice Transfers tokens to a recipient
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), to, amount);
        return true;
    }

    /**
     * @notice Returns the allowance of a spender for an owner
     * @param owner The owner address
     * @param spender The spender address
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender];
    }

    /**
     * @notice Approves a spender to spend tokens
     * @param spender The spender address
     * @param amount The amount to approve
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @notice Transfers tokens from an owner to a recipient
     * @param from The owner address
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        _spendAllowance(from, _msgSender(), amount);
        _transfer(from, to, amount);
        return true;
    }

    /**
     * @notice Increases the allowance of a spender
     * @param spender The spender address
     * @param addedValue The amount to increase by
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender] + addedValue);
        return true;
    }

    /**
     * @notice Decreases the allowance of a spender
     * @param spender The spender address
     * @param subtractedValue The amount to decrease by
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender];
        if (currentAllowance < subtractedValue) revert IncentivizedERC20__InsufficientAllowance();
        unchecked {
            _approve(_msgSender(), spender, currentAllowance - subtractedValue);
        }
        return true;
    }

    // ============ Incentives Management ============

    /**
     * @notice Sets the incentives tracker
     * @dev Only callable by accounts with INCENTIVES_ADMIN_ROLE
     * @param newTracker The new incentives tracker
     */
    function setIncentivesTracker(IIncentivesTracker newTracker) external onlyIncentivesAdmin {
        IIncentivesTracker oldTracker = incentivesTracker;
        incentivesTracker = newTracker;
        emit IncentivesTrackerUpdated(oldTracker, newTracker);
    }

    /**
     * @notice Returns the incentives tracker
     */
    function getIncentivesTracker() external view returns (IIncentivesTracker) {
        return incentivesTracker;
    }

    // ============ Internal Functions ============

    /**
     * @dev Internal transfer logic with incentive hooks
     * @notice Updates incentives with NEW balances after state changes to ensure
     *         the incentives tracker calculates rewards based on current positions
     * @param from The sender address
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function _transfer(address from, address to, uint256 amount) internal virtual {
        if (from == address(0)) revert IncentivizedERC20__InvalidAddress();
        if (to == address(0)) revert IncentivizedERC20__InvalidAddress();

        _beforeTokenTransfer(from, to, amount);

        uint128 castAmount = amount.toUint128();

        // Cache pre-transfer balances
        uint128 fromBalanceBefore = _userState[from].balance;
        uint128 toBalanceBefore = _userState[to].balance;

        if (fromBalanceBefore < castAmount) revert IncentivizedERC20__InsufficientBalance();

        // Update balances (Solidity 0.8+ prevents overflow)
        unchecked {
            _userState[from].balance = fromBalanceBefore - castAmount;
        }
        _userState[to].balance = toBalanceBefore + castAmount; // Safe: Solidity 0.8+ reverts on overflow

        // Update incentives with NEW balances after transfer
        _updateIncentives(from, to, _totalSupply, _userState[from].balance, _userState[to].balance);

        emit Transfer(from, to, amount);

        _afterTokenTransfer(from, to, amount);
    }

    /**
     * @dev Updates incentives for affected addresses after balance changes
     * @param from The sender address (or address(0) for mint)
     * @param to The recipient address (or address(0) for burn)
     * @param totalSupplyAfter The total supply after the balance change
     * @param fromBalanceAfter The sender's balance after the change
     * @param toBalanceAfter The recipient's balance after the change
     */
    function _updateIncentives(
        address from,
        address to,
        uint256 totalSupplyAfter,
        uint128 fromBalanceAfter,
        uint128 toBalanceAfter
    ) internal incentivesGuard {
        IIncentivesTracker tracker = incentivesTracker;
        if (address(tracker) == address(0)) return;

        // Update sender if not zero address (skip for mint)
        if (from != address(0)) {
            tracker.handleAction(from, totalSupplyAfter, fromBalanceAfter);
        }

        // Update recipient if not zero address and different from sender
        if (to != address(0) && from != to) {
            tracker.handleAction(to, totalSupplyAfter, toBalanceAfter);
        }
    }

    /**
     * @dev Mints tokens to an account with incentive tracking
     * @param account The account to mint to
     * @param amount The amount to mint
     */
    function _mint(address account, uint256 amount) internal virtual {
        if (account == address(0)) revert IncentivizedERC20__InvalidAddress();

        _beforeTokenTransfer(address(0), account, amount);

        uint128 castAmount = amount.toUint128();

        // Update state
        _totalSupply = _totalSupply + amount;
        _userState[account].balance = _userState[account].balance + castAmount;

        // Update incentives with NEW values after mint
        _updateIncentives(address(0), account, _totalSupply, 0, _userState[account].balance);

        emit Transfer(address(0), account, amount);

        _afterTokenTransfer(address(0), account, amount);
    }

    /**
     * @dev Burns tokens from an account with incentive tracking
     * @param account The account to burn from
     * @param amount The amount to burn
     */
    function _burn(address account, uint256 amount) internal virtual {
        if (account == address(0)) revert IncentivizedERC20__InvalidAddress();

        _beforeTokenTransfer(account, address(0), amount);

        uint128 castAmount = amount.toUint128();
        uint128 accountBalanceBefore = _userState[account].balance;

        if (accountBalanceBefore < castAmount) revert IncentivizedERC20__InsufficientBalance();

        // Update state
        unchecked {
            _userState[account].balance = accountBalanceBefore - castAmount;
            _totalSupply = _totalSupply - amount;
        }

        // Update incentives with NEW values after burn
        _updateIncentives(account, address(0), _totalSupply, _userState[account].balance, 0);

        emit Transfer(account, address(0), amount);

        _afterTokenTransfer(account, address(0), amount);
    }

    /**
     * @dev Updates the additional data for a user
     * @param user The user address
     * @param additionalData The new additional data value
     */
    function _setAdditionalData(address user, uint128 additionalData) internal virtual {
        _userState[user].additionalData = additionalData;
    }

    /**
     * @dev Approve logic
     * @param owner The owner address
     * @param spender The spender address
     * @param amount The amount to approve
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        if (owner == address(0)) revert IncentivizedERC20__InvalidAddress();
        if (spender == address(0)) revert IncentivizedERC20__InvalidAddress();

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    /**
     * @dev Spend allowance logic
     * @param owner The owner address
     * @param spender The spender address
     * @param amount The amount to spend
     */
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual {
        uint256 currentAllowance = allowance(owner, spender);
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < amount) revert IncentivizedERC20__InsufficientAllowance();
            unchecked {
                _approve(owner, spender, currentAllowance - amount);
            }
        }
    }

    /**
     * @dev Hook called before any transfer
     * @param from The sender address
     * @param to The recipient address
     * @param amount The transfer amount
     */
    function _beforeTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    /**
     * @dev Hook called after any transfer
     * @param from The sender address
     * @param to The recipient address
     * @param amount The transfer amount
     */
    function _afterTokenTransfer(address from, address to, uint256 amount) internal virtual {}

    /**
     * @dev Updates token name (internal use only)
     * @param newName The new name
     */
    function _setName(string memory newName) internal {
        _name = newName;
    }

    /**
     * @dev Updates token symbol (internal use only)
     * @param newSymbol The new symbol
     */
    function _setSymbol(string memory newSymbol) internal {
        _symbol = newSymbol;
    }

    /**
     * @dev Updates token decimals (internal use only)
     * @param newDecimals The new decimals
     */
    function _setDecimals(uint8 newDecimals) internal {
        _decimals = newDecimals;
    }
}
