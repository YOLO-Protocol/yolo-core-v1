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
[![Tests](https://img.shields.io/badge/Tests-465%20passing-success.svg)]()
![Solidity](https://img.shields.io/badge/solidity-0.8.26-blue)
![Version](https://img.shields.io/badge/version-1.0.0-orange)

## Table of Contents

- [YOLO Protocol V1](#yolo-protocol-v1)
  - [Table of Contents](#table-of-contents)
  - [**Introduction**](#introduction)
  - [Background](#background)
  - [Quick Start](#quick-start)
  - [Key Concepts](#key-concepts)

---

## **Introduction**

YOLO Protocol V1 is a Uniswap V4 Hook that combines a CDP stablecoin, synthetic asset issuance (stocks, commodities, crypto), leveraged trade module into a single gas-optimized protocol. By leveraging Uniswap V4's hook architecture, YOLO eliminates liquidity fragmentation while providing users with seamless access to lending, trading, and leverage through one unified interface—all secured by over-collateralized positions and real-time Pyth oracle price feeds.


## Background

GM! The team behind YOLO are longtime DeFi farmers ourselves, who are huge fans of DeFi protocols such as Aave, Synthetix, GMX, Gearbox, Pendle, Euler and others. At the same time, we are also heavy stock traders ourselves, and have always wished that there was a way for us to quickly gain exposure to stocks, commodities, indices, and currencies on-chain—without the hassle of moving our funds between DeFi and centralized brokers or CFD platforms.

YOLO is a project we always wished existed, and so we built it ourselves.
- YOLO started as a Base Batch #001 Hackathon APAC DeFi track winner
- Participated in Uniswap Hook Incubator Cohort 5, and won the largest prize pool during demo day

**Evolution**: V0 (monolithic MVP) → V0.5 (delegated logic + compound interest) → V1 (modular libraries + referral system + perpetual trading).

---

## Quick Start

```bash
# Clone the repository
git clone https://github.com/YOLO-Protocol/yolo-core-v1.git
cd yolo-core-v1

# Install dependencies
forge install && pnpm install

# Build contracts
pnpm build

# Run all tests
pnpm test

# Run tests with verbose output
pnpm test:verbose

# Run specific test contract
forge test --match-contract TestContractName

# Generate coverage report
pnpm coverage

# Check code formatting
pnpm lint
```

**Development Profiles:**
- **Default**: 200 optimizer runs (balanced for development)
- **Test**: `FOUNDRY_PROFILE=test forge test` (200 runs with verbose output)
- **Production**: `FOUNDRY_PROFILE=production forge build` (2M runs, maximum gas optimization)
- **Coverage**: `FOUNDRY_PROFILE=coverage forge coverage` (no optimization)


## Key Concepts

| Feature | Description | Use Case |
|---------|-------------|----------|
| **YOLO Hook** | The core infrastucture - Uniswap V4 Hook that combines the functionality of a CDP Stablecoin Module, Synthetic Asset Module as well as Leveraged Trading Module. | Serves as the entry point of user actions, state storage as well as callback hook by Uniswap's pool manager on swapping related to YOLO's anchor pool and synthetic pools |
| **USY** | YOLO Protocol's CDP Stablecoin - natively paired with USDC with a StableSwap AMM in Yolo Hook | Functions as the anchor liquidity for all Yolo Synthetic Assets |
| **Synthetic Assets** | Over-collateralized synthetic assets to track prices (currencies, stocks, indices, commodities, cryptos, etc.) | Directly swappable in Uniswap or our custom frontend; no liquidity needed, on-demand mint and burn |
| **sUSY** | Liquidity receipt token of USY-USDC Pool | Functions as the liquidity receipt of the anchor pool and yield-bearing version of USY. Holding sUSY also shares the protocol's borrowing revenue |
| **YLP** | Serves as the counterparty pool for all synthetic assets' price exposure (including leveraged & non-leveraged positions) | Absorbs traders' losses and pays out traders' profits. Also earns liquidated positions' seized collateral |

---