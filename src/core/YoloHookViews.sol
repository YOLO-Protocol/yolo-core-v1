// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {YoloHookStorage} from "./YoloHookStorage.sol";
import {DataTypes} from "../libraries/DataTypes.sol";
import {SwapModule} from "../libraries/SwapModule.sol";
import {StablecoinModule} from "../libraries/StablecoinModule.sol";
import {LendingPairModule} from "../libraries/LendingPairModule.sol";
import {FlashLoanModule} from "../libraries/FlashLoanModule.sol";
import {DecimalNormalization} from "../libraries/DecimalNormalization.sol";
import {IYoloOracle} from "../interfaces/IYoloOracle.sol";

/**
 * @title YoloHookViews
 * @author alvin@yolo.wtf
 * @notice Delegatecall-only facet that exposes read-only helpers for YoloHook
 */
contract YoloHookViews is YoloHookStorage {
    using DecimalNormalization for uint256;

    // ------------------------------------------------
    // Simple getters
    // ------------------------------------------------

    function paused() external view returns (bool) {
        return s._paused;
    }

    function yoloOracle() external view returns (IYoloOracle) {
        return s.yoloOracle;
    }

    function usy() external view returns (address) {
        return s.usy;
    }

    function usdc() external view returns (address) {
        return s.usdc;
    }

    function ylpVault() external view returns (address) {
        return s.ylpVault;
    }

    function sUSY() external view returns (address) {
        return s.sUSY;
    }

    function treasury() external view returns (address treasuryAddress) {
        treasuryAddress = s.treasury;
    }

    function usdcDecimals() external view returns (uint8) {
        return s.usdcDecimals;
    }

    function getPendingSyntheticBurn() external view returns (address token, uint256 amount) {
        return (s.pendingSyntheticToken, s.pendingSyntheticAmount);
    }

    function totalAnchorReserveUSY() external view returns (uint256) {
        return s.totalAnchorReserveUSY;
    }

    function totalAnchorReserveUSDC() external view returns (uint256) {
        return s.totalAnchorReserveUSDC;
    }

    function getAllSyntheticAssets() external view returns (address[] memory) {
        return s._yoloAssets;
    }

    function getAllWhitelistedCollaterals() external view returns (address[] memory) {
        return s._whitelistedCollaterals;
    }

    function getAssetConfiguration(address syntheticToken) external view returns (DataTypes.AssetConfiguration memory) {
        return s._assetConfigs[syntheticToken];
    }

    function getPairConfiguration(address syntheticAsset, address collateralAsset)
        external
        view
        returns (DataTypes.PairConfiguration memory)
    {
        return s._pairConfigs[_pairId(syntheticAsset, collateralAsset)];
    }

    function getUserPositionKeys(address user) external view returns (DataTypes.UserPositionKey[] memory) {
        return s.userPositionKeys[user];
    }

    function getSyntheticCollaterals(address syntheticAsset) external view returns (address[] memory) {
        return s._syntheticToCollaterals[syntheticAsset];
    }

    function getCollateralSynthetics(address collateral) external view returns (address[] memory) {
        return s._collateralToSynthetics[collateral];
    }

    function getAnchorSwapFeeBps() external view returns (uint256) {
        return s.anchorSwapFeeBps;
    }

    function getSyntheticSwapFeeBps() external view returns (uint256) {
        return s.syntheticSwapFeeBps;
    }

    function getFlashLoanFeeBps() external view returns (uint256) {
        return s.flashLoanFeeBps;
    }

    function getAnchorAmplification() external view returns (uint256) {
        return s.anchorAmplificationCoefficient;
    }

    function getAnchorReserves() external view returns (uint256 reserveUSY, uint256 reserveUSDC) {
        return (s.totalAnchorReserveUSY, s.totalAnchorReserveUSDC);
    }

    function getAnchorReservesNormalized18() external view returns (uint256 reserveUSY18, uint256 reserveUSDC18) {
        reserveUSY18 = s.totalAnchorReserveUSY;
        reserveUSDC18 = s.totalAnchorReserveUSDC.to18(s.usdcDecimals);
    }

    function isYoloAsset(address syntheticToken) external view returns (bool) {
        return s._isYoloAsset[syntheticToken];
    }

    function isWhitelistedCollateral(address collateralAsset) external view returns (bool) {
        return LendingPairModule.isWhitelistedCollateral(s, collateralAsset);
    }

    function getUserTradeCount(address user) external view returns (uint256) {
        return s.tradePositions[user].length;
    }

    error YoloHook__InvalidTradeIndex();

    function getUserTrade(address user, uint256 index) external view returns (DataTypes.TradePosition memory) {
        DataTypes.TradePosition[] storage positions = s.tradePositions[user];
        if (index >= positions.length) revert YoloHook__InvalidTradeIndex();
        return positions[index];
    }

    function getUserPosition(address user, address collateral, address yoloAsset)
        external
        view
        returns (DataTypes.UserPosition memory)
    {
        return s.positions[user][collateral][yoloAsset];
    }

    function getPositionDebt(address user, address collateral, address yoloAsset) external view returns (uint256) {
        return LendingPairModule.getPositionDebt(s, user, collateral, yoloAsset);
    }

    function getUserAccountData(address user)
        external
        view
        returns (uint256 totalCollateralUSD, uint256 totalDebtUSD, uint256 ltv)
    {
        return LendingPairModule.getUserAccountData(s, user);
    }

    function maxFlashLoan(address token) external view returns (uint256 maxAmount) {
        return FlashLoanModule.maxFlashLoan(s, token);
    }

    // ------------------------------------------------
    // View calculators
    // ------------------------------------------------

    function previewAnchorSwap(bool zeroForOne, uint256 amountIn)
        external
        view
        returns (uint256 amountOut, uint256 feeAmount)
    {
        return SwapModule.previewAnchorSwap(s, s._anchorPoolKey, zeroForOne, amountIn);
    }

    function previewAddLiquidity(uint256 usyIn18, uint256 usdcIn18) external view returns (uint256 sUSYToMint) {
        return StablecoinModule.previewAddLiquidity(s, usyIn18, usdcIn18);
    }

    function previewRemoveLiquidity(uint256 sUSYAmount) external view returns (uint256 usyOut18, uint256 usdcOut18) {
        return StablecoinModule.previewRemoveLiquidity(s, sUSYAmount);
    }

    function previewFlashLoanFee(address token, uint256 amount) external view returns (uint256 fee) {
        return FlashLoanModule.previewFlashLoanFee(s, msg.sender, token, amount);
    }

    // ------------------------------------------------
    // Internal helpers
    // ------------------------------------------------

    function _pairId(address syntheticAsset, address collateralAsset) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(syntheticAsset, collateralAsset));
    }
}
