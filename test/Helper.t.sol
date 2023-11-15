// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "forge-std/Test.sol";

import "./../../src/contracts/core/OrderManager.sol";
import "./../../src/contracts/core/Vault.sol";
import "./../../src/contracts/core/PriceFeed.sol";
import "./../../src/contracts/core/Utils.sol";
import "./../../src/contracts/core/interfaces/IUtils.sol";
import "./../../src/contracts/core/interfaces/IPriceFeed.sol";
import "./../../src/contracts/core/interfaces/IVault.sol";
import "./../../src/contracts/libraries/token/IERC20.sol";
import "./../../src/contracts/libraries/utils/EnumerableSet.sol";
import "./../../src/contracts/libraries/utils/Structs.sol";
import './../../src/contracts/core/USDL.sol';




contract Helper is Test {
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    uint constant minExecutionFeeMarketOrder = 37 * 10 ** 16;
    uint constant minExecutionFeeLimitOrder = 37 * 10 ** 16;
    uint constant maxAllowedDelayPriceFeed = 300;
    uint constant depositFee = 10; //0.1%
    uint constant maxProfitMultiplier = 9;
    uint256 public maxOIImbalance = 10**36;

    uint256 constant collateralSize = 10 * 10**18;
    uint256 constant sizeDelta = 100 * 10**30;
    uint256 constant _executionFee = 10;
    uint256 constant acceptablePrice = 1600 * 10**30;
    uint256 constant takeProfitPrice = 1650;
    uint256 constant stopLossPrice = 1550;
    uint256 constant PRICE_PRECISION = 10 ** 30;
    address[] _addresses;
    uint[] _indexes;
    bytes32[] _keys;

    event CreateIncreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 amountIn,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 queueIndex,
        uint256 blockNumber,
        uint256 blockTime,
        uint256 gasPrice
    );

    event UpdatePosition(
        address indexed account,
        address indexed collateralToken,
        address indexed indexToken,
        bool isLong,
        uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryBorrowingRate,
        uint256 reserveAmount,
        int256 realisedPnl,
        uint256 markPrice
    );

    event CreateOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        uint256 executionFee,
        bool isLong,
        bool triggerAboveThreshold,
        bool indexed isIncreaseOrder,
        bool isMaxOrder
    );

    event UpdateOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        bool isLong,
        bool triggerAboveThreshold,
        bool indexed isIncreaseOrder,
        bool isMaxOrder
    );
    event ExecuteOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        uint256 executionFee,
        uint256 executionPrice,
        bool isLong,
        bool triggerAboveThreshold,
        bool indexed isIncreaseOrder
    );
    event ExecuteIncreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 amountIn,
        uint256 sizeDelta,
        bool isLong,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );
    event CancelOrder(
        address indexed account,
        address collateralToken,
        address indexToken,
        uint256 orderIndex,
        uint256 collateralDelta,
        uint256 sizeDelta,
        uint256 triggerPrice,
        uint256 executionFee,
        bool isLong,
        bool triggerAboveThreshold,
        bool indexed isIncreaseOrder,
        bool isMaxOrder
    );
    event CreateDecreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 index,
        uint256 queueIndex,
        uint256 blockNumber,
        uint256 blockTime
    );
    event ExecuteDecreasePosition(
        address indexed account,
        address _collateralToken,
        address indexToken,
        uint256 collateralDelta,
        uint256 sizeDelta,
        bool isLong,
        address receiver,
        uint256 acceptablePrice,
        uint256 executionFee,
        uint256 blockGap,
        uint256 timeGap
    );

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    address testUserAddress = 0xb3D1a79cdE88c1a9B69Fc43fd1eCEa6df87eFDeB;
    address testFeeReceiver = 0x79F30C5D9e25E70766DCC8ba6b489b5bA0Cc81FD;
    address usdclSource = 0x2c089786d105b95a51c3E7FB5F4dc78E7B963634;

    Vault vault;
    PriceFeed priceFeed;
    Utils utils;
    IUtils _iutils;
    OrderManager orderManager;
    USDL usdl;

    function deployVault() public returns (Vault){
        Vault _vault = new Vault(); 
        console.log("Vault deployed at address: ", address(_vault));
        return _vault;
    }
    function deployUSDL(Vault _vault) public returns (USDL){
        USDL _usdl = new USDL(address(_vault));
        console.log("USDL deployed at address: ", address(_usdl));
        return _usdl;
    }

    function deployAndInitializePriceFeed() public returns (PriceFeed){
        PriceFeed _priceFeed = new PriceFeed(maxAllowedDelayPriceFeed, vm.envAddress("PYTH_CONTRACT"), vm.envAddress("UPDATER"), 15);
        console.log("PriceFeed deployed at address: ", address(_priceFeed));
        _priceFeed.updateTokenIdMapping(vm.envAddress("MNT"), vm.envBytes32("MNT_PYTH_FEED"));
        _priceFeed.updateTokenIdMapping(vm.envAddress("ETH"), vm.envBytes32("ETH_PYTH_FEED"));
        _priceFeed.updateTokenIdMapping(vm.envAddress("BTC"), vm.envBytes32("BTC_PYTH_FEED"));
        _priceFeed.updateTokenIdMapping(vm.envAddress("UNI"), vm.envBytes32("UNI_PYTH_FEED"));
        _priceFeed.updateTokenIdMapping(vm.envAddress("ARB"), vm.envBytes32("ARB_PYTH_FEED"));
        return _priceFeed;
    }
    function deployUtils(Vault _vault, PriceFeed _pricefeed) public returns (Utils){
        utils = new Utils(_vault, _pricefeed);
        console.log("Utils deployed at address: ", address(utils));
        return utils;
    }

    // helper functions
    function getRequestKey(
        address account,
        uint256 index
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(account, index));
    }
    function getOrderKey(address _account, uint256 index) public pure returns(bytes32){
        return keccak256(abi.encodePacked(_account, index));
    }

    function mockPricesOfToken(uint minPrice, uint maxPrice, string memory token) public {
        vm.mockCall(
            address(address(priceFeed)),
            abi.encodeWithSelector(priceFeed.getMaxPriceOfToken.selector, address(vm.envAddress(token))),
            abi.encode(maxPrice * 10**30)
        );
        vm.mockCall(
            address(address(priceFeed)),
            abi.encodeWithSelector(priceFeed.getMinPriceOfToken.selector, address(vm.envAddress(token))),
            abi.encode(minPrice * 10**30)
        );
        // vm.mockCall(
        //     address(address(priceFeed)),
        //     abi.encodeWithSelector(priceFeed.getPriceOfToken.selector, address(vm.envAddress(token))),
        //     abi.encode((minPrice * 10**30 + maxPrice * 10**30)/2)
        // );

    }

    // vault helper
    function increasePositionVault( address _account, address _collateralToken, address _indexToken, uint256 _sizeDelta, bool _isLong) public {
        vault.increasePosition(_account, _collateralToken, _indexToken, _sizeDelta, _isLong);
    }

    function buyUsdlHelper(uint256 _amount) public returns(uint256) {
        mockUSDCLTransfer(_amount);
        uint256 usdlAmount = vault.buyUSDL(vm.envAddress("USDCL"), testUserAddress);
        return usdlAmount;
    }

    function sellUsdlHelper(uint256 _amount) public returns(uint256) {
        mockUSDLTransfer(_amount);
        uint256 usdlAmount = vault.sellUSDL(vm.envAddress("USDCL"), testUserAddress);
        return usdlAmount;
    }

    function mockUSDCLTransfer(uint256 _amount) public {
        vm.mockCall(
            address(address(vm.envAddress("USDCL"))),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault)),
            abi.encode(vault.tokenBalances(vm.envAddress("USDCL")) + _amount)
        );
    }

    function mockUSDLTransfer(uint256 _amount) public{
        vm.mockCall(
            address(address(usdl)),
            abi.encodeWithSelector(IERC20.balanceOf.selector, address(vault)),
            abi.encode(vault.tokenBalances(address(usdl)) + _amount)
        );
    }

    function createLongIncreasePositionOnEth(uint fee) public returns(bytes32) {
        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        return orderManager.createIncreasePosition{value: fee}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, acceptablePrice, 0, 0, fee);
    }
    function createShortIncreasePositionOnEth(uint fee) public returns(bytes32) {
        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        return orderManager.createIncreasePosition{value: fee}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, false, acceptablePrice, 0, 0, fee);
    }
    function createLongDecreasePositionOnEth(uint fee) public returns(bytes32) {
        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        return orderManager.createDecreasePosition{value: fee}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, testUserAddress, acceptablePrice, fee);
    }
    function createShortDecreasePositionOnEth(uint fee) public returns(bytes32) {
        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        return orderManager.createDecreasePosition{value: fee}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, false, testUserAddress, acceptablePrice, fee);
    }
    

    //TODO: technically move  mock prices and adding liquidity to pool to different function.
    function executeIncreasePositionOnEth(bytes32 requestKey, uint minPrice, uint maxPrice) public {
        // mockPrices
        mockPricesOfToken(minPrice,maxPrice,"ETH");
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 1000 *10**18);
        //TODO: replace pool deposit with proper add liquidity to pool.
        vault.directPoolDeposit(vm.envAddress("USDCL"));

        uint256 prevBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(vault));
        uint256 initialFeeBal = address(testUserAddress).balance;
        bool executed = orderManager.executeIncreasePosition(requestKey, payable(address(testUserAddress))); 
    }

    function createDecreaseLongPositionOnEth(uint fee) public returns(bytes32) {
        return orderManager.createDecreasePosition{value: fee}(vm.envAddress("USDCL"), vm.envAddress("ETH"), 0, sizeDelta, true, address(testUserAddress), acceptablePrice, fee);
    }

    function executeDecreasePositionOnEth(bytes32 requestKey, uint minPrice, uint maxPrice) public {
        mockPricesOfToken(minPrice, maxPrice,"ETH");
        orderManager.executeDecreasePosition(requestKey, payable(address(testUserAddress)));
    }

    function createLongLimitOrderOnEth() public {
        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        orderManager.createOrders{value: minExecutionFeeLimitOrder}(collateralSize, vm.envAddress("ETH"), sizeDelta, vm.envAddress("USDCL"), true, true, minExecutionFeeLimitOrder, acceptablePrice, 0, 0, false);
    }

    function setInitialState() public {
        vm.deal(testUserAddress, 2 ether);
        vault = deployVault();
        // initialize vault
        priceFeed  = deployAndInitializePriceFeed();
        utils = deployUtils(vault, priceFeed);
        orderManager = new OrderManager(address(vault), address(utils), address(priceFeed), minExecutionFeeMarketOrder, minExecutionFeeLimitOrder, depositFee, maxProfitMultiplier);
        initializeOrderManager();
        initializeVault();
        mockPricesOfToken(1,1,"USDCL");
    }

    function initializeVault() public {
        vault.setOrderManager(address(orderManager), true);
        vault.setTokenConfig(vm.envAddress("USDCL"), 18, 0, true, true, false, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("ETH"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setUtils(utils);
        vault.setPriceFeed(address(priceFeed));
        vault.setSafetyFactor(100);
        vault.setFundingRate(3600, 100, 1);
        vault.setBorrowingRate(3600, 100);
        vault.setMaxLeverage(54*10000, vm.envAddress("BTC"));
        vault.setMaxLeverage(54*10000, vm.envAddress("ETH"));
    }   

    function initializeOrderManager() public {
        orderManager.setOrderKeeper(address(this), true);
        orderManager.setOrderKeeper(address(orderManager), true); // Discuss with Anirudh
        orderManager.setDelayValues(0, 0, 3600);
        orderManager.setLiquidator(address(this), true);
    }
    function getPositionKey(
        address _account,
        address _collateralToken,
        address _indexToken,
        bool _isLong
    ) public pure returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    _account,
                    _collateralToken,
                    _indexToken,
                    _isLong
                )
            );
    }
}