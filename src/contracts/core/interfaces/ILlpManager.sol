// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "./IVault.sol";

interface ILlpManager {
    function llp() external view returns (address);
    function usdl() external view returns (address);
    function vault() external view returns (IVault);
    function cooldownDuration() external returns (uint256);
    function lastAddedAt(address _account) external returns (uint256);
    function addLiquidityForAccount(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdl, uint256 _minllp) external returns (uint256);
    function removeLiquidityForAccount(address _account, address _tokenOut, uint256 _llpAmount, uint256 _minOut, address _receiver) external returns (uint256);
    function setCooldownDuration(uint256 _cooldownDuration) external;
}
