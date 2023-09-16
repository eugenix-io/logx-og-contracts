// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../libraries/utils/ReentrancyGuard.sol';
import '../libraries/token/IERC20.sol';
import './BaseOrderManager.sol';
import './interfaces/IOrderManager.sol';
import '../libraries/utils/EnumerableSet.sol';

contract OrderManager is
    BaseOrderManager,
    IOrderManager,
    ReentrancyGuard
{
    struct IncreasePositionRequest {
        address account;
        address _collateralToken;
        address indexToken;
        uint256 amountIn;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 blockNumber;
        uint256 blockTime;    }

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
    }

    uint256 public minExecutionFeeMarketOrder;
    uint256 public minExecutionFeeLimitOrder;
    mapping(address => uint256) increasePositionsIndex;
    mapping(bytes32 => IncreasePositionRequest) increasePositionRequests;
    bytes32[] increasePositionRequestKeys;
    mapping(address => uint256) decreasePositionsIndex;
    mapping(bytes32 => DecreasePositionRequest) decreasePositionRequests;
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
        bool indexed isIncreaseOrder
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
        bool indexed isIncreaseOrder
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
        bool indexed isIncreaseOrder
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
        uint256 _minExecutionFeeMarketOrder, 
        uint256 _minExecutionFeeLimitOrder
    ) BaseOrderManager(_vault) {
        minExecutionFeeMarketOrder = _minExecutionFeeMarketOrder;
        minExecutionFeeLimitOrder = _minExecutionFeeLimitOrder;
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

    function setMinExecutionFeeMarketOrder(uint256 _minExecutionFeeMarketOrder) external onlyAdmin {
        minExecutionFeeMarketOrder = _minExecutionFeeMarketOrder;
    }

    function setMinExecutionFeeLimitOrder(uint256 _minExecutionFeeLimitOrder) external onlyAdmin {
        minExecutionFeeLimitOrder = _minExecutionFeeLimitOrder;
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
        uint256 _executionFee
    ) external payable nonReentrant returns (bytes32) {
        require(_executionFee >= minExecutionFeeMarketOrder, "OrderManager: execution fee less than min execution fee");
        require(_executionFee == msg.value, "OrderManager: execution fee not equal to value in msg.value");

        if (_amountIn > 0) {
            IERC20(_collateralToken).transferFrom(
                msg.sender,
                address(this),
                _amountIn
            );
        }

        return
            _createIncreasePosition(
                msg.sender,
                _collateralToken,
                _indexToken,
                _amountIn,
                _sizeDelta,
                _isLong,
                _acceptablePrice,
                _executionFee
            );
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
        IncreasePositionRequest memory request = IncreasePositionRequest(
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
        IncreasePositionRequest memory request = increasePositionRequests[_key];
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
        IERC20(request._collateralToken).transfer(request.account, request.amountIn);
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
                } catch {}
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
        IncreasePositionRequest memory request = increasePositionRequests[_key];
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
        IERC20(request._collateralToken).transfer(vault, afterFeeAmount);

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
        IncreasePositionRequest memory _request
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
        require(_executionFee >= minExecutionFeeMarketOrder, "OrderManager: fee");
        require(_executionFee == msg.value, "OrderManager: value sent is not equal to execution fee");

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
                } catch {}
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

        IERC20(request._collateralToken).transfer(
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
    function withdrawFunds(address _token) external onlyAdmin {
        uint balance  = IERC20(_token).balanceOf(address(this));
        IERC20(_token).transfer(admin, balance);
    }

    function validatePositionOrderPrice(
        bool _triggerAboveThreshold,
        uint256 _triggerPrice,
        address _indexToken,
        bool _maximizePrice
    ) public view returns (uint256, bool) {
        uint256 currentPrice = _maximizePrice
            ? IVault(vault).getMaxPrice(_indexToken) : IVault(vault).getMinPrice(_indexToken);
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

    function createOrder(
        uint256 _collateralDelta,
        address _indexToken,
        uint256 _sizeDelta,
        address _collateralToken,
        bool _isLong,
        uint256 _triggerPrice,
        bool _triggerAboveThreshold,
        uint256 _executionFee,
        bool isIncreaseOrder
    ) external payable nonReentrant returns(address, uint256) {
        // always need this call because of mandatory executionFee user has to transfer in ETH
        //_transferInETH();

        require(_executionFee >= minExecutionFeeLimitOrder, "OrderManager: insufficient execution fee");
        require(msg.value == _executionFee, "OrderManager: incorrect execution fee transferred");
        if(isIncreaseOrder){
            IERC20(_collateralToken).transferFrom(msg.sender, address(this), _collateralDelta);
        }

        {
            uint256 _collateralAmountUsd = IVault(vault).tokenToUsdMin(_collateralToken, _collateralDelta);
            require(_collateralAmountUsd >= minPurchaseTokenAmountUsd, "OrderManager: too less collateral");
        }

        return _createOrder(
            msg.sender,
            _collateralDelta,
            _collateralToken,
            _indexToken,
            _sizeDelta,
            _isLong,
            _triggerPrice,
            _triggerAboveThreshold,
            _executionFee,
            isIncreaseOrder
        );
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
        bool isIncreaseOrder
    ) private returns(address, uint256){
        uint256 _orderIndex = ordersIndex[_account];
        ordersIndex[_account] = _orderIndex+(1);
        bytes32 orderKey = getOrderKey(_account,_orderIndex);
        orders[orderKey] = Order(
            _account,
            _collateralToken,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _triggerPrice,
            _executionFee,
            _isLong,
            _triggerAboveThreshold,
            isIncreaseOrder
        );
        EnumerableSet.add(orderKeys, orderKey);

        emitOrderCreateEvent(_account, _orderIndex);
        return(msg.sender, _orderIndex);
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
            order.isIncreaseOrder
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
            order.isIncreaseOrder
        );
    }

    function updateOrder(uint256 _orderIndex, uint256 _sizeDelta, uint256 _collateralDelta,  uint256 _triggerPrice, bool _triggerAboveThreshold) external nonReentrant {
        Order storage order = orders[getOrderKey(msg.sender,_orderIndex)];
        require(order.account != address(0), "OrderManager: non-existent order");

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;
        order.collateralDelta = _collateralDelta;

        emit UpdateOrder(
            msg.sender,
            order.collateralToken,
            order.indexToken,
            _orderIndex,
            _collateralDelta,
            _sizeDelta,
            _triggerPrice,
            order.isLong,
            _triggerAboveThreshold,
            order.isIncreaseOrder
        );
    }

    function cancelOrder(uint256 _orderIndex) public nonReentrant {
        bytes32 orderKey = getOrderKey(msg.sender,_orderIndex);
        Order memory order = orders[orderKey];
        require(order.account != address(0), "OrderManager: non-existent order");

        delete orders[orderKey];
        EnumerableSet.remove(orderKeys, orderKey);
        IERC20(order.collateralToken).transfer(msg.sender, order.collateralDelta);
        (bool success,  ) = (msg.sender).call{value: order.executionFee}("");
        require(success, "OrderManager: Exectuion Fee transfer failed");

        

        emit CancelOrder(
            order.account,
            order.collateralToken,
            order.indexToken,
            _orderIndex,
            order.collateralDelta,
            order.sizeDelta,
            order.executionFee,
            order.triggerPrice,
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
            false
        );
    }

    function _validateIncreaseOrder(address _account, uint256 _orderIndex) internal view {
        (
            ,//address _collateralToken,
            ,//amountIn
            address _indexToken,
            uint256 _sizeDelta,
            bool _isLong,
            , // triggerPrice
            , // triggerAboveThreshold
            // executionFee
            , // isIncreaseOrder
        ) = getOrder(_account, _orderIndex);

        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);

    }

    function executeOrder(address _address, uint256 _orderIndex, address payable _feeReceiver) override external nonReentrant onlyOrderKeeper {
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
            _validateIncreaseOrder(_address, _orderIndex);
            IERC20(order.collateralToken).transfer(vault, order.collateralDelta);
            IVault(vault).increasePosition(order.account, order.collateralToken, order.indexToken, order.sizeDelta, order.isLong);

        } else{
            uint256 amountOut = IVault(vault).decreasePosition(order.account, order.collateralToken, order.indexToken, order.collateralDelta, order.sizeDelta, order.isLong, address(this));
            IERC20(order.collateralToken).transfer(order.account, amountOut);
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
            false
        );
    }

    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        address _feeReceiver
    ) external nonReentrant onlyLiquidator {
        IVault(vault).liquidatePosition(_account, _collateralToken, _indexToken, _isLong, _feeReceiver);
    }

    function getOrderKey(address _account, uint256 index) public pure returns(bytes32){
        return keccak256(abi.encodePacked(_account, index));
    }
}