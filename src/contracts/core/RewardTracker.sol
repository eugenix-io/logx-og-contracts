// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import "../libraries/token/IERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";

import "./interfaces/IRewardDistributor.sol";
import "./interfaces/IRewardTracker.sol";
import "../access/Governable.sol";
import '../libraries/token/SafeERC20.sol';

contract RewardTracker is IERC20, ReentrancyGuard, IRewardTracker, Governable {
    using SafeERC20 for IERC20;
    struct Position{
        uint stakedAmount;
        uint entryRewardPerLPToken;
    }

    uint8 public constant decimals = 18;

    bool public isInitialized;

    string public name;
    string public symbol;

    mapping(address => bool) public isDepositToken;
    mapping(address => mapping(address => uint256)) public override depositBalances;
    mapping(address => uint256) public totalDepositSupply;

    uint256 public override totalSupply;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;

    mapping(address => Position) public positions;
    mapping(address => bool) public isHandler;
    address public rewardToken;
    uint public rewardPrecision = 1000000;
    address admin;
    uint public cummulativeRewardPerLPToken = 0;

    event Claim(address indexed fundingAccount, address indexed receiver, uint256 amount);
    event Stakellp(address indexed fundingAccount, address indexed receiver, uint256 amount);
    event Unstakellp(address indexed fundingAccount, address indexed receiver, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function initialize(
        address[] memory _depositTokens,
        address _rewardToken,
        address _admin
    ) external onlyGov {
        require(!isInitialized, "RewardTracker: already initialized");
        isInitialized = true;

        for (uint256 i = 0; i < _depositTokens.length; i++) {
            address depositToken = _depositTokens[i];
            isDepositToken[depositToken] = true;
        }

        rewardToken = _rewardToken;
        admin = _admin;
    }

    function onlyAdmin() internal view {
        require(
            msg.sender == admin,
            "RewardTracker: forbidden incorrect admin"
        );
    }

    function setDepositToken(
        address _depositToken,
        bool _isDepositToken
    ) external onlyGov {
        isDepositToken[_depositToken] = _isDepositToken;
    }

    function setRewardPrecision(uint _rewardPrecision) public onlyGov {
        rewardPrecision = _rewardPrecision;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setCummulativeRewardRate(uint _cummulativeRewardPerLPToken) public onlyGov {
        cummulativeRewardPerLPToken = _cummulativeRewardPerLPToken;
    }

    function withdrawToken(
        address _token,
        address _account,
        uint256 _amount
    ) external onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function balanceOf(
        address _account
    ) external view override returns (uint256) {
        return balances[_account];
    }

    function transfer(
        address _recipient,
        uint256 _amount
    ) external override returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(
        address _owner,
        address _spender
    ) external view override returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(
        address _spender,
        uint256 _amount
    ) external override returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) external override returns (bool) {
        if (isHandler[msg.sender]) {
            _transfer(_sender, _recipient, _amount);
            return true;
        }

        uint256 nextAllowance = allowances[_sender][msg.sender] - _amount;
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function claimForAccount(
        address _account,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        uint claimedAmount = _claim(_account, _receiver);
        positions[_account].entryRewardPerLPToken = cummulativeRewardPerLPToken;
        return claimedAmount;
    }

    function claimable(
        address _account
    ) public view override returns (uint256) {
        Position memory position = positions[_account];
        return ((cummulativeRewardPerLPToken -  position.entryRewardPerLPToken) * position.stakedAmount)/rewardPrecision;
    }


    function _claim(address _account, address _receiver) private returns (uint256) {
        uint tokenAmount = claimable(_account);

        if (tokenAmount > 0) {
            IERC20(rewardToken).safeTransfer(_receiver, tokenAmount);
            emit Claim(_account, _receiver, tokenAmount);
        }

        return tokenAmount;
    }

    function _mint(address _account, uint256 _amount) internal {
        require(
            _account != address(0),
            "RewardTracker: mint to the zero address"
        );

        totalSupply = totalSupply + _amount;
        balances[_account] = balances[_account] + _amount;

        emit Transfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) internal {
        require(
            _account != address(0),
            "RewardTracker: burn from the zero address"
        );

        balances[_account] = balances[_account] - _amount;
        totalSupply = totalSupply - _amount;

        emit Transfer(_account, address(0), _amount);
    }

    function _transfer(
        address _sender,
        address _recipient,
        uint256 _amount
    ) private {
        require(
            _sender != address(0),
            "RewardTracker: transfer from the zero address"
        );
        require(
            _recipient != address(0),
            "RewardTracker: transfer to the zero address"
        );

        balances[_sender] = balances[_sender] - _amount;
        balances[_recipient] = balances[_recipient] + _amount;

        emit Transfer(_sender, _recipient, _amount);
    }

    function _approve(
        address _owner,
        address _spender,
        uint256 _amount
    ) private {
        require(
            _owner != address(0),
            "RewardTracker: approve from the zero address"
        );
        require(
            _spender != address(0),
            "RewardTracker: approve to the zero address"
        );

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "RewardTracker: forbidden");
    }

    function stakeForAccount(
        address _fundingAccount,
        address _account,
        address _depositToken,
        uint256 _amount
    ) external override nonReentrant {
        _validateHandler();
        _stake(_fundingAccount, _account, _depositToken, _amount);
    }

    function _stake(
        address _fundingAccount,
        address _account,
        address _depositToken,
        uint256 _amount
    ) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(
            isDepositToken[_depositToken],
            "RewardTracker: invalid _depositToken"
        );

        IERC20(_depositToken).safeTransferFrom(
            _fundingAccount,
            address(this),
            _amount
        );

        Position memory prevPosition = positions[_account];

        if(prevPosition.stakedAmount!=0){
            _claim(_account, _account);
        }
        Position memory updatedPosition;

        updatedPosition.stakedAmount = prevPosition.stakedAmount + _amount;
        updatedPosition.entryRewardPerLPToken = cummulativeRewardPerLPToken;
        positions[_account] = updatedPosition;
        depositBalances[_account][_depositToken] =
            depositBalances[_account][_depositToken] +
            _amount;
        totalDepositSupply[_depositToken] =
            totalDepositSupply[_depositToken] +
            _amount;

        _mint(_account, _amount);
        emit Stakellp(_fundingAccount, _account, _amount);
    }

    function unstakeForAccount(
        address _account,
        address _depositToken,
        uint256 _amount,
        address _receiver
    ) external override nonReentrant {
        _validateHandler();
        _unstake(_account, _depositToken, _amount, _receiver);
    }

    function _unstake(
        address _account,
        address _depositToken,
        uint256 _amount,
        address _receiver
    ) private {
        require(_amount > 0, "RewardTracker: invalid _amount");
        require(
            isDepositToken[_depositToken],
            "RewardTracker: invalid _depositToken"
        );

        Position memory prevPosition = positions[_account];
        require(
            prevPosition.stakedAmount >= _amount,
            "RewardTracker: _amount exceeds stakedAmount"
        );

        _claim(_account, _receiver);

        Position memory updatePosition;

        updatePosition.stakedAmount = prevPosition.stakedAmount - _amount;
        updatePosition.entryRewardPerLPToken = cummulativeRewardPerLPToken;
        positions[_account] = updatePosition;

        uint256 depositBalance = depositBalances[_account][_depositToken];
        require(
            depositBalance >= _amount,
            "RewardTracker: _amount exceeds depositBalance"
        );
        depositBalances[_account][_depositToken] = depositBalance - _amount;
        totalDepositSupply[_depositToken] = totalDepositSupply[_depositToken] - _amount;

        _burn(_account, _amount);
        IERC20(_depositToken).safeTransfer(_receiver, _amount);
        emit Unstakellp(_account, _receiver, _amount);
    }
}
