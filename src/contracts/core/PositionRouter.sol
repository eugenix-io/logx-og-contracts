// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../libraries/utils/ReentrancyGuard.sol';
import './interfaces/IRouter.sol';
import '../libraries/token/IERC20.sol';
import '../libraries/token/SafeERC20.sol';
import './BasePositionManager.sol';
import './interfaces/IPositionRouter.sol';

contract PositionRouter is
    BasePositionManager,
    IPositionRouter,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

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

    uint256 public minExecutionFee;
    //mapping from user address to number of increase position requests sent from that address
    mapping(address => uint256) increasePositionsIndex;
    //mapping with key = keccak256(userAddress, index) and value = increase position request
    mapping(bytes32 => IncreasePositionRequest) increasePositionRequests;
    //array of increase position request keys
    bytes32[] increasePositionRequestKeys;
    mapping(address => uint256) decreasePositionsIndex;
    mapping(bytes32 => DecreasePositionRequest) decreasePositionRequests;
    bytes32[] decreasePositionRequestKeys;
    mapping(address => bool) public isPositionKeeper;//address of priceFeed contract needs to be added to this mapping
    uint256 public minBlockDelayKeeper;
    uint256 public minTimeDelayPublic;
    uint256 public maxTimeDelay;
    uint256 public increasePositionRequestKeysStart;
    uint256 public decreasePositionRequestKeysStart;

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

    event SetPositionKeeper(address indexed account, bool isActive);
    event SetDelayValues(
        uint256 minBlockDelayKeeper,
        uint256 minTimeDelayPublic,
        uint256 maxTimeDelay
    );

    event SetMinExecutionFee(uint256 minExecutionFee);

    constructor(
        address _vault,
        address _router,
        uint256 _minExecutionFee
    ) BasePositionManager(_vault, _router) {
        minExecutionFee = _minExecutionFee;
    }

    modifier onlyPositionKeeper() {
        require(isPositionKeeper[msg.sender], "PositionRouter: 403");
        _;
    }

    function setPositionKeeper(
        address _account,
        bool _isActive
    ) external onlyAdmin {
        isPositionKeeper[_account] = _isActive;
        emit SetPositionKeeper(_account, _isActive);
    }

    function setMinExecutionFee(uint256 _minExecutionFee) external onlyAdmin {
        minExecutionFee = _minExecutionFee;
        emit SetMinExecutionFee(_minExecutionFee);
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



    function createIncreasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _amountIn,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee
    ) external payable nonReentrant returns (bytes32) {
        require(_executionFee >= minExecutionFee, "PositionRouter: execution fee less than min execution fee");
        require(_executionFee == msg.value, "PositionRouter: execution fee not equal to value in msg.value");

        if (_amountIn > 0) {
            IRouter(router).pluginTransfer(
                _collateralToken,
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
        IERC20(request._collateralToken).safeTransfer(request.account, request.amountIn);
        (bool success,  ) = _executionFeeReceiver.call{value: request.executionFee}("");
        require(success, "PositionRouter: failed to return execution fee");

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

        _increasePosition(
            request.account,
            request._collateralToken,
            request.indexToken,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice
        );

        (bool success,  ) = _executionFeeReceiver.call{value: request.executionFee}("");
        require(success, "PositionRouter: failed to send eth to executor");

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
        require(_executionFee >= minExecutionFee, "PositionRouter: fee");
        require(_executionFee == msg.value, "PositionRouter: value sent is not equal to execution fee");

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
        require(success, "PositionRouter: failed to return execution fee");

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

        IERC20(request._collateralToken).safeTransfer(
            request.receiver,
            amountOut
        );

        (bool success, ) = _executionFeeReceiver.call{value: request.executionFee}("");
        require(success, "Posiiton Router: Failed to send fee to executor");

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
            "PositionRouter: expired"
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
        require(msg.sender == _account, "PositionRouter: 403");

        require(
            _positionBlockTime + minTimeDelayPublic <= block.timestamp,
            "PositionRouter: delay"
        );

        return true;
    }

    function getRequestKey(
        address account,
        uint256 index
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, index));
    }

}