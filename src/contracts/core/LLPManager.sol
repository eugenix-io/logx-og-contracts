// SPDX-License-Identifier: MIT

import "../libraries/token/IERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import './interfaces/IMintable.sol';
import './interfaces/IUSDL.sol';
import "./interfaces/IVault.sol";
import "./interfaces/ILlpManager.sol";
import "../access/Governable.sol";

pragma solidity 0.8.19;

contract LlpManager is ReentrancyGuard, Governable, ILlpManager {

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant usdl_DECIMALS = 18;
    uint256 public constant llp_PRECISION = 10 ** 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    IVault public override vault;
    address public override usdl;
    address public override llp;

    uint256 public override cooldownDuration;
    mapping(address => uint256) public override lastAddedAt;
    mapping(address => bool) public whiteListedTokens;

    mapping(address => bool) public isHandler;

    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 aumInusdl,
        uint256 llpSupply,
        uint256 usdlAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 llpAmount,
        uint256 aumInusdl,
        uint256 llpSupply,
        uint256 usdlAmount,
        uint256 amountOut
    );

    constructor(
        address _vault,
        address _usdl,
        address _llp,
        uint256 _cooldownDuration
    ) {
        gov = msg.sender;
        vault = IVault(_vault);
        usdl = _usdl;
        llp = _llp;
        cooldownDuration = _cooldownDuration;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function whiteListToken(address token) public onlyGov {
        whiteListedTokens[token] = true;
    }

    function removeFromWhiteListToken(address token) public onlyGov {
        whiteListedTokens[token] = false;
    }

    function setCooldownDuration(
        uint256 _cooldownDuration
    ) external override onlyGov {
        require(
            _cooldownDuration <= MAX_COOLDOWN_DURATION,
            "LlpManager: invalid _cooldownDuration"
        );
        cooldownDuration = _cooldownDuration;
    }

    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minusdl,
        uint256 _minllp
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        _validateToken(_token);
        return
            _addLiquidity(
                _fundingAccount,
                _account,
                _token,
                _amount,
                _minusdl,
                _minllp
            );
    }

    function removeLiquidityForAccount(
        address _account,
        address _tokenOut,
        uint256 _llpAmount,
        uint256 _minOut,
        address _receiver
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        _validateToken(_tokenOut);
        return
            _removeLiquidity(
                _account,
                _tokenOut,
                _llpAmount,
                _minOut,
                _receiver
            );
    }

    function getPrice(bool _maximise) external view returns (uint256) {
        uint256 aum = getAum(_maximise);
        uint256 supply = IERC20(llp).totalSupply();
        return (aum * llp_PRECISION) / supply;
    }

    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = getAum(true);
        amounts[1] = getAum(false);
        return amounts;
    }

    function getAumInUsdl(
        bool maximise
    ) public view override returns (uint256) {
        uint256 aum = getAum(maximise);
        return (aum * (10 ** usdl_DECIMALS)) / (PRICE_PRECISION);
    }

    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum;
        uint256 profits = 0;
        IVault _vault = vault;

        for (uint256 i = 0; i < length; i++) {
            address token = vault.allWhitelistedTokens(i);
            bool isWhitelisted = vault.whitelistedTokens(token);

            if (!isWhitelisted) {
                continue;
            }

            uint256 price = maximise
                ? _vault.getMaxPrice(token)
                : _vault.getMinPrice(token);
            uint256 poolAmount = _vault.poolAmounts(token);
            uint256 decimals = _vault.tokenDecimals(token);

            if (_vault.stableTokens(token)) {
                aum = aum + ((poolAmount * (price)) / (10 ** decimals));
            } else {
                aum = aum + ((poolAmount * (price)) / (10 ** decimals));
                uint256 shortSize = _vault.globalShortSizes(token);

                if (shortSize > 0) {
                    ( bool hasProfit, uint256 delta) = getGlobalPositionDelta(token, false);
                    if (!hasProfit) {
                        aum = aum + (delta);
                    } else {
                        profits = profits + (delta);
                    }
                }

                uint256 longSize = _vault.globalLongSizes(token);

                if (longSize > 0) {
                    ( bool hasProfit, uint256 delta) = getGlobalPositionDelta(token, true);
                    if (!hasProfit) {
                        aum = aum + (delta);
                    } else {
                        profits = profits + (delta);
                    }
                }
            }
        }

        aum = profits > aum ? 0 : aum - (profits) ;
        return aum;
    }

    function getGlobalShortAveragePrice(
        address _token
    ) public view returns (uint256) {
        return vault.globalShortAveragePrices(_token);
    }

    function _addLiquidity(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minusdl,//amount in usdl token order of 18
        uint256 _minllp//amount in llp token order of 18
    ) private returns (uint256) {
        require(_amount > 0, "LlpManager: invalid _amount");

        // calculate aum before buyusdl
        uint256 aumInusdl = getAumInUsdl(true);
        uint256 llpSupply = IERC20(llp).totalSupply();

        IERC20(_token).transferFrom(
            _fundingAccount,
            address(vault),
            _amount
        );
        uint256 usdlAmount = vault.buyUSDL(_token, address(this));
        require(usdlAmount >= _minusdl, "LlpManager: insufficient usdl output");

        uint256 mintAmount = aumInusdl == 0
            ? usdlAmount
            : (usdlAmount * (llpSupply)) / (aumInusdl);
        require(mintAmount >= _minllp, "LlpManager: insufficient llp output");

        IMintable(llp).mint(_account, mintAmount);

        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(
            _account,
            _token,
            _amount,
            aumInusdl,
            llpSupply,
            usdlAmount,
            mintAmount
        );

        return mintAmount;
    }

    function _removeLiquidity(
        address _account,
        address _tokenOut,
        uint256 _llpAmount,
        uint256 _minOut,
        address _receiver
    ) private returns (uint256) {
        require(_llpAmount > 0, "LlpManager: invalid _llpAmount");
        require(
            lastAddedAt[_account] + (cooldownDuration) <= block.timestamp,
            "LlpManager: cooldown duration not yet passed"
        );

        // calculate aum before sellusdl
        uint256 aumInusdl = getAumInUsdl(false);
        uint256 llpSupply = IERC20(llp).totalSupply();

        uint256 usdlAmount = (_llpAmount * (aumInusdl)) / (llpSupply);
        uint256 usdlBalance = IERC20(usdl).balanceOf(address(this));
        if (usdlAmount > usdlBalance) {
            IUSDL(usdl).mint(address(this), usdlAmount - (usdlBalance));
        }

        IMintable(llp).burn(_account, _llpAmount);

        IERC20(usdl).transfer(address(vault), usdlAmount);
        uint256 amountOut = vault.sellUSDL(_tokenOut, _receiver);
        require(amountOut >= _minOut, "LlpManager: insufficient output");

        emit RemoveLiquidity(
            _account,
            _tokenOut,
            _llpAmount,
            aumInusdl,
            llpSupply,
            usdlAmount,
            amountOut
        );

        return amountOut;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "LlpManager: forbidden");
    }

    function _validateToken(address token) private view {
        require(whiteListedTokens[token], "LlpManager: Token not whiteListed.");
    }

    function getGlobalPositionDelta(address _token, bool _isLong) public view returns (bool, uint256) {
        uint256 size = _isLong ? vault.globalLongSizes(_token) : vault.globalShortSizes(_token);
        if (size == 0) { return (false, 0); }

        uint256 nextPrice = _isLong ? vault.getMinPrice(_token) : vault.getMaxPrice(_token);
        return getGlobalPositionDeltaWithPrice(_token, nextPrice, size, _isLong);
    }

    function getGlobalPositionDeltaWithPrice(
        address _token,
        uint256 _price,
        uint256 _size,
        bool _isLong
    ) public view returns (bool, uint256) {
        uint256 averagePrice = _isLong? vault.globalLongAveragePrices(_token) : vault.globalShortAveragePrices(_token);
        uint256 priceDelta = averagePrice > _price
            ? averagePrice - (_price)
            : _price - (averagePrice);
        uint256 delta = (_size * (priceDelta)) / (averagePrice);
        return (averagePrice > _price, delta);
    }
}
