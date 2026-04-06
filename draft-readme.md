# YOLO Protocol V1

```
___  _ ____  _     ____    ____  ____  ____  _____  ____  ____  ____  _
\  \///  _ \/ \   /  _ \  /  __\/  __\/  _ \/__ __\/  _ \/   _\/  _ \/ \
 \  / | / \|| |   | / \|  |  \/||  \/|| / \|  / \  | / \||  /  | / \|| |
 / /  | \_/|| |_/\| \_/|  |  __/|    /| \_/|  | |  | \_/||  \__| \_/|| |_/\
/_/   \____/\____/\____/  \_/   \_/\_\\____/  \_/  \____/\____/\____/\____/
```

[![License: BUSL-1.1](https://img.shields.io/badge/License-BUSL--1.1-yellow.svg)](https://github.com/YOLO-Protocol/yolo-core-v1/blob/main/LICENSE)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)
[![Tests](https://img.shields.io/badge/Tests-335%20passing-success.svg)]()

**The Ultimate Modular DeFi Infrastructure on Uniswap V4**

YOLO Protocol V1 is a production-ready, gas-optimized DeFi engine built as a Uniswap V4 Hook, combining stablecoin issuance, synthetic asset trading, leveraged positions, and flash loans into a single modular infrastructure.

---

## Quick Start ⚡

```bash
# Clone and install
git clone https://github.com/YOLO-Protocol/yolo-core-v1.git
cd yolo-core-v1
forge install && pnpm install

# Run tests
pnpm test

# Build contracts
pnpm build
```

**Quick Links:**
- 📖 [Full Documentation](#) (Coming Soon)
- 🎮 [Live Demo](#) (Coming Soon)
- 🚀 [Deployed Contracts](#13-deployment)
- 💬 [Discord Community](#)

---

## Table of Contents

- [What is YOLO Protocol?](#what-is-yolo-protocol-)
- [Architecture Overview](#architecture-overview-)
- [Core Components](#core-components-)
- [User Workflows](#user-workflows-)
- [Development Guide](#development-guide-)
- [Testing](#testing-architecture-)
- [Security](#security-)
- [API Reference](#api-reference-)
- [Deployment](#deployment-)

---

## What is YOLO Protocol? 🎯

### Executive Summary

YOLO Protocol V1 is a **modular DeFi infrastructure** that brings together the best features of MakerDAO, Synthetix, and Gearbox—all within a single Uniswap V4 Hook. Built with production-grade security and gas efficiency in mind, it enables:

- **Stablecoin Issuance**: YOLO USD (USY) backed by yield-bearing tokens with Curve-style AMM
- **Synthetic Assets**: Trade yNVDA, yTSLA, yGOLD, and more without traditional liquidity pools
- **Leveraged Trading**: Up to 20x leverage via flash loan-powered YoloLooper
- **Flash Loans**: EIP-3156 compliant with privileged paths for capital efficiency

### Core Value Proposition

**Problem**: Traditional DeFi protocols require users to navigate multiple platforms for stablecoins, synthetic assets, leverage, and flash loans, leading to fragmented liquidity and poor UX.

**Solution**: YOLO Protocol consolidates these primitives into a single, gas-optimized Hook that leverages Uniswap V4's architecture for seamless composability.

**Why Uniswap V4 Hook?**
- ✅ Access to Uniswap's deep liquidity
- ✅ Custom swap logic without liquidity fragmentation
- ✅ Single entry point for all DeFi operations
- ✅ Upgradeable via UUPS proxy pattern

### Key Features at a Glance

| Feature | Description | Use Case |
|---------|-------------|----------|
| **USY Stablecoin** | Curve-style stable swap with USDC | Anchor liquidity, low-slippage swaps |
| **Synthetic Assets** | On-demand assets (yNVDA, yTSLA, yGOLD) | Trade anything with oracle support |
| **YoloLooper** | Flash loan-based leverage (up to 20x) | Capital-efficient leveraged positions |
| **Flash Loans** | Zero-fee for privileged loopers | Arbitrage, liquidations, leverage |
| **sUSY LP Token** | Yield-bearing receipt for anchor pool | Passive income from fees + interest |
| **Compound Interest** | Aave-style RAY precision (27 decimals) | Accurate debt accrual over time |

---

## Architecture Overview 🏗️

### High-Level System Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                         Uniswap V4 Core                         │
│                       (PoolManager)                             │
└────────────────────────┬────────────────────────────────────────┘
                         │ Hook Integration
                         ▼
┌─────────────────────────────────────────────────────────────────┐
│                        YoloHook (Main Entry)                    │
│  - Access Control (ACLManager)                                  │
│  - Pause Mechanism                                              │
│  - Module Orchestration                                         │
└──┬──────────┬──────────┬──────────┬──────────┬─────────┬────────┘
   │          │          │          │          │         │
   ▼          ▼          ▼          ▼          ▼         ▼
┌─────┐  ┌──────┐  ┌────────┐  ┌──────┐  ┌─────┐  ┌──────┐
│Stable│  │Synth │  │Lending │  │Liquid│  │Flash│  │Swap  │
│coin  │  │Asset │  │Pair    │  │ation │  │Loan │  │Modules│
│Module│  │Module│  │Module  │  │Module│  │Module│  │      │
└──┬───┘  └──┬───┘  └───┬────┘  └──┬───┘  └──┬──┘  └──┬───┘
   │         │          │           │         │        │
   └─────────┴──────────┴───────────┴─────────┴────────┘
                         │
                ┌────────┴─────────┐
                │                  │
         ┌──────▼──────┐    ┌─────▼──────┐
         │ YoloLooper  │    │ Tokenization│
         │  (Leverage) │    │   Layer     │
         └─────────────┘    │ - USY       │
                            │ - sUSY      │
                            │ - Synthetics│
                            └─────────────┘
```

### V0 → V0.5 → V1 Evolution

| Version | Architecture | Key Features | Contract Size |
|---------|--------------|--------------|---------------|
| **V0** | Monolithic (1,591 lines) | Linear interest, basic CDPs | Single contract |
| **V0.5** | Delegatecall pattern (1,685 lines) | Compound interest, sUSY LP token | Hook + delegated logic |
| **V1** | Externally linked libraries (<500 lines each) | Full modularity, YoloLooper, optimized gas | Modular libraries |

**Key V1 Improvements:**
1. **Gas Efficiency**: Externally linked libraries eliminate ~2,500 gas overhead per call vs delegatecall
2. **Contract Size**: Modular design keeps each component under 500 lines (YoloHook: 24,182 bytes, under 24,576 limit)
3. **Maintainability**: Single-responsibility modules easier to audit and upgrade
4. **Security**: Type-safe library calls vs runtime delegatecall risks

### Module-Based Design Philosophy

YOLO V1 uses **Aave-style externally linked libraries** for maximum efficiency:

```solidity
// ❌ V0.5 pattern (EXPENSIVE - delegatecall overhead)
contract YoloHook {
    function addLiquidity(...) external {
        (bool success,) = anchorPoolLogic.delegatecall(
            abi.encodeWithSignature("addLiquidity(...)")
        ); // ~2,500 gas overhead!
    }
}

// ✅ V1 pattern (GAS EFFICIENT - direct library calls)
library StablecoinModule {
    function addLiquidity(AppStorage storage s, ...) external { ... }
}

contract YoloHook {
    using StablecoinModule for AppStorage;
    AppStorage internal s;

    function addLiquidity(...) external {
        s.addLiquidity(...); // Direct call - much cheaper!
    }
}
```

**Benefits:**
- 📉 Lower gas costs (~2,500 gas saved per external call)
- 🔒 Type safety at compile-time
- 🧩 Each library deployed once, linked at deployment
- 📦 Smaller main contract (stays under 24KB EIP-170 limit)

---

## Core Components 🔧

### 5.1 YoloHook (Main Entry Point)

**Location**: `src/core/YoloHook.sol`

**Purpose**: Central orchestrator for all protocol operations, implementing Uniswap V4 Hook interface.

**Key Responsibilities:**
- Uniswap V4 lifecycle hooks (`beforeSwap`, `afterSwap`, `beforeInitialize`, etc.)
- Access control enforcement via ACLManager
- Module coordination (delegates to specialized libraries)
- Emergency pause mechanism
- UUPS upgradeable proxy pattern

**Key Functions:**

```solidity
// Initialization
function initialize(
    IYoloOracle _yoloOracle,
    address _usdc,
    address _usyImplementation,
    address _sUSYImplementation,
    address _ylpVaultImplementation
) external initializer;

// Emergency Controls
function pause(bool _toPause) external onlyPauser;

// Hook Lifecycle (Uniswap V4)
function beforeSwap(...) external override returns (bytes4, BeforeSwapDelta, uint24);
function afterSwap(...) external override returns (bytes4, int128);
```

**Contract Stats:**
- Size: 24,182 bytes (394 bytes under EIP-170 limit after optimization)
- Functions: 75 total (externals, views, admin)
- Modifiers: `whenNotPaused`, `nonReentrant`, `onlyRole`

---

### 5.2 Module Library Architecture

All modules are **externally linked libraries** that operate on `AppStorage` (defined in `YoloHookStorage.sol`).

#### 5.2.1 StablecoinModule

**Location**: `src/libraries/StablecoinModule.sol`

**Purpose**: Manages YOLO USD (USY) stablecoin with Curve-style Stable Swap AMM for the USY↔USDC anchor pool.

**Key Functions:**

```solidity
// Mint USY via balanced deposit
function mintUSY(
    AppStorage storage s,
    uint256 maxUsyAmount,
    uint256 maxUsdcAmount,
    uint256 minLiquidityReceived,
    address receiver
) external returns (uint256 usyMinted, uint256 usdcUsed);

// Burn USY to redeem underlying
function burnUSY(
    AppStorage storage s,
    uint256 usyAmount,
    uint256 minUsdcOut,
    address receiver
) external returns (uint256 usdcOut);

// AMM Swaps
function swapUSDCForUSY(...) external returns (uint256 usyOut);
function swapUSYForUSDC(...) external returns (uint256 usdcOut);
```

**AMM Math**: Uses Curve Stable Swap invariant `x³y + xy³ = k` (see `StableMath.sol`)

**Key Features:**
- Low slippage for stablecoin swaps
- Balanced deposit requirement for minting
- Integration with sUSY LP token

---

#### 5.2.2 SyntheticAssetModule

**Location**: `src/libraries/SyntheticAssetModule.sol`

**Purpose**: On-demand creation and lifecycle management of synthetic assets (yNVDA, yTSLA, yGOLD, etc.).

**Key Functions:**

```solidity
// Create new synthetic asset
function createSyntheticAsset(
    AppStorage storage s,
    string calldata name,
    string calldata symbol,
    address syntheticImplementation
) external returns (address syntheticAsset);

// Lifecycle management
function deactivateSyntheticAsset(AppStorage storage s, address syntheticToken) external;
function reactivateSyntheticAsset(AppStorage storage s, address syntheticToken) external;
function updateMaxSupply(AppStorage storage s, address syntheticToken, uint256 newMaxSupply) external;
```

**Key Features:**
- UUPS upgradeable synthetic tokens
- Oracle-based pricing (integrates with YoloOracle)
- Treasury integration for interest collection
- Max supply caps for risk management

---

#### 5.2.3 LendingPairModule

**Location**: `src/libraries/LendingPairModule.sol`

**Purpose**: CDP (Collateralized Debt Position) operations with Aave-style compound interest.

**Key Functions:**

```solidity
// Open/increase leveraged position
function borrowSyntheticAsset(
    AppStorage storage s,
    address yoloAsset,
    uint256 borrowAmount,
    address collateral,
    uint256 collateralAmount,
    address onBehalfOf
) external;

// Close/reduce position
function repaySyntheticAsset(
    AppStorage storage s,
    address collateral,
    address yoloAsset,
    uint256 repayAmount,
    bool autoClaimOnFullRepayment,
    address onBehalfOf
) external;

// Collateral management
function depositCollateral(...) external;
function withdrawCollateral(...) external;

// Configuration (admin only)
function configureLendingPair(
    AppStorage storage s,
    address syntheticAsset,
    address collateralAsset,
    uint256 ltv,
    uint256 liquidationThreshold,
    uint256 liquidationBonus,
    uint256 borrowRate,
    uint256 minimumBorrowAmount
) external returns (bytes32 pairId);
```

**Interest Model:**
- **Compound Interest**: RAY precision (27 decimals) for accuracy
- **Formula**: `actualDebt = normalizedDebt × liquidityIndex / RAY`
- **Rate Accrual**: `newIndex = oldIndex × (1 + rate × timeDelta)`

**Key Parameters:**
- **LTV (Loan-to-Value)**: Max borrowing power (e.g., 75% = borrow up to 75% of collateral value)
- **Liquidation Threshold**: Health factor trigger (e.g., 80% = liquidated if debt exceeds 80% of collateral)
- **Liquidation Bonus**: Reward for liquidators (e.g., 5% discount on collateral)

**onBehalfOf Pattern:**
- User can borrow/repay for themselves (onBehalfOf = msg.sender)
- Loopers with LOOPER_ROLE can act on behalf of users (for flash loan leverage)

---

#### 5.2.4 LiquidationModule

**Location**: `src/libraries/LiquidationModule.sol`

**Purpose**: Liquidate undercollateralized positions to protect protocol solvency.

**Key Functions:**

```solidity
function liquidatePosition(
    AppStorage storage s,
    address user,
    address collateral,
    address yoloAsset,
    uint256 debtToCover
) external returns (uint256 collateralSeized);
```

**Liquidation Mechanics:**

1. **Health Factor Check**: `healthFactor = (collateralValue × liquidationThreshold) / debtValue`
   - If `healthFactor < 1.0`, position is liquidatable

2. **Liquidation Process**:
   - Liquidator repays user's debt (up to `debtToCover`)
   - Receives collateral worth `debtValue × (1 + liquidationBonus)`
   - Example: Repay $1000 debt, receive $1050 worth of collateral (5% bonus)

3. **Partial vs Full Liquidation**:
   - Partial: Liquidate just enough to restore health
   - Full: Liquidate entire position if severely underwater

**Key Features:**
- Oracle-based pricing for accurate valuation
- Liquidation bonus incentivizes keepers
- Prevents bad debt accumulation

---

#### 5.2.5 FlashLoanModule

**Location**: `src/libraries/FlashLoanModule.sol`

**Purpose**: EIP-3156 compliant flash loans with privileged paths for capital efficiency.

**Key Functions:**

```solidity
// Standard flash loan (with fee)
function flashLoan(
    AppStorage storage s,
    address caller,
    address borrower,
    address token,
    uint256 amount,
    bytes calldata data
) external returns (bool success, uint256 fee);

// Batch flash loans
function flashLoanBatch(
    AppStorage storage s,
    address caller,
    address borrower,
    address[] calldata tokens,
    uint256[] calldata amounts,
    bytes calldata data
) external returns (bool success, uint256[] memory fees);
```

**Special Features:**

1. **Privileged Flash Loans** (zero fee):
   - Contracts with `PRIVILEGED_FLASHLOANER_ROLE` pay no fees
   - Used by YoloLooper for leverage operations
   - No reentrancy guard (trust-based for efficiency)

2. **Standard Flash Loans**:
   - Default fee: 0.09% (9 basis points)
   - Reentrancy protection via `nonReentrant`

3. **EIP-3156 Compliance**:
   - `maxFlashLoan()` - Query max borrowable amount
   - `flashFee()` - Query fee for amount
   - Borrower must implement `onFlashLoan()` callback

**Use Cases:**
- Arbitrage (standard path)
- Liquidations (standard path)
- Leverage via YoloLooper (privileged path)

---

#### 5.2.6 SwapModule

**Location**: `src/libraries/SwapModule.sol`

**Purpose**: Handle USY↔USDC swaps in the anchor pool via Uniswap V4 hooks.

**Hook Integration:**

```solidity
function beforeSwap(...) external returns (...);
function afterSwap(...) external returns (...);
```

**Features:**
- Integrates with StablecoinModule for AMM logic
- Handles Uniswap V4 delta accounting
- Supports both exact input and exact output swaps

---

#### 5.2.7 SyntheticSwapModule

**Location**: `src/libraries/SyntheticSwapModule.sol`

**Purpose**: Enable swaps between synthetic assets using USY as intermediary.

**Swap Flow:**
```
yNVDA → USY → yTSLA
  ↓       ↓       ↓
Burn   Anchor  Mint
       Pool
```

**Key Features:**
- No direct liquidity pool needed between synthetics
- Leverages anchor pool liquidity
- Oracle-based pricing for fair execution

---

#### 5.2.8 BootstrapModule

**Location**: `src/libraries/BootstrapModule.sol`

**Purpose**: One-time initialization of the USY↔USDC anchor pool.

**Key Function:**

```solidity
function bootstrapAnchorPool(
    AppStorage storage s,
    uint256 initialUsyAmount,
    uint256 initialUsdcAmount
) external;
```

**Called during**: Initial protocol setup after deployment

---

### 5.3 YoloLooper (Leverage Engine)

**Location**: `src/looper/YoloLooper.sol`

**Purpose**: Flash loan-powered leverage and deleverage operations for capital-efficient trading.

**Key Functions:**

```solidity
// Open leveraged position (up to 20x)
function leverage(
    address collateral,
    address syntheticAsset,
    uint256 initialCollateral,
    uint256 targetLeverage, // 18 decimals (2e18 = 2x, 3e18 = 3x)
    uint256 minSyntheticReceived
) external;

// Close or reduce leverage
function deleverage(
    address collateral,
    address syntheticAsset,
    uint256 repayAmount, // 0 = full deleverage
    uint256 minCollateralFreed
) external;
```

**Leverage Flow (3x Example):**

```
1. User deposits 5,000 PT-USDe
2. YoloLooper flash loans 10,000 yNVDA
3. Swap yNVDA → USDC → PT-USDe (via external router)
4. Deposit PT-USDe + borrow yNVDA (on user's behalf)
5. Repay flash loan with borrowed yNVDA
6. Result: User has 15,000 PT-USDe position with 10,000 yNVDA debt (3x leverage)
```

**Deleverage Flow (Full Exit):**

```
1. YoloLooper flash loans yNVDA (to repay debt)
2. Repay user's debt → frees collateral
3. Withdraw minimum collateral needed
4. Swap collateral → USDC → yNVDA
5. Repay flash loan
6. Refund excess synthetic to user
7. Withdraw ALL remaining collateral to user
```

**Advanced Features:**

1. **Slippage Protection**:
   - `minSyntheticReceived` for leverage
   - `minCollateralFreed` for deleverage
   - Reverts if slippage exceeds tolerance

2. **Excess Synthetic Refund** (NEW in V1):
   - 2% swap buffer for safety
   - Excess refunded to user instead of stuck in contract
   - Ensures ~100% value recovery

3. **Auto-Claim Control**:
   - `autoClaimOnFullRepayment` parameter
   - Looper sets to `false` to manage collateral flow
   - Normal users set to `true` for convenience

4. **External Router Integration**:
   - Pluggable swap router (e.g., 1inch, Uniswap)
   - Handles non-USY collateral swaps

**Security:**
- Requires `LOOPER_ROLE` for onBehalfOf operations
- EIP-3156 flash borrower pattern
- Slippage protection on all swaps

---

### 5.4 Tokenization Layer

#### 5.4.1 YoloSyntheticAsset

**Location**: `src/tokenization/YoloSyntheticAsset.sol`

**Base**: `MintableIncentivizedERC20Upgradeable` (Aave-inspired)

**Key Features:**
- ERC20Upgradeable with ERC20Permit (gasless approvals)
- Hook-controlled minting/burning (only YoloHook can mint)
- Treasury integration for interest collection
- Incentives controller support (for future reward distribution)

**Example Synthetics:**
- yNVDA (Nvidia stock)
- yTSLA (Tesla stock)
- yGOLD (Gold commodity)
- yJPY, yKRW, yEUR (Foreign currencies)

---

#### 5.4.2 StakedYoloUSD (sUSY)

**Location**: `src/tokenization/StakedYoloUSD.sol`

**Purpose**: LP receipt token for USY↔USDC anchor pool.

**Key Features:**
- ERC20Upgradeable with ERC20Permit
- Value accrual: sUSY appreciates as reserves grow from fees + interest
- Hook-only minting/burning
- Redeemable for proportional share of anchor pool

**Value Formula:**
```solidity
sUSYValue = (reserveUSY + reserveUSDC) × (userSUSY / totalSUSY)
```

**Yield Sources:**
1. Swap fees from anchor pool
2. Interest paid by borrowers
3. Liquidation bonuses

---

#### 5.4.3 MintableIncentivizedERC20Upgradeable

**Location**: `src/tokenization/base/MintableIncentivizedERC20Upgradeable.sol`

**Purpose**: Base contract for all YOLO tokens with Aave-style incentives integration.

**Key Features:**
- Hooks into incentives controller on transfer/mint/burn
- Upgradeable via UUPS
- Access-controlled minting
- ERC20Permit support

---

### 5.5 Oracle System

#### 5.5.1 YoloOracle

**Location**: `src/core/YoloOracle.sol`

**Purpose**: Aggregates price feeds for all assets (collateral + synthetics), inspired by Aave Oracle.

**Key Functions:**

```solidity
function getAssetPrice(address asset) external view returns (uint256);
function setAssetSource(address asset, address source) external;
```

**Integration:**
- Chainlink price feeds (primary)
- Fallback mechanisms for redundancy
- 18-decimal normalized prices

**Security:**
- Price staleness checks
- Circuit breakers for extreme deviations
- Admin-only source updates

---

### 5.6 Access Control

#### 5.6.1 ACLManager

**Location**: `src/access/ACLManager.sol`

**Pattern**: Aave V3 role-based access control

**Key Roles:**

| Role | Description | Functions |
|------|-------------|-----------|
| `DEFAULT_ADMIN_ROLE` | Super admin (grant/revoke roles) | All admin functions |
| `ASSETS_ADMIN` | Create and manage synthetic assets | `createSyntheticAsset()`, `deactivate()` |
| `RISK_ADMIN` | Update risk parameters | `updateRiskParameters()`, `updateBorrowRate()` |
| `PAUSER` | Emergency pause protocol | `pause(true/false)` |
| `LOOPER_ROLE` | Privileged contracts for leverage | `borrow()/repay()` with `onBehalfOf` |
| `PRIVILEGED_FLASHLOANER_ROLE` | Zero-fee flash loans | YoloLooper |

**Usage:**

```solidity
// Check role
if (!ACL_MANAGER.hasRole(PAUSER, msg.sender)) revert Unauthorized();

// Grant role (only admin)
ACL_MANAGER.grantRole(LOOPER_ROLE, address(yoloLooper));
```

---

## User Workflows 👤

### 6.1 Liquidity Provider Journey

**Goal**: Earn yield by providing liquidity to the USY↔USDC anchor pool.

```solidity
// 1. Approve tokens
USY.approve(address(yoloHook), maxUsyAmount);
USDC.approve(address(yoloHook), maxUsdcAmount);

// 2. Add liquidity → receive sUSY
(uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted) = yoloHook.addLiquidity(
    10_000e18,  // maxUsyAmount
    10_000e6,   // maxUsdcAmount (USDC has 6 decimals)
    9_500e18,   // minSUSYReceive (5% slippage tolerance)
    msg.sender  // receiver
);

// 3. Hold sUSY and earn from:
//    - Swap fees (0.3% default)
//    - Interest paid by borrowers
//    - Liquidation bonuses

// 4. Remove liquidity when ready
sUSY.approve(address(yoloHook), sUSYAmount);
(uint256 usyOut, uint256 usdcOut) = yoloHook.removeLiquidity(
    1_000e18,   // sUSYAmount to burn
    950e18,     // minUsyOut
    950e6,      // minUsdcOut
    msg.sender  // receiver
);
```

**Expected Returns:**
- Base APY: ~5-15% (from swap fees + interest)
- Boosted APY: Up to 30%+ during high utilization periods

---

### 6.2 Borrower Journey

**Goal**: Collateralize yield-bearing tokens to borrow synthetic assets.

```solidity
// 1. Approve collateral
PT_USDE.approve(address(yoloHook), collateralAmount);

// 2. Borrow synthetic (opens CDP)
yoloHook.borrow(
    address(yNVDA),      // synthetic to borrow
    1_000e18,            // borrowAmount (1000 yNVDA)
    address(PT_USDE),    // collateral
    2_000e18,            // collateralAmount (2000 PT-USDe)
    msg.sender           // onBehalfOf (self)
);
// → Now have 1000 yNVDA debt, 2000 PT-USDe locked
// → Health factor: ~1.5 (safe, assuming 75% LTV)

// 3. Interest accrues over time (compound interest)
// After 30 days @ 10% APR:
// actualDebt = 1000 × (1 + 0.10 × 30/365) ≈ 1008.2 yNVDA

// 4. Repay debt (partial or full)
yNVDA.approve(address(yoloHook), repayAmount);
yoloHook.repay(
    address(yNVDA),      // synthetic to repay
    address(PT_USDE),    // collateral
    1_010e18,            // repayAmount (full repayment + buffer)
    true,                // autoClaimOnFullRepayment
    msg.sender           // onBehalfOf (self)
);
// → Debt cleared, 2000 PT-USDe returned automatically
```

**Key Concepts:**
- **LTV (Loan-to-Value)**: Borrowing power (e.g., 75% = can borrow up to 75% of collateral value)
- **Health Factor**: Safety metric (`collateralValue × liquidationThreshold / debtValue`)
  - HF > 1.0: Safe
  - HF < 1.0: Liquidatable
- **Interest**: Accrues every second, compounds continuously

---

### 6.3 Leverage Trader Journey

**Goal**: Amplify exposure to yield-bearing tokens using YoloLooper.

```solidity
// 1. Approve initial collateral to YoloLooper
PT_USDE.approve(address(yoloLooper), 5_000e18);

// 2. Open 3x leveraged position
yoloLooper.leverage(
    address(PT_USDE),    // collateral
    address(yNVDA),      // synthetic to borrow
    5_000e18,            // initialCollateral
    3e18,                // targetLeverage (3x, in 18 decimals)
    0                    // minSyntheticReceived (no slippage check for example)
);
// → Behind the scenes:
//   - Flash loan 10,000 yNVDA
//   - Swap to 10,000 PT-USDe
//   - Deposit 15,000 PT-USDe, borrow 10,000 yNVDA
//   - Repay flash loan
// → Result: 15,000 PT-USDe collateral, 10,000 yNVDA debt (3x leverage)

// 3. Monitor position health
DataTypes.UserPosition memory position = yoloHook.getUserPosition(
    msg.sender,
    address(PT_USDE),
    address(yNVDA)
);
// position.collateralSuppliedAmount: 15,000e18
// position.normalizedDebtRay: ~10,000 (in RAY precision)

// 4. Deleverage partially or fully
yoloLooper.deleverage(
    address(PT_USDE),    // collateral
    address(yNVDA),      // synthetic
    5_000e18,            // repayAmount (partial deleverage)
    0                    // minCollateralFreed
);
// → Reduces debt by 5,000 yNVDA, frees ~5,000 PT-USDe

// 5. Full exit (repayAmount = 0)
yoloLooper.deleverage(
    address(PT_USDE),
    address(yNVDA),
    0,                   // 0 = full repayment
    0
);
// → Repays all debt, returns all collateral + excess synthetic
```

**Leverage Amplification:**
- 1x: Normal holding (no borrowing)
- 2x: 2× exposure (borrow = initial capital)
- 3x: 3× exposure (borrow = 2× initial capital)
- ...
- 20x: Maximum (extreme risk, tight liquidation margin)

**Risk Warning:**
- Higher leverage = higher liquidation risk
- Price drops can quickly trigger liquidations
- Interest accrues on debt, increasing liquidation risk over time

---

### 6.4 Arbitrageur Journey

**Goal**: Exploit price discrepancies using flash loans.

```solidity
// Implement ERC3156FlashBorrower
contract MyArbitrageur is IERC3156FlashBorrower {
    function executeArbitrage() external {
        // 1. Request flash loan
        yoloHook.flashLoan(
            address(this),   // borrower (receives callback)
            address(USY),    // token
            1_000_000e18,    // amount (1M USY)
            abi.encode(...)  // data for callback
        );
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        // 2. Execute arbitrage logic
        // Example: Buy USY cheap on DEX A, sell expensive on DEX B

        // 3. Ensure profit covers fee
        require(profit > fee, "Unprofitable");

        // 4. Approve repayment
        IERC20(token).approve(msg.sender, amount + fee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
```

**Common Arbitrage Strategies:**
1. **USY Peg Arbitrage**: USY trading off-peg on external DEXs
2. **Synthetic Mispricing**: Oracle delays create temporary price differences
3. **Liquidation Opportunities**: Front-run liquidations with flash loans

---

## Development Guide 💻

### 7.1 Prerequisites

**Required:**
- [Foundry](https://getfoundry.sh/) (latest stable)
- [Node.js](https://nodejs.org/) v18+ and [pnpm](https://pnpm.io/)
- [Git](https://git-scm.com/)

**Optional:**
- VSCode with [Solidity extension](https://marketplace.visualstudio.com/items?itemName=JuanBlanco.solidity)
- [Slither](https://github.com/crytic/slither) for static analysis

### 7.2 Installation

```bash
# Clone repository
git clone https://github.com/YOLO-Protocol/yolo-core-v1.git
cd yolo-core-v1

# Install Solidity dependencies (Foundry)
forge install

# Install Node dependencies (for scripting/linting)
pnpm install
```

### 7.3 Build Commands

**Standard Build (1M optimizer runs):**
```bash
pnpm build
# Equivalent to: forge build --optimize --optimizer-runs 1000000
```

**Build Profiles** (see `foundry.toml`):

```bash
# Test profile (200 runs, faster compilation)
FOUNDRY_PROFILE=test forge build

# Production profile (2M runs, metadata included)
FOUNDRY_PROFILE=production forge build

# Coverage profile (no optimization)
FOUNDRY_PROFILE=coverage forge build
```

**Check Contract Sizes:**
```bash
forge build --sizes
```

**⚠️ CRITICAL: Always run `forge fmt` before committing!**
```bash
forge fmt
# GitHub Actions will reject PRs with unformatted code
```

### 7.4 Testing

**Run All Tests:**
```bash
pnpm test
# Runs: forge test
```

**Verbose Output:**
```bash
pnpm test:verbose
# Runs: forge test -vvv
# Shows: logs, traces, gas usage
```

**Gas Reporting:**
```bash
pnpm test:gas
# Runs: forge test --gas-report
```

**Coverage:**
```bash
pnpm coverage
# Generates: lcov.info and HTML report
```

**Specific Tests:**
```bash
# Match test contract
forge test --match-contract TestAction09_YoloLooperLeverage

# Match test function
forge test --match-test test_Action09_Case03_fullDeleverage

# Match path
forge test --match-path test/TestAction04*.sol

# Combine filters
forge test --match-contract TestAction09 --match-test leverage -vvv
```

**Fuzz Testing:**
```solidity
// Configured in foundry.toml: 1000 runs per fuzz test
function testFuzz_SwapRatio(uint256 amount) public {
    amount = bound(amount, 1e6, 1_000_000e18);
    // ... test logic
}
```

### 7.5 Contract Size Management

**EIP-170 Limit:** 24,576 bytes (24KB)

**Current Sizes (after optimization):**
- YoloHook: 24,182 bytes (394 bytes under limit) ✅
- YoloLooper: 7,726 bytes

**Optimization Strategies Used:**
1. Helper functions (`_requireLooperOrSelf`, `_pairId`)
2. External libraries (Aave pattern)
3. Minimal modifiers
4. Event optimization

**Check Sizes:**
```bash
forge build --sizes | grep YoloHook
```

---

## Testing Architecture 🧪

### 8.1 Test Structure

**Test Hierarchy:**

```
test/
├── base/
│   ├── Base01_InitializeFoundryEnvironment.t.sol   # Fork setup
│   ├── Base02_DeployProtocol.t.sol                 # Core deployment
│   └── Base03_DeployComprehensiveTestEnvironment.t.sol  # Full env
├── TestAction*.t.sol                               # Feature tests
│   ├── TestAction01_AddRemoveLiquidity.t.sol
│   ├── TestAction04_InterestAccrualAndDebtLifecycle.t.sol
│   ├── TestAction09_YoloLooperLeverage.t.sol       # Leverage tests
│   └── ...
└── TestContract*.t.sol                             # Unit tests
    ├── TestContract05_StakedYoloUSD.t.sol
    └── ...
```

**Base Contracts:**
- `Base01`: Fork config, chain IDs, gas settings
- `Base02`: Deploy YoloHook, Oracle, ACLManager
- `Base03`: Deploy full ecosystem (mocks, tokens, pairs)

### 8.2 Key Test Suites

#### TestAction04: Interest Accrual & Debt Lifecycle

**Location**: `test/TestAction04_InterestAccrualAndDebtLifecycle.t.sol`

**Coverage:**
- Compound interest calculations
- Debt accrual over time
- Partial vs full repayment
- Auto-claim on full repayment
- Treasury interest collection

**Key Tests:**
```solidity
test_Action04_Case01_InterestAccrualOverTime()
test_Action04_Case02_PartialRepayment()
test_Action04_Case03_FullRepaymentAutoClaim()
```

---

#### TestAction09: YoloLooper Leverage Operations

**Location**: `test/TestAction09_YoloLooperLeverage.t.sol`

**Coverage:**
- Leverage (1x to 20x)
- Partial deleverage
- Full deleverage with value recovery
- Slippage protection
- Excess synthetic refund

**Key Tests:**

```solidity
// Case 1: Basic 2x leverage
test_Action09_Case01_basicLeverage()

// Case 2: Partial deleverage
test_Action09_Case02_partialDeleverage()

// Case 3: Full deleverage (complex flow)
test_Action09_Case03_fullDeleverage()
  - Verifies debt = 0
  - Verifies collateral = 0 in position
  - Verifies ~100% USD value recovery (collateral + synthetic)

// Case 4: Slippage protection
test_Action09_Case04_leverageSlippageProtection()

// Case 5: Deleverage slippage
test_Action09_Case05_deleverageSlippageProtection()

// Case 6: Extreme leverage (20x)
test_Action09_Case06_extremeLeverage()
```

**Testing Philosophy:**
- Use oracle prices for value comparisons
- Check total USD value recovery (not just token amounts)
- Test edge cases (full deleverage, max leverage, slippage)

---

#### TestContract05: StakedYoloUSD (sUSY)

**Location**: `test/TestContract05_StakedYoloUSD.t.sol`

**Coverage:**
- LP token minting/burning
- Value accrual mechanics
- Hook-only access control
- Transfer mechanics

---

### 8.3 Test Coverage

**Current Coverage:**
- **335 tests passing** ✅
- **Target**: >90% line coverage for production
- **Critical Paths**: 100% coverage (liquidations, flash loans, leverage)

**Generate Coverage Report:**
```bash
pnpm coverage
# Opens: coverage/index.html
```

**Coverage Gaps (if any):**
- Edge cases in extreme market conditions
- Multi-asset flash loan batches (rarely used)

---

## Security 🔒

### 9.1 Access Control

**Role-Based Security (ACLManager):**

```solidity
// Example: Only ASSETS_ADMIN can create synthetics
modifier onlyAssetsAdmin() {
    if (!ACL_MANAGER.hasRole(ASSETS_ADMIN, msg.sender)) {
        revert YoloHook__CallerNotAuthorized();
    }
    _;
}

// Example: Looper-only operations
function _requireLooperOrSelf(address onBehalfOf) private view {
    if (onBehalfOf != msg.sender) {
        if (!ACL_MANAGER.hasRole(LOOPER_ROLE, msg.sender)) {
            revert YoloHook__CallerNotAuthorized();
        }
    }
}
```

**onBehalfOf Pattern:**
- Users can only act on their own behalf
- Contracts with LOOPER_ROLE can act for others (for flash loan leverage)
- Prevents unauthorized debt creation

---

### 9.2 Reentrancy Protection

**Standard Path** (for untrusted callers):
```solidity
function flashLoan(...) external whenNotPaused nonReentrant {
    // ReentrancyGuard prevents reentrancy attacks
}
```

**Privileged Path** (for trusted loopers):
```solidity
function leverageFlashLoan(...) external onlyLooper {
    // NO nonReentrant - trust LOOPER_ROLE contracts
    // Saves ~2,500 gas per call
}
```

**Why Two Paths?**
- Standard: Protect against malicious borrowers
- Privileged: Trust vetted looper contracts for efficiency

---

### 9.3 Oracle Security

**Price Validation:**
```solidity
uint256 price = yoloOracle.getAssetPrice(asset);
require(price > 0, "Invalid price");
require(price < MAX_SANE_PRICE, "Price too high");
```

**Staleness Checks:**
- Chainlink answers have timestamps
- Reject prices older than heartbeat (e.g., 1 hour)

**Circuit Breakers:**
- Pause mechanism for oracle failures
- Admin can update oracle sources

---

### 9.4 Pause Mechanism

**Emergency Pause:**
```solidity
function pause(bool _toPause) external onlyPauser {
    s._paused = _toPause;
    emit _toPause ? Paused(msg.sender) : Unpaused(msg.sender);
}
```

**Behavior When Paused:**
- ❌ User-facing functions revert (`whenNotPaused` modifier)
- ✅ Admin functions remain active (for emergency fixes)
- ✅ View functions remain active (for monitoring)

**Paused Functions:**
- `borrow()`, `repay()`, `addLiquidity()`, `removeLiquidity()`
- `flashLoan()`, `leverage()`, `deleverage()`
- Swap hooks (`beforeSwap`, `afterSwap`)

**Always Active:**
- `pause()` itself (to unpause)
- Admin config functions
- View functions (`getPositionDebt()`, etc.)

---

### 9.5 Upgrade Safety

**UUPS Proxy Pattern:**
- Implementation can be upgraded by admin
- Storage layout preserved via `YoloHookStorage`
- `_disableInitializers()` prevents implementation misuse

**Upgrade Process:**
1. Deploy new implementation
2. Call `upgradeToAndCall()` on proxy (admin only)
3. Run migration logic if needed

---

## Gas Optimizations ⛽

### 10.1 Library Linking

**Externally Linked Libraries** (Aave pattern):

```solidity
// Deployed once, linked at deployment
library StablecoinModule { ... }

// YoloHook references library code
contract YoloHook {
    using StablecoinModule for AppStorage;
}
```

**Gas Savings vs Delegatecall:**
- ~2,500 gas per call (no delegatecall overhead)
- Smaller main contract (reduced deployment cost)

---

### 10.2 Storage Layout

**Struct Packing** (in `YoloHookStorage.sol`):

```solidity
struct UserPosition {
    uint256 collateralSuppliedAmount;  // 32 bytes
    uint256 normalizedDebtRay;          // 32 bytes (RAY precision)
    uint256 storedInterestRate;         // 32 bytes
}
// Total: 96 bytes (3 storage slots)
```

**AppStorage Pattern:**
- Single storage struct for all state
- Enables library-based modular design
- Clean upgrade path

---

### 10.3 Recent Optimizations

**1. `_requireLooperOrSelf()` Helper** (~210 bytes saved):

```solidity
// Before: 4 instances × 70 bytes = 280 bytes
if (onBehalfOf != msg.sender) {
    if (!ACL_MANAGER.hasRole(LOOPER_ROLE, msg.sender)) {
        revert YoloHook__CallerNotAuthorized();
    }
}

// After: 1 function (30 bytes) + 4 calls (10 bytes each) = 70 bytes
_requireLooperOrSelf(onBehalfOf);
```

**2. `_pairId()` Helper** (~130 bytes saved):

```solidity
// Before: 4 instances × 50 bytes = 200 bytes
bytes32 pairId = keccak256(abi.encodePacked(syntheticAsset, collateralAsset));

// After: 1 function (30 bytes) + 4 calls (10 bytes each) = 70 bytes
bytes32 pairId = _pairId(syntheticAsset, collateralAsset);
```

**3. Combined `pause()` Function** (~90 bytes saved):

```solidity
// Before: 2 separate functions
function pause() external { ... }
function unpause() external { ... }

// After: 1 function with parameter
function pause(bool _toPause) external onlyPauser { ... }
```

**Total Savings:** ~430 bytes (brought YoloHook from 24,770 → 24,182 bytes)

---

## Interest Rate Model 📊

### 11.1 Compound Interest

**RAY Precision** (27 decimals):
```solidity
uint256 constant RAY = 1e27;
```

**Liquidity Index Pattern** (Aave V3):

```solidity
// actualDebt = scaledDebt × liquidityIndex / RAY
uint256 actualDebt = (position.normalizedDebtRay * liquidityIndexRay) / RAY;
```

**Index Growth:**
```solidity
// newIndex = oldIndex × (1 + rate × timeDelta)
uint256 newIndex = oldIndex + (oldIndex * borrowRate * timeDelta) / RAY;
```

**Why RAY?**
- Prevents precision loss in compound interest
- Accurate to ~1e-27 (negligible for financial calculations)
- Standard in Aave, Compound V3

---

### 11.2 Rate Calculation

**Per-Pair Configuration:**

```solidity
struct PairConfiguration {
    uint256 borrowRate;           // Annual rate in RAY (e.g., 10% = 0.1e27)
    uint256 liquidityIndexRay;    // Current compound interest index
    uint256 lastUpdateTimestamp;  // Last accrual time
    // ... other fields
}
```

**Effective Rate:**
```solidity
// Time-weighted accrual
uint256 timeDelta = block.timestamp - lastUpdateTimestamp;
uint256 accruedInterest = (debt × borrowRate × timeDelta) / (RAY × SECONDS_PER_YEAR);
```

**Example:**
- Borrow 1000 USY @ 10% APR
- After 1 year: `1000 × 1.10 = 1100 USY` debt
- After 30 days: `1000 × (1 + 0.10 × 30/365) ≈ 1008.2 USY`

---

## API Reference 📚

### 12.1 IYoloHook Interface

**Location**: `src/interfaces/IYoloHook.sol`

#### Liquidity Management

```solidity
/// @notice Add liquidity to anchor pool
/// @param maxUsyAmount Maximum USY to deposit
/// @param maxUsdcAmount Maximum USDC to deposit
/// @param minSUSYReceive Minimum sUSY to receive (slippage protection)
/// @param receiver Address to receive sUSY
/// @return usyUsed Actual USY deposited
/// @return usdcUsed Actual USDC deposited
/// @return sUSYMinted sUSY LP tokens minted
function addLiquidity(
    uint256 maxUsyAmount,
    uint256 maxUsdcAmount,
    uint256 minSUSYReceive,
    address receiver
) external returns (uint256 usyUsed, uint256 usdcUsed, uint256 sUSYMinted);

/// @notice Remove liquidity from anchor pool
/// @param sUSYAmount sUSY LP tokens to burn
/// @param minUsyOut Minimum USY to receive
/// @param minUsdcOut Minimum USDC to receive
/// @param receiver Address to receive underlying
/// @return usyOut USY received
/// @return usdcOut USDC received
function removeLiquidity(
    uint256 sUSYAmount,
    uint256 minUsyOut,
    uint256 minUsdcOut,
    address receiver
) external returns (uint256 usyOut, uint256 usdcOut);
```

#### CDP Operations

```solidity
/// @notice Borrow synthetic assets against collateral
/// @param yoloAsset Synthetic asset to borrow
/// @param borrowAmount Amount to borrow (18 decimals)
/// @param collateral Collateral asset
/// @param collateralAmount Amount of collateral to deposit
/// @param onBehalfOf Address who owns the position (requires LOOPER_ROLE if != msg.sender)
function borrow(
    address yoloAsset,
    uint256 borrowAmount,
    address collateral,
    uint256 collateralAmount,
    address onBehalfOf
) external;

/// @notice Repay borrowed synthetic assets
/// @param yoloAsset Synthetic asset to repay
/// @param collateral Collateral asset
/// @param repayAmount Amount to repay (0 = full repayment)
/// @param autoClaimOnFullRepayment Whether to automatically return collateral if debt becomes 0
/// @param onBehalfOf Address whose debt to reduce (requires LOOPER_ROLE if != msg.sender)
function repay(
    address yoloAsset,
    address collateral,
    uint256 repayAmount,
    bool autoClaimOnFullRepayment,
    address onBehalfOf
) external;

/// @notice Deposit additional collateral to existing position
/// @param yoloAsset Synthetic asset
/// @param collateral Collateral asset
/// @param amount Amount to deposit
/// @param onBehalfOf Address to credit collateral to
function depositCollateral(
    address yoloAsset,
    address collateral,
    uint256 amount,
    address onBehalfOf
) external;

/// @notice Withdraw collateral from position
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
```

#### View Functions

```solidity
/// @notice Get position debt with accrued interest
/// @param user User address
/// @param collateral Collateral asset
/// @param yoloAsset Synthetic asset
/// @return Current debt amount (18 decimals)
function getPositionDebt(
    address user,
    address collateral,
    address yoloAsset
) external view returns (uint256);

/// @notice Get user position data
/// @param user User address
/// @param collateral Collateral asset
/// @param yoloAsset Synthetic asset
/// @return position User position struct
function getUserPosition(
    address user,
    address collateral,
    address yoloAsset
) external view returns (DataTypes.UserPosition memory position);

/// @notice Get pair configuration
/// @param yoloAsset Synthetic asset
/// @param collateral Collateral asset
/// @return pairConfig Pair configuration struct
function getPairConfiguration(
    address yoloAsset,
    address collateral
) external view returns (DataTypes.PairConfiguration memory pairConfig);
```

#### Flash Loans

```solidity
/// @notice Execute flash loan (EIP-3156 compliant)
/// @param borrower Address to receive the loan
/// @param token Token to borrow
/// @param amount Amount to borrow
/// @param data Arbitrary data passed to borrower
/// @return success True if flash loan succeeded
function flashLoan(
    address borrower,
    address token,
    uint256 amount,
    bytes calldata data
) external returns (bool success);

/// @notice Execute privileged flash loan for leverage operations
/// @dev Only callable by contracts with LOOPER_ROLE, no reentrancy guard
/// @param borrower Address to receive the loan (the looper)
/// @param token Token to borrow
/// @param amount Amount to borrow
/// @param data Arbitrary data passed to borrower
/// @return success True if flash loan succeeded
function leverageFlashLoan(
    address borrower,
    address token,
    uint256 amount,
    bytes calldata data
) external returns (bool success);
```

---

### 12.2 Events

```solidity
/// @notice Emitted when a new synthetic asset is created
event SyntheticAssetCreated(
    address indexed syntheticAsset,
    string name,
    string symbol
);

/// @notice Emitted when liquidity is added to anchor pool
event LiquidityAdded(
    address indexed provider,
    uint256 usyAmount,
    uint256 usdcAmount,
    uint256 sUSYMinted
);

/// @notice Emitted when liquidity is removed from anchor pool
event LiquidityRemoved(
    address indexed provider,
    uint256 sUSYBurned,
    uint256 usyAmount,
    uint256 usdcAmount
);

/// @notice Emitted when flash loan is executed
event FlashLoanExecuted(
    address indexed borrower,
    address indexed initiator,
    address[] tokens,
    uint256[] amounts,
    uint256[] fees
);

/// @notice Emitted when a position is liquidated
event PositionLiquidated(
    address indexed user,
    address indexed collateral,
    address indexed yoloAsset,
    uint256 debtCovered,
    uint256 collateralSeized,
    address liquidator
);

/// @notice Emitted when protocol is paused/unpaused
event Paused(address indexed account);
event Unpaused(address indexed account);
```

---

## Deployment 🚀

### 13.1 Deployment Scripts

**Location**: `script/` (to be created)

**Deployment Order:**

1. **ACLManager** (access control)
2. **YoloOracle** (price feeds)
3. **YoloHook Implementation** (logic contract)
4. **YoloHook Proxy** (ERC1967 proxy)
5. **Initialize Proxy** (set oracle, USDC, implementations)
6. **USY Implementation** (stablecoin logic)
7. **sUSY Implementation** (LP token logic)
8. **Deploy USY Proxy** (via YoloHook)
9. **Deploy sUSY Proxy** (via YoloHook)
10. **Bootstrap Anchor Pool** (initial USY/USDC liquidity)
11. **YoloLooper** (leverage engine)
12. **Grant Roles** (LOOPER_ROLE to YoloLooper, etc.)

**Example Script:**

```bash
forge script script/Deploy.s.sol:DeployScript \
    --rpc-url $RPC_URL \
    --private-key $PRIVATE_KEY \
    --broadcast \
    --verify \
    --etherscan-api-key $ETHERSCAN_KEY
```

---

### 13.2 Deployed Addresses

**Mainnet** (Ethereum):
- TBD

**Base Sepolia** (Testnet):
- YoloHook Proxy: `0x...`
- YoloOracle: `0x...`
- USY: `0x...`
- sUSY: `0x...`
- YoloLooper: `0x...`

*(Full deployment addresses to be updated after mainnet launch)*

---

### 13.3 Verification

**Verify Contracts on Etherscan:**

```bash
# Verify implementation
forge verify-contract \
    --chain-id 1 \
    --num-of-optimizations 1000000 \
    --compiler-version v0.8.26 \
    0x<IMPLEMENTATION_ADDRESS> \
    src/core/YoloHook.sol:YoloHook \
    --etherscan-api-key $ETHERSCAN_KEY

# Verify proxy (automatically detects UUPS)
forge verify-contract \
    --chain-id 1 \
    0x<PROXY_ADDRESS> \
    --etherscan-api-key $ETHERSCAN_KEY
```

---

## Roadmap 🗺️

### Current: V1 (Production-Ready Modular Infrastructure)

**Completed:**
- ✅ Modular library architecture (Aave-style)
- ✅ USY stablecoin with Curve AMM
- ✅ Synthetic asset creation & trading
- ✅ YoloLooper flash loan leverage (up to 20x)
- ✅ EIP-3156 flash loans with privileged paths
- ✅ Compound interest with RAY precision
- ✅ sUSY LP token with value accrual
- ✅ Access control via ACLManager
- ✅ Gas optimizations (<24KB contract size)
- ✅ Comprehensive test suite (335 tests)

---

### Future Iterations

**V1.1 - Enhanced Capital Efficiency**
- [ ] Variable interest rates based on utilization
- [ ] Isolated lending pools per collateral type
- [ ] Dynamic LTV based on collateral volatility
- [ ] Multi-collateral positions

**V1.2 - Cross-Chain Expansion**
- [ ] Chainlink CCIP integration for omni-chain synthetics
- [ ] LayerZero bridge for USY
- [ ] Multi-chain liquidity aggregation

**V1.3 - Advanced Trading Features**
- [ ] Perpetual futures via synthetic assets
- [ ] Options vaults (covered calls, cash-secured puts)
- [ ] Limit orders for synthetic swaps
- [ ] Stop-loss automation for leveraged positions

**V2.0 - Decentralized Governance**
- [ ] YOLO governance token
- [ ] DAO-controlled risk parameters
- [ ] Protocol revenue distribution
- [ ] Community-driven synthetic asset listings

---

## Contributing 🤝

### Development Workflow

**Branch Naming:**
```
feature/<feature-name>
fix/<bug-description>
refactor/<component-name>
docs/<documentation-update>
```

**Commit Conventions:**
```bash
# Format: <type>: <description>
feat: add variable interest rates
fix: resolve flash loan reentrancy issue
refactor: optimize YoloHook bytecode size
docs: update API reference for YoloLooper
test: add fuzz tests for liquidation module
```

**Pull Request Process:**
1. Fork repository
2. Create feature branch
3. Write tests (maintain >90% coverage)
4. Run `forge fmt` before committing
5. Ensure all tests pass (`pnpm test`)
6. Submit PR with clear description
7. Address review comments
8. Merge after approval

---

### Code Style

**Solidity Style Guide:**
- Follow [Solidity Style Guide](https://docs.soliditylang.org/en/latest/style-guide.html)
- Use NatSpec for all public/external functions
- Max line length: 120 characters
- Use explicit visibility modifiers

**NatSpec Requirements:**

```solidity
/// @notice Brief description of what the function does
/// @dev Additional technical details (optional)
/// @param paramName Description of parameter
/// @return returnName Description of return value
function exampleFunction(uint256 paramName) external returns (uint256 returnName) {
    // ...
}
```

**Testing Standards:**
- Unit tests for all library functions
- Integration tests for user workflows
- Fuzz tests for mathematical operations
- Gas benchmarks for optimization validation

---

## FAQ ❓

### General Questions

**Q: What's the difference between USY and synthetic assets?**

A:
- **USY (YOLO USD)**: Stablecoin pegged to USDC, backed by anchor pool reserves. Used for liquidity and as intermediary for synthetic swaps.
- **Synthetic Assets**: Non-stablecoin assets (yNVDA, yTSLA, yGOLD) that track real-world prices via oracles. Created on-demand by borrowing.

---

**Q: How does leverage work in YOLO Protocol?**

A: YoloLooper uses flash loans to amplify positions:
1. Flash loan synthetic asset
2. Swap to collateral
3. Deposit collateral + borrow synthetic (on user's behalf)
4. Repay flash loan with borrowed synthetic
5. Result: User has leveraged position without needing upfront capital

Example: 5,000 initial → 15,000 position (3x leverage)

---

**Q: What are the risks?**

A:
1. **Liquidation Risk**: Leveraged positions can be liquidated if collateral value drops
2. **Oracle Risk**: Price feed failures could cause mispricing
3. **Smart Contract Risk**: Bugs in code (mitigated by audits and testing)
4. **Interest Rate Risk**: Debt accrues interest, increasing liquidation risk over time
5. **Slippage Risk**: Large swaps may have unfavorable execution

---

**Q: How is YOLO different from Aave/Compound?**

A: YOLO focuses on:
- **Synthetic Assets**: Trade anything with oracle support (not just crypto)
- **Leverage**: Built-in flash loan leverage (no need for external protocols)
- **Uniswap Integration**: Deep liquidity access without fragmentation
- **Modular Design**: All features in one Hook (stablecoin, synthetics, leverage, flash loans)

---

**Q: Can I lose money providing liquidity (sUSY)?**

A: Potential risks for LPs:
- **Impermanent Loss**: Minimal (USY ↔ USDC both stablecoins)
- **Bad Debt Risk**: If borrowers default and liquidations fail (rare due to over-collateralization)
- **Smart Contract Risk**: Bugs could affect fund recovery

LPs earn from:
- Swap fees (default 0.3%)
- Interest paid by borrowers
- Liquidation bonuses

---

**Q: What collateral types are supported?**

A: Any ERC20 token can be whitelisted by ASSETS_ADMIN, typically:
- Yield-bearing tokens (PT-USDe, PT-sUSDe from Pendle)
- Stablecoins (USDC, USDT, DAI)
- Blue-chip crypto (WETH, WBTC)
- LSTs (wstETH, rETH)

Each collateral-synthetic pair has custom risk parameters (LTV, liquidation threshold).

---

**Q: How do I get LOOPER_ROLE?**

A: LOOPER_ROLE is granted by admin to vetted contracts only (e.g., official YoloLooper). It allows:
- Acting on behalf of users (onBehalfOf pattern)
- Zero-fee flash loans
- Bypassing reentrancy guards

Regular users don't need this role.

---

**Q: What happens if I get liquidated?**

A: Liquidation process:
1. Your health factor drops below 1.0 (collateral value too low vs debt)
2. Liquidator repays your debt (up to debtToCover)
3. Liquidator receives your collateral + liquidation bonus (e.g., 5%)
4. If partial liquidation, your position remains open with reduced debt

**Prevention**: Monitor health factor, add collateral, or repay debt before HF < 1.0

---

## Resources 📖

### Documentation

- **Architecture Diagrams**: [ARCHITECTURE-EXPLAIN.md](./ARCHITECTURE-EXPLAIN.md)
- **Technical Specs**: [MASTER-PLAN.md](./MASTER-PLAN.md)
- **Code Comments**: Extensive NatSpec in contracts

### Community

- **Discord**: [discord.gg/yolo-protocol](#) (Coming Soon)
- **Twitter**: [@YoloProtocol](#)
- **GitHub Discussions**: [github.com/YOLO-Protocol/yolo-core-v1/discussions](#)
- **Telegram**: [t.me/yolo_protocol](#)

### External References

- [Uniswap V4 Documentation](https://docs.uniswap.org/contracts/v4/overview)
- [Aave V3 Technical Paper](https://github.com/aave/aave-v3-core/blob/master/techpaper/Aave_V3_Technical_Paper.pdf) (Architecture inspiration)
- [Curve Stable Swap](https://curve.fi/files/stableswap-paper.pdf) (AMM math)
- [EIP-3156: Flash Loans](https://eips.ethereum.org/EIPS/eip-3156)
- [EIP-170: Contract Size Limit](https://eips.ethereum.org/EIPS/eip-170)

---

## License ⚖️

**BUSL-1.1** (Business Source License 1.1)

Core protocol contracts in `src/` are licensed under BUSL-1.1:
- ✅ Commercial use allowed after 2 years
- ✅ Source code viewable
- ✅ Forks allowed for testing/development
- ❌ Commercial production use restricted (until change date)

**Change Date**: 2027-01-01
**Change License**: GPL-3.0

See [LICENSE](./LICENSE) for full text.

**Exceptions:**
- Interfaces (`src/interfaces/`) - MIT License
- Libraries (`src/libraries/`) - MIT License (some exceptions)
- Test contracts (`test/`) - Unlicensed (development only)

---

## Acknowledgments 🙏

**Built With:**
- [Foundry](https://getfoundry.sh/) - Blazing fast Ethereum development framework
- [Uniswap V4](https://uniswap.org/) - Hook architecture enables our modular design
- [OpenZeppelin](https://openzeppelin.com/) - Battle-tested smart contract libraries
- [Chainlink](https://chain.link/) - Decentralized oracle network

**Inspired By:**
- **Aave V3**: Modular library architecture, compound interest model, role-based access control
- **Curve Finance**: Stable swap AMM mathematics
- **Synthetix**: Synthetic asset creation and management
- **Gearbox**: Leveraged trading concepts

**Incubators & Supporters:**
- [Uniswap V4 Hook Incubator - Cohort UHI5](https://atrium.academy/uniswap)
- [Incubase](https://incubase.xyz/) (Base × Hashed Emergence)
- Base Batch #001 Hackathon (First Prize - DeFi Track)

**Core Team:**
- Alvin Yap (@alvinyap510) - Protocol Architect
- [Co-founder Name] - [Role]

**Special Thanks:**
- The Foundry team for incredible tooling
- Uniswap Foundation for V4 Hook support
- Base team for ecosystem support
- All contributors and testers

---

## Contact & Links 🔗

- **Website**: [yolo.wtf](https://yolo.wtf) (Coming Soon)
- **Docs**: [docs.yolo.wtf](https://docs.yolo.wtf) (Coming Soon)
- **GitHub**: [github.com/YOLO-Protocol](https://github.com/YOLO-Protocol)
- **Twitter**: [@YoloProtocol](https://twitter.com/YoloProtocol)
- **Discord**: [discord.gg/yolo-protocol](#)
- **Email**: team@yolo.wtf
- **Linktree**: [linktr.ee/yolo.protocol](https://linktr.ee/yolo.protocol)

---

**Built with ❤️ by the YOLO Protocol team**

*"DeFi, but make it modular."*
