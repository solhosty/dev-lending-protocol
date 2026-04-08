// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "lib/openzeppelin-contracts/lib/forge-std/src/Script.sol";

import {InterestRate} from "src/InterestRate.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {LendingPool} from "src/LendingPool.sol";

contract Deploy is Script {
    function run() external returns (InterestRate, PriceOracle, LendingPool) {
        vm.startBroadcast();

        InterestRate interestRate = new InterestRate();
        PriceOracle priceOracle = new PriceOracle();
        LendingPool lendingPool = new LendingPool(address(priceOracle), address(interestRate));

        vm.stopBroadcast();
        return (interestRate, priceOracle, lendingPool);
    }
}
