// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

/**AnirudhTodo
 * LogX pool parameters in this file
 * what should be our PRICE_PRECISION?
 * CUMULATIVE_DELTA_PRECISION
 * MAX_PRICE_DURATION
 * minBlockInterval - 0s
 * maxTimeDeviation - 3600s
 * maxPriceUpdateDelay - 3600s
 * spreadBasisPointsIfChainError - 500 => 5%
 * spreadBasisPointsIfInactive - 20 => 0.2%
 * maxDeviationBasisPoints - 1000 => 10%
 * priceDuration - 300
 * priceDataInterval - 60s*/
 

import './interfaces/IPriceFeed.sol';
import '../access/Governable.sol';
import './interfaces/IPositionRouter.sol';
import './interfaces/IPriceEvents.sol';


contract PriceFeed is IPriceFeed, Governable {

    struct PythPriceData{
        uint64 price;
        uint64 conf;
        uint32 expo;
        uint256 publishTime;
    }

    uint256 maxAllowedDelay;
    address updater; 

    mapping(address => PythPriceData) tokenPrices;

    constructor(address[] memory _tokens, PythPriceData[] memory _prices, uint size, uint _maxAllowedDelay){
        setPrices(_tokens, _prices, size);
        maxAllowedDelay = _maxAllowedDelay;
    }

    function getPriceOfToken(address _token) external override view returns(uint){
        PythPriceData memory priceData = tokenPrices[_token];
        validateData(priceData);
        return priceData.price/(10 ** (priceData.expo)); 
    }

    function getMaxPriceOfToken(address _token) external override view returns(uint){
        PythPriceData memory priceData = tokenPrices[_token];
        validateData(priceData);
        return (priceData.price + priceData.conf)/(10 ** priceData.expo) ; 
    }

    function getMinPriceOfToken(address _token) external override view returns(uint){
        PythPriceData memory priceData = tokenPrices[_token];
        validateData(priceData);
        return (priceData.price - priceData.conf)/(10 ** priceData.expo); 
    }

    function validateData(PythPriceData memory _priceData) internal view {
        require(_priceData.publishTime + maxAllowedDelay > block.timestamp , "PriceFeed: current price data not available!");
    }

    modifier onlyUpdater(){
        require(msg.sender == updater, "PriceFeed: sender does not have entitlements to update price");
        _;
    }

    function setPricesAndExecute(
        address[] memory _tokens,
        PythPriceData[] memory _prices,
        address _positionRouter,
        uint256 _endIndexForIncreasePositions,
        uint256 _endIndexForDecreasePositions, 
        uint256 _size
    ) external onlyUpdater {
        setPrices(_tokens, _prices, _size);
        IPositionRouter positionRouter = IPositionRouter(_positionRouter);

        positionRouter.executeIncreasePositions(_endIndexForIncreasePositions, payable(msg.sender));
        positionRouter.executeDecreasePositions(_endIndexForDecreasePositions, payable(msg.sender));
    }

    function setPrices(address[] memory _tokens, PythPriceData[] memory _prices, uint256 size) internal {
        for(uint i =0;i< size;i++){
            tokenPrices[_tokens[i]] = _prices[i];
        }
    }
}
