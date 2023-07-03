// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import './BasePositionManager.sol';
import './interfaces/IVault.sol';
import './interfaces/IPositionsTracker.sol';
import './interfaces/ITimeLock.sol';
import '../libraries/utils/ReentrancyGuard.sol';
import './interfaces/IOrderBook.sol';
import '../libraries/token/SafeERC20.sol';

contract PositionManager is BasePositionManager, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public orderBook;
    //AnirudhTodo - research to findout what is inLegacy mode.
    bool public inLegacyMode;
    bool public shouldValidateIncreaseOrder;

    mapping (address => bool) public isOrderKeeper;
    mapping (address => bool) public isPartner;
    mapping (address => bool) public isLiquidator;

    constructor(
        address _vault,
        address _router,
        address _positionsTracker,
        uint256 _depositFee,
        address _orderBook
    ) BasePositionManager(_vault, _router, _positionsTracker, _depositFee){
        orderBook = _orderBook;
    }
    //AnirudhTodo - research about this mode and check if it is needed?
    modifier onlyPartnersOrLegacyMode() {
        require(isPartner[msg.sender] || inLegacyMode, "PositionManager: forbidden");
        _;
    }

    modifier onlyLiquidator() {
        require(isLiquidator[msg.sender], "PositionManager: forbidden");
        _;
    }

    modifier onlyOrderKeeper() {
        require(isOrderKeeper[msg.sender], "PositionManager: forbidden");
        _;
    }

    function increasePosition(
        address[] memory _path,
        address _indexToken,
        uint256 _amountIn,
        //uint256 _minOut, //AniurdhTodo - check if this is definitely not needed
        uint256 _sizeDelta,
        bool _isLong,
        uint256 _price
    ) external nonReentrant onlyPartnersOrLegacyMode {
        require(_path.length == 1 || _path.length == 2, "PositionManager: invalid _path.length");

        if (_amountIn > 0) {
            if (_path.length == 1) {
                IRouter(router).pluginTransfer(_path[0], msg.sender, address(this), _amountIn);
            }

            uint256 afterFeeAmount = _collectFees(msg.sender, _path, _amountIn, _indexToken, _isLong, _sizeDelta);
            IERC20(_path[_path.length - 1]).safeTransfer(vault, afterFeeAmount);
        }

        _increasePosition(msg.sender, _path[_path.length - 1], _indexToken, _sizeDelta, _isLong, _price);
    }

    function decreasePosition(
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver,
        uint256 _price
    ) external nonReentrant onlyPartnersOrLegacyMode {
        _decreasePosition(msg.sender, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver, _price);
    }

    function liquidatePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong,
        address _feeReceiver
    ) external nonReentrant onlyLiquidator {
        address _vault = vault;
        address timelock = IVault(_vault).gov();
        (uint256 size, , , , , , , ) = IVault(vault).getPosition(_account, _collateralToken, _indexToken, _isLong);

        uint256 markPrice = _isLong ? IVault(_vault).getMinPrice(_indexToken) : IVault(_vault).getMaxPrice(_indexToken);
        // should be called strictly before position is updated in Vault
        IPositionsTracker(positionsTracker).updateGlobalPositionsData(_account, _collateralToken, _indexToken, size, markPrice, false, _isLong);
        

        ITimelock(timelock).enableLeverage(_vault);
        IVault(_vault).liquidatePosition(_account, _collateralToken, _indexToken, _isLong, _feeReceiver);
        ITimelock(timelock).disableLeverage(_vault);
    }

    function executeIncreaseOrder(address _account, uint256 _orderIndex, address payable _feeReceiver) external onlyOrderKeeper {
        _validateIncreaseOrder(_account, _orderIndex);

        address _vault = vault;
        address timelock = IVault(_vault).gov();

        (
            /*address purchaseToken*/,
            /*uint256 purchaseTokenAmount*/,
            address collateralToken,
            address indexToken,
            uint256 sizeDelta,
            bool isLong,
            /*uint256 triggerPrice*/,
            /*bool triggerAboveThreshold*/,
            /*uint256 executionFee*/
        ) = IOrderBook(orderBook).getIncreaseOrder(_account, _orderIndex);

        uint256 markPrice = isLong ? IVault(_vault).getMaxPrice(indexToken) : IVault(_vault).getMinPrice(indexToken);
        // should be called strictly before position is updated in Vault
        IPositionsTracker(positionsTracker).updateGlobalPositionsData(_account, collateralToken, indexToken, sizeDelta, markPrice, false, isLong);
        

        ITimelock(timelock).enableLeverage(_vault);
        IOrderBook(orderBook).executeIncreaseOrder(_account, _orderIndex, _feeReceiver);
        ITimelock(timelock).disableLeverage(_vault);

    }

    function executeDecreaseOrder(address _account, uint256 _orderIndex, address payable _feeReceiver) external onlyOrderKeeper {
        address _vault = vault;
        address timelock = IVault(_vault).gov();

        (
            address collateralToken,
            /*uint256 collateralDelta*/,
            address indexToken,
            uint256 sizeDelta,
            bool isLong,
            /*uint256 triggerPrice*/,
            /*bool triggerAboveThreshold*/,
            /*uint256 executionFee*/
        ) = IOrderBook(orderBook).getDecreaseOrder(_account, _orderIndex);

        uint256 markPrice = isLong ? IVault(_vault).getMinPrice(indexToken) : IVault(_vault).getMaxPrice(indexToken);
        // should be called strictly before position is updated in Vault
        IPositionsTracker(positionsTracker).updateGlobalPositionsData(_account, collateralToken, indexToken, sizeDelta, markPrice, false, isLong);
        
        

        ITimelock(timelock).enableLeverage(_vault);
        IOrderBook(orderBook).executeDecreaseOrder(_account, _orderIndex, _feeReceiver);
        ITimelock(timelock).disableLeverage(_vault);

    }

    function _validateIncreaseOrder(address _account, uint256 _orderIndex) internal view {
        (
            address _purchaseToken,
            uint256 _purchaseTokenAmount,
            address _collateralToken,
            address _indexToken,
            uint256 _sizeDelta,
            bool _isLong,
            , // triggerPrice
            , // triggerAboveThreshold
            // executionFee
        ) = IOrderBook(orderBook).getIncreaseOrder(_account, _orderIndex);

        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);

        if (!shouldValidateIncreaseOrder) { return; }

        // shorts are okay
        //AnirudhTodo - why shorts are okay and not longs
        if (!_isLong) { return; }

        // if the position size is not increasing, this is a collateral deposit
        require(_sizeDelta > 0, "PositionManager: long deposit");

        IVault _vault = IVault(vault);
        (uint256 size, uint256 collateral, , , , , , ) = _vault.getPosition(_account, _collateralToken, _indexToken, _isLong);

        // if there is no existing position, do not charge a fee
        if (size == 0) { return; }

        uint256 nextSize = size+(_sizeDelta);
        uint256 collateralDelta = _vault.tokenToUsdMin(_purchaseToken, _purchaseTokenAmount);
        uint256 nextCollateral = collateral+(collateralDelta);

        uint256 prevLeverage = size*(BASIS_POINTS_DIVISOR)/(collateral);
        // allow for a maximum of a increasePositionBufferBps decrease since there might be some swap fees taken from the collateral
        uint256 nextLeverageWithBuffer = nextSize*(BASIS_POINTS_DIVISOR + increasePositionBufferBps)/(nextCollateral);

        require(nextLeverageWithBuffer >= prevLeverage, "PositionManager: long leverage decrease");
    }
}