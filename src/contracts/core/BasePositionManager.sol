// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../libraries/token/IERC20.sol';
import './interfaces/IVault.sol';
import './interfaces/IPositionsTracker.sol';
import './interfaces/IRouter.sol';
import './interfaces/ITimeLock.sol';
import '../libraries/token/SafeERC20.sol';
import '../access/Governable.sol';
import '../libraries/utils/ReentrancyGuard.sol';


contract BasePositionManager{
    using SafeERC20 for IERC20;
    address public admin;

    address public vault;
    address public positionsTracker;
    address public router;

    // to prevent using the deposit and withdrawal of collateral as a zero fee swap,
    // there is a small depositFee charged if a collateral deposit results in the decrease
    // of leverage for an existing position
    // increasePositionBufferBps alibaslows for a small amount of decrease of leverage
    uint256 public depositFee;
    uint256 public increasePositionBufferBps = 100;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    mapping (address => uint256) public feeReserves;
    mapping (address => uint256) public maxGlobalLongSizes;
    mapping (address => uint256) public maxGlobalShortSizes;

    event SetIncreasePositionBufferBps(uint256 increasePositionBufferBps);
    event WithdrawFees(address token, address receiver, uint256 amount);
    event SetMaxGlobalSizes(
        address[] tokens,
        uint256[] longSizes,
        uint256[] shortSizes
    );
    event LeverageDecreased(uint256 collateralDetlta, uint256 prevLeverage, uint256 nextLeverage);


    modifier onlyAdmin() {
        require(msg.sender == admin, "forbidden");
        _;
    }

    constructor(
        address _vault,
        address _router,
        address _positionsTracker,
        uint256 _depositFee
    ) {
        vault = _vault;
        router = _router;
        depositFee = _depositFee;
        positionsTracker = _positionsTracker;

        admin = msg.sender;
    }

    function setIncreasePositionBufferBps(uint256 _increasePositionBufferBps) external onlyAdmin {
        increasePositionBufferBps = _increasePositionBufferBps;
        emit SetIncreasePositionBufferBps(_increasePositionBufferBps);
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

    function withdrawFees(address _token, address _receiver) external onlyAdmin {
        uint256 amount = feeReserves[_token];
        if (amount == 0) { return; }

        feeReserves[_token] = 0;
        IERC20(_token).safeTransfer(_receiver, amount);

        emit WithdrawFees(_token, _receiver, amount);
    }

    function _collectFees(
        address _account,
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta
    ) internal returns (uint256) {
        bool shouldDeductFee = checkShouldDeductFee(
            _account,
            _path,
            _amountIn,
            _indexToken,
            _isLong,
            _sizeDelta,
            increasePositionBufferBps
        );

        if (shouldDeductFee) {
            uint256 afterFeeAmount = _amountIn*(BASIS_POINTS_DIVISOR-(depositFee))/(BASIS_POINTS_DIVISOR);
            uint256 feeAmount = _amountIn-(afterFeeAmount);
            address feeToken = _path[_path.length - 1];
            feeReserves[feeToken] = feeReserves[feeToken]+(feeAmount);
            return afterFeeAmount;
        }

        return _amountIn;
    }

    function _validateMaxGlobalSize(address _indexToken, bool _isLong, uint256 _sizeDelta) internal view {
        if (_sizeDelta == 0) {
            return;
        }

        if (_isLong) {
            uint256 maxGlobalLongSize = maxGlobalLongSizes[_indexToken];
            if (maxGlobalLongSize > 0 && IVault(vault).guaranteedUsd(_indexToken)+(_sizeDelta) > maxGlobalLongSize) {
                revert("max longs exceeded");
            }
        } else {
            uint256 maxGlobalShortSize = maxGlobalShortSizes[_indexToken];
            if (maxGlobalShortSize > 0 && IVault(vault).globalShortSizes(_indexToken)+(_sizeDelta) > maxGlobalShortSize) {
                revert("max shorts exceeded");
            }
        }
    }

    function _increasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong, uint256 acceptablePrice) internal {
        _validateMaxGlobalSize(_indexToken, _isLong, _sizeDelta);

        uint256 markPrice = _isLong ? IVault(vault).getMaxPrice(_indexToken) : IVault(vault).getMinPrice(_indexToken);
        if (_isLong) {
            require(markPrice <= acceptablePrice, "markPrice > price");
        } else {
            require(markPrice >= acceptablePrice, "markPrice < price");
        }

        address timelock = IVault(vault).gov();

        // should be called strictly before position is updated in Vault
        IPositionsTracker(positionsTracker).updateGlobalPositionsData(_account, _collateralToken, _indexToken, _sizeDelta, markPrice, true, _isLong);
        //AnirudhTodo - why do we need to specifically enable and disable Leverage?
        ITimelock(timelock).enableLeverage(vault);
        IRouter(router).pluginIncreasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
        ITimelock(timelock).disableLeverage(vault);
    }

    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver, uint256 _price) internal returns (uint256) {
        address _vault = vault;

        uint256 markPrice = _isLong ? IVault(_vault).getMinPrice(_indexToken) : IVault(_vault).getMaxPrice(_indexToken);
        if (_isLong) {
            require(markPrice >= _price, "markPrice < price");
        } else {
            require(markPrice <= _price, "markPrice > price");
        }

        address timelock = IVault(_vault).gov();

        // should be called strictly before position is updated in Vault
        IPositionsTracker(positionsTracker).updateGlobalPositionsData(_account, _collateralToken, _indexToken, _sizeDelta, markPrice, false, _isLong);
        

        ITimelock(timelock).enableLeverage(_vault);
        uint256 amountOut = IRouter(router).pluginDecreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
        ITimelock(timelock).disableLeverage(_vault);

        return amountOut;
    }

    function checkShouldDeductFee(
        address _account,
        address[] memory _path,
        uint256 _amountIn,
        address _indexToken,
        bool _isLong,
        uint256 _sizeDelta,
        uint256 _increasePositionBufferBps
    ) public returns (bool) {
        // if the position is a short, do not charge a fee
        if (!_isLong) { return false; }

        // if the position size is not increasing, this is a collateral deposit
        if (_sizeDelta == 0) { return true; }

        address collateralToken = _path[_path.length - 1];

        (uint256 size, uint256 collateral, , , , , , ) = IVault(vault).getPosition(_account, collateralToken, _indexToken, _isLong);

        // if there is no existing position, do not charge a fee
        if (size == 0) { return false; }

        uint256 nextSize = size+(_sizeDelta);
        uint256 collateralDelta = IVault(vault).tokenToUsdMin(collateralToken, _amountIn);
        uint256 nextCollateral = collateral+(collateralDelta);

        uint256 prevLeverage = size*(BASIS_POINTS_DIVISOR)/(collateral);
        // allow for a maximum of a increasePositionBufferBps decrease since there might be some swap fees taken from the collateral
        uint256 nextLeverage = nextSize*(BASIS_POINTS_DIVISOR + _increasePositionBufferBps)/(nextCollateral);
        //AnirudhTodo - check if leverage can increase. If yes why are we always emiting leverageDecreased.
        emit LeverageDecreased(collateralDelta, prevLeverage, nextLeverage);
        //AnirudhTodo - why should we deduct fee only if leverage decreases?
        // deduct a fee if the leverage is decreased
        //Reason - this check is used to find whether we need to deduct deposit Fee and incase of deposit
        // the leverage always decreases.
        //AniurdhTodo - why only have a deposit fee why not a collateral withdrawl fee as well?
        return nextLeverage < prevLeverage;
    }
}