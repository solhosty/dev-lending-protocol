// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/openzeppelin-contracts/lib/forge-std/src/Test.sol";

import {InterestRate} from "src/InterestRate.sol";

contract InterestRateTest is Test {
    InterestRate internal rate;

    function setUp() external {
        rate = new InterestRate();
    }

    function testBaseRateAtZeroUtilization() external {
        uint256 borrowRate = rate.calculateBorrowRate(0, 100e18);
        assertEq(borrowRate, 0.02e18);
    }

    function testBorrowRateAtEightyPercentUtilization() external {
        uint256 borrowRate = rate.calculateBorrowRate(80e18, 100e18);
        assertEq(borrowRate, 0.06e18);
    }

    function testBorrowRateAtNinetyPercentUtilization() external {
        uint256 borrowRate = rate.calculateBorrowRate(90e18, 100e18);
        assertEq(borrowRate, 0.56e18);
    }

    function testBorrowRateAtHundredPercentUtilization() external {
        uint256 borrowRate = rate.calculateBorrowRate(100e18, 100e18);
        assertEq(borrowRate, 1.06e18);
    }
}
