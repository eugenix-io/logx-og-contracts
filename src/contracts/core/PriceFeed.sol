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
import 'pyth-sdk-solidity/IPyth.sol';
import 'pyth-sdk-solidity/PythStructs.sol';
import 'forge-std/console.sol';


contract PriceFeed is IPriceFeed, Governable {

    uint256 maxAllowedDelay;
    address updater; 
    address pythContract;

    mapping(address => bytes32) public tokenPriceIdMapping;
    mapping(bytes32 => PythStructs.Price) public tokenPrices;
    address[] public supportedTokens;

    constructor(uint _maxAllowedDelay, address _pythContract, address _updater){
        maxAllowedDelay = _maxAllowedDelay;
        pythContract = _pythContract;
        updater = _updater;
    }

    function getPriceOfToken(address _token) external override view returns(uint256){
        bytes32 priceId = tokenPriceIdMapping[_token];
        PythStructs.Price memory priceData = tokenPrices[priceId];
        validateData(priceData);
        return getFinalPrice(uint64(priceData.price), priceData.expo);
    }

    function getMaxAllowedDelay() external view returns(uint256){
        return maxAllowedDelay;
    }

    function getPriceId(address _token) external view returns(bytes32){
        return tokenPriceIdMapping[_token];
    }

    function getMaxPriceOfToken(address _token) external override view returns(uint256){
        bytes32 priceId = tokenPriceIdMapping[_token];
        PythStructs.Price memory priceData = tokenPrices[priceId];
        validateData(priceData);
        return getFinalPrice(uint64(priceData.price) + priceData.conf, priceData.expo);
    }

    function getMinPriceOfToken(address _token) external override view returns(uint256){
        bytes32 priceId = tokenPriceIdMapping[_token];
        PythStructs.Price memory priceData = tokenPrices[priceId];
        validateData(priceData);
        return getFinalPrice(uint64(priceData.price) - priceData.conf, priceData.expo); 
    }

    function validateData(PythStructs.Price memory _priceData) internal view {
        console.log(_priceData.publishTime);
        console.log(maxAllowedDelay);
        console.log(block.timestamp);
        require(_priceData.publishTime + maxAllowedDelay > block.timestamp , "PriceFeed: current price data not available!");
    }

    function getPublishTime(address _token) external view returns(uint256){
        bytes32 priceId = tokenPriceIdMapping[_token];
        PythStructs.Price memory priceData = tokenPrices[priceId];
        return priceData.publishTime;
    }

    function getBlockTime()external view returns(uint256){
        return block.timestamp;
    }

    function setUpdater(address _updater) external onlyGov{
        updater = _updater;
    }

    function setPythContract(address _pythContract) external onlyGov{
        pythContract = _pythContract;
    }

    function setMaxAllowedDelay(uint256 _maxAllowedDelay) external onlyGov{
        maxAllowedDelay = _maxAllowedDelay;
    }

    function updateTokenIdMapping(address _token, bytes32 _priceId) external onlyGov{
        if(tokenPriceIdMapping[_token] != bytes32(0)){
            tokenPriceIdMapping[_token] = _priceId;
        }
        else{
            tokenPriceIdMapping[_token] = _priceId;
            supportedTokens.push(_token);
        }
    }

    modifier onlyUpdater(){
        require(msg.sender == updater, "PriceFeed: sender does not have entitlements to update price");
        _;
    }

    function getFinalPrice(uint64 price, int32 expo) internal pure returns(uint256){
        if(expo > 0){
            return price*(10 ** uint32(expo));
        }
        else{
            return price/(10 ** uint32(-1 * expo));
        }
    }

    function setPricesAndExecute(
        bytes[] calldata priceUpdateData,
        address _positionRouter,
        uint256 _endIndexForIncreasePositions,
        uint256 _endIndexForDecreasePositions
    ) external payable onlyUpdater {
        uint fee = IPyth(pythContract).getUpdateFee(priceUpdateData);
        IPyth(pythContract).updatePriceFeeds{value: fee}(priceUpdateData);
        uint numPriceIds = supportedTokens.length;
        console.log(numPriceIds);
        for(uint i=0;i<numPriceIds;i++){
            address currToken = supportedTokens[i];
            bytes32 currPriceId = tokenPriceIdMapping[currToken];
            PythStructs.Price memory price = IPyth(pythContract).getPrice(currPriceId);
            tokenPrices[currPriceId] = price;
            //console.log(price.price);
        }
        IPositionRouter positionRouter = IPositionRouter(_positionRouter);

        positionRouter.executeIncreasePositions(_endIndexForIncreasePositions, payable(msg.sender));
        positionRouter.executeDecreasePositions(_endIndexForDecreasePositions, payable(msg.sender));
    }

    function setPrices(bytes[] calldata priceUpdateData) external payable returns(PythStructs.Price memory){
        uint fee = IPyth(pythContract).getUpdateFee(priceUpdateData);
        IPyth(pythContract).updatePriceFeeds{value: fee}(priceUpdateData);
        uint numPriceIds = supportedTokens.length;
        console.log(numPriceIds);
        for(uint i=0;i<numPriceIds;i++){
            address currToken = supportedTokens[i];
            bytes32 currPriceId = tokenPriceIdMapping[currToken];
            PythStructs.Price memory price =  IPyth(pythContract).getPrice(currPriceId);
            tokenPrices[currPriceId] = price;
        }
        return PythStructs.Price(1,1,1,1);
    }

    function tokenLength() external view returns(uint256){
        return supportedTokens.length;
    }
}
