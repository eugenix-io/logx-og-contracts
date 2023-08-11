// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import './interfaces/IRouter.sol';
import '../libraries/token/IERC20.sol';
import '../access/Governable.sol';
import './interfaces/IVault.sol';

/**
 * When ever user wants to open a trade provide token approval to Router and then transfer to PositionRouter.
*/
contract Router is IRouter, Governable {

    address vault;
    mapping(address => bool) plugins;
    mapping(address => mapping(address => bool)) approvedPlugins;

    constructor(address _vault) {
        vault = _vault;
    }
    
    function setVault(address _vault) external onlyGov {
        vault = _vault;
    }

    function addPlugin(address _plugin) external override onlyGov {
        plugins[_plugin] = true;
    }

    function removePlugin(address _plugin) external onlyGov {
        plugins[_plugin] = false;
    }

    function approvePlugin(address _plugin) external {
        approvedPlugins[msg.sender][_plugin] = true;
    }

    function denyPlugin(address _plugin) external {
        approvedPlugins[msg.sender][_plugin] = false;
    }

    function isPluginApproved(address _plugin, address account) external view returns (bool) {
        return approvedPlugins[account][_plugin];
    }

    function pluginTransfer(
        address _token,
        address _account,
        address _receiver,
        uint256 _amount
    ) external override {
        _validatePlugin(_account);
        IERC20(_token).transferFrom(_account, _receiver, _amount);
    }

    function pluginIncreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _sizeDelta,
        bool _isLong
    ) external override {
        _validatePlugin(_account);
        IVault(vault).increasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
    }

    function pluginDecreasePosition(
        address _account,
        address _collateralToken,
        address _indexToken,
        uint256 _collateralDelta,
        uint256 _sizeDelta,
        bool _isLong,
        address _receiver
    ) external override returns (uint256) {
        _validatePlugin(_account);
        return IVault(vault).decreasePosition(_account, _collateralToken, _indexToken, _collateralDelta, _sizeDelta, _isLong, _receiver);
    }

    function _validatePlugin(address _account) private view {
        require(plugins[msg.sender], "Router: invalid plugin");
        require(approvedPlugins[_account][msg.sender], "Router: plugin not approved");
    }
}