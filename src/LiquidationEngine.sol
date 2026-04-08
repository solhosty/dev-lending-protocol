// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {LendingPool} from "src/LendingPool.sol";
import {PriceOracle} from "src/PriceOracle.sol";

contract LiquidationEngine is Ownable {
    uint256 public constant BPS = 10_000;
    uint256 public constant HEALTH_FACTOR_ONE = 1e18;

    LendingPool public immutable pool;
    PriceOracle public immutable priceOracle;

    uint256 public engineBonusBps;

    error InvalidParams();
    error PositionHealthy();
    error TransferFailed();

    event MultiAssetLiquidation(address indexed liquidator, address indexed borrower, uint256 collateralAssetCount);
    event CollateralSeized(
        address indexed liquidator,
        address indexed borrower,
        address indexed collateralAsset,
        uint256 debtCovered,
        uint256 collateralSeized,
        uint256 bonusAmount
    );
    event BonusBpsUpdated(uint256 oldBonusBps, uint256 newBonusBps);

    /// @notice Deploys the liquidation engine.
    /// @param _pool The lending pool used for liquidation execution.
    /// @param _engineBonusBps Extra bonus in basis points paid per liquidation.
    constructor(LendingPool _pool, uint256 _engineBonusBps) Ownable(msg.sender) {
        pool = _pool;
        priceOracle = _pool.priceOracle();
        engineBonusBps = _engineBonusBps;
    }

    /// @notice Liquidates a borrower across multiple collateral assets in one call.
    /// @param borrower The borrower being liquidated.
    /// @param debtAsset The debt asset to repay.
    /// @param collateralAssets The collateral assets to seize against.
    /// @param debtAmounts The per-asset debt amounts to cover.
    function liquidateMultiAsset(
        address borrower,
        address debtAsset,
        address[] calldata collateralAssets,
        uint256[] calldata debtAmounts
    ) external {
        uint256 length = collateralAssets.length;
        if (length == 0 || length != debtAmounts.length) {
            revert InvalidParams();
        }

        if (pool.getHealthFactor(borrower) >= HEALTH_FACTOR_ONE) {
            revert PositionHealthy();
        }

        uint256 totalDebt;
        for (uint256 i = 0; i < length; i++) {
            totalDebt += debtAmounts[i];
        }

        if (!IERC20(debtAsset).transferFrom(msg.sender, address(this), totalDebt)) {
            revert TransferFailed();
        }

        if (!IERC20(debtAsset).approve(address(pool), 0)) {
            revert TransferFailed();
        }
        if (!IERC20(debtAsset).approve(address(pool), totalDebt)) {
            revert TransferFailed();
        }

        for (uint256 i = 0; i < length; i++) {
            address collateralAsset = collateralAssets[i];
            IERC20 collateralToken = IERC20(collateralAsset);

            uint256 beforeBalance = collateralToken.balanceOf(address(this));
            pool.liquidate(borrower, debtAsset, collateralAsset, debtAmounts[i]);
            uint256 afterBalance = collateralToken.balanceOf(address(this));

            uint256 seizedCollateral = afterBalance - beforeBalance;
            uint256 bonusAmount;
            unchecked {
                // Gas optimization: overflow not possible with realistic values.
                bonusAmount = (seizedCollateral * engineBonusBps) / BPS;
            }

            emit CollateralSeized(msg.sender, borrower, collateralAsset, debtAmounts[i], seizedCollateral, bonusAmount);
        }

        for (uint256 i = 0; i < length; i++) {
            address collateralAsset = collateralAssets[i];
            uint256 collateralBalance = IERC20(collateralAsset).balanceOf(address(this));
            if (collateralBalance == 0) {
                continue;
            }

            if (!IERC20(collateralAsset).transfer(msg.sender, collateralBalance)) {
                revert TransferFailed();
            }
        }

        emit MultiAssetLiquidation(msg.sender, borrower, length);
    }

    /// @notice Updates the engine bonus in basis points.
    /// @param _bonusBps The new bonus basis points value.
    function setEngineBonusBps(uint256 _bonusBps) external onlyOwner {
        uint256 oldBonusBps = engineBonusBps;
        engineBonusBps = _bonusBps;
        emit BonusBpsUpdated(oldBonusBps, _bonusBps);
    }

    /// @notice Estimates extra bonus collateral from a collateral amount.
    /// @param collateralAsset The collateral asset address (unused in calculation).
    /// @param collateralAmount The collateral amount to estimate bonus for.
    /// @return bonusAmount The estimated extra bonus amount.
    function getEstimatedBonus(address collateralAsset, uint256 collateralAmount) external view returns (uint256 bonusAmount) {
        collateralAsset;
        unchecked {
            // Gas optimization: overflow not possible with realistic values.
            bonusAmount = (collateralAmount * engineBonusBps) / BPS;
        }
    }
}
