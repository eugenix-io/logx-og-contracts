// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface IPriceFeed {
    function getPriceOfToken(address _token) external view returns(uint);
    function getMaxPriceOfToken(address _token) external view returns(uint);
    function getMinPriceOfToken(address _token) external view returns(uint);
}