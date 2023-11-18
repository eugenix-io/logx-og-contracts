// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../libraries/token/SafeERC20.sol';
import '../libraries/utils/ReentrancyGuard.sol';
import '../libraries/token/IERC20.sol';
import './BaseOrderManager.sol';
import './interfaces/IOrderManager.sol';
import '../libraries/utils/EnumerableSet.sol';
import "./../libraries/utils/Structs.sol";

contract OrderManager is
    BaseOrderManager,
    IOrderManager,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    struct DecreasePositionRequest {
        address account;
        address _collateralToken;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        address receiver;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 blockNumber;
        uint256 blockTime;
    }

    struct Order {
        address account;
        address collateralToken;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        uint256 triggerPrice;
        uint256 executionFee;
        bool isLong;
        bool triggerAboveThreshold;
        bool isIncreaseOrder;
        bool isMaxOrder;
    }

    uint256 public minExecutionFeeMarketOrder;
    uint256 public minExecutionFeeLimitOrder;
    mapping(address => uint256) public increasePositionsIndex;
    mapping(bytes32 => StructsUtils.IncreasePositionRequest) public increasePositionRequests;
    bytes32[] public increasePositionRequestKeys;
    mapping(address => uint256) public decreasePositionsIndex;
    mapping(bytes32 => DecreasePositionRequest) public decreasePositionRequests;
    bytes32[] decreasePositionRequestKeys;
    mapping(address => bool) public isPositionKeeper;
    uint256 public minBlockDelayKeeper;
    uint256 public minTimeDelayPublic;
    uint256 public maxTimeDelay;
    uint256 public increasePositionRequestKeysStart;
    uint256 public decreasePositionRequestKeysStart;

    mapping (bytes32 => Order) public orders;
    EnumerableSet.Bytes32Set private orderKeys;
    mapping (address => uint256) public ordersIndex;
    mapping (address => bool) public isOrderKeeper;
    mapping (address => bool) public isLiquidator;
    uint public maxProfitMultiplier;

    uint256 public minPurchaseTokenAmountUsd;

    event CreateIncreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 amountIn,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 queueIndex,
        uint256 blockNumber,
        uint256 blockTime,
        uint256 gasPrice
    );

    event CancelIncreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 amountIn,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event CreateDecreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 queueIndex,
        uint256 blockNumber,
        uint256 blockTime
    );

    event ExecuteDecreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event CancelDecreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event ExecuteIncreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 amountIn,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event CreateOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        uint256 executionFee,
        bool isLong,
        bool triggerAboveThreshold,
        bool indexed isIncreaseOrder,
        bool isMaxOrder
    );

    event UpdateOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        bool isLong,
        bool triggerAboveThreshold,
        bool indexed isIncreaseOrder,
        bool isMaxOrder
    );

    event CancelOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        uint256 executionFee,
        bool isLong,
        bool triggerAboveThreshold,
        bool indexed isIncreaseOrder,
        bool isMaxOrder
    );
    event ExecuteOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        uint256 executionFee,
        uint256 executionPrice,
        bool isLong,
        bool triggerAboveThreshold,
        bool indexed isIncreaseOrder
    );

    event SetPositionKeeper(address indexed account, bool isActive);
    event SetOrderKeeper(address indexed account, bool isActive);
    event SetLiquidator(address indexed account, bool isActive);

    event SetDelayValues(
        uint256 minBlockDelayKeeper,
        uint256 minTimeDelayPublic,
        uint256 maxTimeDelay
    );

    constructor(
        address _vault,
        address _utils,
        address _pricefeed,
        uint256 _minExecutionFeeMarketOrder, 
        uint256 _minExecutionFeeLimitOrder,
        uint _depositFee,
        uint _maxProfitMultiplier
    ) BaseOrderManager(_vault, _utils, _pricefeed, _depositFee) {
        minExecutionFeeMarketOrder = _minExecutionFeeMarketOrder;
        minExecutionFeeLimitOrder = _minExecutionFeeLimitOrder;
        maxProfitMultiplier = _maxProfitMultiplier;
    }

    modifier onlyPositionKeeper() {
        require(isPositionKeeper[msg.sender], "OrderManager: 403");
        _;
    }

    modifier onlyLiquidator() {
        require(isLiquidator[msg.sender], "OrderManager: forbidden");
        _;
    }

    modifier onlyOrderKeeper() {
        require(isOrderKeeper[msg.sender], "OrderManager: forbidden");
        _;
    }

    function setPositionKeeper(
        address _account,
        bool _isActive
    ) external onlyAdmin {
        isPositionKeeper[_account] = _isActive;
        emit SetPositionKeeper(_account, _isActive);
    }

    function setMaxTPMultiplier(uint _maxProfitMultiplier) external onlyAdmin {
        maxProfitMultiplier = _maxProfitMultiplier;
    }

    function setMinExecutionFeeMarketOrder(uint256 _minExecutionFeeMarketOrder) external onlyAdmin {
        minExecutionFeeMarketOrder = _minExecutionFeeMarketOrder;
    }

    function setMinExecutionFeeLimitOrder(uint256 _minExecutionFeeLimitOrder) external onlyAdmin {
        minExecutionFeeLimitOrder = _minExecutionFeeLimitOrder;
    }

    function setPriceFeed(address _priceFeed) override external onlyAdmin {
        pricefeed = _priceFeed;
    }

    function setDelayValues(
        uint256 _minBlockDelayKeeper,
        uint256 _minTimeDelayPublic,
        uint256 _maxTimeDelay
    ) external onlyAdmin {
        minBlockDelayKeeper = _minBlockDelayKeeper;
        minTimeDelayPublic = _minTimeDelayPublic;
        maxTimeDelay = _maxTimeDelay;
        emit SetDelayValues(
            _minBlockDelayKeeper,
            _minTimeDelayPublic,
            _maxTimeDelay
        );
    }

    function setOrderKeeper(address _account, bool _isActive) external onlyAdmin {
        isOrderKeeper[_account] = _isActive;
        emit SetOrderKeeper(_account, _isActive);
    }

    function setLiquidator(address _account, bool _isActive) external onlyAdmin {
        isLiquidator[_account] = _isActive;
        emit SetLiquidator(_account, _isActive);
    }

    function createIncreasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 takeProfitPrice,
        uint256 stopLossPrice,
        uint256 _executionFee
    ) external payable nonReentrant returns (bytes32) {
        require(!IVault(vault).ceaseTradingActivity(), "OrderManager: Trading Activity is ceased!");
        require(_executionFee == msg.value, "OrderManager: execution fee not equal to value in msg.value");
        if(takeProfitPrice ==0 && stopLossPrice ==0){
            require(_executionFee >= minExecutionFeeMarketOrder + minExecutionFeeLimitOrder, "OrderManager: market order execution fee less than min execution fee");
        } else if(takeProfitPrice !=0 && stopLossPrice !=0){
            require(_executionFee >= minExecutionFeeMarketOrder + 3 * minExecutionFeeLimitOrder, "OrderManager: tpsl execution fee less than min execution fee");
        } else {
            require(_executionFee >= minExecutionFeeMarketOrder + 2* minExecutionFeeLimitOrder, "OrderManager: tp or sl execution fee less than min execution fee");
        }

        if (_amountIn > 0) {
            IERC20(_collateralToken).safeTransferFrom(
                msg.sender,
                address(this),
                _amountIn
            );
        }
        bytes32 positionKey =  _createIncreasePosition(
                msg.sender,
                _collateralToken,
                _indexToken,
                _amountIn,
                _sizeDelta,
                _isLong,
                _acceptablePrice,
                minExecutionFeeMarketOrder
            );
        if(takeProfitPrice !=0){
            _createOrder(msg.sender, 0, _collateralToken, _indexToken, _sizeDelta, _isLong, takeProfitPrice, _isLong, minExecutionFeeLimitOrder, false , false);
        }
        if(stopLossPrice !=0){
            _createOrder(msg.sender, 0, _collateralToken, _indexToken, _sizeDelta, _isLong, stopLossPrice, !_isLong, minExecutionFeeLimitOrder, false , false);
        }
        uint256 tpPrice;
        {
            uint256 collateralAmount = _amountIn;
            bool isLong = _isLong;
            address collateralToken = _collateralToken;
            address indexToken = _indexToken;
            uint256 sizeDelta = _sizeDelta;
            tpPrice = IUtils(utils).getTPPrice(_sizeDelta, _isLong, _acceptablePrice, collateralAmount * maxProfitMultiplier, collateralToken);
            _createOrder(msg.sender, 0, collateralToken, indexToken, sizeDelta, isLong, tpPrice, isLong, minExecutionFeeLimitOrder, false , true);
            return positionKey;
        }
        
    }

    function _createIncreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee
    ) internal returns (bytes32) {
        StructsUtils.IncreasePositionRequest memory request = StructsUtils.IncreasePositionRequest(
            _account,
            _collateralToken,
            _indexToken,
            _amountIn,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            block.number,
            block.timestamp
        );

        (uint256 index, bytes32 requestKey) = _storeIncreasePositionRequest(
            request
        );
        emit CreateIncreasePosition(
            _account,
            _collateralToken,
            _indexToken,
            _amountIn,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            index,
            increasePositionRequestKeys.length - 1,
            block.number,
            block.timestamp,
            tx.gasprice
        );
        return requestKey;
    }

    function cancelIncreasePosition(
        bytes32 _key,
        address payable _executionFeeReceiver
    ) public nonReentrant returns (bool) {
        StructsUtils.IncreasePositionRequest memory request = increasePositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeIncreasePositions loop will continue executing the next request
        if (request.account == address(0)) {
            return true;
        }

        bool shouldCancel = _validateCancellation(
            request.blockNumber,
            request.blockTime,
            request.account
        );
        if (!shouldCancel) {
            return false;
        }

        delete increasePositionRequests[_key];
        IERC20(request._collateralToken).safeTransfer(request.account, request.amountIn);
        (bool success,  ) = _executionFeeReceiver.call{value: request.executionFee}("");
        require(success, "OrderManager: failed to return execution fee");

        emit CancelIncreasePosition(
            request.account,
            request._collateralToken,
            request.indexToken,
            request.amountIn,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            block.number - request.blockNumber,
            block.timestamp - request.blockTime
        );
        return true;
    }

    function executeIncreasePositions(
        uint256 _endIndex,
        address payable _executionFeeReceiver
    ) external override onlyPositionKeeper {
        uint256 index = increasePositionRequestKeysStart;
        uint256 length = increasePositionRequestKeys.length;

        if (index >= length) {
            return;
        }

        if (_endIndex > length) {
            _endIndex = length;
        }

        while (index < _endIndex) {
            bytes32 key = increasePositionRequestKeys[index];

            // if the request was executed then delete the key from the array
            // if the request was not executed then break from the loop, this can happen if the
            // minimum number of blocks has not yet passed
            // an error could be thrown if the request is too old or if the slippage is
            // higher than what the user specified, or if there is insufficient liquidity for the position
            // in case an error was thrown, cancel the request
            try
                this.executeIncreasePosition(key, _executionFeeReceiver)
            returns (bool _wasExecuted) {
                if (!_wasExecuted) {
                    break;
                }
            } catch {
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try
                    this.cancelIncreasePosition(key, _executionFeeReceiver)
                returns (bool _wasCancelled) {
                    if (!_wasCancelled) {
                        break;
                    }
                } catch {
                    continue;
                }
            }

            delete increasePositionRequestKeys[index];
            index++;
        }

        increasePositionRequestKeysStart = index;
    }

    function executeIncreasePosition(
        bytes32 _key,
        address payable _executionFeeReceiver
    ) public nonReentrant returns (bool) {
        StructsUtils.IncreasePositionRequest memory request = increasePositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeIncreasePositions loop will continue executing the next request
        if (request.account == address(0)) {
            return true;
        }

        bool shouldExecute = _validateExecution(
            request.blockNumber,
            request.blockTime,
            request.account
        );
        if (!shouldExecute) {
            return false;
        }

        delete increasePositionRequests[_key];

        uint256 afterFeeAmount = _collectFees(request.account, request._collateralToken, request.amountIn, request.indexToken, request.isLong, request.sizeDelta);
        IERC20(request._collateralToken).safeTransfer(vault, afterFeeAmount);

        _increasePosition(
            request.account,
            request._collateralToken,
            request.indexToken,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice
        );

        (bool success,  ) = _executionFeeReceiver.call{value: request.executionFee}("");
        require(success, "OrderManager: failed to send eth to executor");

        emit ExecuteIncreasePosition(
            request.account,
            request._collateralToken,
            request.indexToken,
            request.amountIn,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            block.number - (request.blockNumber),
            block.timestamp - (request.blockTime)
        );

        return true;
    }

    function _storeIncreasePositionRequest(
        StructsUtils.IncreasePositionRequest memory _request
    ) internal returns (uint256, bytes32) {
        address account = _request.account;
        uint256 index = increasePositionsIndex[account] + 1;
        increasePositionsIndex[account] = index;
        bytes32 key = getRequestKey(account, index);

        increasePositionRequests[key] = _request;
        increasePositionRequestKeys.push(key);

        return (index, key);
    }

    function createDecreasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _executionFee
    ) external payable nonReentrant returns (bytes32) {
        require(!IVault(vault).ceaseTradingActivity(), "OrderManager: Trading Activity is ceased!");
        require(_executionFee >= minExecutionFeeMarketOrder, "OrderManager: fee");
        require(_executionFee == msg.value, "OrderManager: value sent is not equal to execution fee");
        bool sufficientPositionExists = checkSufficientPositionExists(msg.sender, _collateralToken, _indexToken,_isLong, _sizeDelta);
        require(sufficientPositionExists, "OrderManager: Sufficient size doesn't exist");

        return
            _createDecreasePosition(
                msg.sender,
                _collateralToken,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                _receiver,
                _acceptablePrice,
                _executionFee
            );
    }

    function _createDecreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _executionFee
    ) internal returns (bytes32) {
        DecreasePositionRequest memory request = DecreasePositionRequest(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver,
            _acceptablePrice,
            _executionFee,
            block.number,
            block.timestamp
        );

        (uint256 index, bytes32 requestKey) = _storeDecreasePositionRequest(
            request
        );
        emit CreateDecreasePosition(
            request.account,
            request._collateralToken,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.executionFee,
            index,
            decreasePositionRequestKeys.length - 1,
            block.number,
            block.timestamp
        );
        return requestKey;
    }

    function _storeDecreasePositionRequest(
        DecreasePositionRequest memory _request
    ) internal returns (uint256, bytes32) {
        address account = _request.account;
        uint256 index = decreasePositionsIndex[account] + 1;
        decreasePositionsIndex[account] = index;
        bytes32 key = getRequestKey(account, index);

        decreasePositionRequests[key] = _request;
        decreasePositionRequestKeys.push(key);

        return (index, key);
    }

    function cancelDecreasePosition(
        bytes32 _key,
        address payable _executionFeeReceiver
    ) public nonReentrant returns (bool) {
        DecreasePositionRequest memory request = decreasePositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeDecreasePositions loop will continue executing the next request
        if (request.account == address(0)) {
            return true;
        }

        bool shouldCancel = _validateCancellation(
            request.blockNumber,
            request.blockTime,
            request.account
        );
        if (!shouldCancel) {
            return false;
        }

        delete decreasePositionRequests[_key];

        (bool success,  ) = _executionFeeReceiver.call{value: request.executionFee}("");
        require(success, "OrderManager: failed to return execution fee");

        emit CancelDecreasePosition(
            request.account,
            request._collateralToken,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.executionFee,
            block.number - request.blockNumber,
            block.timestamp - request.blockTime
        );

        return true;
    }

    function executeDecreasePositions(
        uint256 _endIndex,
        address payable _executionFeeReceiver
    ) external override onlyPositionKeeper {
        uint256 index = decreasePositionRequestKeysStart;
        uint256 length = decreasePositionRequestKeys.length;

        if (index >= length) {
            return;
        }

        if (_endIndex > length) {
            _endIndex = length;
        }

        while (index < _endIndex) {
            bytes32 key = decreasePositionRequestKeys[index];

            // if the request was executed then delete the key from the array
            // if the request was not executed then break from the loop, this can happen if the
            // minimum number of blocks has not yet passed
            // an error could be thrown if the request is too old
            // in case an error was thrown, cancel the request
            try
                this.executeDecreasePosition(key, _executionFeeReceiver)
            returns (bool _wasExecuted) {
                if (!_wasExecuted) {
                    break;
                }
            } catch {
                // wrap this call in a try catch to prevent invalid cancels from blocking the loop
                try
                    this.cancelDecreasePosition(key, _executionFeeReceiver)
                returns (bool _wasCancelled) {
                    if (!_wasCancelled) {
                        break;
                    }
                } catch {
                    continue;
                }
            }

            delete decreasePositionRequestKeys[index];
            index++;
        }

        decreasePositionRequestKeysStart = index;
    }

    function executeDecreasePosition(
        bytes32 _key,
        address payable _executionFeeReceiver
    ) public nonReentrant returns (bool) {
        DecreasePositionRequest memory request = decreasePositionRequests[_key];
        // if the request was already executed or cancelled, return true so that the executeDecreasePositions loop will continue executing the next request
        if (request.account == address(0)) {
            return true;
        }

        bool shouldExecute = _validateExecution(
            request.blockNumber,
            request.blockTime,
            request.account
        );
        if (!shouldExecute) {
            return false;
        }

        delete decreasePositionRequests[_key];

        uint256 amountOut = _decreasePosition(
            request.account,
            request._collateralToken,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            address(this),
            request.acceptablePrice
        );

        IERC20(request._collateralToken).safeTransfer(
            request.receiver,
            amountOut
        );

        (bool success, ) = _executionFeeReceiver.call{value: request.executionFee}("");
        require(success, "OrderManager: Failed to send fee to executor");

        emit ExecuteDecreasePosition(
            request.account,
            request._collateralToken,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.executionFee,
            block.number - (request.blockNumber),
            block.timestamp - (request.blockTime)
        );
        return true;
    }

    function _validateExecution(
        uint256 _positionBlockNumber,
        uint256 _positionBlockTime,
        address _account
    ) internal view returns (bool) {
        require(
            block.timestamp < _positionBlockTime + (maxTimeDelay),
            "OrderManager: expired"
        );

        return
            _validateExecutionOrCancellation(
                _positionBlockNumber,
                _positionBlockTime,
                _account
            );
    }

    function _validateCancellation(
        uint256 _positionBlockNumber,
        uint256 _positionBlockTime,
        address _account
    ) internal view returns (bool) {
        return
            _validateExecutionOrCancellation(
                _positionBlockNumber,
                _positionBlockTime,
                _account
            );
    }

    function _validateExecutionOrCancellation(
        uint256 _positionBlockNumber,
        uint256 _positionBlockTime,
        address _account
    ) internal view returns (bool) {
        bool isKeeperCall = msg.sender == address(this) ||
            isPositionKeeper[msg.sender];

        if (isKeeperCall) {
            return _positionBlockNumber + minBlockDelayKeeper <= block.number;
        }
        require(msg.sender == _account, "OrderManager: 403");

        require(
            _positionBlockTime + minTimeDelayPublic <= block.timestamp,
            "OrderManager: delay"
        );

        return true;
    }

    function getRequestKey(
        address account,
        uint256 index
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, index));
    }

    //function is added only for testing purposes to prevent locking of funds. 
    //Main-net will not have this function.
    function withdrawFunds(address _token, uint256 _amount) external onlyAdmin {
        uint balance  = IERC20(_token).balanceOf(address(this));
        require(_amount <= balance,"OrderManager: Requested amount exceeds OrderManager balance");
        IERC20(_token).safeTransfer(admin, _amount);
    }

    function validatePositionOrderPrice(
        bool _triggerAboveThreshold,
        uint256 _triggerPrice,
        address _indexToken,
        bool _maximizePrice
    ) public view returns (uint256, bool) {
        uint256 currentPrice = _maximizePrice
            ? IPriceFeed(pricefeed).getMaxPriceOfToken(_indexToken) : IPriceFeed(pricefeed).getMinPriceOfToken(_indexToken);
        bool isPriceValid = _triggerAboveThreshold ? currentPrice > _triggerPrice : currentPrice < _triggerPrice;
        require(isPriceValid, "OrderManager: invalid price for execution");
        return (currentPrice, isPriceValid);
    }

    function getOrder(address _account, uint256 _orderIndex) override public view returns (
        address collateralToken,
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        bool isIncreaseOrder
    ) {
        Order memory order = orders[getOrderKey(_account, _orderIndex)];
        return (
            order.collateralToken,
            order.collateralDelta,
            order.indexToken,
            order.sizeDelta,
            order.isLong,
            order.triggerPrice,
            order.triggerAboveThreshold,
            order.executionFee,
            order.isIncreaseOrder
        );
    }

    function _validateLimitOrderPrices(uint256 currMarketPrice, bool _isLong, uint256 limitPrice) public pure {
            if(_isLong){
                require(limitPrice < currMarketPrice, "Order Manager: Limit Price should be lower than current market price for a Increase Order");
            }
            else{
                require(limitPrice > currMarketPrice, "Order Manager: Limit Price should be higher than current market price for a Decrease Order");
            }
    }

    function _validateTPSLOrderPrices(uint256 currMarketPrice, bool _isLong, uint tpPrice, uint256 slPrice) public pure {
        if(_isLong){
            if(tpPrice !=0){
                require(tpPrice > currMarketPrice, "Order Manager: TP price should be higher than curr market price for a long position");
            }
            if(slPrice !=0){
                require(slPrice < currMarketPrice, "Order Manager: SL price should be lower than curr market price for a long position");
            }
        }
        else{
            if(tpPrice !=0){
                require(tpPrice < currMarketPrice, "Order Manager: TP price should be lower than curr market price for a short position");
            }
            if(slPrice !=0){
                require(slPrice > currMarketPrice, "Order Manager: SL price should be higher than curr market price for a short position");
            }
        }
    }

    function createOrders(
        uint256 collateralDelta,
        address indexToken,
        uint256 sizeDelta,
        address collateralToken,
        bool isLong,
        bool isIncreaseOrder,
        uint256 _executionFee,
        uint256 limitPrice,
        uint256 tpPrice,
        uint256 slPrice,
        bool maxOrder
    ) external payable nonReentrant {
        require(!IVault(vault).ceaseTradingActivity(), "OrderManager: Trading Activity is ceased!");
        require(msg.value == _executionFee, "OrderManager: incorrect execution fee transferred");

        // to make sure that you can either open a limit order or tp or sl order
        if(tpPrice !=0 || slPrice !=0){
            require(limitPrice == 0, "OrderManager: Cannot open tp or sl order with a limit order");
        }
        // fee checks 
        if(tpPrice !=0 && slPrice !=0){
            require(_executionFee >= 2*minExecutionFeeLimitOrder, "OrderManager: Insufficient execution fee for limit order");
        } else{
            require(_executionFee >= minExecutionFeeLimitOrder, "OrderManager: Insufficient execution fee for limit order");
        }

        {
            uint256 _collateralDelta = collateralDelta;
            address _indexToken = indexToken;
            uint256 _sizeDelta = sizeDelta;
            address _collateralToken = collateralToken;
            bool _isLong = isLong;
            uint256 _limitPrice = limitPrice;
            bool _isIncreaseOrder = isIncreaseOrder;
            bool _maxOrder = maxOrder;
            uint256 _tpPrice= tpPrice;
            uint256 _slPrice= slPrice;

            if(limitPrice != 0){
                uint256 currMarketPrice = _isLong? IPriceFeed(pricefeed).getMaxPriceOfToken(_indexToken):IPriceFeed(pricefeed).getMinPriceOfToken(_indexToken);
                    _validateLimitOrderPrices(currMarketPrice, _isLong, _limitPrice);
        
                    IERC20(_collateralToken).safeTransferFrom(msg.sender, address(this), _collateralDelta);
                    uint256 _collateralAmountUsd = IUtils(utils).tokenToUsdMin(_collateralToken, _collateralDelta);
                    require(_collateralAmountUsd >= minPurchaseTokenAmountUsd, "OrderManager: too less collateral");
                    _createOrder(msg.sender, _collateralDelta, _collateralToken, _indexToken, _sizeDelta, _isLong, _limitPrice, !_isLong, minExecutionFeeLimitOrder, true, _maxOrder);
            }else{
                // tpsl order or limit order when closing position
                uint256 currMarketPrice = !_isLong? IPriceFeed(pricefeed).getMaxPriceOfToken(_indexToken):IPriceFeed(pricefeed).getMinPriceOfToken(_indexToken);
                _validateTPSLOrderPrices(currMarketPrice, _isLong, _tpPrice, _slPrice);
                if(tpPrice != 0){
                    _createOrder(msg.sender, 0, _collateralToken, _indexToken, _sizeDelta, _isLong, _tpPrice, _isLong, minExecutionFeeLimitOrder, false, _maxOrder);
                }
                if(slPrice !=0){
                    _createOrder(msg.sender, 0, _collateralToken, _indexToken, _sizeDelta, _isLong, _slPrice, !_isLong, minExecutionFeeLimitOrder, false, _maxOrder);
                }
            }
        }
    }


    function _createOrder(
        address _account,
        uint256 _collateralDelta,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _executionFee,
        bool _isIncreaseOrder,
        bool _isMaxOrder
    ) private {

        {
            address account = _account;
            uint256 collateralDelta = _collateralDelta;
            address collateralToken = _collateralToken;
            address indexToken = _indexToken;
            uint256 sizeDelta = _sizeDelta;
            bool isLong = _isLong;
            uint256 triggerPrice = _triggerPrice;
            bool triggerAboveThreshold = _triggerAboveThreshold;
            uint256 executionFee = _executionFee;
            bool isIncreaseOrder = _isIncreaseOrder;
            bool isMaxOrder = _isMaxOrder;

            uint256 _orderIndex = ordersIndex[account];
            ordersIndex[account] = _orderIndex+(1);
            bytes32 orderKey = getOrderKey(account,_orderIndex);
            orders[orderKey] = Order(
                account,
                collateralToken,
                indexToken,
                collateralDelta,
                sizeDelta,
                triggerPrice,
                executionFee,
                isLong,
                triggerAboveThreshold,
                isIncreaseOrder,
                isMaxOrder
            );
            EnumerableSet.add(orderKeys, orderKey);

            emitOrderCreateEvent(account, _orderIndex);
        }
        
    }

    function emitOrderCreateEvent(address _account, uint256 idx) internal{
        Order memory order = orders[getOrderKey(_account,idx)];
        emit CreateOrder(
            _account,
            order.collateralToken,
            order.indexToken,
            idx,
            order.collateralDelta,
            order.sizeDelta,
            order.triggerPrice,
            order.executionFee,
            order.isLong,
            order.triggerAboveThreshold,
            order.isIncreaseOrder,
            order.isMaxOrder
        );
        emit UpdateOrder(
            _account,
            order.collateralToken,
            order.indexToken,
            idx,
            order.collateralDelta,
            order.sizeDelta,
            order.triggerPrice,
            order.isLong,
            order.triggerAboveThreshold,
            order.isIncreaseOrder,
            order.isMaxOrder
        );
    }

    function updateOrder(uint256 _orderIndex, uint256 _sizeDelta, uint256 _newCollateralAmount,  uint256 _triggerPrice) external nonReentrant {
        Order storage order = orders[getOrderKey(msg.sender,_orderIndex)];
        require(order.account != address(0), "OrderManager: non-existent order");
        uint256 currMarketPrice = order.isLong? IPriceFeed(pricefeed).getMaxPriceOfToken(order.indexToken):IPriceFeed(pricefeed).getMinPriceOfToken(order.indexToken);
        if(order.triggerPrice > currMarketPrice){
            require(_triggerPrice > currMarketPrice, "OrderManager: Invalid price update");
        }
        else{
            require(_triggerPrice < currMarketPrice, "OrderManager: Invalid price update");
        }

        uint256 oldCollateralAmount = order.collateralDelta;
        if(order.isIncreaseOrder){
            uint256 _collateralAmountUsd = IUtils(utils).tokenToUsdMin(order.collateralToken, _newCollateralAmount);
            require(_collateralAmountUsd >= minPurchaseTokenAmountUsd, "OrderManager: too less collateral");
            bool increaseCollateral = _newCollateralAmount > oldCollateralAmount;
            uint256 collateralDelta = increaseCollateral ? (_newCollateralAmount - oldCollateralAmount) : (oldCollateralAmount - _newCollateralAmount);
            if(increaseCollateral){
                IERC20(order.collateralToken).safeTransferFrom(msg.sender, address(this), collateralDelta);
            }
            else{
                IERC20(order.collateralToken).safeTransfer(order.account, collateralDelta);
            }
            order.collateralDelta = _newCollateralAmount;
        }

        order.triggerPrice = _triggerPrice;
        order.sizeDelta = _sizeDelta;

        emit UpdateOrder(
            msg.sender,
            order.collateralToken,
            order.indexToken,
            _orderIndex,
            order.collateralDelta,
            order.sizeDelta,
            order.triggerPrice,
            order.isLong,
            order.triggerAboveThreshold,
            order.isIncreaseOrder,
            order.isMaxOrder
        );
    }

    function cancelOrder(uint256 _orderIndex, address account) public nonReentrant() {
        require(msg.sender == account || isOrderKeeper[msg.sender], "OrderManager: Cannot cancel");
        bytes32 orderKey = getOrderKey(account,_orderIndex);
        Order memory order = orders[orderKey];
        _cancelOrder(orderKey, _orderIndex,  order);
    }

    function _cancelOrder(bytes32 orderKey, uint256 _orderIndex, Order memory order) internal {
        require(order.account != address(0), "OrderManager: non-existent order");

        delete orders[orderKey];
        EnumerableSet.remove(orderKeys, orderKey);
        if(order.isIncreaseOrder){
            IERC20(order.collateralToken).safeTransfer(order.account, order.collateralDelta);
        }
        (bool success,  ) = (order.account).call{value: order.executionFee}("");
        require(success, "OrderManager: Exectuion Fee transfer failed");

        emit CancelOrder(
            order.account,
            order.collateralToken,
            order.indexToken,
            _orderIndex,
            order.collateralDelta,
            order.sizeDelta,
            order.triggerPrice,
            order.executionFee,
            order.isLong,
            order.triggerAboveThreshold,
            order.isIncreaseOrder,
            order.isMaxOrder
        );

        emit UpdateOrder(
            order.account,
            order.collateralToken,
            order.indexToken,
            _orderIndex,
            0,
            0,
            0,
            false,
            false,
            false,
            order.isMaxOrder
        );
    }

    function executeOrder(address _address, uint256 _orderIndex, address payable _feeReceiver) override public nonReentrant onlyOrderKeeper {
        bytes32 orderKey = getOrderKey(_address,_orderIndex);
        Order memory order = orders[orderKey];
        require(order.account != address(0), "OrderManager: non-existent order");

        // increase long should use max price
        // increase short should use min price
        (uint256 currentPrice, ) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            order.isLong
        );

        if(order.isIncreaseOrder){
            IERC20(order.collateralToken).safeTransfer(vault, order.collateralDelta);
            IVault(vault).increasePosition(order.account, order.collateralToken, order.indexToken, order.sizeDelta, order.isLong);

        } else{
            bool sufficientSizeExists = checkSufficientPositionExists(order.account, order.collateralToken, order.indexToken, order.isLong, order.sizeDelta);
            if(!sufficientSizeExists){
                _cancelOrder(orderKey, _orderIndex, order);
                return;
            }
            uint256 amountOut = IVault(vault).decreasePosition(order.account, order.collateralToken, order.indexToken, order.collateralDelta, order.sizeDelta, order.isLong, address(this));
            IERC20(order.collateralToken).safeTransfer(order.account, amountOut);
        }

        delete orders[orderKey];
        EnumerableSet.remove(orderKeys, orderKey);

        // pay executor
        (bool success,  ) = _feeReceiver.call{value: order.executionFee}("");
        require(success, "OrderManager: Exectuion Fee transfer failed");

        emit ExecuteOrder(
            order.account,
            order.collateralToken,
            order.indexToken,
            _orderIndex,
            order.collateralDelta,
            order.sizeDelta,
            order.triggerPrice,
            order.executionFee,
            currentPrice,
            order.isLong,
            order.triggerAboveThreshold,
            order.isIncreaseOrder
        );
        emit UpdateOrder(
            order.account,
            order.collateralToken,
            order.indexToken,
            _orderIndex,
            0,
            0,
            0,
            false,
            false,
            false,
            order.isMaxOrder
        );
    }

    function getOrderKey(address _account, uint256 index) public pure returns(bytes32){
        return keccak256(abi.encodePacked(_account, index));
    }

    function getAllOrders() public view returns(Order[] memory){
        uint orderLength = EnumerableSet.length(orderKeys);
        Order[] memory openOrders = new Order[](orderLength);
        for(uint i =0;i<orderLength;i++){
            openOrders[i] = (orders[EnumerableSet.at(orderKeys, i)]);
        }
        return openOrders;
    }

    function executeMultipleOrders(address[] calldata accountAddresses, uint[] calldata orderIndices, address payable _feeReceiver) public onlyOrderKeeper {
        uint length = accountAddresses.length;
        for(uint i=0;i<length;i++){
            try this.executeOrder(accountAddresses[i], orderIndices[i], _feeReceiver){} catch {}
        }
    }

    function liquidateMultiplePositions(bytes32[] calldata keys, address payable _feeReceiver) public onlyLiquidator {
        uint length = keys.length;
        for(uint i=0;i<length;i++){
            try IVault(vault).liquidatePosition(keys[i],_feeReceiver){} catch{}
        }
    }

    function checkSufficientPositionExists(address account, address collateralToken, address indexToken, bool isLong, uint sizeDelta) private view returns(bool) {
        (uint size,,,,,,,,) = IVault(vault).getPosition(account, collateralToken, indexToken, isLong);
        if(size < sizeDelta){
            return false;
        }
        return true;
    }
}