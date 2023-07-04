// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/token/Address.sol";
import "./interfaces/IRewardTracker.sol";
import "./interfaces/IRewardRouter.sol";
import "../core/interfaces/ILlpManager.sol";
import "../access/Governable.sol";

contract RewardRouter is IRewardRouter, ReentrancyGuard, Governable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public usdc;

    address public llp; // logX Liquidity Provider token

    address public llpManager;

    address public override feeLlpTracker;

    event Stakellp(address account, uint256 amount);
    event Unstakellp(address account, uint256 amount);

    function initialize(
        address _usdc,
        address _llp,
        address _llpManager,
        address _feeLlpTracker
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;
        usdc = _usdc;
        llp = _llp;
        llpManager = _llpManager;
        feeLlpTracker = _feeLlpTracker;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function mintAndStakeLlp(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minLlp) external nonReentrant returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");
        require(_token == usdc, "Only USDC is supported");

        address account = msg.sender;
        uint256 llpAmount = ILlpManager(llpManager).addLiquidityForAccount(account, account, _token, _amount, _minUsdg, _minLlp);
        IRewardTracker(feeLlpTracker).stakeForAccount(account, account, llp, llpAmount);

        emit Stakellp(account, llpAmount);

        return llpAmount;
    }

    function unstakeAndRedeemLlp(address _tokenOut, uint256 _llpAmount, uint256 _minOut, address _receiver) external nonReentrant returns (uint256) {
        require(_llpAmount > 0, "RewardRouter: invalid _llpAmount");
        require(_tokenOut == usdc, "Only USDC is supported");

        address account = msg.sender;
        IRewardTracker(feeLlpTracker).unstakeForAccount(account, llp, _llpAmount, account);
        uint256 amountOut = ILlpManager(llpManager).removeLiquidityForAccount(account, _tokenOut, _llpAmount, _minOut, _receiver);

        emit Unstakellp(account, _llpAmount);

        return amountOut;
    }
}
