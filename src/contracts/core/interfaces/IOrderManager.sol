// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IOrderManager{
    function increasePositionRequestKeysStart() external returns (uint256);
    function decreasePositionRequestKeysStart() external returns (uint256);
    function executeIncreasePositions(uint256 _count, address payable _executionFeeReceiver) external;
    function executeDecreasePositions(uint256 _count, address payable _executionFeeReceiver) external;
    function getOrder(address _account, uint256 _orderIndex) external view returns (
        address collateralToken,
        uint256 amountIn,
        address indexToken,
        uint256 sizeDelta,
        bool isLong,
        uint256 triggerPrice,
        bool triggerAboveThreshold,
        uint256 executionFee,
        bool isIncreaseOrder
    );

    function executeOrder(address, uint256, address payable) external;
    function setOrderKeeper(address _account, bool _isActive) external;
    function setPriceFeed(address _priceFeed) external;
}