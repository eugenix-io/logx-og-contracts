// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../libraries/token/IERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IUtils.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/IUSDL.sol";
import "../access/Governable.sol";
import "../libraries/utils/EnumerableSet.sol";
import '../libraries/token/SafeERC20.sol';

contract Vault is ReentrancyGuard, IVault {
    using SafeERC20 for IERC20;

    struct Position {
        address account;
        address collateralToken;
        address indexToken;
        bool isLong;
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryBorrowingRate;
        int256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }
// ------------------------- LOGIC
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDL_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_BORROWING_RATE_INTERVAL = 1 seconds;
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 seconds;
    uint256 public constant MAX_BORROWING_RATE_FACTOR = 100000000; // 1%

    bool public override isInitialized;
    IUtils public utils;

    mapping(address=>bool) public orderManagers;
    address public override priceFeed;

    address public override usdl;
    address public override gov;
    bool public override ceaseTradingActivity = false;
    bool public override ceaseLPActivity = false;

    uint256 public override liquidationFeeUsd;
    uint256 public override liquidationFactor;
    uint256 public override mintBurnFeeBasisPoints = 30; // 0.3%
    uint256 public override marginFeeBasisPoints = 10; // 0.1%
    uint256 public override maxFundingRateFactor = 100000000; // 1%

    uint256 public override minProfitTime;
    bool public override hasDynamicFees = false;

    uint256 public override borrowingInterval = 1 minutes;
    uint256 public override borrowingRateFactor;
    uint256 public override fundingInterval = 1 minutes;
    uint256 public override fundingRateFactor;

    bool public override inManagerMode = false;
    bool public override inPrivateLiquidationMode = false;

    uint256 public override maxGasPrice;
    mapping (address=>uint256) public maxOIImbalance;
    mapping (address=>uint256) public override oiImbalanceThreshold; 
    uint256 public safetyFactor;
    

// ------------------------------ / :LOGIC

    mapping(address => bool) public override isLiquidator;
    mapping(address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => bool) public override canBeIndexToken;
    mapping(address => bool) public override canBeCollateralToken;
    mapping(address => uint256) public override tokenDecimals;
    mapping(address => uint256) public override minProfitBasisPoints;
    mapping(address => bool) public override stableTokens;
    mapping(address=>uint256) public override maxLeverage;

    // tokenBalances is used only to determine _transferIn values
    mapping(address => uint256) public override tokenBalances;

    // poolAmounts tracks the number of tokens received.
    // Lets say 10^18 USDC is added to pool 1 will added to the 
    // pool amount instead of 10^18
    mapping(address => uint256) public override poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    // Lets say 10^18 USDC is reserved for a leveraged position
    // 1 will added to the reservedAmount instead of 10^18
    mapping(address => uint256) public override reservedAmounts;

    // cumulativeBorrowingRates tracks the borrowing rates based on utilization
    mapping(address => uint256) public override cumulativeBorrowingRates;
    uint256 public  fundingExponent;
    mapping(address => int256) public  cumulativeFundingRatesForLongs;
    mapping(address => int256) public cumulativeFundingRatesForShorts;

    // lastBorrowingTimes tracks the last time borrowing was updated for a token
    mapping(address => uint256) public override lastBorrowingTimes;
    mapping(address => uint256) public override lastFundingTimes;
    
    

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;
    EnumerableSet.Bytes32Set private positionKeys;

    // feeReserves tracks the amount of fees per token
    mapping(address => uint256) public override feeReserves;

    mapping(address => uint256) public override globalShortSizes;
    mapping(address => uint256) public override globalLongSizes;
    mapping(address => uint256) public override globalShortAveragePrices;
    mapping(address => uint256) public override globalLongAveragePrices;
    //maxGlobalLongSizes and maxGlobalShortSizes are stored in bps the true value of 
    //maxGlobalSize is obtained by multiplying these bps values with AUM.
    mapping(address => uint256) public override maxGlobalShortSizes;
    mapping(address => uint256) public override maxGlobalLongSizes;

    event BuyUSDL(
        address account,
        address token,
        uint256 tokenAmount,
        uint256 usdlAmount,
        uint256 feeBasisPoints
    );
    event SellUSDL(
        address account,
        address token,
        uint256 usdlAmount,
        uint256 tokenAmount,
        uint256 feeBasisPoints
    );
    event IncreasePosition(
        bytes32 key,
        address indexed account,
        address indexed collateralToken,
        address indexed indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        int256 fee
    );
    event DecreasePosition(
        address indexed account,
        address collateralToken,
        address indexed indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        int256 fee,
        bool indexed isLiquidated,
        int256 realisedPnl
    );
    event UpdatePosition(
        address indexed account,
        address indexed collateralToken,
        address indexed indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryBorrowingRate,
        int256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );

    event UpdateBorrowingRate(address token, uint256 borrowingRate);
    event UpdateFundingRate(address token, int256 fundingLongRate, int256 fundingShortRate);

    event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(address token, int256 feeUsd, uint256 feeTokens);

    event DirectPoolDeposit(address token, uint256 amount);
    event IncreasePoolAmount(address token, uint256 amount);
    event DecreasePoolAmount(address token, uint256 amount);
    event IncreaseReservedAmount(address token, uint256 amount);
    event DecreaseReservedAmount(address token, uint256 amount);

    // once the parameters are verified to be working correctly,
    // gov should be set to a timelock contract or a governance contract
    constructor() {
        gov = msg.sender;
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _onlyGov() private view {
        _validate(msg.sender == gov, "Vault: forbidden");
    }

    function initialize(
        address _orderManager,
        address _usdl,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _liquidationFactor,
        uint256 _borrowingRateFactor
    ) external {
        _onlyGov();
        _validate(!isInitialized, "Vault: Already Initialized!");
        isInitialized = true;
        orderManagers[_orderManager] = true;
        usdl = _usdl;
        priceFeed = _priceFeed;
        liquidationFeeUsd = _liquidationFeeUsd;
        liquidationFactor = _liquidationFactor;
        borrowingRateFactor = _borrowingRateFactor;
    }


    function setUtils(IUtils _utils) external override {
        _onlyGov();
        utils = _utils;
    }

    function setGov(address newGov) external {
        _onlyGov();
        gov = newGov;
    }

    function setMaxOIImbalance(uint256 _maxOIImbalance, address _token) external {
        _onlyGov();
        maxOIImbalance[_token] = _maxOIImbalance;
    }

    function setCeaseTradingActivity(bool _cease) external override {
        _onlyGov();
        ceaseTradingActivity = _cease;
    }

    function setCeaseLPActivity(bool _cease) external override{
        _onlyGov();
        ceaseLPActivity = _cease;
    }

    function setOrderManager(address newOrderManager, bool _isOrderManager) external {
        _onlyGov();
        orderManagers[newOrderManager] = _isOrderManager;
    }

    function setUsdl(address newUsdl) external {
        _onlyGov();
        usdl = newUsdl;
    }

    function setSafetyFactor(uint256 _safetyFactor) public  {
        _onlyGov();
        safetyFactor = _safetyFactor;
    }   

    function setMaxFundingRateFactor( uint256 _maxFundingRateFactor) public {
        _onlyGov();
        maxFundingRateFactor = _maxFundingRateFactor;
    }

    function setOiImbalanceThreshold( address _token, uint256 _oiImbalanceThreshold) public {
        _onlyGov();
        oiImbalanceThreshold[_token] = _oiImbalanceThreshold;
    }

    function directPoolDeposit(address _token) external override nonReentrant {
        _validate(whitelistedTokens[_token], "Vault: Not a whitelisted token");
        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, "Vault: Invalid tokenAmount");
        _increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount);
    }

    function allWhitelistedTokensLength()
        external
        view
        override
        returns (uint256)
    {
        return allWhitelistedTokens.length;
    }

    function setInManagerMode(bool _inManagerMode) external override {
        _onlyGov();
        inManagerMode = _inManagerMode;
    }

    function setManager(address _manager, bool _isManager) external override {
        _onlyGov();
        isManager[_manager] = _isManager;
    }

    function setInPrivateLiquidationMode(
        bool _inPrivateLiquidationMode
    ) external override {
        _onlyGov();
        inPrivateLiquidationMode = _inPrivateLiquidationMode;
    }

    function setLiquidator(
        address _liquidator,
        bool _isActive
    ) external override {
        _onlyGov();
        isLiquidator[_liquidator] = _isActive;
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external override {
        _onlyGov();
        maxGasPrice = _maxGasPrice;
    }

    function setPriceFeed(address _priceFeed) external override {
        _onlyGov();
        priceFeed = _priceFeed;
    }

    function setMaxLeverage(uint256 _maxLeverage, address _token) external override {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, "Vault: maxLeverage too low");
        maxLeverage[_token] = _maxLeverage;
    }

    function setMaxGlobalShortSize(
        address _token,
        uint256 _amount
    ) external override {
        _onlyGov();
        maxGlobalShortSizes[_token] = _amount;
    }

    function setMaxGlobalLongSize(
        address _token,
        uint256 _amount
    ) external override {
        _onlyGov();
        maxGlobalLongSizes[_token] = _amount;
    }

    function setFees(
        uint256 _mintBurnFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _liquidationFactor,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external override {
        _onlyGov();
        _validate(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "Vault: mintBurnFeeBasisPoints too high");
        _validate(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, "Vault: marginFeeBasisPoints too high");
        _validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, "Vault: liquidationFeeUsd too high");
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        liquidationFactor = _liquidationFactor;
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    function setBorrowingRate(
        uint256 _borrowingInterval,
        uint256 _borrowingRateFactor
    ) external override {
        _onlyGov();
        _validate(_borrowingInterval >= MIN_BORROWING_RATE_INTERVAL, "Vault: borrowingInterval too low");
        _validate(_borrowingRateFactor <= MAX_BORROWING_RATE_FACTOR, "Vault: borrowingRateFactor too high");
        borrowingInterval = _borrowingInterval;
        borrowingRateFactor = _borrowingRateFactor;
    }

    function setFundingRate(
        uint256 _fundingInterval,
        uint256 _fundingRateFactor, 
        uint256 _fundingExponent
    ) external override {
        _onlyGov();
        _validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, "Vault: funding interval too low");
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
        fundingExponent = _fundingExponent;
    }

    // potential shift
    function _validateTokens(
        address _collateralToken,
        address _indexToken
    ) private view {
        _validate(canBeCollateralToken[_collateralToken], "Vault: Invalid collateralToken");
        _validate(canBeIndexToken[_indexToken], "Vault: Invalid indexToken");
    }

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _minProfitBps,
        bool _isStable, 
        bool _canBeCollateralToken,
        bool _canBeIndexToken,
        uint _maxLeverage,
        uint256 _maxOiImbalance
    ) external override {
        _onlyGov();
        // decimal check
        // _validate(_tokenDecimals == IERC20(address(_token)).decimals(), "Vault: token decimals do not match decimals in its ERC20 contract");
        
        // increment token count for the first time
        if (!whitelistedTokens[_token]) {
            allWhitelistedTokens.push(_token);
        }

        whitelistedTokens[_token] = true;
        tokenDecimals[_token] = _tokenDecimals;
        minProfitBasisPoints[_token] = _minProfitBps;
        stableTokens[_token] = _isStable;
        canBeCollateralToken[_token] = _canBeCollateralToken;
        canBeIndexToken[_token] = _canBeIndexToken;
        maxLeverage[_token] = _maxLeverage;
        maxOIImbalance[_token] = _maxOiImbalance;
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance - (prevBalance);
    }

    function updateCumulativeBorrowingRate(address _collateralToken) public {

        (uint256 borrowingTime, uint256 borrowingRate) = utils.updateCumulativeBorrowingRate(lastBorrowingTimes[_collateralToken], borrowingInterval, borrowingRateFactor, poolAmounts[_collateralToken], reservedAmounts[_collateralToken]);

        lastBorrowingTimes[_collateralToken] = borrowingTime;
        cumulativeBorrowingRates[_collateralToken] = cumulativeBorrowingRates[_collateralToken] + (borrowingRate);
        
        emit UpdateBorrowingRate(
            _collateralToken,
            cumulativeBorrowingRates[_collateralToken]
        );
    }

    function updateCumulativeFundingRate(address _indexToken) public {
        (uint lastFundingUpdateTime, int256 fundingLongRate, int256 fundingShortRate) = utils.updateCumulativeFundingRate( fundingRateFactor, _indexToken, lastFundingTimes[_indexToken], fundingInterval);
        cumulativeFundingRatesForLongs[_indexToken] = cumulativeFundingRatesForLongs[_indexToken] + fundingLongRate;
        cumulativeFundingRatesForShorts[_indexToken] = cumulativeFundingRatesForShorts[_indexToken] + fundingShortRate;
        lastFundingTimes[_indexToken] = lastFundingUpdateTime;
        
        emit UpdateFundingRate(
            _indexToken,
            cumulativeFundingRatesForLongs[_indexToken],
            cumulativeFundingRatesForShorts[_indexToken]
        );
    }

    // potential shift
    function buyUSDL(
        address _token,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(!ceaseLPActivity, "Vault: LP activity is suspended");
        _validate(whitelistedTokens[_token], "Vault: Not a whitelisted token");

        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, "Vault: tokenAmount too low");

        uint256 price = getMinPriceOfToken(_token);

        uint256 usdlAmount = (tokenAmount * (price)) / (PRICE_PRECISION);
        usdlAmount = utils.adjustForDecimals(usdlAmount, _token, usdl);
        //this usdl amount is after multiplying with 10^ 18
        _validate(usdlAmount > 0, "Vault: usdlAmount too low");

        // Consider: If not targeting dynamic fees in mainnet than simplyign these function calls for LLP mint/burn fee basis points
        uint256 feeBasisPoints = utils.getBuyUsdlFeeBasisPoints(
            _token,
            usdlAmount
        );

        uint256 amountAfterFees = _collectSwapFees(_token, tokenAmount, feeBasisPoints);
        uint256 mintAmount = (amountAfterFees * (price)) / (PRICE_PRECISION);
        mintAmount = utils.adjustForDecimals(mintAmount, _token, usdl);
        _increasePoolAmount(_token, amountAfterFees);

        IUSDL(usdl).mint(_receiver, mintAmount);

        emit BuyUSDL(
            _receiver,
            _token,
            tokenAmount,
            mintAmount,
            feeBasisPoints
        );
        return mintAmount;
    }

    // potential shift
    function _collectSwapFees(address _token, uint256 _amount, uint256 _feeBasisPoints) private returns (uint256) {
        uint256 afterFeeAmount = _amount*(BASIS_POINTS_DIVISOR-(_feeBasisPoints))/(BASIS_POINTS_DIVISOR);
        uint256 feeAmount = _amount-(afterFeeAmount);
        feeReserves[_token] = feeReserves[_token]+(feeAmount);
        emit CollectSwapFees(_token, utils.tokenToUsdMin(_token, feeAmount), feeAmount);
        return afterFeeAmount;
    }

    function _increasePoolAmount(address _token, uint256 _amount) private {
        poolAmounts[_token] = poolAmounts[_token] + (_amount);
        uint256 balance = IERC20(_token).balanceOf(address(this));
        _validate(poolAmounts[_token] <= balance, "Vault: poolAmount exceedes balance");
        emit IncreasePoolAmount(_token, _amount);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) private {
        require(poolAmounts[_token] >= _amount, "Vault: poolAmount exceeded");
        poolAmounts[_token] = poolAmounts[_token] - (_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], "Vault: reservedAmount exceedes poolAmount");
        emit DecreasePoolAmount(_token, _amount);
    }

    // potential shift
    function sellUSDL(
        address _token,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validate(!ceaseLPActivity, "Vault: LP activity is suspended");
        _validateManager();
        _validate(whitelistedTokens[_token], "Vault: Not a whitelisted token");

        uint256 usdlAmount = _transferIn(usdl);
        _validate(usdlAmount > 0, "Vault: usdlAmount too low");

        uint256 redemptionAmount = utils.getRedemptionAmount(_token, usdlAmount);
        _validate(redemptionAmount > 0, "Vault: redemptionAmount too low");

        _decreasePoolAmount(_token, redemptionAmount);

        IUSDL(usdl).burn(address(this), usdlAmount);

        _updateTokenBalance(usdl);
    
        uint256 feeBasisPoints = utils.getSellUsdlFeeBasisPoints(
            _token,
            usdlAmount
        );
        uint256 amountOut = _collectSwapFees(_token, redemptionAmount, feeBasisPoints);
        _validate(amountOut > 0, "Vault: amountOut too low");

        _transferOut(_token, amountOut, _receiver);

        emit SellUSDL(_receiver, _token, usdlAmount, amountOut, feeBasisPoints);

        return amountOut;
    }

    function _transferOut(
        address _token,
        uint256 _amount,
        address _receiver
    ) private {
        IERC20(_token).safeTransfer(_receiver, _amount);
        tokenBalances[_token] = IERC20(_token).balanceOf(address(this));
    }

    function _updateTokenBalance(address _token) private {
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;
    }

    function getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    )
        public
        view
        override
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            int256,
            uint256,
            uint256,
            bool,
            uint256
        )
    {
        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position memory position = positions[key];
        uint256 realisedPnl = position.realisedPnl > 0
            ? uint256(position.realisedPnl)
            : uint256(-position.realisedPnl);
        return (
            position.size, // 0
            position.collateral, // 1
            position.averagePrice, // 2
            position.entryBorrowingRate, // 3
            position.entryFundingRate,//4
            position.reserveAmount, // 5
            realisedPnl, // 6
            position.realisedPnl >= 0, // 7
            position.lastIncreasedTime // 8
        );
    }

    function getPositionKey(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong
                )
            );
    }

    

    function liquidatePosition(address _account, address _collateralToken, address _indexToken, bool _isLong, address _feeReceiver) external override {
        bytes32 positionKey = getPositionKey(_account, _collateralToken, _indexToken, _isLong);
        liquidatePosition(positionKey, _feeReceiver);
    }

    function liquidatePosition(
        bytes32 key,
        address _feeReceiver
    ) public override nonReentrant {
        if (inPrivateLiquidationMode) {
            _validate(isLiquidator[msg.sender], "Vault: not liquidator");
        }
        Position memory position;
        {
        position = positions[key];
        }
        _validate(position.size > 0, "Vault: no position found");
        updateCumulativeBorrowingRate(position.collateralToken);
        updateCumulativeFundingRate(position.indexToken);

        
        uint256 markPrice = position.isLong ? getMinPriceOfToken(position.indexToken) : getMaxPriceOfToken(position.indexToken);
        int totalFees;
        {
        (uint256 liquidationState, int256 marginFees) = utils.validateLiquidation(
            position.account,
            position.collateralToken,
            position.indexToken,
            position.isLong,
            false,
            markPrice
        );
        _validate(liquidationState != 0, "Vault: position not liquidatable");
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(
                position.account,
                position.collateralToken,
                position.indexToken,
                position.size,
                position.isLong,
                position.account
            );
            return;
        }
        totalFees = marginFees;
        }

        if (position.isLong) {
            globalLongAveragePrices[position.indexToken] = utils.getNextGlobalAveragePrice(position.account, position.collateralToken, position.indexToken, markPrice, position.size, true, false);
        } else {
            globalShortAveragePrices[position.indexToken] = utils.getNextGlobalAveragePrice(position.account, position.collateralToken, position.indexToken, markPrice, position.size, false, false);
        }

        _decreaseReservedAmount(position.collateralToken, position.reserveAmount);
        {
        int actualFeeUsd = totalFees;
        if(actualFeeUsd<0){
            uint actualUpdate;
            (actualFeeUsd, actualUpdate) = updateFeeReserves(totalFees, position.collateralToken);
            _increasePoolAmount(position.collateralToken, actualUpdate);
        } else {
            if (uint(totalFees) <= position.collateral) {
            uint256 remainingCollateral = position.collateral - uint(totalFees);
            _increasePoolAmount(
                position.collateralToken,
                utils.usdToTokenMin(position.collateralToken, remainingCollateral)
            );
            } else {
                actualFeeUsd = int(position.collateral);
            }
            updateFeeReserves(actualFeeUsd, position.collateralToken);
        }
        emit DecreasePosition(position.account, position.collateralToken, position.indexToken, position.size, position.isLong, markPrice, actualFeeUsd, true, position.realisedPnl);
        emit UpdatePosition(
            position.account,
            position.collateralToken,
            position.indexToken,
            position.isLong,
            0,
            0,
            0,
            0,
            0,
            0,
            position.realisedPnl,
            markPrice
        );
        }

        
        if (!position.isLong) {
            _decreaseGlobalShortSize(position.indexToken, position.size);
        } else {
            _decreaseGlobalLongSize(position.indexToken, position.size);
        }

        deletePositionKey(key);

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(
            position.collateralToken,
            utils.usdToTokenMin(position.collateralToken, utils.calcLiquidationFee(position.size, position.indexToken))
        );
        _transferOut(
            position.collateralToken,
            utils.usdToTokenMin(position.collateralToken, utils.calcLiquidationFee(position.size, position.indexToken)),
            _feeReceiver
        );

    }

    function abs(int value) public pure returns(int){
        return value< 0 ? -value: value;
    }

    function updateFeeReserves(int feeUsd, address _collateralToken) internal returns(int, uint){
        uint currentFeeReserves = feeReserves[_collateralToken];
        uint actualUpdateTokens = utils.usdToTokenMin(_collateralToken, uint(abs(feeUsd)));
        int actualFeeTransfer = feeUsd;
        if(feeUsd >=0){
            feeReserves[_collateralToken] = currentFeeReserves + actualUpdateTokens;
        } else {
            if(currentFeeReserves<actualUpdateTokens){
                actualUpdateTokens = currentFeeReserves;
            }
            feeReserves[_collateralToken] = currentFeeReserves - actualUpdateTokens;
            actualFeeTransfer = int(utils.tokenToUsdMin(_collateralToken, actualUpdateTokens));
            actualFeeTransfer = -1 * actualFeeTransfer;
        }
        emit CollectMarginFees(_collateralToken, actualFeeTransfer, actualUpdateTokens);
        return (actualFeeTransfer,actualUpdateTokens);
    }

    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token] + (_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], "Vault: reservedAmount exceedes poolAmount");
        emit IncreaseReservedAmount(_token, _amount);
    }

    function _decreaseReservedAmount(address _token, uint256 _amount) private {
        require(
            reservedAmounts[_token] >= _amount,
            "Vault: insufficient reserve"
        );
        reservedAmounts[_token] = reservedAmounts[_token] - (_amount);
        emit DecreaseReservedAmount(_token, _amount);
    }

    // for longs: nextAveragePrice = (nextPrice * nextSize)/ (nextSize + delta)
    // for shorts: nextAveragePrice = (nextPrice * nextSize) / (nextSize - delta)
    
    function withdrawFees(address _token, address _receiver) external override returns (uint256) {
        _onlyGov();
        uint256 amount = feeReserves[_token];
        if(amount == 0) { return 0; }
        feeReserves[_token] = 0;
        _transferOut(_token, amount, _receiver);
        return amount;
    }

// shift
    function _collectMarginFees(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryBorrowingRate,
        int256 _entryFundingRate
    ) private returns (int256) {
        int256 feeUsd = utils.collectMarginFees(_account, _collateralToken, _indexToken, _isLong, _sizeDelta, _size, _entryBorrowingRate, _entryFundingRate);
        (feeUsd,) = updateFeeReserves(feeUsd, _collateralToken);
        return feeUsd;
    }

    function getPositionKeysList() public view returns(bytes32[] memory){
        return EnumerableSet.values(positionKeys);
    }

    function getAllOpenPositions() public view returns(Position[] memory){
        uint numKeys = EnumerableSet.length(positionKeys);
        Position[] memory _positions = new Position[](numKeys);
        for(uint256 i = 0; i < numKeys; i++) {
            _positions[i] = positions[EnumerableSet.at(positionKeys,i)];
        }
        return _positions;
    }

    function increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external override nonReentrant {
        _validate(!ceaseTradingActivity, "Vault: trade activity is suspended!");
        _validateGasPrice();
        _validateOrderManager(_account);
        _validateTokens(_collateralToken, _indexToken);
        utils.validateIncreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong
        );

        updateCumulativeBorrowingRate(_collateralToken);
        updateCumulativeFundingRate(_indexToken);

        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position storage position = positions[key];

        uint256 price = _isLong ? getMaxPriceOfToken(_indexToken) : getMinPriceOfToken(_indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
            position.account = _account;
            position.collateralToken = _collateralToken;
            position.indexToken = _indexToken;
            position.isLong = _isLong;
            EnumerableSet.add(positionKeys,key);
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = utils.getNextAveragePrice(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                price,
                _sizeDelta,
                position.lastIncreasedTime
            );
        }

        int256 fee = _collectMarginFees(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryBorrowingRate,
            position.entryFundingRate
        );
        uint256 collateralDelta = _transferIn(_collateralToken);
        uint256 collateralDeltaUsd = utils.tokenToUsdMin(
            _collateralToken,
            collateralDelta
        );

        position.collateral = position.collateral + (collateralDeltaUsd);
        if(fee>0){
            _validate(position.collateral >= uint(fee), "Vault: insufficient collateral");
            position.collateral = position.collateral - uint(fee);
        } else {
            position.collateral = position.collateral + uint(-fee);
        }
        position.entryBorrowingRate = utils.getEntryBorrowingRate(
            _collateralToken,
            _indexToken,
            _isLong
        );
        position.entryFundingRate = utils.getEntryFundingRate(_collateralToken, _indexToken, _isLong);
        position.size = position.size + (_sizeDelta);
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, "Vault: size should be > 0");
        utils.validatePosition(position.size, position.collateral);
        utils.validateLiquidation(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            true,
            price
        );

        // reserve tokens to pay profits on the position
        {
        uint256 reserveDelta = utils.usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount = position.reserveAmount + (reserveDelta);
        _increaseReservedAmount(_collateralToken, reserveDelta);
        }

        if (_isLong) {
            if(globalLongSizes[_indexToken] ==0){
                globalLongAveragePrices[_indexToken] = price;
            } else {
                globalLongAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, true, true);
            }
            _increaseGlobalLongSize(_indexToken, _sizeDelta);
        } else {
            if (globalShortSizes[_indexToken] == 0) {
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, false, true);
            }
            _increaseGlobalShortSize(_indexToken, _sizeDelta);
        }

        emit IncreasePosition(
            key,
            _account,
            _collateralToken,
            _indexToken,
            collateralDeltaUsd,
            _sizeDelta,
            _isLong,
            price,
            fee
        );
        emit UpdatePosition(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            position.size,
            position.collateral,
            position.averagePrice,
            position.entryBorrowingRate,
            position.entryFundingRate,
            position.reserveAmount,
            position.realisedPnl,
            price
        );
    }

    function decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validate(!ceaseTradingActivity, "Vault: trade activity is suspended!");
        _validateGasPrice();
        _validateOrderManager(_account);
        return
            _decreasePosition(
                _account,
                _collateralToken,
                _indexToken,
                _sizeDelta,
                _isLong,
                _receiver
            );
    }

    function _increaseGlobalShortSize(
        address _token,
        uint256 _amount
    ) internal {
        uint globalShortSize = globalShortSizes[_token];
        globalShortSize = globalShortSize + (_amount);

        uint256 maxSize = maxGlobalShortSizes[_token]*IUtils(utils).getAum(false)/BASIS_POINTS_DIVISOR;
        require(
            globalShortSize <= maxSize,
            "Vault: max shorts exceeded"
        );
        validateOIImbalance(globalLongSizes[_token], globalShortSize, _token);
        globalShortSizes[_token] = globalShortSize;
    }
    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
            size = 0;
        } else {
            size = size - (_amount);
        }
        globalShortSizes[_token] = size;
    }

    function validateOIImbalance(uint globalLongSize, uint globalShortSize, address _token) view private {
        if(globalLongSize>globalShortSize){
            require(globalLongSize< globalShortSize + maxOIImbalance[_token], "Vault: Max OI breached!");
        } else {
            require(globalShortSize< globalLongSize + maxOIImbalance[_token], "Vault: Max OI breached!");
        }
    }

    function _increaseGlobalLongSize(
        address _token,
        uint256 _amount
    ) internal {
        uint globalLongSize = globalLongSizes[_token];
        globalLongSize = globalLongSize + (_amount);

        uint256 maxSize = maxGlobalLongSizes[_token]*IUtils(utils).getAum(false)/BASIS_POINTS_DIVISOR;
        require(
            globalLongSize <= maxSize,
            "Vault: max longs exceeded"
        );
        validateOIImbalance(globalLongSize, globalShortSizes[_token], _token);
        globalLongSizes[_token] = globalLongSize;

    }

    function _decreaseGlobalLongSize(address _token, uint256 _amount) private {
        uint256 size = globalLongSizes[_token];
        if (_amount > size) {
            size = 0;
        } else {
            size = size - (_amount);
        }
        globalLongSizes[_token] = size;
    }

    function _decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) private returns (uint256) {
        utils.validateDecreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _receiver
        );
        updateCumulativeBorrowingRate(_collateralToken);
        updateCumulativeFundingRate(_indexToken);
        Position storage position;
        {
        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        position = positions[key];
        }
        _validate(position.size > 0, "Vault: no position found");
        _validate(position.size >= _sizeDelta, "Vault: decrease position size too large");

        // scrop variables to avoid stack too deep errors
        {
            uint256 reserveDelta = (position.reserveAmount * (_sizeDelta)) /
                (position.size);
            position.reserveAmount = position.reserveAmount - (reserveDelta);
            _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        uint256 price = _isLong ? getMinPriceOfToken(_indexToken) : getMaxPriceOfToken(_indexToken);
        uint amountOutAfterFees;
        {
        (int fee, uint256 usdOutAfterFee, int256 signedDelta) = _reduceCollateral(
            _account,
            _collateralToken,
            _indexToken,
            0,
            _sizeDelta,
            _isLong
        );
        if (usdOutAfterFee > 0) {
            amountOutAfterFees = utils.usdToTokenMin(
                _collateralToken,
                usdOutAfterFee
            );
            _transferOut(_collateralToken, amountOutAfterFees, _receiver);
        }
        emit DecreasePosition(
                _account,
                _collateralToken,
                _indexToken,
                _sizeDelta,
                _isLong,
                price,
                fee,
                false,
                signedDelta
        );
        }

        if (_isLong) {
            globalLongAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, true, false);
        } else {
            globalShortAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, false, false);
        }

        if (position.size != _sizeDelta) {
            position.entryBorrowingRate = utils.getEntryBorrowingRate(
                _collateralToken,
                _indexToken,
                _isLong
            );
            position.entryFundingRate = utils.getEntryFundingRate(_collateralToken, _indexToken, _isLong);
            position.size = position.size - (_sizeDelta);

            utils.validatePosition(position.size, position.collateral);
            utils.validateLiquidation(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                true,
                price
            );
            
        } else {
            bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
            deletePositionKey(key);
        }
        emit UpdatePosition(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryBorrowingRate,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl,
                price
            );

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        } else {
            _decreaseGlobalLongSize(_indexToken, _sizeDelta);
        }

        return amountOutAfterFees;
    }

    function deletePositionKey(bytes32 _key) private {
        EnumerableSet.remove(positionKeys, _key);
        delete positions[_key];
    }

    function _reduceCollateral(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (int256, uint256, int256 ) {
        Position storage position ;
        {
        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        position = positions[key];
        }

        int256 fee = _collectMarginFees(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryBorrowingRate,
            position.entryFundingRate
        );
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            uint256 markPrice = _isLong ? getMinPriceOfToken(_indexToken) : getMaxPriceOfToken(_indexToken);
            address indexToken = _indexToken;
            bool isLong = _isLong;
            (bool _hasProfit, uint256 delta) = utils.getDelta(
                indexToken,
                position.size,
                position.averagePrice,
                markPrice,
                isLong,
                position.lastIncreasedTime
            );
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = (_sizeDelta * (delta)) / (position.size);
        }

        uint256 usdOut;
        // transfer profits out
        {
            address collateralToken = _collateralToken;
            if (hasProfit) {
                usdOut = adjustedDelta;
                position.realisedPnl = position.realisedPnl + int256(adjustedDelta);
                uint256 tokenAmount = utils.usdToTokenMin(collateralToken, adjustedDelta);
                _decreasePoolAmount(collateralToken, tokenAmount);
            }
            if (!hasProfit) {
                position.collateral = position.collateral - (adjustedDelta);
                uint256 tokenAmount = utils.usdToTokenMin(collateralToken, adjustedDelta);
                _increasePoolAmount(collateralToken, tokenAmount);
                position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
            }
        }

        // reduce the position's collateral by _collateralDelta
        // transfer _collateralDelta out
        if (_collateralDelta > 0) {
            usdOut = usdOut + (_collateralDelta);
            position.collateral = position.collateral - (_collateralDelta);
        }

        // if the position will be closed, then transfer the remaining collateral out
        if (position.size == _sizeDelta) {
            usdOut = usdOut + (position.collateral);
            position.collateral = 0;
        }

        // if the usdOut is more than the fee then deduct the fee from the usdOut directly
        // else deduct the fee from the position's collateral
        uint256 usdOutAfterFee;
        if(fee<0){
            usdOutAfterFee = usdOut + uint(abs(fee));
        } else{
            if (usdOut > uint(fee)) {
                usdOutAfterFee = usdOut - uint(fee);
            } else {
                uint remainingFee = uint(fee) - usdOut;
                position.collateral = position.collateral - remainingFee; // Revist to check for fee > position.collateral
            }
        }
        int signedDelta = hasProfit ? int(adjustedDelta) : -1 * int(adjustedDelta);
        return (fee, usdOutAfterFee, signedDelta);
    }
    

    function _validate(bool _condition, string memory errorMessage) private pure {
        require(_condition, errorMessage);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        if (inManagerMode) {
            _validate(isManager[msg.sender], "Vault: not manager");
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (maxGasPrice == 0) {
            return;
        }
        _validate(tx.gasprice <= maxGasPrice, "Vault: gas price too high");
    }

    function _validateOrderManager(address _account) private view {
        if (msg.sender == _account) {
            return;
        }
        _validate(orderManagers[msg.sender] == true, "Vault: OrderManager not approved");
    }

    function getMinPriceOfToken(address _token) public view returns(uint256){
        return IPriceFeed(priceFeed).getMinPriceOfToken(_token);
    }
    function getMaxPriceOfToken(address _token) public view returns(uint256){
        return IPriceFeed(priceFeed).getMaxPriceOfToken(_token);
    }
}
