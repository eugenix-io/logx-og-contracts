// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IPriceFeed.sol";
import "./interfaces/IUSDL.sol";
import "../access/Governable.sol";

contract Vault is ReentrancyGuard, IVault {
    using SafeERC20 for IERC20;

    struct Position {
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
    uint256 public constant MAX_INT256 = uint256(type(int256).max);

    bool public override isInitialized;
    bool public override isLeverageEnabled = true;
    address public usdc;

    IVaultUtils public vaultUtils;

    address public errorController;

    address public override router;
    address public override priceFeed;

    address public override usdl;
    address public override gov;

    uint256 public override maxLeverage = 50 * 10000; // 50x

    uint256 public override liquidationFeeUsd;
    uint256 public override taxBasisPoints = 50; // 0.5%
    uint256 public override stableTaxBasisPoints = 20; // 0.2%
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

    mapping(address => mapping(address => bool))
        public
        override approvedRouters;
    mapping(address => bool) public override isLiquidator;
    mapping(address => bool) public override isManager;

    address[] public override allWhitelistedTokens;

    mapping(address => bool) public override whitelistedTokens;
    mapping(address => uint256) public override tokenDecimals;
    mapping(address => uint256) public override minProfitBasisPoints;
    mapping(address => bool) public override stableTokens;
    mapping(address => bool) public override shortableTokens;

    // tokenBalances is used only to determine _transferIn values
    mapping(address => uint256) public override tokenBalances;

    // poolAmounts tracks the number of received tokens that can be used for leverage
    // this is tracked separately from tokenBalances to exclude funds that are deposited as margin collateral
    mapping(address => uint256) public override poolAmounts;

    // reservedAmounts tracks the number of tokens reserved for open leverage positions
    mapping(address => uint256) public override reservedAmounts;

    // cumulativeFundingRates tracks the funding rates based on utilization
    mapping(address => uint256) public override cumulativeFundingRates;
    // lastFundingTimes tracks the last time funding was updated for a token
    mapping(address => uint256) public override lastFundingTimes;

    // positions tracks all open positions
    mapping(bytes32 => Position) public positions;

    // feeReserves tracks the amount of fees per token
    mapping(address => uint256) public override feeReserves;

    mapping(address => uint256) public override globalShortSizes;
    mapping(address => uint256) public override globalLongSizes;
    mapping(address => uint256) public override globalShortAveragePrices;
    mapping(address => uint256) public override globalLongAveragePrices;
    mapping(address => uint256) public override maxGlobalShortSizes;
    mapping(address => uint256) public override maxGlobalLongSizes;
    //AnirudhTodo - change erros and error messages according to the updated code.
    mapping(uint256 => string) public errors;
    mapping(address => uint256) public bufferAmounts;

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
    event Swap(
        address account,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 amountOutAfterFees,
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
        _validate(msg.sender == gov, 53);
    }

    function initialize(
        address _router,
        address _usdl,
        address _priceFeed,
        uint256 _liquidationFeeUsd,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor,
        address _usdc
    ) external {
        _onlyGov();
        _validate(!isInitialized, 1);
        isInitialized = true;
        router = _router;
        usdl = _usdl;
        priceFeed = _priceFeed;
        liquidationFeeUsd = _liquidationFeeUsd;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
        usdc = _usdc;
    }

    function setVaultUtils(IVaultUtils _vaultUtils) external override {
        _onlyGov();
        vaultUtils = _vaultUtils;
    }

    function setGov(address newGov) external {
        _onlyGov();
        gov = newGov;
    }

    // deposit into the pool without minting USDL tokens
    // useful in allowing the pool to become over-collaterised
    function directPoolDeposit(address _token) external override nonReentrant {
        _validate(whitelistedTokens[_token], 14);
        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 15);
        _increasePoolAmount(_token, tokenAmount);
        emit DirectPoolDeposit(_token, tokenAmount);
    }

    function setErrorController(address _errorController) external {
        _onlyGov();
        errorController = _errorController;
    }

    function setError(
        uint256 _errorCode,
        string calldata _error
    ) external override {
        require(
            msg.sender == errorController,
            "Vault: invalid errorController"
        );
        errors[_errorCode] = _error;
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

    function setIsLeverageEnabled(bool _isLeverageEnabled) external override {
        _onlyGov();
        isLeverageEnabled = _isLeverageEnabled;
    }

    //anirudhDoubt: what is the need for maxGasPrice
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
        _validate(_maxLeverage > MIN_LEVERAGE, 2);
        maxLeverage = _maxLeverage;
    }

    function setBufferAmount(
        address _token,
        uint256 _amount
    ) external override {
        _onlyGov();
        bufferAmounts[_token] = _amount;
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
        uint256 _taxBasisPoints,
        uint256 _stableTaxBasisPoints,
        uint256 _mintBurnFeeBasisPoints,
        uint256 _marginFeeBasisPoints,
        uint256 _liquidationFeeUsd,
        uint256 _minProfitTime,
        bool _hasDynamicFees
    ) external override {
        _onlyGov();
        _validate(_taxBasisPoints <= MAX_FEE_BASIS_POINTS, 3);
        _validate(_stableTaxBasisPoints <= MAX_FEE_BASIS_POINTS, 4);
        _validate(_mintBurnFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 5);
        _validate(_marginFeeBasisPoints <= MAX_FEE_BASIS_POINTS, 8);
        _validate(_liquidationFeeUsd <= MAX_LIQUIDATION_FEE_USD, 9);
        taxBasisPoints = _taxBasisPoints;
        stableTaxBasisPoints = _stableTaxBasisPoints;
        mintBurnFeeBasisPoints = _mintBurnFeeBasisPoints;
        marginFeeBasisPoints = _marginFeeBasisPoints;
        liquidationFeeUsd = _liquidationFeeUsd;
        minProfitTime = _minProfitTime;
        hasDynamicFees = _hasDynamicFees;
    }

    function setFundingRate(
        uint256 _fundingInterval,
        uint256 _fundingRateFactor,
        uint256 _stableFundingRateFactor
    ) external override {
        _onlyGov();
        _validate(_fundingInterval >= MIN_FUNDING_RATE_INTERVAL, 10);
        _validate(_fundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 11);
        _validate(_stableFundingRateFactor <= MAX_FUNDING_RATE_FACTOR, 12);
        fundingInterval = _fundingInterval;
        fundingRateFactor = _fundingRateFactor;
        stableFundingRateFactor = _stableFundingRateFactor;
    }


    function _validateTokens(
        address _collateralToken,
        address _indexToken
    ) private view {
        _validate(_collateralToken == usdc, 42);
        _validate(whitelistedTokens[_indexToken], 43);
        _validate(shortableTokens[_indexToken], 48);//AnirudhTodo-check this only if isShort
    }

    function setTokenConfig(
        address _token,
        uint256 _tokenDecimals,
        uint256 _minProfitBps,
        bool _isStable,
        bool _isShortable
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
        shortableTokens[_token] = _isShortable;

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
    //210

    function _transferIn(address _token) private returns (uint256) {
        uint256 prevBalance = tokenBalances[_token];
        uint256 nextBalance = IERC20(_token).balanceOf(address(this));
        tokenBalances[_token] = nextBalance;

        return nextBalance - (prevBalance);
    }

    function updateCumulativeFundingRate(
        address _collateralToken,
        address _indexToken
    ) public {
        bool shouldUpdate = vaultUtils.updateCumulativeFundingRate(
            _collateralToken,
            _indexToken
        );
        if (!shouldUpdate) {
            return;
        }

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

    function adjustForDecimals(
        uint256 _amount,
        address _tokenDiv,
        address _tokenMul
    ) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == usdl
            ? USDL_DECIMALS
            : tokenDecimals[_tokenDiv];
        uint256 decimalsMul = _tokenMul == usdl
            ? USDL_DECIMALS
            : tokenDecimals[_tokenMul];
        return (_amount * (10 ** decimalsMul)) / (10 ** decimalsDiv);
    }

    function buyUSDL(
        address _token,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(whitelistedTokens[_token], 16);

        uint256 tokenAmount = _transferIn(_token);
        _validate(tokenAmount > 0, 17);

        uint256 price = getMinPrice(_token);

        uint256 usdlAmount = (tokenAmount * (price)) / (PRICE_PRECISION);
        usdlAmount = adjustForDecimals(usdlAmount, _token, usdl);
        _validate(usdlAmount > 0, 18);

        uint256 feeBasisPoints = vaultUtils.getBuyUsdlFeeBasisPoints(
            _token,
            usdlAmount
        );

        uint256 amountAfterFees = _collectSwapFees(_token, tokenAmount, feeBasisPoints);
        uint256 mintAmount = (amountAfterFees * (price)) / (PRICE_PRECISION);
        mintAmount = adjustForDecimals(mintAmount, _token, usdl);
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
        _validate(poolAmounts[_token] <= balance, 49);
        emit IncreasePoolAmount(_token, _amount);
    }

    function _decreasePoolAmount(address _token, uint256 _amount) private {
        require(poolAmounts[_token] >= _amount, "Vault: poolAmount exceeded");
        poolAmounts[_token] = poolAmounts[_token] - (_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 50);
        emit DecreasePoolAmount(_token, _amount);
    }

    function getRedemptionAmount(
        address _token,
        uint256 _usdlAmount
    ) public view override returns (uint256) {
        uint256 price = getMaxPrice(_token);
        uint256 redemptionAmount = (_usdlAmount * (PRICE_PRECISION)) / (price);
        return adjustForDecimals(redemptionAmount, usdl, _token);
    }

    function sellUSDL(
        address _token,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateManager();
        _validate(whitelistedTokens[_token], 19);

        uint256 usdlAmount = _transferIn(usdl);
        _validate(usdlAmount > 0, 20);

        uint256 redemptionAmount = getRedemptionAmount(_token, usdlAmount);
        _validate(redemptionAmount > 0, 21);

        _decreasePoolAmount(_token, redemptionAmount);

        IUSDL(usdl).burn(address(this), usdlAmount);

        // the _transferIn call increased the value of tokenBalances[usdl]
        // usually decreases in token balances are synced by calling _transferOut
        // however, for usdl, the tokens are burnt, so _updateTokenBalance should
        // be manually called to record the decrease in tokens
        _updateTokenBalance(usdl);

        uint256 feeBasisPoints = vaultUtils.getSellUsdlFeeBasisPoints(
            _token,
            usdlAmount
        );
        uint256 amountOut = _collectSwapFees(_token, redemptionAmount, feeBasisPoints);
        _validate(amountOut > 0, 22);

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
            _validate(isLiquidator[msg.sender], 34);
        }


        updateCumulativeFundingRate(_collateralToken, _indexToken);
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
        _validate(position.size > 0, 35);

        (uint256 liquidationState, uint256 marginFees) = validateLiquidation(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            false
        );
        _validate(liquidationState != 0, 36);
        uint256 markPrice = _isLong ? getMinPrice(_indexToken) : getMaxPrice(_indexToken);
        if (_isLong) {
            globalLongAveragePrices[_indexToken] = getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, markPrice, position.size, true, true);
        } else {
            globalShortAveragePrices[_indexToken] = getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, markPrice, position.size, false, true);
        }
        if (liquidationState == 2) {
            // max leverage exceeded but there is collateral remaining after deducting losses so decreasePosition instead
            //anirudhDoubt: what does above comment mean
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

        delete positions[getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        )];

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

    // validateLiquidation returns (state, fees)
    function validateLiquidation(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) public view override returns (uint256, uint256) {
        return
            vaultUtils.validateLiquidation(
                _account,
                _collateralToken,
                _indexToken,
                _isLong,
                _raise
            );
    }

    function _increaseReservedAmount(address _token, uint256 _amount) private {
        reservedAmounts[_token] = reservedAmounts[_token] + (_amount);
        _validate(reservedAmounts[_token] <= poolAmounts[_token], 52);
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
    //AnirudhTodo - there is a difference in averagePrice calculation in positions tracker
    //and this function have a look.
    function getNextAveragePrice(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 _lastIncreasedTime
    ) public view returns (uint256) {
        (bool hasProfit, uint256 delta) = getDelta(
            _indexToken,
            _size,
            _averagePrice,
            _isLong,
            _lastIncreasedTime
        );
        uint256 nextSize = _size + (_sizeDelta);
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit ? nextSize + (delta) : nextSize - (delta);
        } else {
            divisor = hasProfit ? nextSize - (delta) : nextSize + (delta);
        }
        return (_nextPrice * (nextSize)) / (divisor);
    }

    function withdrawFees(address _token, address _receiver) external override returns (uint256) {
        _onlyGov();
        uint256 amount = feeReserves[_token];
        if(amount == 0) { return 0; }
        feeReserves[_token] = 0;
        _transferOut(_token, amount, _receiver);
        return amount;
    }

    function getFeeBasisPoints(address _token, uint256 _usdlDelta, uint256 _feeBasisPoints, bool _increment) public override view returns (uint256) {
        return vaultUtils.getFeeBasisPoints(_token, _usdlDelta, _feeBasisPoints, _increment);
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
            vaultUtils.getPositionFee(
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
            vaultUtils.getFundingFee(
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
            vaultUtils.getEntryFundingRate(
                _collateralToken,
                _indexToken,
                _isLong
            );
    }

    function _validatePosition(
        uint256 _size,
        uint256 _collateral
    ) private view {
        if (_size == 0) {
            _validate(_collateral == 0, 39);
            return;
        }
        _validate(_size >= _collateral, 40);
    }

    function usdToTokenMax(
        address _token,
        uint256 _usdAmount
    ) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

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

    function increasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external override nonReentrant {
        _validate(isLeverageEnabled, 28);
        _validateGasPrice();
        _validateRouter(_account);//AnirudhInfo - validate whether msg.sender is approved to place order for account
        _validateTokens(_collateralToken, _indexToken);
        vaultUtils.validateIncreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong
        );// AnirudhTodo - current no validation.

        updateCumulativeFundingRate(_collateralToken, _indexToken);

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
        }

        if (position.size > 0 && _sizeDelta > 0) {
            position.averagePrice = getNextAveragePrice(
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
        _validate(position.collateral >= fee, 29);

        position.collateral = position.collateral - (fee);
        position.entryFundingRate = getEntryFundingRate(
            _collateralToken,
            _indexToken,
            _isLong
        );
        position.size = position.size + (_sizeDelta);
        position.lastIncreasedTime = block.timestamp;

        _validate(position.size > 0, 30);
        _validatePosition(position.size, position.collateral);
        validateLiquidation(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            true
        );

        // reserve tokens to pay profits on the position
        uint256 reserveDelta = usdToTokenMax(_collateralToken, _sizeDelta);//AnirudhTodo: check why collateral and not index token
        position.reserveAmount = position.reserveAmount + (reserveDelta);
        _increaseReservedAmount(_collateralToken, reserveDelta);

        if (_isLong) {
            if(globalLongSizes[_indexToken] ==0){
                globalLongAveragePrices[_indexToken] = price;
            } else {
                globalLongAveragePrices[_indexToken] = getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, true, true);
            }
            _increaseGlobalLongSize(_indexToken, _sizeDelta);

        } else {
            if (globalShortSizes[_indexToken] == 0) {//--etherscan-api-key "abc"
                globalShortAveragePrices[_indexToken] = price;
            } else {
                globalShortAveragePrices[_indexToken] = getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, false, true);
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
        _validateRouter(_account);
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
        //AniurdhTodo - no validations are performed in vaultUtils. See if you can add any.
        vaultUtils.validateDecreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver
        );
        updateCumulativeFundingRate(_collateralToken, _indexToken);

        bytes32 key = getPositionKey(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        Position storage position = positions[key];
        _validate(position.size > 0, 31);
        _validate(position.size >= _sizeDelta, 32);
        _validate(position.collateral >= _collateralDelta, 33);

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
            globalLongAveragePrices[_indexToken] = getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, true, true);
        } else {
            globalShortAveragePrices[_indexToken] = getNextGlobalAveragePrice(_account, _collateralToken, _indexToken, price, _sizeDelta, false, true);
        }

        if (position.size != _sizeDelta) {
            position.entryFundingRate = getEntryFundingRate(
                _collateralToken,
                _indexToken,
                _isLong
            );
            position.size = position.size - (_sizeDelta);

            _validatePosition(position.size, position.collateral);
            validateLiquidation(
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

            delete positions[key];
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

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view override returns (bool, uint256) {
        _validate(_averagePrice > 0, 38);
        uint256 price = _isLong
            ? getMinPrice(_indexToken)
            : getMaxPrice(_indexToken);
        uint256 priceDelta = _averagePrice > price
            ? _averagePrice - (price)
            : price - (_averagePrice);
        uint256 delta = (_size * (priceDelta)) / (_averagePrice);

        bool hasProfit;
        if (_isLong) {
            hasProfit = price > _averagePrice;
        } else {
            hasProfit = _averagePrice > price;
        }

        // if the minProfitTime has passed then there will be no min profit threshold
        // the min profit threshold helps to prevent front-running issues
        uint256 minBps = block.timestamp > _lastIncreasedTime + (minProfitTime) ? 0 : minProfitBasisPoints[_indexToken];
        if (hasProfit && delta * (BASIS_POINTS_DIVISOR) <= _size * (minBps)) {
            delta = 0;
        }

        return (hasProfit, delta);
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
            (bool _hasProfit, uint256 delta) = getDelta(
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
        //AnirudhTodo - cross-check the understanding below.
        //looks like the funding rate is dependent on the utilization levels of eacth token in the pool.
        return
            (_fundingRateFactor * (reservedAmounts[_token]) * (intervals)) /
            (poolAmount);
    }

    function getNextGlobalAveragePrice(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) public view returns (uint256) {
        int256 realisedPnl = getRealisedPnl(_account,_collateralToken, _indexToken, _sizeDelta, _isIncrease, _isLong);
        uint256 averagePrice = _isLong? globalLongAveragePrices[_indexToken] : globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice-(_nextPrice) : _nextPrice-(averagePrice);

        uint256 nextSize;
        uint256 delta;
        // avoid stack to deep
        {
            uint256 size = _isLong ? globalLongSizes[_indexToken]: globalLongSizes[_indexToken];
            nextSize = _isIncrease ? size+(_sizeDelta) : size-(_sizeDelta);

            if (nextSize == 0) {
                return 0;
            }

            if (averagePrice == 0) {
                return _nextPrice;
            }
            delta = size*(priceDelta)/(averagePrice);
        }

        return _getNextGlobalPositionAveragePrice(
            averagePrice,
            _nextPrice,
            nextSize,
            delta,
            realisedPnl,
            _isLong
        );

    }

    function getRealisedPnl(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isIncrease, 
        bool _isLong
    ) public view returns (int256) {
        if (_isIncrease) {
            return 0;
        }
        //AnirudhTodo - averagePrice here is not the global one. Its the averageprice of the position.
        (uint256 size, /*uint256 collateral*/, uint256 averagePrice, , , , , uint256 lastIncreasedTime) = getPosition(_account, _collateralToken, _indexToken, _isLong);

        (bool hasProfit, uint256 delta) = getDelta(_indexToken, size, averagePrice, _isLong, lastIncreasedTime);
        // get the proportional change in pnl
        uint256 adjustedDelta = _sizeDelta*(delta)/(size);
        require(adjustedDelta < MAX_INT256, "Vault: overflow");
        return hasProfit ? int256(adjustedDelta) : -int256(adjustedDelta);
    }

    function _getNextGlobalPositionAveragePrice(
        uint256 _averagePrice,
        uint256 _nextPrice,
        uint256 _nextSize,
        uint256 _delta,
        int256 _realisedPnl,
        bool _isLong
    ) internal pure returns (uint256) {
        bool hasProfit = _isLong ? _nextPrice > _averagePrice : _nextPrice < _averagePrice;
        uint256 nextDelta = _getNextDelta(hasProfit, _delta, _realisedPnl);
        uint256 divisor;
        if(_isLong){
            divisor = hasProfit ? _nextSize+(nextDelta): _nextSize-(nextDelta);
        }else{
            divisor = hasProfit ? _nextSize-(nextDelta) : _nextSize+(nextDelta);
        }

        uint256 nextAveragePrice = _nextPrice*(_nextSize)/divisor;

        return nextAveragePrice;
    }

    function _getNextDelta(
        bool _hasProfit,
        uint256 _delta,
        int256 _realisedPnl
    ) internal pure returns (uint256) {
        // global delta 10000, realised pnl 1000 => new pnl 9000
        // global delta 10000, realised pnl -1000 => new pnl 11000
        // global delta -10000, realised pnl 1000 => new pnl -11000
        // global delta -10000, realised pnl -1000 => new pnl -9000
        // global delta 10000, realised pnl 11000 => new pnl -1000 (flips sign)
        // global delta -10000, realised pnl -11000 => new pnl 1000 (flips sign)
        
        if (_hasProfit) {
            // global shorts pnl is positive
            if (_realisedPnl > 0) {
                if (uint256(_realisedPnl) > _delta) {
                    _delta = uint256(_realisedPnl)-(_delta);
                    _hasProfit = false;
                } else {
                    _delta = _delta-(uint256(_realisedPnl));
                }
            } else {
                _delta = _delta+(uint256(-_realisedPnl));
            }
            return _delta;
        }

        if (_realisedPnl > 0) {
            _delta = _delta+(uint256(_realisedPnl));
        } else {
            if (uint256(-_realisedPnl) > _delta) {
                _delta = uint256(-_realisedPnl)-(_delta);
                _hasProfit = true;
            } else {
                _delta = _delta-(uint256(-_realisedPnl));
            }
        }
        return _delta;
    }

    function _validate(bool _condition, uint256 _errorCode) private view {
        require(_condition, errors[_errorCode]);
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateManager() private view {
        if (inManagerMode) {
            _validate(isManager[msg.sender], 54);
        }
    }

    // we have this validation as a function instead of a modifier to reduce contract size
    function _validateGasPrice() private view {
        if (maxGasPrice == 0) {
            return;
        }
        _validate(tx.gasprice <= maxGasPrice, 55);
    }

    function _validateRouter(address _account) private view {
        if (msg.sender == _account) {
            return;
        }
        if (msg.sender == router) {
            return;
        }
        _validate(approvedRouters[_account][msg.sender], 41);
    }
}
