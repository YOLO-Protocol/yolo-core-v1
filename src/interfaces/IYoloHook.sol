// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IYoloOracle} from "./IYoloOracle.sol";
import {DataTypes} from "../libraries/DataTypes.sol";

/**
 * @title IYoloHook
 * @author alvin@yolo.wtf
 * @notice Interface for YoloHook integration with sUSY and other protocol components
 */
interface IYoloHook {
    /// @notice Get USY token address
    function usy() external view returns (address);

    /// @notice Get sUSY token address
    function sUSY() external view returns (address);

    /// @notice Get YLP address
    function ylpVault() external view returns (address);

    /// @notice Get YoloOracle address (centralized oracle for all synthetic assets)
    function yoloOracle() external view returns (IYoloOracle);

    /// @notice Get protocol treasury address
    function treasury() external view returns (address);

    /// @notice Get current anchor pool reserves (raw values)
    /// @return reserveUSY USY reserves (18 decimals)
    /// @return reserveUSDC USDC reserves (native decimals - chain dependent)
    function getAnchorReserves() external view returns (uint256 reserveUSY, uint256 reserveUSDC);

    /// @notice Get anchor pool reserves normalized to 18 decimals
    /// @dev Reduces repeated scaling in sUSY/UI
    /// @return reserveUSY18 USY reserves (18 decimals)
    /// @return reserveUSDC18 USDC reserves (18 decimals normalized)
    function getAnchorReservesNormalized18() external view returns (uint256 reserveUSY18, uint256 reserveUSDC18);

    /// @notice Get total anchor pool USY reserve
    /// @return Total USY reserve (18 decimals)
    function totalAnchorReserveUSY() external view returns (uint256);

    /// @notice Get total anchor pool USDC reserve
    /// @return Total USDC reserve (native decimals)
    function totalAnchorReserveUSDC() external view returns (uint256);

    /// @notice Get pending synthetic burn data
    /// @return token Pending synthetic token address
    /// @return amount Pending synthetic burn amount
    function getPendingSyntheticBurn() external view returns (address token, uint256 amount);

    /// @notice Burn pending synthetic tokens
    function burnPendingSynthetic() external;

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

    /// @notice Preview anchor pool swap
    /// @param zeroForOne True if swapping token0 for token1
    /// @param amountIn Amount to swap
    /// @return amountOut Expected output amount
    /// @return feeAmount Fee amount
    function previewAnchorSwap(bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount);

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

    /// @notice Uniswap V4 unlock callback
    /// @param data Encoded callback data
    /// @return Encoded result data
    function unlockCallback(bytes calldata data) external returns (bytes memory);

    /// @notice Returns true if the address is a YOLO synthetic asset
    function isYoloAsset(address syntheticToken) external view returns (bool);

    /// @notice Returns true if the address is whitelisted as collateral
    function isWhitelistedCollateral(address collateralAsset) external view returns (bool);

    /// @notice Get all synthetic assets
    function getAllSyntheticAssets() external view returns (address[] memory);

    /// @notice Create a new synthetic asset
    /// @param name Token name (e.g., "Yolo Synthetic ETH")
    /// @param symbol Token symbol (e.g., "yETH")
    /// @param decimals Token decimals (typically 18)
    /// @param oracleSource Price feed source for the synthetic asset
    /// @param implementation YoloSyntheticAsset implementation address
    /// @param maxSupply Maximum supply cap (0 for unlimited)
    /// @param maxFlashLoanAmount Maximum flash loan amount (0 for unlimited)
    /// @return syntheticToken Address of deployed synthetic token proxy
    function createSyntheticAsset(
        string calldata name,
        string calldata symbol,
        uint8 decimals,
        address oracleSource,
        address implementation,
        uint256 maxSupply,
        uint256 maxFlashLoanAmount
    ) external returns (address syntheticToken);

    /// @notice Deactivate a synthetic asset
    /// @param syntheticToken Address of the synthetic token
    function deactivateSyntheticAsset(address syntheticToken) external;

    /// @notice Reactivate a synthetic asset
    /// @param syntheticToken Address of the synthetic token
    function reactivateSyntheticAsset(address syntheticToken) external;

    /// @notice Get all whitelisted collaterals
    function getAllWhitelistedCollaterals() external view returns (address[] memory);

    /// @notice Whitelist a collateral asset
    /// @param collateralAsset Address of collateral to whitelist
    function whitelistCollateral(address collateralAsset) external;

    /// @notice Configure a lending pair
    /// @param syntheticAsset Synthetic asset address
    /// @param collateralAsset Collateral asset address
    /// @param depositToken Deposit token address
    /// @param debtToken Debt token address
    /// @param ltv Loan-to-Value ratio
    /// @param liquidationThreshold Liquidation threshold
    /// @param liquidationBonus Liquidation bonus
    /// @param liquidationPenalty Liquidation penalty
    /// @param borrowRate Borrow rate
    /// @param maxMintableCap Maximum mintable cap
    /// @param maxSupplyCap Maximum supply cap
    /// @param minimumBorrowAmount Minimum borrow amount
    /// @param isExpirable Whether the pair is expirable
    /// @param expirePeriod Expire period
    /// @return pairId Unique identifier for the pair
    function configureLendingPair(
        address syntheticAsset,
        address collateralAsset,
        address depositToken,
        address debtToken,
        uint256 ltv,
        uint256 liquidationThreshold,
        uint256 liquidationBonus,
        uint256 liquidationPenalty,
        uint256 borrowRate,
        uint256 maxMintableCap,
        uint256 maxSupplyCap,
        uint256 minimumBorrowAmount,
        bool isExpirable,
        uint256 expirePeriod
    ) external returns (bytes32 pairId);

    /// @notice Update risk parameters for a lending pair
    /// @param pairId Unique identifier for the pair
    /// @param ltv New Loan-to-Value ratio
    /// @param liquidationThreshold New liquidation threshold
    /// @param liquidationBonus New liquidation bonus
    function updateRiskParameters(bytes32 pairId, uint256 ltv, uint256 liquidationThreshold, uint256 liquidationBonus)
        external;

    /// @notice Update borrow rate for a lending pair
    /// @param pairId Lending pair ID
    /// @param newBorrowRate New borrow rate in basis points
    function updateBorrowRate(bytes32 pairId, uint256 newBorrowRate) external;

    /// @notice Update the oracle module
    /// @param _yoloOracle New oracle address
    function updateOracle(IYoloOracle _yoloOracle) external;

    /// @notice Update the YLP vault
    /// @param _ylpVault New YLP vault address
    function updateYLPVault(address _ylpVault) external;

    /// @notice Upgrade implementation of a protocol contract
    /// @param target Target contract to upgrade
    /// @param newImplementation New implementation address
    function upgradeImplementation(address target, address newImplementation) external;

    /// @notice Get asset configuration
    function getAssetConfiguration(address syntheticAsset) external view returns (DataTypes.AssetConfiguration memory);

    /// @notice Check if protocol is paused
    function paused() external view returns (bool);

    /// @notice Pause the protocol
    function pause() external;

    /// @notice Unpause the protocol
    function unpause() external;

    /// @notice Get user's position keys for iteration
    /// @param user User address
    /// @return Array of position keys (user's active positions)
    function getUserPositionKeys(address user) external view returns (DataTypes.UserPositionKey[] memory);

    /// @notice Get valid collaterals for a synthetic asset
    /// @param syntheticAsset Synthetic asset address
    /// @return Array of collateral addresses valid for this synthetic
    function getSyntheticCollaterals(address syntheticAsset) external view returns (address[] memory);

    /// @notice Get valid synthetic assets for a collateral
    /// @param collateral Collateral asset address
    /// @return Array of synthetic addresses valid for this collateral
    function getCollateralSynthetics(address collateral) external view returns (address[] memory);

    /// @notice Get anchor pool amplification coefficient
    /// @return Amplification coefficient (A parameter for StableSwap)
    function getAnchorAmplification() external view returns (uint256);

    /// @notice Get anchor pool swap fee
    /// @return Swap fee in basis points (0-10000)
    function getAnchorSwapFeeBps() external view returns (uint256);

    /// @notice Get minimum liquidity constant
    /// @return Minimum liquidity locked on first deposit
    function MINIMUM_LIQUIDITY() external view returns (uint256);

    /// @notice Get LOOPER_ROLE constant
    /// @return LOOPER_ROLE bytes32 value
    function LOOPER_ROLE() external view returns (bytes32);

    /// @notice Get PRIVILEGED_FLASHLOANER_ROLE constant
    /// @return PRIVILEGED_FLASHLOANER_ROLE bytes32 value
    function PRIVILEGED_FLASHLOANER_ROLE() external view returns (bytes32);

    /// @notice Get synthetic pool swap fee
    /// @return Swap fee in basis points (0-10000)
    function getSyntheticSwapFeeBps() external view returns (uint256);

    /// @notice Get flash loan fee
    /// @return Fee in basis points (0-10000)
    function getFlashLoanFeeBps() external view returns (uint256);

    /// @notice Returns all leveraged trades owned by a user
    /// @param user User address
    /// @return Leveraged trade positions
    function getUserTrades(address user) external view returns (DataTypes.TradePosition[] memory);

    /// @notice Returns a single leveraged trade for a user by index
    /// @param user User address
    /// @param index Trade index
    function getUserTrade(address user, uint256 index) external view returns (DataTypes.TradePosition memory);

    /// @notice Returns the total number of leveraged trades owned by a user
    /// @param user User address
    function getUserTradeCount(address user) external view returns (uint256);

    /// @notice Unified entry point for leveraged trade state mutations
    /// @param update Structured update parameters
    /// @return idx Index impacted by the mutation
    /// @return collateralDelta Signed collateral delta applied
    /// @return syntheticDelta Signed synthetic delta applied
    function updateTradePosition(DataTypes.TradeUpdate calldata update)
        external
        returns (uint256 idx, int256 collateralDelta, int256 syntheticDelta);

    /// @notice Settles leveraged-trade PnL (called by TradeOrchestrators)
    /// @param user Trader receiving or paying PnL
    /// @param syntheticAsset Underlying synthetic asset
    /// @param pnlUSY Signed PnL amount (18 decimals)
    function settlePnLFromPerps(address user, address syntheticAsset, int256 pnlUSY) external;

    // ============================================================
    // CDP OPERATIONS
    // ============================================================

    /// @notice Borrow synthetic assets against collateral
    /// @dev Supports onBehalfOf pattern (Aave V3) - LOOPER_ROLE required when onBehalfOf != msg.sender
    /// @param yoloAsset Synthetic asset to borrow
    /// @param borrowAmount Amount to borrow (18 decimals)
    /// @param collateral Collateral asset
    /// @param collateralAmount Amount of collateral to deposit
    /// @param onBehalfOf Address who owns the position (tokens minted to msg.sender)
    function borrow(
        address yoloAsset,
        uint256 borrowAmount,
        address collateral,
        uint256 collateralAmount,
        address onBehalfOf
    ) external;

    /// @notice Repay borrowed synthetic assets
    /// @dev Supports onBehalfOf pattern - LOOPER_ROLE required when onBehalfOf != msg.sender
    ///      Burns tokens from msg.sender, reduces debt on onBehalfOf
    /// @param yoloAsset Synthetic asset to repay
    /// @param collateral Collateral asset
    /// @param repayAmount Amount to repay (0 = full repayment)
    /// @param autoClaimOnFullRepayment Whether to automatically return collateral if debt becomes 0
    /// @param onBehalfOf Address whose debt to reduce (tokens burned from msg.sender)
    function repay(
        address yoloAsset,
        address collateral,
        uint256 repayAmount,
        bool autoClaimOnFullRepayment,
        address onBehalfOf
    ) external;

    /// @notice Renew position (reset expiry time)
    /// @param yoloAsset Synthetic asset
    /// @param collateral Collateral asset
    function renewPosition(address yoloAsset, address collateral) external;

    /// @notice Deposit additional collateral to existing position
    /// @dev Requires existing position - LOOPER_ROLE required when onBehalfOf != msg.sender
    ///      Pulls collateral from msg.sender, credits onBehalfOf
    /// @param yoloAsset Synthetic asset
    /// @param collateral Collateral asset
    /// @param amount Amount to deposit
    /// @param onBehalfOf Address to credit collateral to (collateral from msg.sender)
    function depositCollateral(address yoloAsset, address collateral, uint256 amount, address onBehalfOf) external;

    /// @notice Withdraw collateral from position
    /// @dev LOOPER_ROLE required when onBehalfOf != msg.sender
    ///      Withdraws from onBehalfOf's position, sends to receiver
    /// @param collateral Collateral asset
    /// @param yoloAsset Synthetic asset
    /// @param amount Amount to withdraw
    /// @param onBehalfOf Address whose position to withdraw from
    /// @param receiver Address to receive the withdrawn collateral
    function withdrawCollateral(
        address collateral,
        address yoloAsset,
        uint256 amount,
        address onBehalfOf,
        address receiver
    ) external;

    /// @notice Liquidate an undercollateralized position
    /// @param user Address of the user being liquidated
    /// @param collateral Collateral asset
    /// @param yoloAsset Synthetic asset
    /// @param repayAmount Amount to repay
    function liquidate(address user, address collateral, address yoloAsset, uint256 repayAmount) external;

    /// @notice Get position debt with accrued interest
    /// @param user User address
    /// @param collateral Collateral asset
    /// @param yoloAsset Synthetic asset
    /// @return Current debt amount
    function getPositionDebt(address user, address collateral, address yoloAsset) external view returns (uint256);

    /// @notice Get user position data
    /// @param user User address
    /// @param collateral Collateral asset
    /// @param yoloAsset Synthetic asset
    /// @return position User position struct
    function getUserPosition(address user, address collateral, address yoloAsset)
        external
        view
        returns (DataTypes.UserPosition memory position);

    /// @notice Get aggregated user account data
    /// @param user User address
    /// @return totalCollateralUSD Total collateral in USD
    /// @return totalDebtUSD Total debt in USD
    /// @return ltv Current LTV in basis points
    function getUserAccountData(address user)
        external
        view
        returns (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 ltv);

    /// @notice Get pair configuration
    /// @param yoloAsset Synthetic asset
    /// @param collateral Collateral asset
    /// @return pairConfig Pair configuration struct
    function getPairConfiguration(address yoloAsset, address collateral)
        external
        view
        returns (DataTypes.PairConfiguration memory pairConfig);

    // ============================================================
    // FLASH LOANS
    // ============================================================

    /// @notice Execute flash loan
    /// @dev EIP-3156 compliant - zero fee for PRIVILEGED_FLASHLOANER_ROLE
    /// @param borrower Address to receive the loan
    /// @param token Token to borrow
    /// @param amount Amount to borrow
    /// @param data Arbitrary data passed to borrower
    /// @return success True if flash loan succeeded
    function flashLoan(address borrower, address token, uint256 amount, bytes calldata data)
        external
        returns (bool success);

    /// @notice Execute batch flash loan
    /// @param borrower Address to receive the loans
    /// @param tokens Tokens to borrow
    /// @param amounts Amounts to borrow
    /// @param data Arbitrary data passed to borrower
    /// @return success True if flash loan succeeded
    function flashLoanBatch(
        address borrower,
        address[] calldata tokens,
        uint256[] calldata amounts,
        bytes calldata data
    ) external returns (bool success);

    /// @notice Execute privileged flash loan for leverage operations
    /// @dev Only callable by contracts with LOOPER_ROLE, no reentrancy guard
    /// @param borrower Address to receive the loan (the looper)
    /// @param token Token to borrow
    /// @param amount Amount to borrow
    /// @param data Arbitrary data passed to borrower
    /// @return success True if flash loan succeeded
    function leverageFlashLoan(address borrower, address token, uint256 amount, bytes calldata data)
        external
        returns (bool success);

    /// @notice Get maximum flash loan amount for a token
    /// @param token Token address
    /// @return maxAmount Maximum flash loan amount
    function maxFlashLoan(address token) external view returns (uint256 maxAmount);

    /// @notice Preview flash loan fee
    /// @param token Token to borrow
    /// @param amount Amount to borrow
    /// @return fee Fee amount
    function previewFlashLoanFee(address token, uint256 amount) external view returns (uint256 fee);

    /// @notice Update maximum flash loan amount for a synthetic asset
    /// @param syntheticToken Synthetic asset address
    /// @param newMaxFlashLoanAmount New maximum flash loan amount
    function updateMaxFlashLoanAmount(address syntheticToken, uint256 newMaxFlashLoanAmount) external;

    /// @notice Update flash loan fee
    /// @param newFeeBps New flash loan fee in basis points (0-10000)
    function updateFlashLoanFee(uint256 newFeeBps) external;

    /// @notice Toggle privileged liquidator mode
    /// @param enabled True to restrict liquidations to privileged liquidators only
    function togglePrivilegedLiquidator(bool enabled) external;
}
