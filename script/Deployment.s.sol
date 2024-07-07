// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import '../src/contracts/core/PriceFeed.sol';
import "forge-std/Script.sol";
import '../src/contracts/core/Vault.sol';
import '../src/contracts/core/OrderManager.sol';
import '../src/contracts/core/USDL.sol';
import '../src/contracts/core/LlpManager.sol';
import '../src/contracts/core/RewardRouter.sol';
import '../src/contracts/core/RewardTracker.sol';
import '../src/contracts/core/Utils.sol';
import '../src/contracts/libraries/token/IERC20.sol';

contract Deployment is Script {
    uint constant liquidationFeeUsd = 5 * 10 ** 30;
    uint constant liquidationFactor = 100;
    uint constant borrowingRateFactor = 100;
    uint constant maxAllowedDelayPriceFeed = 300;
    uint constant minExecutionFeeMarketOrder = 37 * 10 ** 16;
    uint constant minExecutionFeeLimitOrder = 37 * 10 ** 16;
    uint constant llpCooldownDuration = 1 hours;
    uint constant maxGlobalLongSize = 2000;
    uint constant maxGlobalShortSize = 2000;
    uint constant minPurchaseTokenAmountUsd = 0;
    uint constant depositFee = 10;
    address constant executor = 0x143328D5d7C84515b3c8b3f8891471ff872C0015;
    uint public maxProfitMultiplier = 9;
    address[] rewardTrackerDepositToken;
    uint256 public fundingInterval = 3600;
    uint256 public fundingRateFactor = 100;
    uint256 public fundingExponent = 1;
    uint256 public maxOIImbalance = 10**36;
    uint256 public safetyFactorVault = 90;
    uint256 public oiImbalancethreshold = 2000;



    function run() external{  
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_ADMIN"); 
        vm.startBroadcast(deployerPrivateKey);
        allContractDeployments();
        vm.stopBroadcast();
    }

    function allContractDeployments() public {
        Vault vault = deployVault();
        PriceFeed priceFeed  = deployAndInitializePriceFeed();
        USDL usdl = deployUSDL(vault);
        RewardRouter rewardRouter = deployRewardRouter();
        Utils utils = deployUtils(vault, priceFeed);
        LlpManager llpManager = deployLlpManager(vault, utils, usdl, rewardRouter);
        initializeLLP(llpManager);
        OrderManager orderManager = deployOrderManager(vault, priceFeed, utils);
        initializeVault(vault, orderManager, priceFeed, usdl, utils, llpManager);
        RewardTracker rewardTracker = deployRewardTracker();
        initlializeRewardTracker(rewardTracker);
        initializeRewardRouter(rewardRouter, vm.envAddress("LLP"), address(llpManager), address(rewardTracker));
    }

    function deployOrderManager(Vault vault, PriceFeed priceFeed, Utils utils) public returns (OrderManager){
        OrderManager orderManager = new OrderManager(address(vault), address(utils), address(priceFeed),minExecutionFeeMarketOrder, minExecutionFeeLimitOrder, depositFee, maxProfitMultiplier);
        console.log("OrderManager deployed at address: ", address(orderManager));
        orderManager.setPositionKeeper(address(priceFeed), true);
        orderManager.setMinExecutionFeeLimitOrder(minExecutionFeeLimitOrder);
        orderManager.setMinExecutionFeeMarketOrder(minExecutionFeeMarketOrder);
        orderManager.setLiquidator(0x143328D5d7C84515b3c8b3f8891471ff872C0015, true);
        orderManager.setOrderKeeper(0x143328D5d7C84515b3c8b3f8891471ff872C0015, true);
        orderManager.setDelayValues(0, 0, 3600);
        return orderManager;
    }

    function initializeRewardRouter(RewardRouter rewardRouter, address llp, address llpManager, address rewardTracker) public {
        rewardRouter.initialize(llp, llpManager, rewardTracker);
        RewardTracker(rewardTracker).setHandler(address(rewardRouter), true);
    }

    function deployRewardTracker() public returns (RewardTracker){
        RewardTracker rewardTracker = new RewardTracker("fee LLP", "fLlp");
        console.log("RewardTracker deployed at address: ", address(rewardTracker));
        return rewardTracker;
    }

    function initlializeRewardTracker(RewardTracker rewardTracker) public {
        rewardTrackerDepositToken.push(vm.envAddress("LLP"));
        address[] memory _depositTokens = rewardTrackerDepositToken;
        rewardTracker.initialize(_depositTokens, vm.envAddress("USDCL"), vm.envAddress("ADMIN"));
    }

    function deployUtils(Vault vault, PriceFeed pricefeed) public returns (Utils){
        Utils utils = new Utils(vault, pricefeed);
        console.log("Utils deployed at address: ", address(utils));
        return utils;
    }

    function deployUSDL(Vault vault) public returns (USDL){
        USDL usdl = new USDL(address(vault));
        console.log("USDL deployed at address: ", address(usdl));
        return usdl;
    }

    function deployRewardRouter() public returns (RewardRouter){
        RewardRouter rewardRouter = new RewardRouter();
        console.log("RewardRouter deployed at address: ", address(rewardRouter));
        return rewardRouter;
    }

    function initializeLLP(LlpManager llpManager) public {
        IMintable llp = IMintable(vm.envAddress("LLP"));
        llp.setMinter(address(llpManager), true);
    }

    function deployLlpManager(Vault vault, Utils utils, USDL usdl, RewardRouter rewardRouter) public returns (LlpManager){
        LlpManager llpManager = new LlpManager(address(vault), address(utils), address(usdl), vm.envAddress("LLP"), llpCooldownDuration, 10**36);
        llpManager.setHandler(address(rewardRouter), true);
        llpManager.whiteListToken(vm.envAddress("USDCL"));
        console.log("LlpManager deployed at address: ", address(llpManager));
        usdl.addVault(address(llpManager));  // also add llpmanager as vault in usdl(this is needed when llpManager mints usdl)
        return llpManager;
    }

    function deployAndInitializePriceFeed() public returns (PriceFeed){
        PriceFeed priceFeed = new PriceFeed(maxAllowedDelayPriceFeed, vm.envAddress("PYTH_CONTRACT"), vm.envAddress("UPDATER"), 15);
        console.log("PriceFeed deployed at address: ", address(priceFeed));
        priceFeed.updateTokenIdMapping(vm.envAddress("USDCL"), vm.envBytes32("USDC_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("ETH"), vm.envBytes32("ETH_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("BTC"), vm.envBytes32("BTC_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("UNI"), vm.envBytes32("UNI_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("LINK"), vm.envBytes32("LINK_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("ARB"), vm.envBytes32("ARB_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("CRV"), vm.envBytes32("CRV_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("AVAX"), vm.envBytes32("AVAX_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("BNB"), vm.envBytes32("BNB_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("FTM"), vm.envBytes32("FTM_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("OP"), vm.envBytes32("OP_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("MATIC"), vm.envBytes32("MATIC_PYTH_FEED"));
        priceFeed.updateTokenIdMapping(vm.envAddress("MNT"), vm.envBytes32("MNT_PYTH_FEED"));

        // executor address
        priceFeed.setUpdater(vm.envAddress("EXECUTOR1"));
        priceFeed.setUpdater(vm.envAddress("EXECUTOR2"));
        priceFeed.setUpdater(vm.envAddress("EXECUTOR3"));
        priceFeed.setUpdater(vm.envAddress("EXECUTOR4"));
        priceFeed.setUpdater(vm.envAddress("EXECUTOR5"));
        priceFeed.setUpdater(vm.envAddress("EXECUTOR6"));
        priceFeed.setUpdater(vm.envAddress("EXECUTOR7"));
        priceFeed.setUpdater(vm.envAddress("EXECUTOR8"));

        console.log("PriceFeed initialized");
        return priceFeed;
    }

    function deployVault() public returns (Vault){
        Vault vault = new Vault(); 
        console.log("Vault deployed at address: ", address(vault));
        return vault;
    }

    function initializeVault(Vault vault, OrderManager orderManager, PriceFeed priceFeed, USDL usdl, Utils utils, LlpManager llpManager) public {
        usdl.addVault(address(vault));
        vault.initialize(address(orderManager), address(usdl), address(priceFeed),liquidationFeeUsd,liquidationFactor, borrowingRateFactor);
        vault.setTokenConfig(vm.envAddress("USDCL"), 18, 0, true, true, false, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("ETH"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("BTC"), 8, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("UNI"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("LINK"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("ARB"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("CRV"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("AVAX"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("BNB"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("FTM"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("OP"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("MATIC"), 18, 0, false, false, true, 540000, maxOIImbalance);
        vault.setTokenConfig(vm.envAddress("MNT"), 18, 0, false, false, true, 540000, maxOIImbalance);
        //TODO: maxGlobalLongSize is not needed for collateral token it is needed only for indextokens but 
        // we are not setting it here.
        vault.setMaxGlobalLongSize(vm.envAddress("USDCL"), maxGlobalLongSize);
        vault.setMaxGlobalShortSize(vm.envAddress("USDCL"), maxGlobalShortSize);
        vault.setUtils(utils);
        vault.setInManagerMode(true);
        vault.setManager(address(llpManager), true);
        vault.setFundingRate(fundingInterval, fundingRateFactor, fundingExponent);

        vault.setSafetyFactor(safetyFactorVault);
    }

    //util functions
    function addLiquidity() public {
        IERC20 usdc = IERC20(vm.envAddress("USDCL"));
        usdc.approve(vm.envAddress("LLP_MANAGER"), 10000000*10**18);
        RewardRouter rewardRouter = RewardRouter(vm.envAddress("REWARD_ROUTER"));
        rewardRouter.mintLlp(vm.envAddress("USDCL"), 100000000000000000000000, 0, 0);
    }

    function updateOnlyPriceFeed() public {
        OrderManager orderManager = OrderManager(vm.envAddress("ORDER_MANAGER"));
        Vault vault = Vault(vm.envAddress("VAULT"));
        PriceFeed priceFeed = deployAndInitializePriceFeed();
        orderManager.setPositionKeeper(address(priceFeed), true);
        vault.setPriceFeed(address(priceFeed));
    }

    function decreaseMarketPositions() public {
        uint256 deployerPrivateKey = vm.envUint("FUNDS_PROVIDER_PVT_KEY"); 
        OrderManager orderManager = OrderManager(vm.envAddress("ORDER_MANAGER"));
        vm.startBroadcast(deployerPrivateKey);
        orderManager.createDecreasePosition{value: 38*10**16}(vm.envAddress("USDCL"), vm.envAddress("UNI"), 0, 10991053747058005000000000000000,
        true, 0x678F9fBAce927A9490070bf1eDB1564E26e0Db8c, 4316099772300000000000000000000, 38*10**16);
        vm.stopBroadcast();
        uint256 decPos = orderManager.decreasePositionRequestKeysStart();
        // vm.stopPrank();
        // vm.startPrank(vm.envAddress("ADMIN"));
        //orderManager.executeDecreasePositions(decPos+ 1, payable(vm.envAddress("ADMIN")));
        //vm.stopPrank();
    }

    function increaseMarketPositions() public {
        uint256 deployerPrivateKey = vm.envUint("FUNDS_PROVIDER_PVT_KEY"); 
        OrderManager orderManager = OrderManager(vm.envAddress("ORDER_MANAGER"));
        vm.startBroadcast(deployerPrivateKey);
        IERC20  usdc = IERC20(vm.envAddress("USDCL"));
        usdc.approve(vm.envAddress("ORDER_MANAGER"), 200*10**18);
        orderManager.createIncreasePosition{value: 38*10**16}(vm.envAddress("USDCL"), vm.envAddress("OP"), 10000000000000000000, 10988347427288002000000000000000,
        true, 1302658323600000000000000000000, 0, 0, 38*10**16);
        orderManager.createIncreasePosition{value: 38*10**16}(vm.envAddress("USDCL"), vm.envAddress("BTC"), 10000000000000000000, 10988347427288002000000000000000,
        false, 25354550100000000000000000000000000, 0, 0, 38*10**16);
        vm.stopBroadcast();
    }

    function deployTempUtils() public {

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY_ADMIN"); 
        Vault vault = Vault(vm.envAddress("VAULT"));
        LlpManager llpManager = LlpManager(vm.envAddress("LLP_MANAGER"));
        PriceFeed pricefeed = PriceFeed(vm.envAddress("PRICE_FEED"));
        vm.startBroadcast(deployerPrivateKey);
        Utils utils = new Utils(vault, pricefeed);
        vault.setUtils(utils);
        llpManager.setUtils(address(utils));
        vault.setLiquidator(0x678F9fBAce927A9490070bf1eDB1564E26e0Db8c, true);
        vault.liquidatePosition(0x89708d517aC399244Cf3Ff54324f793A2432AC93, 0xA11be02594AEF2AB383703D4ac7c7aD01767B30E, 0x0000000000000000000000000000000000000001, true, 0x678F9fBAce927A9490070bf1eDB1564E26e0Db8c);
        vm.stopBroadcast();
    }

}