// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/openzeppelin-contracts/lib/forge-std/src/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

import {LendingPool} from "src/LendingPool.sol";
import {LiquidationEngine} from "src/LiquidationEngine.sol";
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

contract UserActor {
    function approveToken(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }

    function deposit(address pool, address asset, uint256 amount) external {
        LendingPool(pool).deposit(asset, amount);
    }

    function borrow(address pool, address asset, uint256 amount) external {
        LendingPool(pool).borrow(asset, amount);
    }

    function liquidateMultiAsset(
        address engine,
        address borrower,
        address debtAsset,
        address[] calldata collateralAssets,
        uint256[] calldata debtAmounts
    ) external {
        LiquidationEngine(engine).liquidateMultiAsset(borrower, debtAsset, collateralAssets, debtAmounts);
    }
}

contract LiquidationEngineTest is Test {
    LendingPool internal pool;
    LiquidationEngine internal engine;
    PriceOracle internal oracle;
    InterestRate internal rate;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockERC20 internal dai;
    MockPriceFeed internal wethFeed;
    MockPriceFeed internal usdcFeed;
    MockPriceFeed internal daiFeed;

    UserActor internal borrower;
    UserActor internal liquidityProvider;
    UserActor internal liquidator;

    int256 internal constant WETH_PRICE = 2_000e8;
    int256 internal constant USDC_PRICE = 1e8;
    int256 internal constant DAI_PRICE = 1e8;

    function setUp() external {
        rate = new InterestRate();
        oracle = new PriceOracle();
        pool = new LendingPool(address(oracle), address(rate));
        engine = new LiquidationEngine(pool, 500);

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        dai = new MockERC20("DAI", "DAI", 18);

        wethFeed = new MockPriceFeed(8, WETH_PRICE);
        usdcFeed = new MockPriceFeed(8, USDC_PRICE);
        daiFeed = new MockPriceFeed(8, DAI_PRICE);

        oracle.setPriceFeed(address(weth), address(wethFeed));
        oracle.setPriceFeed(address(usdc), address(usdcFeed));
        oracle.setPriceFeed(address(dai), address(daiFeed));

        pool.addMarket(address(weth), "Wrapped Ether", "WETH", 7500, 8000, 10500);
        pool.addMarket(address(usdc), "USD Coin", "USDC", 8500, 9000, 10500);
        pool.addMarket(address(dai), "DAI", "DAI", 8000, 8500, 10500);

        borrower = new UserActor();
        liquidityProvider = new UserActor();
        liquidator = new UserActor();

        weth.mint(address(borrower), 20e18);
        dai.mint(address(borrower), 30_000e18);
        usdc.mint(address(liquidityProvider), 200_000e6);
        usdc.mint(address(liquidator), 100_000e6);

        weth.mint(address(engine), 5e18);
        dai.mint(address(engine), 5_000e18);
    }

    function testLiquidateMultiAssetTwoCollaterals() external {
        _provideUsdcLiquidity(120_000e6);

        borrower.approveToken(address(weth), address(pool), 10e18);
        borrower.deposit(address(pool), address(weth), 10e18);

        borrower.approveToken(address(dai), address(pool), 20_000e18);
        borrower.deposit(address(pool), address(dai), 20_000e18);

        borrower.borrow(address(pool), address(usdc), 28_000e6);

        wethFeed.setPrice(1_000e8);

        liquidator.approveToken(address(usdc), address(engine), 5_000e6);

        address[] memory collateralAssets = new address[](2);
        collateralAssets[0] = address(weth);
        collateralAssets[1] = address(dai);

        uint256[] memory debtAmounts = new uint256[](2);
        debtAmounts[0] = 2_000e6;
        debtAmounts[1] = 3_000e6;

        liquidator.liquidateMultiAsset(address(engine), address(borrower), address(usdc), collateralAssets, debtAmounts);

        assertEq(pool.userBorrows(address(borrower), address(usdc)), 23_000e6);
    }

    function testLiquidateMultiAssetSingleCollateral() external {
        _provideUsdcLiquidity(120_000e6);

        borrower.approveToken(address(weth), address(pool), 10e18);
        borrower.deposit(address(pool), address(weth), 10e18);
        borrower.borrow(address(pool), address(usdc), 14_000e6);

        wethFeed.setPrice(1_200e8);
        liquidator.approveToken(address(usdc), address(engine), 2_000e6);

        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = address(weth);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 2_000e6;

        liquidator.liquidateMultiAsset(address(engine), address(borrower), address(usdc), collateralAssets, debtAmounts);

        assertEq(pool.userBorrows(address(borrower), address(usdc)), 12_000e6);
    }

    function testSetEngineBonusBpsOnlyOwner() external {
        vm.prank(address(liquidator));
        vm.expectRevert();
        engine.setEngineBonusBps(900);
    }

    function testRevertsOnHealthyPosition() external {
        _provideUsdcLiquidity(120_000e6);

        borrower.approveToken(address(weth), address(pool), 8e18);
        borrower.deposit(address(pool), address(weth), 8e18);
        borrower.borrow(address(pool), address(usdc), 4_000e6);

        liquidator.approveToken(address(usdc), address(engine), 1_000e6);

        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = address(weth);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 1_000e6;

        vm.expectRevert(LiquidationEngine.PositionHealthy.selector);
        liquidator.liquidateMultiAsset(address(engine), address(borrower), address(usdc), collateralAssets, debtAmounts);
    }

    function testRevertsOnArrayLengthMismatch() external {
        address[] memory collateralAssets = new address[](2);
        collateralAssets[0] = address(weth);
        collateralAssets[1] = address(dai);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 1_000e6;

        vm.expectRevert(LiquidationEngine.InvalidParams.selector);
        liquidator.liquidateMultiAsset(address(engine), address(borrower), address(usdc), collateralAssets, debtAmounts);
    }

    function _provideUsdcLiquidity(uint256 amount) internal {
        liquidityProvider.approveToken(address(usdc), address(pool), amount);
        liquidityProvider.deposit(address(pool), address(usdc), amount);
    }
}
