// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/openzeppelin-contracts/lib/forge-std/src/Test.sol";

import {PriceOracle} from "src/PriceOracle.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

contract MockPriceFeed is AggregatorV3Interface {
    int256 internal price;
    uint8 internal immutable feedDecimals;

    constructor(uint8 decimals_, int256 initialPrice) {
        feedDecimals = decimals_;
        price = initialPrice;
    }

    function setPrice(int256 newPrice) external {
        price = newPrice;
    }

    function decimals() external view returns (uint8) {
        return feedDecimals;
    }

    function description() external pure returns (string memory) {
        return "mock";
    }

    function version() external pure returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        return (roundId, price, 0, 0, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, 0, 1);
    }
}

contract PriceOracleTest is Test {
    PriceOracle internal oracle;
    MockPriceFeed internal feed;
    address internal constant ASSET = address(0xA11CE);

    function setUp() external {
        oracle = new PriceOracle();
        feed = new MockPriceFeed(8, 2_000e8);
    }

    function testSetAndGetPrice() external {
        oracle.setPriceFeed(ASSET, address(feed));
        uint256 price = oracle.getAssetPrice(ASSET);
        assertEq(price, 2_000e18);
    }

    function testOnlyOwnerCanSetPriceFeed() external {
        vm.prank(address(0xB0B));
        vm.expectRevert("Ownable: caller is not the owner");
        oracle.setPriceFeed(ASSET, address(feed));
    }

    function testZeroPriceReverts() external {
        oracle.setPriceFeed(ASSET, address(feed));
        feed.setPrice(0);

        vm.expectRevert("INVALID_PRICE");
        oracle.getAssetPrice(ASSET);
    }
}
