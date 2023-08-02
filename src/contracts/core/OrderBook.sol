// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "../libraries/token/IERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRouter.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IOrderBook.sol";

contract OrderBook is ReentrancyGuard, IOrderBook {

    uint256 public constant PRICE_PRECISION = 1e30;
    uint256 public constant USDL_PRECISION = 1e18;

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

    mapping (address => mapping(uint256 => Order)) public orders;
    mapping (address => uint256) public ordersIndex;

    address public gov;
    address public usdl;
    address public router;
    address public vault;
    uint256 public minExecutionFee;
    uint256 public minPurchaseTokenAmountUsd;
    bool public isInitialized = false;

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
    event UpdateOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 sizeDelta,
        uint256 collateralDelta,
        uint256 triggerPrice,
        bool isLong,
        bool triggerAboveThreshold
    );

    event Initialize(
        address router,
        address vault,
        address usdl,
        uint256 minExecutionFee,
        uint256 minPurchaseTokenAmountUsd
    );
    event UpdateMinExecutionFee(uint256 minExecutionFee);
    event UpdateMinPurchaseTokenAmountUsd(uint256 minPurchaseTokenAmountUsd);
    event UpdateGov(address gov);

    modifier onlyGov() {
        require(msg.sender == gov, "OrderBook: forbidden");
        _;
    }

    constructor() {
        gov = msg.sender;
    }

    function initialize(
        address _router,
        address _vault,
        address _usdl,
        uint256 _minExecutionFee,
        uint256 _minPurchaseTokenAmountUsd
    ) external onlyGov {
        require(!isInitialized, "OrderBook: already initialized");
        isInitialized = true;

        router = _router;
        vault = _vault;
        usdl = _usdl;
        minExecutionFee = _minExecutionFee;
        minPurchaseTokenAmountUsd = _minPurchaseTokenAmountUsd;

        emit Initialize(_router, _vault, _usdl, _minExecutionFee, _minPurchaseTokenAmountUsd);
    }

    function setMinExecutionFee(uint256 _minExecutionFee) external onlyGov {
        minExecutionFee = _minExecutionFee;

        emit UpdateMinExecutionFee(_minExecutionFee);
    }

    function setMinPurchaseTokenAmountUsd(uint256 _minPurchaseTokenAmountUsd) external onlyGov {
        minPurchaseTokenAmountUsd = _minPurchaseTokenAmountUsd;

        emit UpdateMinPurchaseTokenAmountUsd(_minPurchaseTokenAmountUsd);
    }

    function setGov(address _gov) external onlyGov {
        gov = _gov;

        emit UpdateGov(_gov);
    }

    function getUsdlMinPrice(address _otherToken) internal view returns (uint256) {
        uint256 redemptionAmount = IVault(vault).getRedemptionAmount(_otherToken, USDL_PRECISION);
        uint256 otherTokenPrice = IVault(vault).getMinPrice(_otherToken);

        uint256 otherTokenDecimals = IVault(vault).tokenDecimals(_otherToken);
        return redemptionAmount*(otherTokenPrice)/(10 ** otherTokenDecimals);
    }

    function validatePositionOrderPrice(
        bool _triggerAboveThreshold,
        uint256 _triggerPrice,
        address _indexToken,
        bool _maximizePrice,
        bool _raise
    ) public view returns (uint256, bool) {
        uint256 currentPrice = _maximizePrice
            ? IVault(vault).getMaxPrice(_indexToken) : IVault(vault).getMinPrice(_indexToken);
        bool isPriceValid = _triggerAboveThreshold ? currentPrice > _triggerPrice : currentPrice < _triggerPrice;
        if (_raise) {
            require(isPriceValid, "OrderBook: invalid price for execution");
        }
        return (currentPrice, isPriceValid);
    }

    function getOrder(address _account, uint256 _orderIndex) override external view returns (
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
        Order memory order = orders[_account][_orderIndex];
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

        require(_executionFee >= minExecutionFee, "OrderBook: insufficient execution fee");
        require(msg.value == _executionFee, "OrderBook: incorrect execution fee transferred");
        IRouter(router).pluginTransfer(_collateralToken, msg.sender, address(this), _collateralDelta);

        {
            uint256 _collateralAmountUsd = IVault(vault).tokenToUsdMin(_collateralToken, _collateralDelta);
            require(_collateralAmountUsd >= minPurchaseTokenAmountUsd, "OrderBook: insufficient collateral");
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
        orders[_account][_orderIndex] = Order(
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

        emitOrderCreateEvent(_account, _orderIndex);
        return(msg.sender, _orderIndex);
    }

    function emitOrderCreateEvent(address _account, uint256 idx) internal{
        Order memory order = orders[_account][idx];
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
    }

    function updateOrder(uint256 _orderIndex, uint256 _sizeDelta, uint256 _collateralDelta,  uint256 _triggerPrice, bool _triggerAboveThreshold) external nonReentrant {
        Order storage order = orders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        order.triggerPrice = _triggerPrice;
        order.triggerAboveThreshold = _triggerAboveThreshold;
        order.sizeDelta = _sizeDelta;
        order.collateralDelta = _collateralDelta;

        emit UpdateOrder(
            msg.sender,
            order.collateralToken,
            order.indexToken,
            _orderIndex,
            _sizeDelta,
            _collateralDelta,
            _triggerPrice,
            order.isLong,
            _triggerAboveThreshold
        );
    }

    function cancelOrder(uint256 _orderIndex) public nonReentrant {
        Order memory order = orders[msg.sender][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        delete orders[msg.sender][_orderIndex];
        IERC20(order.collateralToken).transfer(msg.sender, order.collateralDelta);
        (bool success,  ) = (msg.sender).call{value: order.executionFee}("");

        

        emit CancelOrder(
            order.account,
            order.collateralToken,
            order.indexToken,
            order.collateralDelta,
            _orderIndex,
            order.sizeDelta,
            order.executionFee,
            order.triggerPrice,
            order.isLong,
            order.triggerAboveThreshold,
            order.isIncreaseOrder
        );
    }

    function executeOrder(address _address, uint256 _orderIndex, address payable _feeReceiver) override external nonReentrant {
        Order memory order = orders[_address][_orderIndex];
        require(order.account != address(0), "OrderBook: non-existent order");

        // increase long should use max price
        // increase short should use min price
        (uint256 currentPrice, ) = validatePositionOrderPrice(
            order.triggerAboveThreshold,
            order.triggerPrice,
            order.indexToken,
            order.isLong,
            true
        );

        delete orders[_address][_orderIndex];

        if(order.isIncreaseOrder){
            IERC20(order.collateralToken).transfer(vault, order.collateralDelta);
            IRouter(router).pluginIncreasePosition(order.account, order.collateralToken, order.indexToken, order.sizeDelta, order.isLong);

        } else{
            uint256 amountOut = IRouter(router).pluginDecreasePosition(order.account, order.collateralToken, order.indexToken, order.collateralDelta, order.sizeDelta, order.isLong, address(this));
            IERC20(order.collateralToken).transfer(order.account, amountOut);
        }

        // pay executor
        (bool success,  ) = _feeReceiver.call{value: order.executionFee}("");

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
    }
}
