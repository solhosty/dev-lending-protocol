// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {LendingPool} from "src/LendingPool.sol";
import {PriceOracle} from "src/PriceOracle.sol";

contract LiquidationEngine is Ownable, ReentrancyGuard {
    uint256 public constant BPS = 10_000;

    LendingPool public immutable pool;
    PriceOracle public immutable priceOracle;

    uint256 public minDebtThresholdUsd;
    bool public paused;

    event LiquidationExecuted(
        address indexed liquidator,
        address indexed borrower,
        address indexed debtAsset,
        address collateralAsset,
        uint256 debtCovered,
        uint256 collateralSeized
    );
    event MinDebtThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    event PauseUpdated(bool paused);

    constructor(address pool_, address priceOracle_) Ownable(msg.sender) {
        require(pool_ != address(0), "INVALID_POOL");
        require(priceOracle_ != address(0), "INVALID_ORACLE");

        pool = LendingPool(pool_);
        priceOracle = PriceOracle(priceOracle_);
        minDebtThresholdUsd = 100e18;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

    function executeLiquidations(
        address[] calldata borrowers,
        address[] calldata debtAssets,
        address[] calldata collateralAssets,
        uint256[] calldata debtAmounts
    ) external nonReentrant whenNotPaused {
        uint256 entries = borrowers.length;
        require(entries == debtAssets.length, "LENGTH_MISMATCH");
        require(entries == collateralAssets.length, "LENGTH_MISMATCH");
        require(entries == debtAmounts.length, "LENGTH_MISMATCH");

        for (uint256 i = 0; i < entries; i++) {
            address borrower = borrowers[i];
            address debtAsset = debtAssets[i];
            address collateralAsset = collateralAssets[i];
            uint256 requestedDebtAmount = debtAmounts[i];

            require(borrower != address(0), "INVALID_BORROWER");
            require(debtAsset != address(0), "INVALID_DEBT_ASSET");
            require(collateralAsset != address(0), "INVALID_COLLATERAL_ASSET");
            require(requestedDebtAmount > 0, "INVALID_AMOUNT");

            uint256 userDebt = pool.userBorrows(borrower, debtAsset);
            require(userDebt > 0, "NO_DEBT");

            uint256 debtValueUsd = _assetValueUsd(debtAsset, userDebt);
            require(debtValueUsd >= minDebtThresholdUsd, "DEBT_BELOW_THRESHOLD");

            uint256 borrowerCollateral = pool.userDeposits(borrower, collateralAsset);
            require(borrowerCollateral > 0, "NO_COLLATERAL");

            (, , , , , uint256 liquidationBonusBps,,) = pool.getMarket(collateralAsset);
            uint256 debtPrice = priceOracle.getAssetPrice(debtAsset);
            uint256 collateralPrice = priceOracle.getAssetPrice(collateralAsset);

            uint256 maxDebtToCover = (borrowerCollateral * BPS * collateralPrice) / (debtPrice * liquidationBonusBps);

            uint256 debtToCover = requestedDebtAmount;
            if (debtToCover > userDebt) {
                debtToCover = userDebt;
            }
            if (debtToCover > maxDebtToCover) {
                debtToCover = maxDebtToCover;
            }
            require(debtToCover > 0, "INVALID_AMOUNT");

            uint256 collateralToSeize = (debtToCover * debtPrice * liquidationBonusBps) / (BPS * collateralPrice);
            require(collateralToSeize <= borrowerCollateral, "COLLATERAL_EXCEEDED");

            require(IERC20(debtAsset).transferFrom(msg.sender, address(this), debtToCover), "TRANSFER_FROM_FAILED");
            require(IERC20(debtAsset).approve(address(pool), 0), "APPROVE_RESET_FAILED");
            require(IERC20(debtAsset).approve(address(pool), debtToCover), "APPROVE_FAILED");

            pool.liquidate(borrower, debtAsset, collateralAsset, debtToCover);
            require(IERC20(collateralAsset).transfer(msg.sender, collateralToSeize), "COLLATERAL_TRANSFER_FAILED");

            emit LiquidationExecuted(
                msg.sender, borrower, debtAsset, collateralAsset, debtToCover, collateralToSeize
            );
        }
    }

    function setMinDebtThreshold(uint256 newThreshold) external onlyOwner {
        require(newThreshold > 0, "INVALID_THRESHOLD");

        uint256 oldThreshold = minDebtThresholdUsd;
        minDebtThresholdUsd = newThreshold;
        emit MinDebtThresholdUpdated(oldThreshold, newThreshold);
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PauseUpdated(paused_);
    }

    function _assetValueUsd(address asset, uint256 amount) internal view returns (uint256) {
        uint256 price = priceOracle.getAssetPrice(asset);
        uint8 decimals = _assetDecimals(asset);
        return (amount * price) / (10 ** decimals);
    }

    function _assetDecimals(address asset) internal view returns (uint8) {
        (bool success, bytes memory data) = asset.staticcall(abi.encodeWithSignature("decimals()"));
        require(success && data.length >= 32, "DECIMALS_CALL_FAILED");
        return abi.decode(data, (uint8));
    }
}
