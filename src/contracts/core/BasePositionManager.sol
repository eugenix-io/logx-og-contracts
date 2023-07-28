// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../libraries/token/IERC20.sol';
import './interfaces/IVault.sol';
import './interfaces/IRouter.sol';
import './interfaces/ITimeLock.sol';
import '../access/Governable.sol';
import '../libraries/utils/ReentrancyGuard.sol';


contract BasePositionManager{
    address public admin;
    address public vault;
    address public router;

    uint256 public constant BASIS_POINTS_DIVISOR = 10000;
    mapping (address => uint256) public maxGlobalLongSizes;
    mapping (address => uint256) public maxGlobalShortSizes;

    event SetMaxGlobalSizes(
        address[] tokens,
        uint256[] longSizes,
        uint256[] shortSizes
    );

    modifier onlyAdmin() {
        require(msg.sender == admin, "BasePositionManager: forbidden");
        _;
    }

    constructor(
        address _vault,
        address _router
    ) {
        vault = _vault;
        router = _router;
        admin = msg.sender;
    }

    function setAdmin(address _admin) external onlyAdmin {
        admin = _admin;
    }

    function setRouter(address _router) external onlyAdmin {
        router = _router;
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

        IRouter(router).pluginIncreasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
    }

    function _decreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver, uint256 _price) internal returns (uint256) {
        address _vault = vault;

        uint256 markPrice = _isLong ? IVault(_vault).getMinPrice(_indexToken) : IVault(_vault).getMaxPrice(_indexToken);
        if (_isLong) {
            require(markPrice >= _price, "BasePositionManager: markPrice < price");
        } else {
            require(markPrice <= _price, "BasePositionManager: markPrice > price");
        }
        
        uint256 amountOut = IRouter(router).pluginDecreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);

        return amountOut;
    }
}