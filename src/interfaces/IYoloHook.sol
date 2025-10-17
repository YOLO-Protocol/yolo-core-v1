// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IYoloOracle} from "./IYoloOracle.sol";

/**
 * @title IYoloHook
 * @author alvin@yolo.wtf
 * @notice Interface for YoloHook integration with sUSY and other protocol components
 */
interface IYoloHook {
    /// @notice Get USY token address
    function usy() external view returns (address);

    /// @notice Get YoloOracle address (centralized oracle for all synthetic assets)
    function yoloOracle() external view returns (IYoloOracle);

    /// @notice Get current anchor pool reserves (raw values)
    /// @return reserveUSY USY reserves (18 decimals)
    /// @return reserveUSDC USDC reserves (native decimals - chain dependent)
    function getAnchorReserves() external view returns (uint256 reserveUSY, uint256 reserveUSDC);

    /// @notice Get anchor pool reserves normalized to 18 decimals
    /// @dev Reduces repeated scaling in sUSY/UI
    /// @return reserveUSY18 USY reserves (18 decimals)
    /// @return reserveUSDC18 USDC reserves (18 decimals normalized)
    function getAnchorReservesNormalized18() external view returns (uint256 reserveUSY18, uint256 reserveUSDC18);

    /// @notice Get USDC decimals (retrieved during initialize())
    function usdcDecimals() external view returns (uint8);

    /// @notice Get USDC token address
    function usdc() external view returns (address);

    /// @notice Get PoolManager address (Uniswap V4)
    function poolManagerAddress() external view returns (address);

    /// @notice Mint USY into the YLP vault (for negative PnL settlement)
    /// @dev Callable only by registered YOLO synthetic assets
    function fundYLPWithUSY(uint256 amount) external;

    /// @notice Settle PnL on behalf of a synthetic during burn
    /// @dev Callable only by registered YOLO synthetic assets
    /// @param user Account whose position is being settled
    /// @param pnlUSY Profit/loss in USY (positive = user profit; negative = user loss)
    function settlePnLFromSynthetic(address user, int256 pnlUSY) external;

    /// @notice Preview sUSY minted for adding liquidity
    /// @dev Uses min-share formula, enforces balanced deposits
    /// @param usyIn18 USY amount (18 decimals)
    /// @param usdcIn18 USDC amount (18 decimals normalized)
    /// @return sUSYToMint Expected sUSY tokens
    function previewAddLiquidity(uint256 usyIn18, uint256 usdcIn18) external view returns (uint256 sUSYToMint);

    /// @notice Preview token amounts for burning sUSY
    /// @param sUSYAmount sUSY to burn
    /// @return usyOut18 USY to receive (18 decimals)
    /// @return usdcOut18 USDC to receive (18 decimals normalized)
    function previewRemoveLiquidity(uint256 sUSYAmount) external view returns (uint256 usyOut18, uint256 usdcOut18);

    /// @notice Add liquidity to anchor pool
    function addLiquidity(uint256 maxUsyAmount, uint256 maxUsdcAmount, uint256 minSUSYReceive, address receiver)
        external
        returns (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted);

    /// @notice Remove liquidity from anchor pool
    function removeLiquidity(uint256 sUSYAmount, uint256 minUsyOut, uint256 minUsdcOut, address receiver)
        external
        returns (uint256 usyOut, uint256 usdcOut);

    /// @notice Returns true if the address is a YOLO synthetic asset
    function isYoloAsset(address syntheticToken) external view returns (bool);
}
