// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../libraries/token/IERC20.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IUtils.sol";
import "./interfaces/IPriceFeed.sol";

import "../access/Governable.sol";

contract Utils is IUtils, Governable {
    struct Position {
        uint256 size;
        uint256 collateral;
        uint256 averagePrice;
        uint256 entryFundingRate;
        uint256 reserveAmount;
        int256 realisedPnl;
        uint256 lastIncreasedTime;
    }

    IVault public vault;
    IPriceFeed public priceFeed;
    
    uint256 public constant MAX_INT256 = uint256(type(int256).max);

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public constant FUNDING_RATE_PRECISION = 1000000;
    uint256 public constant USDL_DECIMALS = 18;
    uint256 public constant PRICE_PRECISION = 10 ** 30;
    bool public isValidate = true;



    constructor(IVault _vault, IPriceFeed _pricefeed) {
        vault = _vault;
        priceFeed = _pricefeed;
    }

    function setValidate(bool _validate) external onlyGov{
        isValidate = _validate;
    }

    function setVault(IVault _vault) external onlyGov {
        vault = _vault;
    }
    function setPriceFeed(IPriceFeed _pricefeed) external onlyGov {
        priceFeed = _pricefeed;
    }

    function validateIncreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256  _sizeDelta,
        bool  _isLong 
    ) external view override {

        if(!isValidate){
            return;
        }

        Position memory prevPosition = getPosition(_account, _collateralToken, _indexToken, _isLong);
        uint256 sizeAfterUpdate = _sizeDelta + prevPosition.size;
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 globalSizeAfterUpdate = _isLong ? vault.globalLongSizes(_indexToken) + _sizeDelta: vault.globalShortSizes(_indexToken) + _sizeDelta;
        require(sizeAfterUpdate*100/(globalSizeAfterUpdate) < vault.maxExposurePerUser(), "Utils: Heavy exposure for single user");
        uint256 availableLiquidityInUsd = 0;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            if(!vault.whitelistedTokens(token)){
                continue;
            }
            uint256 price = getMinPrice(token);
            availableLiquidityInUsd += vault.poolAmounts(token) * price;
        }
        require(sizeAfterUpdate*100/(availableLiquidityInUsd) < vault.maxLiquidityPerUser(), "Utils: Huge liquidity captured for single user");
    }

    function validateDecreasePosition(
        address /* _account */,
        address /* _collateralToken */,
        address /* _indexToken */,
        uint256 /* _collateralDelta */,
        uint256 /* _sizeDelta */,
        bool /* _isLong */,
        address /* _receiver */
    ) external view override {
        // no additional validations
    }

    function getPosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) internal view returns (Position memory) {
        IVault _vault = vault;
        Position memory position;
        {
            (
                uint256 size,
                uint256 collateral,
                uint256 averagePrice,
                uint256 entryFundingRate /* reserveAmount */ /* realisedPnl */ /* hasProfit */,
                ,
                ,
                ,
                uint256 lastIncreasedTime
            ) = _vault.getPosition(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong
                );
            position.size = size;
            position.collateral = collateral;
            position.averagePrice = averagePrice;
            position.entryFundingRate = entryFundingRate;
            position.lastIncreasedTime = lastIncreasedTime;
        }
        return position;
    }

    function validateLiquidation(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        bool _raise
    ) public view override returns (uint256, uint256) {
        Position memory position = getPosition(
            _account,
            _collateralToken,
            _indexToken,
            _isLong
        );
        IVault _vault = vault;

        (bool hasProfit, uint256 delta) = getDelta(
            _indexToken,
            position.size,
            position.averagePrice,
            _isLong,
            position.lastIncreasedTime
        );
        uint256 marginFees = getFundingFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            position.size,
            position.entryFundingRate
        );
        marginFees =
            marginFees +
            (
                getPositionFee(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong,
                    position.size
                )
            );

        if (!hasProfit && position.collateral < delta) {
            if (_raise) {
                revert("Vault: losses exceed collateral");
            }
            return (1, marginFees);
        }

        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral - (delta);
        }

        if (remainingCollateral < marginFees) {
            if (_raise) {
                revert("Vault: fees exceed collateral");
            }
            // cap the fees to the remainingCollateral
            return (1, remainingCollateral);
        }

        if (remainingCollateral < marginFees + (_vault.liquidationFeeUsd())) {
            if (_raise) {
                revert("Vault: liquidation fees exceed collateral");
            }
            return (1, marginFees);
        }
        //AnirudhTodo - we need to cut fees from remaining collateral and them compare right?
        if (
            remainingCollateral * (_vault.maxLeverage()) * vault.safetyFactor() <
            position.size * (BASIS_POINTS_DIVISOR)
        ) {
            if (_raise) {
                revert("Vault: maxLeverage exceeded");
            }
            return (2, marginFees);
        }

        return (0, marginFees);
    }

    // TODO: revisit this, check implemention
    function getEntryFundingRate(
        address _collateralToken,
        address /* _indexToken */,
        bool /* _isLong */
    ) public view override returns (uint256) {
        return vault.cumulativeFundingRates(_collateralToken);
    }

    function getPositionFee(
        address /* _account */,
        address /* _collateralToken */,
        address /* _indexToken */,
        bool /* _isLong */,
        uint256 _sizeDelta
    ) public view override returns (uint256) {
        if (_sizeDelta == 0) {
            return 0;
        }
        uint256 afterFeeUsd = (_sizeDelta *
            (BASIS_POINTS_DIVISOR - (vault.marginFeeBasisPoints()))) /
            (BASIS_POINTS_DIVISOR);
        return _sizeDelta - (afterFeeUsd);
    }

    function getFundingFee(
        address /* _account */,
        address _collateralToken,
        address /* _indexToken */,
        bool /* _isLong */,
        uint256 _size,
        uint256 _entryFundingRate
    ) public view override returns (uint256) {
        if (_size == 0) {
            return 0;
        }

        uint256 fundingRate = vault.cumulativeFundingRates(_collateralToken) -
            (_entryFundingRate);
        if (fundingRate == 0) {
            return 0;
        }

        return (_size * (fundingRate)) / (FUNDING_RATE_PRECISION);
    }

    function getBuyUsdlFeeBasisPoints(
        address _token,
        uint256 _usdlAmount
    ) public view override returns (uint256) {
        return
            getFeeBasisPoints(
                _token,
                _usdlAmount,
                vault.mintBurnFeeBasisPoints(),
                true
            );
    }

    function getSellUsdlFeeBasisPoints(
        address _token,
        uint256 _usdlAmount
    ) public view override returns (uint256) {
        return
            getFeeBasisPoints(
                _token,
                _usdlAmount,
                vault.mintBurnFeeBasisPoints(),
                false
            );
    }

    function getFeeBasisPoints(
        address _token,
        uint256 _usdlDelta,
        uint256 _feeBasisPoints,
        bool _increment
    ) public view override returns (uint256) {
        if (!vault.hasDynamicFees()) {
            return _feeBasisPoints;
        }
        return _feeBasisPoints;
    }

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

    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view returns (bool, uint256) {
        _validate(_averagePrice > 0, "Vault: averagePrice should be > 0");
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
        uint256 minBps = block.timestamp >
            _lastIncreasedTime + (vault.minProfitTime())
            ? 0
            : vault.minProfitBasisPoints(_indexToken);
        if (hasProfit && delta * (BASIS_POINTS_DIVISOR) <= _size * (minBps)) {
            delta = 0;
        }

        return (hasProfit, delta);
    }

    function _validate(
        bool _condition,
        string memory errorMessage
    ) private pure {
        require(_condition, errorMessage);
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
        int256 realisedPnl = getRealisedPnl(
            _account,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isIncrease,
            _isLong
        );
        uint256 averagePrice = _isLong
            ? vault.globalLongAveragePrices(_indexToken)
            : vault.globalShortAveragePrices(_indexToken);
        uint256 priceDelta = averagePrice > _nextPrice
            ? averagePrice - (_nextPrice)
            : _nextPrice - (averagePrice);

        uint256 nextSize;
        uint256 delta;
        // avoid stack to deep
        {
            uint256 size = _isLong
                ? vault.globalLongSizes(_indexToken)
                : vault.globalShortSizes(_indexToken);
            nextSize = _isIncrease ? size + (_sizeDelta) : size - (_sizeDelta);

            if (nextSize == 0) {
                return 0;
            }

            if (averagePrice == 0) {
                return _nextPrice;
            }
            delta = (size * (priceDelta)) / (averagePrice);
        }

        return
            _getNextGlobalPositionAveragePrice(
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
        (
            uint256 size /*uint256 collateral*/,
            ,
            uint256 averagePrice,
            ,
            ,
            ,
            ,
            uint256 lastIncreasedTime
        ) = vault.getPosition(_account, _collateralToken, _indexToken, _isLong);

        (bool hasProfit, uint256 delta) = getDelta(
            _indexToken,
            size,
            averagePrice,
            _isLong,
            lastIncreasedTime
        );
        // get the proportional change in pnl
        uint256 adjustedDelta = (_sizeDelta * (delta)) / (size);
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
        bool hasProfit = _isLong
            ? _nextPrice > _averagePrice
            : _nextPrice < _averagePrice;
        uint256 nextDelta = _getNextDelta(hasProfit, _delta, _realisedPnl);
        uint256 divisor;
        if (_isLong) {
            divisor = hasProfit
                ? _nextSize + (nextDelta)
                : _nextSize - (nextDelta);
        } else {
            divisor = hasProfit
                ? _nextSize - (nextDelta)
                : _nextSize + (nextDelta);
        }

        uint256 nextAveragePrice = (_nextPrice * (_nextSize)) / divisor;

        return nextAveragePrice;
    }

    function _getNextDelta(
        bool _hasProfit,
        uint256 _delta,
        int256 _realisedPnl
    ) internal pure returns (uint256) {

        if (_hasProfit) {
            // global shorts pnl is positive
            if (_realisedPnl > 0) {
                if (uint256(_realisedPnl) > _delta) {
                    _delta = uint256(_realisedPnl) - (_delta);
                    _hasProfit = false;
                } else {
                    _delta = _delta - (uint256(_realisedPnl));
                }
            } else {
                _delta = _delta + (uint256(-_realisedPnl));
            }
            return _delta;
        }

        if (_realisedPnl > 0) {
            _delta = _delta + (uint256(_realisedPnl));
        } else {
            if (uint256(-_realisedPnl) > _delta) {
                _delta = uint256(-_realisedPnl) - (_delta);
                _hasProfit = true;
            } else {
                _delta = _delta - (uint256(-_realisedPnl));
            }
        }
        return _delta;
    }

    function adjustForDecimals(
        uint256 _amount,
        address _tokenDiv,
        address _tokenMul
    ) public view returns (uint256) {
        uint256 decimalsDiv = _tokenDiv == vault.usdl()
            ? USDL_DECIMALS
            : vault.tokenDecimals(_tokenDiv);
        uint256 decimalsMul = _tokenMul == vault.usdl()
            ? USDL_DECIMALS
            : vault.tokenDecimals(_tokenMul);
        return (_amount * (10 ** decimalsMul)) / (10 ** decimalsDiv);
    }

    function getAumInUsdl(
        bool maximise
    ) public view returns (uint256) {
        uint256 aum = getAum(maximise);
        return (aum * (10 ** USDL_DECIMALS)) / (PRICE_PRECISION);
    }

    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum;
        uint256 profits = 0;
        IVault _vault = vault;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = maximise
                ? getMaxPrice(token)
                : getMinPrice(token);
            uint256 poolAmount = _vault.poolAmounts(token);
            uint256 decimals = _vault.tokenDecimals(token);

            if (_vault.stableTokens(token)) {
                aum = aum + ((poolAmount * (price)) / (10 ** decimals));
            } else {
                aum = aum + ((poolAmount * (price)) / (10 ** decimals));
                uint256 shortSize = _vault.globalShortSizes(token);

                if (shortSize > 0) {
                    ( bool hasProfit, uint256 delta) = getGlobalPositionDelta(token, false);
                    if (!hasProfit) {
                        aum = aum + (delta);
                    } else {
                        profits = profits + (delta);
                    }
                }

                uint256 longSize = _vault.globalLongSizes(token);

                if (longSize > 0) {
                    ( bool hasProfit, uint256 delta) = getGlobalPositionDelta(token, true);
                    if (!hasProfit) {
                        aum = aum + (delta);
                    } else {
                        profits = profits + (delta);
                    }
                }
            }
        }

        aum = profits > aum ? 0 : aum - (profits) ;
        return aum;
    }

    function getGlobalPositionDelta(address _token, bool _isLong) public view returns (bool, uint256) {
        uint256 size = _isLong ? vault.globalLongSizes(_token) : vault.globalShortSizes(_token);
        if (size == 0) { return (false, 0); }

        uint256 nextPrice = _isLong ? getMinPrice(_token) : getMaxPrice(_token);
        return getGlobalPositionDeltaWithPrice(_token, nextPrice, size, _isLong);
    }

    function getGlobalPositionDeltaWithPrice(
        address _token,
        uint256 _price,
        uint256 _size,
        bool _isLong
    ) public view returns (bool, uint256) {
        uint256 averagePrice = _isLong? vault.globalLongAveragePrices(_token) : vault.globalShortAveragePrices(_token);
        uint256 priceDelta = averagePrice > _price
            ? averagePrice - (_price)
            : _price - (averagePrice);
        uint256 delta = (_size * (priceDelta)) / (averagePrice);
        return (averagePrice > _price, delta);
    }


    function calculateMintAmount(uint256 _minusdl, address _token, uint256 aumInusdl, uint256 llpSupply, uint256 _minllp, address _receiver) external returns(uint256, uint256){
        uint256 usdlAmount = vault.buyUSDL(_token, _receiver);
        require(usdlAmount >= _minusdl, "LlpManager: insufficient usdl output");

        uint256 mintAmount = aumInusdl == 0
            ? usdlAmount
            : (usdlAmount * (llpSupply)) / (aumInusdl);
        require(mintAmount >= _minllp, "LlpManager: insufficient llp output");
        return (mintAmount, usdlAmount);
    }

    function validatePosition(
        uint256 _size,
        uint256 _collateral
    ) public view {
        if (_size == 0) {
            _validate(_collateral == 0, "Vault: collateral should be 0");
            return;
        }
        _validate(_size >= _collateral, "Vault: collateral exceeds size");
    }
    function updateCumulativeFundingRate(uint256 lastFundingTime, uint256 fundingInterval, uint256 fundingRateFactor, uint256 poolAmount, uint256 reservedAmount) public view returns(uint256 fundingTime, uint256 fundingRate) {
        if (lastFundingTime == 0) {
            return ((block.timestamp / (fundingInterval)) * (fundingInterval) , 0);
        }
        
        if (lastFundingTime + (fundingInterval) > block.timestamp) {
            return (lastFundingTime,0);
        }

        fundingTime =  (block.timestamp / (fundingInterval)) * (fundingInterval);
        fundingRate = getNextFundingRate(lastFundingTime, fundingInterval, fundingRateFactor, poolAmount, reservedAmount);

        return (fundingTime, fundingRate);
    }

    function getNextFundingRate(uint lastFundingTime, uint fundingInterval, uint fundingRateFactor, uint poolAmount, uint reservedAmount) public view returns(uint){
        if (lastFundingTime + (fundingInterval) > block.timestamp) {
            return 0;
        }

        uint256 intervals = (block.timestamp - lastFundingTime) / (fundingInterval);
        if (poolAmount == 0) {
            return 0;
        }
        
        return
            (fundingRateFactor * (reservedAmount) * (intervals)) /
            (poolAmount);
    }

    function usdToTokenMax(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) { 
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMinPrice(_token));
    }

    function usdToTokenMin(address _token, uint256 _usdAmount) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        return usdToToken(_token, _usdAmount, getMaxPrice(_token));
    }

    function tokenToUsdMin(address _token, uint256 _tokenAmount) public view returns (uint256) {
        if (_tokenAmount == 0) {
            return 0;
        }
        uint256 price = getMinPrice(_token);
        uint256 decimals = vault.tokenDecimals(_token);
        return (_tokenAmount * (price)) / (10 ** decimals);
    }

    function usdToToken(address _token, uint256 _usdAmount, uint256 _price) public view returns (uint256) {
        if (_usdAmount == 0) {
            return 0;
        }
        uint256 decimals = vault.tokenDecimals(_token);
        return (_usdAmount * (10 ** decimals)) / (_price);
    }

    function getMinPrice(address _token) public view returns (uint256) {
        return priceFeed.getMinPriceOfToken(_token);
    }
    function getMaxPrice(address _token) public view returns (uint256) {
        return priceFeed.getMaxPriceOfToken(_token);
    }

    
    function getRedemptionAmount(address _token, uint256 _usdlAmount) public view override returns (uint256) {
        uint256 price = getMaxPrice(_token);
        uint256 redemptionAmount = (_usdlAmount * (PRICE_PRECISION)) / (price);
        return adjustForDecimals(redemptionAmount, vault.usdl(), _token);
    }

    function collectMarginFees(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _size,
        uint256 _entryFundingRate
    ) public view returns (uint256 feeTokens, uint256 feeUsd) {
        feeUsd = getPositionFee(
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

        feeTokens = usdToTokenMin(_collateralToken, feeUsd);

        return (feeTokens, feeUsd);
    }

}
