// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import "./Helper.t.sol";

contract vaultTest is Test, Helper {
    function setUp() public {
        vault = deployVault();
        usdl = deployUSDL(vault);
        priceFeed = deployAndInitializePriceFeed();
        utils = deployUtils(vault, priceFeed);
        vault.setUtils(utils);
        vault.setSafetyFactor(1);
        vault.setUsdl(address(usdl));
        vault.setTokenConfig(vm.envAddress("USDCL"), 18, 0, true, true, false, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("ETH"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setMaxLeverage(54*10000, vm.envAddress("ETH"));
        vault.setMaxLeverage(54*10000, vm.envAddress("BTC"));
        orderManager = new OrderManager(
            address(vault),
            address(utils),
            address(priceFeed),
            minExecutionFeeMarketOrder,
            minExecutionFeeLimitOrder,
            depositFee,
            maxProfitMultiplier
        );
        vault.setOrderManager(address(orderManager), true);
        vault.setPriceFeed(address(priceFeed));
        mockPricesOfToken(1, 1, "USDCL");
        mockPricesOfToken(1650, 1650,"ETH");
    }

    /*     6. increasePosition
           6.4 Do we need to check updateCumulativeBorrowingRate and updateCumulativeFundingRate by opening position multiple time, since they have their separate tests?? DISCUS
           6.5 Check if an existing position is increases what values are being set, test getNextAveragePrice IMPORTANT, update prices here
           6.6 marginFee is collected and fee reserves are updated
           6.7 specified collateralAmount is sent to vault
           6.8 check a case where fee exceeds collateral
           6.9 check for both fee + and -
           6.10 size always >= collateral - validatePosition
           6.11 test validateLiquidation
           6.12 reservedAMount is increased
           6.13 check for emitted events
     */
    // 6.1 check for valid collateral and index tokens
    function testIncreasePositionValidTokens() public {
        vm.startPrank(address(orderManager));
        address collateralToken = makeAddr("Random collateral address");
        address indexToken = makeAddr("Random Index Address");

        vm.expectRevert("Vault: Invalid collateralToken");
        increasePositionVault(
            testUserAddress,
            collateralToken,
            vm.envAddress("ETH"),
            sizeDelta,
            true
        );
        vm.expectRevert("Vault: Invalid indexToken");
        increasePositionVault(
            testUserAddress,
            vm.envAddress("USDCL"),
            indexToken,
            sizeDelta,
            true
        );
    }

    //6.2 check heavy exposure per user and 6.3 Huge liquidity single user check
    // function test_increasePosition_maxExposure() public {
    //     vm.startPrank(address(orderManager));
    //     // dont set maxExposurePerUser default is 0, try opening a position then it shoudl fail
    //     vm.expectRevert("Utils: Heavy exposure for single user");
    //     increasePositionVault(
    //         testUserAddress,
    //         vm.envAddress("USDCL"),
    //         vm.envAddress("ETH"),
    //         sizeDelta,
    //         true
    //     );
    //     vm.stopPrank();
    //     // set maxExposure greater than 100 and for first position it should pass
    //     vm.prank(address(this));
    //     vault.setMaxExposurePerUser(110);
    //     vm.expectRevert("Utils: Huge liquidity captured for single user");
    //     vm.startPrank(address(orderManager));
    //     increasePositionVault(
    //         testUserAddress,
    //         vm.envAddress("USDCL"),
    //         vm.envAddress("ETH"),
    //         sizeDelta,
    //         true
    //     );
    // }

    //6.5 Check if opening a position for first time, values are set correctly

    /*    4. buyUSDL
            Try with different values of tokenAmount(fuzz testing) - Do for all tests wherever possible once all the test cases are finalised
    */

    // 4.0 only orderManager can call vault
    function testBuyUsdlOrderManagerValidationCheck() public {
        vault.setInManagerMode(true);
        address randomUser = makeAddr("Random user address");
        vm.prank(randomUser);
        vm.expectRevert("Vault: not manager");
        vault.buyUSDL(vm.envAddress("USDCL"), testUserAddress);
    }

    // 4.1 Try sending a token that is not whitelisted
    function testBuyUsdlTokenValidation() public {
        address collateralToken = makeAddr("Random collateral address");
        vm.expectRevert("Vault: Not a whitelisted token");
        vault.buyUSDL(collateralToken, testUserAddress);
    }

    // 4.2 Try buying llp by sending zero tokens
    function testBuyUsdlTokenAmountZero() public {
        // mock balanceOf call with prev balance to return 0 from _transferIn
        mockUSDCLTransfer(0);
        vm.expectRevert("Vault: tokenAmount too low");
        vault.buyUSDL(vm.envAddress("USDCL"), testUserAddress);
    }

    // 4.3 Try a case where output usdlAmount amounts to zero, mock price to zero
    function testBuyUsdlZeroUsdl() public {
        mockPricesOfToken(0, 0, "USDCL");
        console.log("test");
        mockUSDCLTransfer(10 * 10 ** 18);
        vm.expectRevert("Vault: usdlAmount too low");
        uint256 usdlAmount = vault.buyUSDL(
            vm.envAddress("USDCL"),
            testUserAddress
        );
        console.log("usdlamount", usdlAmount);
    }

    //  4.4 Check if fee is deducted correctly
    function testBuyUsdlSuccessfullFee() public {
        uint256 transferAmount = 1000 * 10 ** 18;
        // check feeReserves[_token] value
        uint256 usdlAmount = buyUsdlHelper(transferAmount);
        // usdlAMount should be .3% of transferAmount
        uint256 amountAfterFee = (transferAmount *
            (BASIS_POINTS_DIVISOR - vault.mintBurnFeeBasisPoints())) /
            BASIS_POINTS_DIVISOR;
        assertEq(usdlAmount, amountAfterFee);
        assertEq(
            transferAmount - amountAfterFee,
            vault.feeReserves(vm.envAddress("USDCL"))
        );
    }

    // 4.5 pool amount should increase
    function testBuyUsdlSuccessfullPoolAmount() public {
        uint256 transferAmount = 1000 * 10 ** 18;
        // check feeReserves[_token] value
        uint256 initialPoolAmount = vault.poolAmounts(vm.envAddress("USDCL"));
        uint256 usdlAmount = buyUsdlHelper(transferAmount);
        uint256 finalPoolAmount = vault.poolAmounts(vm.envAddress("USDCL"));
        // usdlAMount should be .3% of transferAmount
        uint256 amountAfterFee = (transferAmount *
            (BASIS_POINTS_DIVISOR - vault.mintBurnFeeBasisPoints())) /
            BASIS_POINTS_DIVISOR;
        assertEq(finalPoolAmount - initialPoolAmount, amountAfterFee);
    }

    //  4.6 check before and after usdl supply to check right amount of usdl is minted
    function testBuyUsdlSuccessfullUsdl() public {
        uint256 initialSupply = IERC20(usdl).totalSupply();
        uint256 usdlAmount = buyUsdlHelper(1000 * 10 ** 18);
        uint256 finalSupply = IERC20(usdl).totalSupply();
        assertEq(finalSupply - initialSupply, usdlAmount);
    }

    //  4.4 Check _receivers usdl balance in each case
    function testBuyUsdlReceiverBalanceCheck() public {
        uint256 initialBalance = IERC20(usdl).balanceOf(testUserAddress);
        uint256 usdlAmount = buyUsdlHelper(1000 * 10 ** 18);
        uint256 finalBalance = IERC20(usdl).balanceOf(testUserAddress);
        assertEq(finalBalance - initialBalance, usdlAmount);
    }

    /*     5. sellUSDL
           5.2 Transfer different amounts of usdl(fuzz testing)
           5.5 check before and after usdl supply to check right amount of usdl is burnt
           5.6 tokenBalances[_token] for usdl shoudl increase
    */

    //  5.1 Try sending a token that is not whitelisted
    function testSellUsdlTokenValidation() public {
        address collateralToken = makeAddr("Random collateral address");
        vm.expectRevert("Vault: Not a whitelisted token");
        vault.sellUSDL(collateralToken, testUserAddress);
    }

    // 5.2 check when 0 usdl is transfered
    function testSellUsdlZeroUsdlSent() public {
        mockUSDLTransfer(0);
        vm.expectRevert("Vault: usdlAmount too low");
        vault.sellUSDL(vm.envAddress("USDCL"), testUserAddress);
    }

    // 5.3 Check one case where redemptionAmount amounts to zero
    function testSellUsdlZeroRedemptionAmount() public {
        uint256 trasferAmount = 1000 * 10 ** 18;
        mockUSDLTransfer(trasferAmount);
        // mock utils.getRedemptionAmount() with return value as 0
        vm.mockCall(
            address(address(utils)),
            abi.encodeWithSelector(utils.getRedemptionAmount.selector),
            abi.encode(0)
        );
        vm.expectRevert("Vault: redemptionAmount too low");
        vault.sellUSDL(vm.envAddress("USDCL"), testUserAddress);
    }

    // 5.4 Check pool amounts is decreased according to redemptionAmount
    function testSellUSDLSuccessFullPoolAmount() public {
        // 1. buy some usdl
        uint256 transferUSDCLAmount = 1000 * 10 ** 18;
        uint256 usdlAmount = buyUsdlHelper(transferUSDCLAmount);
        uint256 finalPoolAmount = vault.poolAmounts(vm.envAddress("USDCL"));
        console.log("final balance", finalPoolAmount); // 99.7% of USDCL amount

        // 2. try selling half
        uint256 amountOut = sellUsdlHelper(transferUSDCLAmount / 2); // - Causing issue because trying to burn usdl which is not present in vault
        console.log("sellusdl amount out", amountOut);
    }

    /*  1. directPoolDeposit
            1.1 try to deposit unlisted token
            1.2 send some ERC20 and check if tokenBalances[_token] is increased with the same value
            1.3 check DirectPoolDeposit is emitted with write _token and tokenAmount
    */

    /*   2. updateCumulativeBorrowingRate
            2.1 check for lastBorrowingTime = 0
            2.2 check when one interval has not passed, lastBorrowingTime shoudl be same and rate 0
            2.3 move ahead in time by few intervals(fuzz testing)
            2.3.1 test for variable intervals and with different reservedAmount and poolAmount(fuzz testing)
   */

    /*    3. updateCumulativeFundingRate
            3.1 Test for same time interval dependent cases as updateCumulativeBorrowingRate
            3.2 Try with different globalLongSizes and globalShortSizes(fuzz testing)
                Two ways to do this: Mock the  vault.globalLongSizes(_indexToken) and vault.globalShortSizes(_indexToken) calls or genuinely increase these two values be openign and closing positions - ASK Anirudh
            3.3 if longs size> shorts size then longs should be gaining funding fee.
   */

    /*     7. decreasePosition(_collateralDelta will always be zero from frontend)
           7.1 Try closing a non existant position
           7.2 Try closing a sizeDelta greater than position.size
           7.3 Try decreasing collateral greater than collateralDelta
           7.4 check if reservedAmounts[_token] is decreased in right proportion of sizeDelta and positionSize
           7.5 mock utils.getDelta for hasProfit true and false and check pool amount is increased when hasProfit false and viceVersa
           7.6 try closign 100% of the position and check if all collateral is returned
                7.6.1 check for both fee +ve and -ve
           7.7 
 */

    /*     8.2 collectMarginFees
            8.1nmock utils.collectMarginFees for feeTokens and feeUsd(+ve -ve) and check if feeReserves[_collateralToken] is updated correctly


 */

    /*     9.3 utils.delta
            9.4 

 */
}
