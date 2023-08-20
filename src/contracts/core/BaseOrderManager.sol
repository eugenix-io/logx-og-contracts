// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../libraries/token/IERC20.sol';
import './interfaces/IVault.sol';
import './interfaces/ITimeLock.sol';
import '../access/Governable.sol';
import '../libraries/utils/ReentrancyGuard.sol';


contract BaseOrderManager{
    address public admin;
    address public vault;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    mapping (address => uint256) public maxGlobalLongSizes;
    mapping (address => uint256) public maxGlobalShortSizes;
    uint256 public increasePositionBufferBps = 100;
    mapping (address => uint256) public feeReserves;
    uint public depositFee;

    event SetMaxGlobalSizes(
        address[] tokens,
        uint256[] longSizes,
        uint256[] shortSizes
    );

    event LeverageDecreased(
        uint256 collateralDelta,
        uint256 prevLeverage,
        uint256 nextLeverage
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "BasePositionManager: forbidden");
        _;
    }

    constructor(
        address _vault
    ) {
        vault = _vault;
        admin = msg.sender;
    }

    function setAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    function setVault(address _vault) external onlyAdmin {
        vault = _vault;
    }

    function setMaxGlobalSizes(
        address[] memory _tokens,
        uint256[] memory _longSizes,
        uint256[] memory _shortSizes
    ) external onlyAdmin {
        for (uint256 i = 0; i < _tokens.length; i++) {
            address token = _tokens[i];
            maxGlobalLongSizes[token] = _longSizes[i];
            maxGlobalShortSizes[token] = _shortSizes[i];
        }

        emit SetMaxGlobalSizes(_tokens, _longSizes, _shortSizes);
    }

    function _validateMaxGlobalSize(address _indexToken, bool _isLong, uint256 _sizeDelta) internal view {
        if (_sizeDelta == 0) {
            return;
        }

        if (_isLong) {
            uint256 maxGlobalLongSize = maxGlobalLongSizes[_indexToken];
            if (maxGlobalLongSize > 0 && IVault(vault).globalLongSizes(_indexToken)+(_sizeDelta) > maxGlobalLongSize) {
                revert("BasePositionManager: max longs exceeded");
            }
        } else {
            uint256 maxGlobalShortSize = maxGlobalShortSizes[_indexToken];
            if (maxGlobalShortSize > 0 && IVault(vault).globalShortSizes(_indexToken)+(_sizeDelta) > maxGlobalShortSize) {
                revert("BasePositionManager: max shorts exceeded");
            }
        }
    }

    function _increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong, uint256 acceptablePrice) internal {
        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);

        uint256 markPrice = _isLong ? IVault(vault).getMaxPrice(_indexToken) : IVault(vault).getMinPrice(_indexToken);
        if (_isLong) {
            require(markPrice <= acceptablePrice, "BasePositionManager: markPrice > price");
        } else {
            require(markPrice >= acceptablePrice, "BasePositionManager: markPrice < price");
        }

        IVault(vault).increasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
    }

    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver, uint256 _price) internal returns (uint256) {
        address _vault = vault;

        uint256 markPrice = _isLong ? IVault(_vault).getMinPrice(_indexToken) : IVault(_vault).getMaxPrice(_indexToken);
        if (_isLong) {
            require(markPrice >= _price, "BasePositionManager: markPrice < price");
        } else {
            require(markPrice <= _price, "BasePositionManager: markPrice > price");
        }
        
        uint256 amountOut = IVault(vault).decreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);

        return amountOut;
    }

    function shouldDeductFee(
        address _account,
        address collateralToken,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _increasePositionBufferBps
    ) private returns (bool) {

        // if the position size is not increasing, this is a collateral deposit
        if (_sizeDelta == 0) { return true; }

        (uint256 size, uint256 collateral, , , , , , ) = IVault(vault).getPosition(_account, collateralToken, _indexToken, _isLong);

        // if there is no existing position, do not charge a fee
        if (size == 0) { return false; }

        uint256 nextSize = size+(_sizeDelta);
        uint256 collateralDelta = IVault(vault).tokenToUsdMin(collateralToken, _amountIn);
        uint256 nextCollateral = collateral+(collateralDelta);

        uint256 prevLeverage = size*(BASIS_POINTS_DIVISOR)/(collateral);
        // allow for a maximum of a increasePositionBufferBps decrease since there might be some swap fees taken from the collateral
        uint256 nextLeverage = nextSize*(BASIS_POINTS_DIVISOR + _increasePositionBufferBps)/(nextCollateral);

        emit LeverageDecreased(collateralDelta, prevLeverage, nextLeverage);

        // deduct a fee if the leverage is decreased
        return nextLeverage < prevLeverage;
    }

    function _collectFees(
        address _account,
        address collateralToken,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) internal returns (uint256) {
        bool shouldDeduct = shouldDeductFee(
            _account,
            collateralToken,
            _amountIn,
            _indexToken,
            _isLong,
            _sizeDelta,
            increasePositionBufferBps
        );

        if (shouldDeduct) {
            uint256 afterFeeAmount = _amountIn*(BASIS_POINTS_DIVISOR - (depositFee))/(BASIS_POINTS_DIVISOR);
            uint256 feeAmount = _amountIn-(afterFeeAmount);
            feeReserves[collateralToken] = feeReserves[collateralToken]+(feeAmount);
            return afterFeeAmount;
        }

        return _amountIn;
    }
}