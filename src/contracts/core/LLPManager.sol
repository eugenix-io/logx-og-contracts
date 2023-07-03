// SPDX-License-Identifier: MIT

import "../libraries/token/IERC20.sol";
import "../libraries/token/SafeERC20.sol";
import "../libraries/utils/ReentrancyGuard.sol";
import './interfaces/IMintable.sol';
import './interfaces/IUSDG.sol';
import "./interfaces/IVault.sol";
import "./interfaces/ILlpManager.sol";
import "./interfaces/IPositionsTracker.sol";
import "../access/Governable.sol";

pragma solidity 0.8.19;

/* TODO
    3. Create LLP token
    7. Why do we need USDG. If valid reason create similar to USDG token else remove it completely
*/

contract LlpManager is ReentrancyGuard, Governable, ILlpManager {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant USDG_DECIMALS = 18;
    uint256 public constant llp_PRECISION = 10 ** 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 48 hours;
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    IVault public override vault;
    IPositionsTracker public positionsTracker;
    address public override usdg;
    address public override llp;

    uint256 public override cooldownDuration;
    mapping(address => uint256) public override lastAddedAt;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    bool public inPrivateMode;
    mapping(address => bool) public isHandler;

    event AddLiquidity(
        address account,
        address token,
        uint256 amount,
        uint256 aumInUsdg,
        uint256 llpSupply,
        uint256 usdgAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address account,
        address token,
        uint256 llpAmount,
        uint256 aumInUsdg,
        uint256 llpSupply,
        uint256 usdgAmount,
        uint256 amountOut
    );

    constructor(
        address _vault,
        address _usdg,
        address _llp,
        address _positionsTracker,
        uint256 _cooldownDuration
    ) {
        gov = msg.sender;
        vault = IVault(_vault);
        usdg = _usdg;
        llp = _llp;
        positionsTracker = IPositionsTracker(_positionsTracker);
        cooldownDuration = _cooldownDuration;
    }

    function setInPrivateMode(bool _inPrivateMode) external onlyGov {
        inPrivateMode = _inPrivateMode;
    }

    function setpositionsTracker(IPositionsTracker _positionsTracker) external onlyGov {
        positionsTracker = _positionsTracker;
    }

    function setHandler(address _handler, bool _isActive) external onlyGov {
        isHandler[_handler] = _isActive;
    }

    function setCooldownDuration(
        uint256 _cooldownDuration
    ) external override onlyGov {
        require(
            _cooldownDuration <= MAX_COOLDOWN_DURATION,
            "llpManager: invalid _cooldownDuration"
        );
        cooldownDuration = _cooldownDuration;
    }

    function setAumAdjustment(
        uint256 _aumAddition,
        uint256 _aumDeduction
    ) external onlyGov {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
    }

    function addLiquidityForAccount(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdg,
        uint256 _minllp
    ) external override nonReentrant returns (uint256) {
        _validateHandler();
        return
            _addLiquidity(
                _fundingAccount,
                _account,
                _token,
                _amount,
                _minUsdg,
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

    function getAumInUsdg(
        bool maximise
    ) public view override returns (uint256) {
        uint256 aum = getAum(maximise);
        return (aum * (10 ** USDG_DECIMALS)) / (PRICE_PRECISION);
    }

    function getAum(bool maximise) public view returns (uint256) {
        uint256 length = vault.allWhitelistedTokensLength();
        uint256 aum = aumAddition;
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
                    ( bool hasProfit, uint256 delta) = positionsTracker.getGlobalPositionDelta(token, false);
                    if (!hasProfit) {
                        // add losses from shorts
                        aum = aum + (delta);
                    } else {
                        profits = profits + (delta);
                    }
                }

                uint256 longSize = _vault.globalLongSizes(token);

                if (longSize > 0) {
                    ( bool hasProfit, uint256 delta) = positionsTracker.getGlobalPositionDelta(token, true);
                    if (!hasProfit) {
                        // add losses from longs
                        aum = aum + (delta);
                    } else {
                        profits = profits + (delta);
                    }
                }
            }
        }

        aum = profits > aum ? 0 : aum - (profits) ;
        return aumDeduction > aum ? 0 : aum - (aumDeduction);
    }

    function getGlobalShortAveragePrice(
        address _token
    ) public view returns (uint256) {
        return positionsTracker.globalShortAveragePrices(_token);
    }

    function _addLiquidity(
        address _fundingAccount,
        address _account,
        address _token,
        uint256 _amount,
        uint256 _minUsdg,
        uint256 _minllp
    ) private returns (uint256) {
        require(_amount > 0, "llpManager: invalid _amount");

        // calculate aum before buyUSDG
        uint256 aumInUsdg = getAumInUsdg(true);
        uint256 llpSupply = IERC20(llp).totalSupply();

        IERC20(_token).safeTransferFrom(
            _fundingAccount,
            address(vault),
            _amount
        );
        uint256 usdgAmount = vault.buyUSDG(_token, address(this));
        require(usdgAmount >= _minUsdg, "llpManager: insufficient USDG output");

        uint256 mintAmount = aumInUsdg == 0
            ? usdgAmount
            : (usdgAmount * (llpSupply)) / (aumInUsdg);
        require(mintAmount >= _minllp, "llpManager: insufficient llp output");

        IMintable(llp).mint(_account, mintAmount);

        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(
            _account,
            _token,
            _amount,
            aumInUsdg,
            llpSupply,
            usdgAmount,
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
        require(_llpAmount > 0, "llpManager: invalid _llpAmount");
        require(
            lastAddedAt[_account] + (cooldownDuration) <= block.timestamp,
            "llpManager: cooldown duration not yet passed"
        );

        // calculate aum before sellUSDG
        uint256 aumInUsdg = getAumInUsdg(false);
        uint256 llpSupply = IERC20(llp).totalSupply();

        uint256 usdgAmount = (_llpAmount * (aumInUsdg)) / (llpSupply);
        uint256 usdgBalance = IERC20(usdg).balanceOf(address(this));
        if (usdgAmount > usdgBalance) {
            IUSDG(usdg).mint(address(this), usdgAmount - (usdgBalance));
        }

        IMintable(llp).burn(_account, _llpAmount);

        IERC20(usdg).transfer(address(vault), usdgAmount);
        uint256 amountOut = vault.sellUSDG(_tokenOut, _receiver);
        require(amountOut >= _minOut, "llpManager: insufficient output");

        emit RemoveLiquidity(
            _account,
            _tokenOut,
            _llpAmount,
            aumInUsdg,
            llpSupply,
            usdgAmount,
            amountOut
        );

        return amountOut;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "llpManager: forbidden");
    }
}
