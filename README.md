# Lending Protocol

This repository contains a Foundry-based lending protocol inspired by Aave v3.
It includes collateralized borrowing, a variable interest-rate model, oracle pricing,
and liquidation flows.

## Architecture

User -> LendingPool -> AToken / DebtToken
User -> LendingPool -> PriceOracle -> Chainlink-style price feed
User -> LendingPool -> InterestRate

## Getting Started

Prerequisites: If you do not have Foundry installed yet, run:

```bash
curl -L https://foundry.paradigm.xyz | bash && foundryup
```

1. Clone this repository to your machine so you have the project files locally.
2. Run `git submodule update --init --recursive` to pull required submodules.
3. Run `forge install` to install any project dependencies used by Foundry.
4. Run `forge build` to compile the contracts and confirm the project builds.
5. Run `forge test` to execute the test suite and verify everything passes.

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

## LiquidationEngine

`LiquidationEngine` is a permissionless batch liquidation orchestrator for multi-asset
liquidation flows. It does not replace pool accounting; each entry delegates to
`LendingPool.liquidate()` after local checks and caps are applied.

### What It Does

- Accepts arrays for `borrowers`, `debtAssets`, `collateralAssets`, and `debtAmounts`.
- Executes multiple liquidation entries in one transaction through
  `executeLiquidations(...)`.
- Pulls debt tokens from the caller, approves `LendingPool`, delegates liquidation, and
  forwards seized collateral back to the caller.

### How It Works

1. Validates equal array lengths and per-entry non-zero addresses/amounts.
2. Reads borrower debt and collateral balances from `LendingPool`.
3. Prices debt via `PriceOracle`, enforces a minimum debt threshold, and computes a
   capped `debtToCover` so bonus-adjusted seizure cannot exceed remaining collateral.
4. Approves debt tokens and calls `LendingPool.liquidate()` for each entry.

### Key Safety Features

- Bonus cap: trims `debtToCover` when the liquidation bonus would otherwise over-seize
  borrower collateral.
- Dust defense: rejects liquidations where borrower debt value is below the default
  `$100` USD threshold (`minDebtThresholdUsd`, owner-adjustable).
- Reentrancy protection: `executeLiquidations(...)` is guarded by `ReentrancyGuard`.

### Usage

```solidity
address[] memory borrowers = new address[](2);
borrowers[0] = userA;
borrowers[1] = userB;

address[] memory debtAssets = new address[](2);
debtAssets[0] = usdc;
debtAssets[1] = dai;

address[] memory collateralAssets = new address[](2);
collateralAssets[0] = weth;
collateralAssets[1] = weth;

uint256[] memory debtAmounts = new uint256[](2);
debtAmounts[0] = 1_000e6;
debtAmounts[1] = 500e18;

liquidationEngine.executeLiquidations(borrowers, debtAssets, collateralAssets, debtAmounts);
```

## Build And Test

```bash
forge build
forge test
```

## Deployment (Keystore-Based, Recommended)

### Step 1: Set up environment variables

```bash
cp .env.example .env
# Edit .env and fill in your real values
source .env
```

Copy the example file, set your real `SEPOLIA_RPC_URL` and `ETHERSCAN_API_KEY`,
then load them into your shell with `source .env`.

### Step 2: Create an encrypted keystore

```bash
cast wallet import deployer --interactive
```

Foundry prompts for a private key and password, then stores the key encrypted in
Foundry's default keystore directory.

### Step 3: Fund the wallet

Fund the keystore address with Sepolia ETH from a faucet such as Alchemy, Infura,
or Google Cloud.

### Step 4: Deploy

```bash
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --broadcast --account deployer
```

Foundry prompts for the keystore password at runtime.

Using `--account` with an encrypted keystore is the recommended approach over
`--private-key` flags or `PRIVATE_KEY` environment variables, because the key is
encrypted at rest and not exposed in shell history, environment variables, or CI logs.
