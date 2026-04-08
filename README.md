# Lending Protocol

This repository contains a Foundry-based lending protocol inspired by Aave v3.
It includes collateralized borrowing, a variable interest-rate model, oracle pricing,
and liquidation flows.

## Architecture

User -> LendingPool -> AToken / DebtToken
User -> LendingPool -> PriceOracle -> Chainlink-style price feed
User -> LendingPool -> InterestRate

## Contracts

- `src/LendingPool.sol`: Core market lifecycle for `addMarket`, `deposit`, `withdraw`,
  `borrow`, `repay`, `liquidate`, `batchLiquidate`, and health-factor checks.
- `src/PriceOracle.sol`: Owner-managed asset-to-feed registry with price reads from
  `latestRoundData()`.
- `src/InterestRate.sol`: Two-slope variable-rate model (2% base, 4% slope under 80%
  utilization, 100% slope above 80%).
- `src/AToken.sol`: ERC20 deposit receipt token minted/burned by `LendingPool`.
- `src/DebtToken.sol`: ERC20 debt accounting token minted/burned by `LendingPool`, with
  transfers disabled.
- `src/interfaces/AggregatorV3Interface.sol`: Local Chainlink-compatible feed interface.

## Build And Test

```bash
forge build
forge test
```

## Deployment (Keystore-Based, Recommended)

### Step 1: Create an encrypted keystore

```bash
cast wallet import deployer --interactive
```

Foundry prompts for a private key and password, then stores the key encrypted in
Foundry's default keystore directory.

### Step 2: Fund the wallet

Fund the keystore address with Sepolia ETH from a faucet such as Alchemy, Infura,
or Google Cloud.

### Step 3: Deploy

```bash
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --account deployer
```

Foundry prompts for the keystore password at runtime.

Using `--account` with an encrypted keystore is the recommended approach over
`--private-key` flags or `PRIVATE_KEY` environment variables, because the key is
encrypted at rest and not exposed in shell history, environment variables, or CI logs.
