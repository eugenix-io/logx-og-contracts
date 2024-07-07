// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

library StructsUtils {
    struct IncreasePositionRequest {
        address account;
        address _collateralToken;
        address indexToken;
        uint256 amountIn;
        uint256 sizeDelta;
        bool isLong;
        uint256 acceptablePrice;
        uint256 executionFee;
        uint256 blockNumber;
        uint256 blockTime;    
    }
}