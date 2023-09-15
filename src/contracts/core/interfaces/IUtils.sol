// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IUtils {
    function validateIncreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) external view;
    function validateDecreasePosition(address _account, address _collateralToken, address _indexToken, uint256 _collateralDelta, uint256 _sizeDelta, bool _isLong, address _receiver) external view;
    function validateLiquidation(address _account, address _collateralToken, address _indexToken, bool _isLong, bool _raise) external view returns (uint256, uint256);
    function getEntryFundingRate(address _collateralToken, address _indexToken, bool _isLong) external view returns (uint256);
    function getPositionFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _sizeDelta) external view returns (uint256);
    function getFundingFee(address _account, address _collateralToken, address _indexToken, bool _isLong, uint256 _size, uint256 _entryFundingRate) external view returns (uint256);
    function getBuyUsdlFeeBasisPoints(address _token, uint256 _usdgAmount) external view returns (uint256);
    function getSellUsdlFeeBasisPoints(address _token, uint256 _usdgAmount) external view returns (uint256);
    function getFeeBasisPoints(address _token, uint256 _usdgDelta, uint256 _feeBasisPoints, bool _increment) external view returns (uint256);
    function getDelta(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _lastIncreasedTime
    ) external view returns (bool, uint256);
    function getNextGlobalAveragePrice(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        bool _isLong,
        bool _isIncrease
    ) external view returns (uint256);
    function getNextAveragePrice(
        address _indexToken,
        uint256 _size,
        uint256 _averagePrice,
        bool _isLong,
        uint256 _nextPrice,
        uint256 _sizeDelta,
        uint256 _lastIncreasedTime
    ) external view returns (uint256);
    function adjustForDecimals(
        uint256 _amount,
        address _tokenDiv,
        address _tokenMul
    ) external view returns (uint256);
    function getGlobalPositionDelta(address _token, bool _isLong) external view returns (bool, uint256);
    function getGlobalPositionDeltaWithPrice(
        address _token,
        uint256 _price,
        uint256 _size,
        bool _isLong
    ) external view returns (bool, uint256);
    function getAum(bool maximise) external view returns (uint256);
    function getAumInUsdl(
        bool maximise
    ) external view returns (uint256);
    function calculateMintAmount(uint256 _minusdl, address _token, uint256 aumInusdl, uint256 llpSupply, uint256 _minllp, address _receiver) external returns(uint256, uint256);
    function validatePosition(
        uint256 _size,
        uint256 _collateral
    ) external view;

    function getNextFundingRate(uint lastFundingTime, uint fundingInterval, uint fundingRateFactor, uint poolAmount, uint reservedAmount) external view returns(uint);

}
