// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title TokenFaucet
 * @notice Simple daily faucet to drip mock collateral/USDC to testers
 */
contract TokenFaucet is Ownable {
    using SafeERC20 for IERC20;

    error TokenFaucet__InvalidAddress();
    error TokenFaucet__InvalidAmount();
    error TokenFaucet__ClaimTooSoon(uint256 nextClaimTimestamp);
    error TokenFaucet__InsufficientBalance();

    IERC20 public immutable underlying;
    uint256 public immutable dispensePerDay;

    uint256 private constant CLAIM_COOLDOWN = 1 days;
    mapping(address => uint256) public lastClaimAt;

    event TokenClaimed(address indexed claimer, uint256 amount);
    event TokensDeposited(address indexed from, uint256 amount);

    constructor(address token, uint256 amountPerDay) Ownable(msg.sender) {
        if (token == address(0)) revert TokenFaucet__InvalidAddress();
        if (amountPerDay == 0) revert TokenFaucet__InvalidAmount();
        underlying = IERC20(token);
        dispensePerDay = amountPerDay;
    }

    /**
     * @notice Claim the daily allocation of faucet tokens
     */
    function claimToken() external {
        uint256 last = lastClaimAt[msg.sender];
        if (last != 0 && block.timestamp - last < CLAIM_COOLDOWN) {
            revert TokenFaucet__ClaimTooSoon(last + CLAIM_COOLDOWN);
        }

        if (underlying.balanceOf(address(this)) < dispensePerDay) {
            revert TokenFaucet__InsufficientBalance();
        }

        lastClaimAt[msg.sender] = block.timestamp;
        underlying.safeTransfer(msg.sender, dispensePerDay);
        emit TokenClaimed(msg.sender, dispensePerDay);
    }

    /**
     * @notice Deposit underlying tokens into the faucet
     * @dev Caller must approve this contract beforehand
     */
    function deposit(uint256 amount) external onlyOwner {
        if (amount == 0) revert TokenFaucet__InvalidAmount();
        underlying.safeTransferFrom(msg.sender, address(this), amount);
        emit TokensDeposited(msg.sender, amount);
    }
}
