// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/openzeppelin-contracts/lib/forge-std/src/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

import {AToken} from "src/AToken.sol";
import {DebtToken} from "src/DebtToken.sol";
import {LendingPool} from "src/LendingPool.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {InterestRate} from "src/InterestRate.sol";
import {AggregatorV3Interface} from "src/interfaces/AggregatorV3Interface.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable tokenDecimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return tokenDecimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

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

contract UserActor {
    function approveToken(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }

    function deposit(address pool, address asset, uint256 amount) external {
        LendingPool(pool).deposit(asset, amount);
    }

    function withdraw(address pool, address asset, uint256 amount) external {
        LendingPool(pool).withdraw(asset, amount);
    }

    function borrow(address pool, address asset, uint256 amount) external {
        LendingPool(pool).borrow(asset, amount);
    }

    function repay(address pool, address asset, uint256 amount) external {
        LendingPool(pool).repay(asset, amount);
    }

    function liquidate(address pool, address user, address debtAsset, address collateralAsset, uint256 debtToCover)
        external
    {
        LendingPool(pool).liquidate(user, debtAsset, collateralAsset, debtToCover);
    }

    function batchLiquidate(
        address pool,
        address[] calldata users,
        address debtAsset,
        address collateralAsset,
        uint256[] calldata debtToCover
    ) external {
        LendingPool(pool).batchLiquidate(users, debtAsset, collateralAsset, debtToCover);
    }
}

contract LendingPoolTest is Test {
    LendingPool internal pool;
    PriceOracle internal oracle;
    InterestRate internal rate;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockPriceFeed internal wethFeed;
    MockPriceFeed internal usdcFeed;

    UserActor internal alice;
    UserActor internal bob;
    UserActor internal carol;
    UserActor internal liquidator;

    int256 internal constant WETH_PRICE = 2_000e8;
    int256 internal constant USDC_PRICE = 1e8;

    function setUp() external {
        rate = new InterestRate();
        oracle = new PriceOracle();
        pool = new LendingPool(address(oracle), address(rate));

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wethFeed = new MockPriceFeed(8, WETH_PRICE);
        usdcFeed = new MockPriceFeed(8, USDC_PRICE);

        oracle.setPriceFeed(address(weth), address(wethFeed));
        oracle.setPriceFeed(address(usdc), address(usdcFeed));

        pool.addMarket(address(weth), "Wrapped Ether", "WETH", 7500, 8000, 10500);
        pool.addMarket(address(usdc), "USD Coin", "USDC", 8500, 9000, 10500);

        alice = new UserActor();
        bob = new UserActor();
        carol = new UserActor();
        liquidator = new UserActor();

        weth.mint(address(alice), 20e18);
        weth.mint(address(carol), 20e18);
        usdc.mint(address(bob), 100_000e6);
        usdc.mint(address(liquidator), 50_000e6);
    }

    function testAddMarketStoresConfig() external {
        (bool listed,, address debtToken,, uint256 ltBps, uint256 lbBps,,) = pool.getMarket(address(weth));
        assertTrue(listed);
        assertTrue(debtToken != address(0));
        assertEq(ltBps, 8000);
        assertEq(lbBps, 10500);
    }

    function testDepositMintsATokens() external {
        _aliceApproveAndDepositWeth(10e18);

        (, address aToken,,,,,,) = pool.getMarket(address(weth));
        assertEq(AToken(aToken).balanceOf(address(alice)), 10e18);
        assertEq(pool.userDeposits(address(alice), address(weth)), 10e18);
    }

    function testWithdrawBurnsATokens() external {
        _aliceApproveAndDepositWeth(10e18);
        alice.withdraw(address(pool), address(weth), 4e18);

        (, address aToken,,,,,,) = pool.getMarket(address(weth));
        assertEq(AToken(aToken).balanceOf(address(alice)), 6e18);
        assertEq(pool.userDeposits(address(alice), address(weth)), 6e18);
    }

    function testBorrowTransfersUnderlying() external {
        _bobProvideUsdcLiquidity(30_000e6);
        _aliceApproveAndDepositWeth(10e18);

        uint256 usdcBefore = usdc.balanceOf(address(alice));
        alice.borrow(address(pool), address(usdc), 10_000e6);

        assertEq(usdc.balanceOf(address(alice)) - usdcBefore, 10_000e6);
        assertEq(pool.userBorrows(address(alice), address(usdc)), 10_000e6);
    }

    function testRepayBurnsDebtTokens() external {
        _bobProvideUsdcLiquidity(30_000e6);
        _aliceApproveAndDepositWeth(10e18);
        alice.borrow(address(pool), address(usdc), 8_000e6);

        usdc.mint(address(alice), 8_000e6);
        alice.approveToken(address(usdc), address(pool), 8_000e6);
        alice.repay(address(pool), address(usdc), 8_000e6);

        (, , address debtToken,,,,,) = pool.getMarket(address(usdc));
        assertEq(DebtToken(debtToken).balanceOf(address(alice)), 0);
        assertEq(pool.userBorrows(address(alice), address(usdc)), 0);
    }

    function testLiquidateSeizesCollateral() external {
        _bobProvideUsdcLiquidity(40_000e6);
        _aliceApproveAndDepositWeth(10e18);
        alice.borrow(address(pool), address(usdc), 14_000e6);

        wethFeed.setPrice(1_200e8);

        liquidator.approveToken(address(usdc), address(pool), 2_000e6);
        uint256 liquidatorWethBefore = weth.balanceOf(address(liquidator));
        liquidator.liquidate(address(pool), address(alice), address(usdc), address(weth), 2_000e6);

        assertEq(pool.userBorrows(address(alice), address(usdc)), 12_000e6);
        assertTrue(weth.balanceOf(address(liquidator)) > liquidatorWethBefore);
    }

    function testBatchLiquidateLoopsUsers() external {
        _bobProvideUsdcLiquidity(50_000e6);

        _aliceApproveAndDepositWeth(10e18);
        _carolApproveAndDepositWeth(8e18);

        alice.borrow(address(pool), address(usdc), 12_000e6);
        carol.borrow(address(pool), address(usdc), 9_000e6);

        wethFeed.setPrice(1_200e8);

        liquidator.approveToken(address(usdc), address(pool), 4_000e6);

        address[] memory users = new address[](2);
        users[0] = address(alice);
        users[1] = address(carol);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1_000e6;
        amounts[1] = 1_500e6;

        liquidator.batchLiquidate(address(pool), users, address(usdc), address(weth), amounts);

        assertEq(pool.userBorrows(address(alice), address(usdc)), 11_000e6);
        assertEq(pool.userBorrows(address(carol), address(usdc)), 7_500e6);
    }

    function testHealthFactorReturnsMaxWithoutDebt() external {
        _aliceApproveAndDepositWeth(2e18);

        uint256 healthFactor = pool.getHealthFactor(address(alice));
        assertEq(healthFactor, type(uint256).max);
    }

    function _aliceApproveAndDepositWeth(uint256 amount) internal {
        alice.approveToken(address(weth), address(pool), amount);
        alice.deposit(address(pool), address(weth), amount);
    }

    function _carolApproveAndDepositWeth(uint256 amount) internal {
        carol.approveToken(address(weth), address(pool), amount);
        carol.deposit(address(pool), address(weth), amount);
    }

    function _bobProvideUsdcLiquidity(uint256 amount) internal {
        bob.approveToken(address(usdc), address(pool), amount);
        bob.deposit(address(pool), address(usdc), amount);
    }
}
