// SPDX-License-Identifier: GPL-2.0-or-later

pragma solidity 0.8.19;

import "../libraries/token/IERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import "../libraries/token/Address.sol";
import "./interfaces/IRewardTracker.sol";
import "./interfaces/IRewardRouter.sol";
import "../core/interfaces/ILlpManager.sol";
import "../access/Governable.sol";
import '../libraries/token/SafeERC20.sol';

contract RewardRouter is IRewardRouter, ReentrancyGuard, Governable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    bool public isInitialized;

    address public llp; // logX Liquidity Provider token

    address public llpManager;

    address public override feeLlpTracker;

    event Mintllp(address indexed account, uint256 amount);
    event Burnllp(address indexed account, uint256 amount);

    function initialize(
        address _llp,
        address _llpManager,
        address _feeLlpTracker
    ) external onlyGov {
        require(!isInitialized, "RewardRouter: already initialized");
        isInitialized = true;
        llp = _llp;
        llpManager = _llpManager;
        feeLlpTracker = _feeLlpTracker;
    }

    function setFeeLlpTracker(address _feeLlpTracker) external onlyGov {
        feeLlpTracker = _feeLlpTracker;
    }

    function setLlpManager(address _llpManager) external onlyGov {
        llpManager = _llpManager;
    }

    function setLlp(address _llp) external onlyGov {
        llp = _llp;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function mintLlp(address _token, uint256 _amount, uint256 _minUsdl, uint256 _minLlp) external nonReentrant returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");

        address account = msg.sender;
        uint256 llpAmount = ILlpManager(llpManager).addLiquidityForAccount(account, account, _token, _amount, _minUsdl, _minLlp);
        emit Mintllp(account, llpAmount);
        return llpAmount;
    }

    function burnLlp( uint256 _llpAmount, uint256 _minOut, address tokenOut) external nonReentrant returns (uint256) {
        require(_llpAmount > 0, "RewardRouter: invalid _llpAmount");

        address account = msg.sender;
        uint256 amountOut = ILlpManager(llpManager).removeLiquidityForAccount(account, tokenOut, _llpAmount, _minOut, account);
        emit Burnllp(account, _llpAmount);

        return amountOut;
    }

    function stakeLlp(uint256 llpAmount) external nonReentrant {
        require(llpAmount > 0, "RewardRouter: llpAmount too low");
        address account = msg.sender;
        IRewardTracker(feeLlpTracker).stakeForAccount(account, account, llp, llpAmount);
    }

    function unstakeLlp(uint256 amount) external nonReentrant {
        address account = msg.sender;
        IRewardTracker(feeLlpTracker).unstakeForAccount(account, llp, amount, account);
    }

    function claimStakeRewards() external nonReentrant {
        address account = msg.sender;
        IRewardTracker(feeLlpTracker).claimForAccount(account, account);
    }
}
