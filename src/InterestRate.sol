// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

contract InterestRate {
    uint256 public constant PRECISION = 1e18;
    uint256 public constant BASE_RATE = 0.02e18;
    uint256 public constant SLOPE1 = 0.04e18;
    uint256 public constant SLOPE2 = 1e18;
    uint256 public constant OPTIMAL_UTILIZATION = 0.8e18;

    function calculateBorrowRate(uint256 totalBorrows, uint256 totalLiquidity) public pure returns (uint256) {
        if (totalBorrows == 0 || totalLiquidity == 0) {
            return BASE_RATE;
        }

        uint256 utilization = (totalBorrows * PRECISION) / totalLiquidity;

        if (utilization <= OPTIMAL_UTILIZATION) {
            return BASE_RATE + ((utilization * SLOPE1) / OPTIMAL_UTILIZATION);
        }

        uint256 excessUtilization = utilization - OPTIMAL_UTILIZATION;
        uint256 excessRange = PRECISION - OPTIMAL_UTILIZATION;
        return BASE_RATE + SLOPE1 + ((excessUtilization * SLOPE2) / excessRange);
    }

    function calculateSupplyRate(uint256 totalBorrows, uint256 totalLiquidity, uint256 reserveFactorBps)
        external
        pure
        returns (uint256)
    {
        if (totalBorrows == 0 || totalLiquidity == 0) {
            return 0;
        }

        uint256 borrowRate = calculateBorrowRate(totalBorrows, totalLiquidity);
        uint256 utilization = (totalBorrows * PRECISION) / totalLiquidity;
        uint256 grossSupplyRate = (borrowRate * utilization) / PRECISION;
        return (grossSupplyRate * (10_000 - reserveFactorBps)) / 10_000;
    }
}
