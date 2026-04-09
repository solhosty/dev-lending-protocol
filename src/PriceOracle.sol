// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/access/Ownable.sol";

import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

contract PriceOracle is Ownable {
    uint256 public constant MAX_PRICE_AGE = 1 days;

    mapping(address => address) public priceFeeds;

    constructor() Ownable(msg.sender) {}

    function setPriceFeed(address asset, address feed) external onlyOwner {
        require(asset != address(0), "INVALID_ASSET");
        require(feed != address(0), "INVALID_FEED");
        priceFeeds[asset] = feed;
    }

    function getAssetPrice(address asset) external view returns (uint256) {
        address feed = priceFeeds[asset];
        require(feed != address(0), "FEED_NOT_SET");

        AggregatorV3Interface aggregator = AggregatorV3Interface(feed);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            aggregator.latestRoundData();
        require(answer > 0, "INVALID_PRICE");
        require(answeredInRound >= roundId, "INCOMPLETE_ROUND");
        require(startedAt > 0 && updatedAt > 0, "STALE_PRICE");
        require(block.timestamp - updatedAt <= MAX_PRICE_AGE, "STALE_PRICE");

        uint8 decimals = aggregator.decimals();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 price = uint256(answer);

        if (decimals < 18) {
            return price * (10 ** (18 - decimals));
        }

        if (decimals > 18) {
            return price / (10 ** (decimals - 18));
        }

        return price;
    }
}
