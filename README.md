# Sui DeFi Vault

DeFi primitives on Sui: share-based vault (ERC-4626 style), time-locked staking with rewards, and collateralized lending with liquidation.

## Building & Testing

```bash
sui move build
sui move test
```

## Modules

- **vault** — deposit SUI, receive shares, withdraw proportionally
- **staking** — lock tokens, earn rewards over time, compound
- **lending** — collateralized borrows (75% LTV), interest accrual, liquidation at 85%

## License

MIT with attribution — see [LICENSE](LICENSE).
