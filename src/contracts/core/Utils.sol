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
        uint256 entryBorrowingRate;
        int256 entryFundingRate;
        uint256 reserveAmount;
        uint256 realisedPnl;
        bool isProfit;
        uint256 lastIncreasedTime;
    }

    IVault public vault;
    IPriceFeed public priceFeed;
    
    uint256 public constant MAX_INT256 = uint256(type(int256).max);

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    uint256 public BORROWING_RATE_PRECISION = 10000000000;
    int256 public FUNDING_RATE_PRECISION = 10000000000;
    uint256 public constant USDL_DECIMALS = 18;
    uint256 public constant PRICE_PRECISION = 10 ** 30;



    constructor(IVault _vault, IPriceFeed _pricefeed) {
        vault = _vault;
        priceFeed = _pricefeed;
    }

    function setVault(IVault _vault) external onlyGov {
        vault = _vault;
    }
    function setPriceFeed(address _pricefeed) external onlyGov {
        priceFeed = IPriceFeed(_pricefeed);
    }
    function setBorrowingRatePrecision(uint256 _precision) external onlyGov{
        BORROWING_RATE_PRECISION = _precision;
    }
    function setFundingRatePrecision(int256 _precision) external onlyGov{
        FUNDING_RATE_PRECISION = _precision;
    }

    function validateIncreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256  _sizeDelta,
        bool  _isLong 
    ) external view override {}

    // Will we be implementing this validation function
    function validateDecreasePosition(
        address /* _account */,
        address /* _collateralToken */,
        address /* _indexToken */,
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
        Position memory position;
        {
            (
                uint256 size,
                uint256 collateral,
                uint256 averagePrice,
                uint256 entryBorrowingRate,
                int256 entryFundingRate,
                ,
                , // 6
                ,
                uint256 lastIncreasedTime
            ) = vault.getPosition(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong
                );
            position.size = size;
            position.collateral = collateral;
            position.averagePrice = averagePrice;
            position.entryBorrowingRate = entryBorrowingRate;
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
        bool _raise,
        uint256 _markPrice
    ) public view override returns (uint256, int256) {
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
            _markPrice,
            _isLong,
            position.lastIncreasedTime
        );
        int256 marginFees = int(getBorrowingFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            position.size,
            position.entryBorrowingRate
        ));
        marginFees =
            marginFees +
            int(
                getPositionFee(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong,
                    position.size
                )
            );

        marginFees = marginFees + getFundingFee(_account, _collateralToken, _indexToken, _isLong, position.size, position.entryFundingRate);
        if (!hasProfit && position.collateral < delta) {
            if (_raise) {
                revert("Vault: losses exceed collateral");
            }
            return (1, marginFees);
        }

        uint256 remainingCollateral = position.collateral;
        if (!hasProfit) {
            remainingCollateral = position.collateral - (delta);
        } else {
            remainingCollateral = position.collateral + delta;
        }

        if(marginFees<0){
            remainingCollateral = remainingCollateral + uint(abs(marginFees));
        } else {
            if (remainingCollateral < uint(marginFees)) {
                if (_raise) {
                    revert("Vault: fees exceed collateral");
                }
            // cap the fees to the remainingCollateral
                return (1, int(remainingCollateral));
            }
            remainingCollateral = remainingCollateral - uint(marginFees);
        }

        if (remainingCollateral < calcLiquidationFee(position.size, _indexToken)) {
            if (_raise) {
                revert("Vault: liquidation fees exceed collateral");
            }
            return (1, marginFees);
        }

        if (
            remainingCollateral * (_vault.maxLeverage(_indexToken)) * _vault.safetyFactor() <
            position.size * (BASIS_POINTS_DIVISOR) * 100
        ) {
            if (_raise) {
                revert("Vault: maxLeverage exceeded");
            }
            return (2, marginFees);
        }

        return (0, marginFees);
    }

    function getEntryBorrowingRate(
        address _collateralToken,
        address /* _indexToken */,
        bool /* _isLong */
    ) public view override returns (uint256) {
        return vault.cumulativeBorrowingRates(_collateralToken);
    }

    function getEntryFundingRate(
        address /*_collateralToken*/,
        address _indexToken,
        bool  _isLong
    ) public view override returns (int256) {
        return _isLong ? vault.cumulativeFundingRatesForLongs( _indexToken) : vault.cumulativeFundingRatesForShorts(_indexToken);
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

    function getBorrowingFee(
        address /* _account */,
        address _collateralToken,
        address /* _indexToken */,
        bool /* _isLong */,
        uint256 _size,
        uint256 _entryBorrowingRate
    ) public view override returns (uint256) {
        if (_size == 0) {
            return 0;
        }

        uint256 borrowingRate = vault.cumulativeBorrowingRates(_collateralToken) -
            (_entryBorrowingRate);
        if (borrowingRate == 0) {
            return 0;
        }

        return (_size * (borrowingRate)) / (BORROWING_RATE_PRECISION);
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
        address /*_token*/,
        uint256 /*_usdlDelta*/,
        uint256 _feeBasisPoints,
        bool /*_increment*/
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
            _nextPrice,
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
        uint256 _nextPrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) public view returns (bool, uint256) {
        _validate(_averagePrice > 0, "Vault: averagePrice should be > 0");
        uint256 price = _nextPrice;
        uint256 priceDelta = _averagePrice > price ? _averagePrice - (price) : price - (_averagePrice);
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
            _isLong,
            _nextPrice
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
        bool _isLong,
        uint256 _nextPrice
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
            ,
            uint256 lastIncreasedTime
        ) = vault.getPosition(_account, _collateralToken, _indexToken, _isLong);

        (bool hasProfit, uint256 delta) = getDelta(
            _indexToken,
            size,
            averagePrice,
            _nextPrice,
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
        uint256 decimalsDiv = _tokenDiv == vault.usdl() ? USDL_DECIMALS : vault.tokenDecimals(_tokenDiv);
        uint256 decimalsMul = _tokenMul == vault.usdl() ? USDL_DECIMALS : vault.tokenDecimals(_tokenMul);

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
        bool hasProfit = _isLong ? _price > averagePrice : averagePrice > _price;
        return (hasProfit, delta);
    }

    function validatePosition(
        uint256 _size,
        uint256 _collateral
    ) public pure {
        if (_size == 0) {
            _validate(_collateral == 0, "Utils: collateral should be 0");
            return;
        }
        _validate(_size >= _collateral, "Utils: collateral exceeds size");
    }
    function updateCumulativeBorrowingRate(uint256 lastBorrowingTime, uint256 borrowingInterval, uint256 borrowingRateFactor, uint256 poolAmount, uint256 reservedAmount) public view returns(uint256 borrowingTime, uint256 borrowingRate) {
        if (lastBorrowingTime == 0) {
            return ((block.timestamp / (borrowingInterval)) * (borrowingInterval) , 0);
        }
        
        if (lastBorrowingTime +borrowingInterval > block.timestamp) {
            return (lastBorrowingTime,0);
        }

        borrowingTime =  (block.timestamp / (borrowingInterval)) * (borrowingInterval);
        borrowingRate = getNextBorrowingRate(lastBorrowingTime, borrowingInterval, borrowingRateFactor, poolAmount, reservedAmount);

        return (borrowingTime, borrowingRate);
    }

    function updateCumulativeFundingRate(uint256 fundingRateFactor, address _indexToken, uint lastFundingTime, uint fundingInterval) public view returns(uint256 lastFundingUpdateTime, int256 fundingRateForLong, int256 fundingRateForShort) {
        if (lastFundingTime == 0) {
            return ((block.timestamp / (fundingInterval)) * (fundingInterval) , 0, 0);
        }
        
        if (lastFundingTime +fundingInterval > block.timestamp) {
            return (lastFundingTime,0, 0);
        }

        lastFundingUpdateTime =  (block.timestamp / (fundingInterval)) * (fundingInterval);
        uint intervals = (lastFundingUpdateTime - lastFundingTime)/fundingInterval;
        (fundingRateForLong, fundingRateForShort) = getNextFundingRate(vault.fundingExponent(), fundingRateFactor, _indexToken);
        return (lastFundingUpdateTime, fundingRateForLong * int(intervals), fundingRateForShort * int(intervals));
    }

    function getNextFundingRate( uint256 fundingExponent, uint256 fundingRateFactor, address _indexToken) public view returns(int256, int256 ) {
        uint256 globalLongSizeVault = vault.globalLongSizes(_indexToken); 
        uint256 globalShortSizeVault = vault.globalShortSizes(_indexToken);
        uint256 oiImbalance = globalLongSizeVault>globalShortSizeVault? globalLongSizeVault - globalShortSizeVault: globalShortSizeVault - globalLongSizeVault;
        if(globalLongSizeVault + globalShortSizeVault == 0){
            return (0, 0);
        }
        (uint adaptiveFundingRateFactor, uint adaptiveFundingExponent) = calculateAdaptiveFundingRate(fundingRateFactor, fundingExponent, _indexToken); 
        uint nextFundingRateForLong =  (adaptiveFundingRateFactor*(oiImbalance**adaptiveFundingExponent))/ (globalLongSizeVault + globalShortSizeVault);
        if(globalShortSizeVault==0){
            return(int(nextFundingRateForLong), 0);
        }
        if(globalLongSizeVault==0){
            return(0, int(nextFundingRateForLong));
        }
        uint nextFundingRateForShort = nextFundingRateForLong *globalLongSizeVault/globalShortSizeVault;
        if(globalLongSizeVault>globalShortSizeVault){
            return (int256(nextFundingRateForLong), -1 * int256(nextFundingRateForShort)); // chance of overflow, revisit
            //to prevent overflow can set a maxThreshold of nextFundingRate.
        } else {
            return (-1 * int256(nextFundingRateForLong), int256(nextFundingRateForShort));
        }
    }

    function calculateAdaptiveFundingRate(uint256 fundingRateFactor, uint256 fundingExponent, address _indexToken) public view returns(uint256, uint256) {
        uint256 globalLongSizeVault = vault.globalLongSizes(_indexToken); 
        uint256 globalShortSizeVault = vault.globalShortSizes(_indexToken);
        uint256 oiImbalance = globalLongSizeVault>globalShortSizeVault? globalLongSizeVault - globalShortSizeVault: globalShortSizeVault - globalLongSizeVault;
        uint256 oiImbalanceThreshold = IVault(vault).oiImbalanceThreshold(_indexToken);
        uint256 oiImbalanceInBps = oiImbalance*BASIS_POINTS_DIVISOR/(globalLongSizeVault + globalShortSizeVault);
        if(globalLongSizeVault ==0 || globalShortSizeVault ==0 || oiImbalanceInBps <= oiImbalanceThreshold){
            return (fundingRateFactor, fundingExponent);
        } else {
            uint256 deviation = oiImbalanceInBps - oiImbalanceThreshold;
            uint256 updatedFundingRateFactor = fundingRateFactor + ((IVault(vault).maxFundingRateFactor() - fundingRateFactor)*deviation)/(BASIS_POINTS_DIVISOR - oiImbalanceThreshold);
            return (updatedFundingRateFactor, fundingExponent);
        }
    }

    function getNextBorrowingRate(uint lastBorrowingTime, uint borrowingInterval, uint borrowingRateFactor, uint poolAmount, uint reservedAmount) public view returns(uint){
        if (lastBorrowingTime + (borrowingInterval) > block.timestamp) {
            return 0;
        }

        uint256 intervals = (block.timestamp - lastBorrowingTime) / (borrowingInterval);
        if (poolAmount == 0) {
            return 0;
        }
        
        return
            (borrowingRateFactor * (reservedAmount) * (intervals)) /
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
        uint256 _entryBorrowingRate, 
        int256 _entryFundingRate
    ) public view returns (int256 feeUsd) {
        feeUsd = int(getPositionFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _sizeDelta
        ));

        uint256 borrowingFee = getBorrowingFee(
            _account,
            _collateralToken,
            _indexToken,
            _isLong,
            _size,
            _entryBorrowingRate
        );

        int256 fundingFee = getFundingFee(_account, _collateralToken, _indexToken, _isLong, _size, _entryFundingRate);
        feeUsd = feeUsd + int(borrowingFee) + fundingFee;
        return feeUsd;
    }

    function abs(int value) public pure returns(int){
        return value< 0 ? -value: value;
    }

    function getFundingFee(address /*account*/, address /*collateralToken*/, address indexToken, bool isLong, uint256 size, int256 entryFundingRate) public view returns(int256){
        if(size==0){
            return 0;
        }
        int256 differenceInFundingRate;
        if(isLong){
            differenceInFundingRate = vault.cumulativeFundingRatesForLongs(indexToken) - entryFundingRate;
        } else {
            differenceInFundingRate = vault.cumulativeFundingRatesForShorts(indexToken) - entryFundingRate;
        }

        return (differenceInFundingRate * int(size))/FUNDING_RATE_PRECISION;
    }

    function getTPPrice(uint256 sizeDelta, bool isLong, uint256 markPrice, uint256 _maxTPAmount, address collateralToken) view public returns(uint256) {  
        uint maxProfitInUsd =( _maxTPAmount * getMinPrice(collateralToken))/10**vault.tokenDecimals(collateralToken);      
        uint256 profitDelta = (maxProfitInUsd * markPrice)/sizeDelta;
        if(isLong){
            return markPrice + profitDelta;
        }
        return markPrice - profitDelta;
    }

    function calcLiquidationFee(uint size, address indexToken) view public returns(uint) {
        uint liqFeeBasedOnSize = size*vault.liquidationFactor()/BASIS_POINTS_DIVISOR;
        if(liqFeeBasedOnSize>vault.liquidationFeeUsd()){
            return liqFeeBasedOnSize;
        } else{
            return vault.liquidationFeeUsd();
        }
        
    }

}
