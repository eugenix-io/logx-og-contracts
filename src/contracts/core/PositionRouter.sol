// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../libraries/utils/ReentrancyGuard.sol';
import './interfaces/IRouter.sol';
import '../libraries/token/IERC20.sol';
import '../libraries/token/SafeERC20.sol';
import './BasePositionManager.sol';
import './interfaces/IPositionRouter.sol';
/**
 * Currently we are accepting execution fee in the same token as collateral which is USDC. 
 * AnirudhTodo - add constructor.
*/
contract PositionRouter is
    BasePositionManager,
    IPositionRouter,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    struct IncreasePositionRequest {
        address account;
        address[] path;
        address indexToken;
        uint256 amountIn;
        uint256 minOut;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 blockNumber;
        uint256 blockTime;
        bool hasCollateralInETH;
    }

    struct DecreasePositionRequest {
        address account;
        address[] path;
        address indexToken;
        uint256 collateralDelta;
        uint256 sizeDelta;
        bool isLong;
        address receiver;
        uint256 acceptablePrice;
        uint256 minOut;
        uint256 executionFee;
        uint256 blockNumber;
        uint256 blockTime;
    }

    uint256 public minExecutionFee;
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

    event CreateIncreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 amountIn,
        uint256 minOut,
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
        address[] path,
        address indexToken,
        uint256 amountIn,
        uint256 minOut,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event CreateDecreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 minOut,
        uint256 executionFee,
        uint256 index,
        uint256 queueIndex,
        uint256 blockNumber,
        uint256 blockTime
    );

    event ExecuteDecreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 minOut,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event CancelDecreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 minOut,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event ExecuteIncreasePosition(
        address indexed account,
        address[] path,
        address indexToken,
        uint256 amountIn,
        uint256 minOut,
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

    constructor(
        address _vault,
        address _router,
        address _shortsTracker,
        uint256 _depositFee,
        uint256 _minExecutionFee
    ) BasePositionManager(_vault, _router, _shortsTracker, _depositFee) {
        minExecutionFee = _minExecutionFee;
    }

    modifier onlyPositionKeeper() {
        require(isPositionKeeper[msg.sender], "403");
        _;
    }

    function setPositionKeeper(
        address _account,
        bool _isActive
    ) external onlyAdmin {
        isPositionKeeper[_account] = _isActive;
        emit SetPositionKeeper(_account, _isActive);
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
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee
    ) external payable nonReentrant returns (bytes32) {
        require(_executionFee >= minExecutionFee, "fee");
        require(_path.length == 1 || _path.length == 2, "len");

        if (_amountIn > 0) {
            //AnirudhInfo - path[0] is collateral token.
            IRouter(router).pluginTransfer(
                _path[0],
                msg.sender,
                address(this),
                _amountIn + _executionFee
            );
        }

        return
            _createIncreasePosition(
                msg.sender,
                _path,
                _indexToken,
                _amountIn,
                _minOut,
                _sizeDelta,
                _isLong,
                _acceptablePrice,
                _executionFee,
                false
            );
    }

    function _createIncreasePosition(
        address _account,
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        uint256 _minOut,
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _acceptablePrice,
        uint256 _executionFee,
        bool _hasCollateralInETH
    ) internal returns (bytes32) {
        IncreasePositionRequest memory request = IncreasePositionRequest(
            _account,
            _path,
            _indexToken,
            _amountIn,
            _minOut,
            _sizeDelta,
            _isLong,
            _acceptablePrice,
            _executionFee,
            block.number,
            block.timestamp,
            _hasCollateralInETH
        );

        (uint256 index, bytes32 requestKey) = _storeIncreasePositionRequest(
            request
        );
        emit CreateIncreasePosition(
            _account,
            _path,
            _indexToken,
            _amountIn,
            _minOut,
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
        //execution fee should also be provided in collateral token
        IERC20(request.path[0]).safeTransfer(request.account, request.amountIn);
        IERC20(request.path[0]).safeTransfer(
            _executionFeeReceiver,
            request.executionFee
        );

        emit CancelIncreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.amountIn,
            request.minOut,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice,
            request.executionFee,
            block.number - request.blockNumber,
            block.timestamp - request.blockTime
        );

        return true;
    }

    function createDecreasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _minOut,
        uint256 _executionFee
    ) external payable nonReentrant returns (bytes32) {
        require(_executionFee >= minExecutionFee, "fee");
        require(_path.length == 1 || _path.length == 2, "len");
        //AnirudhCheck - transfering execution fees to PositionRouter
        IERC20(_path[0]).safeTransferFrom(
            msg.sender,
            address(this),
            _executionFee
        );

        return
            _createDecreasePosition(
                msg.sender,
                _path,
                _indexToken,
                _collateralDelta,
                _sizeDelta,
                _isLong,
                _receiver,
                _acceptablePrice,
                _minOut,
                _executionFee
            );
    }

    function _createDecreasePosition(
        address _account,
        address[] memory _path,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _acceptablePrice,
        uint256 _minOut,
        uint256 _executionFee
    ) internal returns (bytes32) {
        DecreasePositionRequest memory request = DecreasePositionRequest(
            _account,
            _path,
            _indexToken,
            _collateralDelta,
            _sizeDelta,
            _isLong,
            _receiver,
            _acceptablePrice,
            _minOut,
            _executionFee,
            block.number,
            block.timestamp
        );

        (uint256 index, bytes32 requestKey) = _storeDecreasePositionRequest(
            request
        );
        emit CreateDecreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.minOut,
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

        IERC20(request.path[0]).safeTransfer(
            _executionFeeReceiver,
            request.executionFee
        );

        emit CancelDecreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.minOut,
            request.executionFee,
            block.number - request.blockNumber,
            block.timestamp - request.blockTime
        );

        return true;
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
            return _positionBlockNumber - minBlockDelayKeeper <= block.number;
        }
        require(msg.sender == _account, "403");

        require(
            _positionBlockTime + minTimeDelayPublic <= block.timestamp,
            "delay"
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

        if (request.amountIn > 0) {
            uint256 amountIn = request.amountIn;
            uint256 afterFeeAmount = _collectFees(
                request.account,
                request.path,
                amountIn,
                request.indexToken,
                request.isLong,
                request.sizeDelta
            );
            IERC20(request.path[request.path.length - 1]).safeTransfer(
                vault,
                afterFeeAmount
            );
        }

        _increasePosition(
            request.account,
            request.path[request.path.length - 1],
            request.indexToken,
            request.sizeDelta,
            request.isLong,
            request.acceptablePrice
        );

        //_transferOutETHWithGasLimitFallbackToWeth(request.executionFee, _executionFeeReceiver);

        emit ExecuteIncreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.amountIn,
            request.minOut,
            request.sizeDelta,
            request.isLong,
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
            "expired"
        );

        return
            _validateExecutionOrCancellation(
                _positionBlockNumber,
                _positionBlockTime,
                _account
            );
    }

    function getRequestKey(
        address account,
        uint256 index
    ) internal pure returns (bytes32) {
        //AnirudhTodo - remove keccak256 as hashing is not needed here. Hashing is implemented
        // as GMX does it.
        return keccak256(abi.encodePacked(account, index));
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
            request.path[0],
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            address(this),
            request.acceptablePrice
        );

        IERC20(request.path[request.path.length - 1]).safeTransfer(
            request.receiver,
            amountOut
        );

        emit ExecuteDecreasePosition(
            request.account,
            request.path,
            request.indexToken,
            request.collateralDelta,
            request.sizeDelta,
            request.isLong,
            request.receiver,
            request.acceptablePrice,
            request.minOut,
            request.executionFee,
            block.number - (request.blockNumber),
            block.timestamp - (request.blockTime)
        );
        return true;
    }

    //AniurdhTodo - need to complete these implementations or remove them from Interface itself.
}