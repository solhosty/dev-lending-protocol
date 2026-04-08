// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/security/ReentrancyGuard.sol";

import {AToken} from "src/AToken.sol";
import {DebtToken} from "src/DebtToken.sol";
import {PriceOracle} from "src/PriceOracle.sol";
import {InterestRate} from "src/InterestRate.sol";

contract LendingPool is Ownable, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint256 public constant HEALTH_FACTOR_ONE = 1e18;

    struct Market {
        bool isListed;
        AToken aToken;
        DebtToken debtToken;
        uint256 collateralFactorBps;
        uint256 liquidationThresholdBps;
        uint256 liquidationBonusBps;
        uint256 totalDeposits;
        uint256 totalBorrows;
    }

    mapping(address => Market) public markets;
    address[] public listedAssets;

    mapping(address => mapping(address => uint256)) public userDeposits;
    mapping(address => mapping(address => uint256)) public userBorrows;

    PriceOracle public immutable priceOracle;
    InterestRate public immutable interestRate;

    event MarketAdded(address indexed asset, address indexed aToken, address indexed debtToken);
    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event Withdraw(address indexed user, address indexed asset, uint256 amount);
    event Borrow(address indexed user, address indexed asset, uint256 amount);
    event Repay(address indexed user, address indexed asset, uint256 amount);
    event Liquidate(
        address indexed liquidator,
        address indexed user,
        address debtAsset,
        address collateralAsset,
        uint256 debtCovered,
        uint256 collateralSeized
    );

    constructor(address oracle_, address interestRate_) {
        require(oracle_ != address(0), "INVALID_ORACLE");
        require(interestRate_ != address(0), "INVALID_RATE_MODEL");
        priceOracle = PriceOracle(oracle_);
        interestRate = InterestRate(interestRate_);
    }

    function addMarket(
        address asset,
        string calldata name,
        string calldata symbol,
        uint256 collateralFactorBps,
        uint256 liquidationThresholdBps,
        uint256 liquidationBonusBps
    ) external onlyOwner {
        require(asset != address(0), "INVALID_ASSET");
        require(!markets[asset].isListed, "MARKET_EXISTS");
        require(collateralFactorBps <= BPS, "INVALID_COLLATERAL_FACTOR");
        require(liquidationThresholdBps <= BPS, "INVALID_LIQ_THRESHOLD");
        require(liquidationBonusBps >= BPS, "INVALID_LIQ_BONUS");

        AToken aToken = new AToken(string.concat("Aave ", name), string.concat("a", symbol), address(this));
        DebtToken debtToken =
            new DebtToken(string.concat("Variable Debt ", name), string.concat("vd", symbol), address(this));

        markets[asset] = Market({
            isListed: true,
            aToken: aToken,
            debtToken: debtToken,
            collateralFactorBps: collateralFactorBps,
            liquidationThresholdBps: liquidationThresholdBps,
            liquidationBonusBps: liquidationBonusBps,
            totalDeposits: 0,
            totalBorrows: 0
        });
        listedAssets.push(asset);

        emit MarketAdded(asset, address(aToken), address(debtToken));
    }

    function deposit(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "INVALID_AMOUNT");
        Market storage market = _getMarket(asset);

        require(IERC20(asset).transferFrom(msg.sender, address(this), amount), "TRANSFER_FAILED");
        market.totalDeposits += amount;
        userDeposits[msg.sender][asset] += amount;

        market.aToken.mint(msg.sender, amount);

        emit Deposit(msg.sender, asset, amount);
    }

    function withdraw(address asset, uint256 amount) external {
        require(amount > 0, "INVALID_AMOUNT");
        Market storage market = _getMarket(asset);
        require(userDeposits[msg.sender][asset] >= amount, "INSUFFICIENT_DEPOSIT");

        require(IERC20(asset).transfer(msg.sender, amount), "TRANSFER_FAILED");

        market.totalDeposits -= amount;
        userDeposits[msg.sender][asset] -= amount;
        market.aToken.burn(msg.sender, amount);

        uint256 totalBorrow = _totalBorrowValue(msg.sender);
        if (totalBorrow > 0) {
            require(getHealthFactor(msg.sender) >= HEALTH_FACTOR_ONE, "HEALTH_FACTOR_LOW");
        }

        emit Withdraw(msg.sender, asset, amount);
    }

    function borrow(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "INVALID_AMOUNT");
        Market storage market = _getMarket(asset);
        require(IERC20(asset).balanceOf(address(this)) >= amount, "INSUFFICIENT_LIQUIDITY");

        uint256 nextBorrowValue = _totalBorrowValue(msg.sender) + _assetValue(asset, amount);
        require(nextBorrowValue <= _totalCollateralValueForBorrow(msg.sender), "INSUFFICIENT_COLLATERAL");

        market.totalBorrows += amount;
        userBorrows[msg.sender][asset] += amount;
        market.debtToken.mint(msg.sender, amount);

        require(IERC20(asset).transfer(msg.sender, amount), "TRANSFER_FAILED");

        emit Borrow(msg.sender, asset, amount);
    }

    function repay(address asset, uint256 amount) external nonReentrant {
        require(amount > 0, "INVALID_AMOUNT");
        Market storage market = _getMarket(asset);

        uint256 debt = userBorrows[msg.sender][asset];
        require(debt > 0, "NO_DEBT");

        uint256 repayAmount = amount > debt ? debt : amount;
        require(IERC20(asset).transferFrom(msg.sender, address(this), repayAmount), "TRANSFER_FAILED");

        userBorrows[msg.sender][asset] = debt - repayAmount;
        market.totalBorrows -= repayAmount;
        market.debtToken.burn(msg.sender, repayAmount);

        emit Repay(msg.sender, asset, repayAmount);
    }

    function liquidate(address user, address debtAsset, address collateralAsset, uint256 debtToCover)
        external
        nonReentrant
    {
        _liquidate(msg.sender, user, debtAsset, collateralAsset, debtToCover);
    }

    function batchLiquidate(
        address[] calldata users,
        address debtAsset,
        address collateralAsset,
        uint256[] calldata debtToCover
    ) external {
        require(users.length == debtToCover.length, "LENGTH_MISMATCH");

        for (uint256 i = 0; i < users.length; i++) {
            _liquidate(msg.sender, users[i], debtAsset, collateralAsset, debtToCover[i]);
        }
    }

    function getHealthFactor(address user) public view returns (uint256) {
        uint256 borrowValue = _totalBorrowValue(user);
        if (borrowValue == 0) {
            return type(uint256).max;
        }

        uint256 thresholdAdjustedCollateral = _totalCollateralValueAtLiquidationThreshold(user);
        return (thresholdAdjustedCollateral * HEALTH_FACTOR_ONE) / borrowValue;
    }

    function getMarket(address asset)
        external
        view
        returns (
            bool isListed,
            address aToken,
            address debtToken,
            uint256 collateralFactorBps,
            uint256 liquidationThresholdBps,
            uint256 liquidationBonusBps,
            uint256 totalDeposits,
            uint256 totalBorrows
        )
    {
        Market storage market = markets[asset];
        return (
            market.isListed,
            address(market.aToken),
            address(market.debtToken),
            market.collateralFactorBps,
            market.liquidationThresholdBps,
            market.liquidationBonusBps,
            market.totalDeposits,
            market.totalBorrows
        );
    }

    function getCurrentRates(address asset) external view returns (uint256 borrowRate, uint256 supplyRate) {
        Market storage market = _getMarket(asset);
        borrowRate = interestRate.calculateBorrowRate(market.totalBorrows, market.totalDeposits);
        supplyRate = interestRate.calculateSupplyRate(market.totalBorrows, market.totalDeposits, 1_000);
    }

    function _liquidate(address liquidator, address user, address debtAsset, address collateralAsset, uint256 debtToCover)
        internal
    {
        require(debtToCover > 0, "INVALID_AMOUNT");
        require(getHealthFactor(user) < HEALTH_FACTOR_ONE, "HEALTHY_POSITION");

        Market storage debtMarket = _getMarket(debtAsset);
        Market storage collateralMarket = _getMarket(collateralAsset);

        uint256 userDebt = userBorrows[user][debtAsset];
        require(userDebt > 0, "NO_DEBT");

        uint256 debtAmount = debtToCover > userDebt ? userDebt : debtToCover;
        require(IERC20(debtAsset).transferFrom(liquidator, address(this), debtAmount), "TRANSFER_FAILED");

        userBorrows[user][debtAsset] = userDebt - debtAmount;
        debtMarket.totalBorrows -= debtAmount;
        debtMarket.debtToken.burn(user, debtAmount);

        uint256 debtPrice = priceOracle.getAssetPrice(debtAsset);
        uint256 collateralPrice = priceOracle.getAssetPrice(collateralAsset);

        uint256 collateralToSeize = (debtAmount * debtPrice * collateralMarket.liquidationBonusBps)
            / (BPS * collateralPrice);

        userDeposits[user][collateralAsset] -= collateralToSeize;
        collateralMarket.totalDeposits -= collateralToSeize;
        collateralMarket.aToken.burn(user, collateralToSeize);
        require(IERC20(collateralAsset).transfer(liquidator, collateralToSeize), "TRANSFER_FAILED");

        emit Liquidate(liquidator, user, debtAsset, collateralAsset, debtAmount, collateralToSeize);
    }

    function _getMarket(address asset) internal view returns (Market storage) {
        Market storage market = markets[asset];
        require(market.isListed, "MARKET_NOT_LISTED");
        return market;
    }

    function _totalBorrowValue(address user) internal view returns (uint256 totalBorrowValue) {
        uint256 length = listedAssets.length;
        for (uint256 i = 0; i < length; i++) {
            address asset = listedAssets[i];
            uint256 borrowed = userBorrows[user][asset];
            if (borrowed == 0) {
                continue;
            }

            totalBorrowValue += _assetValue(asset, borrowed);
        }
    }

    function _totalCollateralValueForBorrow(address user) internal view returns (uint256 totalCollateralValue) {
        uint256 length = listedAssets.length;
        for (uint256 i = 0; i < length; i++) {
            address asset = listedAssets[i];
            uint256 deposited = userDeposits[user][asset];
            if (deposited == 0) {
                continue;
            }

            uint256 assetValue = _assetValue(asset, deposited);
            totalCollateralValue += (assetValue * markets[asset].collateralFactorBps) / BPS;
        }
    }

    function _totalCollateralValueAtLiquidationThreshold(address user)
        internal
        view
        returns (uint256 totalCollateralValue)
    {
        uint256 length = listedAssets.length;
        for (uint256 i = 0; i < length; i++) {
            address asset = listedAssets[i];
            uint256 deposited = userDeposits[user][asset];
            if (deposited == 0) {
                continue;
            }

            uint256 assetValue = _assetValue(asset, deposited);
            totalCollateralValue += (assetValue * markets[asset].liquidationThresholdBps) / BPS;
        }
    }

    function _assetValue(address asset, uint256 amount) internal view returns (uint256) {
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
