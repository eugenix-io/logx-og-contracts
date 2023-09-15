// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../libraries/token/IERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IUtils.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/IUSDL.sol";
import "../access/Governable.sol";

contract Vault is ReentrancyGuard, IVault {

    struct Position {
        address account;
        address collateralToken;
        address indexToken;
        bool isLong;
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant MIN_LEVERAGE = 10000; // 1x
    uint256 public constant USDL_DECIMALS = 18;
    uint256 public constant MAX_FEE_BASIS_POINTS = 500; // 5%
    uint256 public constant MAX_LIQUIDATION_FEE_USD = 100 * PRICE_PRECISION; // 100 USD
    uint256 public constant MIN_FUNDING_RATE_INTERVAL = 1 hours;
    uint256 public constant MAX_FUNDING_RATE_FACTOR = 10000; // 1%

    bool public override isInitialized;
    address public usdc;

    IUtils public utils;

    address public override orderManager;
    address public override priceFeed;

    address public override usdl;
    address public override gov;

    uint256 public override maxLeverage = 50 * 10000; // 50x

    uint256 public override liquidationFeeUsd;
    uint256 public override mintBurnFeeBasisPoints = 30; // 0.3%
    uint256 public override marginFeeBasisPoints = 10; // 0.1%

    uint256 public override minProfitTime;
    bool public override hasDynamicFees = false;

    uint256 public override fundingInterval = 8 hours;
    uint256 public override fundingRateFactor;
    uint256 public override stableFundingRateFactor;

    bool public override inManagerMode = false;
    bool public override inPrivateLiquidationMode = false;

    uint256 public override maxGasPrice;
    uint256 public override maxExposurePerUser;
    uint256 public maxLiquidityPerUser;
    uint256 public safetyFactor;

    mapping(address => bool) public override isLiquidator;
    mapping(address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => bool) public override canBeIndexToken;
    mapping(address => bool) public override canBeCollateralToken;
    mapping(address => uint256) public override tokenDecimals;
    mapping(address => uint256) public override minProfitBasisPoints;
    mapping(address => bool) public override stableTokens;

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

    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping(address => uint256) public override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping(address => uint256) public override lastFundingTimes;
    

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;
    bytes32[] public positionKeys;

    // feeReserves tracks the amount of fees per token
    mapping(address => uint256) public override feeReserves;

    mapping(address => uint256) public override globalShortSizes;
    mapping(address => uint256) public override globalLongSizes;
    mapping(address => uint256) public override globalShortAveragePrices;
    mapping(address => uint256) public override globalLongAveragePrices;
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
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event DecreasePosition(
        bytes32 key,
        address account,
        address collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        uint256 price,
        uint256 fee
    );
    event LiquidatePosition(
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event UpdatePosition(
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );
    event ClosePosition(
        address account,
        address collateralToken,
        address indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryFundingRate,
        uint256 reserveAmount,
        int256 realisedPnl
    );

    event UpdateFundingRate(address token, uint256 fundingRate);
    event UpdatePnl(bytes32 key, bool hasProfit, uint256 delta);

    event CollectSwapFees(address token, uint256 feeUsd, uint256 feeTokens);
    event CollectMarginFees(address token, uint256 feeUsd, uint256 feeTokens);

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
        uint256 _fundingRateFactor,
        address _usdc
    ) external {
        _onlyGov();
        _validate(!isInitialized, "Vault: Already Initialized!");
        isInitialized = true;
        orderManager = _orderManager;
        usdl = _usdl;
        priceFeed = _priceFeed;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
        usdc = _usdc;
    }

    function setUtils(IUtils _utils) external override {
        _onlyGov();
        utils = _utils;
    }

    function setGov(address newGov) external {
        _onlyGov();
        gov = newGov;
    }

    function setOrderManager(address newOrderManager) external {
        _onlyGov();
        orderManager = newOrderManager;
    }

    function setUsdl(address newUsdl) external {
        _onlyGov();
        usdl = newUsdl;
    }

    function setMaxExposurePerUser(uint256 _maxExposurePerUser) public  {
        maxExposurePerUser = _maxExposurePerUser;
        
    }

    function setMaxLiquidityPerUser(uint256 _maxLiquidityPerUser) public  {
        maxLiquidityPerUser = _maxLiquidityPerUser;
        
    }

    function setSafetyFactor(uint256 _safetyFactor) public  {
        safetyFactor = _safetyFactor;
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

    function setMaxLeverage(uint256 _maxLeverage) external override {
        _onlyGov();
        _validate(_maxLeverage > MIN_LEVERAGE, "Vault: maxLeverage too low");
        maxLeverage = _maxLeverage;
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
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    function setFundingRate(
        uint256 _fundingInterval,
        uint256 _fundingRateFactor
    ) external override {
        _onlyGov();
        _validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, "Vault: fundingInterval too low");
        _validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, "Vault: fundingRateFactor too high");
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
    }


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
        bool _canBeIndexToken
    ) external override {
        _onlyGov();
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
        //TODO: add a check to see if number of decimals given is same as number of decimals on IERC20  contract.

        // validate price feed
        getMaxPrice(_token);
    }

    function getMaxPrice(
        address _token
    ) public view override returns (uint256) {
        return
            IPriceFeed(priceFeed).getMaxPriceOfToken(
                _token
            );
    }

    function getMinPrice(
        address _token
    ) public view override returns (uint256) {
        return
            IPriceFeed(priceFeed).getMinPriceOfToken(
                _token
            );
    }

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance - (prevBalance);
    }

    function updateCumulativeFundingRate(
        address _collateralToken
    ) public {

        if (lastFundingTimes[_collateralToken] == 0) {
            lastFundingTimes[_collateralToken] =
                (block.timestamp / (fundingInterval)) *
                (fundingInterval);
            return;
        }

        if (
            lastFundingTimes[_collateralToken] + (fundingInterval) >
            block.timestamp
        ) {
            return;
        }

        uint256 fundingRate = getNextFundingRate(_collateralToken);
        cumulativeFundingRates[_collateralToken] =
            cumulativeFundingRates[_collateralToken] +
            (fundingRate);
        lastFundingTimes[_collateralToken] =
            (block.timestamp / (fundingInterval)) *
            (fundingInterval);

        emit UpdateFundingRate(
            _collateralToken,
            cumulativeFundingRates[_collateralToken]
        );
    }

    function getNextFundingRate(
        address _token
    ) public view override returns (uint256) {
        if (lastFundingTimes[_token] + (fundingInterval) > block.timestamp) {
            return 0;
        }

        uint256 intervals = (block.timestamp - lastFundingTimes[_token]) / (fundingInterval);
        uint256 poolAmount = poolAmounts[_token];
        if (poolAmount == 0) {
            return 0;
        }

        uint256 _fundingRateFactor = stableTokens[_token]
            ? stableFundingRateFactor
            : fundingRateFactor;
        return
            (_fundingRateFactor * (reservedAmounts[_token]) * (intervals)) /
            (poolAmount);
    }

    function buyUSDL(
        address _token,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(whitelistedTokens[_token], "Vault: Not a whitelisted token");

        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, "Vault: tokenAmount too low");

        uint256 price = getMinPrice(_token);

        uint256 usdlAmount = (tokenAmount * (price)) / (PRICE_PRECISION);
        usdlAmount = utils.adjustForDecimals(usdlAmount, _token, usdl);
        _validate(usdlAmount > 0, "Vault: usdlAmount too low");

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

    function _collectSwapFees(address _token, uint256 _amount, uint256 _feeBasisPoints) private returns (uint256) {
        uint256 afterFeeAmount = _amount*(BASIS_POINTS_DIVISOR-(_feeBasisPoints))/(BASIS_POINTS_DIVISOR);
        uint256 feeAmount = _amount-(afterFeeAmount);
        feeReserves[_token] = feeReserves[_token]+(feeAmount);
        emit CollectSwapFees(_token, tokenToUsdMin(_token, feeAmount), feeAmount);
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

    function getRedemptionAmount(
        address _token,
        uint256 _usdlAmount
    ) public view override returns (uint256) {
        uint256 price = getMaxPrice(_token);
        uint256 redemptionAmount = (_usdlAmount * (PRICE_PRECISION)) / (price);
        return utils.adjustForDecimals(redemptionAmount, usdl, _token);
    }

    function sellUSDL(
        address _token,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(whitelistedTokens[_token], "Vault: Not a whitelisted token");

        uint256 usdlAmount = _transferIn(usdl);
        _validate(usdlAmount > 0, "Vault: usdlAmount too low");

        uint256 redemptionAmount = getRedemptionAmount(_token, usdlAmount);
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
        IERC20(_token).transfer(_receiver, _amount);
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
            position.entryFundingRate, // 3
            position.reserveAmount, // 4
            realisedPnl, // 5
            position.realisedPnl >= 0, // 6
            position.lastIncreasedTime // 7
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

    function tokenToUsdMin(
        address _token,
        uint256 _tokenAmount
    ) public view override returns (uint256) {
        if (_tokenAmount == 0) {
            return 0;
        }
        uint256 price = getMinPrice(_token);
        uint256 decimals = tokenDecimals[_token];
        return (_tokenAmount * (price)) / (10 ** decimals);
    }

    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        address _feeReceiver
    ) external override nonReentrant {
        if (inPrivateLiquidationMode) {
            _validate(isLiquidator[msg.sender], "Vault: not liquidator");
        }


        updateCumulativeFundingRate(_collateralToken);
        Position memory position;
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

        (uint256 liquidationState, uint256 marginFees) = utils.validateLiquidation(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            false
        );
        _validate(liquidationState != 0, "Vault: position not liquidatable");
        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            _decreasePosition(
                _account,
                _collateralToken,
                _indexToken,
                0,
                position.size,
                _isLong,
                _account
            );
            return;
        }

        if (_isLong) {
            globalLongAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, markPrice, position.size, true, false);
        } else {
            globalShortAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, markPrice, position.size, false, false);
        }

        uint256 feeTokens = usdToTokenMin(_collateralToken, marginFees);
        feeReserves[_collateralToken] =
            feeReserves[_collateralToken] +
            (feeTokens);
        emit CollectMarginFees(_collateralToken, marginFees, feeTokens);

        _decreaseReservedAmount(_collateralToken, position.reserveAmount);

        emit LiquidatePosition(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            position.size,
            position.collateral,
            position.reserveAmount,
            position.realisedPnl,
            markPrice
        );

        emit UpdatePosition(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            0,
            0,
            0,
            0,
            0,
            position.realisedPnl,
            0
        );

        if (marginFees < position.collateral) {
            uint256 remainingCollateral = position.collateral - (marginFees);
            _increasePoolAmount(
                _collateralToken,
                usdToTokenMin(_collateralToken, remainingCollateral)
            );
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, position.size);
        } else {
            _decreaseGlobalLongSize(_indexToken, position.size);
        }

        deletePositionKey(getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        ));

        // pay the fee receiver using the pool, we assume that in general the liquidated amount should be sufficient to cover
        // the liquidation fees
        _decreasePoolAmount(
            _collateralToken,
            usdToTokenMin(_collateralToken, liquidationFeeUsd)
        );
        _transferOut(
            _collateralToken,
            usdToTokenMin(_collateralToken, liquidationFeeUsd),
            _feeReceiver
        );

    }

    function usdToTokenMin(
        address _token,
        uint256 _usdAmount
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    //100015345354437731381
    //210000000000000000000

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

    function getFeeBasisPoints(address _token, uint256 _usdlDelta, uint256 _feeBasisPoints, bool _increment) public override view returns (uint256) {
        return utils.getFeeBasisPoints(_token, _usdlDelta, _feeBasisPoints, _increment);
    }

    function _collectMarginFees(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryFundingRate
    ) private returns (uint256) {
        uint256 feeUsd = getPositionFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta
        );

        uint256 fundingFee = getFundingFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _size,
            _entryFundingRate
        );
        feeUsd = feeUsd + (fundingFee);

        uint256 feeTokens = usdToTokenMin(_collateralToken, feeUsd);
        feeReserves[_collateralToken] =
            feeReserves[_collateralToken] +
            (feeTokens);

        emit CollectMarginFees(_collateralToken, feeUsd, feeTokens);
        return feeUsd;
    }

    function getPositionFee(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) public view returns (uint256) {
        return
            utils.getPositionFee(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                _sizeDelta
            );
    }

    function getFundingFee(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _size,
        uint256 _entryFundingRate
    ) public view returns (uint256) {
        return
            utils.getFundingFee(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                _size,
                _entryFundingRate
            );
    }

    function getEntryFundingRate(
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public view returns (uint256) {
        return
            utils.getEntryFundingRate(
                _collateralToken,
                _indexToken,
                _isLong
            );
    }

    //TODO: move to utils
    function _validatePosition(
        uint256 _size,
        uint256 _collateral
    ) private view {
        if (_size == 0) {
            _validate(_collateral == 0, "Vault: collateral should be 0");
            return;
        }
        _validate(_size >= _collateral, "Vault: collateral exceeds size");
    }

    //TODO: move to utils
    function usdToTokenMax(
        address _token,
        uint256 _usdAmount
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    //TODO: move to utils
    function usdToToken(
        address _token,
        uint256 _usdAmount,
        uint256 _price
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        uint256 decimals = tokenDecimals[_token];
        return (_usdAmount * (10 ** decimals)) / (_price);
    }

    function getPositionKeysList() public view returns(bytes32[] memory){
        return positionKeys;
    }

    function getAllOpenPositions() public view returns(Position[] memory){
        Position[] memory _positions = new Position[](positionKeys.length);
        for(uint256 i = 0; i < positionKeys.length; i++) {
            _positions[i] = positions[positionKeys[i]];
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

        updateCumulativeFundingRate(_collateralToken);

        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position storage position = positions[key];

        uint256 price = _isLong ? getMaxPrice(_indexToken) : getMinPrice(_indexToken);

        if (position.size == 0) {
            position.averagePrice = price;
            position.account = _account;
            position.collateralToken = _collateralToken;
            position.indexToken = _indexToken;
            position.isLong = _isLong;
            positionKeys.push(key);
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

        uint256 fee = _collectMarginFees(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        uint256 collateralDelta = _transferIn(_collateralToken);
        uint256 collateralDeltaUsd = tokenToUsdMin(
            _collateralToken,
            collateralDelta
        );

        position.collateral = position.collateral + (collateralDeltaUsd);
        _validate(position.collateral >= fee, "Vault: insufficient collateral");

        position.collateral = position.collateral - (fee);
        position.entryFundingRate = getEntryFundingRate(
            _collateralToken,
            _indexToken,
            _isLong
        );
        position.size = position.size + (_sizeDelta);
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, "Vault: size should be > 0");
        _validatePosition(position.size, position.collateral);
        utils.validateLiquidation(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            true
        );

        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);
        position.reserveAmount = position.reserveAmount + (reserveDelta);
        _increaseReservedAmount(_collateralToken, reserveDelta);

        if (_isLong) {
            if(globalLongSizes[_indexToken] ==0){
                globalLongAveragePrices[_indexToken] = price;
            } else {
                globalLongAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, true, true);
            }
            _increaseGlobalLongSize(_indexToken, _sizeDelta);

        } else {
            if (globalShortSizes[_indexToken] == 0) {//--etherscan-api-key "abc"
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
        _validateGasPrice();
        _validateOrderManager(_account);
        return
            _decreasePosition(
                _account,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                _receiver
            );
    }

    function _increaseGlobalShortSize(
        address _token,
        uint256 _amount
    ) internal {
        globalShortSizes[_token] = globalShortSizes[_token] + (_amount);

        uint256 maxSize = maxGlobalShortSizes[_token];
        if (maxSize != 0) {
            require(
                globalShortSizes[_token] <= maxSize,
                "Vault: max shorts exceeded"
            );
        }
    }
    function _decreaseGlobalShortSize(address _token, uint256 _amount) private {
        uint256 size = globalShortSizes[_token];
        if (_amount > size) {
            globalShortSizes[_token] = 0;
            return;
        }

        globalShortSizes[_token] = size - (_amount);
    }

    function _increaseGlobalLongSize(
        address _token,
        uint256 _amount
    ) internal {
        globalLongSizes[_token] = globalLongSizes[_token] + (_amount);

        uint256 maxSize = maxGlobalLongSizes[_token];
        if (maxSize != 0) {
            require(
                globalLongSizes[_token] <= maxSize,
                "Vault: max longs exceeded"
            );
        }
    }

    function _decreaseGlobalLongSize(address _token, uint256 _amount) private {
        uint256 size = globalLongSizes[_token];
        if (_amount > size) {
            globalLongSizes[_token] = 0;
            return;
        }

        globalLongSizes[_token] = size - (_amount);
    }

    function _decreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) private returns (uint256) {
        utils.validateDecreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver
        );
        updateCumulativeFundingRate(_collateralToken);

        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position storage position = positions[key];
        _validate(position.size > 0, "Vault: no position found");
        _validate(position.size >= _sizeDelta, "Vault: decrease position size too large");
        _validate(position.collateral >= _collateralDelta, "Vault: decrease position collateral too large");

        // scrop variables to avoid stack too deep errors
        {
            uint256 reserveDelta = (position.reserveAmount * (_sizeDelta)) /
                (position.size);
            position.reserveAmount = position.reserveAmount - (reserveDelta);
            _decreaseReservedAmount(_collateralToken, reserveDelta);
        }

        (uint256 usdOut, uint256 usdOutAfterFee) = _reduceCollateral(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong
        );

        uint256 price = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);

        if (_isLong) {
            globalLongAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, true, false);
        } else {
            globalShortAveragePrices[_indexToken] = utils.getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, false, false);
        }

        if (position.size != _sizeDelta) {
            position.entryFundingRate = getEntryFundingRate(
                _collateralToken,
                _indexToken,
                _isLong
            );
            position.size = position.size - (_sizeDelta);

            _validatePosition(position.size, position.collateral);
            utils.validateLiquidation(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                true
            );

            emit DecreasePosition(
                key,
                _account,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                price,
                usdOut - (usdOutAfterFee)
            );
            emit UpdatePosition(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl,
                price
            );
        } else {
            emit DecreasePosition(
                key,
                _account,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                price,
                usdOut - (usdOutAfterFee)
            );
            emit UpdatePosition(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                0,
                0,
                0,
                0,
                0,
                0,
                price
            );
            emit ClosePosition(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                position.size,
                position.collateral,
                position.averagePrice,
                position.entryFundingRate,
                position.reserveAmount,
                position.realisedPnl
            );

            deletePositionKey(key);
        }

        if (!_isLong) {
            _decreaseGlobalShortSize(_indexToken, _sizeDelta);
        } else {
            _decreaseGlobalLongSize(_indexToken, _sizeDelta);
        }

        if (usdOut > 0) {
            uint256 amountOutAfterFees = usdToTokenMin(
                _collateralToken,
                usdOutAfterFee
            );
            _transferOut(_collateralToken, amountOutAfterFees, _receiver);
            return amountOutAfterFees;
        }

        return 0;
    }

    function deletePositionKey(bytes32 _key) private {
        uint size = positionKeys.length;
        for(uint i=0;i<size;i++){
            if(positionKeys[i] == _key){
                positionKeys[i] = positionKeys[positionKeys.length-1];
                positionKeys.pop();
                break;
            }
        }
        delete positions[_key];
    }

    function _reduceCollateral(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong
    ) private returns (uint256, uint256) {
        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position storage position = positions[key];

        uint256 fee = _collectMarginFees(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta,
            position.size,
            position.entryFundingRate
        );
        bool hasProfit;
        uint256 adjustedDelta;

        // scope variables to avoid stack too deep errors
        {
            (bool _hasProfit, uint256 delta) = utils.getDelta(
                _indexToken,
                position.size,
                position.averagePrice,
                _isLong,
                position.lastIncreasedTime
            );
            hasProfit = _hasProfit;
            // get the proportional change in pnl
            adjustedDelta = (_sizeDelta * (delta)) / (position.size);
        }

        uint256 usdOut;
        // transfer profits out
        if (hasProfit) {
            usdOut = adjustedDelta;
            position.realisedPnl = position.realisedPnl + int256(adjustedDelta);
            uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
            _decreasePoolAmount(_collateralToken, tokenAmount);
        }

        if (!hasProfit) {
            position.collateral = position.collateral - (adjustedDelta);
            uint256 tokenAmount = usdToTokenMin(_collateralToken, adjustedDelta);
            _increasePoolAmount(_collateralToken, tokenAmount);
            position.realisedPnl = position.realisedPnl - int256(adjustedDelta);
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
        uint256 usdOutAfterFee = usdOut;
        if (usdOut > fee) {
            usdOutAfterFee = usdOut - (fee);
        } else {
            position.collateral = position.collateral - (fee);
        }

        emit UpdatePnl(key, hasProfit, adjustedDelta);

        return (usdOut, usdOutAfterFee);
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
        _validate(msg.sender == orderManager, "Vault: OrderManager not approved");
    }

    //function is added only for testing purposes to prevent locking of funds. 
    //Main-net will not have this function.
    function withdrawFunds(address _token) external {
        _onlyGov();
        uint balance  = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(gov, balance);
    }
}
