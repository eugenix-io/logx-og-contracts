// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import './IERC20.sol';
import './IBaseToken.sol';
import './SafeERC20.sol';



contract BaseToken is IERC20, IBaseToken {
    using SafeERC20 for IERC20;
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public override totalSupply;
    uint256 public nonStakingSupply;

    address public gov;

    mapping (address => uint256) public balances;
    mapping (address => mapping (address => uint256)) public allowances;

    mapping (address => bool) public nonStakingAccounts;
    mapping (address => bool) public admins;

    bool public inPrivateTransferMode;
    mapping (address => bool) public isHandler;

    modifier onlyGov() {
        require(msg.sender == gov, "BaseToken: forbidden");
        _;
    }

    modifier onlyAdmin() {
        require(admins[msg.sender], "BaseToken: forbidden");
        _;
    }

    constructor(string memory _name, string memory _symbol, uint256 _initialSupply) {
        name = _name;
        symbol = _symbol;
        gov = msg.sender;
        _mint(msg.sender, _initialSupply);
    }

    function setGov(address _gov) external onlyGov {
        gov = _gov;
    }

    function setInfo(string memory _name, string memory _symbol) external onlyGov {
        name = _name;
        symbol = _symbol;
    }

    function addAdmin(address _account) external onlyGov {
        admins[_account] = true;
    }

    function removeAdmin(address _account) external override onlyGov {
        admins[_account] = false;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external override onlyGov {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    function setInPrivateTransferMode(bool _inPrivateTransferMode) external override onlyGov {
        inPrivateTransferMode = _inPrivateTransferMode;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function totalStaked() external view override returns (uint256) {
        return totalSupply-(nonStakingSupply);
    }

    function balanceOf(address _account) external view override returns (uint256) {
        return balances[_account];
    }

    function stakedBalance(address _account) external view override returns (uint256) {
        if (nonStakingAccounts[_account]) {
            return 0;
        }
        return balances[_account];
    }

    function transfer(address _recipient, uint256 _amount) external override returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) external view override returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external override returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external override returns (bool) {
        if (isHandler[msg.sender]) {
            _transfer(_sender, _recipient, _amount);
            return true;
        }

        if(allowances[_sender][msg.sender]<_amount){
            revert("BaseToken: transfer amount exceeds allowance");
        }
        uint256 nextAllowance = allowances[_sender][msg.sender]-_amount;
        _approve(_sender, msg.sender, nextAllowance);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function _mint(address _account, uint256 _amount) internal {
        require(_account != address(0), "BaseToken: mint to the zero address");

        _updateRewards(_account);

        totalSupply = totalSupply+(_amount);
        balances[_account] = balances[_account]+(_amount);

        if (nonStakingAccounts[_account]) {
            nonStakingSupply = nonStakingSupply+(_amount);
        }

        emit Transfer(address(0), _account, _amount);
    }

    function _burn(address _account, uint256 _amount) internal {
        require(_account != address(0), "BaseToken: burn from the zero address");

        _updateRewards(_account);
        if(_amount> balances[_account]){
            revert("BaseToken: burn amount exceeds balance");
        }

        balances[_account] = balances[_account]-_amount;
        totalSupply = totalSupply-(_amount);

        if (nonStakingAccounts[_account]) {
            nonStakingSupply = nonStakingSupply-(_amount);
        }

        emit Transfer(_account, address(0), _amount);
    }

    function _transfer(address _sender, address _recipient, uint256 _amount) private {
        require(_sender != address(0), "BaseToken: transfer from the zero address");
        require(_recipient != address(0), "BaseToken: transfer to the zero address");

        if (inPrivateTransferMode) {
            require(isHandler[msg.sender], "BaseToken: msg.sender not whitelisted");
        }

        _updateRewards(_sender);
        _updateRewards(_recipient);
        if(_amount> balances[_sender]){
            revert("BaseToken: transfer amount exceeds balance");
        }
        balances[_sender] = balances[_sender] - _amount;
        balances[_recipient] = balances[_recipient]+(_amount);

        if (nonStakingAccounts[_sender]) {
            nonStakingSupply = nonStakingSupply-(_amount);
        }
        if (nonStakingAccounts[_recipient]) {
            nonStakingSupply = nonStakingSupply+(_amount);
        }

        emit Transfer(_sender, _recipient,_amount);
    }

    function _approve(address _owner, address _spender, uint256 _amount) private {
        require(_owner != address(0), "BaseToken: approve from the zero address");
        require(_spender != address(0), "BaseToken: approve to the zero address");

        allowances[_owner][_spender] = _amount;

        emit Approval(_owner, _spender, _amount);
    }

    function _updateRewards(address _account) private {
    }
}
