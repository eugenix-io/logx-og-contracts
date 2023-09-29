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



contract Helper is Test {
    uint constant minExecutionFeeMarketOrder = 37 * 10 ** 16;
    uint constant minExecutionFeeLimitOrder = 37 * 10 ** 16;
    uint constant maxAllowedDelayPriceFeed = 300;
    uint constant depositFee = 10; //0.1%

    uint256 constant collateralSize = 10 * 10**18;
    uint256 constant sizeDelta = 100 * 10**30;
    uint256 constant _executionFee = 10;
    uint256 constant acceptablePrice = 1600 * 10**30;
    uint256 constant takeProfitPrice = 1650;
    uint256 constant stopLossPrice = 1550;
    uint256 constant PRICE_PRECISION = 10 ** 30;

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
        bool indexed isIncreaseOrder
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
        bool indexed isIncreaseOrder
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

    Vault vault;
    PriceFeed priceFeed;
    Utils utils;
    IUtils _iutils;
    OrderManager orderManager;

    function deployVault() public returns (Vault){
        Vault _vault = new Vault(); 
        console.log("Vault deployed at address: ", address(_vault));
        return _vault;
    }

     function deployAndInitializePriceFeed() public returns (PriceFeed){
        PriceFeed _priceFeed = new PriceFeed(maxAllowedDelayPriceFeed, vm.envAddress("PYTH_CONTRACT"), vm.envAddress("UPDATER"));
        console.log("PriceFeed deployed at address: ", address(priceFeed));
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

    function mockPricesOfUSDC(uint usdcMinPrice, uint usdcMaxPrice) public {
        vm.mockCall(
            address(address(priceFeed)),
            abi.encodeWithSelector(priceFeed.getMaxPriceOfToken.selector, address(vm.envAddress("USDC"))),
            abi.encode(usdcMaxPrice * 10**30)
        );
        vm.mockCall(
            address(address(priceFeed)),
            abi.encodeWithSelector(priceFeed.getMinPriceOfToken.selector, address(vm.envAddress("USDC"))),
            abi.encode(usdcMinPrice * 10**30)
        );
    }

    function mockPricesOfEth(uint ethMinPrice, uint ethMaxPrice) public {
        vm.mockCall(
            address(address(priceFeed)),
            abi.encodeWithSelector(priceFeed.getMaxPriceOfToken.selector, address(vm.envAddress("ETH"))),
            abi.encode(ethMaxPrice * 10**30)
        );
        vm.mockCall(
            address(address(priceFeed)),
            abi.encodeWithSelector(priceFeed.getMinPriceOfToken.selector, address(vm.envAddress("ETH"))),
            abi.encode(ethMinPrice * 10**30)
        );
    }

    function createLongIncreasePositionOnEth(uint fee) public returns(bytes32) {
        IERC20(vm.envAddress("USDC")).approve(address(orderManager), collateralSize);
        return orderManager.createIncreasePosition{value: fee}(vm.envAddress("USDC"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, acceptablePrice, 0, 0, fee);
    }

    function executeIncreaseLongPositionOnEth(bytes32 requestKey) public {
        // mockPrices
        mockPricesOfUSDC(1,1);
        mockPricesOfEth(1600,1600);
        IERC20(vm.envAddress("USDC")).transfer(address(vault), 1000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDC"));

        uint256 prevBalance = IERC20(vm.envAddress("USDC")).balanceOf(address(vault));
        uint256 initialFeeBal = address(testUserAddress).balance;
        vm.expectEmit(true, true, true, false, address(orderManager));
        emit ExecuteIncreasePosition(testUserAddress, vm.envAddress("USDC"), vm.envAddress("ETH"), collateralSize, sizeDelta, false, acceptablePrice, minExecutionFeeLimitOrder, 0, 0);
        bool executed = orderManager.executeIncreasePosition(requestKey, payable(address(testUserAddress))); 
    }

    function createLongLimitOrderOnEth() public returns(address orderAccount, uint256 orderIndex){
        IERC20(vm.envAddress("USDC")).approve(address(orderManager), collateralSize);
        (orderAccount, orderIndex) = orderManager.createOrder{value: minExecutionFeeLimitOrder}(collateralSize, vm.envAddress("ETH"), sizeDelta, vm.envAddress("USDC"), true, takeProfitPrice, true, minExecutionFeeLimitOrder, true);
    }

    
}