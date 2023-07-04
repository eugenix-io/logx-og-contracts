// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../access/Governable.sol";
import "./interfaces/IPositionsTracker.sol";
import "./interfaces/IVault.sol";

contract PositionsTracker is Governable, IPositionsTracker {

    event GlobalShortDataUpdated(address indexed token, uint256 globalShortSize, uint256 globalShortAveragePrice);
    event GlobalLongDataUpdated(address indexed token, uint256 globalLongSize, uint256 globalLongAveragePrice);

    uint256 public constant MAX_INT256 = uint256(type(int256).max);

    IVault public vault;

    mapping (address => bool) public isHandler;
    mapping (bytes32 => bytes32) public data;

    mapping (address => uint256) override public globalShortAveragePrices;
    mapping (address => uint256) override public globalLongAveragePrices;

    modifier onlyHandler() {
        require(isHandler[msg.sender], "ShortsTracker: forbidden");
        _;
    }

    constructor(address _vault) {
        vault = IVault(_vault);
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        require(_handler != address(0), "ShortsTracker: invalid _handler");
        isHandler[_handler] = _isActive;
    }

    function _setGlobalShortAveragePrice(address _token, uint256 _averagePrice) internal {
        globalShortAveragePrices[_token] = _averagePrice;
    }

    function _setGlobalLongAveragePrice(address _token, uint256 _averagePrice) internal {
        globalLongAveragePrices[_token] = _averagePrice;
    }

    function updateGlobalPositionsData(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        uint256 _markPrice,
        bool _isIncrease,
        bool _isLong
    ) override external onlyHandler {
        if (_sizeDelta == 0) {
            return;
        }

        (uint256 globalPositionSize, uint256 globalPositionAveragePrice) = getNextGlobalPositionData(
            _account,
            _collateralToken,
            _indexToken,
            _markPrice,
            _sizeDelta,
            _isIncrease,
            _isLong
        );

        if(_isLong){
            _setGlobalLongAveragePrice(_indexToken, globalPositionAveragePrice);
            emit GlobalLongDataUpdated(_indexToken, globalPositionSize, globalPositionAveragePrice);
        }else{
            _setGlobalShortAveragePrice(_indexToken, globalPositionAveragePrice);
            emit GlobalShortDataUpdated(_indexToken, globalPositionSize, globalPositionAveragePrice);
        }   
    }

    function getGlobalPositionDelta(address _token, bool _isLong) public view returns (bool, uint256) {
        uint256 size = vault.globalShortSizes(_token);
        if (size == 0) { return (false, 0); }

        uint256 nextPrice = _isLong ? vault.getMinPrice(_token) : vault.getMaxPrice(_token);
        return getGlobalPositionDeltaWithPrice(_token, nextPrice, size, _isLong);
    }

    function getGlobalPositionDeltaWithPrice(
        address _token,
        uint256 _price,
        uint256 _size,
        bool _isLong
    ) public view returns (bool, uint256) {
        uint256 averagePrice = _isLong? globalLongAveragePrices[_token] : globalShortAveragePrices[_token];
        uint256 priceDelta = averagePrice > _price
            ? averagePrice - (_price)
            : _price - (averagePrice);
        uint256 delta = (_size * (priceDelta)) / (averagePrice);
        return (averagePrice > _price, delta);
    }

    function getNextGlobalPositionData(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        bool _isIncrease, 
        bool _isLong
    ) override public view returns (uint256, uint256) {
        int256 realisedPnl = getRealisedPnl(_account,_collateralToken, _indexToken, _sizeDelta, _isIncrease, _isLong);
        uint256 averagePrice = _isLong? globalLongAveragePrices[_indexToken] : globalShortAveragePrices[_indexToken];
        uint256 priceDelta = averagePrice > _nextPrice ? averagePrice-(_nextPrice) : _nextPrice-(averagePrice);

        uint256 nextSize;
        uint256 delta;
        // avoid stack to deep
        {
            uint256 size = _isLong ? vault.globalShortSizes(_indexToken): vault.globalLongSizes(_indexToken);
            nextSize = _isIncrease ? size+(_sizeDelta) : size-(_sizeDelta);

            if (nextSize == 0) {
                return (0, 0);
            }

            if (averagePrice == 0) {
                return (nextSize, _nextPrice);
            }
            delta = size*(priceDelta)/(averagePrice);
        }

        uint256 nextAveragePrice = _getNextGlobalPositionAveragePrice(
            averagePrice,
            _nextPrice,
            nextSize,
            delta,
            realisedPnl,
            _isLong
        );

        return (nextSize, nextAveragePrice);
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

        IVault _vault = vault;
        //AnirudhTodo - averagePrice here is not the global one. Its the averageprice of the position.
        (uint256 size, /*uint256 collateral*/, uint256 averagePrice, , , , , uint256 lastIncreasedTime) = _vault.getPosition(_account, _collateralToken, _indexToken, _isLong);

        (bool hasProfit, uint256 delta) = _vault.getDelta(_indexToken, size, averagePrice, _isLong, lastIncreasedTime);
        // get the proportional change in pnl
        uint256 adjustedDelta = _sizeDelta*(delta)/(size);
        require(adjustedDelta < MAX_INT256, "ShortsTracker: overflow");
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

    /*anirudhExp-*/
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
}
