// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import './BasePositionManager.sol';
import './interfaces/IVault.sol';
import './interfaces/ITimeLock.sol';
import '../libraries/utils/ReentrancyGuard.sol';
import './interfaces/IOrderBook.sol';

contract PositionManager is BasePositionManager, ReentrancyGuard {
    address public orderBook;

    mapping (address => bool) public isOrderKeeper;
    mapping (address => bool) public isPartner;
    mapping (address => bool) public isLiquidator;

    event SetOrderKeeper(address indexed account, bool isActive);
    event SetLiquidator(address indexed account, bool isActive);

    constructor(
        address _vault,
        address _router,
        address _orderBook
    ) BasePositionManager(_vault, _router){
        orderBook = _orderBook;
    }

    modifier onlyLiquidator() {
        require(isLiquidator[msg.sender], "PositionManager: forbidden");
        _;
    }

    modifier onlyOrderKeeper() {
        require(isOrderKeeper[msg.sender], "PositionManager: forbidden");
        _;
    }

    function setOrderKeeper(address _account, bool _isActive) external onlyAdmin {
        isOrderKeeper[_account] = _isActive;
        emit SetOrderKeeper(_account, _isActive);
    }

    function setLiquidator(address _account, bool _isActive) external onlyAdmin {
        isLiquidator[_account] = _isActive;
        emit SetLiquidator(_account, _isActive);
    }

    function setOrderBook(address _orderBook) external onlyAdmin {
        orderBook = _orderBook;
    }

    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        address _feeReceiver
    ) external nonReentrant onlyLiquidator {
        address _vault = vault;
        IVault(_vault).liquidatePosition(_account, _collateralToken, _indexToken, _isLong, _feeReceiver);
    }

    function executeIncreaseOrder(address _account, uint256 _orderIndex, address payable _feeReceiver) external onlyOrderKeeper {
        _validateIncreaseOrder(_account, _orderIndex);
        IOrderBook(orderBook).executeOrder(_account, _orderIndex, _feeReceiver);

    }

    function executeDecreaseOrder(address _account, uint256 _orderIndex, address payable _feeReceiver) external onlyOrderKeeper {
        IOrderBook(orderBook).executeOrder(_account, _orderIndex, _feeReceiver);

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
        ) = IOrderBook(orderBook).getOrder(_account, _orderIndex);

        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);

    }
}