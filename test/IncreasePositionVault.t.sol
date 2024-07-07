// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "./Helper.t.sol";

contract IncreasePositionVault is Test, Helper{

    //TODO: add a function in helper to do all these tasks such as creating orderManager, creating Vault, adding liquidity to pool. This way every test will test whatever functionality but the setup will be ready.
    function setUp() public {
        setInitialState();
    }

    function testIncreaseOrderPlaced() public {
        vm.startPrank(testUserAddress);
        vm.warp(3600);
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
        (uint256 size,
        uint256 collateral,
        uint256 averagePrice,
        uint256 entryBorrowingFee,
        int256 entryFundingFee,
        uint256 reserveAmount,
        uint256 realisedPnl,
        bool realisedPnlSign,
        uint256 lastIncreaseTime) = vault.getPosition(testUserAddress, vm.envAddress("USDCL"), vm.envAddress("ETH"), true);
        console.log("size", size);
        assertEq(size, 100000000000000000000000000000000, "Not expected size!");
        assertEq(averagePrice, 1600* PRICE_PRECISION, "Not expected Price");
        assertEq(entryBorrowingFee, 0, "Not expected Borrowing Fee");
        assertEq(entryFundingFee, 0, "Not expected Funding Fee");
        assertEq(collateral, 9900000000000000000000000000000, "Collateral doesn't match");
        assertEq(realisedPnl, 0, "Pnl doesn't match");
        vm.warp(10800);
        vault.updateCumulativeFundingRate(vm.envAddress("ETH"));
        vault.updateCumulativeBorrowingRate(vm.envAddress("USDCL"));
        int cumulativeFundingRate = vault.cumulativeFundingRatesForLongs(vm.envAddress("ETH"));
        uint cumulativeBorrowingRate = vault.cumulativeBorrowingRates(vm.envAddress("USDCL"));
        assertEq(cumulativeFundingRate, 200, "FundingRate not updated");
        vm.stopPrank();
    }

    function testUpdateInFundingFeeAndBorrowingFee() public {
        vm.startPrank(testUserAddress);
        vm.warp(3600);
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
        vm.warp(10800);
        vault.updateCumulativeFundingRate(vm.envAddress("ETH"));
        vault.updateCumulativeBorrowingRate(vm.envAddress("USDCL"));
        int cumulativeFundingRate = vault.cumulativeFundingRatesForLongs(vm.envAddress("ETH"));
        uint cumulativeBorrowingRate = vault.cumulativeBorrowingRates(vm.envAddress("USDCL"));
        assertEq(cumulativeFundingRate, 200, "FundingRate doesn't match");
        assertEq(cumulativeBorrowingRate, 20, "BorrowingRate doesn't match");
        vm.stopPrank();
    }

    function testValidateOiImbalanceIncreaseGlobalLong() public {
        vault.setMaxOIImbalance(sizeDelta, vm.envAddress("ETH")); // reduce maxOI to sizeDelta you are trying to open a position for
        // try to increase global long by a value greater than current permissible delta
        vm.startPrank(testUserAddress);
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        // execute position
        mockPricesOfToken(1600,1600,"ETH");
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 1000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDCL"));
        vm.expectRevert("Vault: Max OI breached!");
        bool executed = orderManager.executeIncreasePosition(requestKey, payable(address(testUserAddress))); 
    }
    function testValidateOiImbalanceIncreaseGlobalShort() public {
        vault.setMaxOIImbalance(sizeDelta, vm.envAddress("ETH")); // reduce maxOI to sizeDelta you are trying to open a position for
        // try to increase global long by a value greater than current permissible delta
        vm.startPrank(testUserAddress);
        bytes32 requestKey = createShortIncreasePositionOnEth(minExecutionFeeMarketOrder);
        // execute position
        mockPricesOfToken(1600,1600,"ETH");
        IERC20(vm.envAddress("USDCL")).transfer(address(vault), 1000 *10**18);
        vault.directPoolDeposit(vm.envAddress("USDCL"));
        vm.expectRevert("Vault: Max OI breached!");
        bool executed = orderManager.executeIncreasePosition(requestKey, payable(address(testUserAddress))); 
    }
    function testValidateOiImbalanceDecreaseGlobalLong() public {
        vm.startPrank(testUserAddress);
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
        vm.stopPrank();
        vault.setMaxOIImbalance(sizeDelta, vm.envAddress("ETH")); // oi Imbalance reduced after opening the position
        // now try to decrease the position       
        vm.startPrank(testUserAddress);
        bytes32 decreaseRequestKey = createLongDecreasePositionOnEth(minExecutionFeeMarketOrder);
        executeDecreasePositionOnEth(decreaseRequestKey, 1600, 1600);
    }
    function testValidateOiImbalanceDecreaseGlobalShort() public {
        vm.startPrank(testUserAddress);
        bytes32 requestKey = createShortIncreasePositionOnEth(minExecutionFeeMarketOrder);
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
        vm.stopPrank();
        vault.setMaxOIImbalance(sizeDelta, vm.envAddress("ETH")); // oi Imbalance reduced after opening the position
        // now try to decrease the position       
        vm.startPrank(testUserAddress);
        bytes32 decreaseRequestKey = createShortDecreasePositionOnEth(minExecutionFeeMarketOrder);
        executeDecreasePositionOnEth(decreaseRequestKey, 1600, 1600);
    }



    function testIncreaseThenDecrease25PercentWithProfit() public {
        vm.startPrank(testUserAddress);
        vm.warp(3600);
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
        vm.warp(10800);

        vm.stopPrank();
    }

    function testIncreaseThenDecrease25PercentWithLoss() public {
        vm.startPrank(testUserAddress);
        vm.warp(3600);
        bytes32 requestKey = createLongIncreasePositionOnEth(minExecutionFeeMarketOrder);
        executeIncreasePositionOnEth(requestKey, 1600, 1600);
        vm.warp(10800);
        vm.stopPrank();
    }  

    function testIncreaseThenDecrease50Percent() public {
    } 

    function testIncreaseThenDecrease75Percent() public {
    } 

    function testIncreaseThenDecrease100Percent() public {
    } 

}