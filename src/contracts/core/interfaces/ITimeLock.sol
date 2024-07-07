// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

interface ITimelock {
    function setAdmin(address _admin) external;
    function signalSetGov(address _target, address _gov) external;
}
