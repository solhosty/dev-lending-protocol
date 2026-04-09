// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/openzeppelin-contracts/lib/forge-std/src/Test.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {PriceOracle} from "src/PriceOracle.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

contract MockPriceFeed is AggregatorV3Interface {
    int256 internal price;
    uint8 internal immutable feedDecimals;
    uint80 internal latestRoundId;
    uint80 internal latestAnsweredInRound;
    uint256 internal latestStartedAt;
    uint256 internal latestUpdatedAt;

    constructor(uint8 decimals_, int256 initialPrice) {
        feedDecimals = decimals_;
        price = initialPrice;
        latestRoundId = 1;
        latestAnsweredInRound = 1;
        latestStartedAt = block.timestamp;
        latestUpdatedAt = block.timestamp;
    }

    function setPrice(int256 newPrice) external {
        price = newPrice;
    }

    function setRoundData(uint80 newRoundId, uint256 newStartedAt, uint256 newUpdatedAt, uint80 newAnsweredInRound)
        external
    {
        latestRoundId = newRoundId;
        latestStartedAt = newStartedAt;
        latestUpdatedAt = newUpdatedAt;
        latestAnsweredInRound = newAnsweredInRound;
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
        return (roundId, price, latestStartedAt, latestUpdatedAt, latestAnsweredInRound);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (latestRoundId, price, latestStartedAt, latestUpdatedAt, latestAnsweredInRound);
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
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xB0B)));
        oracle.setPriceFeed(ASSET, address(feed));
    }

    function testZeroPriceReverts() external {
        oracle.setPriceFeed(ASSET, address(feed));
        feed.setPrice(0);

        vm.expectRevert("INVALID_PRICE");
        oracle.getAssetPrice(ASSET);
    }

    function testIncompleteRoundReverts() external {
        oracle.setPriceFeed(ASSET, address(feed));
        feed.setRoundData(2, block.timestamp, block.timestamp, 1);

        vm.expectRevert("INCOMPLETE_ROUND");
        oracle.getAssetPrice(ASSET);
    }

    function testStalePriceReverts() external {
        oracle.setPriceFeed(ASSET, address(feed));
        vm.warp(block.timestamp + oracle.MAX_PRICE_AGE() + 1);

        vm.expectRevert("STALE_PRICE");
        oracle.getAssetPrice(ASSET);
    }
}
