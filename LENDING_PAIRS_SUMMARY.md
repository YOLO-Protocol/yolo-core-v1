# Deploy02 Lending Pairs Configuration Summary

## Overview
**Total Lending Pairs Configured: 37 pairs**
- WETH Collateral: 15 pairs (supports ALL assets)
- WBTC Collateral: 12 pairs (supports ALL major assets)
- SOL Collateral: 6 pairs (selective blue chips only)
- sUSDe Collateral: 4 pairs (conservative, safe havens only)

## Risk Framework

### Collateral Tiers
1. **WETH/WBTC**: Blue chip crypto, highest liquidity → Support ALL assets
2. **SOL**: Medium risk → Support USY + select blue chips
3. **sUSDe**: Conservative stablecoin → Support USY + safe havens only

### Interest Rate Structure
- **USY**: 8-10% (varies by collateral risk)
  - WETH/WBTC: 9%
  - SOL: 10%
  - sUSDe: 8%
- **Stocks/Commodities/Metals**: 3-6%
  - Blue chips (AAPL, GOOGL, MSFT, etc.): 4%
  - Volatile (NVDA, TSLA): 5-6%
  - ETFs (SPY, QQQ): 3-4%
- **Forex (EUR)**: 5%
- **Metals (Gold, Silver)**: 4%

### Cap Strategy
- **Single collateral max mint cap**: 40% of asset's total cap
- **USY**: Unlimited (no cap)
- Examples:
  - yBTC/yETH (10M total cap): 4M per collateral
  - ySOL (5M total cap): 2M per collateral
  - yAAPL (10M total cap): 4M per collateral

## Detailed Breakdown

### WETH Collateral (15 pairs)
All pairs support high liquidity and comprehensive asset coverage:

| Synthetic | Rate | LTV | Liq Threshold | Liq Bonus/Penalty | Mint Cap | Min Borrow |
|-----------|------|-----|---------------|-------------------|----------|------------|
| USY | 9% | 75% | 80% | 5%/5% | Unlimited | 100 USY |
| yETH | 3% | **90%** | 95% | 3%/3% | 4M | 1 yETH |
| yBTC | 3% | 70% | 75% | 5%/5% | 4M | 0.01 yBTC |
| ySOL | 4% | 65% | 70% | 7%/7% | 2M | 1 ySOL |
| yAAPL | 4% | 60% | 65% | 7%/7% | 4M | 10 shares |
| yGOOGL | 4% | 60% | 65% | 7%/7% | 4M | 10 shares |
| yNVDA | 5% | **55%** | 60% | 8%/8% | 4M | 10 shares |
| yMETA | 4% | 60% | 65% | 7%/7% | 4M | 10 shares |
| yMSFT | 4% | 60% | 65% | 7%/7% | 4M | 10 shares |
| yAMZN | 4% | 60% | 65% | 7%/7% | 4M | 10 shares |
| yTSLA | 6% | **50%** | 55% | **10%/10%** | 2M | 10 shares |
| ySPY | 3% | 65% | 70% | 6%/6% | 4M | 10 shares |
| yQQQ | 4% | 65% | 70% | 6%/6% | 4M | 10 shares |
| yEUR | 5% | 60% | 65% | 7%/7% | 2M | 100 EUR |
| yXAU | 4% | 65% | 70% | 6%/6% | 2M | 1 oz |

### WBTC Collateral (12 pairs)
Focus on major assets with similar risk parameters to WETH:

| Synthetic | Rate | LTV | Liq Threshold | Liq Bonus/Penalty | Mint Cap | Min Borrow |
|-----------|------|-----|---------------|-------------------|----------|------------|
| USY | 9% | 75% | 80% | 5%/5% | Unlimited | 100 USY |
| yBTC | 3% | **90%** | 95% | 3%/3% | 4M | 0.01 yBTC |
| yETH | 3% | 70% | 75% | 5%/5% | 4M | 1 yETH |
| ySOL | 4% | 65% | 70% | 7%/7% | 2M | 1 ySOL |
| yAAPL | 4% | 60% | 65% | 7%/7% | 4M | 10 shares |
| yGOOGL | 4% | 60% | 65% | 7%/7% | 4M | 10 shares |
| yNVDA | 5% | 55% | 60% | 8%/8% | 4M | 10 shares |
| yMSFT | 4% | 60% | 65% | 7%/7% | 4M | 10 shares |
| ySPY | 3% | 65% | 70% | 6%/6% | 4M | 10 shares |
| yQQQ | 4% | 65% | 70% | 6%/6% | 4M | 10 shares |
| yEUR | 5% | 60% | 65% | 7%/7% | 2M | 100 EUR |
| yXAU | 4% | 65% | 70% | 6%/6% | 2M | 1 oz |

### SOL Collateral (6 pairs - Selective)
Higher risk collateral, only blue chips and major assets:

| Synthetic | Rate | LTV | Liq Threshold | Liq Bonus/Penalty | Mint Cap | Min Borrow |
|-----------|------|-----|---------------|-------------------|----------|------------|
| USY | **10%** | 65% | 70% | 7%/7% | Unlimited | 100 USY |
| ySOL | 4% | **85%** | 90% | 4%/4% | 2M | 1 ySOL |
| yBTC | 4% | 60% | 65% | 8%/8% | **1.5M** | 0.01 yBTC |
| yETH | 4% | 60% | 65% | 8%/8% | **1.5M** | 1 yETH |
| ySPY | 4% | 55% | 60% | 8%/8% | **1.5M** | 10 shares |
| yQQQ | 5% | 55% | 60% | 8%/8% | **1.5M** | 10 shares |

Note: SOL mint caps are 15% (1.5M) instead of 40% for most assets due to higher collateral risk.

### sUSDe Collateral (4 pairs - Conservative)
Stablecoin collateral, only USD-denominated or safe haven assets:

| Synthetic | Rate | LTV | Liq Threshold | Liq Bonus/Penalty | Mint Cap | Min Borrow |
|-----------|------|-----|---------------|-------------------|----------|------------|
| USY | 8% | **80%** | 85% | 4%/4% | Unlimited | 100 USY |
| yEUR | 5% | 70% | 75% | 5%/5% | **1M** | 100 EUR |
| yXAU | 4% | 70% | 75% | 5%/5% | **1M** | 1 oz |
| ySPY | 3% | 65% | 70% | 6%/6% | **1.5M** | 10 shares |

Note: sUSDe mint caps are conservative (15-20%) to limit exposure from stablecoin collateral.

## Key Risk Parameters

### LTV (Loan-to-Value) Ranges
- **90%**: Same-asset pairs (WETH→yETH, WBTC→yBTC, SOL→ySOL)
- **75-80%**: USY minting, stablecoin pairs
- **65-70%**: Blue chip cryptos, major stocks, ETFs
- **60%**: Most stocks
- **50-55%**: High volatility (TSLA, NVDA on SOL)

### Liquidation Bonuses
- **3-4%**: Same-asset pairs, stablecoin pairs (low risk)
- **5-6%**: Blue chip assets
- **7-8%**: Most stocks, volatile cryptos
- **10%**: Highest volatility (TSLA)

### Interest Rate Logic
Based on common sense risk assessment:
1. **Collateral Risk**: SOL (10%) > WETH/WBTC (9%) > sUSDe (8%)
2. **Asset Volatility**:
   - Stablecoins/ETFs: 3%
   - Blue chip stocks: 4%
   - Volatile stocks (NVDA): 5%
   - Very volatile (TSLA): 6%
3. **Forex**: 5% (moderate volatility)
4. **Commodities**: 4% (moderate)

## Implementation Notes

1. **Mint Cap Enforcement**: Each collateral type respects the 40% rule (or less for higher risk)
2. **Supply Cap**: Set to unlimited for all pairs (can be adjusted post-deployment)
3. **Minimum Borrow**:
   - USY: 100 tokens
   - Crypto: 0.01-1 token
   - Stocks: 10 shares
   - Forex: 100 units
   - Precious metals: 1 oz

## Files Modified
- `script/Deploy02_ConfigureProtocol.s.sol`: Complete lending pair configuration
- Lending pair data available in: `temp_lending_pairs.txt`

## Next Steps
1. Copy lending pairs from `temp_lending_pairs.txt` into Deploy02
2. Verify all addresses match deployed collaterals
3. Run Deploy02 to configure all pairs
4. Monitor initial minting activity for cap adjustments
