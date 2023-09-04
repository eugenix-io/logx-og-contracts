// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;
 

import './interfaces/IPriceFeed.sol';
import '../access/Governable.sol';
import './interfaces/IOrderManager.sol';
import './interfaces/IPriceEvents.sol';
import 'pyth-sdk-solidity/IPyth.sol';
import 'pyth-sdk-solidity/PythStructs.sol';
import 'forge-std/console.sol';


contract PriceFeed is IPriceFeed, Governable {

    uint256 maxAllowedDelay;
    mapping(address => bool) updater; 
    address pythContract;
    uint256 public constant PRICE_PRECISION = 30;

    mapping(address => bytes32) public tokenPriceIdMapping;
    mapping(bytes32 => PythStructs.Price) public tokenPrices;
    address[] public supportedTokens;

    constructor(uint _maxAllowedDelay, address _pythContract, address _updater){
        maxAllowedDelay = _maxAllowedDelay;
        pythContract = _pythContract;
        updater[_updater] = true;
    }

    function getPriceOfToken(address _token) external override view returns(uint256){
        bytes32 priceId = tokenPriceIdMapping[_token];
        PythStructs.Price memory priceData = tokenPrices[priceId];
        validateData(priceData);
        return getFinalPrice(uint64(priceData.price), priceData.expo);
    }

    function getMaxPriceOfToken(address _token) external override view returns(uint256){
        bytes32 priceId = tokenPriceIdMapping[_token];
        PythStructs.Price memory priceData = tokenPrices[priceId];
        validateData(priceData);
        return getFinalPrice(uint64(priceData.price), priceData.expo);
    }

    function getMinPriceOfToken(address _token) external override view returns(uint256){
        bytes32 priceId = tokenPriceIdMapping[_token];
        PythStructs.Price memory priceData = tokenPrices[priceId];
        validateData(priceData);
        return getFinalPrice(uint64(priceData.price), priceData.expo); 
    }

    function validateData(PythStructs.Price memory _priceData) internal view {
        require(_priceData.publishTime + maxAllowedDelay > block.timestamp , "PriceFeed: current price data not available!");
    }

    function setUpdater(address _updater) external onlyGov{
        updater[_updater] = true;
    }

    function removeUpdater(address _updater) external onlyGov {
        updater[_updater] = false;
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
        require(updater[msg.sender], "PriceFeed: sender does not have entitlements to update price");
        _;
    }

    function setPricesAndExecute(
        bytes[] calldata priceUpdateData,
        address _orderManager,
        uint256 _endIndexForIncreasePositions,
        uint256 _endIndexForDecreasePositions
    ) external payable onlyUpdater {
        setPrices(priceUpdateData);
        executePositions(_orderManager, _endIndexForIncreasePositions, _endIndexForDecreasePositions);
    }

    function setPrices(bytes[] calldata priceUpdateData) public  payable onlyUpdater{
        uint fee = IPyth(pythContract).getUpdateFee(priceUpdateData);
        IPyth(pythContract).updatePriceFeeds{value: fee}(priceUpdateData);
        uint numPriceIds = supportedTokens.length;
        console.log(numPriceIds);
        for(uint i=0;i<numPriceIds;i++){
            address currToken = supportedTokens[i];
            bytes32 currPriceId = tokenPriceIdMapping[currToken];
            PythStructs.Price memory price = IPyth(pythContract).getPriceUnsafe(currPriceId);
            validateData(price);
            tokenPrices[currPriceId] = price;
        }
    }

    function executePositions(address _orderManager,uint _endIndexForIncreasePositions, uint _endIndexForDecreasePositions) public onlyUpdater {
        IOrderManager orderManager = IOrderManager(_orderManager);
        orderManager.executeIncreasePositions(_endIndexForIncreasePositions, payable(msg.sender));
        orderManager.executeDecreasePositions(_endIndexForDecreasePositions, payable(msg.sender));
    }

    function getFinalPrice(uint256 price, int32 exponent) private pure returns(uint256){
        uint256 adjustment = PRICE_PRECISION - uint32(-1* exponent);
        return price * (10 ** adjustment);
    }
}
