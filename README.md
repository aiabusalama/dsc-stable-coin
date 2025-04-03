# DSC - Decentralized Stable Coin

[![Solidity 0.8.19](https://img.shields.io/badge/Solidity-0.8.19-363636?logo=solidity)](https://soliditylang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FF694B.svg)](https://getfoundry.sh/)

## Core Protocol Mechanics

### Collateralization System
- **200% Minimum Collateralization** (Liquidation at 50% LTV)
- **Multi-Asset Backing**: ETH and BTC as collateral
- **Dynamic Peg Maintenance**: Algorithmic stabilization

### Liquidation Engine
- **10% Liquidation Bonus** for incentivization
- **Health Factor Monitoring**:
  ```solidity
  HealthFactor = (CollateralValue * 0.5) / DebtValue
  ```
- **Thresholds**:
  - Safe: > 1.0
  - Liquidatable: ≤ 1.0

## Advanced Features

### Oracle Integration
- Chainlink Price Feeds with 8 decimal precision
- Staleness checks via `OracleLib.sol`
- Price calculations with 18 decimal standscdization

### Security Architecture
- Reentrancy guards on all state-changing functions
- CEI (Checks-Effects-Interactions) pattern enforcement
- 100% test coverage including fuzz tests

## Technical Specifications

```mermaid
sequenceDiagram
    title DSC Protocol: Full Business Logic Flow

    %% Actors
    actor User
    actor Liquidator
    box  DSC Protocol
    participant DSCEngine
    participant DSCToken
    participant Oracle
    end

    %% 1. Deposit & Mint
    User->>DSCEngine: Deposit 2 WETH
    DSCEngine->>Oracle: Get WETH/USD price
    Oracle-->>DSCEngine: $2000 (valid)
    DSCEngine->>DSCEngine: Store 2 WETH ($4000 value)
    User->>DSCEngine: "Mint 2000 DSC ($2000)"
    DSCEngine->>DSCEngine: Verify 200% collateral (4000/2000)
    DSCEngine->>DSCToken: Mint 2000 DSC
    DSCToken-->>User: 2000 DSC

    %% 2. Price Drops
    Note over User,Oracle: WETH price drops to 1500 (user collateral now 3000)

    %% 3. Liquidation
    Liquidator->>DSCEngine: "Check 1500 price (valid)"
    DSCEngine->>DSCEngine: Health Factor = 1.5 (below 2.0)
    Liquidator->>DSCEngine: "Liquidate 1000 DSC debt"
    DSCEngine->>DSCToken: Burn 1000 DSC
    DSCEngine->>Liquidator: Send 1.1 WETH (worth 1650, 10% bonus)

    %% 4. Oracle Failure
    User->>DSCEngine: "Try to mint more DSC"
    DSCEngine->>Oracle: Get price
    Oracle--x DSCEngine: "STALE PRICE (3h old)"
    DSCEngine--x User: "Transactions frozen"
```

## Development

```bash
# Run tests
forge test -vv

# Fuzz testing
forge test --match-test invariant

# Deploy to Sepolia
make deploy ARGS="--network sepolia"
```

## License
MIT

## 🚀 Thank You!

[![LinkedIn](https://img.shields.io/badge/LinkedIn-Connect_@abusalama-0077B5?style=for-the-badge&logo=linkedin&logoColor=white)](https://www.linkedin.com/in/abusalama/)  
[![GitHub](https://img.shields.io/badge/GitHub-Follow_@abusalama-181717?style=for-the-badge&logo=github&logoColor=white)](https://github.com/aiabusalama)  
