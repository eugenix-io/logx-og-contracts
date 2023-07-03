// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IPositionsTracker {
    function globalShortAveragePrices(address _token) external view returns (uint256);
    function globalLongAveragePrices(address _token) external view returns (uint256);
    function getNextGlobalPositionData(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        bool _isIncrease, 
        bool _isLong
    ) external view returns (uint256, uint256);
    function updateGlobalPositionsData(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        uint256 _markPrice,
        bool _isIncrease,
        bool _isLong
    ) external;
    function getGlobalPositionDelta(
        address _token,
        bool _isLong
    ) external view returns (bool, uint256);
}
