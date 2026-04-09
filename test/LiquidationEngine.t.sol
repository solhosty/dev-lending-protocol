// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "lib/openzeppelin-contracts/lib/forge-std/src/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";

import {LendingPool} from "src/LendingPool.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {InterestRate} from "src/InterestRate.sol";
import {LiquidationEngine} from "src/LiquidationEngine.sol";
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
}

contract LiquidationEngineActor {
    function approveToken(address token, address spender, uint256 amount) external {
        ERC20(token).approve(spender, amount);
    }

    function executeLiquidations(
        address engine,
        address[] calldata borrowers,
        address[] calldata debtAssets,
        address[] calldata collateralAssets,
        uint256[] calldata debtAmounts
    ) external {
        LiquidationEngine(engine).executeLiquidations(borrowers, debtAssets, collateralAssets, debtAmounts);
    }
}

contract ReentrantMockERC20 is MockERC20 {
    bool public arm;
    address public engine;
    address public borrower;
    address public debtAsset;
    address public collateralAsset;
    uint256 public debtAmount;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) MockERC20(name_, symbol_, decimals_) {}

    function armReentry(
        address engine_,
        address borrower_,
        address debtAsset_,
        address collateralAsset_,
        uint256 debtAmount_
    ) external {
        arm = true;
        engine = engine_;
        borrower = borrower_;
        debtAsset = debtAsset_;
        collateralAsset = collateralAsset_;
        debtAmount = debtAmount_;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public override returns (bool) {
        if (arm && msg.sender == engine) {
            address[] memory borrowers = new address[](1);
            borrowers[0] = borrower;

            address[] memory debtAssets = new address[](1);
            debtAssets[0] = debtAsset;

            address[] memory collateralAssets = new address[](1);
            collateralAssets[0] = collateralAsset;

            uint256[] memory debtAmounts = new uint256[](1);
            debtAmounts[0] = debtAmount;

            LiquidationEngine(engine).executeLiquidations(borrowers, debtAssets, collateralAssets, debtAmounts);
        }

        return super.transferFrom(sender, recipient, amount);
    }
}

contract LiquidationEngineTest is Test {
    LendingPool internal pool;
    PriceOracle internal oracle;
    InterestRate internal rate;
    LiquidationEngine internal liquidationEngine;

    MockERC20 internal weth;
    MockERC20 internal usdc;
    MockERC20 internal wbtc;
    MockERC20 internal dai;

    MockPriceFeed internal wethFeed;
    MockPriceFeed internal usdcFeed;
    MockPriceFeed internal wbtcFeed;
    MockPriceFeed internal daiFeed;

    UserActor internal alice;
    UserActor internal bob;
    UserActor internal carol;
    LiquidationEngineActor internal liquidator;

    int256 internal constant WETH_PRICE = 2_000e8;
    int256 internal constant USDC_PRICE = 1e8;
    int256 internal constant WBTC_PRICE = 30_000e8;
    int256 internal constant DAI_PRICE = 1e8;

    function setUp() external {
        rate = new InterestRate();
        oracle = new PriceOracle();
        pool = new LendingPool(address(oracle), address(rate));
        liquidationEngine = new LiquidationEngine(address(pool), address(oracle));

        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20("USD Coin", "USDC", 6);
        wbtc = new MockERC20("Wrapped Bitcoin", "WBTC", 8);
        dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        wethFeed = new MockPriceFeed(8, WETH_PRICE);
        usdcFeed = new MockPriceFeed(8, USDC_PRICE);
        wbtcFeed = new MockPriceFeed(8, WBTC_PRICE);
        daiFeed = new MockPriceFeed(8, DAI_PRICE);

        oracle.setPriceFeed(address(weth), address(wethFeed));
        oracle.setPriceFeed(address(usdc), address(usdcFeed));
        oracle.setPriceFeed(address(wbtc), address(wbtcFeed));
        oracle.setPriceFeed(address(dai), address(daiFeed));

        pool.addMarket(address(weth), "Wrapped Ether", "WETH", 7500, 8000, 10500);
        pool.addMarket(address(usdc), "USD Coin", "USDC", 8500, 9000, 10500);
        pool.addMarket(address(wbtc), "Wrapped Bitcoin", "WBTC", 7000, 7500, 10500);
        pool.addMarket(address(dai), "Dai Stablecoin", "DAI", 8500, 9000, 10500);

        alice = new UserActor();
        bob = new UserActor();
        carol = new UserActor();
        liquidator = new LiquidationEngineActor();

        weth.mint(address(alice), 30e18);
        weth.mint(address(bob), 200e18);
        weth.mint(address(carol), 30e18);
        weth.mint(address(liquidator), 100e18);

        usdc.mint(address(bob), 300_000e6);
        usdc.mint(address(liquidator), 100_000e6);

        wbtc.mint(address(carol), 5e8);
        wbtc.mint(address(bob), 2e8);

        dai.mint(address(bob), 300_000e18);
        dai.mint(address(liquidator), 100_000e18);
    }

    function testSingleLiquidation() external {
        _bobProvideUsdcLiquidity(50_000e6);

        alice.approveToken(address(weth), address(pool), 10e18);
        alice.deposit(address(pool), address(weth), 10e18);
        alice.borrow(address(pool), address(usdc), 14_000e6);

        wethFeed.setPrice(1_200e8);

        liquidator.approveToken(address(usdc), address(liquidationEngine), 2_000e6);

        address[] memory borrowers = new address[](1);
        borrowers[0] = address(alice);

        address[] memory debtAssets = new address[](1);
        debtAssets[0] = address(usdc);

        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = address(weth);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 2_000e6;

        uint256 liquidatorWethBefore = weth.balanceOf(address(liquidator));
        liquidator.executeLiquidations(
            address(liquidationEngine), borrowers, debtAssets, collateralAssets, debtAmounts
        );

        assertEq(pool.userBorrows(address(alice), address(usdc)), 12_000e6);
        assertTrue(weth.balanceOf(address(liquidator)) > liquidatorWethBefore);
    }

    function testMultiAssetLiquidation() external {
        _bobProvideUsdcLiquidity(80_000e6);
        _bobProvideDaiLiquidity(80_000e18);

        alice.approveToken(address(weth), address(pool), 10e18);
        alice.deposit(address(pool), address(weth), 10e18);
        alice.borrow(address(pool), address(usdc), 12_000e6);

        carol.approveToken(address(weth), address(pool), 5e18);
        carol.deposit(address(pool), address(weth), 5e18);
        carol.borrow(address(pool), address(dai), 6_000e18);

        wethFeed.setPrice(1_200e8);

        liquidator.approveToken(address(usdc), address(liquidationEngine), 1_000e6);
        liquidator.approveToken(address(dai), address(liquidationEngine), 1_500e18);

        address[] memory borrowers = new address[](2);
        borrowers[0] = address(alice);
        borrowers[1] = address(carol);

        address[] memory debtAssets = new address[](2);
        debtAssets[0] = address(usdc);
        debtAssets[1] = address(dai);

        address[] memory collateralAssets = new address[](2);
        collateralAssets[0] = address(weth);
        collateralAssets[1] = address(weth);

        uint256[] memory debtAmounts = new uint256[](2);
        debtAmounts[0] = 1_000e6;
        debtAmounts[1] = 1_500e18;

        liquidator.executeLiquidations(
            address(liquidationEngine), borrowers, debtAssets, collateralAssets, debtAmounts
        );

        assertEq(pool.userBorrows(address(alice), address(usdc)), 11_000e6);
        assertEq(pool.userBorrows(address(carol), address(dai)), 4_500e18);
    }

    function testBonusCapping() external {
        _bobProvideDaiLiquidity(100_000e18);

        alice.approveToken(address(weth), address(pool), 1e18);
        alice.deposit(address(pool), address(weth), 1e18);
        alice.borrow(address(pool), address(dai), 1_500e18);

        wethFeed.setPrice(1_000e8);

        liquidator.approveToken(address(dai), address(liquidationEngine), 1_500e18);

        address[] memory borrowers = new address[](1);
        borrowers[0] = address(alice);

        address[] memory debtAssets = new address[](1);
        debtAssets[0] = address(dai);

        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = address(weth);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 1_500e18;

        uint256 collateralBefore = pool.userDeposits(address(alice), address(weth));
        uint256 debtBefore = pool.userBorrows(address(alice), address(dai));
        uint256 debtPrice = oracle.getAssetPrice(address(dai));
        uint256 collateralPrice = oracle.getAssetPrice(address(weth));
        (, , , , , uint256 liquidationBonusBps,,) = pool.getMarket(address(weth));

        uint256 expectedDebtToCover = (collateralBefore * 10_000 * collateralPrice) / (debtPrice * liquidationBonusBps);
        uint256 expectedCollateralSeized =
            (expectedDebtToCover * debtPrice * liquidationBonusBps) / (10_000 * collateralPrice);

        liquidator.executeLiquidations(
            address(liquidationEngine), borrowers, debtAssets, collateralAssets, debtAmounts
        );

        assertEq(pool.userBorrows(address(alice), address(dai)), debtBefore - expectedDebtToCover);
        assertEq(pool.userDeposits(address(alice), address(weth)), collateralBefore - expectedCollateralSeized);
    }

    function testMinDebtThresholdReverts() external {
        _bobProvideUsdcLiquidity(10_000e6);

        alice.approveToken(address(weth), address(pool), 1e18);
        alice.deposit(address(pool), address(weth), 1e18);
        alice.borrow(address(pool), address(usdc), 50e6);

        liquidator.approveToken(address(usdc), address(liquidationEngine), 50e6);

        address[] memory borrowers = new address[](1);
        borrowers[0] = address(alice);

        address[] memory debtAssets = new address[](1);
        debtAssets[0] = address(usdc);

        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = address(weth);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 50e6;

        vm.expectRevert(bytes("DEBT_BELOW_THRESHOLD"));
        liquidator.executeLiquidations(
            address(liquidationEngine), borrowers, debtAssets, collateralAssets, debtAmounts
        );
    }

    function testArrayLengthMismatchReverts() external {
        address[] memory borrowers = new address[](1);
        borrowers[0] = address(alice);

        address[] memory debtAssets = new address[](0);
        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = address(weth);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 1;

        vm.expectRevert(bytes("LENGTH_MISMATCH"));
        liquidator.executeLiquidations(
            address(liquidationEngine), borrowers, debtAssets, collateralAssets, debtAmounts
        );
    }

    function testZeroAddressReverts() external {
        address[] memory borrowers = new address[](1);
        borrowers[0] = address(0);

        address[] memory debtAssets = new address[](1);
        debtAssets[0] = address(usdc);

        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = address(weth);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 1;

        vm.expectRevert(bytes("INVALID_BORROWER"));
        liquidator.executeLiquidations(
            address(liquidationEngine), borrowers, debtAssets, collateralAssets, debtAmounts
        );
    }

    function testReentrancyReverts() external {
        ReentrantMockERC20 reentrantDebt = new ReentrantMockERC20("Reentrant Debt", "RDEBT", 18);
        MockPriceFeed reentrantFeed = new MockPriceFeed(8, 200e8);

        oracle.setPriceFeed(address(reentrantDebt), address(reentrantFeed));
        pool.addMarket(address(reentrantDebt), "Reentrant Debt", "RDEBT", 8000, 8500, 10500);

        reentrantDebt.mint(address(bob), 100_000e18);
        reentrantDebt.mint(address(liquidator), 10_000e18);

        bob.approveToken(address(reentrantDebt), address(pool), 50_000e18);
        bob.deposit(address(pool), address(reentrantDebt), 50_000e18);

        alice.approveToken(address(weth), address(pool), 2e18);
        alice.deposit(address(pool), address(weth), 2e18);
        alice.borrow(address(pool), address(reentrantDebt), 10e18);

        reentrantDebt.armReentry(address(liquidationEngine), address(alice), address(reentrantDebt), address(weth), 100e18);
        liquidator.approveToken(address(reentrantDebt), address(liquidationEngine), 100e18);

        address[] memory borrowers = new address[](1);
        borrowers[0] = address(alice);

        address[] memory debtAssets = new address[](1);
        debtAssets[0] = address(reentrantDebt);

        address[] memory collateralAssets = new address[](1);
        collateralAssets[0] = address(weth);

        uint256[] memory debtAmounts = new uint256[](1);
        debtAmounts[0] = 100e18;

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        liquidator.executeLiquidations(
            address(liquidationEngine), borrowers, debtAssets, collateralAssets, debtAmounts
        );
    }

    function _bobProvideUsdcLiquidity(uint256 amount) internal {
        bob.approveToken(address(usdc), address(pool), amount);
        bob.deposit(address(pool), address(usdc), amount);
    }

    function _bobProvideWethLiquidity(uint256 amount) internal {
        bob.approveToken(address(weth), address(pool), amount);
        bob.deposit(address(pool), address(weth), amount);
    }

    function _bobProvideDaiLiquidity(uint256 amount) internal {
        bob.approveToken(address(dai), address(pool), amount);
        bob.deposit(address(pool), address(dai), amount);
    }
}
