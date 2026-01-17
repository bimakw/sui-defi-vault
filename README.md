# Sui DeFi Vault

A collection of DeFi primitives built on Sui blockchain including vaults, staking, and lending protocols.

## Tech Stack

- **Language**: Move
- **Blockchain**: Sui Network
- **Patterns**: ERC-4626 Vault, Staking Rewards, Collateralized Lending

## Modules

| Module | Description | Pattern |
|--------|-------------|---------|
| `vault` | Share-based vault for SUI deposits | ERC-4626 equivalent |
| `staking` | Time-locked staking with rewards | MasterChef-style |
| `lending` | Collateralized lending protocol | Compound-style |

## Features

### Vault
- Share-based accounting
- Deposit/withdraw SUI
- Exchange rate tracking
- Partial withdrawals

### Staking
- Time-locked staking periods
- Reward token distribution
- Compound rewards
- Multiple pools support

### Lending
- Collateralized borrowing
- Interest accrual
- Liquidation mechanism
- Health factor monitoring

## Prerequisites

```bash
# Install Sui CLI
cargo install --locked --git https://github.com/MystenLabs/sui.git --branch devnet sui
```

## Quick Start

```bash
# Clone repository
git clone https://github.com/bimakw/sui-defi-vault.git
cd sui-defi-vault

# Build
sui move build

# Test
sui move test

# Deploy
sui client publish --gas-budget 100000000
```

## Usage

### Vault Operations

```bash
# Deposit SUI (receive shares)
sui client call --package $PACKAGE --module vault --function deposit \
  --args $VAULT $COIN \
  --gas-budget 10000000

# Withdraw (burn shares, receive SUI)
sui client call --package $PACKAGE --module vault --function withdraw \
  --args $VAULT $SHARE_TOKEN \
  --gas-budget 10000000

# Partial withdrawal
sui client call --package $PACKAGE --module vault --function withdraw_partial \
  --args $VAULT $SHARE_TOKEN 500000000 \
  --gas-budget 10000000
```

### Staking Operations

```bash
# Create staking pool
sui client call --package $PACKAGE --module staking --function create_pool \
  --type-args 0x2::sui::SUI \
  --args 1000000 86400000 0x6 \
  --gas-budget 10000000

# Stake tokens
sui client call --package $PACKAGE --module staking --function stake \
  --type-args 0x2::sui::SUI \
  --args $POOL $COIN 0x6 \
  --gas-budget 10000000

# Claim rewards
sui client call --package $PACKAGE --module staking --function claim_rewards \
  --type-args 0x2::sui::SUI \
  --args $POOL $POSITION 0x6 \
  --gas-budget 10000000

# Unstake (after lock period)
sui client call --package $PACKAGE --module staking --function unstake \
  --type-args 0x2::sui::SUI \
  --args $POOL $POSITION 0x6 \
  --gas-budget 10000000
```

### Lending Operations

```bash
# Deposit to lending pool
sui client call --package $PACKAGE --module lending --function deposit \
  --args $POOL $COIN \
  --gas-budget 10000000

# Borrow with collateral (75% LTV)
sui client call --package $PACKAGE --module lending --function borrow \
  --args $POOL $COLLATERAL_COIN 750000000 0x6 \
  --gas-budget 10000000

# Repay loan
sui client call --package $PACKAGE --module lending --function repay \
  --args $POOL $LOAN_POSITION $REPAYMENT_COIN 0x6 \
  --gas-budget 10000000

# Liquidate undercollateralized position
sui client call --package $PACKAGE --module lending --function liquidate \
  --args $POOL $LOAN_POSITION $REPAYMENT_COIN 0x6 \
  --gas-budget 10000000
```

## Protocol Parameters

### Vault
| Parameter | Value |
|-----------|-------|
| Min Deposit | 0.001 SUI |
| Initial Exchange Rate | 1:1 |

### Staking
| Parameter | Value |
|-----------|-------|
| Lock Period | Configurable |
| Reward Rate | Per second (scaled 1e9) |

### Lending
| Parameter | Value |
|-----------|-------|
| Collateral Factor | 75% LTV |
| Liquidation Threshold | 85% |
| Liquidation Bonus | 5% |
| Interest Rate | 10% APY |

## Architecture

```
sui-defi-vault/
├── sources/
│   ├── vault.move      # ERC-4626 vault
│   ├── staking.move    # Staking rewards
│   └── lending.move    # Lending protocol
├── tests/
├── Move.toml
└── README.md
```

## Key Concepts

### Share-Based Accounting
```
shares = deposit_amount * total_shares / total_assets
withdrawal = shares * total_assets / total_shares
```

### Staking Rewards
```
accumulated_reward_per_share += rewards * 1e18 / total_staked
pending = user_shares * acc_reward_per_share / 1e18 - reward_debt
```

### Health Factor
```
health_factor = (collateral * liquidation_threshold) / debt
liquidatable when health_factor < 1.0
```

## Security Considerations

- Precision scaling (1e18) for reward calculations
- Time-based interest accrual
- Collateral ratio enforcement
- Liquidation incentives via bonus
- Share-based protection against donation attacks

## Testing

```bash
# Run all tests
sui move test

# Run specific module tests
sui move test vault_tests

# With verbose output
sui move test -v
```

## License

MIT License with Attribution - See [LICENSE](LICENSE)

Copyright (c) 2024 Bima Kharisma Wicaksana
