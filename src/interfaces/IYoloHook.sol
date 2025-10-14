// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IYoloHook
 * @author alvin@yolo.wtf
 * @notice Interface for YoloHook integration with sUSY and other protocol components
 */
interface IYoloHook {
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
}
