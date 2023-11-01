// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "./Helper.t.sol";



contract OrderManagerTest is Test, Helper {
   
    //TODO: add a function in helper to do all these tasks such as creating orderManager, creating Vault, adding liquidity to pool. This way every test will test whatever functionality but the setup will be ready.
    function setUp() public {
        setInitialState();
    }

    /* 1. createIncreasePosition   
        1.1 check _executionFee for each of the three: marketOrder, market with tp and sl, market with tp or sl
        1.2 orderManagerContract balance should increase by _amountIn
        1.3 positionRequest is created and stored succesfully: 
            increasePositionsIndex[account] is increased by one
            request at increasePositionRequests[key] is the same as the one we created
            increasePositionRequestKeys now contains the request key - Skipping This
        1.4 check CreateIncreasePosition event is emitted or not
        1.5 if takeProfitPrice != 0 check if corresponsing tp order is created or not, similary check for sl order
            ordersIndex[_account] is increased by 1
            orderKeys is populated with the correct orderKey DISCUSS
            emitOrderCreateEvent is emitted
        1. correct positionKey for a request is returned or not 
    */
   function testMarketOrderWithFeeZero() public {
        vm.expectRevert("OrderManager: market order execution fee less than min execution fee");
        orderManager.createIncreasePosition{value: 0}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, acceptablePrice, 0, 0, 0);
   }

   function testMarketWithTPSLOrderWithLessFee() public {
        vm.expectRevert("OrderManager: tpsl execution fee less than min execution fee");
        orderManager.createIncreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, acceptablePrice, takeProfitPrice, stopLossPrice, minExecutionFeeMarketOrder);

   }

   function testMarketWithTPOrderWithLessFee() public {
        vm.expectRevert("OrderManager: tp or sl execution fee less than min execution fee");
        orderManager.createIncreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, acceptablePrice, takeProfitPrice, 0, minExecutionFeeMarketOrder);

   }
    function testSuccessfulCreateIncreasePosition() public {
        vm.startPrank(testUserAddress);
        uint256 tpslFeeAmount = minExecutionFeeMarketOrder + 2 * minExecutionFeeLimitOrder;
        uint256 prevBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(orderManager));
        uint256 prevPositionIndex = orderManager.increasePositionsIndex(testUserAddress);
        uint256 prevOrderIndex = orderManager.ordersIndex(testUserAddress);
        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);

        vm.expectEmit(true, true, true, false, address(orderManager));
        emit CreateIncreasePosition(
            testUserAddress,
            vm.envAddress("USDCL"),
            vm.envAddress("ETH"),
            collateralSize,
            sizeDelta,
            true,
            acceptablePrice,
            tpslFeeAmount,
            prevBalance+1,
            0,
            0,
            0,
            0
        );

        vm.expectEmit(true, true, true, false, address(orderManager));
        emit CreateOrder(
            testUserAddress,
            vm.envAddress("USDCL"),
            vm.envAddress("ETH"),
            prevOrderIndex,
            collateralSize,
            sizeDelta,
            takeProfitPrice,
            0, 
            true,
            true,
            false,
            false
        );

        vm.expectEmit(true, true, true, false, address(orderManager));
        emit UpdateOrder(
            testUserAddress,
            vm.envAddress("USDCL"),
            vm.envAddress("ETH"),
            prevOrderIndex,
            collateralSize,
            sizeDelta,
            takeProfitPrice,
            true,
            true,
            false,
            false
        );

        vm.expectEmit(true, true, true, false, address(orderManager));
        emit CreateOrder(
            testUserAddress,
            vm.envAddress("USDCL"),
            vm.envAddress("ETH"),
            prevOrderIndex+1,
            collateralSize,
            sizeDelta,
            takeProfitPrice,
            0, 
            true,
            true,
            false,
            false
        );

        vm.expectEmit(true, true, true, false, address(orderManager));
        emit UpdateOrder(
            testUserAddress,
            vm.envAddress("USDCL"),
            vm.envAddress("ETH"),
            prevOrderIndex+1,
            collateralSize,
            sizeDelta,
            takeProfitPrice,
            true,
            true,
            false,
            false
        );

        // should open a position and create two orders one tp and one sl
        bytes32 requestKey = orderManager.createIncreasePosition{value: tpslFeeAmount}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, acceptablePrice, takeProfitPrice, stopLossPrice, tpslFeeAmount);
        uint256 finalBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(orderManager));
        uint256 finalPositionIndex = orderManager.increasePositionsIndex(testUserAddress);
        uint256 finalOrderIndex = orderManager.ordersIndex(testUserAddress);

        assertEq(finalBalance-prevBalance, collateralSize);
        assertEq(requestKey, getRequestKey(testUserAddress, finalPositionIndex));

        // check position opened
        assertEq(finalPositionIndex, prevPositionIndex+1);

        //(address,address,address,uint256,uint256,bool,uint256,uint256,uint256,uint256)

        (address positionAccount,
        address positionCollateralToken,
        address PositionIndexToken,
        uint256 positionAmountIn, 
        uint256 positionSizeDelta, 
        bool positionIsLong, 
        uint256 positionAcceptablePrice, 
        uint256 positionExecutionFee
        ,,) = orderManager.increasePositionRequests(requestKey);

        assertEq(positionAccount, testUserAddress);
        assertEq(positionCollateralToken, vm.envAddress("USDCL"));
        assertEq(PositionIndexToken, vm.envAddress("ETH"));
        assertEq(positionAmountIn, collateralSize);
        assertEq(positionSizeDelta, sizeDelta);
        assertEq(positionIsLong, true);
        assertEq(positionAcceptablePrice, acceptablePrice);
        assertEq(positionExecutionFee, minExecutionFeeMarketOrder);

        // check orders created
        assertEq(finalOrderIndex, prevOrderIndex+3);
        {   
            uint256 tpOrderIndex = prevOrderIndex;
            bytes32 tpOrderKey = getOrderKey(testUserAddress, tpOrderIndex );

            (
                address tpOrderAccount,
                address tpOrderCollateralToken,
                address tpOrderIndexToken,
                uint256 tpOrderCollateralDelta,
                uint256 tpOrderSizeDelta,
                uint256 tpOrderTriggerPrice,
                uint256 tpOrderExecutionFee,
                bool tpOrderIsLong,
                bool tpOrderTriggerAboveThreshold,
                bool tpOrderIsIncreaseOrder,
            ) = orderManager.orders(tpOrderKey);

            assertEq(tpOrderAccount, testUserAddress);
            assertEq(tpOrderCollateralToken, vm.envAddress("USDCL"));
            assertEq(tpOrderIndexToken, vm.envAddress("ETH"));
            assertEq(tpOrderCollateralDelta, 0); // 0 since its a tpsl order on a market order
            assertEq(tpOrderSizeDelta, sizeDelta);
            assertEq(tpOrderTriggerPrice, takeProfitPrice);
            assertEq(tpOrderExecutionFee, minExecutionFeeLimitOrder);
            assertEq(tpOrderIsLong, true);
            assertEq(tpOrderTriggerAboveThreshold, true);
            assertEq(tpOrderIsIncreaseOrder, false);

        }
        {
            uint256 slpOrderIndex = prevOrderIndex+1;
            bytes32 slOrderKey = getOrderKey(testUserAddress, slpOrderIndex);

            (
                address slOrderAccount,
                address slOrderCollateralToken,
                address slOrderIndexToken,
                uint256 slOrderCollateralDelta,
                uint256 slOrderSizeDelta,
                uint256 slOrderTriggerPrice,
                uint256 slOrderExecutionFee,
                bool slOrderIsLong,
                bool slOrderTriggerAboveThreshold,
                bool slOrderIsIncreaseOrder,
            ) = orderManager.orders(slOrderKey);

            assertEq(slOrderAccount, testUserAddress);
            assertEq(slOrderCollateralToken, vm.envAddress("USDCL"));
            assertEq(slOrderIndexToken, vm.envAddress("ETH"));
            assertEq(slOrderCollateralDelta, 0); // 0 since its a tpsl order on a market order
            assertEq(slOrderSizeDelta, sizeDelta);
            assertEq(slOrderTriggerPrice, stopLossPrice);
            assertEq(slOrderExecutionFee, minExecutionFeeLimitOrder);
            assertEq(slOrderIsLong, true);
            assertEq(slOrderTriggerAboveThreshold, false);
            assertEq(slOrderIsIncreaseOrder, false);
        }
        vm.stopPrank();
    }
    /* 3. createDecreasePosition
        3.1 should fail if_executionFee < minExecutionFeeMarketOrder and  _executionFee != msg.value
        3.2 decreasePositionsIndex[account] should increase by 1
        3.3 positionRequest is created and stored succesfully: 
            decreasePositionsIndex[account] is increased by one, 
            request at decreasePositionRequests[key] is the same as the one we created, 
            decreasePositionRequestKeys now contains the request key
        3.4 CreateDecreasePosition event is emitted with right values
   */

  function testCreateDecreasePositionWithoutExistingPosition() public {
    vm.expectRevert("OrderManager: Sufficient size doesn't exist");
    bytes32 requestKey = orderManager.createDecreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, testUserAddress, acceptablePrice, minExecutionFeeMarketOrder);
  }
  function testSuccessfulCreateDecreasePosition() public {
    vm.startPrank(testUserAddress);
    vm.expectRevert("OrderManager: fee");
    orderManager.createDecreasePosition{value: 0}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, testUserAddress, acceptablePrice, 0);
    vm.expectRevert("OrderManager: value sent is not equal to execution fee");
    orderManager.createDecreasePosition{value: 0}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, testUserAddress, acceptablePrice, minExecutionFeeMarketOrder);
    
    bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
    executeIncreasePositionOnEth(requestKey, 1600, 1600);
    console.log("executed");

    uint256 prevPositionIndex = orderManager.decreasePositionsIndex(testUserAddress);
    vm.expectEmit(true, true, true, false, address(orderManager));
    emit CreateDecreasePosition(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, testUserAddress, acceptablePrice, minExecutionFeeMarketOrder, 0, 0, 0,0);
    requestKey = orderManager.createDecreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, testUserAddress, acceptablePrice, minExecutionFeeMarketOrder);
    uint256 finalPositionIndex = orderManager.decreasePositionsIndex(testUserAddress);
    assertEq(finalPositionIndex, prevPositionIndex+1);

    (
        address positionAccount,
        address positionCollateralToken,
        address PositionIndexToken,
        uint256 positionCollateralDelta, 
        uint256 positionSizeDelta, 
        bool positionIsLong, 
        address positionReceiver,
        uint256 positionAcceptablePrice, 
        uint256 positionExecutionFee
        ,,) = orderManager.decreasePositionRequests(requestKey);

        assertEq(positionAccount, testUserAddress);
        assertEq(positionCollateralToken, vm.envAddress("USDCL"));
        assertEq(PositionIndexToken, vm.envAddress("ETH"));
        assertEq(positionCollateralDelta, collateralSize);
        assertEq(positionSizeDelta, sizeDelta);
        assertEq(positionIsLong, true);
        assertEq(positionAcceptablePrice, acceptablePrice);
        assertEq(positionExecutionFee, minExecutionFeeMarketOrder);
  }

    /* 5. createOrder
        5.1 _executionFee is sent in msg.value
        5.2 if isIncreaseOrder check collateral amount is sent or not
        5.3 _createOrder is covered in createIncreasePosition
   */

    function testCreateOrder() public {
        vm.startPrank(testUserAddress);

        vm.expectRevert("OrderManager: incorrect execution fee transferred");
        // long false, isincreasing true, 
        orderManager.createOrders(collateralSize, vm.envAddress("ETH"), sizeDelta, vm.envAddress("USDCL"), false, true, minExecutionFeeLimitOrder, acceptablePrice, 0, 0, false);

        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        uint256 prevBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(orderManager));
        uint256 prevOrderIndex = orderManager.ordersIndex(testUserAddress);

        vm.mockCall(
            address(address(utils)),
            abi.encodeWithSelector(_iutils.tokenToUsdMin.selector),
            abi.encode(1*collateralSize)
        );

        mockPricesOfToken(1550,1550, "ETH");
        // testing a short limit order
        bool isLong = false;
        orderManager.createOrders{value: minExecutionFeeLimitOrder}(collateralSize, vm.envAddress("ETH"), sizeDelta, vm.envAddress("USDCL"), isLong, true, minExecutionFeeLimitOrder, acceptablePrice, 0, 0, false);

        uint256 finalBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(orderManager));
        assertEq(finalBalance-prevBalance, collateralSize);

        {
            uint256 slpOrderIndex = prevOrderIndex;
            bytes32 slOrderKey = getOrderKey(testUserAddress, slpOrderIndex);

            (
                address slOrderAccount,
                address slOrderCollateralToken,
                address slOrderIndexToken,
                uint256 slOrderCollateralDelta,
                uint256 slOrderSizeDelta,
                uint256 slOrderTriggerPrice,
                uint256 slOrderExecutionFee,
                bool slOrderIsLong,
                bool slOrderTriggerAboveThreshold,
                bool slOrderIsIncreaseOrder,
            ) = orderManager.orders(slOrderKey);

            assertEq(slOrderAccount, testUserAddress);
            assertEq(slOrderCollateralToken, vm.envAddress("USDCL"));
            assertEq(slOrderIndexToken, vm.envAddress("ETH"));
            assertEq(slOrderCollateralDelta, collateralSize); // 0 since its a tpsl order on a market order
            assertEq(slOrderSizeDelta, sizeDelta);
            assertEq(slOrderTriggerPrice, acceptablePrice);
            assertEq(slOrderExecutionFee, minExecutionFeeLimitOrder);
            assertEq(slOrderIsLong, false);
            assertEq(slOrderTriggerAboveThreshold, !isLong);
            assertEq(slOrderIsIncreaseOrder, true);
        }
    }

    /* 8. executeIncreasePosition
        8.1 check for a non existent key
        8.2 check for expired position
        8.3 _key should be deleted from increasePositionRequests
        8.4 balance of vault should increase
        8.5 check fee collection logic - visit this again
        8.6 during execution execution:
            8.7.1 if long position markPrice <= acceptablePrice
            8.8.1 if short position then vice versa 
        8.7 executionFee is sent to _executionFeeReceiver successfully
        8.8 ExecuteIncreasePosition is emitted correctly
  */

    function test_maxLeverageCheck() public {
        vm.startPrank(testUserAddress);
        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), 1000*10**18);
        bytes32 requestKey = orderManager.createIncreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), 1000*10**18, 47500*10**30, false, acceptablePrice, 0, 0, minExecutionFeeMarketOrder);
        mockPricesOfToken(1641,1641,"ETH");
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 60000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDCL"));
        bool executed = orderManager.executeIncreasePosition(requestKey, payable(address(testUserAddress))); 
        console.log("executed", executed);
    }

    function testExecuteIncreasePosition() public {
        vm.startPrank(testUserAddress);

        bytes32 randomKey = getRequestKey(address(testUserAddress), 123);
        bool executedRandom = orderManager.executeIncreasePosition(randomKey, payable(testUserAddress)); // some random bytes key
        assertEq(executedRandom, true);

        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        bytes32 requestKey = orderManager.createIncreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, false, acceptablePrice, 0, 0, minExecutionFeeMarketOrder);
        // mockPrices
        mockPricesOfToken(1650,1650, "ETH");
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 1000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDCL"));

        uint256 prevBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(vault));
        uint256 initialFeeBal = address(testUserAddress).balance;
        vm.expectEmit(true, true, true, false, address(orderManager));
        emit ExecuteIncreasePosition(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, false, acceptablePrice, minExecutionFeeLimitOrder, 0, 0);
        bool executed = orderManager.executeIncreasePosition(requestKey, payable(address(testUserAddress))); 
        uint256 finalBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(vault));
        uint256 finalFeeBal = address(testUserAddress).balance;

        (
            address positionAccount,
            address positionCollateralToken,
            address PositionIndexToken,
            uint256 positionAmountIn, 
            uint256 positionSizeDelta, 
            bool positionIsLong, 
            uint256 positionAcceptablePrice, 
            uint256 positionExecutionFee
        ,,) = orderManager.increasePositionRequests(requestKey);
        assertEq(positionAccount, address(0));
        assertEq(finalBalance-prevBalance,10 * 10**18);
        assertEq(finalFeeBal-initialFeeBal, minExecutionFeeMarketOrder);


        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        bytes32 requestKey2 = orderManager.createIncreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize/2, sizeDelta/2, false, acceptablePrice, 0, 0, minExecutionFeeMarketOrder);
        mockPricesOfToken(1590, 1610, "ETH");
        vm.expectRevert("BasePositionManager: markPrice < price");
        bool executed2 = orderManager.executeIncreasePosition(requestKey2, payable(testUserAddress)); // some random bytes key


        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        bytes32 requestKey3 = orderManager.createIncreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize/2, sizeDelta/2, true, acceptablePrice, 0, 0, minExecutionFeeMarketOrder);
        vm.expectRevert("BasePositionManager: markPrice > price");
        bool executed3 = orderManager.executeIncreasePosition(requestKey3, payable(testUserAddress)); // some random bytes key

    }

    /* 9. executeDecreasePosition
        9.1 check for a non existent key
        9.2 check for expired position
        9.3 _key should be deleted from decreasePositionRequests
        9.5 mock amountOut and check if receiver gets the amountOut successfully
        9.6 executionFee is sent to _executionFeeReceiver successfully 
        9.8 ExecuteIncreasePosition is emitted correctly
          
        TODO: MANU 
            9.4 during execution: mockPrice and check this
                9.4.1 if long position markPrice >= acceptablePrice
                9.4.2  if short position then vice versa
            9.5 If the user is just decreasign leverage then check transfer of deposit fee
    */

   function testExecuteDecreasePosition() public {
        vm.startPrank(testUserAddress);
        bytes32 randomKey = getRequestKey(address(testUserAddress), 123);
        bool executedRandom = orderManager.executeDecreasePosition(randomKey, payable(testUserAddress)); // some random bytes key
        assertEq(executedRandom, true);

        // now 1. open create a open position request, execute request, create a decrease position request then execute it

        // 1. create a open position 
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        // 2. Execute increase position
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
        // 3. create a decrease position request for open position
        bytes32 decRequestKey = orderManager.createDecreasePosition{value: minExecutionFeeMarketOrder}(vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, testUserAddress, acceptablePrice, minExecutionFeeMarketOrder);
        
        uint256 prevBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(testUserAddress));
        uint256 initialFeeBal = address(testUserAddress).balance;
        vm.expectEmit(true, true, true, false, address(orderManager));
        emit ExecuteDecreasePosition(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), collateralSize, sizeDelta, true, testUserAddress,  acceptablePrice, minExecutionFeeLimitOrder, 0, 0);
        bool executedDecr = orderManager.executeDecreasePosition(decRequestKey, payable(address(testUserAddress))); 
        uint256 finalBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(testUserAddress));
        uint256 finalFeeBal = address(testUserAddress).balance;

        // check if user balance increased by collateralSize*98%
        assertEq(finalBalance-prevBalance, (collateralSize*98)/100);

        // cehck fee return 
        assertEq(finalFeeBal-initialFeeBal, minExecutionFeeMarketOrder);

        // check position got deleted
        ( address positionAccount,,,,,,,,,, ) = orderManager.decreasePositionRequests(decRequestKey);
        assertEq(positionAccount, address(0));
        (
            uint256 positionSize,
            uint256 positionCollateral,
            uint256 positionAVGPrice,
            uint256 positionEntryBorrowingRate,
            int256 positionEntryFundingRate,
            uint256 positionReserveAmount,
            uint256 positionRealisedPnl,
            bool isProfit,
            uint256 positionLastIncreasedTime
        ) = vault.getPosition(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), true);
        assertEq(positionSize, 0);
        assertEq(positionCollateral, 0);
        assertEq(positionAVGPrice, 0);
        assertEq(positionEntryBorrowingRate, 0);
        assertEq(positionEntryFundingRate, 0);
        assertEq(positionReserveAmount, 0);
        assertEq(positionRealisedPnl, 0);
        assertEq(positionLastIncreasedTime, 0);
   }

    /* 10. executeOrder
        10.1 check non existent order
        10.2 if increasingOrder vault balance should increase by collateralDelta
        10.3 if decreasingOrder:
            order.sizeDelta < size of position, else cancel order
            mock vault decreasePosition retun value amountOut, then order.account balance should increase by 
        10.4 order should be removed from orders
        10.5 orderKey should be removed from orderKeys set
        10.6 check if executionFee goes back to _feeReceiver
        10.7 ExecuteOrder, UpdateOrder event emitted successfully
    */

   /* 7. cancelOrder
        7.1 check for unauthorised user
        7.2 check for non existent order
        7.3 order should not be present in orders
        7.4 orderKey should not be present in orderKeys set
        7.5 check if collateral is transfered back to the user, balance of contract should decrease and user should increase
        7.6 CancelOrder, UpdateOrder events are emitted
   */

    // also covers cancel orders
    function testExecuteFailForNonExistentOrder() public {
        vm.expectRevert("OrderManager: non-existent order");
        orderManager.executeOrder(testUserAddress, 0, payable(testUserAddress)); // non existent orderIndex
    }

    function testSuccessfulExecutionOfLimitOrder() public {
        mockPricesOfToken(1649, 1651,"ETH"); // current market price
        // -------------------------// Place an order to open a position and check its execution -------------------------//
        vm.startPrank(testUserAddress);
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 1000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDCL"));
        uint256 orderIndex = orderManager.ordersIndex(testUserAddress);
        createLongLimitOrderOnEth();
        vm.stopPrank();

        // execute order
        mockPricesOfToken(1599, 1599,"ETH");
        uint256 prevVaultBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(vault));
        orderManager.executeOrder(testUserAddress, orderIndex, payable(testUserAddress));
        uint256 nextVaultBalance = IERC20(vm.envAddress("USDCL")).balanceOf(address(vault));
        assertEq(nextVaultBalance-prevVaultBalance, collateralSize);
    }

    function testCloseOrderWithSizeGreaterThanExistingPosition() public {
        mockPricesOfToken(1599, 1601, "ETH");
        //-------------------------// Place a decreasing order which exceeds position size and it should get cancelled -------------------------//
        vm.startPrank(testUserAddress);
        // IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        uint256 orderIndex2 = orderManager.ordersIndex(testUserAddress);
        //long true increasingOrder false
        orderManager.createOrders{value: minExecutionFeeLimitOrder}(collateralSize, vm.envAddress("ETH"), sizeDelta*2, vm.envAddress("USDCL"), true, false, minExecutionFeeLimitOrder, 0, takeProfitPrice*PRICE_PRECISION, 0, false);
        vm.stopPrank();

        vm.expectEmit(true, true, true, true, address(orderManager));
        emit CancelOrder(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), orderIndex2, collateralSize, sizeDelta*2, takeProfitPrice*PRICE_PRECISION, minExecutionFeeLimitOrder, true, true, false, false);
        mockPricesOfToken(takeProfitPrice+1, takeProfitPrice+1, "ETH");
        orderManager.executeOrder(testUserAddress, orderIndex2, payable(testUserAddress)); // this should cancel because size*2
    }
    
   function testExecuteOrder() public {
        mockPricesOfToken(1599, 1601,"ETH");

        vm.startPrank(testUserAddress);
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
    
        //-------------------------// Place another decreasing order this time with right values and it shoudl execute -------------------------//-------------------------//-------------------------
        uint256 orderIndex3 = orderManager.ordersIndex(testUserAddress);
        // tested a close tp order here
        orderManager.createOrders{value: minExecutionFeeLimitOrder}(collateralSize, vm.envAddress("ETH"), sizeDelta, vm.envAddress("USDCL"), true, false, minExecutionFeeLimitOrder, 0, takeProfitPrice*10**30, 0, false);
        vm.stopPrank();
        mockPricesOfToken(1649, 1651, "ETH");
        uint256 initialUserBal = IERC20(vm.envAddress("USDCL")).balanceOf(address(testUserAddress));
        uint256 initialFeeBal = address(testFeeReceiver).balance;
        orderManager.executeOrder(testUserAddress, orderIndex3, payable(testFeeReceiver));
        uint256 finalUserBal = IERC20(vm.envAddress("USDCL")).balanceOf(address(testUserAddress));
        uint256 finalFeeBal = address(testFeeReceiver).balance;

        // TODO: add an assert to check if finalUserBal-initialUserBal is in a centain percentage of collateralSize, delta is not exactly equal to collateralSize beacause of fees and all
        console.log("finalUserBal", finalUserBal - initialUserBal); // finalUserBal - initialUserBal = 9678861296184130829 ~ 10**18

        bytes32 key = getOrderKey(testUserAddress, orderIndex3);
        ( address account,,,,,,,,,,) = orderManager.orders(key);
        assertEq(account, address(0), "Address doesn't match"); // order delete after execution
        assertEq(finalFeeBal-initialFeeBal, minExecutionFeeLimitOrder, "Balances doesn't match");
   }

    /*
        deposit fee base order manager - feature addition 
    */

    /* 2. cancelIncreasePosition
        2.1 try cancelling a random request that is not present in increasePositionRequests
        2.2 if keeper call check block number
        2.3 if not keeper try cancelling with a random address - shoudl fail 403
        2.4 if authorised to cancel check min delay time
        2.5 increasePositionRequests should not contain key
        2.6 check if collateral is transfered back
        2.7 check if CancelIncreasePosition is emitted with correct values
   */

   /* 4. cancelDecreasePosition
        4.1 try cancelling a random request that is not present in decreasePositionRequests
        4.2 validation check similar to cancelIncreasePosition
        4.3 decreasePositionRequests should not contain key
        4.4 executionFee is transferred to _executionFeeReceiver
        4.5 CancelDecreasePosition is emitted successfully
   */ 

    /* 6. updateOrder
        6.1 check for non existent order
        6.2 check emitted event
        6.3 after updating check if values are updated for that order correctly
   */  

   /* executeMultipleOrders
        1. pass one invalid order and see if its cancelled
        2. pass 2 valid and 1 invalid
        3. overflow
   */
    

   function testExecuteMultipleOrderInvalidPriceCatched() public{
        mockPricesOfToken(1649, 1651,"ETH"); // current market price
        vm.startPrank(testUserAddress);
        uint256 orderIndex = orderManager.ordersIndex(testUserAddress);
        createLongLimitOrderOnEth();
        vm.stopPrank();
        _addresses.push(testUserAddress);
        _indexes.push(orderIndex);
        // don't mock trigger price, check if invalid price revert is catched
        // test will pass if the error is catched successfully
        orderManager.executeMultipleOrders(_addresses, _indexes, payable(address(this))); // revert within the orderManager contract itself
   }

   function testExecuteMultipleOrderVaultFailCatch() public {
        mockPricesOfToken(1649, 1651, "ETH"); // current market price
        vm.startPrank(testUserAddress);
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 1000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDCL"));
        uint256 orderIndex = orderManager.ordersIndex(testUserAddress);
        createLongLimitOrderOnEth();
        vm.stopPrank();
        mockPricesOfToken(1599, 1599,"ETH");
        vm.mockCall(
            address(utils),
            abi.encodeWithSelector(utils.collectMarginFees.selector),
            abi.encode(-1,-1) // to cause an arthimetic overflow/underflow
        );
        _addresses.push(testUserAddress);
        _indexes.push(orderIndex);
        // test will pass if the error is catched successfully
       orderManager.executeMultipleOrders(_addresses, _indexes, payable(address(this))); // catch overflow from vault
   }

   function testExecuteMultipleSuccessfull() public {
        mockPricesOfToken(1649, 1651,"ETH"); // current market price
        vm.startPrank(testUserAddress);
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 1000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDCL"));
        uint256 orderIndex1 = orderManager.ordersIndex(testUserAddress);
        createLongLimitOrderOnEth();
        uint256 orderIndex2 = orderManager.ordersIndex(testUserAddress);
        createLongLimitOrderOnEth();
        uint256 orderIndex3 = orderManager.ordersIndex(testUserAddress);
        createLongLimitOrderOnEth();
        vm.stopPrank();

        _addresses.push(testUserAddress);
        _addresses.push(testUserAddress);
        _addresses.push(testUserAddress);

        _indexes.push(orderIndex1);
        _indexes.push(orderIndex2);
        _indexes.push(orderIndex3);
        mockPricesOfToken(1599, 1599, "ETH");

        vm.expectEmit(true, true, true, false, address(orderManager));
        emit ExecuteOrder(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), orderIndex1, collateralSize, sizeDelta, acceptablePrice, minExecutionFeeLimitOrder,1559 * 10**30, true, false, true);
        vm.expectEmit(true, true, true, false, address(orderManager));
        emit ExecuteOrder(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), orderIndex2, collateralSize, sizeDelta, acceptablePrice, minExecutionFeeLimitOrder,1559 * 10**30, true, false, true);
        vm.expectEmit(true, true, true, false, address(orderManager));
        emit ExecuteOrder(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), orderIndex3, collateralSize, sizeDelta, acceptablePrice, minExecutionFeeLimitOrder,1559 * 10**30, true, false, true);
        orderManager.executeMultipleOrders(_addresses, _indexes, payable(address(testUserAddress))); // expect three ExecuteOrder events
   }

   function testExecuteMultiplePartialSuccessfull() public{
        mockPricesOfToken(1649, 1651,"ETH");
        vm.startPrank(testUserAddress);
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 1000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDCL"));
        uint256 orderIndex1 = orderManager.ordersIndex(testUserAddress); // 1. valid order
        createLongLimitOrderOnEth();
        _addresses.push(testUserAddress);
        _indexes.push(orderIndex1);

        uint256 orderIndex2 = orderManager.ordersIndex(testUserAddress);
        IERC20(vm.envAddress("USDCL")).approve(address(orderManager), collateralSize);
        orderManager.createOrders{value: minExecutionFeeLimitOrder}(collateralSize, vm.envAddress("ETH"), sizeDelta, vm.envAddress("USDCL"), true, true, minExecutionFeeLimitOrder, acceptablePrice/2, 0, 0, false); // 2. try executing this when price does not reach the trigger price, so this shoudl fail
        
        _addresses.push(testUserAddress);
        _indexes.push(orderIndex2);

        uint256 orderIndex3 = orderManager.ordersIndex(testUserAddress); // 3. valid order
        createLongLimitOrderOnEth();
        _addresses.push(testUserAddress);
        _indexes.push(orderIndex3);
        vm.stopPrank();

        mockPricesOfToken(1599, 1599,"ETH");

        vm.expectEmit(true, true, true, false, address(orderManager));
        emit ExecuteOrder(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), orderIndex1, collateralSize, sizeDelta, acceptablePrice, minExecutionFeeLimitOrder,1559 * 10**30, true, false, true);
        
        vm.expectEmit(true, true, true, false, address(orderManager));
        emit ExecuteOrder(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), orderIndex3, collateralSize, sizeDelta, acceptablePrice, minExecutionFeeLimitOrder,1559 * 10**30, true, false, true);
        
        orderManager.executeMultipleOrders(_addresses, _indexes, payable(address(testUserAddress))); // expect two ExecuteOrder events

        {
            uint256 _orderIndex = orderIndex1;
            // order1 should not exist
            (address account,
            address collateralToken,
            address indexToken,
            uint256 collateralDelta,
            uint256 sizeDelta,
            uint256 triggerPrice,
            uint256 executionFee,
            bool isLong,
            bool triggerAboveThreshold,
            bool isIncreaseOrder,
            bool isMaxOrder) = orderManager.orders(getOrderKey(testUserAddress, _orderIndex));
            assertEq(account, address(0));
            assertEq(collateralToken, address(0));
            assertEq(indexToken, address(0));
            assertEq(collateralDelta, 0);
            assertEq(sizeDelta, 0);
            assertEq(triggerPrice, 0);
            assertEq(executionFee, 0);
        }
        {
            uint256 _orderIndex = orderIndex2;
            // order2 should exist
            (address account,
            address collateralToken,
            address indexToken,
            uint256 collateralDelta,
            uint256 _sizeDelta,
            uint256 triggerPrice,
            uint256 executionFee,
            bool isLong,
            bool triggerAboveThreshold,
            bool isIncreaseOrder,
            bool isMaxOrder) = orderManager.orders(getOrderKey(testUserAddress, _orderIndex));
            assertEq(account, address(testUserAddress));
            assertEq(collateralToken, vm.envAddress("USDCL"));
            assertEq(indexToken, vm.envAddress("ETH"));
            assertEq(collateralDelta, collateralSize);
            assertEq(_sizeDelta, sizeDelta);
            assertEq(triggerPrice, acceptablePrice/2);
            assertEq(executionFee, minExecutionFeeLimitOrder);
        }
        {
            uint256 _orderIndex = orderIndex3;
            // order1 should not exist
            (address account,
            address collateralToken,
            address indexToken,
            uint256 collateralDelta,
            uint256 sizeDelta,
            uint256 triggerPrice,
            uint256 executionFee,
            bool isLong,
            bool triggerAboveThreshold,
            bool isIncreaseOrder,
            bool isMaxOrder) = orderManager.orders(getOrderKey(testUserAddress, _orderIndex));
            assertEq(account, address(0));
            assertEq(collateralToken, address(0));
            assertEq(indexToken, address(0));
            assertEq(collateralDelta, 0);
            assertEq(sizeDelta, 0);
            assertEq(triggerPrice, 0);
            assertEq(executionFee, 0);
        }
    }

   function testLiquidateMultiplePositionNonExistantPosition() public{
        bytes32 randomKey1 = getPositionKey(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), true);
        bytes32 randomKey2 = getPositionKey(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("BTC"), true);
        bytes32 randomKey3 = getPositionKey(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), true);
        _keys.push(randomKey1); // random keys 
        _keys.push(randomKey2);
        _keys.push(randomKey3);

        orderManager.liquidateMultiplePositions(_keys, payable(testUserAddress)); // checks if each revert is catched successfuly and the transaction does not fail, test will pass if catched succesfully
   }

   function testLiquidateMultiplePositionPartialSuccessfull() public{
        vm.startPrank(testUserAddress);
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
        vm.stopPrank();
        bytes32 positionKey = getPositionKey(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), true);

        bytes32 randomKey1 = getPositionKey(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("BTC"), true);
        _keys.push(randomKey1); // invalid key
        _keys.push(positionKey); // valid key

        // TODO: MANU Fix this liquidation price 
        mockPricesOfToken(1440, 1440, "ETH"); // position was opened at 1600, now price dropped to 1440
        vm.expectEmit(true, true, true, false, address(vault));
        emit UpdatePosition(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), true, 0, 0, 0, 0, 0, 0, 0);
        orderManager.liquidateMultiplePositions(_keys, payable(testUserAddress));
   }


}