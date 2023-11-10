// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./interfaces/IPriceFeed.sol";
import "../access/Governable.sol";
import './interfaces/IOrderManager.sol';
import "./interfaces/IPriceEvents.sol";
import "pyth-sdk-solidity/IPyth.sol";
import "pyth-sdk-solidity/PythStructs.sol";

contract PriceFeed is IPriceFeed, Governable {
    struct PriceArgs {
        uint256 price;
        int32 expo;
        uint256 publishTime;
    }

    struct TokenPrice {
        uint256 maxPrice;
        uint256 minPrice;
        int32 maxPriceExpo;
        int32 minPriceExpo;
        uint256 publishTime;
    }

    uint256 public maxAllowedDelay;
    mapping(address => bool) public updater; 
    address public pythContract;
    uint256 public constant PRICE_PRECISION = 30;

    mapping(address => bytes32) public tokenPriceIdMapping;
    mapping(address => TokenPrice) public tokenToPrice;
    address[] public supportedTokens;
    uint256 public maxAllowedDelta;
    uint mntIndex;

    event PriceSet(
        TokenPrice priceSet
    );
    constructor(
        uint _maxAllowedDelay,
        address _pythContract,
        address _updater,
        uint256 _maxAllowedDelta
    ) {
        maxAllowedDelay = _maxAllowedDelay;
        pythContract = _pythContract;
        updater[_updater] = true;
        maxAllowedDelta = _maxAllowedDelta;
    }

    modifier onlyUpdater() {
        require(updater[msg.sender], "PriceFeed: sender does not have entitlements to update price");
        _;
    }

    function setUpdater(address _updater) external onlyGov {
        updater[_updater] = true;
    }
    function removeUpdater(address _updater) external onlyGov {
        updater[_updater] = false;
    }

    function setPythContract(address _pythContract) external onlyGov {
        pythContract = _pythContract;
    }

    function setMaxAllowedDelay(uint256 _maxAllowedDelay) external onlyGov {
        maxAllowedDelay = _maxAllowedDelay;
    }

    function setMaxAllowedDelta(uint256 _maxAllowedDelta) external onlyGov {
        maxAllowedDelta = _maxAllowedDelta;
    }

    function setMNTIndex(uint _index) external onlyGov {
        mntIndex = _index;
    }

    function updateTokenIdMapping(
        address _token,
        bytes32 _priceId
    ) external onlyGov {
        if (tokenPriceIdMapping[_token] != bytes32(0)) {
            tokenPriceIdMapping[_token] = _priceId;
        } else {
            tokenPriceIdMapping[_token] = _priceId;
            supportedTokens.push(_token);
        }
    }

    function validateData(uint256 _publishTime) internal view {
        require(
            _publishTime + maxAllowedDelay > block.timestamp,
            "PriceFeed: current price data not available!"
        );
    }

    function setPricesAndExecute(
        bytes[] calldata _priceUpdateData,
        PriceArgs[] memory _darkOraclePrices,
        address _orderManager,
        uint256 _endIndexForIncreasePositions,
        uint256 _endIndexForDecreasePositions
    ) external payable onlyUpdater {
        setPrices(_priceUpdateData, _darkOraclePrices);
        executePositions(_orderManager, _endIndexForIncreasePositions, _endIndexForDecreasePositions);
    }

    function _setMntPrice() internal {
        address mntAddress = supportedTokens[0]; // leave 0 index for a custom token like MNT
        bytes32 MNTPriceId = tokenPriceIdMapping[mntAddress];
        PythStructs.Price memory mntPythPrice = IPyth(pythContract).getPriceNoOlderThan(MNTPriceId, maxAllowedDelay);
        TokenPrice memory mntPriceObject = TokenPrice(uint64(mntPythPrice.price), uint64(mntPythPrice.price), mntPythPrice.expo, mntPythPrice.expo, mntPythPrice.publishTime);
        tokenToPrice[mntAddress] = mntPriceObject;
    }

    function _setPrice(address _tokenAddress,  PriceArgs memory _darkOraclePrice) internal {
        validateData(_darkOraclePrice.publishTime);
        TokenPrice memory priceObject = TokenPrice(_darkOraclePrice.price, _darkOraclePrice.price, _darkOraclePrice.expo, _darkOraclePrice.expo, _darkOraclePrice.publishTime);
        tokenToPrice[_tokenAddress] = priceObject;
        emit PriceSet(priceObject);
    }
    
    function setPrices( bytes[] calldata _priceUpdateData, PriceArgs[] memory _darkOraclePrices) public payable onlyUpdater {
        uint numPriceIds = supportedTokens.length;
        // set MNT price
       _setMntPrice();

        if(_priceUpdateData.length == 0){
            // 0 index for MNT
            for(uint i = 1; i < numPriceIds; i++){
                address currToken = supportedTokens[i];
                _setPrice(currToken, _darkOraclePrices[i]);
            }
        }
        else{
            // compare with pyth and set
            uint fee = IPyth(pythContract).getUpdateFee(_priceUpdateData);
            IPyth(pythContract).updatePriceFeeds{value: fee}(_priceUpdateData);

            for (uint i = 1; i < numPriceIds; i++) {
                address currToken = supportedTokens[i];
                bytes32 currPriceId = tokenPriceIdMapping[currToken];
                PythStructs.Price memory pythPrice = IPyth(pythContract).getPriceNoOlderThan(currPriceId, maxAllowedDelay);
                compareAndSetPrice(currToken, pythPrice, _darkOraclePrices[i]);
            }
        }
    }

    function compareAndSetPrice(address _tokenAddress, PythStructs.Price memory _pythPrice, PriceArgs memory _darkOraclePrice) internal {
        uint256 pythPrice = getFinalPrice(uint64(_pythPrice.price), _pythPrice.expo);
        uint256 darkOraclePrice = getFinalPrice(uint64(_darkOraclePrice.price),_darkOraclePrice.expo);

        if (allowedDelta(pythPrice, darkOraclePrice)) {
            _setPrice(_tokenAddress, _darkOraclePrice);
        } else {
            validateData(_pythPrice.publishTime);
            TokenPrice memory priceObject = TokenPrice(
                pythPrice > darkOraclePrice
                    ? uint64(_pythPrice.price)
                    : _darkOraclePrice.price,
                pythPrice < darkOraclePrice
                    ? uint64(_pythPrice.price)
                    : _darkOraclePrice.price,
                pythPrice > darkOraclePrice
                    ? _pythPrice.expo
                    : _darkOraclePrice.expo,
                pythPrice < darkOraclePrice
                    ? _pythPrice.expo
                    : _darkOraclePrice.expo,
                _darkOraclePrice.publishTime
            );
            tokenToPrice[_tokenAddress] = priceObject;
            emit PriceSet(priceObject);
        }
    }

    function allowedDelta(uint256 _a, uint256 _b) public view returns (bool) {
        uint256 _allowedDelta = (_a * maxAllowedDelta) / 1000;
        return
            (_a >= _b) ? (_a - _b <= _allowedDelta) : (_b - _a <= _allowedDelta);
    }

    function executePositions(address _orderManager,uint _endIndexForIncreasePositions, uint _endIndexForDecreasePositions) public onlyUpdater {
        IOrderManager orderManager = IOrderManager(_orderManager);
        orderManager.executeIncreasePositions(_endIndexForIncreasePositions, payable(msg.sender));
        orderManager.executeDecreasePositions(_endIndexForDecreasePositions, payable(msg.sender));
    }

    function getMaxPriceOfToken(
        address _token
    ) external view override returns (uint256) {
        TokenPrice memory price = tokenToPrice[_token];
        validateData(price.publishTime);
        return getFinalPrice(uint64(price.maxPrice), price.maxPriceExpo);
    }

    function getMinPriceOfToken(
        address _token
    ) external view override returns (uint256) {
        TokenPrice memory price = tokenToPrice[_token];
        validateData(price.publishTime);
        return getFinalPrice(uint64(price.minPrice), price.minPriceExpo);
    }

    function getFinalPrice(
        uint256 price,
        int32 exponent
    ) private pure returns (uint256) {
        uint256 adjustment = PRICE_PRECISION - uint32(-1 * exponent);
        return price * (10 ** adjustment);
    }

    function withdrawFunds(uint256 _amount, address payable _receiver) public onlyGov{
        require(address(this).balance >= _amount, "PriceFeed: requested amount exceeds contract balance");
        (bool sent, bytes memory data) = _receiver.call{value: _amount}("");
        require(sent, "PriceFeed: Failed to send Ether");
    }
}